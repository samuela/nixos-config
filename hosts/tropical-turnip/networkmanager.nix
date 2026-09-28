{ pkgs, ... }:
let
  pin = import ../../nix/networkmanager-nixpkgs.nix;
  networkmanagerPkgs =
    import
      (builtins.fetchTarball {
        inherit (pin) url sha256;
      })
      {
        system = pkgs.stdenv.hostPlatform.system;
        config = { };
        overlays = [ ];
      };
in
{
  # NM 1.58 retries saved credentials after ambiguous handshake failures before
  # requesting new secrets. Avoid a single timeout blocking autoconnect (#15).
  # Upstream: 746a5902ad85ec0611a3e6ebfd7b68b45621a40b (plus its prerequisites).
  # Select the maintained 1.58.1 package and its dependencies, not new NixOS
  # modules or a global overlay: kernel, firmware and other hosts stay pinned.
  # Keep finite default retries; this does not fix the initial missing M3.
  networking.networkmanager.package = networkmanagerPkgs.networkmanager;
}
