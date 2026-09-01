# Debug-kernel specialisation for investigating the amdgpu/TTM hibernation
# bulk_move list corruption — upstream bug drm/amd #5387.
#
# This adds a SEPARATE boot entry ("debug-ttm") to the bootloader. Your normal
# system is untouched; pick the debug entry only when you want to reproduce /
# instrument the crash.
#
# It builds the kernel with:
#   - DEBUG_LIST   : the list-debug check that already caught the BUG
#   - KASAN        : catches any use-after-free / out-of-bounds at the access
#   - lockdep      : validates the lru_lock path the bulk_move code runs under
#
# (The TTM kunit mock-device tests run on a SEPARATE kernel built by
#  tools/testing/kunit/kunit.py — no GPU and no system rebuild needed — so they
#  are not part of this on-metal debug kernel.)
#
# ⚠️  KASAN forces a full from-source kernel compile (no binary-cache hit).
#     Expect a long build (~20-45 min on this laptop) and higher RAM/CPU at
#     runtime. If that's too heavy, comment out the KASAN lines below —
#     DEBUG_LIST alone still trips on the corruption.
#
# ⚠️  We deliberately DO NOT set panic_on_warn here: the harmless
#     dcn31_program_compbuf_size display WARN fires during normal operation and
#     would panic the machine. To capture OUR warn at its source during a test,
#     toggle it at runtime right before hibernating:
#         sudo sysctl kernel.panic_on_warn=1
#     (then hibernate; ramoops will capture the panic at the WARN instead of 17
#     minutes later at the list_del).

{ lib, pkgs, ... }:
let
  # Thomas Hellström's upstream v2 structural fix from drm/amd #5387.
  # Patchwork: https://patchwork.freedesktop.org/patch/740147/
  ttmNestedSublistsV2 = pkgs.fetchurl {
    url = "https://patchwork.freedesktop.org/patch/740147/raw/";
    hash = "sha256-3NKCSlg1dEFFVtw/162VcYm3yywYHtDD8SeryB5ajzw=";
  };

  llvmLatestKernelPackages = pkgs.linuxPackagesFor (
    pkgs.linuxPackages_latest.kernel.override {
      stdenv = pkgs.pkgsLLVM.stdenv;
    }
  );
in
{
  specialisation.debug-ttm.configuration = {
    system.nixos.tags = [ "debug-ttm" ];

    # Linux 7.2 requires Clang when combining KASAN with Rust support.
    # Keep the normal kernel on GCC and use the complete LLVM toolchain only
    # for this instrumented specialisation.
    boot.kernelPackages = lib.mkForce llvmLatestKernelPackages;

    boot.kernelPatches = [
      {
        name = "ttm-debug-config";
        patch = null;
        structuredExtraConfig = with lib.kernel; {
          # --- catch the corruption ---
          DEBUG_KERNEL = yes;
          DEBUG_LIST = yes;
          KASAN = yes; # generic KASAN; Clang currently selects inline instrumentation

          # --- lock correctness on the bulk_move / lru_lock path ---
          PROVE_LOCKING = yes;
          DEBUG_SPINLOCK = yes;
        };
      }
      {
        # Thomas's nested-sublists v2 fix. Pass criterion: run
        # `~/ttm-trigger.sh hib N` (or `load SECS`) and confirm KASAN,
        # DEBUG_LIST, and lockdep stay silent.
        name = "ttm-5387-nested-sublists-v2";
        patch = ttmNestedSublistsV2;
      }
    ];
  };
}
