#include "hm_ring.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct hm_ring {
    float *data;
    size_t capacity;
    _Atomic size_t head;  // total floats written (producer)
    _Atomic size_t tail;  // total floats read (consumer)
    _Atomic uint64_t dropped;
};

hm_ring *hm_ring_create(size_t capacity_floats) {
    hm_ring *r = calloc(1, sizeof(hm_ring));
    if (!r) return NULL;
    r->data = calloc(capacity_floats, sizeof(float));
    if (!r->data) { free(r); return NULL; }
    r->capacity = capacity_floats;
    return r;
}

void hm_ring_destroy(hm_ring *r) {
    if (!r) return;
    free(r->data);
    free(r);
}

size_t hm_ring_available(const hm_ring *r) {
    return atomic_load_explicit(&((hm_ring *)r)->head, memory_order_acquire) -
           atomic_load_explicit(&((hm_ring *)r)->tail, memory_order_acquire);
}

uint64_t hm_ring_dropped(const hm_ring *r) {
    return atomic_load_explicit(&((hm_ring *)r)->dropped, memory_order_relaxed);
}

int hm_ring_write(hm_ring *r, const float *src, size_t count) {
    size_t head = atomic_load_explicit(&r->head, memory_order_relaxed);
    size_t tail = atomic_load_explicit(&r->tail, memory_order_acquire);
    if (r->capacity - (head - tail) < count) {
        atomic_fetch_add_explicit(&r->dropped, count, memory_order_relaxed);
        return 0;
    }
    size_t start = head % r->capacity;
    size_t first = count < r->capacity - start ? count : r->capacity - start;
    memcpy(r->data + start, src, first * sizeof(float));
    memcpy(r->data, src + first, (count - first) * sizeof(float));
    atomic_store_explicit(&r->head, head + count, memory_order_release);
    return 1;
}

size_t hm_ring_read(hm_ring *r, float *dst, size_t count) {
    size_t tail = atomic_load_explicit(&r->tail, memory_order_relaxed);
    size_t head = atomic_load_explicit(&r->head, memory_order_acquire);
    size_t n = head - tail < count ? head - tail : count;
    size_t start = tail % r->capacity;
    size_t first = n < r->capacity - start ? n : r->capacity - start;
    memcpy(dst, r->data + start, first * sizeof(float));
    memcpy(dst + first, r->data, (n - first) * sizeof(float));
    atomic_store_explicit(&r->tail, tail + n, memory_order_release);
    return n;
}

void hm_ring_note_dropped(hm_ring *r, uint64_t count) {
    atomic_fetch_add_explicit(&r->dropped, count, memory_order_relaxed);
}

struct hm_atomic_u64 { _Atomic uint64_t value; };

hm_atomic_u64 *hm_atomic_create(uint64_t initial) {
    hm_atomic_u64 *c = calloc(1, sizeof(hm_atomic_u64));
    if (c) atomic_init(&c->value, initial);
    return c;
}

void hm_atomic_destroy(hm_atomic_u64 *c) { free(c); }

uint64_t hm_atomic_load(const hm_atomic_u64 *c) {
    return atomic_load_explicit(&((hm_atomic_u64 *)c)->value, memory_order_acquire);
}

void hm_atomic_store(hm_atomic_u64 *c, uint64_t v) { atomic_store_explicit(&c->value, v, memory_order_release); }

uint64_t hm_atomic_add(hm_atomic_u64 *c, uint64_t d) {
    return atomic_fetch_add_explicit(&c->value, d, memory_order_acq_rel) + d;
}
