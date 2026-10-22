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
in
assert c.home-manager.useGlobalPkgs;
assert hm.programs.tmux.enable;
assert tmux.drvPath == pkgs.tmux.drvPath;
assert tmux.drvPath != baseline.drvPath;
assert tmux.version == baseline.version;
assert builtins.elem tmux.drvPath (map (p: p.drvPath) hm.home.packages);
assert tmux.patches == (baseline.patches ++ [ ../nix/tmux-csi-u-default-modifier.patch ]);
assert pkgs.lib.hasInfix "set -s extended-keys on" hm.programs.tmux.extraConfig;
assert pkgs.lib.hasInfix "set -s extended-keys-format csi-u" hm.programs.tmux.extraConfig;
assert pkgs.lib.hasInfix "alacritty:Eneks=\\E[=1u:Dseks=\\E[=0u" hm.programs.tmux.extraConfig;
pkgs.runCommand "tmux-csi-u-check"
  {
    nativeBuildInputs = [ pkgs.python3 ];
  }
  ''
    python3 ${./test_tmux_csi_u.py} ${tmux}/bin/tmux > "$out"
    cat "$out"
  ''
