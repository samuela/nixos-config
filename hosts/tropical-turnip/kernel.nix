# One kernel configuration for normal use and diagnostics. Older NixOS
# generations remain rollback choices; there is no separate debug specialisation.
{ lib, pkgs, ... }:
let
  llvmLatestKernelPackages = pkgs.linuxPackagesFor (
    pkgs.linuxPackages_7_2.kernel.override {
      stdenv = pkgs.pkgsLLVM.stdenv;
    }
  );
in
{
  # Keep the existing toolchain/instrumentation while investigating #13/#14.
  # Rust + KASAN requires Clang in Linux 7.2. This is a from-source kernel build
  # with significant runtime memory/CPU overhead, not a stock cached kernel.
  boot.kernelPackages = lib.mkForce llvmLatestKernelPackages;

  boot.kernelPatches = [
    {
      name = "diagnostic-kernel-config";
      patch = null;
      structuredExtraConfig = with lib.kernel; {
        DEBUG_KERNEL = yes;
        DEBUG_LIST = yes;
        KASAN = yes;
        PROVE_LOCKING = yes;
        DEBUG_SPINLOCK = yes;
        # 65536 chains exhausted on Sep 20 and disabled lockdep. Increase the
        # capacity fourfold; this is bounded but still costs additional RAM.
        LOCKDEP_CHAINS_BITS = freeform "18";
        GENERIC_IRQ_DEBUGFS = yes;
        FTRACE = yes;
        FUNCTION_TRACER = yes;
        FUNCTION_GRAPH_TRACER = yes;
        DYNAMIC_DEBUG = yes;
      };
    }
    # Linux 7.2.8 includes the corrected TTM #5387 swapout fix and both
    # MT7921 CLC parser fixes; no local source backports are needed.
  ];

  # Diagnostic task/CPU dumps plus sync, without enabling kill/reboot keys.
  boot.kernel.sysctl."kernel.sysrq" = 24;

  # Do not enable panic_on_warn: the known dcn31_program_compbuf_size WARN
  # also occurs during normal operation. Keep the existing panic/oops capture.
}
