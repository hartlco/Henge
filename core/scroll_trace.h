#ifndef HENGEVM_SCROLL_TRACE_H
#define HENGEVM_SCROLL_TRACE_H

#include <stdatomic.h>
#include <stdint.h>

/* One full VM runs in the iOS process. The start time identifies its capture even
   if a drawable's callback arrives after a different VM has started. */
extern _Atomic uint64_t hv_scroll_trace_start_ns;
static inline uint64_t hv_scroll_trace_active(void) {
    return atomic_load_explicit(&hv_scroll_trace_start_ns, memory_order_relaxed);
}

void hv_scroll_trace_begin(void);
void hv_scroll_trace_cancel(void);
uint64_t hv_scroll_trace_now(void);
void hv_scroll_trace_range(uint64_t capture, uint64_t since);
void hv_scroll_trace_batch(uint64_t capture, uint64_t first_fallback);
void hv_scroll_trace_frame(uint64_t capture, uint64_t presented);

#endif
