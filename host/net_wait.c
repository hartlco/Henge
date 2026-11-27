#include "net_wait.h"

#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <string.h>
#include <sys/event.h>
#include <sys/select.h>
#include <time.h>
#include <unistd.h>

static struct pollfd watched[HV_NET_MAX_POLL];
static int nwatched, kq = -1, use_poll;

void hv_net_wait_reset(void) {
    if (kq >= 0) close(kq);
    kq = -1;
    nwatched = use_poll = 0;
}

/* With many quiet connections, keep the kernel's read and write subscriptions between waits.
   libslirp supplies fresh poll slots and clears revents on every pass. */
int hv_net_wait(struct pollfd *pfds, int npfd, int timeout, HvNetWaitStats *stats) {
    int sockets = npfd - 1; /* pfds[0] is the wake pipe */
    stats->waits++;
    if (sockets > stats->peak_sockets) stats->peak_sockets = sockets;
    if (sockets < 8 || npfd > HV_NET_MAX_POLL) {
        if (nwatched) hv_net_wait_reset();
        return poll(pfds, (nfds_t)npfd, timeout);
    }
    size_t bytes = (size_t)npfd * sizeof *pfds;
    if (nwatched != npfd || memcmp(watched, pfds, bytes)) {
        hv_net_wait_reset();
        memcpy(watched, pfds, bytes);
        nwatched = npfd;
        return poll(pfds, (nfds_t)npfd, timeout);
    }
    if (use_poll) return poll(pfds, (nfds_t)npfd, timeout);
    static struct kevent events[2 * HV_NET_MAX_POLL];
    int changes = 0;
    if (kq < 0) {
        fd_set seen;
        FD_ZERO(&seen);
        for (int i = 0; i < npfd; i++) {
            int fd = pfds[i].fd, interest = pfds[i].events;
            if (!interest || (interest & ~(POLLIN | POLLPRI | POLLOUT)) ||
                ((interest & (POLLPRI | POLLIN)) == POLLPRI)) goto fallback;
            if (fd < 0 || fd >= FD_SETSIZE || FD_ISSET(fd, &seen)) goto fallback;
            FD_SET(fd, &seen);
            if (interest & (POLLIN | POLLPRI)) {
                int flags = EV_ADD | ((interest & POLLPRI) ? EV_OOBAND : 0);
                EV_SET(&events[changes], fd, EVFILT_READ, flags, 0, 0, (void *)(intptr_t)i);
                changes++;
            }
            if (interest & POLLOUT) {
                EV_SET(&events[changes], fd, EVFILT_WRITE, EV_ADD, 0, 0, (void *)(intptr_t)i);
                changes++;
            }
        }
        kq = kqueue();
        if (kq < 0) goto fallback;
        (void)fcntl(kq, F_SETFD, FD_CLOEXEC);
    }
    struct timespec ts = {timeout / 1000, (timeout % 1000) * 1000000L};
    int count = kevent(kq, events, changes, events, 2 * npfd, timeout < 0 ? NULL : &ts);
    if (count < 0) {
        if (errno != EINTR) goto fallback;
        hv_net_wait_reset(); /* the interrupted call may have been installing the set */
        errno = EINTR;
        return -1;
    }
    int ready = 0;
    for (int j = 0; j < count; j++) {
        const struct kevent *e = &events[j];
        if (e->flags & EV_ERROR) goto fallback;
        /* Let poll report the exact combination of flags for a hangup or urgent data. */
        if (e->flags & (EV_EOF | EV_OOBAND)) return poll(pfds, (nfds_t)npfd, 0);
        int i = (int)(intptr_t)e->udata;
        if (!pfds[i].revents) ready++;
        pfds[i].revents |= pfds[i].events & (e->filter == EVFILT_READ ? POLLIN : POLLOUT);
    }
    stats->reused++;
    return ready;
fallback:
    if (kq >= 0) close(kq);
    kq = -1;
    use_poll = 1;
    return poll(pfds, (nfds_t)npfd, timeout);
}
