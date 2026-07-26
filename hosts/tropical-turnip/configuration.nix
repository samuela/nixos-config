# Configuration for tropical-turnip (Framework 13" AMD 7040)
{ config, pkgs, ... }:

let
  # Last updated 2026-04-05
  nixos-hardware = builtins.fetchTarball "https://github.com/NixOS/nixos-hardware/archive/80afbd13eea0b7c4ac188de949e1711b31c2b5f0.tar.gz";

  writeLean =
    nameOrPath:
    {
      lean ? pkgs.lean4,
      strip ? true,
      makeWrapperArgs ? [ ],
    }:
    content:
    let
      exeName = builtins.baseNameOf nameOrPath;
    in
    pkgs.writers.makeBinWriter {
      inherit strip makeWrapperArgs;
      compileScript = ''
        export HOME="$PWD"
        export XDG_CACHE_HOME="$PWD/.cache"
        export CC="${pkgs.stdenv.cc}/bin/cc"
        export AR="${pkgs.binutils}/bin/ar"

        cp "$contentPath" Main.lean
        cat > lakefile.lean <<'EOF'
        import Lake
        open Lake DSL

        package generatedLeanBin

        lean_exe «${exeName}» where
          root := `Main
        EOF

        ${pkgs.lib.getExe' lean "lake"} build ${pkgs.lib.escapeShellArg exeName}
        cp ".lake/build/bin/${exeName}" "$out"
      '';
    } nameOrPath content;

  sleepFailureDiagnostics = pkgs.writeShellScript "sleep-failure-diagnostics" ''
    set +e

    failed_action="$1"
    echo "sleep-failure: diagnostics begin: action=$failed_action"
    echo "sleep-failure: timestamp=$(${pkgs.coreutils}/bin/date --iso-8601=seconds)"

    for path in \
      /proc/cmdline \
      /proc/sys/kernel/tainted \
      /sys/power/state \
      /sys/power/mem_sleep \
      /sys/power/disk \
      /sys/power/pm_async \
      /sys/power/pm_trace \
      /sys/power/wakeup_count \
      /sys/power/suspend_stats/*; do
      if [ -r "$path" ]; then
        echo "sleep-failure: file=$path value=$(${pkgs.coreutils}/bin/cat "$path")"
      fi
    done

    for supply in /sys/class/power_supply/*; do
      [ -d "$supply" ] || continue
      for field in \
        type status online capacity capacity_level \
        energy_now energy_full energy_full_design power_now \
        charge_now charge_full charge_full_design current_now voltage_now; do
        if [ -r "$supply/$field" ]; then
          echo "sleep-failure: file=$supply/$field value=$(${pkgs.coreutils}/bin/cat "$supply/$field")"
        fi
      done
    done

    ${pkgs.systemd}/bin/systemctl show \
      systemd-suspend-then-hibernate.service systemd-hibernate.service \
      --no-pager \
      --property=Id,LoadState,ActiveState,SubState,Result,ExecMainCode,ExecMainStatus,StatusText,InvocationID
    ${pkgs.systemd}/bin/journalctl \
      --boot --dmesg --no-pager --output=short-monotonic --lines=300
    echo "sleep-failure: diagnostics end: action=$failed_action"
  '';
in
{
  imports = [
    "${nixos-hardware}/framework/13-inch/7040-amd"
    ./hardware-configuration.nix
    ../../modules/core.nix
    ../../modules/oom-mitigations.nix
    ../../modules/restic-backup.nix
    ./debug-ttm-kernel.nix # adds a "debug-ttm" boot entry (KASAN/lockdep/kunit) for drm/amd #5387

  ];

  networking.hostName = "tropical-turnip";

  # Use latest kernel for amdgpu/RDNA 3 MES fixes (6.12 had recurring GPU resets)
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # See https://wiki.archlinux.org/title/Network_configuration/Wireless#mt7921
  boot.extraModprobeConfig = ''
    options mt7921e disable_aspm=1
  '';

  # Cap how many generations get kernels+initrds on the 511M ESP. Without this,
  # every generation accumulates until /boot fills and bootloader install fails
  # with ENOSPC. The debug-ttm specialisation adds a SECOND (KASAN)
  # kernel+initrd per generation (~150 MB/generation total), so the ESP only
  # holds ~3 while it is enabled. Bump this back to ~8-10 after removing the
  # debug-ttm specialisation.
  boot.loader.systemd-boot.configurationLimit = 3;

  ### Hibernation, swap, and power management

  # Create a 36GB swap file for hibernation (system has 32GB RAM)
  swapDevices = [
    {
      device = "/var/lib/swapfile";
      size = 36 * 1024; # 36GB in MB
    }
  ];

  # Enable hibernation support - specify swap file location and offset
  # NOTE: If you change the swap size, you MUST update resume_offset:
  #   1. Run: sudo filefrag -v /var/lib/swapfile | head -10
  #   2. Use the first physical_offset value (currently 8665088)
  #   3. Update resume_offset below and rebuild
  boot.resumeDevice = "/dev/disk/by-uuid/9af0faf1-75d0-43c3-ba88-b697ddf73c4d";
  boot.kernelParams = [
    "resume_offset=8665088"
    # Hibernation debugging: log each driver's suspend/resume callback so the
    # last device touched before a hang is identifiable in dmesg.
    "pm_debug_messages"
    "no_console_suspend"
    # Crash capture for the intermittent hibernation hang: reserve 2M of RAM
    # for ramoops. On panic the kernel memcpys the tail of dmesg there (works
    # even with the I/O stack suspended); contents survive the warm reboot
    # triggered by kernel.panic below and appear in /sys/fs/pstore, which
    # systemd-pstore archives to /var/lib/systemd/pstore. A cold boot (battery
    # death / forced power-off) loses the buffer, but the panic sysctls below
    # should reboot the machine long before the battery drains.
    "reserve_mem=2M:4096:ramoops"
    "ramoops.mem_name=ramoops"
    "ramoops.record_size=0x20000" # 128K per panic record
    "ramoops.max_reason=2" # capture on oops and panic
    "pstore.kmsg_bytes=0x20000" # snapshot 128K of dmesg, not the 10K default
    # Only one pstore backend can register. efi_pstore is built into the kernel
    # and otherwise claims pstore before the ramoops module can use reserved RAM.
    "efi_pstore.pstore_disable=1"
  ];

  # Load ramoops in the initrd so it registers before normal userspace and
  # exposes any crash record left in reserved RAM by the previous boot.
  boot.initrd.kernelModules = [ "ramoops" ];

  # Turn a hibernation hang into a panic (captured by ramoops) followed by a
  # warm reboot, instead of an 11-hour battery drain with no logs. A stuck
  # device-suspend callback parks the sleep task in D-state, which the hung
  # task detector catches after 120s (kernel default); softlockup/hardlockup
  # cover the with-interrupts-off variants.
  boot.kernel.sysctl = {
    "kernel.panic_on_oops" = 1;
    "kernel.hung_task_panic" = 1;
    "kernel.softlockup_panic" = 1;
    "kernel.hardlockup_panic" = 1;
    "kernel.panic" = 10; # reboot 10s after panic
  };

  # Serialize device suspend/resume so the pm_debug_messages trace is
  # sequential: the last callback logged before a hang is the culprit. With
  # async suspend (default), many devices suspend concurrently and log order
  # proves nothing. Costs a few hundred ms per suspend.
  systemd.tmpfiles.rules = [
    "w /sys/power/pm_async - - - - 0"
    # pm_trace uses the RTC for fingerprints and conflicts with the wake alarm
    # needed by suspend-then-hibernate. Enable it only for controlled tests.
    "w /sys/power/pm_trace - - - - 0"
  ];

  # Power management - prevent file system corruption from sudden battery death
  # When battery hits 5%, the system will hibernate (save RAM to disk)
  services.upower = {
    enable = true;
    percentageLow = 15; # Warn at 15%
    percentageCritical = 5; # Critical at 5%
    percentageAction = 5; # Take action at 5%
    # NOTE: This will attempt hibernate even if there's a kernel mismatch (unlike
    # smart-suspend which falls back to plain suspend). At 5% battery, a failed
    # hibernate resume on next boot is preferable to losing everything.
    criticalPowerAction = "Hibernate";
  };

  # Enable verbose UPower logging to diagnose battery action failures
  systemd.services.upower.environment.G_MESSAGES_DEBUG = "all";

  systemd.sleep.settings.Sleep = {
    # Stay suspended for 30 minutes before writing the hibernation image.
    HibernateDelaySec = "30m";
    # Power off directly after writing the image. The default "platform" mode
    # asks ACPI firmware to enter S4, which is an extra failure point after the
    # image is already safely on disk.
    HibernateMode = "shutdown";
  };

  # `systemctl suspend-then-hibernate` only enqueues the sleep request, so the
  # user-session caller cannot observe a later systemd-sleep failure. Capture
  # it on the system unit itself and then make one direct hibernation attempt.
  systemd.services."systemd-suspend-then-hibernate".onFailure = [
    "hibernate-fallback.service"
  ];

  systemd.services.hibernate-fallback = {
    description = "Capture suspend-then-hibernate failure and fall back to hibernation";
    serviceConfig.Type = "oneshot";
    script = ''
      ${sleepFailureDiagnostics} suspend-then-hibernate
      for delay in 2 5 10; do
        echo "sleep-failure: requesting hibernate fallback after ''${delay}s"
        ${pkgs.coreutils}/bin/sleep "$delay"
        if ${pkgs.systemd}/bin/systemctl hibernate; then
          echo "sleep-failure: hibernate fallback enqueued"
          exit 0
        fi
      done
      echo "sleep-failure: unable to enqueue hibernate fallback"
      exit 1
    '';
  };

  # If the fallback itself returns a regular failure, preserve the same
  # diagnostics. A kernel hang cannot run OnFailure; panic/watchdog capture is
  # responsible for that case.
  systemd.services."systemd-hibernate".onFailure = [
    "hibernate-failure-diagnostics.service"
  ];

  systemd.services.hibernate-failure-diagnostics = {
    description = "Capture hibernation failure diagnostics";
    serviceConfig.Type = "oneshot";
    script = ''
      ${sleepFailureDiagnostics} hibernate
    '';
  };

  # Ignore lid switch events and let swayidle's smart-suspend handle suspension.
  # This allows smart-suspend to check power state and audio activity before suspending.
  # Behavior: closing lid on AC power won't suspend, closing on battery will suspend
  # after swayidle's 5-minute inactivity timeout (unless audio is active).
  services.logind.settings.Login.HandleLidSwitch = "ignore";

  # Turn internal screen off/on when lid is closed/opened. This is separate from
  # suspend handling (which is done by swayidle's smart-suspend based on idle time).
  # Only affects eDP-1 (internal display), so external monitors remain on. When
  # closing the lid undocked, pause MPRIS media players in the user session.
  services.acpid = {
    enable = true;
    logEvents = true;
    lidEventCommands = ''
      log_lid_event() {
        ${pkgs.util-linux}/bin/logger -t lid-event -- "$*"
      }

      user_uid=$(${pkgs.coreutils}/bin/id -u skainswo)
      export XDG_RUNTIME_DIR=/run/user/$user_uid
      export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus

      log_lid_event "start: raw_event='$1' user_uid=$user_uid xdg_runtime_dir=$XDG_RUNTIME_DIR dbus_session_bus_address=$DBUS_SESSION_BUS_ADDRESS pid=$$"

      external_display_connected=false
      drm_summary=""
      for status in /sys/class/drm/card*-*/status; do
        if [ ! -e "$status" ]; then continue; fi

        connector=$(${pkgs.coreutils}/bin/basename "$(${pkgs.coreutils}/bin/dirname "$status")")
        connector_status=$(${pkgs.coreutils}/bin/cat "$status" 2>/dev/null || true)
        drm_summary="$drm_summary $connector:$connector_status"

        case "$connector" in
          *-eDP-*|*-LVDS-*|*-DSI-*) continue ;;
        esac

        if [ "$connector_status" = connected ]; then
          external_display_connected=true
          break
        fi
      done
      log_lid_event "drm: external_display_connected=$external_display_connected connectors='$drm_summary'"

      run_user_playerctl() {
        if [ "$(${pkgs.coreutils}/bin/id -u)" = "$user_uid" ]; then
          ${pkgs.coreutils}/bin/env \
            XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
            DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
            ${pkgs.playerctl}/bin/playerctl "$@"
        else
          ${pkgs.util-linux}/bin/runuser -u skainswo -- \
            ${pkgs.coreutils}/bin/env \
              XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
              DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
              ${pkgs.playerctl}/bin/playerctl "$@"
        fi
      }

      pause_media_if_undocked() {
        if [ "$external_display_connected" = true ]; then
          log_lid_event "media: skip pause because external display is connected"
          return
        fi

        players=$(run_user_playerctl -l 2>&1 | ${pkgs.coreutils}/bin/tr '\n' ';')
        status_before=$(run_user_playerctl -a status 2>&1 | ${pkgs.coreutils}/bin/tr '\n' ';')
        run_user_playerctl -a pause >/dev/null 2>&1
        pause_rc=$?
        status_after=$(run_user_playerctl -a status 2>&1 | ${pkgs.coreutils}/bin/tr '\n' ';')

        log_lid_event "media: players='$players' before='$status_before' pause_rc=$pause_rc after='$status_after'"
        return 0
      }

      lid_action() {
        for state in /proc/acpi/button/lid/*/state; do
          if [ ! -e "$state" ]; then continue; fi

          state_value=$(${pkgs.coreutils}/bin/cat "$state" 2>/dev/null || true)
          log_lid_event "lid-state: source=$state value='$state_value'"
          case "$state_value" in
            *closed*) echo close; return ;;
            *open*) echo open; return ;;
          esac
        done

        # Event is passed as a single string, commonly "button/lid LID0 close",
        # but some firmware reports numeric payloads instead.
        case "$1" in
          *closed*|*close*)
            log_lid_event "lid-state: fallback raw_event='$1' action=close"
            echo close
            ;;
          *open*)
            log_lid_event "lid-state: fallback raw_event='$1' action=open"
            echo open
            ;;
          *)
            log_lid_event "lid-state: fallback raw_event='$1' action=unknown"
            echo unknown
            ;;
        esac
      }

      action=$(lid_action "$1")
      # Find niri socket dynamically (includes PID which changes on restart)
      export NIRI_SOCKET=$(${pkgs.findutils}/bin/find "$XDG_RUNTIME_DIR" -maxdepth 1 -name "niri.*.sock" -print -quit 2>/dev/null)
      log_lid_event "decision: action=$action niri_socket='$NIRI_SOCKET'"

      case "$action" in
        close)
          pause_media_if_undocked
          if [ -n "$NIRI_SOCKET" ]; then
            niri_output=$(${pkgs.niri}/bin/niri msg output eDP-1 off 2>&1 | ${pkgs.coreutils}/bin/tr '\n' ';')
            niri_rc=$?
            log_lid_event "niri: output=eDP-1 off rc=$niri_rc output='$niri_output'"
          else
            log_lid_event "niri: skip output=eDP-1 off because niri socket was not found"
          fi
          ;;
        open)
          if [ -n "$NIRI_SOCKET" ]; then
            niri_output=$(${pkgs.niri}/bin/niri msg output eDP-1 on 2>&1 | ${pkgs.coreutils}/bin/tr '\n' ';')
            niri_rc=$?
            log_lid_event "niri: output=eDP-1 on rc=$niri_rc output='$niri_output'"
          else
            log_lid_event "niri: skip output=eDP-1 on because niri socket was not found"
          fi
          ;;
        *)
          log_lid_event "decision: no action for raw_event='$1'"
          ;;
      esac

      log_lid_event "done: action=$action"
    '';
  };

  services.resticBackup.enable = true;

  # swayidle with smart-suspend for idle suspension
  home-manager.users.skainswo =
    { pkgs, ... }:
    let
      smart-suspend = writeLean "smart-suspend" {
        makeWrapperArgs = [
          "--prefix"
          "PATH"
          ":"
          (pkgs.lib.makeBinPath [
            pkgs.coreutils
            pkgs.procps
            pkgs.pulseaudio
            pkgs.systemd
          ])
        ];
      } ./smart-suspend.lean;
    in
    {
      # Link smart-suspend for manual debugging. Note that this is not in PATH.
      home.file.".local/bin/smart-suspend".source = smart-suspend;

      services.swayidle = {
        enable = true;
        # Drop the default "-w" so swayidle doesn't block resume callbacks
        # while a timeout command is still running. "smart-suspend arm" loops
        # until it suspends, so with -w swayidle could never deliver disarm
        # mid-wait — the user would stay armed even while actively using the
        # machine.
        extraArgs = [ ];
        timeouts = [
          {
            timeout = 3 * 60;
            command = "${pkgs.niri}/bin/niri msg action power-off-monitors";
          }

          {
            timeout = 5 * 60;
            # Stay armed while the session remains idle so unplugging AC after
            # the initial timeout still suspends an already-idle session.
            command = "${smart-suspend} arm";
            resumeCommand = "${smart-suspend} disarm";
          }
        ];
      };
    };
}
