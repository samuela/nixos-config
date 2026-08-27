import Lean

open System

def log (msg : String) : IO Unit :=
  IO.eprintln msg

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

/--
Whether the firmware reports the laptop lid as closed.

An unknown lid state deliberately returns `none`: callers must not apply the
closed-lid policy unless they can positively identify a closed lid.
-/
def lidClosed? : IO (Option Bool) := do
  let root := FilePath.mk "/proc/acpi/button/lid"
  try
    for entry in ← root.readDir do
      match ← readTrimLower? (entry.path / "state") with
      | some state =>
          if state.endsWith "closed" then
            return some true
          if state.endsWith "open" then
            return some false
      | none => pure ()
    return none
  catch _ =>
    return none

def isInternalDisplayConnector (name : String) : Bool :=
  let parts := name.splitOn "-"
  parts.contains "edp" || parts.contains "lvds" || parts.contains "dsi"

/--
Whether DRM reports a connected external display.

Like `lidClosed?`, failure returns `none`. The undocked override is intentionally
fail-safe: missing or unreadable DRM state preserves the normal blocker policy.
-/
def externalDisplayConnected? : IO (Option Bool) := do
  let root := FilePath.mk "/sys/class/drm"
  try
    let mut sawConnector := false
    for entry in ← root.readDir do
      let connector := entry.fileName.map Char.toLower
      let statusPath := entry.path / "status"
      if ← statusPath.pathExists then
        sawConnector := true
        match ← readTrimLower? statusPath with
        | some "connected" =>
            if !isInternalDisplayConnector connector then
              return some true
        | some _ => pure ()
        | none => return none
    if sawConnector then return some false else return none
  catch _ =>
    return none

def closedAndUndocked : IO Bool := do
  match ← lidClosed?, ← externalDisplayConnected? with
  | some true, some false => return true
  | _, _ => return false

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

/--
Names of the sinks or sources currently in state RUNNING.

`pactl list <kind> short` is tab separated and ends with the state, which parses
far more reliably than grepping the long form for "State: RUNNING". If pactl
fails the output is empty and nothing is reported as running, so a broken pactl
lets the machine sleep rather than pinning it awake.
-/
def runningDevices (kind : String) : IO (List String) := do
  let out ← run "pactl" #["list", kind, "short"]
  let mut names := []
  for line in out.stdout.splitOn "\n" do
    let fields := (line.splitOn "\t").map (·.toSlice.trimAscii.copy)
    match fields with
    | _index :: name :: _rest =>
        if fields.getLast? == some "RUNNING" then
          names := names ++ [name]
    | _ => pure ()
  return names

/--
Application names holding streams, e.g. for kind "sink-inputs".

Purely diagnostic. A sink being RUNNING is not actionable on its own: RUNNING
means some client holds an open, uncorked stream, which is not the same as audio
being audible. Naming the client is the difference between "audio sink running"
appearing 221 times with no way to act on it and knowing which process to fix.
-/
def streamApplications (kind : String) : IO (List String) := do
  let out ← run "pactl" #["list", kind]
  let mut apps := []
  for line in out.stdout.splitOn "\n" do
    let line := line.toSlice.trimAscii.copy
    if line.startsWith "application.name = " then
      let value := (line.drop "application.name = ".length).replace "\"" ""
      if !(apps.contains value) then
        apps := apps ++ [value]
  return apps

def describeAudioBlocker (label : String) (devices apps : List String) : String :=
  let devicesText := String.intercalate ", " devices
  -- "streams: none" is itself a useful signal: a device running with nothing
  -- attached points at PipeWire rather than at any application.
  let appsText := if apps.isEmpty then "none" else String.intercalate ", " apps
  s!"{label}: {devicesText} (streams: {appsText})"

def audioBlocker? : IO (Option String) := do
  let sinks ← runningDevices "sinks"
  if !sinks.isEmpty then
    return some (describeAudioBlocker "audio sink running" sinks (← streamApplications "sink-inputs"))
  let sources ← runningDevices "sources"
  if !sources.isEmpty then
    return some (describeAudioBlocker "audio source running" sources (← streamApplications "source-outputs"))
  return none

def isOnlinePowerSupply (entry : IO.FS.DirEntry) : IO Bool := do
  let onlinePath := entry.path / "online"
  return (← readTrimLower? onlinePath) == some "1"

def onlinePowerSupplies : IO (List String) := do
  let entries := (← (FilePath.mk "/sys/class/power_supply").readDir).toList
  let online ← entries.filterM isOnlinePowerSupply
  return online.map (·.fileName)

/--
Battery percentage at or below which every overridable blocker is ignored and
the machine sleeps regardless.

Hibernation on this host writes an ~11 GB image and measures 3-4 minutes end to
end, so the floor has to leave real runtime rather than a token amount. See
issues #6 and #7: a latched audio sink deferred sleep until the battery was
flat, and the emergency hibernation UPower fired at 2% never finished writing
its image.
-/
def batteryFloorPercent : Nat := 20

/--
Consecutive 60-second deferrals tolerated for an overridable blocker before
sleeping anyway. This bounds the damage from any blocker that latches on and
never clears, independently of whether the battery reading is trustworthy. The
gauge on this host is known to over-report near empty, so the floor above cannot
be the only protection.
-/
def maxConsecutiveDeferrals : Nat := 120

def batteryPercent? : IO (Option Nat) := do
  match ← readTrimLower? "/sys/class/power_supply/BAT1/capacity" with
  | none => return none
  | some raw => return raw.toNat?

/--
Why sleep is being deferred.

For open-lid and docked sessions, external power is deliberately never
overridden: while plugged in the battery is not at risk and staying awake is the
intended behaviour. The closed-and-undocked policy is applied before blockers
are constructed. Every other blocker is overridable by the battery floor or the
deferral cap.
-/
inductive Blocker where
  | externalPower (supplies : String)
  | overridable (reason : String)

def blocker? : IO (Option Blocker) := do
  if ← closedAndUndocked then
    log "eligibility checks passed: lid closed and no external display; ignoring power and audio blockers"
    return none
  let onlineSupplies ← onlinePowerSupplies
  if !onlineSupplies.isEmpty then
    return some (.externalPower (String.intercalate ", " onlineSupplies))
  let battery ← readTrimLower? "/sys/class/power_supply/BAT1/status"
  if battery != some "discharging" then
    return some (.overridable s!"battery state: {battery.getD "unknown"}")
  match ← audioBlocker? with
  | some reason => return some (.overridable reason)
  | none =>
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

partial def waitLoop (deferrals : Nat) : IO UInt32 := do
  match ← blocker? with
  | none => suspendNow
  | some (.externalPower supplies) =>
      -- Not counted as a deferral. Staying awake on AC is the intended steady
      -- state and can legitimately last for days, so it must never accumulate
      -- toward the cap.
      log s!"waiting: external power online: {supplies}"
      IO.sleep 60000
      waitLoop 0
  | some (.overridable reason) =>
      let percent? ← batteryPercent?
      let percentText := match percent? with
        | some percent => s!"{percent}%"
        | none => "unknown"
      let belowFloor : Bool := match percent? with
        | some percent => percent <= batteryFloorPercent
        | none => false
      let deferrals := deferrals + 1
      if belowFloor then
        log s!"override: battery {percentText} at or below floor {batteryFloorPercent}%; sleeping despite blocker: {reason}"
        suspendNow
      else if deferrals >= maxConsecutiveDeferrals then
        log s!"override: blocker '{reason}' deferred {deferrals} consecutive checks (cap {maxConsecutiveDeferrals}); sleeping anyway"
        suspendNow
      else
        log s!"waiting: {reason} (deferral {deferrals}/{maxConsecutiveDeferrals}; battery {percentText})"
        IO.sleep 60000
        waitLoop deferrals

def runArm : IO UInt32 := do
  IO.FS.createDirAll (← stateDir)

  if let some pid ← readPid? then
    if ← pidAlive pid then
      log "already armed"
      return 0

  IO.FS.writeFile (← pidFile) s!"{← IO.Process.getPID}"

  try
    log "armed"
    waitLoop 0
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
