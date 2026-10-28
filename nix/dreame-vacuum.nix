{
  lib,
  callPackage,
  buildHomeAssistantComponent,
  fetchFromGitHub,
  home-assistant,
}:

let
  inherit (home-assistant) python3Packages;
  mini-racer = callPackage ./mini-racer.nix { inherit python3Packages; };
in
assert lib.versionAtLeast python3Packages.cryptography.version "45";
buildHomeAssistantComponent {
  owner = "Tasshack";
  domain = "dreame_vacuum";
  version = "2.0.2";

  # v2.0.2 plus the independently reviewed, unmerged TLS authentication fix:
  # https://github.com/Tasshack/dreame-vacuum/pull/1919
  # Pin the reviewed head, not the moving PR branch or a later rewrite.
  src = fetchFromGitHub {
    owner = "Tasshack";
    repo = "dreame-vacuum";
    rev = "2da4fb76f61934ceadaa69b050a148365ed37cd5";
    hash = "sha256-Vd4j0dHNmZdvT0jCHVPiTvtdDCpOgcA9/vvHCwTGZxU=";
  };

  # Upstream explicitly supports its optional frontend module being absent.
  # Exclude automatic card registration and the separate licensed DVC API;
  # the native integration, map entities and vendor cloud protocol remain.
  postPatch = ''
    rm custom_components/dreame_vacuum/frontend.py
  '';

  dependencies = with python3Packages; [
    numpy
    pycryptodome
    python-miio
    mini-racer
    paho-mqtt
    certifi
    cryptography
  ];

  meta = {
    description = "Dreame Vacuum with pinned PR 1919 TLS verification, without optional licensed frontend";
    homepage = "https://github.com/Tasshack/dreame-vacuum";
    changelog = "https://github.com/Tasshack/dreame-vacuum/releases/tag/v2.0.2";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
  };
}
