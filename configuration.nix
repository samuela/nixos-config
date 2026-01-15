# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:

let
  # Tracking release-25.11 branch. Last updated 2025-12-12
  home-manager = builtins.fetchTarball "https://github.com/nix-community/home-manager/archive/44777152652bc9eacf8876976fa72cc77ca8b9d8.tar.gz";

  # Last updated 2025-12-12
  nixos-hardware = builtins.fetchTarball "https://github.com/NixOS/nixos-hardware/archive/9154f4569b6cdfd3c595851a6ba51bfaa472d9f3.tar.gz";

  # Tracking release-25.11 branch. Last updated 2025-01-14
  stylix = builtins.fetchTarball "https://github.com/nix-community/stylix/archive/5ad96253be7ee7f66298d28a24ac8faba8e0fe54.tar.gz";

  # Tracking https://github.com/noctalia-dev/noctalia-shell/commits/main. Last updated 2025-01-12
  noctaliaSrc = builtins.fetchTarball "https://github.com/noctalia-dev/noctalia-shell/archive/2b55ae2c348fcad50089bc334c4a8155b2941d3b.tar.gz";
  # noctaliaSrc = ../noctalia-shell;
  noctaliaPackage = pkgs.callPackage "${noctaliaSrc}/nix/package.nix" { };
  noctaliaHomeModule = import "${noctaliaSrc}/nix/home-module.nix";

  # Tracking nixpkgs-unstable branch. Last updated 2025-01-14
  unstable-nixpkgs-src = builtins.fetchTarball "https://github.com/NixOS/nixpkgs/archive/13868c071cc73a5e9f610c47d7bb08e5da64fdd5.tar.gz";

  unstable-nixpkgs-patched = (import unstable-nixpkgs-src { }).applyPatches {
    name = "nixpkgs-patched";
    src = unstable-nixpkgs-src;
    patches = [
      # not currently in use but this is where we can patch nixpkgs as needed
    ];
  };

  unstable-pkgs = import unstable-nixpkgs-patched {
    config.allowUnfree = true;
  };
in
{
  # See https://github.com/NixOS/nixpkgs/pull/472183#issuecomment-3700677971
  systemd.package =
    if pkgs.systemd.version == "258.2" then
      pkgs.systemd.overrideAttrs (
        finalAttrs: _prevAttrs: {
          version = "258.3";
          src = pkgs.fetchFromGitHub {
            owner = "systemd";
            repo = "systemd";
            rev = "v${finalAttrs.version}";
            hash = "sha256-wpg/0z7xrB8ysPaa/zNp1mz+yYRCGyXz0ODZcKapovM=";
          };
        }
      )
    else
      abort "remove systemd package override";

  imports = [
    "${nixos-hardware}/framework/13-inch/7040-amd"
    # Include the results of the hardware scan.
    ./hardware-configuration.nix
    (import "${home-manager}/nixos")
    (import stylix).nixosModules.stylix
  ];

  # Bootloader.
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.systemd-boot.enable = true;
  boot.loader.timeout = 1;
  # See https://wiki.archlinux.org/title/Network_configuration/Wireless#mt7921
  boot.extraModprobeConfig = ''
    options mt7921e disable_aspm=1
  '';

  # See https://github.com/NixOS/nixos-hardware/tree/master/framework/13-inch/7040-amd#updating-firmware
  # Use `fwupdmgr update` to update firmware.
  services.fwupd.enable = true;

  security.polkit.enable = true;

  networking.hostName = "tropical-turnip"; # Define your hostname.
  # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.
  # networking.wireless.iwd.enable = true; # for impala

  programs.niri.enable = true;
  services.flatpak.enable = true;

  stylix.enable = true;
  stylix.image = ./wallpapers/john-towner-JgOeRuGD_Y4-unsplash.jpg;
  stylix.polarity = "dark";
  stylix.base16Scheme = "${pkgs.base16-schemes}/share/themes/gruvbox-dark-hard.yaml";
  stylix.opacity.terminal = 0.9;
  stylix.fonts = {
    serif = {
      package = pkgs.dejavu_fonts;
      name = "DejaVu Serif";
    };
    sansSerif = {
      package = pkgs.dejavu_fonts;
      name = "DejaVu Sans";
    };
    # Monospace font for terminals and shell UI.
    monospace = {
      package = pkgs.nerd-fonts.dejavu-sans-mono;
      name = "DejaVu Sans Mono";
    };
    emoji = {
      package = pkgs.noto-fonts-color-emoji;
      name = "Noto Color Emoji";
    };
    sizes.terminal = 18;
  };

  # Enable networking
  networking.networkmanager.enable = true;

  # Set your time zone.
  time.timeZone = "America/New_York";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_US.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "en_US.UTF-8";
    LC_IDENTIFICATION = "en_US.UTF-8";
    LC_MEASUREMENT = "en_US.UTF-8";
    LC_MONETARY = "en_US.UTF-8";
    LC_NAME = "en_US.UTF-8";
    LC_NUMERIC = "en_US.UTF-8";
    LC_PAPER = "en_US.UTF-8";
    LC_TELEPHONE = "en_US.UTF-8";
    LC_TIME = "en_US.UTF-8";
  };

  # Enable the GNOME display manager
  services.displayManager.gdm.enable = true;
  services.displayManager.gdm.wayland = true;
  services.gnome.evolution-data-server.enable = true;

  # A keyring is used by VSCode
  # services.gnome.gnome-keyring.enable = true;

  # Enable sound with pipewire.
  services.pulseaudio.enable = false;
  security.rtkit.enable = true; # Enabling rtkit is recommended for audio performance. See https://wiki.nixos.org/wiki/PipeWire
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    # If you want to use JACK applications, uncomment this
    #jack.enable = true;

    # Prefer LDAC for highest quality audio performance where possible. This is necessary to get decent behavior out of WH-1000XM5s.
    wireplumber.configPackages = [
      (pkgs.writeTextDir "share/wireplumber/bluetooth.lua.d/51-bluez-config.lua" ''
        bluez_monitor.properties = {
          ["bluez5.enable-sbc-xq"] = true,
          ["bluez5.enable-msbc"] = true,
          ["bluez5.enable-hw-volume"] = true,
          ["bluez5.headset-roles"] = "[ hsp_hs hsp_ag hfp_hf hfp_ag ]",
          ["bluez5.codecs"] = "[ sbc sbc_xq aac ldac ]",
          ["bluez5.default.rate"] = 48000,
          ["bluez5.default.channels"] = 2,
        }
      '')
    ];
  };

  # Bluetooth
  hardware.bluetooth.enable = true;
  hardware.bluetooth.powerOnBoot = true;
  services.blueman.enable = true;

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
  powerManagement.enable = true; # enable hibernation

  # Power management - prevent file system corruption from sudden battery death
  # When battery hits 3%, the system will hibernate (save RAM to disk)
  services.upower = {
    enable = true;
    percentageLow = 15; # Warn at 15%
    percentageCritical = 5; # Critical at 5%
    percentageAction = 3; # Take action at 3%
    criticalPowerAction = "Hibernate"; # Hibernate when battery hits 3%
  };

  # HibernateDelaySec: When using "suspend-then-hibernate", stay suspended for 30m before hibernating
  systemd.sleep.extraConfig = ''
    HibernateDelaySec=30m
  '';

  services.logind.settings.Login.HandleLidSwitch = "suspend-then-hibernate";

  ### End battery, swap, and hibernation

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
  nix.gc.automatic = true;

  users.mutableUsers = false;
  users.users.skainswo = {
    isNormalUser = true;
    description = "samuel ainsworth";
    extraGroups = [
      "networkmanager"
      "wheel"
    ];
    hashedPassword = pkgs.lib.strings.trim (builtins.readFile ./secrets/skainswo-password.hash);
    shell = pkgs.fish; # See https://discourse.nixos.org/t/how-to-get-vscodes-retry-as-sudo-to-work-on-nixos/68450/5?u=samuela
  };
  programs.fish.enable = true; # Necessary in order to use shell = pkgs.fish

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # services.physlock.enable = true; See https://github.com/NixOS/nixpkgs/issues/473175

  # See https://nixos.wiki/wiki/Steam.
  programs.xwayland.enable = true; # https://github.com/ValveSoftware/steam-for-linux/issues/4924
  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true; # Open ports in the firewall for Steam Remote Play
    dedicatedServer.openFirewall = true; # Open ports in the firewall for Source Dedicated Server
    localNetworkGameTransfers.openFirewall = true; # Open ports in the firewall for Steam Local Network Game Transfers
  };

  services.tailscale.enable = true;
  services.resolved = {
    enable = true; # https://github.com/tailscale/tailscale/issues/4254
    fallbackDns = [ ];
    domains = [ "~." ];
  };
  # NETGEAR R6700v2 times out on AAAA lookups, so we manually override DNS config.
  networking.nameservers = [
    "1.1.1.1"
    "9.9.9.9"
  ];
  networking.networkmanager.dns = "systemd-resolved";
  networking.useNetworkd = false; # ChatGPT suggested this line is also necessary, and it seems to work for now.

  # Enable Avahi for network service discovery (needed for Chromecast/AirPlay/Miracast)
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    nssmdns6 = true;
    openFirewall = true;
    publish = {
      enable = true;
      addresses = true;
      workstation = true;
      userServices = true;
    };
  };

  # Open firewall ports for Chromecast
  networking.firewall.allowedTCPPorts = [ 8009 ];

  home-manager.useGlobalPkgs = true;
  home-manager.users.skainswo =
    { pkgs, ... }:
    let
      shellAliases = {
        e = "code";
        ga = "git add";
        gc = "git commit -m";
        gd = "git diff";
        gs = "git status";
        ls = "eza --icons=always";
        nd = "nix develop";
        nixpkgs-version = "nix-instantiate --eval -E '(import <nixpkgs> {}).lib.version'";
        ns = "nix-shell";
        o = "xdg-open";
      };
      smart-suspend = pkgs.writeScript "smart-suspend" ''
        #!${pkgs.fish}/bin/fish

        function log
          printf '%s\n' $argv >&2
        end

        log "start"

        # Avoid suspending while plugged into power (any line_power device online).
        set line_powers (${pkgs.upower}/bin/upower -e | string match "*line_power*")
        log "line_power devices: $line_powers"
        for lp in $line_powers
          if test -n "$lp"
            if ${pkgs.upower}/bin/upower -i $lp | string match -q "*online: *yes*"
              log "skip suspend: power online via $lp"
              exit 0
            end
            log "power offline via $lp"
          end
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

        log "suspend-then-hibernate in 5s"
        sleep 5
        exec ${pkgs.systemd}/bin/systemctl suspend-then-hibernate
      '';
    in
    {
      imports = [ noctaliaHomeModule ];

      # Necessary for pkexec to work in VSCode, esp. "Retry as Sudo". See https://nixos.wiki/wiki/Polkit#Authentication_agents.
      systemd.user.services.polkit-gnome-authentication-agent-1 = {
        Unit = {
          Description = "polkit-gnome-authentication-agent-1";
          Wants = [ "graphical-session.target" ];
          After = [ "graphical-session.target" ];
        };
        Install = {
          WantedBy = [ "graphical-session.target" ];
        };
        Service = {
          Type = "simple";
          ExecStart = "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1";
          Restart = "on-failure";
          RestartSec = 1;
          TimeoutStopSec = 10;
        };
      };

      home.packages = with pkgs; [
        # See https://github.com/NixOS/nixpkgs/issues/436326#issuecomment-3217889408
        unstable-pkgs.claude-code
        unstable-pkgs.codex
        unstable-pkgs.gemini-cli
        unstable-pkgs.gurk-rs # Using unstable due to https://github.com/boxdot/gurk-rs/issues/462
        unstable-pkgs.mkchromecast
        unstable-pkgs.vscode
        # unstable-pkgs.crush # https://github.com/NixOS/nixpkgs/issues/470068

        chromium
        clang # many rust libs require having a `cc`
        elan
        impala
        jq
        nautilus # See https://github.com/YaLTeR/niri/issues/1863
        nixfmt-rfc-style # used by the Nix IDE VSCode extension
        obsidian
        kdePackages.okular
        pkg-config # many rust libs require having `pkg-config`
        rustup
        signal-desktop
        spotify # doesn't seem to work?
        swaybg # used in spawn-at-startup by niri config
        swayosd # used in keyboard bindings in niri config. for some reason services.swayosd doesn't add it to PATH
        walker # see services.walker below
        xwayland-satellite # For steam and other X11 applications. See https://discourse.nixos.org/t/how-to-do-xwayland-on-nixos/57825/11?u=samuela.
      ]
      # used by rust-analyzer vsocde extension
      # ++ [
      #   cargo
      #   rustc
      #   rustfmt
      # ];
      ;

      # Link smart-suspend for manual debugging. Note that this is not in PATH.
      home.file.".local/bin/smart-suspend".source = smart-suspend;

      xdg.desktopEntries.gurk = {
        name = "Gurk";
        genericName = "Signal Client (gurk)";
        exec = "gurk";
        terminal = true;
        categories = [
          "Utility"
          "Network"
          "Chat"
        ];
      };

      home.sessionVariables = {
        PAGER = "less -FE"; # For some reason this would be cat otherwise
        EDITOR = "nvim";
      };

      home.pointerCursor = {
        gtk.enable = true; # Ensure Wayland clients pick up the cursor theme.
        package = pkgs.apple-cursor;
        name = "macOS";
        size = 22;
      };

      programs.alacritty = {
        enable = true;
        settings = {
          window = {
            blur = true;
            decorations = "none";
          };
        };
      };
      programs.bat.enable = true;
      programs.eza.enable = true;
      programs.eza.enableZshIntegration = true;
      programs.firefox.enable = true;
      programs.fish = {
        enable = true;
        inherit shellAliases;
      };
      programs.noctalia-shell = {
        enable = true;
        package = noctaliaPackage;
        systemd.enable = true;
        systemd.mutableRuntimeSettings = true; # https://github.com/noctalia-dev/noctalia-shell/pull/1324
      };
      # programs.fuzzel.enable = true;
      programs.fzf.enable = true;
      programs.fzf.enableZshIntegration = true;
      programs.gh.enable = true;
      programs.ghostty = {
        enable = true;
        enableZshIntegration = true;
        systemd.enable = true;
      };
      programs.git = {
        enable = true;
        settings.user.email = "skainsworth@gmail.com";
        settings.user.name = "Samuel Ainsworth";
      };
      programs.htop.enable = true;
      programs.jujutsu = {
        enable = true;
        settings.user = {
          name = "Samuel Ainsworth";
          email = "skainsworth@gmail.com";
        };
      };
      programs.neovim.enable = true;
      # programs.obsidian.enable = true; # This will eventually work but the commit hasn't hit the release yet.
      programs.ripgrep.enable = true;
      programs.starship.enable = true;
      # programs.swaylock.enable = true;
      # programs.swaylock.package = pkgs.swaylock-effects;
      programs.tmux.enable = true;
      programs.vicinae = {
        enable = true;
        systemd.enable = true;
      };
      programs.wezterm.enable = true;
      programs.yazi.enable = true;
      programs.zoxide.enable = true;
      programs.zsh = {
        enable = true;
        inherit shellAliases;
        autosuggestion.enable = true;
        syntaxHighlighting.enable = true;
        history = {
          expireDuplicatesFirst = true;
          extended = true;
          ignoreDups = true;
          ignoreSpace = true;
          share = true;
        };
      };

      xdg.mimeApps.enable = true;
      xdg.mimeApps.defaultApplications = {
        "text/html" = "app.zen_browser.zen.desktop";
        "x-scheme-handler/http" = "app.zen_browser.zen.desktop";
        "x-scheme-handler/https" = "app.zen_browser.zen.desktop";
        "x-scheme-handler/about" = "app.zen_browser.zen.desktop";
        "x-scheme-handler/unknown" = "app.zen_browser.zen.desktop";
        "x-scheme-handler/sgnl" = "signal.desktop";
        "x-scheme-handler/signalcaptcha" = "signal.desktop";
      };

      services.swayosd.enable = true;
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
      # Available on master but not yet on release-25.05 branch as of 2025-08-23.
      # services.walker.enable = true;

      # The state version is required and should stay at the version you
      # originally installed.
      home.stateVersion = "24.11";
    };

  # Enable the OpenSSH daemon.
  # services.openssh.enable = true;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "24.11"; # Did you read the comment?
}
