# Run: nix-build tests/mt7921-clc.nix --no-out-link --option builders ''
# Apply the configured backports to the configured kernel source without building
# the kernel. Check exact equivalence to the fixed upstream v7.2.7 mcu.c, so a
# validation-only patch (which rejects our firmware) cannot pass this test.
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
  # git show v7.2.7:drivers/net/wireless/mediatek/mt76/mt7921/mcu.c | sha256sum
  expectedHash = "a646bf0950bbf0928518e8981e95924d548b8f1b3d49cabce66b5351db5af769";
in
assert kernel.version == "7.2.2";
assert
  map (p: p.name) patches == [
    "mt7921-clc-validate"
    "mt7921-clc-skip-unknown"
  ];
pkgs.runCommand "mt7921-clc-backport-check"
  {
    nativeBuildInputs = [
      pkgs.gnutar
      pkgs.xz
      pkgs.patch
    ];
  }
  ''
    tar -xJf ${kernel.src} --strip-components=1 --wildcards '*/${mcuPath}'
    chmod u+w ${mcuPath}
    ${pkgs.lib.concatMapStringsSep "\n" (p: "patch --batch --fuzz=0 -p1 < ${p.patch}") patches}
    echo '${expectedHash}  ${mcuPath}' | sha256sum --check
    mkdir -p "$out"
    cp ${mcuPath} "$out/mcu.c"
  ''
