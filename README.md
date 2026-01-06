# nixos-config

Personal NixOS configuration. Secrets stay untracked in `secrets/`.

## Secrets

- `secrets/skainswo-password.hash`: hashed password for `users.users.skainswo`; keep mode 600. Regenerate with `mkpasswd -m sha-512 > secrets/skainswo-password.hash`.

## Deploy

- Rebuild from this repo: `./rebuild.sh` (uses `-I nixos-config` to point at `configuration.nix` here).
