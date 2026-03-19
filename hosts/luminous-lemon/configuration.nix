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
  ];

  networking.hostName = "luminous-lemon";
}
