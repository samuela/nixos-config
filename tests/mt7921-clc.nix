# Run: nix-build tests/mt7921-clc.nix --no-out-link --option builders ''
# Verify the upgraded kernel includes both CLC parser fixes without backports.
let
  nixpkgs = import ../nix/pinned-nixpkgs-path.nix;
  system = import (nixpkgs + "/nixos/lib/eval-config.nix") {
    modules = [ ../hosts/tropical-turnip/configuration.nix ];
  };
  inherit (system) pkgs;
  kernel = system.config.boot.kernelPackages.kernel;
  patches = builtins.filter (
    p: pkgs.lib.hasPrefix "mt7921-clc-" p.name
  ) system.config.boot.kernelPatches;
  mcuPath = "drivers/net/wireless/mediatek/mt76/mt7921/mcu.c";
  # Identical in upstream v7.2.7 and v7.2.8.
  expectedHash = "a646bf0950bbf0928518e8981e95924d548b8f1b3d49cabce66b5351db5af769";
in
assert kernel.version == "7.2.8";
assert patches == [ ];
pkgs.runCommand "mt7921-clc-upstream-check"
  {
    nativeBuildInputs = [ pkgs.gnutar pkgs.xz ];
  }
  ''
    tar -xJf ${kernel.src} --strip-components=1 --wildcards '*/${mcuPath}'
    echo '${expectedHash}  ${mcuPath}' | sha256sum --check
    mkdir -p "$out"
    cp ${mcuPath} "$out/mcu.c"
  ''
