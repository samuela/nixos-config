# Configuration for luminous-lemon (ThinkPad L13 Gen 1)
{ config, pkgs, ... }:

let
  # Last updated 2025-12-12
  nixos-hardware = builtins.fetchTarball "https://github.com/NixOS/nixos-hardware/archive/9154f4569b6cdfd3c595851a6ba51bfaa472d9f3.tar.gz";

  # HDMI-attached Google TV. CEC isn't wired through on this laptop's HDMI port,
  # so we control the TV over the network via ADB instead.
  tvIp = "192.168.4.39";
  mkTvCmd =
    name: keycode:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [ pkgs.android-tools ];
      text = ''
        adb connect ${tvIp}:5555 >/dev/null
        adb -s ${tvIp}:5555 shell input keyevent ${keycode}
      '';
    };
in
{
  imports = [
    "${nixos-hardware}/lenovo/thinkpad/l13"
    ./hardware-configuration.nix
    ../../modules/core.nix
    ../../modules/openclaw.nix
    ../../modules/opencode.nix
    ../../modules/oom-mitigations.nix
    ../../modules/restic-backup.nix
  ];

  networking.hostName = "luminous-lemon";

  services.resticBackup.enable = true;

  environment.systemPackages = [
    (mkTvCmd "tv-on" "KEYCODE_WAKEUP")
    (mkTvCmd "tv-off" "KEYCODE_SLEEP")
  ];

  # Follow upstream throttled master until a release after v0.11 lands in nixpkgs.
  # We need a6a95bd, which makes temperature-only configs work by skipping the
  # MSR_PKG_POWER_LIMIT write when PL1/PL2 are omitted. v0.11 logs that package
  # power limits are disabled, then crashes with KeyError: 'MSR_PKG_POWER_LIMIT'.
  nixpkgs.overlays = [
    (_final: prev: {
      throttled =
        assert prev.throttled.version == "0.11"
          || throw "nixpkgs throttled is ${prev.throttled.version}; revisit the local upstream-master overlay";
        prev.throttled.overrideAttrs (_old: {
          version = "unstable-2026-04-20";
          src = prev.fetchFromGitHub {
            owner = "erpalma";
            repo = "throttled";
            rev = "9813d814ae9540a8d3d166d22bf8afe458d323e6";
            hash = "sha256-HCC2RlMpsJMRDnqThOTQsEihuuMU9VWtdD4Yggl/jo4=";
          };
        });
    })
  ];

  # Server mode: never suspend or hibernate
  systemd.sleep.settings.Sleep = {
    AllowSuspend = "no";
    AllowHibernation = "no";
    AllowSuspendThenHibernate = "no";
    AllowHybridSleep = "no";
  };

  # Postmortem, 2026-04-23:
  # An 8-way Rust build pinned all cores long enough to hit the firmware thermal
  # cutoff and force a hardware-protection shutdown. The goal here is to make
  # the machine back off earlier so ordinary throttling happens before the
  # firmware's final emergency poweroff.
  #
  # thermald: asks the kernel/firmware to cool the machine earlier as temps rise.
  # tlp: sets CPU boost/performance policy and caps max perf where needed.
  # throttled: enforces Intel package power and temperature targets directly.
  #
  # This machine lives on wall power, so keep one explicit thermal policy on
  # both AC and battery and do not rely on power-source detection for safety.
  services.thermald = {
    enable = true;
    ignoreCpuidCheck = true;
  };
  services.tlp.enable = true;
  services.throttled.enable = true;

  services.tlp.settings = {
    CPU_BOOST_ON_AC = 1;
    CPU_HWP_DYN_BOOST_ON_AC = 1;
    CPU_MAX_PERF_ON_AC = 100;
    CPU_ENERGY_PERF_POLICY_ON_AC = "performance";
    PLATFORM_PROFILE_ON_AC = "performance";
  };

  services.throttled.extraConfig = ''
    [GENERAL]
    Enabled: True
    Sysfs_Power_Path: /sys/class/power_supply/ADP1/online
    Autoreload: True

    [BATTERY]
    Update_Rate_s: 30
    Trip_Temp_C: 85
    cTDP: 0
    Disable_BDPROCHOT: False

    [AC]
    Update_Rate_s: 5
    Trip_Temp_C: 85
    cTDP: 0
    Disable_BDPROCHOT: False

    [UNDERVOLT.BATTERY]
    CORE: 0
    GPU: 0
    CACHE: 0
    UNCORE: 0
    ANALOGIO: 0

    [UNDERVOLT.AC]
    CORE: 0
    GPU: 0
    CACHE: 0
    UNCORE: 0
    ANALOGIO: 0
  '';

  # throttled's built-in Autoreload checks file mtime, but Nix store-backed
  # config files have a normalized timestamp, so runtime reload never notices a
  # rebuild. Force a service restart when the generated config changes.
  systemd.services.throttled.restartTriggers = [ config.environment.etc."throttled.conf".source ];

  # Tailscale SSH
  # Enable nix-ld for running dynamically linked binaries (e.g. VS Code Remote server)
  programs.nix-ld.enable = true;
  services.tailscale.extraSetFlags = [ "--ssh" ];
}
