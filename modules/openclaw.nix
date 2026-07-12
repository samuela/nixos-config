{ pkgs, unstableNixpkgsSrc, ... }:

let
  openclaw-pkgs = import unstableNixpkgsSrc {
    config = {
      allowUnfree = true;
      permittedInsecurePackages = [ "openclaw-2026.6.11" ];
    };
  };

  # OpenClaw's generated user service misses NixOS profile paths, so its
  # daemon cannot find tools like claude or tailscale. We provide a
  # persistent drop-in instead of patching the generated unit directly.
  openclawServicePath = pkgs.lib.concatStringsSep ":" [
    "/run/wrappers/bin"
    "/home/skainswo/.local/share/flatpak/exports/bin"
    "/var/lib/flatpak/exports/bin"
    "/home/skainswo/.nix-profile/bin"
    "/nix/profile/bin"
    "/home/skainswo/.local/state/nix/profile/bin"
    "/etc/profiles/per-user/skainswo/bin"
    "/nix/var/nix/profiles/default/bin"
    "/run/current-system/sw/bin"
    "/home/skainswo/.local/bin"
    "/home/skainswo/.npm-global/bin"
    "/home/skainswo/bin"
    "/home/skainswo/.volta/bin"
    "/home/skainswo/.asdf/shims"
    "/home/skainswo/.bun/bin"
    "/home/skainswo/.nvm/current/bin"
    "/home/skainswo/.fnm/current/bin"
    "/home/skainswo/.local/share/pnpm"
  ];
in
{
  # Keep the per-user systemd instance running without an active login session
  # so the OpenClaw user service can start at boot and survive SSH/logout.
  users.users.skainswo.linger = true;

  environment.systemPackages = [ openclaw-pkgs.openclaw ];

  home-manager.users.skainswo = {
    home.file.".config/systemd/user/openclaw-gateway.service.d/path.conf".text = ''
      [Service]
      Environment=PATH=${openclawServicePath}
    '';
  };
}
