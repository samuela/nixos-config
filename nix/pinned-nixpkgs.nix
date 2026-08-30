# Top-level nixpkgs pin used by rebuild.sh.
# Tracking the `nixos-26.05` channel.
# Refresh `rev` with:
#   curl -s 'https://status.nixos.org/prometheus/api/v1/query?query=channel_revision' \
#     | jq -r '.data.result[] | select(.metric.channel=="nixos-26.05" and .metric.current=="1") | .metric.revision'
# Last updated: 2026-08-30.
# When bumping this pin, update this date and recompute the unpacked tarball
# hash with `nix-prefetch-url --unpack`.
let
  rev = "c5c4a43b0e8056328ec4529f735cabdb8f1942bb";
in
{
  inherit rev;
  sha256 = "0miz2qn3lamkpqyjbfmz93h4icr323ds7l218vvsgq206razvb5v";
  url = "https://github.com/NixOS/nixpkgs/archive/${rev}.tar.gz";
}
