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
    return none

def suspendCommand : IO String := do
  let booted ← IO.FS.realPath "/run/booted-system/kernel"
  let current ← IO.FS.realPath "/run/current-system/kernel"
  if booted == current then
    return "suspend-then-hibernate"
  else
    log s!"kernel mismatch: booted={booted} current={current}; using suspend"
    return "suspend"

def suspendNow : IO UInt32 := do
  let action ← suspendCommand
  log s!"suspending now with {action}"

  let out ← run "systemctl" #[action]
  if out.exitCode == 0 then
    return 0

  let stderr := out.stderr.toSlice.trimAscii.copy
  let msg :=
    if stderr.isEmpty then
      s!"systemctl {action} failed with exit code {out.exitCode}"
    else
      s!"systemctl {action} failed with exit code {out.exitCode}: {stderr}"
  throw <| IO.userError msg

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

def removePidFile : IO Unit := do
  let path ← pidFile
  try
    IO.FS.removeFile path
  catch _ =>
    pure ()

partial def waitLoop : IO UInt32 := do
  match ← blocker? with
  | some reason =>
      log s!"waiting: {reason}"
      IO.sleep 60000
      waitLoop
  | none =>
      -- Grace period: re-check after 60s before actually suspending. This
      -- avoids a race where a blocker disappears (e.g. AC unplugged on
      -- undock) immediately before the user generates input — swayidle's
      -- resume command needs a moment to fire and kill us.
      log "no blocker; re-checking in 60s before suspending"
      IO.sleep 60000
      match ← blocker? with
      | some reason =>
          log s!"blocker returned during grace: {reason}"
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
