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
sudo ~/dev/nixos-config/rebuild.sh switch --option builders ''
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

## Kernel and resume diagnostics (tropical-turnip)

`hosts/tropical-turnip/kernel.nix` defines **one kernel**, including the corrected
TTM backport, Clang, KASAN, DEBUG_LIST, and lockdep. There is no new `debug-ttm`
specialisation. Old generations may still have their historical debug entries;
these are rollback choices, not a second build of the current configuration.
Clang is required by this kernel's Rust + KASAN combination. This retains the
existing substantial instrumentation overhead and requires a source build.
IRQ debugfs is enabled, lockdep's chain capacity is raised from 2^16 to 2^18,
and SysRq diagnostics + sync are enabled (mask 24). Panic-on-WARN stays off.

`services.resumeDiagnostics.enable = true` enables observation for
[touchpad resume issue #14](https://github.com/samuela/nixos-config/issues/14):

- Before sleep: save GPIO register/IRQ/device state and arm a **private** tracefs
  instance (`resume-diagnostics`), without changing other tracing sessions.
- Trace PM callback start/end/error events and selected I2C-HID, HID-multitouch,
  and AMD GPIO power/IRQ functions; include function return values when supported.
  IRQ events are filtered to the touchpad and its AMD GPIO parent, discovered
  afresh from `/proc/interrupts` rather than assuming IRQ 106 forever.
- After the sleep operation completes: stop/save the trace and snapshot again.
  A separate service collects settled state about five seconds later.
- Record trace setup errors, missing kernel interfaces, and buffer overrun
  counters rather than treating an incomplete trace as proof of success.

The trace ring is 256 KiB **per CPU**, with only the newest 16 report directories
retained. Reports live in `/var/lib/resume-diagnostics/`, readable by root and
`wheel`, not other users. They contain kernel/session logs and hardware metadata:
review before publishing. No raw input reports, keyboard events, or secret
payloads are collected; no device resets or suspend requests are performed.

When the touchpad fails, **before unbinding/rebinding it**, run:

```sh
sudo /run/current-system/sw/bin/resume-diagnostics capture broken
```

Move/click deliberately and confirm with `evtest` if needed (event numbers can
change). After recovery, run:

```sh
sudo /run/current-system/sw/bin/resume-diagnostics capture recovered
sudo /run/current-system/sw/bin/resume-diagnostics list
```

Capture is also useful while healthy for comparison. Missing IRQ debugfs on an
older booted kernel is explicitly recorded; the remaining collection still works.
The tracing captures sequencing/software state, not an electrical waveform or
proof of firmware correctness. A motionless touchpad's silent IRQ is normal.

Apply the configuration with the rebuild command above, then **reboot to load the
new kernel**. Merely switching configurations does not change the running kernel.
Use `systemctl status resume-diagnostics-sleep` while diagnosing hook failures and
inspect the latest report's `trace-config.txt`, `trace-setup.log`, and
`trace-stats.txt` to verify that tracing actually ran. The oneshot sleep service
is normally inactive between sleep cycles. Diagnostic failures do not block sleep.

Configuration and rootless mocked-collector regression checks (from the repo):

```sh
nix-shell -p nix python3 coreutils findutils gnugrep gawk util-linux bash shellcheck --run '
  nix-instantiate --eval --strict tests/hibernation.nix &&
  nix-instantiate --eval --strict tests/resume-diagnostics.nix &&
  shellcheck -s bash modules/resume-diagnostics.sh &&
  python3 tests/test_resume_diagnostics.py
'
```

The mocked tests exercise retention, missing kernel interfaces, trace-setup
failure, filtering, and the capture lifecycle, not actual hardware or systemd
sleep ordering. Verify one real sleep cycle after activation.

## Deploy

- Rebuild from this repo: `./rebuild.sh switch` (uses `-I nixos-config` for the selected host config and `-I nixpkgs` from `nix/pinned-nixpkgs.nix`, so it does not depend on the root `nix-channel`).
- Update the top-level `nixpkgs` pin by changing `rev` and `sha256` in `nix/pinned-nixpkgs.nix`. To compute the new hash for a revision, run `nix-prefetch-url --unpack https://github.com/NixOS/nixpkgs/archive/<rev>.tar.gz` and copy the resulting hash into `sha256`.
