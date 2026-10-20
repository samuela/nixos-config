/* SPDX-License-Identifier: MIT */
#include <assert.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include "packet.h"

static void put32(unsigned char *p, uint32_t v)
{
    for (int i = 0; i < 4; i++) p[i] = v >> (8 * i);
}
static unsigned int key(unsigned char *p, unsigned int info)
{
    memset(p, 0, 99);
    p[0] = 2; p[1] = 3; p[3] = 95; p[4] = 2;
    p[5] = info >> 8; p[6] = info;
    p[9] = 0x12; p[16] = 0x34;
    return 99;
}
static unsigned int make(unsigned char *b, unsigned int groups,
                         int ether, int qos, int pad, unsigned int info)
{
    memset(b, 0, 512);
    put32(b, 2U << 27);
    put32(b + 4, groups);
    put32(b + 8, (ether ? 1U << 13 : 0) | ((unsigned int)pad << 14));
    unsigned int off = 24;
    /* Descriptor layout reviewed against Linux 7.2.8 mt7921_mac_fill_rx(). */
    if (groups & (1 << 14)) off += 16;
    if (groups & (1 << 11)) off += 16;
    if (groups & (1 << 12)) off += 8;
    if (groups & (1 << 13)) {
        off += 8;
        if (groups & (1 << 15)) off += 72;
    }
    off += 2 * pad;
    if (ether) {
        b[off + 12] = 0x88; b[off + 13] = 0x8e;
        off += 14;
    } else {
        b[off] = qos ? 0x88 : 0x08;
        b[off + 1] = 2; /* From DS */
        off += qos ? 26 : 24;
        const unsigned char snap[] = {0xaa, 0xaa, 3, 0, 0, 0, 0x88, 0x8e};
        memcpy(b + off, snap, sizeof(snap));
        off += sizeof(snap);
    }
    return off + key(b + off, info);
}
static int parse(unsigned char *b, unsigned int n, struct packet_info *p)
{
    memset(p, 0, sizeof(*p));
    return parse_mt7921((struct packet_view){b, n}, p);
}

int main(void)
{
    unsigned char b[512];
    struct packet_info p;
    uint32_t seed = 42; /* deterministic fuzz inputs */
    unsigned int cases = 0;
    for (unsigned int g = 0; g < 32; g++) {
        for (int ether = 0; ether < 2; ether++) {
            for (int qos = 0; qos < 2; qos++) {
                for (int pad = 0; pad < 4; pad++) {
                    const unsigned int infos[] = {0x8a, 0x10a, 0x13ca, 0x30a};
                    for (int m = 1; m <= 4; m++) {
                        unsigned int n = make(b, g << 11, ether, qos, pad, infos[m - 1]);
                        assert(parse(b, n, &p) && p.message == m);
                        assert(p.replay == 0x1200000000000034ULL);
                        for (unsigned int cut = 0; cut < n; cut++)
                            assert(!parse(b, cut, &p));
                        cases++;
                    }
                }
            }
        }
    }
    unsigned int n = make(b, 0, 1, 0, 0, 0x8a);
    put32(b, 8U << 27); /* normal MCU */
    assert(parse(b, n, &p));
    put32(b, (7U << 27) | (1U << 16)); /* special RX event */
    assert(parse(b, n, &p));
    put32(b, 7U << 27);
    assert(!parse(b, n, &p));
    n = make(b, 0, 1, 0, 0, 0x8a);
    b[24 + 12] = 0x08; b[24 + 13] = 0x00; /* IPv4 */
    assert(!parse(b, n, &p));
    n = make(b, 0, 1, 0, 0, 0x8a);
    b[24 + 14 + 1] = 0; /* EAP packet, not EAPOL-Key */
    assert(!parse(b, n, &p));
    n = make(b, 0, 0, 0, 0, 0x8a);
    b[25] |= 0x40; /* encrypted frame cannot be decoded as plaintext */
    assert(!parse(b, n, &p));
    n = make(b, 0, 0, 0, 0, 0x8a);
    b[46] = 1; /* noninitial fragment */
    assert(!parse(b, n, &p));
    n = make(b, 0, 0, 1, 0, 0x8a);
    b[48] = 0x80; /* A-MSDU */
    assert(!parse(b, n, &p));
    n = make(b, 0, 1, 0, 0, 0x8a);
    put32(b + 16, 3); /* descriptor A-MSDU */
    assert(!parse(b, n, &p));
    n = make(b, 0, 0, 0, 0, 0x108); /* SAE descriptor version zero M2 */
    assert(parse(b, n, &p) && p.message == 2);
    assert(p.eapol_len == 99 && p.eapol_version == 2 && p.descriptor_type == 2);
    n = make(b, 0, 0, 0, 0, 0x308);
    assert(parse(b, n, &p) && p.message == 4);
    n = make(b, 0, 0, 0, 0, 0x508); /* Error flag, not M2 */
    assert(parse(b, n, &p) && p.message == 0);

    /* Unsupported packets still yield bounded diagnostic metadata. */
    n = make(b, 0, 0, 1, 0, 0x13c8);
    b[25] |= 0x40;
    assert(!parse(b, n, &p) && p.decode == DECODE_PROTECTED && (p.fc & 0x4000));
    n = make(b, 0, 0, 0, 0, 0x13c8);
    b[25] |= 0x04;
    assert(!parse(b, n, &p) && p.decode == DECODE_FRAGMENT);
    n = make(b, 0, 0, 1, 0, 0x13c8);
    b[48] = 0x80;
    assert(!parse(b, n, &p) && p.decode == DECODE_AMSDU && p.qos_ctrl == 0x80);
    n = make(b, 0, 1, 0, 0, 0x13c8);
    b[36] = 0x81; b[37] = 0;
    assert(!parse(b, n, &p) && p.decode == DECODE_NOT_EAPOL && p.ether_type == 0x8100);

    /* Privacy non-interference: changed MAC/nonce/MIC/payload bytes never change
     * metadata, including undecoded control/MCU packets and RX group-4 TA. */
    struct packet_info expected;
    n = make(b, 1U << 14, 1, 0, 0, 0x13c8);
    assert(parse(b, n, &expected));
    b[26] = 0x12; b[27] = 0x34; memset(b + 28, 0x56, 4); /* group-4 TA */
    memset(b + 40, 0x78, 12); /* Ethernet DA/SA */
    memset(b + 40 + 14 + 17, 0xa5, 99 - 17); /* key material/body, not metadata */
    assert(parse(b, n, &p) && !memcmp(&p, &expected, sizeof(p)));
    put32(b, 7U << 27);
    assert(!parse(b, n, &expected) && expected.decode == DECODE_NON_NORMAL);
    memset(b + 4, 0xb6, n - 4);
    assert(!parse(b, n, &p) && !memcmp(&p, &expected, sizeof(p)));
    n = make(b, 0, 0, 0, 0, 0x8a);
    b[24] = 0x94; /* long control packet: bytes 22+ are NOT data-header fields */
    assert(!parse(b, n, &expected) && expected.header_valid == HEADER_FC);
    memset(b + 26, 0xc7, n - 26);
    assert(!parse(b, n, &p) && !memcmp(&p, &expected, sizeof(p)));
    assert(!parse_ethernet((struct packet_view){b, sizeof(b)}, ~0U, &p));
    assert(!parse_wifi((struct packet_view){b, sizeof(b)}, ~0U, &p));

    /* DMA continuation privacy: not even DW0 is a descriptor. A NULL data
     * pointer with a nonzero length must be safe on this branch. */
    memset(&p, 0, sizeof(p));
    parse_dma((struct packet_view){NULL, 512}, 1, &p);
    memset(&expected, 0, sizeof(expected)); expected.decode = DECODE_DMA_CONTINUATION;
    assert(!memcmp(&p, &expected, sizeof(p)));
    n = make(b, 0, 0, 1, 0, 0x13ca);
    memset(&p, 0, sizeof(p));
    parse_dma((struct packet_view){b, n}, 0, &p);
    assert(p.message == 3 && p.decode == DECODE_KEY);
    assert(DMA_WINDOW_MAX == 4096 && RX_WINDOW_MAX == 256);

    struct rx_window w = {.id = 123};
    assert(!window_live(&w, 122));
    assert(window_live(&w, 123));
    assert(window_live(&w, 123 + RX_WINDOW_NS - 1));
    assert(!window_live(&w, 123 + RX_WINDOW_NS));
    assert(!window_live(&w, 123 + RX_WINDOW_NS + 19026000000000ULL)); /* suspend */
    w.id = 0;
    assert(!window_live(&w, 123));
    w.id = ~0ULL - 5;
    assert(window_live(&w, ~0ULL)); /* subtraction avoids deadline overflow */
    /* Include malformed and truncated data under ASan/UBSan. */
    for (unsigned int i = 0; i < 10000; i++) {
        for (unsigned int j = 0; j < sizeof(b); j++) {
            seed = seed * 1664525U + 1013904223U;
            b[j] = seed >> 24;
        }
        parse(b, i % sizeof(b), &p);
    }
    printf("%u descriptor/handshake combinations, all truncations, edge cases and 10000 seeded fuzz inputs passed\n", cases);
    return 0;
}
