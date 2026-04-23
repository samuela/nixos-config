# Configuration for luminous-lemon (ThinkPad L13 Gen 1)
{ ... }:

let
  # Last updated 2025-12-12
  nixos-hardware = builtins.fetchTarball "https://github.com/NixOS/nixos-hardware/archive/9154f4569b6cdfd3c595851a6ba51bfaa472d9f3.tar.gz";
in
{
  imports = [
    "${nixos-hardware}/lenovo/thinkpad/l13"
    ./hardware-configuration.nix
    ../../modules/core.nix
    ../../modules/openclaw.nix
    ../../modules/opencode.nix
    ../../modules/oom-mitigations.nix
  ];

  networking.hostName = "luminous-lemon";

  # Server mode: never suspend or hibernate
  systemd.sleep.extraConfig = ''
    AllowSuspend=no
    AllowHibernation=no
    AllowSuspendThenHibernate=no
    AllowHybridSleep=no
  '';

  # Postmortem, 2026-04-23:
  # An 8-way Rust build pinned all cores long enough to hit the firmware thermal
  # cutoff and force a hardware-protection shutdown. The goal here is to make
  # the machine back off earlier so ordinary throttling happens before the
  # firmware's final emergency poweroff.
  #
  # thermald: asks the kernel/firmware to cool the machine earlier as temps rise.
  # tlp: keeps CPU policy less aggressive by disabling turbo and capping max perf.
  # throttled: enforces Intel package power and temperature targets directly.
  #
  # This machine lives on wall power, so keep one conservative thermal policy on
  # both AC and battery and do not rely on power-source detection for safety.
  services.thermald = {
    enable = true;
    ignoreCpuidCheck = true;
  };
  services.tlp.enable = true;
  services.throttled.enable = true;

  services.tlp.settings = {
    CPU_BOOST_ON_AC = 0;
    CPU_BOOST_ON_BAT = 0;
    CPU_HWP_DYN_BOOST_ON_AC = 0;
    CPU_HWP_DYN_BOOST_ON_BAT = 0;
    CPU_MAX_PERF_ON_AC = 90;
    CPU_MAX_PERF_ON_BAT = 90;
    CPU_ENERGY_PERF_POLICY_ON_AC = "balance_power";
    CPU_ENERGY_PERF_POLICY_ON_BAT = "balance_power";
    PLATFORM_PROFILE_ON_AC = "balanced";
    PLATFORM_PROFILE_ON_BAT = "balanced";
  };

  services.throttled.extraConfig = ''
    [GENERAL]
    Enabled: True
    Sysfs_Power_Path: /sys/class/power_supply/ADP1/online
    Autoreload: True

    [BATTERY]
    Update_Rate_s: 5
    PL1_Tdp_W: 20
    PL1_Duration_s: 28
    PL2_Tdp_W: 28
    PL2_Duration_S: 0.002
    Trip_Temp_C: 80
    cTDP: 0
    Disable_BDPROCHOT: False

    [AC]
    Update_Rate_s: 5
    PL1_Tdp_W: 20
    PL1_Duration_s: 28
    PL2_Tdp_W: 28
    PL2_Duration_S: 0.002
    Trip_Temp_C: 80
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

  # Tailscale SSH
  # Enable nix-ld for running dynamically linked binaries (e.g. VS Code Remote server)
  programs.nix-ld.enable = true;
  services.tailscale.extraSetFlags = [ "--ssh" ];
}
