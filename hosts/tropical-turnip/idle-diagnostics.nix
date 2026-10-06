{
  stdenv,
  pkg-config,
  wayland,
  wayland-scanner,
  wayland-protocols,
}:
stdenv.mkDerivation {
  pname = "idle-diagnostics";
  version = "1";
  src = ./idle-diagnostics.c;
  dontUnpack = true;
  strictDeps = true;
  nativeBuildInputs = [
    pkg-config
    wayland-scanner
  ];
  buildInputs = [ wayland ];
  buildPhase = ''
    runHook preBuild
    protocol=${wayland-protocols}/share/wayland-protocols/staging/ext-idle-notify/ext-idle-notify-v1.xml
    wayland-scanner client-header "$protocol" ext-idle-notify-v1-client-protocol.h
    wayland-scanner private-code "$protocol" ext-idle-notify-v1-protocol.c
    $CC -std=c11 -Wall -Wextra -Werror -I. "$src" ext-idle-notify-v1-protocol.c \
      $(pkg-config --cflags --libs wayland-client) -o idle-diagnostics
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    install -Dm755 idle-diagnostics "$out/bin/idle-diagnostics"
    runHook postInstall
  '';
}
