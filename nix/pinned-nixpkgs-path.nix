let
  pin = import ./pinned-nixpkgs.nix;
in
builtins.fetchTarball {
  inherit (pin) url sha256;
}
