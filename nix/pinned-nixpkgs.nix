# Top-level nixpkgs pin used by rebuild.sh.
# Tracking the `nixos-25.11` channel.
# Refresh `rev` with:
#   curl -s 'https://status.nixos.org/prometheus/api/v1/query?query=channel_revision' \
#     | jq -r '.data.result[] | select(.metric.channel=="nixos-25.11" and .metric.current=="1") | .metric.revision'
# Last updated: 2026-04-22.
# When bumping this pin, update this date too.
let
  rev = "10e7ad5bbcb421fe07e3a4ad53a634b0cd57ffac";
in
{
  inherit rev;
  sha256 = "0x1ip9whw4djx0vlzyqagfifbq3v2m1s11yv4bn0rrj4369dspdy";
  url = "https://github.com/NixOS/nixpkgs/archive/${rev}.tar.gz";
}
