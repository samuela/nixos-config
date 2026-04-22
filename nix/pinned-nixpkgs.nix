# Top-level nixpkgs pin used by rebuild.sh.
# Tracking the `nixos-25.11` channel.
# Refresh `rev` with:
#   curl -s 'https://status.nixos.org/prometheus/api/v1/query?query=channel_revision' \
#     | jq -r '.data.result[] | select(.metric.channel=="nixos-25.11" and .metric.current=="1") | .metric.revision'
# Last updated: 2026-04-22.
let
  rev = "c7f47036d3df2add644c46d712d14262b7d86c0c";
in
{
  inherit rev;
  sha256 = "1aclyh8aysw0d8gb1k9hh7mcklkqfvvv4f86l9zcipi4r0s9fal3";
  url = "https://github.com/NixOS/nixpkgs/archive/${rev}.tar.gz";
}
