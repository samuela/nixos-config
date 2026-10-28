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

## Home Assistant (luminous-lemon only)

`modules/home-assistant.nix` uses the primary nixpkgs pin's **Home Assistant
2026.5.4** native NixOS service. This is not Home Assistant OS: there is no
Supervisor or app/add-on store, and the native installation method is
[unsupported upstream](https://www.home-assistant.io/installation/).
NixOS manages the service and Python dependencies. Adding integrations with
additional dependencies requires adding their domain to `extraComponents` in
that module and rebuilding; selecting an integration in the UI cannot install
missing packages. Optional Alexa Devices (`alexa_devices`), TP-Link Smart Home
(`tplink`, including Kasa switches), Yeelight (`yeelight`) and HomeKit Device
(`homekit_controller`) dependencies are included; add devices in the UI after
rebuilding.

### Apply and onboard

On **luminous-lemon**, the user must activate the configuration (this has not
been done automatically):

```sh
sudo ./rebuild.sh switch --option builders ''
systemctl status home-assistant.service
journalctl -u home-assistant.service -b
```

The intended Service address is **http://ha/** (full-name fallback:
<http://ha.tail32462.ts.net/>), after the admin setup below. Until verified,
from a device connected to the same **Tailscale tailnet**, use the retained
fallback <http://luminous-lemon:8123> if DNS resolves that name. Otherwise use
`http://<luminous-lemon-tailscale-IP>:8123` (find it with `tailscale ip -4` on
the server). Tailnet ACLs must allow access. An alternative is
`ssh -N -L 8123:127.0.0.1:8123 skainswo@luminous-lemon` over a reachable SSH
connection, then <http://localhost:8123>. Create the owner account promptly,
set location/units, and add integrations under **Settings → Devices & services**.

The HTTP listener uses the native defaults (all addresses, port 8123), but the
NixOS firewall opens TCP **8123 only on `tailscale0`**, not globally or on LAN
interfaces. Arbitrary LAN clients cannot use the frontend. Tailscale Serve
proxies Service HTTP port 80 to **http://127.0.0.1:8123**; HA trusts forwarded
headers only from **127.0.0.1**, not the LAN or entire tailnet. No router
forwarding, public ingress or TLS termination is configured. Use Tailscale or
the SSH tunnel rather than sending credentials over untrusted plain HTTP.

`default_config` supplies standard UI/history and discovery components, including
DHCP, SSDP and Zeroconf. Existing Avahi/mDNS and host networking are retained;
no additional discovery firewall ports are opened. Devices normally need to
share the server's LAN/subnet with working multicast. Tailscale transports UI
access, **not LAN multicast discovery**. VLANs, Wi-Fi client isolation and the
host firewall (especially inbound SSDP multicast) can prevent discovery; Avahi
alone does not guarantee it. Discovery is not runtime-tested here. Try a
supported integration's explicit device IP first; determine the actual network
and integration requirements before adding narrowly scoped firewall rules.
No USB coordinator, Matter server, or speculative hardware setup is included.

### Publish the ha Service (one-time admin setup)

Follow [Tailscale Services](https://tailscale.com/docs/features/tailscale-services).
Read-only inspection found Tailscale **1.98.10**, MagicDNS enabled, an **untagged**
luminous-lemon, no Service advertisements, and existing node Serve listeners on
8443/9443 (plus a transient foreground 443 listener). No live tags, policy, SSH
or Serve changes have been applied. Local CLI access does not provide the admin
policy; **publication is blocked on admin review/setup**, not just a rebuild.

1. In the [access controls](https://login.tailscale.com/admin/acls), review a
   suitable host tag and its `tagOwners` with an admin. **Before retagging**, ensure
   intended clients retain node access (including SSH, existing Serve ports and
   direct HA TCP 8123) under the tag-based identity, and review the separate
   Tailscale SSH rules: user-owned/self-based rules may stop matching. Keep a
   tested local/recovery access path. Then have the admin assign the reviewed
   host tag to luminous-lemon. This repo intentionally chooses/applies no tag.
2. In [Services](https://login.tailscale.com/admin/services), define **ha**
   (`svc:ha`) with endpoint **tcp:80**. In access controls, grant only intended
   client identities access to destination `svc:ha` on `tcp:80`; this is separate
   from their retained direct-node access. Manual advertisement approval is
   sufficient; no automatic-approval policy is required.
3. After admin setup, the user's switch above automatically starts publication.
   Check HA and the publication unit:

   ```sh
   curl --noproxy '*' -I http://127.0.0.1:8123/
   systemctl status home-assistant-tailscale.service
   journalctl -u home-assistant-tailscale.service -b
   tailscale serve status --json
   ```

   This boot-enabled oneshot runs exactly
   `tailscale serve --service=svc:ha --http=80 127.0.0.1:8123`. It starts after
   tailscaled and HA, retries failures every 10 seconds, and stays **active
   (exited)** after success. Boot and unit changes reapply the route; no manual
   start is required. Services also persist the route and advertisement in
   tailscaled's state across reboot.
   It updates only this Service, preserving node listeners and other Services;
   do not use `serve reset` or replace the whole Serve config. Verify 8443/9443
   remain unchanged (foreground sessions may independently come and go).
4. Approve luminous-lemon's pending **ha** advertisement on the Services admin
   page. Verify Service status and client access; do not remove the 8123 fallback
   until that succeeds. Stopping/removing the oneshot does **not** unpublish the
   persistent route. To retire it deliberately, drain `svc:ha`, wait for active
   connections to finish, then clear only `svc:ha` using the Serve CLI.

### Service client checks (required after publication)

Use Tailscale **1.94+** clients where possible (Services require 1.86+). Linux
clients on **1.93 or earlier** need `accept-routes` enabled; review other subnet
route impacts before changing that setting. Short **http://ha/** also depends
on each client accepting Tailscale DNS and the `tail32462.ts.net` search suffix:
it is **not yet verified on real clients**. See
[MagicDNS](https://tailscale.com/docs/features/magicdns). From each intended client:

```sh
getent hosts ha
getent hosts ha.tail32462.ts.net
curl --noproxy '*' -I http://ha/
curl --noproxy '*' -I http://ha.tail32462.ts.net/
```

Then open the UI, log in, and check dashboards/live updates (WebSockets). If the
short name fails, use <http://ha.tail32462.ts.net/> and fix client DNS/search
settings. Type **http://** explicitly to avoid browser search/HTTPS-only
heuristics. This is HTTP inside the encrypted tailnet, not public HTTP.
HTTPS would require a separate Serve HTTPS endpoint and the **full** MagicDNS
name/certificate, not `https://ha/`; neither HTTPS nor a custom domain is set up.

### Existing Alexa devices (optional)

Alexa is not required for onboarding or other integrations. To use it, add
[Alexa Devices](https://www.home-assistant.io/integrations/alexa_devices/)
in the UI with the relevant Amazon account. This integration requires Amazon
**authenticator-app MFA** (not just SMS MFA); complete Amazon's authentication
prompts there, never in tracked Nix. It supports Echo/Alexa built-in devices and
their supported features, **not a blanket import of everything listed in the
Alexa app**. It is also not the separate task of exposing HA entities to Alexa
for voice control.

Inventory each device's brand/model, vendor app/account and protocol before
migrating. Third-party Alexa-linked devices generally need their own supported
HA integration. Devices paired directly to an Echo's Zigbee hub may need
re-pairing and compatible coordinator hardware, which is not configured here.
[Matter multi-fabric sharing](https://www.home-assistant.io/integrations/matter/)
may avoid re-pairing for compatible devices/controllers, but requires a separate
supported Matter setup; it is not enabled by this change.

### Existing Kasa switches (optional)

Provision the switches in the Kasa app first and keep them on the same LAN as
luminous-lemon with stable local connectivity. After rebuilding, open
**Settings → Devices & services → Add Integration → TP-Link Smart Home**
([integration documentation](https://www.home-assistant.io/integrations/tplink/)).
If discovery does not find a switch, enter its hostname/IP manually; this is the
preferred fallback with the unchanged discovery firewall rules. A DHCP reservation
can keep its address stable. Tailscale UI access does not provide LAN discovery.

Newer models may request the TP-Link account email (case-sensitive) and password
for local authentication. Enter these only in the HA UI, never in Nix. If needed,
enable **Third-Party Compatibility** in the Kasa app's settings. Alexa is not a
prerequisite; existing Alexa pairing can remain unchanged.

### Yeelight bulbs (optional)

[Yeelight](https://www.home-assistant.io/integrations/yeelight/) supports specific
Wi-Fi models, not all Xiaomi bulbs; check the exact model against its supported
list. Set up a supported bulb in the Yeelight app and enable **LAN Control**, with
local connectivity to luminous-lemon. The dependency change is pending the user's
rebuild above; then retry **Settings → Devices & services → Add Integration →
Yeelight**. Enter the bulb's IP manually if discovery does not find it; firewall
rules are unchanged. Configure devices only in the UI, not Nix.

#### Yeelight 1S Color via HomeKit Device

For the already provisioned Yeelight 1S Color (YLDP13YL) at **192.168.4.70**,
local mDNS advertised **YLBulbColor1s-5927._hap._tcp**, unpaired (`sf=1`), on
TCP port 80. Use [HomeKit Device](https://www.home-assistant.io/integrations/homekit_controller/)
(`homekit_controller`), not HomeKit Bridge (`homekit`). After the switch above,
open **Settings → Devices & services → Add Integration → HomeKit Device →
YLBulbColor1s-5927** and enter the bulb's printed HomeKit pairing code **only in
the HA UI**, never in Nix or this repository. Pairing has not been performed or
verified here.

This local HAP route needs no Yeelight app, LAN Control toggle, Apple device or
cloud login for this already provisioned, unpaired bulb. Keep its existing Xiaomi
app pairing; do not reset it. `default_config` already enables Zeroconf, existing
Avahi is retained, and outgoing TCP 80 is permitted; no new firewall ports are
needed.

### Dreame L40s Ultra CE (Dreamehome US)

After the user-run switch above, open **Settings → Devices & services → Add
Integration → Dreame Vacuum → Dreamehome → United States (US)** and select the
vacuum. Use the **email-registered Dreamehome app account**, matching its app
region, and enter your own credentials **only in the HA UI**. Phone-number login
is unsupported; Apple/Google users need a dedicated password set in the app.
This does not use Alexa, HACS or runtime pip installation. Pairing, firmware and
custom dashboard/card setup are not changed; no extra firewall ports are opened.
Login and the real device connection have not been tested.

`nix/dreame-vacuum.nix` packages stable v2.0.2 plus the exact reviewed head
[`2da4fb76f61934ceadaa69b050a148365ed37cd5`](https://github.com/Tasshack/dreame-vacuum/commit/2da4fb76f61934ceadaa69b050a148365ed37cd5)
of **unmerged [PR 1919](https://github.com/Tasshack/dreame-vacuum/pull/1919)**,
not moving master or a later proposed rewrite. This addresses the missing TLS
server authentication in [issue 1918](https://github.com/Tasshack/dreame-vacuum/issues/1918).
HTTP uses certifi's public trust store; MQTT alone uses the patch's pinned Dreame
private CA (despite its “GlobalSign” name, not the public GlobalSign root).
Review and offline checks cover the reported gaps, not a full cryptographic
certification: hand-written TLS and permissive handshake-message ordering remain
maintenance risks. The optional `frontend.py` is deliberately omitted using
upstream-supported absence handling: no automatic licensed Dreame card,
fingerprinting/card-delivery API routes or card registration. Native map entities
remain available.

`nix/mini-racer.nix` pins the official
[mini-racer 0.14.1 PyPI wheel](https://pypi.org/project/mini-racer/0.14.1/),
including upstream's **prebuilt V8**, with a fixed hash and native-library
patching. This is not legacy `py-mini-racer` or a reproducible V8 source build;
it trusts upstream's binary provenance and is restricted to **x86_64 Linux**.
The ctypes wrapper and V8 14.4.258.23 execute with the pinned Python 3.14.7;
cryptography 48.0.0 satisfies the patch's requirement of at least 45.

This third-party integration depends on Dreame's cloud/internet and can break
with vendor API changes or outages; it is not promised local-only control.
Custom code runs inside HA and handles sensitive account/device state and maps.
Keep passwords/tokens out of Git, Nix expressions and the world-readable store;
protect runtime state and backups. **Encrypted local HA backup creation,
scheduling, emergency-key custody and restore testing still need user onboarding**
as described below.

### State, secrets and backups

Persistent state lives in **`/var/lib/hass`**, owned by `hass` with private
permissions. UI credentials/tokens live in `.storage`; do not commit or copy
them into Nix expressions (the Nix store is readable). If an integration needs
YAML secrets, manually create `/var/lib/hass/secrets.yaml`, owned by `hass:hass`
with mode `0600`, and reference `!secret name` from Nix rather than its value.
`configuration.yaml` is generated and replaced by Nix; edit the module instead.
UI automations, scripts and scenes use separate writable YAML files, and UI
dashboards remain in runtime storage. Rebuilds preserve this state; NixOS
rollback does **not** roll back HA database/schema migrations. Back up before
upgrading and keep this repository/pin for recovery.

In **Settings → System → Backups**, create a backup with local storage selected
and wait for successful completion. Configure an automatic HA backup schedule
and local retention there if desired; this configuration does not create HA
archives by itself. Save the backup emergency kit/encryption key separately
offline, along with the restic repository password. Test a restore before relying
on it. See [HA backup documentation](https://www.home-assistant.io/common-tasks/general/#backups).

The existing luminous-lemon restic job additionally backs up
**`/var/lib/hass/backups`** (the pinned Core local-backup destination). The path
is created even before first startup, so an empty archive directory does not
break restic. It does **not** back up the live SQLite database or `.storage`
directly: copying live database files is not a consistency guarantee. Only
completed HA archives should be relied on. Schedule HA archive creation well
before the restic window (03:00–04:00), avoid overlapping archive creation or
local pruning with restic, and verify both jobs succeeded; an archive still
being written during restic is not a valid recovery point. After a manual HA
backup finishes, copy it off-host immediately with:

```sh
sudo systemctl start restic-backups-luminous-lemon.service
sudo journalctl -u restic-backups-luminous-lemon.service -n 50
```

Restic still needs the manually provisioned credentials above. Its existing
7 daily / 4 weekly / 12 monthly / 3 yearly snapshot retention applies, but only
to archives present when snapshots ran: it does not create newer HA recovery
points or prune local HA archives. Monitor freshness and free space. For
recovery, restore an archive from restic to a separate directory, reprovision
this NixOS service from the saved pin, then upload/restore the HA archive via
HA's onboarding/backup UI with its encryption key; do not overwrite a running
database. OS configuration and external services are not part of a Core backup.

Focused evaluation and generated-YAML tests (no full system/HA package build):

```sh
nix-build tests/home-assistant.nix --no-out-link --option builders ''
```

Offline Dreame package/import/native-runtime and TLS regression checks:

```sh
nix-build tests/dreame-vacuum.nix --no-out-link --option builders ''
```

Before builds, verify `HOME`, the resolved Nix executable/version, shared
`/nix/store`, and `nix show-config` builders/substituters; use empty builders as
above and retain the shared cache. The Dreame test imports the packaged component
and config flow against patched pinned HA Core source and the effective host's
Python dependency selection, without building or starting the HA service. It
executes V8 and the bundled map optimizer, checks CE model codes/US and the
frontend-free flow, and uses generated certificates to check trusted/untrusted,
expired and wrong-hostname rejection plus HTTP/MQTT trust separation. Signature
rejection is executed; Finished guards have bounded source checks, not a full
adversarial handshake suite. Tests forbid network connections and use no account
credentials. They do not prove cloud login, device operation or complete TLS safety.

These host tests check host isolation, packaged components, persistent/UI config, narrow
proxy trust, private firewall scope and archive-only restic paths. The pinned
Serve CLI is exercised against a fake sandbox-only LocalAPI socket: untagged
rejection, scoped/idempotent routing and preservation of other listeners,
advertisements and preferences. No live Tailscale changes occur. They do not
test admin policy, client DNS, Amazon login, device discovery, the running HA
service, or recovery on hardware.

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
