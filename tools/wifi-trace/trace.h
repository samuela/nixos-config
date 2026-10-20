/* SPDX-License-Identifier: MIT */
#ifndef WIFI_TRACE_H
#define WIFI_TRACE_H
#include <linux/types.h>

#define TRACE_FORMAT 3
#define RX_WINDOW_NS 8000000000ULL
#define RX_WINDOW_MAX 256U
#define DMA_WINDOW_MAX 4096U
#define TX_HW_ENCAP (1U << 14) /* Linux 7.2.8 ieee80211_tx_info.flags */
#define TX_STAT_ACK (1U << 9)

enum trace_stage {
    DRIVER_RX = 1, MT76_RX, MAC80211_RX, CONTROL_PORT, CONTROL_RESULT,
    SKB_FREE, SKB_CONSUME, REGD_ENTER, CLC_ENTER, REGD_RETURN,
    RESUME_ENTER, RESUME_RETURN, RX_DESCRIPTOR, WINDOW_OPEN, WINDOW_CLOSE,
    WINDOW_LIMIT, TX_QUEUE_ENTER, TX_QUEUE_RESULT, TX_DESCRIPTOR, TX_STATUS,
    DMA_RX, DMA_LIMIT, PM_STATE, PM_DRIVER_ENTER, PM_DRIVER_RETURN,
    PM_FIRMWARE_ENTER, PM_FIRMWARE_RETURN, SUSPEND_ENTER, SUSPEND_RETURN,
};
enum decode_reason {
    DECODE_NONE, DECODE_KEY, DECODE_SHORT, DECODE_NON_NORMAL, DECODE_AMSDU,
    DECODE_PROTECTED, DECODE_FRAGMENT, DECODE_NOT_DATA, DECODE_NOT_EAPOL,
    DECODE_NOT_KEY, DECODE_DMA_CONTINUATION,
};
enum header_valid { HEADER_FC = 1, HEADER_SEQ = 2, HEADER_QOS = 4, HEADER_ETH = 8 };
enum stat_key {
    RING_LOST, MAP_ERRORS, DRIVER_EAPOL, CONTROL_EAPOL, NESTED_CONTROL,
    TX_ENTER_COUNT, TX_RESULT_COUNT, TX_DESC_COUNT, TX_STATUS_COUNT,
    TX_PAIRING_LOST, TX_DECODE_MISS, TX_DESC_READ_ERROR,
    WINDOW_COUNT, WINDOW_SEEN, WINDOW_EMITTED, WINDOW_SKIPPED, WINDOW_RACE,
    DMA_SEEN, DMA_EMITTED, DMA_SKIPPED, DMA_EMPTY, DMA_READ_ERROR,
    DMA_PAIRING_LOST, PM_PAIRING_LOST, PM_CALLS,
    STAT_COUNT,
};

struct packet_info {
    __u64 replay, window_id;
    __u32 rxd0, rxd1, rxd2, rxd3, rxd4;
    __u32 skb_len, linear_len, eapol_len;
    __u16 key_info, fc, seq_ctrl, qos_ctrl, ether_type;
    __u8 message, decode, header_valid, rx_type, eapol_version, descriptor_type;
};

struct trace_event {
    __u64 time_ns, packet_id, location;
    struct packet_info packet;
    __u32 stage, cpu, flags;
    __s32 result;
    /* TXD4 and TXD5[31:16] are never exported (packet-number fields).
     * Other descriptor words are control metadata, not the TX packet body. */
    __u32 txd[8];
    __u32 key_present;
    __u64 phy_state;
};

struct rx_window { __u64 id; __u32 claimed, dma_claimed; };
static __attribute__((always_inline)) inline int
window_live(const struct rx_window *w, __u64 now)
{
    return w && w->id && now >= w->id && now - w->id < RX_WINDOW_NS;
}
#endif
