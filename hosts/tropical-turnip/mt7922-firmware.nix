{
  config,
  lib,
  pkgs,
  ...
}:
let
  previousFirmware = pkgs.callPackage ./mt7922-firmware-package.nix { };
in
{
  options.hardware.mt7922Firmware.usePrevious = lib.mkEnableOption ''
    the February 2026 MT7922 Wi-Fi RAM/ROM-patch pair, as shipped in
    linux-firmware-20260519, for the firmware-only comparison in issue #15
  '';

  config = lib.mkIf config.hardware.mt7922Firmware.usePrevious {
    # The normal bundle remains present. Only these two names take precedence;
    # compression preserves meta.priority. In particular, Bluetooth stays put.
    hardware.firmware = lib.mkBefore [ (lib.hiPrio previousFirmware) ];
  };
}
