/// Streaming version of `TakeSlicer`: holds the open take while more singing could still join it,
/// and releases it once the session has moved past `end + mergeGap + padding`.
public final class LiveTakeAssembler {
    private let slicer: TakeSlicer
    private var open: [SingingSegment] = []

    public init(slicer: TakeSlicer) { self.slicer = slicer }

    public func add(_ segment: SingingSegment) { open.append(segment) }

    /// Takes that can no longer grow, given the session has reached `position`. A phrase the
    /// detector still has open that started within the merge gap keeps the take open too.
    public func advance(to position: Int64, openPhraseStart: Int64? = nil) -> [TakeRange] {
        guard let last = open.max(by: { $0.end < $1.end }) else { return [] }
        let gap = Int64(slicer.mergeGap * slicer.sampleRate)
        if let openStart = openPhraseStart, openStart - last.end <= gap { return [] }
        let settle = Int64((slicer.mergeGap + slicer.padding) * slicer.sampleRate)
        guard position > last.end + settle else { return [] }
        return flush()
    }

    public func flush() -> [TakeRange] {
        defer { open.removeAll() }
        return slicer.takes(from: open)
    }
}
