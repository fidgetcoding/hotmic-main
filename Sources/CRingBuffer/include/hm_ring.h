#ifndef HM_RING_H
#define HM_RING_H

#include <stddef.h>
#include <stdint.h>

/// Single-producer / single-consumer lock-free float ring. Producer = audio IO thread.
typedef struct hm_ring hm_ring;

hm_ring *hm_ring_create(size_t capacity_floats);
void hm_ring_destroy(hm_ring *ring);

/// Writes all `count` floats or none. Returns 1 on success, 0 if full (dropped count incremented).
int hm_ring_write(hm_ring *ring, const float *src, size_t count);
/// Reads up to `count` floats. Returns number read.
size_t hm_ring_read(hm_ring *ring, float *dst, size_t count);
size_t hm_ring_available(const hm_ring *ring);
uint64_t hm_ring_dropped(const hm_ring *ring);
/// Producer-side: count frames skipped before touching the ring (paired writes). Atomic.
void hm_ring_note_dropped(hm_ring *ring, uint64_t count);

/// Lock-free 64-bit cell for values shared with the audio IO thread.
typedef struct hm_atomic_u64 hm_atomic_u64;
hm_atomic_u64 *hm_atomic_create(uint64_t initial);
void hm_atomic_destroy(hm_atomic_u64 *cell);
uint64_t hm_atomic_load(const hm_atomic_u64 *cell);
void hm_atomic_store(hm_atomic_u64 *cell, uint64_t value);
uint64_t hm_atomic_add(hm_atomic_u64 *cell, uint64_t delta);   // returns the new value

#endif
