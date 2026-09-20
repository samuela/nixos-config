{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.resumeDiagnostics;
  tool = pkgs.writeShellApplication {
    name = "resume-diagnostics";
    runtimeInputs = with pkgs; [
      bash
      coreutils
      findutils
      gnugrep
      gawk
      util-linux
      systemd
    ];
    text = builtins.readFile ./resume-diagnostics.sh;
  };
in
{
  options.services.resumeDiagnostics.enable = lib.mkEnableOption ''
    bounded sleep tracing and GPIO/IRQ snapshots for the Framework 13 AMD
    PIXA3854 touchpad (no automatic recovery or raw input recording)
  '';

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ tool ];

    # Keep captures readable to wheel for local investigation, not other users.
    systemd.tmpfiles.rules = [ "d /var/lib/resume-diagnostics 2750 root wheel -" ];

    # A dedicated before-sleep unit avoids user-session hooks (user.slice may
    # be frozen) and the ambiguous shutdown semantics of powerDownCommands.
    # ExecStop runs when sleep.target is released after the sleep operation.
    systemd.services.resume-diagnostics-sleep = {
      description = "Capture sleep/resume PM trace and GPIO/IRQ state";
      wantedBy = [ "sleep.target" ];
      before = [ "sleep.target" ];
      wants = [
        "sys-kernel-debug.mount"
        "sys-kernel-tracing.mount"
      ];
      after = [
        "sys-kernel-debug.mount"
        "sys-kernel-tracing.mount"
      ];
      unitConfig.StopWhenUnneeded = true;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Diagnostic failure must not prevent sleep or strand the sleep target.
        ExecStart = "-${tool}/bin/resume-diagnostics prepare";
        ExecStop = [
          "-${tool}/bin/resume-diagnostics resume"
          "-${pkgs.systemd}/bin/systemctl --no-block restart resume-diagnostics-settled.service"
        ];
        TimeoutStartSec = "45s";
        TimeoutStopSec = "45s";
      };
    };

    systemd.services.resume-diagnostics-settled = {
      description = "Capture device/session state after resume has settled";
      serviceConfig = {
        Type = "oneshot";
        ExecStartPre = "${pkgs.coreutils}/bin/sleep 5";
        ExecStart = "${tool}/bin/resume-diagnostics settled";
        TimeoutStartSec = "45s";
      };
    };
  };
}
