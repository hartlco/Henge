#include "virtio_net.h"

#include <arpa/inet.h>
#include <stdlib.h>
#include <string.h>

#define F_MAC (1ull << 5)
#define F_GUEST_CSUM (1ull << 1)
#define F_GUEST_TSO4 (1ull << 7)
#define F_STATUS (1ull << 16)
#define RXQ 0
#define TXQ 1
#define VIRTQ_AVAIL_F_NO_INTERRUPT 1
#define HDR_LEN 12 /* virtio_net_hdr with num_buffers (VERSION_1) */
#define MAX_FRAME 65550

static void notify(HvVirtio *v, int q) {
    HvVirtioNet *n = v->dev;
    if (q != TXQ) return; /* new receive buffers: nothing waiting to deliver */
    static HvVirtqElem e;
    static uint8_t frame[MAX_FRAME];
    int any = 0;
    while (hv_virtq_pop(v, q, &e) > 0) {
        uint32_t len = hv_virtq_read(v, &e, HDR_LEN, frame, sizeof frame);
        if (n->transmit) n->transmit(n->opaque, frame, len);
        n->tx_frames++;
        n->tx_bytes += len;
        hv_virtq_push(v, q, &e, 0);
        any = 1;
    }
    if (any) {
        /* Publish the used index before checking whether the driver wants a TX interrupt. */
        __atomic_thread_fence(__ATOMIC_SEQ_CST);
        const uint16_t *flags = hv_phys_ptr(v->m, v->q[TXQ].avail, sizeof *flags);
        if (!flags || !(__atomic_load_n(flags, __ATOMIC_ACQUIRE) & VIRTQ_AVAIL_F_NO_INTERRUPT))
            hv_virtio_interrupt(v);
    }
}

/* Only plain TCP data segments already in this receive batch can be joined. */
typedef struct TcpSegment {
    const uint8_t *frame;
    uint32_t seq, payload;
    uint16_t id;
    uint8_t pushed;
} TcpSegment;

static uint16_t net16(const uint8_t *p) { return (uint16_t)p[0] << 8 | p[1]; }
static uint32_t net32(const uint8_t *p) { return (uint32_t)net16(p) << 16 | net16(p + 2); }
static void put16be(uint8_t *p, uint16_t v) { p[0] = (uint8_t)(v >> 8); p[1] = (uint8_t)v; }

/* Fold native words once per buffer. Both halves of a 32-bit word have the
   same weight in the Internet checksum. memcpy also covers unaligned headers. */
static uint32_t checksum_sum(const uint8_t *p, uint32_t bytes) {
    uint64_t sum = 0;
    while (bytes >= 4) {
        uint32_t word;
        memcpy(&word, p, sizeof word);
        sum += word;
        p += 4;
        bytes -= 4;
    }
    if (bytes >= 2) {
        uint16_t word;
        memcpy(&word, p, sizeof word);
        sum += word;
        p += 2;
        bytes -= 2;
    }
    if (bytes) {
        uint16_t word = 0;
        memcpy(&word, p, 1);
        sum += word;
    }
    while (sum >> 16) sum = (sum & 0xffff) + (sum >> 16);
    return ntohs((uint16_t)sum);
}

static uint16_t fold_sum(uint32_t sum) {
    while (sum >> 16) sum = (sum & 0xffff) + (sum >> 16);
    return (uint16_t)sum;
}

static int tcp_segment(TcpSegment *s, const uint8_t *frame, uint32_t len) {
    if (len <= 54 || len > 65535 + 14 || net16(frame + 12) != 0x0800) return 0;
    const uint8_t *ip = frame + 14, *tcp = ip + 20;
    if (ip[0] != 0x45 || ip[9] != 6 || (net16(ip + 6) & ~0x4000) || net16(ip + 2) + 14u != len ||
        tcp[12] != 0x50 || (tcp[13] != 0x10 && tcp[13] != 0x18) || net16(tcp + 18)) return 0;
    *s = (TcpSegment){frame, net32(tcp + 4), len - 54, net16(ip + 4), (uint8_t)(tcp[13] & 8)};
    return 1;
}

/* Compare the fields that all segments in a receive offload share. */
static int same_tcp_stream(const TcpSegment *a, const TcpSegment *b) {
    const uint8_t *ip = a->frame + 14, *next_ip = b->frame + 14;
    const uint8_t *tcp = ip + 20, *next_tcp = next_ip + 20;
    return !memcmp(a->frame, b->frame, 14) && ip[1] == next_ip[1] && ip[8] == next_ip[8] &&
           net16(ip + 6) == net16(next_ip + 6) && !memcmp(ip + 12, next_ip + 12, 8) &&
           !memcmp(tcp, next_tcp, 4) && net32(tcp + 8) == net32(next_tcp + 8) &&
           net16(tcp + 14) == net16(next_tcp + 14);
}

static int valid_segment(const TcpSegment *s) {
    const uint8_t *ip = s->frame + 14;
    uint32_t tcp_len = s->payload + 20;
    return fold_sum(checksum_sum(ip, 20)) == 0xffff &&
           fold_sum(checksum_sum(ip + 12, 8) + 6 + tcp_len + checksum_sum(ip + 20, tcp_len)) == 0xffff;
}

enum { NET_HDR_F_NEEDS_CSUM = 1, NET_HDR_GSO_TCPV4 = 1 };

typedef struct RxHeader {
    uint8_t flags, gso_type;
    uint16_t hdr_len, gso_size, csum_start, csum_offset, num_buffers;
} RxHeader;
_Static_assert(sizeof(RxHeader) == HDR_LEN, "virtio-net header layout");

/* The driver splits this buffer at gso_size boundaries. A short segment or PUSH
   can only appear at the end. Leave everything else in its original buffer. */
static int group_tcp(const uint8_t *const *frames, const uint32_t *lens, int count, uint32_t capacity,
                     uint8_t *group, uint32_t *len, RxHeader *hdr) {
    TcpSegment first, prev;
    if (count < 2 || capacity < HDR_LEN + 54 || !tcp_segment(&first, frames[0], lens[0]) || first.pushed) return 1;
    uint32_t limit = capacity - HDR_LEN;
    if (limit > 65535 + 14) limit = 65535 + 14;
    uint32_t used = lens[0];
    prev = first;
    int i;
    for (i = 1; i < count; i++) {
        TcpSegment next;
        if (!tcp_segment(&next, frames[i], lens[i]) || used > limit || next.payload > limit - used ||
            next.payload > first.payload || prev.pushed || prev.payload != first.payload ||
            prev.seq + prev.payload != next.seq || (uint16_t)(prev.id + 1) != next.id ||
            !same_tcp_stream(&first, &next)) break;
        if (i == 1 && !valid_segment(&first)) return 1;
        if (!valid_segment(&next)) break;
        if (i == 1) memcpy(group, first.frame, used);
        memcpy(group + used, next.frame + 54, next.payload);
        used += next.payload;
        prev = next;
    }
    if (i == 1) return 1;
    uint8_t *ip = group + 14, *tcp = ip + 20;
    put16be(ip + 2, (uint16_t)(used - 14));
    put16be(ip + 10, 0);
    put16be(ip + 10, (uint16_t)~fold_sum(checksum_sum(ip, 20)));
    tcp[13] = prev.frame[47];
    /* The driver finishes the TCP checksum from this pseudo-header sum. */
    put16be(tcp + 16, fold_sum(checksum_sum(ip + 12, 8) + 6 + used - 34));
    *hdr = (RxHeader){.flags = NET_HDR_F_NEEDS_CSUM, .gso_type = NET_HDR_GSO_TCPV4, .hdr_len = 54, .gso_size = (uint16_t)first.payload,
                      .csum_start = 34, .csum_offset = 16, .num_buffers = 1};
    *len = used;
    return i;
}

static int push_rx(HvVirtioNet *n, const uint8_t *const *frames, const uint32_t *lens, int count, int *notify) {
    HvVirtio *v = &n->vio;
    static HvVirtqElem e;
    if (!(v->status & 4) || !v->q[RXQ].enabled || hv_virtq_pop(v, RXQ, &e) <= 0) return 0;
    uint32_t capacity = hv_virtq_writable(&e), len = lens[0];
    const uint8_t *frame = frames[0];
    if (capacity < HDR_LEN || len > capacity - HDR_LEN) goto drop;
    RxHeader hdr = {.num_buffers = 1};
    int consumed = 1;
    uint64_t required = F_GUEST_CSUM | F_GUEST_TSO4;
    if (count > 1 && (v->driver_features & required) == required) {
        consumed = group_tcp(frames, lens, count, capacity, n->rx_group, &len, &hdr);
        if (consumed > 1) frame = n->rx_group;
    }
    if (hv_virtq_write(v, &e, 0, &hdr, HDR_LEN) != HDR_LEN ||
        hv_virtq_write(v, &e, HDR_LEN, frame, len) != len) goto drop;
    hv_virtq_push(v, RXQ, &e, HDR_LEN + len);
    *notify = 1;
    n->rx_frames += consumed;
    n->rx_buffers++;
    /* The counters measure the original Ethernet traffic. */
    n->rx_bytes += (uint64_t)len + (uint64_t)(consumed - 1) * 54;
    return consumed;

drop:
    /* Return a bad buffer empty. Later frames can still use the next one. */
    hv_virtq_push(v, RXQ, &e, 0);
    *notify = 1;
    n->rx_dropped++;
    return 1;
}

int hv_virtio_net_receive(HvVirtioNet *n, const uint8_t *frame, uint32_t len) {
    int notify = 0;
    int ok = push_rx(n, &frame, &len, 1, &notify);
    if (notify) hv_virtio_interrupt(&n->vio);
    return ok;
}

int hv_virtio_net_receive_batch(HvVirtioNet *n, const uint8_t *const *frames,
                                const uint32_t *lens, int count) {
    int notify = 0, sent = 0;
    while (sent < count) {
        int used = push_rx(n, frames + sent, lens + sent, count - sent, &notify);
        if (!used) break;
        sent += used;
    }
    if (notify) hv_virtio_interrupt(&n->vio);
    return sent;
}

HvVirtioNet *hv_virtio_net_create(HvMachine *m, HvPcie *bus, const uint8_t mac[6]) {
    HvVirtioNet *n = calloc(1, sizeof *n);
    HvVirtio *v = &n->vio;
    hv_virtio_init(v, m, 1, 0x020000, 2, F_MAC | F_STATUS | F_GUEST_CSUM | F_GUEST_TSO4);
    v->dev = n;
    v->notify = notify;
    memcpy(v->config, mac, 6);
    uint16_t status = 1, pairs = 1; /* link up */
    memcpy(v->config + 6, &status, 2);
    memcpy(v->config + 8, &pairs, 2);
    v->config_len = 12;
    hv_pcie_attach(bus, &v->pci);
    return n;
}

/* The cable out (up = 0) or back in: the guest is told its configuration changed. Device lock held. */
void hv_virtio_net_set_link(HvVirtioNet *n, int up) {
    if (!n) return;
    uint16_t status = up ? 1 : 0;
    memcpy(n->vio.config + 6, &status, 2);
    hv_virtio_config_changed(&n->vio);
}
