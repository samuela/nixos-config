# Configuration for tropical-turnip (Framework 13" AMD 7040)
{ config, pkgs, ... }:

let
  # Last updated 2026-04-05
  nixos-hardware = builtins.fetchTarball "https://github.com/NixOS/nixos-hardware/archive/80afbd13eea0b7c4ac188de949e1711b31c2b5f0.tar.gz";

  writeLean =
    nameOrPath:
    {
      lean ? pkgs.lean4,
      strip ? true,
      makeWrapperArgs ? [ ],
    }:
    content:
    let
      exeName = builtins.baseNameOf nameOrPath;
    in
    pkgs.writers.makeBinWriter {
      inherit strip makeWrapperArgs;
      compileScript = ''
        export HOME="$PWD"
        export XDG_CACHE_HOME="$PWD/.cache"
        export CC="${pkgs.stdenv.cc}/bin/cc"
        export AR="${pkgs.binutils}/bin/ar"

        cp "$contentPath" Main.lean
        cat > lakefile.lean <<'EOF'
        import Lake
        open Lake DSL

        package generatedLeanBin

        lean_exe «${exeName}» where
          root := `Main
        EOF

        ${pkgs.lib.getExe' lean "lake"} build ${pkgs.lib.escapeShellArg exeName}
        cp ".lake/build/bin/${exeName}" "$out"
      '';
    } nameOrPath content;
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
  boot.kernelParams = [
    "resume_offset=8665088"
    # Hibernation debugging: log each driver's suspend/resume callback so the
    # last device touched before a hang is identifiable in dmesg.
    "pm_debug_messages"
    "no_console_suspend"
  ];

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
  systemd.sleep.settings.Sleep.HibernateDelaySec = "30m";

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
      smart-suspend = writeLean "smart-suspend" {
        makeWrapperArgs = [
          "--prefix"
          "PATH"
          ":"
          (pkgs.lib.makeBinPath [
            pkgs.coreutils
            pkgs.procps
            pkgs.pulseaudio
            pkgs.systemd
          ])
        ];
      } ./smart-suspend.lean;
    in
    {
      # Link smart-suspend for manual debugging. Note that this is not in PATH.
      home.file.".local/bin/smart-suspend".source = smart-suspend;

      services.swayidle = {
        enable = true;
        # Drop the default "-w" so swayidle doesn't block resume callbacks
        # while a timeout command is still running. "smart-suspend arm" loops
        # until it suspends, so with -w swayidle could never deliver disarm
        # mid-wait — the user would stay armed even while actively using the
        # machine.
        extraArgs = [ ];
        timeouts = [
          {
            timeout = 3 * 60;
            command = "${pkgs.niri}/bin/niri msg action power-off-monitors";
          }

          {
            timeout = 5 * 60;
            # Stay armed while the session remains idle so unplugging AC after
            # the initial timeout still suspends an already-idle session.
            command = "${smart-suspend} arm";
            resumeCommand = "${smart-suspend} disarm";
          }
        ];
      };
    };
}
