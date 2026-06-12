# Offsite encrypted backups to Backblaze B2 via restic.
#
# Secrets are placed manually on each host (see README for the exact commands):
#   /etc/restic/password   — restic repo password; KEEP A COPY OFFLINE.
#   /etc/restic/b2-env     — shell env file with B2_ACCOUNT_ID and B2_ACCOUNT_KEY.
# Both must be mode 0600, owned root:root. The backup unit will fail until they exist.
#
# Restore:
#   sudo restic -r b2:<bucket>:<hostname> --password-file /etc/restic/password snapshots
#   sudo restic -r b2:<bucket>:<hostname> --password-file /etc/restic/password restore <id> --target /tmp/restore
{ config, lib, pkgs, ... }:

let
  cfg = config.services.resticBackup;
  hostname = config.networking.hostName;
in
{
  options.services.resticBackup = {
    enable = lib.mkEnableOption "encrypted offsite backups to Backblaze B2";

    paths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "/home/skainswo"
        "/etc/NetworkManager/system-connections"
        "/var/lib/tailscale"
      ];
      description = "Paths to include in the backup.";
    };

    extraExcludes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional exclude patterns appended to the defaults.";
    };

    timerSpec = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* 03:00:00";
      description = "systemd OnCalendar spec for when the backup runs.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Make `restic` available for manual restores / inspection.
    environment.systemPackages = [ pkgs.restic ];

    services.restic.backups.${hostname} = {
      repository = "b2:skainswo-backups:${hostname}";

      passwordFile = "/etc/restic/password";
      environmentFile = "/etc/restic/b2-env";

      initialize = true;
      paths = cfg.paths;

      exclude = [
        # Build artifacts / package manager caches — large and reproducible.
        "**/node_modules"
        "**/target"           # Rust
        "**/rust-analyzer-target"  # rust-analyzer uses a separate target dir to avoid locking against cargo
        "**/.lake"            # Lean (Lake build tool)
        "**/.direnv"
        "**/.venv"
        "**/__pycache__"
        "**/.mypy_cache"
        "**/.pytest_cache"
        "**/.ruff_cache"
        "**/dist"
        "**/build"
        "**/.next"
        "**/.cargo/registry"
        "**/.rustup"
        "**/.elan/toolchains"   # Lean toolchain manager — re-installable
        "**/.npm"               # npm package cache
        "**/.bun"               # bun package cache
        "**/.vscode-server"     # re-downloads on connect
        "/home/*/.julia"        # Julia packages/artifacts/compiled — `Pkg.instantiate()` rebuilds

        # Per-user caches.
        "/home/*/.cache"
        "/home/*/.local/share/Trash"
        "/home/*/.var/app/*/cache"  # Flatpak per-app caches (Zen, etc.)

        # Browser caches (Firefox-family).
        "**/cache2"
        "**/startupCache"
        "**/shader-cache"
        "/home/*/.mozilla/firefox/*/storage/default/*/cache"
        "/home/*/.var/app/app.zen_browser.zen/.zen/*/storage/default/*/cache"

        # Browser caches (Chromium-family: Chrome, Brave, Edge, Chromium, Electron apps).
        "**/GPUCache"
        "**/Code Cache"
        "**/Service Worker/CacheStorage"
        "**/Service Worker/ScriptCache"
        "**/component_crx_cache"   # bundled component extensions (Widevine, recovery, etc.) — re-fetched
        "**/extensions_crx_cache"  # downloaded extension CRX cache — re-fetched
        "/home/*/.config/google-chrome/*/Cache"
        "/home/*/.config/BraveSoftware/*/Cache"
        "/home/*/.config/chromium/*/Cache"
        "/home/*/.config/Code/Cache*"
        "/home/*/.config/Code/WebStorage"
        "/home/*/.config/obsidian/Cache"

        # VSCode — extensions reinstall from marketplace; globalStorage holds large extension caches.
        "/home/*/.vscode/extensions"
        "/home/*/.config/Code/User/globalStorage"

        # AI agent cache-y stuff
        "**/.openclaw/browser"

        # Steam — game data, runtime libs, and client are all re-downloaded on first launch.
        # Per-user settings under userdata/ are mirrored to Steam Cloud by any game that cares.
        "/home/*/.local/share/Steam"

        # Vicinae local file-search index — rebuilt on first run.
        "/home/*/.local/share/vicinae/file-indexer.db*"

        # Upstream-clone .git histories — the working tree is backed up so any
        # local edits are preserved, but the .git/ history is re-derivable via
        # `git clone <upstream>`. To restore: clone fresh, then overlay the
        # backed-up working tree (rsync -a --exclude=.git restored/ fresh/).
        "/home/skainswo/dev/lean4/.git"
        "/home/skainswo/dev/nixpkgs/.git"
        "/home/skainswo/dev/jax/.git"

        # Docker — back up volumes separately if needed.
        "/var/lib/docker"

        # Nix / build outputs.
        "**/result"
        "**/result-*"
      ] ++ cfg.extraExcludes;

      # Retention: prune old snapshots after each successful backup.
      pruneOpts = [
        "--keep-daily 7"
        "--keep-weekly 4"
        "--keep-monthly 12"
        "--keep-yearly 3"
      ];

      # Run daily; spread the start time so all hosts don't hit B2 at once.
      timerConfig = {
        OnCalendar = cfg.timerSpec;
        RandomizedDelaySec = "1h";
        Persistent = true;
      };
    };

    # Ensure the directory exists with strict perms. The two secret files inside
    # are placed manually (see README) — not managed by Nix.
    systemd.tmpfiles.rules = [
      "d /etc/restic 0700 root root - -"
    ];
  };
}
