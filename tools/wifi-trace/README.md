# MT7922 host tracer v0.5 / format 3 — prepared for this Linux 7.2.8 build

Private diagnostic, not a fix. Use the adjacent **bounded host-capture bundle**,
not the historical 7.2.2 startup instructions. Nothing is enabled by NixOS and
this package performs no radio, profile, power-setting, reconnect or reset action.

## Validation and activation boundary

The loader requires x86-64/7.2.8 and exact binary kernel notes plus seven loaded
module build notes embedded in `identity.h`. `wifi-trace --check` is unprivileged
and read-only. Any changed/unavailable identity refuses attachment. CO-RE uses
**packaged, identity-matched BTF** for structure offsets; this does not make
descriptor meanings or argument conventions portable to another kernel.

### October 17 activation failure and correction

The owner's v0.4 activation failed before attachment: `mt76_dev.rev` could not
be relocated. Linux 7.2.8 requires `CAP_SYS_ADMIN` for BTF-ID enumeration, and
libbpf 1.7.0 silently skips module BTF on that permission failure (debug-level
message). The unit intentionally lacks that broad capability. Identity checks
and the earlier metadata-only object tests did not exercise CO-RE resolution.

v0.5 does **not** grant more privileges or patch libbpf. `target-core.btf` (1,107
bytes) is an immutable minimized CO-RE target, passed via `btf_custom_path` with
no caller override/fallback. It was derived read-only from the exact running
vmlinux, mt76 and mt7921_common BTF using libbpf's split-BTF merge and bpftool's
minimizer. All kernel/module identity guards remain mandatory. No BPF program,
observation hook, retention policy or service capability changed.

`core-reference.json` binds the target and identity header hashes, plus **222
relocations** resolved against full live BTF. `test-core.py` requires every
relocation to resolve to the same field/bit offset; a missing mt76 type is a
negative regression test. Merely succeeding at BTF minimization is insufficient.
Native tests also check target parsing/presence and the explicit object options.
Provenance/exporter/full reference are in the adjacent
`activation-failure.QpyYbkZC/`. These checks still do not prove live verifier
acceptance or attachment. The failed activation's independent restoration
reported both original verbosity settings restored; no retry has been made.

Reviewed against upstream v7.2.8 mt76/MT7921 sources, loaded module BTF and
symbols. `mt76_dma_dequeue`'s seven-argument prototype was checked against the
matching on-disk module, whose ELF build ID matches the loaded module. Its
prologue pushes 48 bytes and reserves 128; the seventh argument is read at
`0xb8(%rsp)`, equivalent to entry RSP+8. The kprobe reads argument 6 from R9 and
argument 7 from entry stack. These new observations still need live calibration.

Build/native tests do **not** prove kernel-verifier acceptance, attachment,
correct runtime observation or completeness. Activation must report **all 26
probes** attached, then a naturally occurring successful handshake must show
sensible new DMA metadata and the usual M1/M3 receive / M2/M4 transmit progression.
Do not force a reconnect or suspend campaign just for calibration.

## Observation points

Original 18 programs retained:

- `mt7921_queue_rx_skb`: decoded EAPOL before driver descriptor validation.
- `mt76_rx`, `ieee80211_rx_list`: tracked receive progression.
- `cfg80211_rx_control_port` entry/return: EAPOL delivery toward nl80211.
- `kfree_skb`, `consume_skb`: tracked release, kernel reason/free site where supplied.
- `mt7921_rx_check`: bounded descriptor samples before skb allocation.
- `mt76_dma_tx_queue_skb` entry/return, `mt76_connac2_mac_write_txwi`
  entry/return, `mt76_tx_status_skb_done`: EAPOL transmit metadata/status.
- Regulatory/CLC callbacks and PCI resume entry/return.

Eight additional programs:

- `mt76_dma_dequeue` entry/return: consumed receive buffers **after DMA cache
  synchronization and before** the caller's drop, length, fragmentation and
  skb-allocation decisions. Covers initial and continuation DMA fragments that
  bypassed the old `rx_check` observation. Does not read hardware registers.
- `mt792x_mcu_drv_pmctrl` and `mt792x_mcu_fw_pmctrl` entry/return: host/firmware
  ownership requests, results and software power-state bits. These calls sleep;
  correlation uses task ID, not per-CPU slots. Normal calls emit when their
  entry or return overlaps a handshake window; errors emit outside it as well.
  PM-event `packet_id` is the call's entry boot timestamp for pairing. A return
  may have no emitted entry when the call began before the window opened.
- PCI suspend entry/return.

`pm_state` also records state at window opening. `phy_state` is the current
`mt76_phy.state` bitmap, **not a hardware register readback**. In the reviewed
source, bit 15 is `MT76_STATE_PM`, bit 13 `MT76_STATE_SUSPEND`, bit 12
`MT76_STATE_POWER_OFF`, bit 8 `MT76_RESET`, bit 2 `MT76_STATE_RUNNING`.
PM-event `flags` bits 0..4 are enable, enable_user, ds_enable, ds_enable_user,
suspended. A PM wrapper's zero return can also mean the transition was skipped;
it is not by itself proof of hardware wake/sleep. No power setting is changed.

## Coverage, budgets and interpretation

Decoded M1 or outbound M2 opens an 8-second window; undecodable outbound EAPOL
can also open one. Retransmissions do not extend/replenish it. Host DMA acceptance
of M4 closes it early. Within a window:

- Up to **4,096 consumed DMA buffers**, independent of the old budget.
- Up to **256 `rx_check` descriptors**.
- Explicit limit events and omission counters. The opening M1 has already passed
  earlier DMA hooks; its earliest record is ordinarily `driver_rx`.

DMA `flags`: bit 0 `more`, bit 1 `drop`, bit 2 continuation (`rx_head` already
present), bit 3 length exceeds the queue's data capacity; bits 16..23 hardware
queue index. `result` is the sample's zero-based budget slot. Continuation bytes
are **never parsed or exported** as descriptors (`decode=10`). This prevents
payload/key material from being mistaken for descriptor words. Empty dequeues,
read failures, pairing failures, cap omissions and window races are counted.

Initial DMA samples retain the existing whitelisted decoder: normal RX types
2/8 (and type 7 with flag 1, reclassified as 8). Other types expose only RXD0;
never their following MCU payload. Normal RXD0–4 and recognized protocol fields
are exported, but no addresses, packet bodies, nonces, MICs or keys. Group-4
transmitter addresses and group-1 packet numbers are not exported. TXD4 is zero;
TXD5's upper packet-number bits are removed.

Important limits:

- Firmware/hardware rejection **before host DMA completion remains invisible**.
- This is not universal assembly/decoding of fragmented, encrypted, A-MSDU, VLAN
  or non-linear frames. Continuation metadata expands coverage, not decoding.
- `mt7921_mac_fill_rx` is inlined in the loaded module. No unsafe offset probe
  was added: generic release locations/reasons and descriptor flags may narrow
  a discard, but a driver-specific errno is not always available.
- `control_result=1` is kernel delivery success, not proof userspace handled M3.
- A nonnegative TX queue result is a queue index, not on-air transmission proof.
- ACKs are normally firmware/hardware generated; this does not identify the
  transmitter of a monitor-observed ACK or directly log every ACK transmission.
- Zero tracer losses never prove complete radio reception. Verify limits,
  omissions, decoder coverage and a successful control before negative claims.
- Probes can affect timing; overhead is not benchmarked. Stop if disruptive.

Default standalone output still stops at 16 MiB JSONL or its optional boot-clock
deadline. **The rolling bundle instead uses `--stream`: pipe-only, no elapsed-time
or cumulative-byte cutoff.** Only use that option with the supplied bounded
consumer; an arbitrary pipe consumer could otherwise spool unlimited output.
A regular file/terminal is refused in stream mode. The default file cap remains.

The loader emits cumulative counter/checkpoint batches at startup, every 30s and
shutdown, so rotating old segments does not remove the only loss information.
Live checkpoints are not atomic across counters. They include missed-probe
coverage (24 kprobe/kretprobe counters; the other two are raw tracepoints).
The consumer carries the latest checkpoint into archived window headers/footers.
The pipe is bounded; a stalled consumer backpressures the loader and can cause
accounted BPF ring loss. Consumer exit causes producer failure, never file fallback.
No probe detach/re-attach is used for rotation. All 26 probe programs are unchanged.

On stop the loader detaches producers, drains the finite ring and reports final
counters. Abrupt termination/disk failure or a consumer that cannot drain can
prevent a complete footer; do not infer zero loss. Snapshot/detachment has a small
race. There is no automatic restart. See the parent README for actual retention
quotas, candidate triggers and the system-journal caveat.

Resource limits: 1 MiB ring, 1,024 tracked skb entries, eight windows, 128 PM
calls, bounded per-CPU synchronous DMA/TX/control slots. No BPF pinning. Module
references may prevent unload: stop capture before unloading Wi-Fi modules.

## Evidence and tests

The parent preparation directory retains source snapshots, raw BTF, the module
ELF/disassembly, identity/prototype checks, builds and MIC-check results. Historical
v0.2 is unchanged in `tracer-before/` and in the repository.

Native ASan/UBSan tests exercise 2,048 descriptor/handshake combinations,
truncations, unsupported types, privacy non-interference, continuation privacy,
window limits and 10,000 seeded malformed inputs. Loader tests inspect all 26
programs/maps without loading BPF, test serialization, redaction, caps, malformed
event ABI and notification sockets. Privileged activation remains owner-only.
