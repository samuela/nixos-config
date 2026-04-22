#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
nixpkgs_pin_expr="$repo_root/nix/pinned-nixpkgs-path.nix"

# Use NIXOS_HOST env var if set, otherwise detect from hostname
hostname="${NIXOS_HOST:-$(hostname)}"
host_config="$repo_root/hosts/$hostname/configuration.nix"

if [[ ! -f "$host_config" ]]; then
  echo "Error: No configuration found for host '$hostname'" >&2
  echo "Expected: $host_config" >&2
  echo "Available hosts:" >&2
  ls -1 "$repo_root/hosts/" >&2
  echo "" >&2
  echo "Hint: Set NIXOS_HOST=<hostname> to override" >&2
  exit 1
fi

# Resolve the pinned nixpkgs tarball to a store path so rebuilds do not depend
# on the ambient root channel / default NIX_PATH.
nixpkgs_path="$(nix eval --raw --file "$nixpkgs_pin_expr")"

nixos-rebuild \
  -I nixpkgs="$nixpkgs_path" \
  -I nixos-config="$host_config" \
  "$@"
