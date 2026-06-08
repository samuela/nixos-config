# nixos-config

Personal NixOS configuration. Secrets stay untracked in `secrets/`.

`Wallpapers/` is intended to be symlinked into `~/Pictures/Wallpapers` for compatbility with noctalia. Some config files are in `.config/` which maps to `~/.config/` and should be symlinked as follows:

```
ln -s /home/skainswo/dev/nixos-config/Wallpapers ~/Pictures/Wallpapers
ln -s /home/skainswo/dev/nixos-config/.config/niri/config.kdl ~/.config/niri/config.kdl
ln -s /home/skainswo/dev/nixos-config/.config/noctalia/plugins.json ~/.config/noctalia/plugins.json
ln -s /home/skainswo/dev/nixos-config/.config/noctalia/settings.json ~/.config/noctalia/settings.json
ln -s /home/skainswo/dev/nixos-config/.config/vicinae/vicinae.json ~/.config/vicinae/vicinae.json
```

## Secrets

- `secrets/skainswo-password.hash`: hashed password for `users.users.skainswo`; keep mode 600. Regenerate with `mkpasswd -m sha-512 > secrets/skainswo-password.hash`.

### Restic backup credentials (placed manually per host)

Not stored in this repo. Place them by hand on each host that imports `modules/restic-backup.nix`:

```
sudo install -d -m 0700 -o root -g root /etc/restic
# Restic repo password. KEEP A COPY OFFLINE (password manager, paper) — if this
# is lost the offsite backups cannot be decrypted.
openssl rand -base64 48 | sudo install -m 0600 -o root -g root /dev/stdin /etc/restic/password
# Backblaze B2 credentials. Use a bucket-scoped application key, NOT the master key.
sudo install -m 0600 -o root -g root /dev/stdin /etc/restic/b2-env <<'EOF'
B2_ACCOUNT_ID=<keyID>
B2_ACCOUNT_KEY=<applicationKey>
EOF
```

The `restic-backups-<hostname>.service` unit will fail until both files exist.

## Deploy

- Rebuild from this repo: `./rebuild.sh switch` (uses `-I nixos-config` for the selected host config and `-I nixpkgs` from `nix/pinned-nixpkgs.nix`, so it does not depend on the root `nix-channel`).
- Update the top-level `nixpkgs` pin by changing `rev` and `sha256` in `nix/pinned-nixpkgs.nix`. To compute the new hash for a revision, run `nix-prefetch-url --unpack https://github.com/NixOS/nixpkgs/archive/<rev>.tar.gz` and copy the resulting hash into `sha256`.
