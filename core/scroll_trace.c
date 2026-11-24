#include "scroll_trace.h"

#include <dispatch/dispatch.h>
#include <os/lock.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

enum { window_ns = 2000000000, slow_ns = 25000000 };
typedef struct {
    uint64_t range_ns;
    unsigned ranges, batches, fallbacks, frames;
    uint32_t fallback_at[8192], frame_at[512]; /* ns from the first scroll report */
} ScrollSample;

_Atomic uint64_t hv_scroll_trace_start_ns;
static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
static ScrollSample sample;

uint64_t hv_scroll_trace_now(void) {
    /* MTLDrawable.presentedTime uses the same host uptime, in seconds. */
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

static int in_capture(uint64_t capture, uint64_t at) {
    return capture && capture == hv_scroll_trace_active() && at - capture < window_ns;
}

void hv_scroll_trace_range(uint64_t capture, uint64_t since) {
    uint64_t end = hv_scroll_trace_now();
    os_unfair_lock_lock(&lock);
    if (in_capture(capture, since)) {
        sample.ranges++;
        sample.range_ns += (end < capture + window_ns ? end : capture + window_ns) - since;
    }
    os_unfair_lock_unlock(&lock);
}

void hv_scroll_trace_batch(uint64_t capture, uint64_t first_fallback) {
    uint64_t at = first_fallback ? first_fallback : hv_scroll_trace_now();
    os_unfair_lock_lock(&lock);
    if (in_capture(capture, at)) {
        sample.batches++;
        if (first_fallback) {
            if (sample.fallbacks < sizeof sample.fallback_at / sizeof *sample.fallback_at)
                sample.fallback_at[sample.fallbacks] = (uint32_t)(at - capture);
            sample.fallbacks++;
        }
    }
    os_unfair_lock_unlock(&lock);
}

void hv_scroll_trace_frame(uint64_t capture, uint64_t presented) {
    os_unfair_lock_lock(&lock);
    if (in_capture(capture, presented)) {
        if (sample.frames < sizeof sample.frame_at / sizeof *sample.frame_at)
            sample.frame_at[sample.frames] = (uint32_t)(presented - capture);
        sample.frames++;
    }
    os_unfair_lock_unlock(&lock);
}

static int compare_ns(const void *a, const void *b) {
    uint32_t x = *(const uint32_t *)a, y = *(const uint32_t *)b;
    return (x > y) - (x < y);
}

static void report(void *context) {
    uint64_t capture = (uintptr_t)context;
    os_unfair_lock_lock(&lock);
    if (capture != hv_scroll_trace_active()) {
        os_unfair_lock_unlock(&lock);
        return;
    }
    ScrollSample s = sample;
    atomic_store(&hv_scroll_trace_start_ns, 0);
    os_unfair_lock_unlock(&lock);

    unsigned nf = sizeof s.frame_at / sizeof *s.frame_at, nb = sizeof s.fallback_at / sizeof *s.fallback_at;
    if (s.frames < nf) nf = s.frames;
    if (s.fallbacks < nb) nb = s.fallbacks;
    qsort(s.frame_at, nf, sizeof *s.frame_at, compare_ns);
    qsort(s.fallback_at, nb, sizeof *s.fallback_at, compare_ns);
    unsigned slow = 0, slow_with_fallback = 0, other_with_fallback = 0, b = 0;
    uint32_t longest = 0;
    for (unsigned f = 1; f < nf; f++) {
        uint32_t from = s.frame_at[f - 1], to = s.frame_at[f], gap = to - from;
        while (b < nb && s.fallback_at[b] <= from) b++;
        int used_fallback = b < nb && s.fallback_at[b] <= to;
        if (gap > longest) longest = gap;
        if (gap > slow_ns) {
            slow++;
            slow_with_fallback += used_fallback;
        } else {
            other_with_fallback += used_fallback;
        }
    }
    fprintf(stderr, "hengevm: scroll-trace 2s: kernel scans (>64 MiB)=%u elapsed=%.3f ms; "
            "fallback batches=%u/%u; displayed=%u first=%.1f ms tail=%.1f ms max gap=%.1f ms; "
            "gaps with fallback: >25 ms=%u/%u, <=25 ms=%u/%u%s\n",
            s.ranges, s.range_ns / 1e6, s.fallbacks, s.batches, s.frames,
            nf ? s.frame_at[0] / 1e6 : -1., nf ? (window_ns - s.frame_at[nf - 1]) / 1e6 : -1.,
            longest / 1e6, slow_with_fallback, slow, other_with_fallback, nf ? nf - 1 - slow : 0,
            nf < s.frames || nb < s.fallbacks ? " (timestamps truncated)" : "");
}

void hv_scroll_trace_begin(void) {
    if (hv_scroll_trace_active()) return;
    os_unfair_lock_lock(&lock);
    if (hv_scroll_trace_active()) {
        os_unfair_lock_unlock(&lock);
        return;
    }
    uint64_t start = hv_scroll_trace_now();
    memset(&sample, 0, sizeof sample);
    atomic_store(&hv_scroll_trace_start_ns, start);
    os_unfair_lock_unlock(&lock);
    /* A presentation handler can arrive after its on-screen timestamp. */
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, window_ns + 250ll * NSEC_PER_MSEC),
                     dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), (void *)(uintptr_t)start, report);
}

void hv_scroll_trace_cancel(void) {
    os_unfair_lock_lock(&lock);
    atomic_store(&hv_scroll_trace_start_ns, 0);
    os_unfair_lock_unlock(&lock);
}
