/* SPDX-License-Identifier: MIT */
#ifndef WIFI_PACKET_H
#define WIFI_PACKET_H
#include "trace.h"

/* Shared by BPF and native tests. Only whitelisted control metadata escapes
 * these helpers; never MAC addresses, nonce/MIC/key bytes, or packet payload. */
struct packet_view { const unsigned char *data; unsigned int len; };

static __attribute__((always_inline)) inline int
read_packet(struct packet_view v, unsigned int off, void *out, unsigned int n)
{
    if (off > v.len || n > v.len - off)
        return 0;
#ifdef __BPF__
    return bpf_probe_read_kernel(out, n, v.data + off) == 0;
#else
    memcpy(out, v.data + off, n);
    return 1;
#endif
}

static __attribute__((always_inline)) inline int
parse_key(struct packet_view v, unsigned int off, struct packet_info *p)
{
    unsigned char h[17];
    p->decode = DECODE_SHORT;
    if (!read_packet(v, off, h, sizeof(h))) return 0;
    unsigned int body_len = ((unsigned int)h[2] << 8) | h[3];
    p->decode = DECODE_NOT_KEY;
    if (h[0] < 1 || h[0] > 3 || h[1] != 3 ||
        (h[4] != 2 && h[4] != 254) || body_len < 95) return 0;
    p->decode = DECODE_SHORT;
    if (v.len - off < body_len + 4) return 0;
    p->key_info = ((__u16)h[5] << 8) | h[6];
    p->eapol_len = body_len + 4;
    p->eapol_version = h[0];
    p->descriptor_type = h[4];
    p->message = 0;
    /* Heuristic classification, not MIC verification. Exclude Request/Error/SMK.
     * Secure distinguishes ordinary RSN M4 from M2; legacy WPA can differ. */
    if ((p->key_info & 8) && !(p->key_info & (0x400 | 0x800 | 0x2000))) {
        if (p->key_info & 0x80)
            p->message = (p->key_info & 0x100) ? 3 : 1;
        else if (p->key_info & 0x100)
            p->message = (p->key_info & 0x200) ? 4 : 2;
    }
    p->replay = 0;
#ifdef __BPF__
#pragma unroll
#endif
    for (int i = 9; i < 17; i++) p->replay = (p->replay << 8) | h[i];
    p->decode = DECODE_KEY;
    return 1;
}

static __attribute__((always_inline)) inline int
parse_ethernet(struct packet_view v, unsigned int off, struct packet_info *p)
{
    unsigned char proto[2];
    p->decode = DECODE_SHORT;
    if (off > v.len || v.len - off < 14 || !read_packet(v, off + 12, proto, 2)) return 0;
    p->ether_type = ((__u16)proto[0] << 8) | proto[1];
    p->header_valid |= HEADER_ETH;
    p->decode = DECODE_NOT_EAPOL;
    if (p->ether_type != 0x888e) return 0;
    return parse_key(v, off + 14, p);
}

static __attribute__((always_inline)) inline int
parse_wifi(struct packet_view v, unsigned int off, struct packet_info *p)
{
    unsigned char hdr[24], snap[8], qos[2];
    p->decode = DECODE_SHORT;
    if (!read_packet(v, off, hdr, 2)) return 0;
    unsigned int fc = hdr[0] | ((unsigned int)hdr[1] << 8);
    p->fc = fc;
    p->header_valid |= HEADER_FC;
    p->decode = DECODE_NOT_DATA;
    if ((fc & 0x0c) != 0x08 || (fc & 0x40)) return 0;
    /* Only data frames have the header layout decoded below. In particular,
     * do not mislabel bytes from a long control frame as sequence/QoS fields. */
    p->decode = DECODE_SHORT;
    if (!read_packet(v, off, hdr, sizeof(hdr))) return 0;
    p->seq_ctrl = hdr[22] | ((__u16)hdr[23] << 8);
    p->header_valid |= HEADER_SEQ;
    unsigned int hlen = 24 + ((fc & 0x0300) == 0x0300 ? 6 : 0);
    if (fc & 0x80) {
        p->decode = DECODE_SHORT;
        if (off > v.len || hlen > v.len - off || !read_packet(v, off + hlen, qos, 2)) return 0;
        p->qos_ctrl = qos[0] | ((__u16)qos[1] << 8);
        p->header_valid |= HEADER_QOS;
        p->decode = DECODE_AMSDU;
        if (qos[0] & 0x80) return 0;
        hlen += 2 + ((fc & 0x8000) ? 4 : 0);
    }
    p->decode = DECODE_PROTECTED;
    if (fc & 0x4000) return 0;
    p->decode = DECODE_FRAGMENT;
    if ((fc & 0x0400) || (hdr[22] & 15)) return 0;
    p->decode = DECODE_SHORT;
    if (off > v.len || hlen > v.len - off ||
        !read_packet(v, off + hlen, snap, sizeof(snap))) return 0;
    p->decode = DECODE_NOT_EAPOL;
    if (snap[0] != 0xaa || snap[1] != 0xaa || snap[2] != 3 ||
        snap[3] || snap[4] || snap[5] || snap[6] != 0x88 || snap[7] != 0x8e) return 0;
    return parse_key(v, off + hlen + 8, p);
}

static __attribute__((always_inline)) inline int
parse_mt7921(struct packet_view v, struct packet_info *p)
{
    __u32 d[6] = {}; /* little-endian: x86-64 only */
    p->decode = DECODE_SHORT;
    if (!read_packet(v, 0, d, 4)) return 0;
    p->rxd0 = d[0];
    unsigned int type = d[0] >> 27;
    if (type == 7 && ((d[0] >> 16) & 15) == 1) type = 8;
    p->rx_type = type;
    p->decode = DECODE_NON_NORMAL;
    /* For other packet types only DW0 is known to be a descriptor. Do NOT
     * interpret their following bytes as RXD: they can contain MCU payload. */
    if (type != 2 && type != 8) return 0;
    p->decode = DECODE_SHORT;
    if (!read_packet(v, 0, d, sizeof(d))) return 0;
    p->rxd1 = d[1]; p->rxd2 = d[2]; p->rxd3 = d[3]; p->rxd4 = d[4];
    unsigned int off = 24;
    if (d[1] & (1U << 14)) {
        __u32 fc, sq;
        if (!read_packet(v, off, &fc, 4) || !read_packet(v, off + 8, &sq, 4)) return 0;
        /* Group 4's transmitter address is deliberately not copied out. */
        p->fc = fc & 0xffff; p->seq_ctrl = sq & 0xffff; p->qos_ctrl = sq >> 16;
        p->header_valid |= HEADER_FC | HEADER_SEQ | HEADER_QOS;
        off += 16;
    }
    if (d[1] & (1U << 11)) off += 16;
    if (d[1] & (1U << 12)) off += 8;
    if (d[1] & (1U << 13)) {
        off += 8;
        if (d[1] & (1U << 15)) off += 72;
    }
    off += 2 * ((d[2] >> 14) & 3);
    p->decode = DECODE_AMSDU;
    if (d[4] & 3) return 0;
    if (d[2] & (1U << 13)) return parse_ethernet(v, off, p);
    return parse_wifi(v, off, p);
}

/* Continuations contain payload, NOT another RX descriptor. Never copy any of
 * their bytes into diagnostic fields. Shared with sanitizer/privacy tests. */
static __attribute__((always_inline)) inline void
parse_dma(struct packet_view v, int continuation, struct packet_info *p)
{
    if (continuation) p->decode = DECODE_DMA_CONTINUATION;
    else parse_mt7921(v, p);
}
#endif
