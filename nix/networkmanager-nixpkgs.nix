# Separate nixpkgs-unstable pin for tropical-turnip's NetworkManager only.
# Keep the main system/kernel/firmware pin in pinned-nixpkgs.nix unchanged.
# Last updated: 2026-09-27.
# Refresh with the nixpkgs-unstable commit and nix-prefetch-url --unpack.
# Remove this pin and the host override once the main pin includes NM >= 1.58.
let
  rev = "3181085bfd08663b6b9e60bc7a8395c2aaa741bd";
in
{
  inherit rev;
  sha256 = "0k9mhqdj610jwzk2vwy04nk20dn993w4z59iyp1k0q71zri0slqi";
  url = "https://github.com/NixOS/nixpkgs/archive/${rev}.tar.gz";
}
