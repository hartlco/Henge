#import <Foundation/Foundation.h>
#import <QuartzCore/CAMetalLayer.h>
#include "pvg_lite.h"
#include "vmapple.h"
#include <assert.h>
#include <stdlib.h>
#include <unistd.h>

/* Exercise real Metal command completion while the guest board is destroyed.
   Empty execs avoid simulator limitations on guest buffer-backed textures. */
static HvMachine machine;
static HvCpu cpus[2];
static HvVmapple board;

/* Scan out three one-pixel rows on scattered pages, including a hole. The large
   surface starts its visible rows at the last entry of the first leaf. */
static void check_surface_rows(HvPvgMetal *metal, int two_levels) {
    enum { PAGE = 0x4000 };
    uint64_t ram = VMAPPLE_MEM;
    uint32_t page = (uint32_t)(ram >> 14);
    assert(hv_phys_write(&machine, VMAPPLE_IOSFC + 0x1010, &ram, sizeof ram) == 0);
    uint32_t *directory = (void *)board.ram;
    directory[0] = ((page + 1) << 2) | 1;
    uint8_t *desc = board.ram + PAGE;
    *(uint32_t *)desc = ((page + 2) << 2) | 1;
    *(uint32_t *)(desc + 4) = 'BGRA';
    *(uint64_t *)(desc + 0x18) = 3 * PAGE;
    *(uint64_t *)(desc + 0x20) = 1;
    *(uint64_t *)(desc + 0x28) = 3;
    *(uint64_t *)(desc + 0x30) = PAGE;
    *(uint32_t *)(desc + 0x60) = two_levels ? 4095 * PAGE : 0;
    uint32_t *root = (void *)(board.ram + 2 * PAGE);
    uint32_t *first = root, *next = root + 1;
    if (two_levels) {
        root[0] = ((page + 3) << 2) | 3;
        root[1] = ((page + 4) << 2) | 3;
        uint32_t *leaf = (void *)(board.ram + 3 * PAGE);
        leaf[0] = ((page + 5) << 2) | 1;
        first = leaf + 4095;
        next = (void *)(board.ram + 4 * PAGE);
    }
    first[0] = ((page + 7) << 2) | 1;
    next[0] = ((page + 6) << 2) | 3; /* a table flag where a pixel page is required */
    next[1] = ((page + 5) << 2) | 1;
    board.ram[7 * PAGE] = 19;
    board.ram[6 * PAGE] = 47;
    board.ram[5 * PAGE] = 83;
    uint32_t *swap = calloc(13, sizeof *swap);
    swap[0] = 8;
    swap[1] = 13 * sizeof *swap;
    hv_pvg_metal_submit(metal, board.pvg, 0, swap, swap[1]);
    hv_pvg_metal_quiesce(metal);
    const uint8_t *pixels;
    uint32_t w, h;
    assert(hv_pvg_metal_frame(metal, &pixels, &w, &h) == 0 && w == 1 && h == 3);
    assert(pixels[0] == 19 && pixels[4] == 0 && pixels[8] == 83);
}

int main(void) {
    alarm(30);
    for (int cycle = 0; cycle < 6; cycle++) @autoreleasepool {
        HvCfgParams cfg = {.nr_cpus = 2};
        if (hv_machine_init(&machine, 4 << 20) ||
            hv_vmapple_create(&board, &machine, cpus, 64 << 20, NULL, NULL, &cfg, NULL)) return 1;
        hv_vmapple_reset_cpu(&board);
        HvPvgMetal *metal = hv_pvg_metal_create(board.pvg);
        if (!metal) { fprintf(stderr, "Metal replay unavailable; lifecycle test cannot run\n"); return 1; }
        if (cycle < 2) check_surface_rows(metal, cycle == 1);
        CAMetalLayer *layer = [CAMetalLayer layer];
        hv_pvg_metal_set_layer(metal, (__bridge void *)layer);
        for (int i = 0; i < 64; i++) {
            uint32_t *cmd = calloc(6, sizeof *cmd);
            cmd[0] = 0x43; cmd[1] = 24; cmd[2] = i + 1;
            hv_pvg_metal_submit(metal, board.pvg, 0, cmd, 24);
        }
        hv_pvg_metal_cursor_moved(metal);
        hv_pvg_metal_set_layer(metal, NULL);
        hv_pvg_metal_destroy(metal);
        hv_vmapple_destroy(&board);
        hv_machine_free(&machine);
    }
    puts("Metal lifecycle: 6 cycles, 384 GPU completions drained");
    return 0;
}
