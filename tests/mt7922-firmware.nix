# Run: nix-build tests/mt7922-firmware.nix --no-out-link --option builders ''
# Compare forced enabled/disabled variants regardless of the deployed toggle,
# including every delivered firmware file.
# No driver operations, network changes, or hardware tests are performed.
let
  nixpkgs = import ../nix/pinned-nixpkgs-path.nix;
  system = import (nixpkgs + "/nixos/lib/eval-config.nix") {
    modules = [ ../hosts/tropical-turnip/configuration.nix ];
  };
  inherit (system) pkgs;
  c =
    (system.extendModules {
      modules = [
        {
          hardware.mt7922Firmware.usePrevious = pkgs.lib.mkForce true;
        }
      ];
    }).config;
  baseline =
    (system.extendModules {
      modules = [
        {
          hardware.mt7922Firmware.usePrevious = pkgs.lib.mkForce false;
        }
      ];
    }).config;
in
assert c.hardware.mt7922Firmware.usePrevious;
assert c.hardware.firmwareCompression == "zstd";
assert c.hardware.firmware.drvPath != baseline.hardware.firmware.drvPath;
assert c.boot.kernelPackages.kernel.drvPath == baseline.boot.kernelPackages.kernel.drvPath;
assert c.boot.kernelParams == baseline.boot.kernelParams;
assert c.boot.extraModprobeConfig == baseline.boot.extraModprobeConfig;
assert c.networking.networkmanager.package.version == "1.58.1";
assert
  c.networking.networkmanager.package.drvPath == baseline.networking.networkmanager.package.drvPath;
assert c.networking.networkmanager.settings == baseline.networking.networkmanager.settings;
assert
  c.networking.networkmanager.connectionConfig == baseline.networking.networkmanager.connectionConfig;
assert c.hardware.graphics.package.drvPath == baseline.hardware.graphics.package.drvPath;
assert c.systemd.package.drvPath == baseline.systemd.package.drvPath;
assert
  c.systemd.services.wpa_supplicant.serviceConfig.ExecStart
  == baseline.systemd.services.wpa_supplicant.serviceConfig.ExecStart;
pkgs.runCommand "mt7922-firmware-comparison-check"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.zstd
    ];
  }
  ''
    mkdir -p "$out"
    python3 ${./check_mt7922_firmware.py} \
      ${baseline.hardware.firmware}/lib/firmware \
      ${c.hardware.firmware}/lib/firmware \
      "$out/comparison.json"
  ''
