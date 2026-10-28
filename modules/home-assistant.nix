# Native Home Assistant; imported only by luminous-lemon.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  stateDir = config.services.home-assistant.configDir;
  backupDir = "${stateDir}/backups";
in
{
  services.home-assistant = {
    enable = true;
    configDir = "/var/lib/hass";
    # Keep the frontend private to the tailnet; no blanket LAN/public opening.
    openFirewall = false;
    openFirewallForComponents = false;
    extraComponents = [
      "default_config"
      "met" # Used during onboarding.
      "alexa_devices"
      "tplink"
      "yeelight"
      "homekit_controller"
    ];
    customComponents = [ (pkgs.callPackage ../nix/dreame-vacuum.nix { }) ];
    # Accounts, integration credentials and dashboards live in runtime .storage,
    # not the Nix store. Keep UI-authored automations/scripts/scenes writable too.
    config = {
      default_config = { };
      # Serve connects over IPv4 loopback, not from a tailnet/LAN address.
      http = {
        use_x_forwarded_for = true;
        trusted_proxies = [ "127.0.0.1" ];
      };
      automation = "!include automations.yaml";
      script = "!include scripts.yaml";
      scene = "!include scenes.yaml";
    };
  };

  # Reapply the scoped route on boot and whenever this unit changes. Tagging,
  # grants and svc:ha must be set up by an admin first. Serve also persists the
  # route in tailscaled's state; never reset unrelated routes when stopping.
  systemd.services.home-assistant-tailscale = {
    description = "Publish Home Assistant as Tailscale Service ha (admin setup required)";
    wantedBy = [ "multi-user.target" ];
    requires = [ "tailscaled.service" ];
    wants = [ "home-assistant.service" ];
    after = [
      "tailscaled.service"
      "home-assistant.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = 10;
      ExecStart = "${lib.getExe config.services.tailscale.package} serve --service=svc:ha --http=80 127.0.0.1:8123";
    };
  };

  # Retain the direct tailnet fallback until Service access is verified.
  networking.firewall.interfaces.${config.services.tailscale.interfaceName}.allowedTCPPorts = [
    8123
  ];

  # Seed only missing files, never overwrite UI edits. Create the archive path
  # before restic can run, including before Home Assistant's first startup.
  systemd.tmpfiles.rules = [
    "d ${stateDir} 0700 hass hass - -"
    "d ${backupDir} 0700 hass hass - -"
    "f ${stateDir}/automations.yaml 0600 hass hass - []"
    "f ${stateDir}/scripts.yaml 0600 hass hass - {}"
    "f ${stateDir}/scenes.yaml 0600 hass hass - []"
  ];

  # Back up HA-created archives, NOT a live SQLite database or runtime .storage.
  # Archive creation/scheduling and recovery-key custody require UI onboarding.
  services.restic.backups.${config.networking.hostName}.paths =
    lib.mkIf config.services.resticBackup.enable
      [ backupDir ];
}
