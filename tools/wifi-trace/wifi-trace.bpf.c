/* SPDX-License-Identifier: GPL-2.0 */
#include <linux/bpf.h>
#include <asm/ptrace.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_core_read.h>
#include <bpf/bpf_tracing.h>
#include "packet.h"

/* Minimal CO-RE declarations: all structure offsets are relocated using BTF. */
struct sk_buff {
    unsigned int len, data_len;
    unsigned char *data;
    unsigned char cb[48];
    unsigned short protocol;
} __attribute__((preserve_access_index));
struct mt76_dev;
struct mt76_phy { struct mt76_dev *dev; unsigned long state; }
    __attribute__((preserve_access_index));
struct mt76_dev { __u32 rev; struct mt76_phy phy; }
    __attribute__((preserve_access_index));
struct mt76_rx_status { __u32 flag; } __attribute__((preserve_access_index));
struct ieee80211_rx_status { __u32 flag; } __attribute__((preserve_access_index));
struct ieee80211_tx_info { __u32 flags; } __attribute__((preserve_access_index));
struct mt76_connac_pm {
    _Bool enable:1, enable_user:1, ds_enable:1, ds_enable_user:1, suspended:1;
} __attribute__((preserve_access_index));
struct mt792x_dev { _Bool regd_change:1; struct mt76_connac_pm pm; }
    __attribute__((preserve_access_index));
struct mt76_queue {
    __u8 hw_idx, buf_offset;
    int buf_size;
    struct sk_buff *rx_head;
} __attribute__((preserve_access_index));

/* DMA dequeue is synchronous in NAPI/queue-lock context. PM calls can sleep:
 * their correlation uses task ID instead, not CPU-local storage. */
struct dma_call {
    __u64 owner, dev, len_ptr, more_ptr, drop_ptr, window;
    __u32 active, continuation, buf_size, buf_offset, hw_idx;
};
struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY); __uint(max_entries, 1);
    __type(key, __u32); __type(value, struct dma_call);
} dma_pending SEC(".maps");
struct pm_key { __u64 owner; __u32 kind, pad; };
struct pm_call { __u64 dev, window, id; };
struct {
    __uint(type, BPF_MAP_TYPE_HASH); __uint(max_entries, 128);
    __type(key, struct pm_key); __type(value, struct pm_call);
} pm_pending SEC(".maps");

struct tracked_packet { __u64 id; struct packet_info info; __u32 tx; };
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1024);
    __type(key, __u64);
    __type(value, struct tracked_packet);
} packets SEC(".maps");

struct pending_call { __u32 active; struct tracked_packet packet; };
struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, struct pending_call);
} pending SEC(".maps");

/* TX queue and descriptor writer are synchronous/non-sleeping, called while
 * holding the TX queue lock. Separate slots avoid confusing the nested writer
 * with its caller. Unexpected nesting/stale entries or owner mismatch invalidate
 * the sample and increment TX_PAIRING_LOST rather than pairing unrelated calls. */
struct tx_call {
    __u64 owner, skb, txwi, dev;
    struct tracked_packet packet;
    __u32 active, key_present;
};
struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 2);
    __type(key, __u32);
    __type(value, struct tx_call);
} tx_pending SEC(".maps");
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 8);
    __type(key, __u64);
    __type(value, struct rx_window);
} windows SEC(".maps");
struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 1 << 20);
} events SEC(".maps");
struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, STAT_COUNT);
    __type(key, __u32);
    __type(value, __u64);
} stats SEC(".maps");

static __always_inline void count(__u32 key)
{
    __u64 *v = bpf_map_lookup_elem(&stats, &key);
    if (v) __sync_fetch_and_add(v, 1);
}
static __always_inline int target(struct mt76_dev *dev)
{
    return (BPF_CORE_READ(dev, rev) >> 16) == 0x7922;
}
static __always_inline struct packet_view view(struct sk_buff *skb, struct packet_info *p)
{
    struct packet_view v = {};
    unsigned int len = BPF_CORE_READ(skb, len);
    unsigned int nonlinear = BPF_CORE_READ(skb, data_len);
    v.data = BPF_CORE_READ(skb, data);
    if (len >= nonlinear) v.len = len - nonlinear;
    p->skb_len = len; p->linear_len = v.len;
    return v;
}
static __always_inline __u32 tx_flags(struct sk_buff *skb)
{
    void *cb = __builtin_preserve_access_index(&skb->cb[0]);
    return BPF_CORE_READ((struct ieee80211_tx_info *)cb, flags);
}
static __always_inline struct trace_event *new_event(__u32 stage, const struct tracked_packet *p,
                                                    __u32 flags, __s32 result, __u64 location)
{
    struct trace_event *e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (!e) { count(RING_LOST); return 0; }
    __builtin_memset(e, 0, sizeof(*e));
    e->time_ns = bpf_ktime_get_boot_ns(); e->cpu = bpf_get_smp_processor_id();
    e->stage = stage; e->flags = flags; e->result = result; e->location = location;
    if (p) { e->packet_id = p->id; e->packet = p->info; }
    return e;
}
static __always_inline void emit(__u32 stage, const struct tracked_packet *p,
                                 __u32 flags, __s32 result, __u64 location)
{
    struct trace_event *e = new_event(stage, p, flags, result, location);
    if (e) bpf_ringbuf_submit(e, 0);
}
static __always_inline __u32 pm_flags(struct mt792x_dev *dev)
{
    return BPF_CORE_READ_BITFIELD_PROBED(dev, pm.enable) |
        (BPF_CORE_READ_BITFIELD_PROBED(dev, pm.enable_user) << 1) |
        (BPF_CORE_READ_BITFIELD_PROBED(dev, pm.ds_enable) << 2) |
        (BPF_CORE_READ_BITFIELD_PROBED(dev, pm.ds_enable_user) << 3) |
        (BPF_CORE_READ_BITFIELD_PROBED(dev, pm.suspended) << 4);
}
static __always_inline void emit_pm(__u32 stage, const struct tracked_packet *p,
                                    struct mt792x_dev *dev, int ret)
{
    struct trace_event *e = new_event(stage, p, pm_flags(dev), ret, 0);
    if (!e) return;
    e->phy_state = BPF_CORE_READ((struct mt76_dev *)dev, phy.state);
    bpf_ringbuf_submit(e, 0);
}
static __always_inline __u64 window_id(__u64 dev, __u64 now)
{
    struct rx_window *w = bpf_map_lookup_elem(&windows, &dev);
    return window_live(w, now) ? w->id : 0;
}
static __always_inline __u64 open_window(__u64 dev, __u64 now, int trigger)
{
    __u64 id = window_id(dev, now);
    if (id) return id; /* Retransmissions cannot reset the budget/deadline. */
    struct rx_window w = {.id = now};
    if (bpf_map_update_elem(&windows, &dev, &w, BPF_ANY)) { count(MAP_ERRORS); return 0; }
    struct tracked_packet p = {};
    p.info.window_id = now;
    count(WINDOW_COUNT);
    emit(WINDOW_OPEN, &p, RX_WINDOW_MAX, trigger, 0);
    /* mt792x_dev starts with the mt76/mphy union on this exact ABI. */
    emit_pm(PM_STATE, &p, (struct mt792x_dev *)dev, 0);
    return now;
}
static __always_inline void close_window(__u64 dev, __u64 now)
{
    struct rx_window *w = bpf_map_lookup_elem(&windows, &dev);
    if (!window_live(w, now)) return;
    __u64 id = w->id;
    __u32 claimed = w->claimed;
    if (__sync_val_compare_and_swap(&w->id, id, 0) != id) { count(WINDOW_RACE); return; }
    struct tracked_packet p = {};
    p.info.window_id = id;
    emit(WINDOW_CLOSE, &p, claimed, 4, 0); /* M4 accepted by host DMA queue. */
}

/* Earlier than queue_rx_skb: includes types consumed by rx_check, before skb
 * construction. Outside an armed window this is only a lookup/time check.
 * The first M1 is therefore recorded at driver_rx, not retroactively here.
 * DMA fragments bypassing rx_check are NOT covered by these snapshots. */
SEC("kprobe/mt7921_rx_check")
int BPF_KPROBE(rx_descriptor, struct mt76_dev *dev, void *data, int len)
{
    __u64 key = (__u64)dev, now = bpf_ktime_get_boot_ns();
    struct rx_window *w = bpf_map_lookup_elem(&windows, &key);
    if (!window_live(w, now)) return 0;
    __u64 id = w->id;
    __u32 slot = __sync_fetch_and_add(&w->claimed, 1);
    count(WINDOW_SEEN);
    if (w->id != id) { count(WINDOW_RACE); return 0; }
    struct tracked_packet p = {};
    p.info.window_id = id;
    if (slot >= RX_WINDOW_MAX) {
        count(WINDOW_SKIPPED);
        if (slot == RX_WINDOW_MAX) emit(WINDOW_LIMIT, &p, slot, 0, 0);
        return 0;
    }
    struct packet_view v = {.data = data, .len = len > 0 ? (__u32)len : 0};
    p.info.skb_len = p.info.linear_len = v.len; /* DMA segment length, not yet an skb */
    parse_mt7921(v, &p.info); /* Also supplies metadata/reasons when decoding fails. */
    count(WINDOW_EMITTED);
    emit(RX_DESCRIPTOR, &p, slot, 0, 0);
    return 0;
}

SEC("kprobe/mt7921_queue_rx_skb")
int BPF_KPROBE(driver_rx, struct mt76_dev *dev, int q, struct sk_buff *skb)
{
    __u64 key = (__u64)skb;
    bpf_map_delete_elem(&packets, &key); /* Eliminate stale pointer reuse. */
    if (!target(dev)) return 0;
    struct tracked_packet p = {};
    if (!parse_mt7921(view(skb, &p.info), &p.info)) return 0;
    p.id = bpf_ktime_get_boot_ns();
    p.info.window_id = p.info.message == 1 ? open_window((__u64)dev, p.id, 1) : window_id((__u64)dev, p.id);
    count(DRIVER_EAPOL);
    if (bpf_map_update_elem(&packets, &key, &p, BPF_ANY)) count(MAP_ERRORS);
    emit(DRIVER_RX, &p, 0, 0, 0);
    return 0;
}
SEC("kprobe/mt76_rx")
int BPF_KPROBE(mt76_rx, void *dev, int q, struct sk_buff *skb)
{
    __u64 key = (__u64)skb;
    struct tracked_packet *p = bpf_map_lookup_elem(&packets, &key);
    if (p && !p->tx) {
        void *cb = __builtin_preserve_access_index(&skb->cb[0]);
        emit(MT76_RX, p, BPF_CORE_READ((struct mt76_rx_status *)cb, flag), 0, 0);
    }
    return 0;
}
SEC("kprobe/ieee80211_rx_list")
int BPF_KPROBE(mac_rx, void *hw, void *sta, struct sk_buff *skb)
{
    __u64 key = (__u64)skb;
    struct tracked_packet *p = bpf_map_lookup_elem(&packets, &key);
    if (p && !p->tx) {
        void *cb = __builtin_preserve_access_index(&skb->cb[0]);
        emit(MAC80211_RX, p, BPF_CORE_READ((struct ieee80211_rx_status *)cb, flag), 0, 0);
    }
    return 0;
}
SEC("kprobe/cfg80211_rx_control_port")
int BPF_KPROBE(control_rx, void *dev, struct sk_buff *skb, int unencrypted)
{
    __u32 zero = 0;
    struct pending_call *call = bpf_map_lookup_elem(&pending, &zero);
    if (!call) return 0;
    if (call->active) { count(NESTED_CONTROL); call->active = 0; }
    if (BPF_CORE_READ(skb, protocol) != __builtin_bswap16(0x888e)) return 0;
    struct tracked_packet p = {};
    if (!parse_key(view(skb, &p.info), 0, &p.info)) return 0;
    __u64 key = (__u64)skb;
    struct tracked_packet *old = bpf_map_lookup_elem(&packets, &key);
    if (old && !old->tx) p = *old;
    else p.id = bpf_ktime_get_boot_ns();
    count(CONTROL_EAPOL);
    call->packet = p; call->active = 1;
    emit(CONTROL_PORT, &p, unencrypted, 0, 0);
    return 0;
}
SEC("kretprobe/cfg80211_rx_control_port")
int BPF_KRETPROBE(control_done, int ret)
{
    __u32 zero = 0;
    struct pending_call *call = bpf_map_lookup_elem(&pending, &zero);
    if (call && call->active) {
        emit(CONTROL_RESULT, &call->packet, 0, ret & 0xff, 0);
        call->active = 0;
    }
    return 0;
}

static __always_inline struct tx_call *tx_begin(__u32 slot)
{
    struct tx_call *call = bpf_map_lookup_elem(&tx_pending, &slot);
    if (call && call->active) { count(TX_PAIRING_LOST); call->active = 0; }
    return call;
}
static __always_inline struct tx_call *tx_end(__u32 slot)
{
    struct tx_call *call = bpf_map_lookup_elem(&tx_pending, &slot);
    if (!call || !call->active) return 0;
    call->active = 0;
    if (call->owner != bpf_get_current_pid_tgid()) { count(TX_PAIRING_LOST); return 0; }
    return call;
}
SEC("kprobe/mt76_dma_tx_queue_skb")
int BPF_KPROBE(tx_queue_enter, struct mt76_phy *phy, void *q, int qid, struct sk_buff *skb)
{
    struct tx_call *call = tx_begin(0);
    if (!call) return 0;
    struct mt76_dev *dev = BPF_CORE_READ(phy, dev);
    if (!target(dev)) return 0;
    __u64 key = (__u64)skb;
    bpf_map_delete_elem(&packets, &key);
    if (BPF_CORE_READ(skb, protocol) != __builtin_bswap16(0x888e)) return 0;
    struct tracked_packet p = {.tx = 1};
    __u32 flags = tx_flags(skb);
    struct packet_view v = view(skb, &p.info);
    int decoded = flags & TX_HW_ENCAP ? parse_ethernet(v, 0, &p.info) : parse_wifi(v, 0, &p.info);
    if (!decoded) count(TX_DECODE_MISS);
    p.id = bpf_ktime_get_boot_ns();
    p.info.window_id = (p.info.message == 2 || !decoded) ? open_window((__u64)dev, p.id, 2) : window_id((__u64)dev, p.id);
    if (bpf_map_update_elem(&packets, &key, &p, BPF_ANY)) count(MAP_ERRORS);
    call->owner = bpf_get_current_pid_tgid(); call->skb = key;
    call->dev = (__u64)dev; call->packet = p; call->active = 1;
    count(TX_ENTER_COUNT);
    emit(TX_QUEUE_ENTER, &p, flags, qid, 0);
    return 0;
}
SEC("kretprobe/mt76_dma_tx_queue_skb")
int BPF_KRETPROBE(tx_queue_exit, int ret)
{
    struct tx_call *call = tx_end(0);
    if (!call) return 0;
    /* skb may already be freed on failure: use the saved metadata only. */
    count(TX_RESULT_COUNT);
    emit(TX_QUEUE_RESULT, &call->packet, 0, ret, 0);
    if (ret >= 0 && call->packet.info.message == 4)
        close_window(call->dev, bpf_ktime_get_boot_ns());
    return 0;
}
SEC("kprobe/mt76_connac2_mac_write_txwi")
int BPF_KPROBE(txwi_enter, struct mt76_dev *dev, void *txwi, struct sk_buff *skb, void *wcid, void *key_conf)
{
    struct tx_call *call = tx_begin(1);
    if (!call || !target(dev)) return 0;
    __u64 key = (__u64)skb;
    struct tracked_packet *p = bpf_map_lookup_elem(&packets, &key);
    if (!p || !p->tx) return 0;
    call->owner = bpf_get_current_pid_tgid(); call->skb = key;
    call->txwi = (__u64)txwi; call->packet = *p;
    call->key_present = key_conf != 0; call->active = 1;
    return 0;
}
SEC("kretprobe/mt76_connac2_mac_write_txwi")
int txwi_exit(struct pt_regs *ctx)
{
    struct tx_call *call = tx_end(1);
    if (!call) return 0;
    count(TX_DESC_COUNT);
    struct trace_event *e = new_event(TX_DESCRIPTOR, &call->packet, 0, 0, 0);
    if (!e) return 0;
    e->key_present = call->key_present;
    const char *txwi = (const char *)call->txwi;
    /* Explicit whitelist: do not read/export TXD4 or packet contents. */
    int err = bpf_probe_read_kernel(&e->txd[0], 16, txwi);
    err |= bpf_probe_read_kernel(&e->txd[5], 4, txwi + 20);
    err |= bpf_probe_read_kernel(&e->txd[6], 8, txwi + 24);
    e->txd[5] &= 0xffff;
    if (err) { count(TX_DESC_READ_ERROR); e->result = -14; }
    bpf_ringbuf_submit(e, 0);
    return 0;
}
SEC("kprobe/mt76_tx_status_skb_done")
int BPF_KPROBE(tx_status, struct mt76_dev *dev, struct sk_buff *skb)
{
    __u64 key = (__u64)skb;
    struct tracked_packet *p = bpf_map_lookup_elem(&packets, &key);
    if (p && p->tx) {
        count(TX_STATUS_COUNT);
        emit(TX_STATUS, p, tx_flags(skb), 0, 0);
    }
    return 0;
}

static __always_inline int free_packet(__u64 key, __u64 location, int reason, int stage)
{
    struct tracked_packet *p = bpf_map_lookup_elem(&packets, &key);
    if (!p) return 0;
    emit(stage, p, 0, reason, location);
    bpf_map_delete_elem(&packets, &key);
    return 0;
}
SEC("raw_tracepoint/kfree_skb")
int freed(struct bpf_raw_tracepoint_args *ctx)
{
    return free_packet(ctx->args[0], ctx->args[1], ctx->args[2], SKB_FREE);
}
SEC("raw_tracepoint/consume_skb")
int consumed(struct bpf_raw_tracepoint_args *ctx)
{
    return free_packet(ctx->args[0], ctx->args[1], 0, SKB_CONSUME);
}
SEC("kprobe/__mt7921_mcu_regd_update")
int BPF_KPROBE(regd_enter, struct mt792x_dev *dev)
{
    emit(REGD_ENTER, 0, BPF_CORE_READ_BITFIELD_PROBED(dev, regd_change), 0, 0);
    return 0;
}
SEC("kretprobe/__mt7921_mcu_regd_update")
int BPF_KRETPROBE(regd_exit, int ret) { emit(REGD_RETURN, 0, 0, ret, 0); return 0; }
SEC("kprobe/mt7921_mcu_set_clc")
int clc_enter(struct pt_regs *ctx) { emit(CLC_ENTER, 0, 0, 0, 0); return 0; }
SEC("kprobe/mt7921_pci_resume")
int resume_enter(struct pt_regs *ctx) { emit(RESUME_ENTER, 0, 0, 0, 0); return 0; }
SEC("kretprobe/mt7921_pci_resume")
int BPF_KRETPROBE(resume_exit, int ret) { emit(RESUME_RETURN, 0, 0, ret, 0); return 0; }
/* Earliest consumed-buffer boundary: after DMA synchronization, before the
 * caller's drop/length/fragment/skb-allocation decisions. No MMIO reads/writes.
 * x86-64 SysV argument 7 (bool *drop) is at entry RSP+8. Reviewed against
 * running-module BTF and disassembly; loader locks module build identities. */
SEC("kprobe/mt76_dma_dequeue")
int dma_enter(struct pt_regs *ctx)
{
    __u32 zero = 0;
    struct dma_call *c = bpf_map_lookup_elem(&dma_pending, &zero);
    if (!c) return 0;
    if (c->active) { c->active = 0; count(DMA_PAIRING_LOST); return 0; }
    struct mt76_dev *dev = (void *)PT_REGS_PARM1(ctx);
    struct mt76_queue *q = (void *)PT_REGS_PARM2(ctx);
    if ((__u8)PT_REGS_PARM3(ctx) || !target(dev)) return 0; /* bool flush */
    __u64 id = window_id((__u64)dev, bpf_ktime_get_boot_ns());
    if (!id) return 0;
    __u64 drop = 0;
    if (bpf_probe_read_kernel(&drop, sizeof(drop), (void *)(PT_REGS_SP(ctx) + 8))) {
        count(DMA_READ_ERROR); return 0;
    }
    if (!PT_REGS_PARM4(ctx) || !PT_REGS_PARM6(ctx) || !drop) {
        count(DMA_READ_ERROR); return 0;
    }
    c->owner = bpf_get_current_pid_tgid(); c->dev = (__u64)dev;
    c->len_ptr = PT_REGS_PARM4(ctx); c->more_ptr = PT_REGS_PARM6(ctx);
    c->drop_ptr = drop; c->window = id;
    c->continuation = BPF_CORE_READ(q, rx_head) != 0;
    c->buf_size = BPF_CORE_READ(q, buf_size);
    c->buf_offset = BPF_CORE_READ(q, buf_offset);
    c->hw_idx = BPF_CORE_READ(q, hw_idx); c->active = 1;
    return 0;
}
SEC("kretprobe/mt76_dma_dequeue")
int BPF_KRETPROBE(dma_exit, void *data)
{
    __u32 zero = 0;
    struct dma_call *c = bpf_map_lookup_elem(&dma_pending, &zero);
    if (!c || !c->active) return 0;
    c->active = 0;
    if (c->owner != bpf_get_current_pid_tgid()) { count(DMA_PAIRING_LOST); return 0; }
    if (!data) { count(DMA_EMPTY); return 0; }
    if ((__u64)data >= (__u64)-4095) { count(DMA_READ_ERROR); return 0; }
    struct rx_window *w = bpf_map_lookup_elem(&windows, &c->dev);
    if (!w || w->id != c->window) { count(WINDOW_RACE); return 0; }
    __u32 slot = __sync_fetch_and_add(&w->dma_claimed, 1);
    count(DMA_SEEN);
    struct tracked_packet p = {};
    p.info.window_id = c->window;
    if (slot >= DMA_WINDOW_MAX) {
        count(DMA_SKIPPED);
        if (slot == DMA_WINDOW_MAX) emit(DMA_LIMIT, &p, slot, 0, 0);
        return 0;
    }
    int len = 0;
    __u8 more = 0, drop = 0;
    int err = bpf_probe_read_kernel(&len, sizeof(len), (void *)c->len_ptr);
    err |= bpf_probe_read_kernel(&more, sizeof(more), (void *)c->more_ptr);
    err |= bpf_probe_read_kernel(&drop, sizeof(drop), (void *)c->drop_ptr);
    if (err || len < 0 || c->buf_size > 65536 || c->buf_offset > c->buf_size) {
        count(DMA_READ_ERROR); return 0;
    }
    __u32 safe_len = (__u32)len < c->buf_size ? (__u32)len : c->buf_size;
    p.info.skb_len = len; p.info.linear_len = safe_len;
    struct packet_view v = {.data = data, .len = safe_len};
    parse_dma(v, c->continuation, &p.info);
    __u32 flags = (!!more) | ((!!drop) << 1) | (c->continuation << 2) |
        (((__u32)len > c->buf_size - c->buf_offset) << 3) | (c->hw_idx << 16);
    count(DMA_EMITTED);
    emit(DMA_RX, &p, flags, slot, 0);
    return 0;
}
static __always_inline int pm_begin(struct mt792x_dev *dev, __u32 kind, __u32 stage)
{
    if (!target((struct mt76_dev *)dev)) return 0;
    struct pm_key key = {.owner = bpf_get_current_pid_tgid(), .kind = kind};
    if (bpf_map_lookup_elem(&pm_pending, &key)) {
        bpf_map_delete_elem(&pm_pending, &key); count(PM_PAIRING_LOST); return 0;
    }
    __u64 now = bpf_ktime_get_boot_ns();
    struct pm_call call = {.dev = (__u64)dev, .id = now,
        .window = window_id((__u64)dev, now)};
    if (bpf_map_update_elem(&pm_pending, &key, &call, BPF_NOEXIST)) {
        count(PM_PAIRING_LOST); return 0;
    }
    count(PM_CALLS);
    if (call.window) {
        struct tracked_packet p = {.id = call.id}; p.info.window_id = call.window;
        emit_pm(stage, &p, dev, 0);
    }
    return 0;
}
static __always_inline int pm_end(__u32 kind, __u32 stage, int ret)
{
    struct pm_key key = {.owner = bpf_get_current_pid_tgid(), .kind = kind};
    struct pm_call *call = bpf_map_lookup_elem(&pm_pending, &key);
    if (!call) return 0;
    __u64 id = call->window ? call->window : window_id(call->dev, bpf_ktime_get_boot_ns());
    if (id || ret) {
        struct tracked_packet p = {.id = call->id}; p.info.window_id = id;
        emit_pm(stage, &p, (void *)call->dev, ret);
    }
    bpf_map_delete_elem(&pm_pending, &key);
    return 0;
}
SEC("kprobe/mt792x_mcu_drv_pmctrl")
int BPF_KPROBE(pm_driver_enter, struct mt792x_dev *dev) { return pm_begin(dev, 1, PM_DRIVER_ENTER); }
SEC("kretprobe/mt792x_mcu_drv_pmctrl")
int BPF_KRETPROBE(pm_driver_exit, int ret) { return pm_end(1, PM_DRIVER_RETURN, ret); }
SEC("kprobe/mt792x_mcu_fw_pmctrl")
int BPF_KPROBE(pm_firmware_enter, struct mt792x_dev *dev) { return pm_begin(dev, 2, PM_FIRMWARE_ENTER); }
SEC("kretprobe/mt792x_mcu_fw_pmctrl")
int BPF_KRETPROBE(pm_firmware_exit, int ret) { return pm_end(2, PM_FIRMWARE_RETURN, ret); }
SEC("kprobe/mt7921_pci_suspend")
int suspend_enter(struct pt_regs *ctx) { emit(SUSPEND_ENTER, 0, 0, 0, 0); return 0; }
SEC("kretprobe/mt7921_pci_suspend")
int BPF_KRETPROBE(suspend_exit, int ret) { emit(SUSPEND_RETURN, 0, 0, ret, 0); return 0; }
char LICENSE[] SEC("license") = "GPL";
