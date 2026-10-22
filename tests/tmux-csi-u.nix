# Run: nix-build tests/tmux-csi-u.nix --no-out-link --option builders ''
# Uses a private PTY and socket in the build sandbox, never the live server.
let
  nixpkgs = import ../nix/pinned-nixpkgs-path.nix;
  system = import (nixpkgs + "/nixos/lib/eval-config.nix") {
    modules = [ ../hosts/luminous-lemon/configuration.nix ];
  };
  inherit (system) pkgs;
  c = system.config;
  hm = c.home-manager.users.skainswo;
  tmux = hm.programs.tmux.package;
  baseline = (import nixpkgs { }).tmux;
  decoderPatch = pkgs.lib.last tmux.patches;
in
assert c.home-manager.useGlobalPkgs;
assert hm.programs.tmux.enable;
assert tmux.drvPath == pkgs.tmux.drvPath;
assert tmux.drvPath != baseline.drvPath;
assert tmux.version == baseline.version;
assert builtins.elem tmux.drvPath (map (p: p.drvPath) hm.home.packages);
assert pkgs.lib.init tmux.patches == baseline.patches;
assert decoderPatch.url == "https://github.com/tmux/tmux/commit/2c298158cff5d9d60c1a4f78f1d0850cd1fa4525.patch";
# The build verifies the fixed hash; avoid duplicating its value here.
assert decoderPatch.outputHashMode == "flat";
assert builtins.match "sha256-[A-Za-z0-9+/]{43}=" decoderPatch.outputHash != null;
assert pkgs.lib.hasInfix "set -s extended-keys on" hm.programs.tmux.extraConfig;
assert pkgs.lib.hasInfix "set -s extended-keys-format csi-u" hm.programs.tmux.extraConfig;
assert pkgs.lib.hasInfix "alacritty:Eneks=\\E[=1u:Dseks=\\E[=0u" hm.programs.tmux.extraConfig;
pkgs.runCommand "tmux-csi-u-check"
  {
    nativeBuildInputs = [ pkgs.python3 pkgs.patchutils ];
  }
  ''
    test "$(lsdiff ${decoderPatch})" = "a/tty-keys.c"
    python3 ${./test_tmux_csi_u.py} ${tmux}/bin/tmux > "$out"
    cat "$out"
  ''
