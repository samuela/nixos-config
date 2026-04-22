# Configuration for luminous-lemon (ThinkPad L13 Gen 1)
{ config, pkgs, ... }:

let
  # Last updated 2025-12-12
  nixos-hardware = builtins.fetchTarball "https://github.com/NixOS/nixos-hardware/archive/9154f4569b6cdfd3c595851a6ba51bfaa472d9f3.tar.gz";
in
{
  imports = [
    "${nixos-hardware}/lenovo/thinkpad/l13"
    ./hardware-configuration.nix
    ../../modules/core.nix
    ../../modules/opencode.nix
  ];

  networking.hostName = "luminous-lemon";

  # Server mode: never suspend or hibernate
  systemd.sleep.extraConfig = ''
    AllowSuspend=no
    AllowHibernation=no
    AllowSuspendThenHibernate=no
    AllowHybridSleep=no
  '';

  # Tailscale SSH
  # Enable nix-ld for running dynamically linked binaries (e.g. VS Code Remote server)
  programs.nix-ld.enable = true;
  services.tailscale.extraSetFlags = [ "--ssh" ];
}
