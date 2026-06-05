# Top-level nixpkgs pin used by rebuild.sh.
# Tracking the `nixos-26.05` channel.
# Refresh `rev` with:
#   curl -s 'https://status.nixos.org/prometheus/api/v1/query?query=channel_revision' \
#     | jq -r '.data.result[] | select(.metric.channel=="nixos-26.05" and .metric.current=="1") | .metric.revision'
# Last updated: 2026-06-05.
# When bumping this pin, update this date too.
#
# 2026-06-05: temporarily pinned to release-26.05 HEAD (not the channel's
# current snapshot) to pick up the backport of NixOS/nixpkgs#523948 which
# fixes GDM 50 sessions failing to launch on NixOS (login loop) — the
# channel snapshot is 49 commits behind that fix. Switch back to the
# channel revision the next time the channel ticks past 7fdb15681cb.
let
  rev = "35d351cdbd653bbe8f523b7fc6b901fc272ec75d";
in
{
  inherit rev;
  sha256 = "0viiyqc5m4ay9fr91yvg8qz5axk9vv28bvhmkalyvd3vbqa72ixs";
  url = "https://github.com/NixOS/nixpkgs/archive/${rev}.tar.gz";
}
