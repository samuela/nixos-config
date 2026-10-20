# Top-level nixpkgs pin used by rebuild.sh.
# Tracking the `nixos-26.05` channel.
# Refresh `rev` with:
#   curl -s 'https://status.nixos.org/prometheus/api/v1/query?query=channel_revision' \
#     | jq -r '.data.result[] | select(.metric.channel=="nixos-26.05" and .metric.current=="1") | .metric.revision'
# Last updated: 2026-10-02.
# When bumping this pin, update this date and recompute the unpacked tarball
# hash with `nix-prefetch-url --unpack`.
let
  rev = "774debe7a0d1b496e35677ad955a1011c6ff74f3";
in
{
  inherit rev;
  sha256 = "1japvhk1jlgc8sihm9gczwnv6fjanqsr1ji57vx67wbvqj88a34x";
  url = "https://github.com/NixOS/nixpkgs/archive/${rev}.tar.gz";
}
