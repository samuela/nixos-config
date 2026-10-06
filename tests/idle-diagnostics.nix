# Run: nix-build tests/idle-diagnostics.nix --no-out-link --option builders ''
let
  nixpkgs = import ../nix/pinned-nixpkgs-path.nix;
  system = import (nixpkgs + "/nixos/lib/eval-config.nix") {
    modules = [ ../hosts/tropical-turnip/configuration.nix ];
  };
  inherit (system) pkgs;
  c = system.config;
  idle = c.home-manager.users.skainswo.services.swayidle;
  diagnostics = c.systemd.user.services.idle-diagnostics;
  observer = pkgs.callPackage ../hosts/tropical-turnip/idle-diagnostics.nix { };
in
assert idle.enable;
assert idle.extraArgs == [ "-d" ]; # Keep -w absent: smart-suspend must not block resume.
assert
  map (timeout: timeout.timeout) idle.timeouts == [
    180
    300
  ];
assert pkgs.lib.hasSuffix "idle-screen-off" (builtins.elemAt idle.timeouts 0).command;
assert pkgs.lib.hasSuffix "smart-suspend arm" (builtins.elemAt idle.timeouts 1).command;
assert pkgs.lib.hasSuffix "smart-suspend disarm" (builtins.elemAt idle.timeouts 1).resumeCommand;
assert diagnostics.partOf == [ "graphical-session.target" ];
assert diagnostics.wantedBy == [ "graphical-session.target" ];
assert diagnostics.serviceConfig.Restart == "on-failure";
assert diagnostics.unitConfig.ConditionEnvironment == "NIRI_SOCKET";
assert !c.systemd.user.services.niri.restartIfChanged;
assert
  c.systemd.user.services.niri.environment.RUST_LOG
  == "niri=debug,smithay::backend::renderer::gles=error,niri::dbus::freedesktop_screensaver=trace";
pkgs.runCommand "idle-diagnostics-tests"
  {
    nativeBuildInputs = [ pkgs.python3 ];
  }
  ''
    python ${./test_idle_diagnostics.py} ${observer}/bin/idle-diagnostics \
      ${(builtins.elemAt idle.timeouts 0).command}
    touch "$out"
  ''
