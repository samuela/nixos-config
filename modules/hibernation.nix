# Shared policy for systemd sleep, critical-battery handling, and smart-suspend.
{ config, lib, ... }:
let
  cfg = config.powerManagement.hibernation;
in
{
  options.powerManagement.hibernation.enable = lib.mkEnableOption ''
    hibernation, hybrid sleep, and suspend-then-hibernate
  '';

  config = {
    systemd.sleep.settings.Sleep = {
      AllowHibernation = cfg.enable;
      AllowHybridSleep = cfg.enable;
      AllowSuspendThenHibernate = cfg.enable;
    };

    # Read at the moment of sleep, not when the idle helper starts. This also
    # updates an already-running smart-suspend wait after a configuration switch.
    environment.etc."hibernation-enabled".text = if cfg.enable then "yes\n" else "no\n";

    # Never substitute suspend at critical battery: it keeps draining power.
    # PowerOff loses the session but shuts down cleanly rather than exhausting
    # the battery. Swap/resume configuration remains available for re-enabling.
    services.upower.criticalPowerAction = if cfg.enable then "Hibernate" else "PowerOff";
  };
}
