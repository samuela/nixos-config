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

## Deploy

- Rebuild from this repo: `./rebuild.sh switch` (uses `-I nixos-config` for the selected host config and `-I nixpkgs` from `nix/pinned-nixpkgs.nix`, so it does not depend on the root `nix-channel`).
- Update the top-level `nixpkgs` pin by changing `rev` and `sha256` in `nix/pinned-nixpkgs.nix`. To compute the new hash for a revision, run `nix-prefetch-url --unpack https://github.com/NixOS/nixpkgs/archive/<rev>.tar.gz` and copy the resulting hash into `sha256`.
