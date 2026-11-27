#include "net_wait.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

enum { SLOTS = 12 };
static HvNetWaitStats stats;
static struct pollfd slots[SLOTS];
static int peers[SLOTS];

/* Repeat each wait so the cached path sees the same readiness as poll. */
static void compare(int n) {
    struct pollfd expected[SLOTS];
    for (int pass = 0; pass < 3; pass++) {
        for (int i = 0; i < n; i++) slots[i].revents = 0;
        memcpy(expected, slots, n * sizeof *slots);
        int ready = poll(expected, (nfds_t)n, 0);
        assert(ready >= 0 && hv_net_wait(slots, n, 0, &stats) == ready);
        for (int i = 0; i < n; i++) assert(slots[i].revents == expected[i].revents);
    }
}

static void open_pair(int i) {
    int pair[2];
    assert(!socketpair(AF_UNIX, SOCK_STREAM, 0, pair));
    slots[i] = (struct pollfd){pair[0], POLLIN | POLLPRI, 0};
    peers[i] = pair[1];
}

int main(void) {
    for (int i = 0; i < SLOTS; i++) open_pair(i);
    compare(2);
    assert(stats.reused == 0);
    compare(SLOTS);
    assert(stats.reused && stats.peak_sockets == SLOTS - 1);

    assert(write(peers[1], "a", 1) == 1 && write(peers[3], "b", 1) == 1);
    slots[3].events |= POLLOUT;
    compare(SLOTS); /* one socket ready to read and write */
    slots[3].events = POLLPRI;
    compare(SLOTS); /* ordinary data does not satisfy a priority-only request */
    slots[3].events = POLLIN | POLLPRI;
    assert(!shutdown(peers[1], SHUT_WR));
    compare(SLOTS); /* hangup with an unread byte */
    char byte;
    assert(read(slots[1].fd, &byte, 1) == 1 && byte == 'a');
    compare(SLOTS);

    struct pollfd original = slots[5];
    slots[5] = slots[3];
    compare(SLOTS); /* two poll slots refer to the same descriptor */
    slots[5] = original;
    compare(SLOTS);

    hv_net_wait_reset(); /* libslirp replaces a socket, possibly with the same fd */
    close(slots[1].fd);
    close(peers[1]);
    open_pair(1);
    compare(SLOTS);
    assert(write(peers[1], "c", 1) == 1);
    compare(SLOTS);
    hv_net_wait_reset();
    for (int i = 0; i < SLOTS; i++) {
        close(slots[i].fd);
        close(peers[i]);
    }
    puts("socket waits matched poll");
    return 0;
}
