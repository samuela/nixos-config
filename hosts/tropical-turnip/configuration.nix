# Configuration for tropical-turnip (Framework 13" AMD 7040)
{ config, pkgs, ... }:

let
  # Last updated 2026-04-05
  nixos-hardware = builtins.fetchTarball "https://github.com/NixOS/nixos-hardware/archive/80afbd13eea0b7c4ac188de949e1711b31c2b5f0.tar.gz";
in
{
  imports = [
    "${nixos-hardware}/framework/13-inch/7040-amd"
    ./hardware-configuration.nix
    ../../modules/core.nix
    ../../modules/oom-mitigations.nix
  ];

  networking.hostName = "tropical-turnip";

  # Use latest kernel for amdgpu/RDNA 3 MES fixes (6.12 had recurring GPU resets)
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # See https://wiki.archlinux.org/title/Network_configuration/Wireless#mt7921
  boot.extraModprobeConfig = ''
    options mt7921e disable_aspm=1
  '';

  ### Hibernation, swap, and power management

  # Create a 36GB swap file for hibernation (system has 32GB RAM)
  swapDevices = [
    {
      device = "/var/lib/swapfile";
      size = 36 * 1024; # 36GB in MB
    }
  ];

  # Enable hibernation support - specify swap file location and offset
  # NOTE: If you change the swap size, you MUST update resume_offset:
  #   1. Run: sudo filefrag -v /var/lib/swapfile | head -10
  #   2. Use the first physical_offset value (currently 8665088)
  #   3. Update resume_offset below and rebuild
  boot.resumeDevice = "/dev/disk/by-uuid/9af0faf1-75d0-43c3-ba88-b697ddf73c4d";
  boot.kernelParams = [ "resume_offset=8665088" ];

  # Power management - prevent file system corruption from sudden battery death
  # When battery hits 5%, the system will hibernate (save RAM to disk)
  services.upower = {
    enable = true;
    percentageLow = 15; # Warn at 15%
    percentageCritical = 5; # Critical at 5%
    percentageAction = 5; # Take action at 5%
    # NOTE: This will attempt hibernate even if there's a kernel mismatch (unlike
    # smart-suspend which falls back to plain suspend). At 5% battery, a failed
    # hibernate resume on next boot is preferable to losing everything.
    criticalPowerAction = "Hibernate";
  };

  # HibernateDelaySec: When using "suspend-then-hibernate", stay suspended for 30m before hibernating
  systemd.sleep.extraConfig = ''
    HibernateDelaySec=30m
  '';

  # Ignore lid switch events and let swayidle's smart-suspend handle suspension.
  # This allows smart-suspend to check power state and audio activity before suspending.
  # Behavior: closing lid on AC power won't suspend, closing on battery will suspend
  # after swayidle's 5-minute inactivity timeout (unless audio is active).
  services.logind.settings.Login.HandleLidSwitch = "ignore";

  # Turn internal screen off/on when lid is closed/opened. This is separate from
  # suspend handling (which is done by swayidle's smart-suspend based on idle time).
  # Only affects eDP-1 (internal display), so external monitors remain on.
  services.acpid = {
    enable = true;
    lidEventCommands = ''
      export XDG_RUNTIME_DIR=/run/user/$(${pkgs.coreutils}/bin/id -u skainswo)
      # Find niri socket dynamically (includes PID which changes on restart)
      export NIRI_SOCKET=$(${pkgs.findutils}/bin/find $XDG_RUNTIME_DIR -maxdepth 1 -name "niri.*.sock" 2>/dev/null | head -1)
      if [ -z "$NIRI_SOCKET" ]; then exit 0; fi
      # Event is passed as single string like "button/lid LID0 close"
      action=$(echo "$1" | ${pkgs.gawk}/bin/awk '{print $3}')
      case "$action" in
        close) ${pkgs.niri}/bin/niri msg output eDP-1 off ;;
        open)  ${pkgs.niri}/bin/niri msg output eDP-1 on ;;
      esac
    '';
  };

  # swayidle with smart-suspend for idle suspension
  home-manager.users.skainswo =
    { pkgs, ... }:
    let
      smart-suspend = pkgs.writeScript "smart-suspend" ''
        #!${pkgs.fish}/bin/fish

        function log
          printf '%s\n' $argv >&2
        end

        log "start"

        # Avoid suspending while plugged into power. We use battery state rather
        # than line_power devices because ACAD can go stale and report "online"
        # after the charger is unplugged (observed 2026-03-01, drained to 3%).
        set battery_state (${pkgs.upower}/bin/upower -i /org/freedesktop/UPower/devices/battery_BAT1 | string match -r 'state:\s+(\S+)')
        set battery_state $battery_state[-1]
        log "battery state: $battery_state"
        set line_powers (${pkgs.upower}/bin/upower -e | string match "*line_power*")
        log "line_power devices: $line_powers"
        for lp in $line_powers
          if test -n "$lp"
            if ${pkgs.upower}/bin/upower -i $lp | string match -q "*online: *yes*"
              log "line_power online: $lp"
            end
          end
        end
        if test "$battery_state" != "discharging"
          log "skip suspend: battery not discharging"
          exit 0
        end

        # Avoid suspending while audio capture or playback is active (e.g., in a call).
        if ${pkgs.pulseaudio}/bin/pactl list sinks | string match -q "*State: RUNNING*"
          log "skip suspend: audio sink running"
          exit 0
        end
        if ${pkgs.pulseaudio}/bin/pactl list sources | string match -q "*State: RUNNING*"
          log "skip suspend: audio source running"
          exit 0
        end

        # If a nixos-rebuild changed the kernel since this boot, hibernation resume
        # would fail (kernel version mismatch). Fall back to plain suspend in that case.
        set booted_kernel (${pkgs.coreutils}/bin/readlink -f /run/booted-system/kernel)
        set current_kernel (${pkgs.coreutils}/bin/readlink -f /run/current-system/kernel)
        if test "$booted_kernel" != "$current_kernel"
          log "kernel mismatch: booted=$booted_kernel current=$current_kernel. Using suspend."
          ${pkgs.coreutils}/bin/sleep 5
          exec ${pkgs.systemd}/bin/systemctl suspend
        else
        log "suspend-then-hibernate in 5s"
          ${pkgs.coreutils}/bin/sleep 5
        exec ${pkgs.systemd}/bin/systemctl suspend-then-hibernate
        end
      '';
    in
    {
      # Link smart-suspend for manual debugging. Note that this is not in PATH.
      home.file.".local/bin/smart-suspend".source = smart-suspend;

      services.swayidle = {
        enable = true;
        timeouts = [
          {
            timeout = 3 * 60;
            command = "${pkgs.niri}/bin/niri msg action power-off-monitors";
          }

          {
            timeout = 5 * 60;
            command = "${smart-suspend}";
          }
        ];
      };
    };
}
