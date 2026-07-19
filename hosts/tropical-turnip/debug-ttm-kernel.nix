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
in
{
  specialisation.debug-ttm.configuration = {
    system.nixos.tags = [ "debug-ttm" ];

    boot.kernelPatches = [
      {
        name = "ttm-debug-config";
        patch = null;
        structuredExtraConfig = with lib.kernel; {
          # --- catch the corruption ---
          DEBUG_KERNEL = yes;
          DEBUG_LIST = yes;
          KASAN = yes; # generic/outline KASAN (lighter to build than INLINE)

          # --- lock correctness on the bulk_move / lru_lock path ---
          PROVE_LOCKING = yes;
          DEBUG_SPINLOCK = yes;
        };
      }
      {
        # Linux 7.0.11 differs from Thomas's patch context by one space in a
        # comment. Without this no-op normalization, GNU patch mistakes the
        # first ttm_resource.c hunk for an already-applied/reversed patch.
        name = "ttm-7.0.11-patchwork-context";
        patch = ./ttm-7.0.11-patchwork-context.patch;
      }
      {
        # ===================================================================
        # ONE debug kernel at a time -- pick exactly one of the two patches
        # below (ESP space is tight; two debug specs won't both fit).
        #
        #   Thomas's nested-sublists v2 -> the FIX. Pass criterion: run
        #       `~/ttm-trigger.sh hib N` (or `load SECS`) and KASAN/DEBUG_LIST/
        #       lockdep stay SILENT. This is the validation kernel.
        #
        #   ttm-dangle-detector.patch -> still BUGGY, plus WARN_ONCE probes that
        #       fire at PLANT time. Boot this first to PROVE the trigger is
        #       reached: `~/ttm-trigger.sh hib 1` should print a "TTM#5387: ..."
        #       PLANT within one load-across-hibernate cycle. Then flip back to
        #       the fix patch, rebuild, and confirm the same workload is silent.
        # ===================================================================
        name = "ttm-5387-nested-sublists-v2";
        patch = ttmNestedSublistsV2; # Exact upstream v2; validate it stays KASAN-silent under the proven trigger
        # patch = ./ttm-dangle-detector.patch; # DETECTOR: buggy + loud, to PROVE the trigger
      }
    ];
  };
}
