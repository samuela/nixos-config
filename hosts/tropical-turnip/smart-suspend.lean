import Lean

open System

def log (msg : String) : IO Unit :=
  IO.eprintln msg

def containsText (s needle : String) : Bool :=
  match s.splitOn needle with
  | _ :: _ :: _ => true
  | _ => false

def run (cmd : String) (args : Array String) : IO IO.Process.Output :=
  IO.Process.output { cmd, args }

def logText (label text : String) : IO Unit := do
  let text := text.toSlice.trimAscii.copy
  if text.isEmpty then
    log s!"{label}: <empty>"
  else
    for line in text.splitOn "\n" do
      log s!"{label}: {line}"

def logProcessOutput
    (label cmd : String)
    (args : Array String)
    (out : IO.Process.Output) : IO Unit := do
  let command := String.intercalate " " (cmd :: args.toList)
  log s!"{label}: command={command}; exit_code={out.exitCode}"
  logText s!"{label}.stdout" out.stdout
  logText s!"{label}.stderr" out.stderr

def runDiagnosticCommand
    (label cmd : String)
    (args : Array String) : IO Unit := do
  try
    logProcessOutput label cmd args (← run cmd args)
  catch e =>
    log s!"{label}: unable to run command: {e}"

def logFile (path : FilePath) : IO Unit := do
  try
    logText s!"diagnostic.file.{path}" (← IO.FS.readFile path)
  catch e =>
    log s!"diagnostic.file.{path}: unable to read: {e}"

def logFileIfExists (path : FilePath) : IO Unit := do
  if ← path.pathExists then
    logFile path

def logPowerSupplies : IO Unit := do
  let root := FilePath.mk "/sys/class/power_supply"
  let fields := #[
    "type", "status", "online", "capacity", "capacity_level",
    "energy_now", "energy_full", "energy_full_design", "power_now",
    "charge_now", "charge_full", "charge_full_design", "current_now",
    "voltage_now"
  ]
  try
    for entry in ← root.readDir do
      for field in fields do
        logFileIfExists (entry.path / field)
  catch e =>
    log s!"diagnostic.power_supply: unable to enumerate: {e}"

def collectFailureDiagnostics (failedAction : String) : IO Unit := do
  log s!"diagnostics.begin: failed_action={failedAction}"

  let files := #[
    "/proc/cmdline",
    "/proc/sys/kernel/tainted",
    "/sys/power/state",
    "/sys/power/mem_sleep",
    "/sys/power/disk",
    "/sys/power/pm_async",
    "/sys/power/pm_trace",
    "/sys/power/wakeup_count",
    "/sys/power/suspend_stats/success",
    "/sys/power/suspend_stats/fail",
    "/sys/power/suspend_stats/failed_freeze",
    "/sys/power/suspend_stats/failed_prepare",
    "/sys/power/suspend_stats/failed_suspend",
    "/sys/power/suspend_stats/failed_suspend_late",
    "/sys/power/suspend_stats/failed_suspend_noirq",
    "/sys/power/suspend_stats/failed_resume",
    "/sys/power/suspend_stats/failed_resume_early",
    "/sys/power/suspend_stats/failed_resume_noirq",
    "/sys/power/suspend_stats/last_failed_dev",
    "/sys/power/suspend_stats/last_failed_errno",
    "/sys/power/suspend_stats/last_failed_step",
    "/sys/power/suspend_stats/last_hw_sleep",
    "/sys/power/suspend_stats/total_hw_sleep"
  ]
  for path in files do
    logFileIfExists path
  logPowerSupplies

  runDiagnosticCommand "diagnostic.uname" "uname" #["-a"]
  runDiagnosticCommand "diagnostic.sleep-unit-state" "systemctl" #[
    "show",
    "systemd-suspend-then-hibernate.service",
    "systemd-hibernate.service",
    "--no-pager",
    "--property=Id,LoadState,ActiveState,SubState,Result,ExecMainCode,ExecMainStatus,StatusText,InvocationID"
  ]
  runDiagnosticCommand "diagnostic.sleep-unit-status" "systemctl" #[
    "status",
    "systemd-suspend-then-hibernate.service",
    "systemd-hibernate.service",
    "--no-pager",
    "--full"
  ]
  runDiagnosticCommand "diagnostic.sleep-unit-journal" "journalctl" #[
    "--boot",
    "--no-pager",
    "--output=short-monotonic",
    "--lines=150",
    "--unit=systemd-suspend-then-hibernate.service",
    "--unit=systemd-hibernate.service"
  ]
  runDiagnosticCommand "diagnostic.kernel-journal" "journalctl" #[
    "--boot",
    "--dmesg",
    "--no-pager",
    "--output=short-monotonic",
    "--lines=250"
  ]
  runDiagnosticCommand "diagnostic.sleep-inhibitors" "systemd-inhibit" #[
    "--list",
    "--no-pager"
  ]

  log s!"diagnostics.end: failed_action={failedAction}"

def readTrimLower? (path : FilePath) : IO (Option String) := do
  try
    return some ((← IO.FS.readFile path).toSlice.trimAscii.copy.map Char.toLower)
  catch _ =>
    return none

def stateDir : IO FilePath := do
  let some dir ← IO.getEnv "XDG_RUNTIME_DIR" | panic! "XDG_RUNTIME_DIR is not set"
  return FilePath.mk dir / "smart-suspend"

def pidFile : IO FilePath := do
  return (← stateDir) / "armed.pid"

def removePidFile : IO Unit := do
  let path ← pidFile
  try
    IO.FS.removeFile path
  catch _ =>
    pure ()

def hasRunningStream (kind : String) : IO Bool := do
  let out ← run "pactl" #["list", kind]
  return containsText out.stdout "State: RUNNING"

def isOnlinePowerSupply (entry : IO.FS.DirEntry) : IO Bool := do
  let onlinePath := entry.path / "online"
  return (← readTrimLower? onlinePath) == some "1"

def onlinePowerSupplies : IO (List String) := do
  let entries := (← (FilePath.mk "/sys/class/power_supply").readDir).toList
  let online ← entries.filterM isOnlinePowerSupply
  return online.map (·.fileName)

def blocker? : IO (Option String) := do
  let onlineSupplies ← onlinePowerSupplies
  if !onlineSupplies.isEmpty then
    return some s!"external power online: {String.intercalate ", " onlineSupplies}"
  let battery ← readTrimLower? "/sys/class/power_supply/BAT1/status"
  if battery != some "discharging" then
    return some s!"battery state: {battery.getD "unknown"}"
  else if ← hasRunningStream "sinks" then
    return some "audio sink running"
  else if ← hasRunningStream "sources" then
    return some "audio source running"
  else
    log "eligibility checks passed: no external power; battery discharging; no active audio"
    return none

def suspendCommand : IO String := do
  let booted ← IO.FS.realPath "/run/booted-system/kernel"
  let current ← IO.FS.realPath "/run/current-system/kernel"
  if booted == current then
    log s!"kernel state: booted={booted}; current={current}; kernels match"
    return "suspend-then-hibernate"
  else
    log s!"kernel mismatch: booted={booted} current={current}; using suspend"
    return "suspend"

def suspendNow : IO UInt32 := do
  let action ← suspendCommand
  -- The resume callback should cancel blocker waits, but must not kill this
  -- process while it is diagnosing a failed sleep or starting the fallback.
  removePidFile
  log "sleep attempt committed: cleared armed PID before invoking systemctl"
  log s!"suspending now with {action}"
  log "sleep.preflight-power-snapshot.begin"
  logPowerSupplies
  log "sleep.preflight-power-snapshot.end"

  let out ← run "systemctl" #[action]
  logProcessOutput s!"sleep.{action}" "systemctl" #[action] out
  if out.exitCode == 0 then
    log s!"sleep request enqueued: action={action}; completion is reported by the system sleep unit"
    return 0

  log s!"sleep action failed: action={action}; exit_code={out.exitCode}"
  collectFailureDiagnostics action

  if action != "suspend-then-hibernate" then
    return out.exitCode

  log "fallback.begin: suspend-then-hibernate failed; requesting hibernate"
  let fallback ← run "systemctl" #["hibernate"]
  logProcessOutput "fallback.hibernate" "systemctl" #["hibernate"] fallback
  if fallback.exitCode == 0 then
    log "fallback.enqueued: hibernate request accepted"
    return 0

  log s!"fallback.failure: hibernate failed; exit_code={fallback.exitCode}"
  collectFailureDiagnostics "hibernate-fallback"
  return fallback.exitCode

def readPid? : IO (Option String) := do
  let path ← pidFile
  if ← path.pathExists then
    return some (← IO.FS.readFile path).toSlice.trimAscii.copy
  else
    return none

def pidAlive (pid : String) : IO Bool := do
  let pid := pid.toSlice.trimAscii.copy
  if pid.isEmpty then
    return false
  else
    return (← (FilePath.mk s!"/proc/{pid}").pathExists)

partial def waitLoop : IO UInt32 := do
  match ← blocker? with
  | some reason =>
      log s!"waiting: {reason}"
      IO.sleep 60000
      waitLoop
  | none => suspendNow

def runArm : IO UInt32 := do
  IO.FS.createDirAll (← stateDir)

  if let some pid ← readPid? then
    if ← pidAlive pid then
      log "already armed"
      return 0

  IO.FS.writeFile (← pidFile) s!"{← IO.Process.getPID}"

  try
    log "armed"
    waitLoop
  finally
    removePidFile

def runDisarm : IO UInt32 := do
  match ← readPid? with
  | some pid =>
      log s!"disarming pid {pid}"
      discard <| run "kill" #["-TERM", pid]
  | none =>
      log "disarm called but not armed"
  removePidFile
  return 0

def main (args : List String) : IO UInt32 := do
  match args with
  | ["arm"] => runArm
  | ["disarm"] => runDisarm
  | _ =>
      log "usage: smart-suspend [arm|disarm]"
      return 64
