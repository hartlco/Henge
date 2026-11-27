#include "harness.h"
#include "translate.h"

#include <stdlib.h>

DECLARE_PROGRAM(arith);
DECLARE_PROGRAM(loop);
DECLARE_PROGRAM(condbr);
DECLARE_PROGRAM(csel_ops);
DECLARE_PROGRAM(bl_sub);
DECLARE_PROGRAM(simd_fp);
DECLARE_PROGRAM(stolen);
DECLARE_PROGRAM(pcrel);
DECLARE_PROGRAM(long_block);
DECLARE_PROGRAM(pstate_bits);
DECLARE_PROGRAM(pac);
DECLARE_PROGRAM(hop);
extern const char jit_programs_begin[], jit_programs_finish[];

static const TestProgram programs[] = {
    TEST_PROGRAM(arith),   TEST_PROGRAM(loop),   TEST_PROGRAM(condbr),
    TEST_PROGRAM(csel_ops), TEST_PROGRAM(bl_sub), TEST_PROGRAM(simd_fp),
    TEST_PROGRAM(stolen),  TEST_PROGRAM(pcrel),  TEST_PROGRAM(long_block), TEST_PROGRAM(pstate_bits), TEST_PROGRAM(hop),
};

/* The hot branch and its exit can straddle B's 128 MiB limit. Each word
   needs restoring independently, including a conditional close to the victim. */
static int test_eviction_branch_range(void) {
    static HvMachine m;
    if (hv_machine_init(&m, 160u << 20)) return 1;
    hv_jit_ring(&m.jit, 2);
    const int range = 1 << 25, split = m.jit.seg_words;
    const struct {
        int target, site, hot;
        uint32_t hot_op;
        int direct_site, direct_hot;
    } cases[] = {
        {32, range + 32, range + 33, 0x14000000, 1, 0},
        {64, range + 65, range + 64, 0x14000000, 0, 1},
        {96, range + 110, range + 109, 0x54000000, 0, 0},
        {split - 16, split + 8, split + 7, 0x54000000, 1, 1}
    };
    int bad = 0;
    for (unsigned i = 0; i < sizeof cases / sizeof *cases; i++) {
        uint32_t *base = m.jit.base, *site = base + cases[i].site, *hot = base + cases[i].hot;
        m.slots[i] = (uintptr_t)(base + cases[i].target);
        m.slot_site[i] = hv_slot_enc(&m, site);
        m.slot_stub[i] = hv_slot_enc(&m, site + 4);
        m.slot_cond[i] = hv_slot_enc(&m, hot);
        hv_slot_target_insert(&m, 0, i, cases[i].direct_site || cases[i].direct_hot);
        uint32_t branch = 0x14000004, hot_branch = cases[i].hot_op;
        if (cases[i].direct_site) bad |= !hv_branch_retarget(&branch, cases[i].target - cases[i].site);
        int to = cases[i].direct_hot ? cases[i].target : cases[i].site;
        bad |= !hv_branch_retarget(&hot_branch, to - cases[i].hot);
        hv_jit_write(&m.jit, site, &branch, 4);
        hv_jit_write(&m.jit, hot, &hot_branch, 4);
    }
    hv_jit_finish_words(&m.jit, NULL, 0); /* return MAP_JIT to executable before the eviction reads the branches */
    hv_evict_blocks(&m);
    for (unsigned i = 0; i < sizeof cases / sizeof *cases; i++) {
        uint32_t hot_branch = cases[i].hot_op;
        bad |= !hv_branch_retarget(&hot_branch, cases[i].site - cases[i].hot);
        bad |= m.slots[i] != 0 || m.slot_tseg[i] != 0 || m.jit.base[cases[i].site] != 0x14000004 ||
               m.jit.base[cases[i].hot] != hot_branch;
    }
    bad |= m.stats.evict_unchained != 4 || m.stats.evict_slot_only != 1;
    hv_machine_free(&m);
    printf("eviction at branch range limits: %s\n", bad ? "FAIL" : "ok");
    return bad;
}

/* Move an exit between segments, evict its old target, then reuse the slots after a full flush. */
static int test_incoming_slots(void) {
    static HvMachine m;
    if (hv_machine_init(&m, 1u << 20)) return 1;
    hv_jit_ring(&m.jit, 64);
    uint32_t last = m.max_slots - 1;
    m.slots[0] = m.slots[63] = m.slots[64] = m.slots[last] = 1;
    hv_slot_target_insert(&m, 0, 0, 0);
    hv_slot_target_insert(&m, 0, 63, 0);
    hv_slot_target_insert(&m, 0, 64, 0);
    hv_slot_target_insert(&m, 63, last, 0);
    hv_slot_target_remove(&m, 63);
    hv_slot_target_insert(&m, 1, 63, 0);
    hv_evict_blocks(&m);
    int bad = m.stats.evict_unchained != 2 || m.slots[0] || m.slots[64] || !m.slots[63] || !m.slots[last];
    hv_evict_blocks(&m);
    bad |= m.stats.evict_unchained != 3 || m.slots[63] || !m.slots[last];
    hv_flush_blocks(&m);
    hv_jit_ring(&m.jit, 64);
    m.slots[last] = 1;
    hv_slot_target_insert(&m, 1, last, 0);
    m.jit.end = (size_t)63 * m.jit.seg_words;
    hv_evict_blocks(&m);
    bad |= m.stats.evict_unchained != 3 || !m.slots[last];
    hv_machine_free(&m);
    printf("incoming slots across segments and full flush: %s\n", bad ? "FAIL" : "ok");
    return bad;
}

/* Enter the fallback stubs directly so a short host branch cannot skip them. */
static int test_chain_stubs(HvMachine *m, uint64_t sp) {
    uint32_t ids[2], n = 0;
    for (uint32_t i = 0; i < m->nslots && n < 2; i++)
        if (m->slot_stub[i]) ids[n++] = i;
    if (n != 2) return 1;

    static HvCpu cpu;
    hv_cpu_reset(&cpu, m);
    seed_cpu(&cpu, 27, sp);
    uint64_t lr = cpu.x[30], old[2], target[2];
    uint32_t *stub[2];
    int bad = 0;
    for (int i = 0; i < 2; i++) {
        old[i] = m->slots[ids[i]];
        m->slots[ids[i]] = 0;
        stub[i] = hv_slot_dec(m, m->slot_stub[ids[i]]);
        cpu.exit_req = 0;
        cpu.last_stub = 0;
        hv_enter(&cpu, stub[i]);
        target[i] = cpu.pc;
        bad |= cpu.x[30] != lr || cpu.last_stub != (uintptr_t)&m->slots[ids[i]];
    }
    m->slots[ids[0]] = (uintptr_t)stub[1];
    for (int requested = 0; requested <= 1; requested++) {
        cpu.exit_req = requested;
        cpu.last_stub = 0;
        hv_enter(&cpu, stub[0]);
        bad |= cpu.x[30] != lr || cpu.pc != target[requested ? 0 : 1] ||
               cpu.last_stub != (requested ? 0 : (uintptr_t)&m->slots[ids[1]]);
    }
    for (int i = 0; i < 2; i++) m->slots[ids[i]] = old[i];
    printf("linked, empty and interrupted branch stubs: %s\n", bad ? "FAIL" : "ok");
    return bad;
}

/* Walk the buckets after the ring turns, including older translations of the same PC. */
static int block_chains_ok(HvMachine *m) {
    int count = 0;
    for (uint32_t h = 0; h < HV_BLOCK_HASH; h++) {
        uint32_t prev = 0;
        for (HvBlock *b = m->hash[h]; b; b = b->next) {
            if (b->hash_prev != prev || hv_block_hash(b->va, b->pa, b->flags) != h || ++count > m->nblocks)
                return 0;
            prev = (uint32_t)(b - m->blocks) + 1;
        }
    }
    return count == m->nblocks;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    static HvMachine m;
    if (hv_machine_init(&m, 4 << 20) != 0) {
        printf("machine init failed\n");
        return 1;
    }
    /* The programs' own text is guest RAM at PA = host address, so ADR and
       pointer values agree with the native run. */
    hv_machine_add_ram(&m, (uint64_t)(uintptr_t)jit_programs_begin, jit_programs_finish - jit_programs_begin,
                       (void *)jit_programs_begin, 1);
    uint8_t *stack = aligned_alloc(16384, 65536);
    hv_machine_add_ram(&m, (uint64_t)(uintptr_t)stack, 65536, stack, 0);
    uint64_t sp = (uint64_t)(uintptr_t)stack + 32768;

    m.trace = getenv("HV_TRACE") != NULL;
    int failed = test_eviction_branch_range() + test_incoming_slots();
    size_t count = sizeof programs / sizeof programs[0];
    for (size_t i = 0; i < count; i++) {
        const TestProgram *p = &programs[i];
        /* Two seeds per program: one with flags clear, one with NZCV set going in. */
        for (int variant = 0; variant < 2; variant++) {
            static HvCpu init, native, jit;
            memset(&init, 0, sizeof init);
            seed_cpu(&init, i * 2 + variant + 1, sp);
            if (variant) init.nzcv = 0xa0000000;
            run_native(p, &init, &native, NULL);
            int bad = run_jit(&m, p, &init, &jit, NULL);
            if (!bad) bad = compare_cpus(p->name, &native, &jit);
            printf("%-12s seed %d: %s\n", p->name, variant, bad ? "FAIL" : "ok");
            failed += bad != 0;
        }
    }
    failed += test_chain_stubs(&m, sp);
    /* PAC: compare against the inputs, with canonical pointers in the registers. */
    {
        static HvCpu init, jit;
        static const TestProgram pac_prog = TEST_PROGRAM(pac);
        memset(&init, 0, sizeof init);
        seed_cpu(&init, 99, sp);
        for (int r = 0; r < 31; r++) init.x[r] = r & 1 ? 0xfffffe0007123450ull + r * 8 : 0x100004000ull + r * 8;
        int bad = run_jit(&m, &pac_prog, &init, &jit, NULL);
        static HvCpu want;
        want = init;
        want.x[4] = 0;
        want.x[9] = init.x[30];  /* RETAB came back here, so x30 was restored */
        want.x[10] = init.x[30];
        if (!bad) bad = compare_cpus("pac", &want, &jit);
        printf("%-12s       : %s\n", "pac", bad ? "FAIL" : "ok");
        failed += bad != 0;
    }
    /* Again with a JIT region so small that it fills (and everything is flushed)
       in the middle of a program, chains pending and all. */
    {
        static HvMachine small;
        if (hv_machine_init(&small, 1024) != 0) return 1;
        hv_machine_add_ram(&small, (uint64_t)(uintptr_t)jit_programs_begin, jit_programs_finish - jit_programs_begin,
                           (void *)jit_programs_begin, 1);
        hv_machine_add_ram(&small, (uint64_t)(uintptr_t)stack, 65536, stack, 0);
        for (size_t i = 0; i < count; i++) {
            static HvCpu init, native, jit;
            memset(&init, 0, sizeof init);
            seed_cpu(&init, i * 2 + 1, sp);
            run_native(&programs[i], &init, &native, NULL);
            int bad = run_jit(&small, &programs[i], &init, &jit, NULL);
            if (!bad) bad = compare_cpus(programs[i].name, &native, &jit);
            if (bad) printf("%-12s with a full JIT region: FAIL\n", programs[i].name);
            failed += bad != 0;
        }
        printf("with a 1 KB JIT region: %llu flushes\n", (unsigned long long)small.stats.block_flushes);
    }
    /* Again with the code cache a ring of two 32 KB segments (whatever HV_JIT_SEGMENTS says), the programs' pages
       invalidated after every round so they are translated again and the ring comes round about once a round:
       segments taken back in the middle of programs, with exits chained into their blocks from blocks that stay. */
    {
        static HvMachine ring;
        if (hv_machine_init(&ring, 64 << 10) != 0) return 1;
        hv_jit_ring(&ring.jit, 2);
        hv_machine_add_ram(&ring, (uint64_t)(uintptr_t)jit_programs_begin, jit_programs_finish - jit_programs_begin,
                           (void *)jit_programs_begin, 1);
        hv_machine_add_ram(&ring, (uint64_t)(uintptr_t)stack, 65536, stack, 0);
        int bad_rounds = 0;
        for (int round = 0; round < 64; round++) {
            for (size_t i = 0; i < count; i++) {
                static HvCpu init, native, jit;
                memset(&init, 0, sizeof init);
                seed_cpu(&init, i * 2 + 1 + (size_t)round, sp);
                run_native(&programs[i], &init, &native, NULL);
                int bad = run_jit(&ring, &programs[i], &init, &jit, NULL);
                if (!bad) bad = compare_cpus(programs[i].name, &native, &jit);
                if (bad) printf("%-12s with a ring, round %d: FAIL\n", programs[i].name, round);
                bad_rounds += bad != 0;
            }
            if (!block_chains_ok(&ring)) {
                printf("ring hash chains, round %d: FAIL\n", round);
                return 1;
            }
            uint64_t from = (uint64_t)(uintptr_t)jit_programs_begin & ~16383ull, to = (uint64_t)(uintptr_t)jit_programs_finish;
            for (uint64_t pa = from; pa < to; pa += 16384) hv_invalidate_code(&ring, pa < (uint64_t)(uintptr_t)jit_programs_begin ? (uint64_t)(uintptr_t)jit_programs_begin : pa);
        }
        printf("with a 64 KB ring of %u segments: %llu evictions (%llu blocks dropped, %llu exits unchained), %llu full flushes\n",
               ring.jit.nseg, (unsigned long long)ring.stats.evictions, (unsigned long long)ring.stats.evict_blocks,
               (unsigned long long)ring.stats.evict_unchained, (unsigned long long)ring.stats.block_flushes);
        if (!ring.stats.evictions || !ring.stats.evict_unchained || ring.stats.block_flushes) {
            printf("ring: expected evictions that undo chained exits, and no full flush: FAIL\n");
            bad_rounds++;
        }
        failed += bad_rounds;
    }
    printf("%zu programs x 2 seeds, %d failures, %d blocks translated\n", count, failed, m.nblocks);
    return failed != 0;
}
