# Run: nix-instantiate --eval --strict tests/resume-diagnostics.nix
let
  nixpkgs = import ../nix/pinned-nixpkgs-path.nix;
  system = import (nixpkgs + "/nixos/lib/eval-config.nix") {
    modules = [ ../hosts/tropical-turnip/configuration.nix ];
  };
  c = system.config;
  diagnosticsPatch = builtins.head (
    builtins.filter (p: p.name == "diagnostic-kernel-config") c.boot.kernelPatches
  );
  k = diagnosticsPatch.structuredExtraConfig;
  disabled =
    (system.extendModules {
      modules = [
        (
          { lib, ... }:
          {
            services.resumeDiagnostics.enable = lib.mkForce false;
          }
        )
      ];
    }).config;
in
assert builtins.attrNames c.specialisation == [ ];
assert builtins.elem "ttm-5387-swapout-bulk-move" (map (p: p.name) c.boot.kernelPatches);
assert k.GENERIC_IRQ_DEBUGFS == system.pkgs.lib.kernel.yes;
assert k.KASAN == system.pkgs.lib.kernel.yes;
assert k.LOCKDEP_CHAINS_BITS == system.pkgs.lib.kernel.freeform "18";
assert c.boot.kernel.sysctl."kernel.sysrq" == 24;
assert c.services.resumeDiagnostics.enable;
assert c.systemd.services.resume-diagnostics-sleep.before == [ "sleep.target" ];
assert c.systemd.services.resume-diagnostics-sleep.wantedBy == [ "sleep.target" ];
assert c.systemd.services.resume-diagnostics-sleep.unitConfig.StopWhenUnneeded;
assert c.systemd.services.resume-diagnostics-sleep.serviceConfig.RemainAfterExit;
assert !(disabled.systemd.services ? resume-diagnostics-sleep);
assert !(disabled.systemd.services ? resume-diagnostics-settled);
{
  singleKernel = true;
  tracing = true;
  optional = true;
}
