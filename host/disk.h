#ifndef HENGEVM_DISK_H
#define HENGEVM_DISK_H

#include <stdint.h>
#include <sys/uio.h>

/* A raw disk image file, optionally starting `offset` bytes in (QEMU's vmapple
   notes say the first 16 KB of auxiliary.bin is metadata the guest never sees). */
typedef struct HvDisk {
    int fd;
    int wfd;         /* writes, past the host's cache (F_NOCACHE); -1: through fd */
    uint64_t offset;
    uint64_t size;   /* bytes visible to the guest */
    int readonly;
} HvDisk;

int hv_disk_open(HvDisk *d, const char *path, uint64_t offset, int readonly);
void hv_disk_close(HvDisk *d);
/* Return 0, or -1 on an I/O error or an access past the end. */
int hv_disk_read(HvDisk *d, uint64_t off, void *buf, uint64_t len);
/* Vector operations return bytes transferred, zero for scalar fallback, or -1 on error. */
ssize_t hv_disk_readv(HvDisk *d, uint64_t off, const struct iovec *buffers, int count);
ssize_t hv_disk_writev(HvDisk *d, uint64_t off, const struct iovec *buffers, int count);
int hv_disk_write(HvDisk *d, uint64_t off, const void *buf, uint64_t len);
int hv_disk_flush(HvDisk *d);

#endif
