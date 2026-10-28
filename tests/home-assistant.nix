# Run: nix-build tests/home-assistant.nix --no-out-link --option builders ''
# Evaluate both real hosts and check generated YAML in a sandbox.
# Run the pinned Serve CLI against a sandbox-only fake LocalAPI socket, never
# the live daemon. No HA build/start, credentials, tags, policy or devices.
let
  nixpkgs = import ../nix/pinned-nixpkgs-path.nix;
  evalHost =
    host:
    import (nixpkgs + "/nixos/lib/eval-config.nix") {
      modules = [ (../hosts + "/${host}/configuration.nix") ];
    };
  luminous = evalHost "luminous-lemon";
  tropical = evalHost "tropical-turnip";
  inherit (luminous) pkgs;
  inherit (pkgs) lib;
  c = luminous.config;
  ha = c.services.home-assistant;
  publication = c.systemd.services.home-assistant-tailscale;
  other = tropical.config;
  backup = c.services.restic.backups.luminous-lemon;
  baseline =
    (luminous.extendModules {
      modules = [ { disabledModules = [ ../modules/home-assistant.nix ]; } ];
    }).config;
  python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
in
assert ha.enable;
assert !other.services.home-assistant.enable;
assert !(other.systemd.services ? home-assistant);
assert !(other.systemd.services ? home-assistant-tailscale);
assert !(c.systemd.services ? go-links);
assert publication.wantedBy == [ "multi-user.target" ];
assert publication.requiredBy == [ ];
assert publication.requires == [ "tailscaled.service" ];
assert publication.wants == [ "home-assistant.service" ];
assert
  publication.after == [
    "tailscaled.service"
    "home-assistant.service"
  ];
assert publication.serviceConfig.Type == "oneshot";
assert
  publication.serviceConfig.ExecStart
  == "${lib.getExe c.services.tailscale.package} serve --service=svc:ha --http=80 127.0.0.1:8123";
assert !(publication.serviceConfig ? ExecStop);
assert publication.serviceConfig.RemainAfterExit;
assert publication.serviceConfig.Restart == "on-failure";
assert publication.serviceConfig.RestartSec == 10;
assert publication.script == "";
assert !(builtins.elem "/var/lib/hass/backups" other.services.restic.backups.tropical-turnip.paths);
assert !(builtins.elem 8123 other.networking.firewall.allowedTCPPorts);
assert lib.all (rules: !(builtins.elem 8123 rules.allowedTCPPorts)) (
  builtins.attrValues other.networking.firewall.interfaces
);
assert ha.package.version == pkgs.home-assistant.version;
assert
  ha.extraComponents == [
    "default_config"
    "met"
    "alexa_devices"
  ];
assert lib.all (
  component: builtins.elem component ha.package.availableComponents
) ha.extraComponents;
assert lib.all (
  component: builtins.elem component ha.finalPackage.extraComponents
) ha.extraComponents;
assert lib.hasPrefix "\"${lib.getExe ha.finalPackage}\" "
  c.systemd.services.home-assistant.serviceConfig.ExecStart;
assert builtins.elem "multi-user.target" c.systemd.targets.home-assistant.wantedBy;
assert ha.customComponents == [ ];
assert ha.configDir == "/var/lib/hass";
assert c.users.users.hass.home == ha.configDir;
assert c.users.users.hass.createHome;
assert c.systemd.services.home-assistant.serviceConfig.User == "hass";
assert c.systemd.services.home-assistant.serviceConfig.UMask == "0077";
assert builtins.elem ha.configDir c.systemd.services.home-assistant.serviceConfig.ReadWritePaths;
assert ha.config.default_config == { };
assert ha.config.http.use_x_forwarded_for;
assert ha.config.http.trusted_proxies == [ "127.0.0.1" ];
assert ha.config.automation == "!include automations.yaml";
assert ha.config.script == "!include scripts.yaml";
assert ha.config.scene == "!include scenes.yaml";
assert !ha.configWritable;
assert ha.lovelaceConfig == null;
assert ha.lovelaceConfigFile == null;
assert !ha.openFirewall;
assert !ha.openFirewallForComponents;
assert ha.config.http.server_port == 8123;
assert
  ha.config.http.server_host == [
    "0.0.0.0"
    "::"
  ];
assert c.services.tailscale.interfaceName == "tailscale0";
assert c.networking.firewall.enable;
assert !(builtins.elem "tailscale0" c.networking.firewall.trustedInterfaces);
assert c.networking.firewall.allowedTCPPorts == baseline.networking.firewall.allowedTCPPorts;
assert c.networking.firewall.allowedUDPPorts == baseline.networking.firewall.allowedUDPPorts;
assert c.networking.firewall.interfaces.tailscale0.allowedTCPPorts == [ 8123 ];
assert
  c.networking.firewall.interfaces == baseline.networking.firewall.interfaces
  // {
    tailscale0 =
      baseline.networking.firewall.interfaces.tailscale0 or {
        allowedTCPPorts = [ ];
        allowedTCPPortRanges = [ ];
        allowedUDPPorts = [ ];
        allowedUDPPortRanges = [ ];
      }
      // {
        allowedTCPPorts = [ 8123 ];
      };
  };
assert c.services.avahi.enable && c.services.avahi.openFirewall;
assert c.services.avahi.allowInterfaces == baseline.services.avahi.allowInterfaces;
assert c.services.avahi.publish == baseline.services.avahi.publish;
assert c.services.tailscale.enable == baseline.services.tailscale.enable;
assert c.services.tailscale.interfaceName == baseline.services.tailscale.interfaceName;
assert lib.all (option: c.services.tailscale.${option} == baseline.services.tailscale.${option}) [
  "package"
  "openFirewall"
  "useRoutingFeatures"
  "extraSetFlags"
  "extraUpFlags"
  "authKeyFile"
  "permitCertUid"
];
assert lib.all
  (
    name:
    lib.all
      (option: c.systemd.services.${name}.${option} == baseline.systemd.services.${name}.${option})
      [
        "serviceConfig"
        "script"
        "path"
        "after"
        "wants"
        "wantedBy"
      ]
  )
  [
    "tailscaled"
    "tailscaled-set"
    "opencode-web"
  ];
assert
  lib.sort builtins.lessThan backup.paths == lib.sort builtins.lessThan (
    baseline.services.restic.backups.luminous-lemon.paths ++ [ "/var/lib/hass/backups" ]
  );
assert !(builtins.elem "/var/lib/hass" backup.paths);
assert lib.all (rule: builtins.elem rule c.systemd.tmpfiles.rules) [
  "d /var/lib/hass 0700 hass hass - -"
  "d /var/lib/hass/backups 0700 hass hass - -"
  "f /var/lib/hass/automations.yaml 0600 hass hass - []"
  "f /var/lib/hass/scripts.yaml 0600 hass hass - {}"
  "f /var/lib/hass/scenes.yaml 0600 hass hass - []"
];
pkgs.runCommand "home-assistant-config-check"
  {
    nativeBuildInputs = [ python ];
    configuration = c.environment.etc."home-assistant/configuration.yaml".source;
    publicationCommand = publication.serviceConfig.ExecStart;
  }
  ''
    python - <<'PY'
    import os
    import yaml

    class Loader(yaml.SafeLoader):
        pass

    Loader.add_constructor("!include", lambda loader, node: ("include", loader.construct_scalar(node)))
    with open(os.environ["configuration"]) as source:
        config = yaml.load(source, Loader=Loader)
    assert config["default_config"] == {}
    assert config["http"] == {
        "server_host": ["0.0.0.0", "::"], "server_port": 8123,
        "use_x_forwarded_for": True, "trusted_proxies": ["127.0.0.1"],
    }
    for domain, filename in [("automation", "automations.yaml"), ("script", "scripts.yaml"), ("scene", "scenes.yaml")]:
        assert config[domain] == ("include", filename)
    assert "alexa_devices" not in config
    print("Host scope, components, persistence, firewall, archives and loopback proxy YAML checked")
    PY
    python ${./test_home_assistant_tailscale.py}
    touch "$out"
  ''
