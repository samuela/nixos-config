#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

nixos-rebuild -I nixos-config="$repo_root/configuration.nix" "$@"
