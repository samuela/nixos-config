{
  lib,
  fetchurl,
  runCommand,
}:
let
  # Parent of the June MT7922 update. Both blobs are byte-identical to the
  # February builds shipped in linux-firmware-20260519, retained on this host.
  # Fetch only Wi-Fi RAM + ROM patch, not the Bluetooth firmware or whole bundle.
  rev = "529153aaa9528c053899282cc42c36cdb4ea26f0";
  firmwareFile =
    name: hash:
    fetchurl {
      inherit name hash;
      url = "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/mediatek/${name}?id=${rev}";
    };
  rom = firmwareFile "WIFI_MT7922_patch_mcu_1_1_hdr.bin" "sha256-bQSYj19E/EHpQEpJIpGnpRmzjmrqY2my+TnNDHB2X1o=";
  ram = firmwareFile "WIFI_RAM_CODE_MT7922_1.bin" "sha256-Eib1swUxsvAniXpKSZ+3fDH0o5AlyY5amJZ2mqp4H9o=";
in
runCommand "mt7922-wifi-firmware-20260224"
  {
    meta = {
      description = "Previous MT7922 Wi-Fi firmware pair for a controlled comparison";
      license = lib.licenses.unfreeRedistributableFirmware;
      platforms = lib.platforms.linux;
    };
  }
  ''
    install -Dm444 ${rom} "$out/lib/firmware/mediatek/WIFI_MT7922_patch_mcu_1_1_hdr.bin"
    install -Dm444 ${ram} "$out/lib/firmware/mediatek/WIFI_RAM_CODE_MT7922_1.bin"
  ''
