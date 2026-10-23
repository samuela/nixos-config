# nixos-config

Personal NixOS configuration. Secrets stay untracked in `secrets/`.

`Wallpapers/` is intended to be symlinked into `~/Pictures/Wallpapers` for compatbility with noctalia. Some config files are in `.config/` which maps to `~/.config/` and should be symlinked as follows:

```
ln -s /home/skainswo/dev/nixos-config/Wallpapers ~/Pictures/Wallpapers
ln -s /home/skainswo/dev/nixos-config/.config/niri/config.kdl ~/.config/niri/config.kdl
ln -s /home/skainswo/dev/nixos-config/.config/noctalia/plugins.json ~/.config/noctalia/plugins.json
ln -s /home/skainswo/dev/nixos-config/.config/noctalia/settings.json ~/.config/noctalia/settings.json
ln -s /home/skainswo/dev/nixos-config/.config/vicinae/vicinae.json ~/.config/vicinae/vicinae.json
```

## Secrets

- `secrets/skainswo-password.hash`: hashed password for `users.users.skainswo`; keep mode 600. Regenerate with `mkpasswd -m sha-512 > secrets/skainswo-password.hash`.

### Restic backup credentials (placed manually per host)

Not stored in this repo. Place them by hand on each host that imports `modules/restic-backup.nix`:

```
sudo install -d -m 0700 -o root -g root /etc/restic
# Restic repo password. KEEP A COPY OFFLINE (password manager, paper) — if this
# is lost the offsite backups cannot be decrypted.
openssl rand -base64 48 | sudo install -m 0600 -o root -g root /dev/stdin /etc/restic/password
# Backblaze B2 credentials. Use a bucket-scoped application key, NOT the master key.
sudo install -m 0600 -o root -g root /dev/stdin /etc/restic/b2-env <<'EOF'
B2_ACCOUNT_ID=<keyID>
B2_ACCOUNT_KEY=<applicationKey>
EOF
```

The `restic-backups-<hostname>.service` unit will fail until both files exist.

## Hibernation toggle (tropical-turnip)

Set `powerManagement.hibernation.enable` in
`hosts/tropical-turnip/configuration.nix` to `true` or `false`, then apply:

```sh
sudo ~/dev/nixos-config/rebuild.sh switch
```

Currently **disabled** while investigating [resume failures (#13)](https://github.com/samuela/nixos-config/issues/13).

- **Off:** idle sleep uses plain suspend; systemd rejects hibernation, hybrid
  sleep, and suspend-then-hibernate; hibernation fallback services are absent.
  At 5% battery, UPower powers off cleanly instead of hibernating.
- **On:** idle sleep uses suspend-then-hibernate when the booted and configured
  kernels match, with a 30-minute delay; critical battery triggers hibernation.
- Swap and resume configuration are retained so re-enabling is straightforward.
  The toggle does not require a reboot. An in-progress sleep operation is not
  cancelled by changing the configuration.

**Plain suspend still drains the battery.** Critical-battery power-off loses
unsaved work, and UPower cannot act while the machine remains suspended. Save
work and shut down for extended periods away from power.

## Idle / screen-off diagnostics (tropical-turnip)

Screen-off remains at **3 minutes** and smart-suspend at **5 minutes**. Diagnostics
add no locking, power commands, or inhibitors of their own:

- `swayidle.service`: debug logs for timer registration, idle/resume callbacks,
  command launches, and the screen-off IPC command's exit status. `-w` stays off
  so smart-suspend cannot block resume callbacks.
- `idle-diagnostics.service`: independent **30-second** inhibitor-aware and
  input-only idle notifications, kernel DPMS changes (polled every 5 seconds),
  and a heartbeat every minute. No key contents, pointer coordinates, or window
  titles are collected.
- `niri.service`: narrowly scoped ScreenSaver D-Bus trace logs with application,
  reason, and owner names, uninhibit calls, and disconnected clients. Application
  names/reasons are client-supplied and may contain sensitive text; review logs
  before sharing. This does **not** enumerate native Wayland inhibitor owners.

Apply with `sudo ~/dev/nixos-config/rebuild.sh switch --option builders ''`.
The observer and swayidle logging take effect when their user units start/restart;
Niri's trace filter takes effect **after logging out and back in**. Do not restart
`niri.service` in a working session: that terminates the desktop.

After another occurrence, note when you left and returned, and inspect all three
units together (replace the times with the relevant interval):

```sh
journalctl --user -u swayidle.service -u idle-diagnostics.service -u niri.service \
  --since '2026-10-05 19:00' --until '2026-10-05 20:15' -o short-iso-precise
```

Interpretation:

- Sustained `input-only=idle` but `inhibitor-aware=active` indicates idle inhibition.
  Look for matching Niri `fdo inhibit` app/reason/owner messages. A Wayland
  inhibitor can cause the same discrepancy without a D-Bus message.
- `input-only resumed` indicates compositor-reported activity, not necessarily
  intentional physical input. Repeated activity can prevent the 3-minute timeout.
- `idle-screen-off` records whether the timeout command ran and its exit status.
  Exit zero means the IPC request succeeded; only the DPMS log shows whether the
  kernel subsequently reported the display off (not a physical panel measurement).
- An inhibitor-aware `resumed` event alone is **not proof of user input**: a new
  inhibitor also causes it. Pair it with the input-only stream. Brief mismatches
  can occur while the two callbacks are being delivered; use sustained state.
- Heartbeats distinguish quiet periods from a missing observer. These observations
  start when the service starts; they cannot reconstruct earlier incidents.

Tests (fake Wayland compositor plus Nix assertions preserving the idle policy):

```sh
nix-shell -p nix --run 'nix-build tests/idle-diagnostics.nix --no-out-link --option builders ""'
```

## NetworkManager authentication retries (tropical-turnip)

`hosts/tropical-turnip/networkmanager.nix` selects **NetworkManager 1.58.1**
from the separate, hash-pinned `nix/networkmanager-nixpkgs.nix` revision.
Only this host's NetworkManager package and its dependencies use that pin.
This override itself leaves the primary nixpkgs pin, kernel/CLC/TTM fixes,
firmware, supplicant, graphics stack and other hosts unchanged. No global
overlay is used; the separate firmware comparison below is independently toggled.

For [Wi-Fi incident #15](https://github.com/samuela/nixos-config/issues/15),
1.58 includes the [upstream authentication-retry fix](https://github.com/NetworkManager/NetworkManager/commit/746a5902ad85ec0611a3e6ebfd7b68b45621a40b):
a previously successful connection retries saved credentials before requesting
a new password. Finite default retry behavior is retained. This addresses the
premature `NO_SECRETS` autoconnect block, **not the original missing-M3 cause**;
recovery is not guaranteed if every retry fails. The September 28 recurrence
confirmed an automatic retry but both handshakes stalled; 1.58.1 alone was not
sufficient to recover connectivity.

Validate the package selection and sandboxed binary smoke checks:

```sh
nix-shell -p nix --run 'nix-build tests/networkmanager.nix --no-out-link --option builders ""'
```

The test checks that unrelated kernel, firmware, graphics, systemd and supplicant
selections stay unchanged, verifies daemon/client versions and the compiled
Wi-Fi retry code marker. It does not exercise authentication on real hardware.

Activate with `sudo ~/dev/nixos-config/rebuild.sh switch --option builders ''`.
Expect a NetworkManager restart and brief network interruption; this change does
not require a reboot. Verify the **running daemon** via
`nmcli -g VERSION general` (not just the installed client's `nmcli --version`).
Observe retries during normal use rather than forcing suspend/resume cycles.

To roll back this override, remove the `./networkmanager.nix` import from the
host configuration and rebuild. Once the main pin includes NetworkManager
1.58 or newer, remove the separate pin, host module/import and temporary test.

## MT7922 Wi-Fi firmware comparison (tropical-turnip)

The toggle in `hosts/tropical-turnip/configuration.nix` is now **false**:
its next activation/rebind restores the normal July Wi-Fi pair. Setting
`hardware.mt7922Firmware.usePrevious = true` selects **only the Wi-Fi RAM and ROM
patch** from the February 24 builds shipped in linux-firmware-20260519.
`mt7922-firmware-package.nix` fetches the two blobs from an immutable upstream
commit with pinned hashes; both match the retained May release byte-for-byte.
The main firmware bundle stays installed. Bluetooth and every other firmware
payload remain unchanged, as do NetworkManager 1.58.1, the supplicant, kernel
(including both CLC backports), graphics and power-management settings.

This is a reversible diagnostic comparison for
[incident #15](https://github.com/samuela/nixos-config/issues/15), **not a known
fix or a recommendation to keep old firmware indefinitely**. Observe ordinary
use; do not force repeated suspend cycles. A successful initial reconnect after
resetting the device is not proof that the older firmware fixes the recurrence.
The [September 29 recurrence](https://github.com/samuela/nixos-config/issues/15#issuecomment-5900948293)
reproduced the same handshake stalls with this pair: the downgrade is **not a
fix**. Restoration of the normal pair is prepared; running firmware changes
only after the operator completes the switch and rebind below.

Validate the enabled/disabled configurations and the complete firmware trees:

```sh
nix-shell -p nix --run 'nix-build tests/mt7922-firmware.nix --no-out-link --option builders ""'
```

The test requires exactly two changed firmware files, checks their decompressed
hashes/build headers, and verifies unchanged kernel/userspace selections. Both
variants are forced in the test regardless of the deployed toggle. It does not
exercise the firmware on hardware.

**Apply from a local terminal, not over this Wi-Fi connection.** First activate:

```sh
sudo ~/dev/nixos-config/rebuild.sh switch --option builders ''
```

A switch updates the kernel's firmware search path but does not replace firmware
already running on the card. Rebind this host's MT7922 PCI device to reload it
(brief Wi-Fi interruption; no reboot). No manual NetworkManager restart is
needed; the supplicant may restart during the device change. Rebinding keeps
the currently loaded CLC-patched modules, rather than inadvertently loading
modules from the older booted generation:

```sh
sudo sh -c '
  set -eu
  dev=0000:01:00.0
  pci=/sys/bus/pci/devices/$dev
  driver=/sys/bus/pci/drivers/mt7921e
  test "$(cat "$pci/vendor")" = 0x14c3
  test "$(cat "$pci/device")" = 0x0616
  test "$(cat /sys/module/firmware_class/parameters/path)" = "$(readlink -f /run/current-system/firmware)"
  test -e "$driver/bind"
  if test -L "$pci/driver"; then
    test "$(readlink -f "$pci/driver")" = "$driver"
    printf %s "$dev" > "$driver/unbind"
  fi
  printf %s "$dev" > "$driver/bind"
'
```

Verify **both** new initialization messages in the kernel journal before
interpreting the selected configuration:

- **False (normal/restored):** RAM `20260724143402`, ROM `20260724143257a`.
- True (older trial): RAM `20260224103233`, ROM `20260224103145a`.

Also verify that `nmcli -g VERSION general` still reports `1.58.1` and Wi-Fi
reconnects. An unsuccessful probe, missing build messages or failure to reconnect
means the comparison has not yet been established; preserve the logs and roll
back rather than repeatedly resetting the adapter.

**Rollback:** set `hardware.mt7922Firmware.usePrevious = false`, run the same
rebuild command, then the same PCI rebind command. The latter also handles an
already-unbound device after a failed probe. Confirm the July build strings
return. The baseline firmware and system are already in the local store; neither
rollback nor this test requires changing the router or Bluetooth firmware.

The optional [expanded Wi-Fi tracer](tools/wifi-trace/README.md) observes TX
queue/descriptor metadata and bounded RX windows. It is separate from NixOS,
has no default capture deadline, and stops at 16 MiB output. Starting it after
the switch but before this necessary rebind can calibrate the new probes without
another reset. Native tests are not proof of live verifier/attachment success.

## Kernel and resume diagnostics (tropical-turnip)

Both hosts use Linux **7.2.8** from the pinned `nixos-26.05` channel.
`hosts/tropical-turnip/kernel.nix` defines **one kernel**, including the upstream
TTM fix, Clang, KASAN, DEBUG_LIST, and lockdep. There is no new `debug-ttm`
specialisation. Old generations may still have their historical debug entries;
these are rollback choices, not a second build of the current configuration.
Clang is required by this kernel's Rust + KASAN combination. This retains the
existing substantial instrumentation overhead and requires a source build.
IRQ debugfs is enabled, lockdep's chain capacity is raised from 2^16 to 2^18,
and SysRq diagnostics + sync are enabled (mask 24). Panic-on-WARN stays off.

Linux 7.2.8 includes both MT7921/MT7922 CLC firmware-parser fixes: validate
record bounds **and skip unknown indices**. The obsolete local backports have
been removed; `tests/mt7921-clc.nix` verifies the fixed upstream source directly.
These repair the parser defect but have not prevented the handshake stalls.
The separate firmware comparison above remains unchanged; power-saving and
regulatory-refresh policy stay fixed.

Apply kernel changes with the rebuild command above, then **reboot to load the
new kernel**. Merely switching configurations does not change the running kernel.

Configuration and upstream-source regression checks (from the repo):

```sh
nix-shell -p nix --run '
  nix-instantiate --eval --strict tests/hibernation.nix &&
  nix-build tests/mt7921-clc.nix --no-out-link --option builders ""
'
```

The MT7921 test checks the pinned kernel source; it does not compile the kernel
or test Wi-Fi hardware.

## Deploy

- Rebuild from this repo: `./rebuild.sh switch` (uses `-I nixos-config` for the selected host config and `-I nixpkgs` from `nix/pinned-nixpkgs.nix`, so it does not depend on the root `nix-channel`).
- Update the top-level `nixpkgs` pin by changing `rev` and `sha256` in `nix/pinned-nixpkgs.nix`. To compute the new hash for a revision, run `nix-prefetch-url --unpack https://github.com/NixOS/nixpkgs/archive/<rev>.tar.gz` and copy the resulting hash into `sha256`.
