# Shared core configuration for all hosts.
# Host-specific configuration should import this module.
{ config, pkgs, ... }:

let
  # Tracking release-25.11 branch. Last updated 2026-01-26
  home-manager = builtins.fetchTarball "https://github.com/nix-community/home-manager/archive/75ed713570ca17427119e7e204ab3590cc3bf2a5.tar.gz";

  # Tracking release-25.11 branch. Last updated 2025-01-15
  stylix = builtins.fetchTarball "https://github.com/nix-community/stylix/archive/362306faaa7459bebf8eabf135879785f3da9bd2.tar.gz";

  # Tracking https://github.com/noctalia-dev/noctalia-shell/commits/main. Last updated 2025-01-12
  noctaliaSrc = builtins.fetchTarball "https://github.com/noctalia-dev/noctalia-shell/archive/2b55ae2c348fcad50089bc334c4a8155b2941d3b.tar.gz";
  # noctaliaSrc = ../noctalia-shell;
  noctaliaPackage = pkgs.callPackage "${noctaliaSrc}/nix/package.nix" { };
  noctaliaHomeModule = import "${noctaliaSrc}/nix/home-module.nix";

  # Tracking nixpkgs-unstable channel (as shown on status.nixos.org). Last updated 2026-04-06.
  # Update by running:
  #   curl -s 'https://status.nixos.org/prometheus/api/v1/query?query=channel_revision' \
  #     | jq -r '.data.result[] | select(.metric.channel=="nixpkgs-unstable" and .metric.current=="1") | .metric.revision'
  # and substituting the result into this tarball URL.
  unstable-nixpkgs-src = builtins.fetchTarball "https://github.com/NixOS/nixpkgs/archive/5e11f7acce6c3469bef9df154d78534fa7ae8b6c.tar.gz";

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
    (import "${home-manager}/nixos")
  ];

  # Bootloader.
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.systemd-boot.enable = true;
  boot.loader.timeout = 1;

  # See https://github.com/NixOS/nixos-hardware/tree/master/framework/13-inch/7040-amd#updating-firmware
  # Use `fwupdmgr update` to update firmware.
  services.fwupd.enable = true;

  security.polkit.enable = true;

  programs.niri.enable = true;
  services.flatpak.enable = true;

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

  # Power management
  powerManagement.enable = true;
  services.upower.enable = true; # needed for noctalia battery widget

  # nixbuild.net remote builder
  programs.ssh.extraConfig = ''
    Host eu.nixbuild.net
      PubkeyAcceptedKeyTypes ssh-ed25519
      ServerAliveInterval 60
      IPQoS throughput
      IdentityFile /home/skainswo/.ssh/id_ed25519
  '';
  programs.ssh.knownHosts = {
    nixbuild = {
      hostNames = [ "eu.nixbuild.net" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPIQCZc54poJ8vqawd8TraNryQeJnvH1eLpIDgbiqymM";
    };
  };
  nix.distributedBuilds = true;
  nix.buildMachines = [
    {
      hostName = "eu.nixbuild.net";
      system = "x86_64-linux";
      maxJobs = 100;
      supportedFeatures = [ "benchmark" "big-parallel" ];
    }
  ];
  nix.settings.builders-use-substitutes = true;

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
    "dynamic-derivations"
    "ca-derivations"
    "recursive-nix"
  ];
  nix.gc.automatic = true;

  users.mutableUsers = false;
  users.users.skainswo = {
    isNormalUser = true;
    description = "samuel ainsworth";
    extraGroups = [
      "docker"
      "networkmanager"
      "wheel"
    ];
    hashedPassword = pkgs.lib.strings.trim (builtins.readFile ../secrets/skainswo-password.hash);
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

  virtualisation.docker.enable = true;

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
    in
    {
      imports = [
        noctaliaHomeModule
        (import stylix).homeModules.stylix
      ];

      stylix.enable = true;
      stylix.image = ../Wallpapers/john-towner-JgOeRuGD_Y4-unsplash.jpg;
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
        # Note: In some cases it is necessary to run `fc-cache -f` to refresh
        # the font cache. This should be handled by nixos-rebuild switch, but as
        # 2026-01-21 this is not always the case.
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
        comma
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
      # https://github.com/noctalia-dev/noctalia-shell/pull/1324#issuecomment-3752738837
      stylix.targets.noctalia-shell.enable = false; # https://github.com/noctalia-dev/noctalia-shell/pull/1324#issuecomment-3747399960

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
      programs.btop.enable = true;
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
      programs.starship = {
        enable = true;
        settings.custom.kernel_mismatch = {
          command = "echo '⚠ kernel mismatch - hibernate disabled'";
          when = ''test "$(${pkgs.coreutils}/bin/readlink -f /run/booted-system/kernel)" != "$(${pkgs.coreutils}/bin/readlink -f /run/current-system/kernel)"'';
          format = "[$output]($style) ";
          style = "bold yellow";
        };
      };
      # programs.swaylock.enable = true;
      # programs.swaylock.package = pkgs.swaylock-effects;
      programs.tmux = {
        enable = true;
        prefix = "C-a";
        extraConfig = ''
          # Enable mouse mode for scrolling and automatic copy mode entry
          set -g mouse on

          # Navigate through windows with Ctrl-PageDown and Ctrl-PageUp
          bind-key -n C-PageDown next-window
          bind-key -n C-PageUp previous-window
        '';
      };

      programs.vicinae = {
        enable = true;
        systemd.enable = true;
      };
      stylix.targets.vicinae.enable = false;

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
      # Available on master but not yet on release-25.05 branch as of 2025-08-23.
      # services.walker.enable = true;

      # The state version is required and should stay at the version you
      # originally installed.
      home.stateVersion = "24.11";
    };

  # Enable the OpenSSH daemon.
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "24.11"; # Did you read the comment?
}
