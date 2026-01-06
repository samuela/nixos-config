#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

sudo nixos-rebuild switch -I nixos-config="$repo_root/configuration.nix" "$@"
