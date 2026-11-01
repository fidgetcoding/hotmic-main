import CRingBuffer

/// Swift face of the lock-free SPSC float ring. `write` is real-time safe (no allocation, no locks).
public final class RingBuffer: @unchecked Sendable {
    private let ring: OpaquePointer
    public let capacity: Int

    public init(capacity: Int) {
        guard let ring = hm_ring_create(capacity) else { fatalError("ring allocation failed") }
        self.ring = ring
        self.capacity = capacity
    }

    deinit { hm_ring_destroy(ring) }

    @discardableResult
    public func write(_ source: UnsafePointer<Float>, count: Int) -> Bool {
        hm_ring_write(ring, source, count) == 1
    }

    public func read(into destination: UnsafeMutablePointer<Float>, count: Int) -> Int {
        hm_ring_read(ring, destination, count)
    }

    public var available: Int { hm_ring_available(ring) }
    public var freeSpace: Int { capacity - available }
    public var dropped: UInt64 { hm_ring_dropped(ring) }
    /// Producer-side bookkeeping when a paired write is skipped before touching the ring. Atomic.
    public func noteDropped(_ count: Int) { hm_ring_note_dropped(ring, UInt64(count)) }
}

/// A 64-bit value shared with the audio IO thread without locks.
public final class AtomicU64: @unchecked Sendable {
    private let cell: OpaquePointer
    public init(_ initial: UInt64 = 0) {
        guard let cell = hm_atomic_create(initial) else { fatalError("atomic allocation failed") }
        self.cell = cell
    }
    deinit { hm_atomic_destroy(cell) }
    public var value: UInt64 {
        get { hm_atomic_load(cell) }
        set { hm_atomic_store(cell, newValue) }
    }
    @discardableResult public func add(_ delta: UInt64) -> UInt64 { hm_atomic_add(cell, delta) }
}
