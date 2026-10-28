# Run after checking HOME, resolved Nix/toolchain, /nix/store and builders:
# nix-build tests/dreame-vacuum.nix --no-out-link --option builders ''
# No HA service, cloud login or network traffic. Use the deployed package's
# dependency selection and patched Core source, without building/running HA.
let
  nixpkgs = import ../nix/pinned-nixpkgs-path.nix;
  host = import (nixpkgs + "/nixos/lib/eval-config.nix") {
    modules = [ ../hosts/luminous-lemon/configuration.nix ];
  };
  inherit (host) pkgs;
  ha = host.config.services.home-assistant;
  component = builtins.head ha.customComponents;
  ps = ha.finalPackage.python3Packages;
  core = pkgs.applyPatches {
    name = "home-assistant-import-source-${ha.package.version}";
    src = ha.package.src;
    patches = ha.package.patches;
  };
in
assert component.domain == "dreame_vacuum";
assert component.src.rev == "2da4fb76f61934ceadaa69b050a148365ed37cd5";
assert pkgs.lib.versionAtLeast ps.cryptography.version "45";
pkgs.runCommand "dreame-vacuum-check"
  {
    nativeBuildInputs = [ ps.python ];
    PYTHONPATH = "${component}:${core}:${ps.makePythonPath ha.finalPackage.dependencies}:${ha.finalPackage.pythonPath}";
    componentPath = component;
    sourcePath = component.src;
    pythonVersion = ps.python.version;
    cryptographyVersion = ps.cryptography.version;
  }
  ''
    python ${./test_dreame_vacuum.py}
    touch "$out"
  ''
