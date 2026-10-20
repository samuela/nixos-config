"""Compare complete firmware trees; only the two pinned Wi-Fi blobs may differ."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess


# Raw (decompressed) hashes independently verified against the retained May
# release, not calculated from the candidate package under test.
EXPECTED = {
    "mediatek/WIFI_MT7922_patch_mcu_1_1_hdr.bin.zst": (
        "6d04988f5f44fc41e9404a492291a7a519b38e6aea6369b2f939cd0c70765f5a",
        "20260224103145a",
    ),
    "mediatek/WIFI_RAM_CODE_MT7922_1.bin.zst": (
        "1226f5b30531b2f027897a4a499fb77c31f4a39025c98e5a9896769aaa781fda",
        "20260224103233",
    ),
}


def inventory(root):
    # buildEnv links entire vendor directories: rglob without following directory
    # symlinks would silently omit most of the baseline firmware.
    result = {}
    for directory, _, files in os.walk(root, followlinks=True):
        for name in files:
            path = Path(directory) / name
            if not path.is_file():
                raise AssertionError(f"Broken or non-file firmware entry: {path}")
            result[path.relative_to(root).as_posix()] = path
    return result


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def changed_files(baseline, candidate):
    old, new = inventory(baseline), inventory(candidate)
    if old.keys() != new.keys():
        raise AssertionError(
            f"Firmware paths changed: added={sorted(new.keys() - old.keys())}, "
            f"removed={sorted(old.keys() - new.keys())}"
        )
    changed = []
    for name in sorted(old):
        # All paths are immutable Nix store files; identical resolved paths need
        # not be hashed twice. Different paths still require byte comparison.
        if old[name].resolve() != new[name].resolve():
            if digest(old[name]) != digest(new[name]):
                changed.append(name)
    return changed, len(old)


def main():
    # No random data or PRNG is used.
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("report", type=Path)
    args = parser.parse_args()

    changed, count = changed_files(args.baseline, args.candidate)
    if set(changed) != EXPECTED.keys():
        raise AssertionError(f"Expected only the MT7922 Wi-Fi pair to change; got {changed}")

    builds = {}
    for name, (expected_hash, expected_build) in EXPECTED.items():
        # zstd otherwise skips buildEnv's file symlinks. Resolve rather than
        # using --force, which would also permit pass-through of non-zstd data.
        source = (args.candidate / name).resolve(strict=True)
        data = subprocess.check_output(["zstd", "-d", "-c", str(source)])
        if hashlib.sha256(data).hexdigest() != expected_hash:
            raise AssertionError(f"Wrong firmware payload: {name}")
        header = data[:16] if "patch_mcu" in name else data[-36:][17:32]
        build = header.rstrip(b"\x00\n").decode("ascii")
        if build != expected_build:
            raise AssertionError(f"Wrong firmware build: {name}: {build}")
        builds[name] = {"sha256": expected_hash, "build": build}

    # Included in the complete comparison, but require that this critical
    # negative control really exists in both trees rather than passing vacuously.
    bluetooth = "mediatek/BT_RAM_CODE_MT7922_1_1_hdr.bin.zst"
    if not (args.baseline / bluetooth).is_file() or bluetooth in changed:
        raise AssertionError("MT7922 Bluetooth firmware is missing or changed")

    report = {"files_compared": count, "changed": changed, "builds": builds}
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
