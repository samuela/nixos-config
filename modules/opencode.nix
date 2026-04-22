{ unstablePkgs, ... }:

{
  # Reuse the shared newer nixpkgs pin from core.nix instead of carrying a
  # separate module-local pin. The default module `pkgs` set is older, but the
  # shared `unstablePkgs` pin already contains opencode.
  environment.systemPackages = [ unstablePkgs.opencode ];

  systemd.services.opencode-web = {
    description = "OpenCode Web";
    after = [
      "network-online.target"
      "tailscaled.service"
    ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${unstablePkgs.opencode}/bin/opencode web --hostname 0.0.0.0 --port 3535";
      WorkingDirectory = "/home/skainswo/opencode";
      User = "skainswo";
      Group = "users";
      EnvironmentFile = "/etc/opencode.env";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  networking.firewall.allowedTCPPorts = [ 3535 ];
}
