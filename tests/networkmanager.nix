# Run: nix-build tests/networkmanager.nix --no-out-link --option builders ''
# Evaluation guards the narrow package override. The sandboxed smoke test only
# queries binary versions and checks the compiled Wi-Fi retry log marker; it
# does not start a daemon, access the host's D-Bus, or exercise real Wi-Fi.
let
  nixpkgs = import ../nix/pinned-nixpkgs-path.nix;
  system = import (nixpkgs + "/nixos/lib/eval-config.nix") {
    modules = [ ../hosts/tropical-turnip/configuration.nix ];
  };
  inherit (system) pkgs;
  c = system.config;
  nm = c.networking.networkmanager.package;
  baseline =
    (system.extendModules {
      modules = [
        {
          networking.networkmanager.package = pkgs.lib.mkForce pkgs.networkmanager;
        }
      ];
    }).config;
in
assert nm.version == "1.58.1";
# Retire this temporary override/test when the primary pin catches up.
assert pkgs.lib.versionOlder pkgs.networkmanager.version "1.58";
assert nm.drvPath != pkgs.networkmanager.drvPath;
assert c.boot.kernelPackages.kernel.drvPath == baseline.boot.kernelPackages.kernel.drvPath;
assert c.hardware.firmware.drvPath == baseline.hardware.firmware.drvPath;
assert c.hardware.graphics.package.drvPath == baseline.hardware.graphics.package.drvPath;
assert c.systemd.package.drvPath == baseline.systemd.package.drvPath;
assert
  c.systemd.services.wpa_supplicant.serviceConfig.ExecStart
  == baseline.systemd.services.wpa_supplicant.serviceConfig.ExecStart;
assert c.networking.networkmanager.settings == baseline.networking.networkmanager.settings;
assert
  c.networking.networkmanager.connectionConfig == baseline.networking.networkmanager.connectionConfig;
assert
  map toString c.networking.networkmanager.plugins
  == map toString baseline.networking.networkmanager.plugins;
assert builtins.elem (toString nm) (map toString c.systemd.packages);
assert builtins.elem (toString nm) (map toString c.environment.systemPackages);
pkgs.runCommand "networkmanager-upgrade-check"
  {
    nativeBuildInputs = [ pkgs.gnugrep ];
  }
  ''
    mkdir -p "$out"
    ${nm}/sbin/NetworkManager --version | tee "$out/daemon-version"
    grep -Fx '${nm.version}' "$out/daemon-version"
    ${nm}/bin/nmcli --version | tee "$out/client-version"
    grep -Fx 'nmcli tool, version ${nm.version}' "$out/client-version"
    grep -r -a -q -F \
      'Activation: (wifi) disconnected during association, reauthenticating connection' \
      ${nm}/lib/NetworkManager
    touch "$out/wifi-auth-retry-present"
  ''
