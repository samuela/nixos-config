# Top-level nixpkgs pin used by rebuild.sh.
# Tracking the `nixos-26.05` channel.
# Refresh `rev` with:
#   curl -s 'https://status.nixos.org/prometheus/api/v1/query?query=channel_revision' \
#     | jq -r '.data.result[] | select(.metric.channel=="nixos-26.05" and .metric.current=="1") | .metric.revision'
# Last updated: 2026-06-05.
# When bumping this pin, update this date too.
let
  rev = "6b316287bae2ee04c9b93c8c858d930fd07d7338";
in
{
  inherit rev;
  sha256 = "0mpcj1cn2hl2z7w87z6qimwx14i4gb2c60mybj7p9c2ksmmi2wvd";
  url = "https://github.com/NixOS/nixpkgs/archive/${rev}.tar.gz";
}
