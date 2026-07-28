# Shared core configuration for all hosts.
# Host-specific configuration should import this module.
{ config, pkgs, ... }:

let
  # Tracking release-26.05 branch. Last updated 2026-06-05
  home-manager = builtins.fetchTarball "https://github.com/nix-community/home-manager/archive/e28654b71096e08c019d4861ca26acb646f583d8.tar.gz";

  # Tracking release-26.05 branch. Last updated 2026-06-05
  stylix = builtins.fetchTarball "https://github.com/nix-community/stylix/archive/aacc65706d523528aed81f55c2c780aaeb541d55.tar.gz";

  # Tracking https://github.com/noctalia-dev/noctalia-shell/commits/main. Last updated 2025-01-12
  noctaliaSrc = builtins.fetchTarball "https://github.com/noctalia-dev/noctalia-shell/archive/2b55ae2c348fcad50089bc334c4a8155b2941d3b.tar.gz";
  # noctaliaSrc = ../noctalia-shell;
  noctaliaPackage = pkgs.callPackage "${noctaliaSrc}/nix/package.nix" { };
  noctaliaHomeModule = import "${noctaliaSrc}/nix/home-module.nix";

  # Tracking nixpkgs master branch. Last updated 2026-07-26.
  unstable-nixpkgs-src = builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/d7949fe81b1240d2452fef4b67aeda455f00cd25.tar.gz";
    sha256 = "sha256-l5FmH6o98w3jm8zre0UT1cjGDMudhtPq5KbNbLkiVgU=";
  };

  unstable-nixpkgs-patched = pkgs.applyPatches {
    name = "nixpkgs-master-with-openclaw-2026.7.1";
    src = unstable-nixpkgs-src;
    patches = [
      # Nixpkgs currently carries 2026.6.33; package the latest stable release.
      # Drop once nixpkgs updates OpenClaw to 2026.7.1 or newer.
      (pkgs.writeText "openclaw-2026.7.1.patch" ''
        --- a/pkgs/by-name/op/openclaw/package.nix
        +++ b/pkgs/by-name/op/openclaw/package.nix
        @@ -13 +13 @@
        -  version ? "2026.6.33",
        +  version ? "2026.7.1",
        @@ -26 +26 @@
        -    hash = "sha256-OdH5olBLDGQYCtR2ElbzcQ2+Hgy3cZDixkIwmSPh9Xw=";
        +    hash = "sha256-37LZ10P+XGzfU3KVpRhfEElYscoUlE+zi85hmvicjLI=";
        @@ -29 +29 @@
        -  pnpmDepsHash = "sha256-eVyR8SVp0SyjflFomvgn9dgAqvXIUgjCYc5NICxxIg8=";
        +  pnpmDepsHash = "sha256-/ou2Hoix9m/be6kq4Osg4gTTQQRTkL5uLOuERmevuQ0=";
        @@ -77 +77,3 @@
             cp --reflink=auto -r package.json dist node_modules $libdir/
        +    mkdir -p $libdir/packages
        +    cp --reflink=auto -r packages/ai $libdir/packages/
      '')
    ];
  };

  unstable-pkgs = import unstable-nixpkgs-patched {
    config.allowUnfree = true;
  };

  tmuxAgentStatus = pkgs.writeShellApplication {
    name = "tmux-agent-status";
    runtimeInputs = with pkgs; [
      gnugrep
      tmux
    ];
    text = ''
      pane_id="''${1:-}"

      if [ -z "$pane_id" ]; then
        exit 0
      fi

      pane_command="$(tmux display-message -p -t "$pane_id" '#{pane_current_command}' 2>/dev/null || true)"
      if [ "$pane_command" != "codex" ]; then
        exit 0
      fi

      pane_title="$(tmux display-message -p -t "$pane_id" '#{pane_title}' 2>/dev/null || true)"

      case "$pane_title" in
        ⠋*|⠙*|⠹*|⠸*|⠼*|⠴*|⠦*|⠧*|⠇*|⠏*)
          printf '#[fg=green]●#[default]'
          exit 0
          ;;
      esac

      bottom_text="$(tmux capture-pane -p -t "$pane_id" -S -8 2>/dev/null || true)"
      last_nonempty=""
      while IFS= read -r line; do
        if [ -n "$line" ]; then
          last_nonempty="$line"
        fi
      done < <(printf '%s\n' "$bottom_text")

      case "$last_nonempty" in
        "› "*)
          printf '#[fg=cyan]?#[default]'
          exit 0
          ;;
      esac

      if printf '%s\n' "$bottom_text" | grep -Eiq 'Would you like to run the following command|Press enter to confirm or esc to cancel|^› 1\. Yes, proceed'; then
        printf '#[fg=yellow]!#[default]'
      else
        printf '#[fg=cyan]?#[default]'
      fi
    '';
  };

  # Includes Supreeeme/xwayland-satellite#387, which fixes a panic when all
  # outputs are disconnected. Without this, niri's xwayland-satellite exits
  # with status 101 on lid-close/no-output transitions and kills X11 clients.
  xwayland-satellite-fixed = pkgs.xwayland-satellite.overrideAttrs (
    finalAttrs: _old: {
      version = "0.8.1-unstable-2026-06-12";
      src = pkgs.fetchFromGitHub {
        owner = "Supreeeme";
        repo = "xwayland-satellite";
        rev = "8575d0ef55d70f9b4c46b6bffb3accf912217e1e";
        hash = "sha256-28696iIw8uE0ZUyFTtzhEM8xMh85clCYypMxkvUi+sc=";
      };
      cargoHash = "sha256-jbEihJYcOwFeDiMYlOtaS8GlunvSze80iWahDj1qDrs=";
      cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
        inherit (finalAttrs) pname version src;
        hash = finalAttrs.cargoHash;
      };
    }
  );
in
{
  _module.args.unstableNixpkgsSrc = unstable-nixpkgs-patched;
  _module.args.unstablePkgs = unstable-pkgs;

  imports = [
    (import "${home-manager}/nixos")
  ];

  # Bootloader.
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.systemd-boot.enable = true;
  boot.loader.timeout = 1;

  # Keep fwupd available for explicit firmware maintenance, but do not run the
  # metadata refresh timer automatically. The timer runs `fwupdmgr refresh` as
  # the fwupd-refresh service user; with fwupd 2.1.4 that non-interactive
  # refresh can fail Polkit auth for org.freedesktop.fwupd.refresh-remote and
  # leave fwupd-refresh.service failed, which then breaks rebuild switching.
  # See https://github.com/NixOS/nixpkgs/issues/530906.
  # Mask the timer and its oneshot service; manual fwupdmgr use does not need
  # either unit.
  services.fwupd.enable = true;
  systemd.services.fwupd-refresh.enable = false;
  systemd.timers.fwupd-refresh.enable = false;

  security.polkit.enable = true;

  programs.niri.enable = true;
  # GDM defaults to "gnome-session" when no session is selected and the
  # user's AccountsService record doesn't pin one; on this host that just
  # produces a login loop (no GNOME installed). Pin niri explicitly.
  services.displayManager.defaultSession = "niri";
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
      supportedFeatures = [
        "benchmark"
        "big-parallel"
      ];
    }
  ];
  nix.settings.builders-use-substitutes = true;

  nix.settings.extra-substituters = [
    "https://cache.nixos-cuda.org"
    "https://ploop.cachix.org"
  ];
  nix.settings.extra-trusted-public-keys = [
    "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M="
    "ploop.cachix.org-1:i6+Fqarsbf5swqH09RXOEDvxy7Wm7vbiIXu4A9HCg1g="
  ];

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
    settings.Resolve = {
      FallbackDNS = [ ];
      Domains = [ "~." ];
    };
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
  # Let HM back up (rather than abort on) pre-existing files it wants to manage,
  # e.g. an existing ~/.mozilla/firefox/profiles.ini -> profiles.ini.hm-bak.
  home-manager.backupFileExtension = "hm-bak";
  home-manager.users.skainswo =
    { pkgs, config, ... }:
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
      # `home-manager.useGlobalPkgs = true` causes hm-level `nixpkgs.overlays`
      # to be ignored anyway, so stylix's overlay-based package patching is a
      # no-op. Disable it explicitly to silence the hm warning.
      stylix.overlays.enable = false;
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

        brave

        chromium
        clang # many rust libs require having a `cc`
        comma
        elan
        impala
        jq
        nautilus # See https://github.com/YaLTeR/niri/issues/1863
        nixfmt # used by the Nix IDE VSCode extension
        nodejs # Vicinae local extensions require a Node runtime.
        obsidian
        kdePackages.okular
        pkg-config # many rust libs require having `pkg-config`
        rustup
        unstable-pkgs.signal-desktop
        spotify # doesn't seem to work?
        swaybg # used in spawn-at-startup by niri config
        swayosd # used in keyboard bindings in niri config. for some reason services.swayosd doesn't add it to PATH
        walker # see services.walker below
        xwayland-satellite-fixed # For steam and other X11 applications. See https://discourse.nixos.org/t/how-to-do-xwayland-on-nixos/57825/11?u=samuela.
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
      programs.firefox = {
        enable = true;
        # Keep the legacy path; migrating would require moving ~/.mozilla/firefox.
        configPath = ".mozilla/firefox";
        # Use the fixed `default` path (not a host-specific random name like
        # `unf7mjew.default`) so this profile config is portable across hosts.
        # NOTE: home-manager does NOT migrate an existing profile here -- it just
        # writes profiles.ini + declarative bits into ~/.mozilla/firefox/default.
        # On each host with a pre-existing Firefox profile, you must manually
        # `mv ~/.mozilla/firefox/<random>.default ~/.mozilla/firefox/default`
        # (with Firefox closed) once, or that host gets a blank profile.
        profiles.default.isDefault = true;
      };
      stylix.targets.firefox.profileNames = [ "default" ];
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
        # gitFull builds git-send-email with the SMTP/TLS Perl modules
        # (IO::Socket::SSL, Authen::SASL) that plain pkgs.git omits.
        package = pkgs.gitFull;
        settings.user.email = "skainsworth@gmail.com";
        settings.user.name = "Samuel Ainsworth";
        # Outgoing mail for `git send-email` (e.g. kernel patches). The SMTP
        # password is deliberately not stored here -- git prompts for it (use a
        # Gmail App Password). https://myaccount.google.com/apppasswords
        settings.sendemail = {
          smtpServer = "smtp.gmail.com";
          smtpServerPort = 587;
          smtpEncryption = "tls";
          smtpUser = "skainsworth@gmail.com";
        };
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
      programs.neovim.withRuby = false;
      programs.neovim.withPython3 = false;
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

          # Show compact per-window Codex state indicators:
          # green dot = working, cyan ? = waiting for prompt, yellow ! = waiting for approval.
          set -g status-interval 2
          set -g window-status-format "#I:#W#{?window_flags,#{window_flags}, }#(${tmuxAgentStatus}/bin/tmux-agent-status #{pane_id})  "
          set -g window-status-current-format "#I:#W#{?window_flags,#{window_flags}, }#(${tmuxAgentStatus}/bin/tmux-agent-status #{pane_id})  "
        '';
      };

      programs.vicinae = {
        enable = true;
        # Override the release-channel package because it lags upstream and
        # misses newer Vicinae features like script commands.
        package = unstable-pkgs.vicinae;
        systemd.enable = true;
      };
      stylix.targets.vicinae.enable = false;
      # Install a small local extension instead of relying on fallback
      # shortcuts, which always see the full root query and compete with other
      # fallback commands like Google search.
      home.file.".local/share/vicinae/extensions/ai-prefixes/package.json".source =
        ../.config/vicinae/extensions/ai-prefixes/package.json;
      home.file.".local/share/vicinae/extensions/ai-prefixes/ask.js".source =
        ../.config/vicinae/extensions/ai-prefixes/ask.js;
      home.file.".local/share/vicinae/extensions/ai-prefixes/chatgpt.js".source =
        ../.config/vicinae/extensions/ai-prefixes/chatgpt.js;
      home.file.".local/share/vicinae/extensions/ai-prefixes/gemini.js".source =
        ../.config/vicinae/extensions/ai-prefixes/gemini.js;
      # Keep the `cl` alias declarative without taking ownership of the main
      # GUI-managed Vicinae settings file.
      home.file.".config/vicinae/overrides/ai-prefixes.jsonc".source =
        ../.config/vicinae/overrides/ai-prefixes.jsonc;
      systemd.user.services.vicinae.Service.Environment = [
        "VICINAE_OVERRIDES=${config.home.homeDirectory}/.config/vicinae/overrides/ai-prefixes.jsonc"
      ];

      programs.wezterm.enable = true;
      programs.yazi.enable = true;
      programs.yazi.shellWrapperName = "y";
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
