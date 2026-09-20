# Invoked by writeShellApplication (bash, with a fixed Nix-provided PATH).
# No device reset, I2C probing, raw input capture, or automatic suspension.
set -euo pipefail

usage() {
  echo 'Usage: resume-diagnostics {prepare|resume|settled|capture [LABEL]|list}'
  echo 'Reports: /var/lib/resume-diagnostics (root and wheel readable).'
  echo 'Run capture broken BEFORE resetting a failed device; capture recovered afterward.'
}
if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  usage
  exit 0
fi
case ${1:-} in prepare|resume|settled|capture|list) ;; *) usage >&2; exit 2 ;; esac
if (( EUID != 0 )); then
  echo 'Run this command as root; it reads debugfs/tracefs.' >&2
  exit 1
fi

state=/var/lib/resume-diagnostics
run=/run/resume-diagnostics
trace_root=/sys/kernel/tracing
instance=$trace_root/instances/resume-diagnostics
touchpad=/sys/bus/i2c/devices/i2c-PIXA3854:00
install -d -m 2750 -g wheel "$state"
install -d -m 0700 "$run"
umask 027
exec 9>"$run/lock"
flock -w 5 9

new_report() {
  local label=$1 dir
  dir=$(mktemp -d "$state/capture-$(date -u +%Y%m%dT%H%M%S.%N)-XXXXXX")
  chmod 2750 "$dir"
  printf '%s\n' "$label" > "$dir/reason"
  printf '%s\n' "$dir"
}
prune() {
  local i
  local -a reports
  mapfile -t reports < <(find "$state" -mindepth 1 -maxdepth 1 -type d -name 'capture-*' -printf '%f\n' | sort -r)
  for ((i=16; i<${#reports[@]}; i++)); do
    # Only our own generated report directories, never arbitrary paths.
    rm -rf -- "${state:?}/${reports[i]}"
  done
}
read_file() {
  local f=$1
  printf '\n=== %s ===\n' "$f"
  if [[ -r $f ]]; then
    timeout 2s cat "$f" || echo '(read failed or timed out)'
  else
    echo '(unavailable on this kernel/device)'
  fi
}
irq_numbers() {
  awk '/PIXA3854:00|pinctrl_amd/ {gsub(":", "", $1); if ($1 ~ /^[0-9]+$/) print $1}' /proc/interrupts
}
snapshot() {
  local dest=$1 f irq dev
  install -d -m 2750 -g wheel "$dest"
  {
    date --iso-8601=ns
    uname -a
    printf 'current-system: '; readlink -f /run/current-system || true
    printf 'booted-kernel: '; readlink -f /run/booted-system/kernel || true
    for f in /proc/sys/kernel/random/boot_id /proc/cmdline /proc/sys/kernel/tainted \
      /proc/sys/kernel/sysrq /proc/interrupts /proc/bus/input/devices \
      /sys/power/pm_async /sys/power/mem_sleep /sys/power/suspend_stats/* \
      /sys/class/dmi/id/{product_name,bios_version,bios_date} \
      /sys/kernel/debug/gpio /sys/kernel/debug/pinctrl/AMDI0030:00/{pins,pinconf-pins} \
      /proc/lockdep_stats; do
      read_file "$f"
    done
    while read -r irq; do
      for f in /proc/irq/"$irq"/{spurious,smp_affinity_list,effective_affinity_list} \
        /sys/kernel/debug/irq/irqs/"$irq"; do
        read_file "$f"
      done
    done < <(irq_numbers)
    for dev in "$touchpad" /sys/bus/platform/devices/AMDI0010:03 /sys/bus/platform/devices/AMDI0030:00; do
      printf '\n=== device %s ===\n' "$dev"
      readlink -f "$dev/driver" || true
      for f in "$dev"/power/{control,runtime_status,wakeup,runtime_active_time,runtime_suspended_time} \
        "$dev"/uevent "$dev"/firmware_node/path; do
        read_file "$f"
      done
    done
    # Static report descriptor, NOT input reports/keystrokes.
    for f in "$touchpad"/*/report_descriptor; do
      [[ -r $f ]] || continue
      printf '\n=== HID descriptor %s ===\n' "$f"
      timeout 2s od -An -tx1 "$f" || true
    done
  } > "$dest/hardware.txt" 2>&1
  timeout 5s journalctl -b -k -n 1200 --no-pager -o short-monotonic > "$dest/kernel.log" 2>&1 || true
  timeout 5s journalctl -b -u systemd-logind -u display-manager -n 160 --no-pager -o short-iso > "$dest/session.log" 2>&1 || true
}
health_snapshot() {
  local dest=$1
  # Not called from the pre-sleep hook: user.slice may be frozen there.
  {
    timeout 3s systemctl show systemd-logind -p MainPID -p NRestarts -p ActiveState || true
    timeout 3s loginctl list-sessions --no-pager || true
    timeout 3s loginctl show-seat seat0 -p ActiveSession -p Sessions || true
  } > "$dest/session-state.txt" 2>&1
}
setup_trace() {
  local dest=$1 fn filter='' irq event
  local -a selected=()
  if [[ ! -d $trace_root/instances ]]; then
    echo 'tracefs unavailable; hardware/journal snapshots still collected' > "$dest/tracing-unavailable.txt"
    return
  fi
  mkdir -p "$instance"
  echo 0 > "$instance/tracing_on"
  echo 0 > "$instance/events/enable"
  echo nop > "$instance/current_tracer"
  echo 256 > "$instance/buffer_size_kb" # per CPU, bounded ring buffer
  echo global > "$instance/trace_clock"
  : > "$instance/trace"
  : > "$instance/set_ftrace_filter"
  # Match only existing traceable symbols, including compiler-generated suffixes.
  # Excludes input-report bodies and high-frequency GPIO mask/unmask calls.
  while read -r fn _; do
    case $fn in
      i2c_hid_core_suspend|i2c_hid_core_suspend.*|i2c_hid_core_resume|i2c_hid_core_resume.*|\
      i2c_hid_set_power|i2c_hid_set_power.*|i2c_hid_start_hwreset|i2c_hid_finish_hwreset|\
      amd_gpio_suspend|amd_gpio_suspend_hibernate_common|amd_gpio_resume|\
      amd_gpio_irq_enable|amd_gpio_irq_disable|amd_gpio_irq_set_wake|\
      mt_suspend|mt_reset_resume|mt_set_modes)
        selected+=("$fn") ;;
    esac
  done < "$trace_root/available_filter_functions"
  if (( ${#selected[@]} )); then
    printf '%s\n' "${selected[@]}" > "$instance/set_ftrace_filter"
    if grep -qw function_graph "$instance/available_tracers"; then
      echo function_graph > "$instance/current_tracer"
      if [[ -e $instance/options/funcgraph-retval ]]; then
        echo 1 > "$instance/options/funcgraph-retval"
      fi
      if [[ -e $instance/options/funcgraph-args ]]; then
        echo 0 > "$instance/options/funcgraph-args"
      fi
    else
      echo function > "$instance/current_tracer"
    fi
  else
    # Never enable unfiltered function tracing if symbols were inlined/absent.
    echo 'No matching functions; using PM/IRQ trace events only' > "$dest/functions-unavailable.txt"
  fi
  for event in power/device_pm_callback_start power/device_pm_callback_end power/suspend_resume; do
    if [[ -e $instance/events/$event/enable ]]; then
      echo 1 > "$instance/events/$event/enable"
    fi
  done
  while read -r irq; do
    [[ -z $filter ]] || filter+=' || '
    filter+="irq == $irq"
  done < <(irq_numbers)
  if [[ -n $filter ]]; then
    for event in irq/irq_handler_entry irq/irq_handler_exit; do
      if [[ -e $instance/events/$event/filter ]]; then
        printf '%s\n' "$filter" > "$instance/events/$event/filter"
        echo 1 > "$instance/events/$event/enable"
      fi
    done
  fi
  {
    read_file "$instance/current_tracer"
    read_file "$instance/set_ftrace_filter"
    read_file "$instance/buffer_size_kb"
    read_file "$instance/trace_clock"
    read_file "$instance/options/funcgraph-retval"
    printf '\nIRQ filter: %s\n' "$filter"
    printf 'Enabled events:\n'
    grep -l '^1$' "$instance"/events/{power,irq}/*/enable || true
  } > "$dest/trace-config.txt"
  echo 1 > "$instance/tracing_on"
  echo 'resume-diagnostics: prepared' > "$instance/trace_marker"
}
save_trace() {
  local dest=$1 f
  [[ -d $instance ]] || return 0
  echo 0 > "$instance/tracing_on"
  timeout 5s cat "$instance/trace" > "$dest/trace.txt" || true
  # Overrun counters reveal whether the bounded buffer lost earlier events.
  for f in "$instance"/per_cpu/cpu*/stats; do
    [[ -r $f ]] || continue
    read_file "$f"
  done > "$dest/trace-stats.txt"
}
current_report() {
  local dir
  [[ -r $run/current ]] || return 1
  read -r dir < "$run/current"
  [[ $dir == "$state"/capture-* && -d $dir ]] || return 1
  printf '%s\n' "$dir"
}

case $1 in
  prepare)
    dir=$(new_report sleep)
    printf '%s\n' "$dir" > "$run/current"
    # Trace setup failure must not prevent snapshots or sleep.
    # Separate process preserves errexit even though failure is handled here.
    if trace_root="$trace_root" instance="$instance" bash -e -u -o pipefail -c "$(declare -f read_file irq_numbers setup_trace); setup_trace \"\$1\"" \
      _ "$dir" 2>"$dir/trace-setup.log"; then
      :
    else
      echo 'Trace setup failed; see trace-setup.log' >&2
      [[ ! -d $instance ]] || echo 0 > "$instance/tracing_on"
    fi
    snapshot "$dir/pre"
    prune
    echo "$dir"
    ;;
  resume)
    dir=$(current_report) || dir=$(new_report resume-without-pre)
    save_trace "$dir"
    snapshot "$dir/post"
    echo "$dir"
    ;;
  settled)
    dir=$(current_report) || exit 0
    [[ -d $dir/post ]] || exit 0
    snapshot "$dir/settled"
    health_snapshot "$dir/settled"
    ;;
  capture)
    label=${2:-manual}
    [[ $label =~ ^[a-zA-Z0-9_-]{1,40}$ ]] || { echo 'Invalid label' >&2; exit 2; }
    dir=$(new_report "$label")
    current_report > "$dir/previous-sleep-report.txt" || true
    save_trace "$dir"
    snapshot "$dir/manual"
    health_snapshot "$dir/manual"
    prune
    echo "$dir"
    ;;
  list)
    find "$state" -mindepth 1 -maxdepth 1 -type d -name 'capture-*' | sort
    ;;
esac
