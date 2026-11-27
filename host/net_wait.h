#ifndef HENGEVM_NET_WAIT_H
#define HENGEVM_NET_WAIT_H

#include <poll.h>
#include <stdint.h>

#define HV_NET_MAX_POLL 1024

typedef struct HvNetWaitStats {
    int peak_sockets;
    uint64_t waits, reused;
} HvNetWaitStats;

/* The NAT worker passes fresh poll slots on every wait. Slot zero is the wake pipe. */
int hv_net_wait(struct pollfd *fds, int count, int timeout, HvNetWaitStats *stats);
/* Discard subscriptions when a socket is replaced or the worker stops. */
void hv_net_wait_reset(void);

#endif
