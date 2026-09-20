# Run: nix-instantiate --eval --strict tests/hibernation.nix
let
  nixpkgs = import ../nix/pinned-nixpkgs-path.nix;
  system = import (nixpkgs + "/nixos/lib/eval-config.nix") {
    modules = [ ../hosts/tropical-turnip/configuration.nix ];
  };
  enabled = system.extendModules {
    modules = [
      (
        { lib, ... }:
        {
          powerManagement.hibernation.enable = lib.mkForce true;
        }
      )
    ];
  };
  check =
    expected: evaluated:
    let
      c = evaluated.config;
      sleep = c.systemd.sleep.settings.Sleep;
    in
    assert c.powerManagement.hibernation.enable == expected;
    assert sleep.AllowHibernation == expected;
    assert sleep.AllowHybridSleep == expected;
    assert sleep.AllowSuspendThenHibernate == expected;
    assert c.services.upower.criticalPowerAction == (if expected then "Hibernate" else "PowerOff");
    assert c.environment.etc."hibernation-enabled".text == (if expected then "yes\n" else "no\n");
    assert (c.systemd.services ? hibernate-fallback) == expected;
    assert (c.systemd.services ? hibernate-failure-diagnostics) == expected;
    assert
      c.systemd.services."systemd-suspend-then-hibernate".onFailure
      == (if expected then [ "hibernate-fallback.service" ] else [ ]);
    assert
      c.systemd.services."systemd-hibernate".onFailure
      == (if expected then [ "hibernate-failure-diagnostics.service" ] else [ ]);
    assert sleep.HibernateDelaySec == "30m";
    assert c.swapDevices != [ ];
    assert c.boot.resumeDevice != "";
    true;
in
{
  disabled = check false system;
  enabled = check true enabled;
}
