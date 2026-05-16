import Lean

open System

def log (msg : String) : IO Unit :=
  IO.eprintln msg

def containsText (s needle : String) : Bool :=
  match s.splitOn needle with
  | _ :: _ :: _ => true
  | _ => false

def trimLower (s : String) : String :=
  s.trim.map Char.toLower

def run (cmd : String) (args : Array String) : IO IO.Process.Output :=
  IO.Process.output { cmd, args }

def stateDir : IO FilePath := do
  let some dir ← IO.getEnv "XDG_RUNTIME_DIR" | panic! "XDG_RUNTIME_DIR is not set"
  return FilePath.mk dir / "smart-suspend"

def pidFile : IO FilePath := do
  return (← stateDir) / "armed.pid"

def hasRunningStream (kind : String) : IO Bool := do
  let out ← run "pactl" #["list", kind]
  return containsText out.stdout "State: RUNNING"

def blocker? : IO (Option String) := do
  let battery := trimLower (← IO.FS.readFile "/sys/class/power_supply/BAT1/status")
  if battery != "discharging" then
    return some s!"battery state: {battery}"
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

  let stderr := out.stderr.trim
  let msg :=
    if stderr.isEmpty then
      s!"systemctl {action} failed with exit code {out.exitCode}"
    else
      s!"systemctl {action} failed with exit code {out.exitCode}: {stderr}"
  throw <| IO.userError msg

def readPid? : IO (Option String) := do
  let path ← pidFile
  if ← path.pathExists then
    return some (← IO.FS.readFile path).trim
  else
    return none

def pidAlive (pid : String) : IO Bool := do
  let pid := pid.trim
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
      suspendNow

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
  if let some pid ← readPid? then
    discard <| run "kill" #["-TERM", pid]
  removePidFile
  return 0

def main (args : List String) : IO UInt32 := do
  match args with
  | ["arm"] => runArm
  | ["disarm"] => runDisarm
  | _ =>
      log "usage: smart-suspend [arm|disarm]"
      return 64
