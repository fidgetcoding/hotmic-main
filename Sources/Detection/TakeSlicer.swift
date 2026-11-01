/// A take to export: padded, merged singing segments. Frames at session rate.
public struct TakeRange: Equatable, Sendable {
    public var start: Int64
    public var end: Int64
    public var confidence: Float
    /// Seconds of lead-in added before the first sung note.
    public var padding: Double = 0
    public var kind: SingingSegment.Kind = .singing
}

/// Turns singing segments into takes: merges phrases closer than `mergeGap` (one idea sung in
/// breaths), pads both sides so the first syllable is never clipped, clamps at session start.
public struct TakeSlicer: Sendable {
    public var sampleRate: Double
    public var padding: Double = 1.5     // s, spec: 0 clipped first syllables
    public var mergeGap: Double = 2.0    // s
    /// A take closes once it reaches this long. Scratch audio only goes back 12 minutes, and a take that grew past
    /// that lost everything before its last 12 minutes (livestream test corpus: up to 25 minutes, with all the writing in it).
    public var maxTakeSeconds: Double = 300

    public init(sampleRate: Double) { self.sampleRate = sampleRate }

    public func takes(from segments: [SingingSegment]) -> [TakeRange] {
        let pad = Int64(padding * sampleRate), gap = Int64(mergeGap * sampleRate)
        var merged: [TakeRange] = []
        var longest: [Int64] = []
        for s in segments.sorted(by: { $0.start < $1.start }) {
            if var last = merged.last, s.start - last.end <= gap {
                last.end = max(last.end, s.end)
                last.confidence = max(last.confidence, s.confidence)
                if s.end - s.start > longest[longest.count - 1] { last.kind = s.kind; longest[longest.count - 1] = s.end - s.start }
                merged[merged.count - 1] = last
            } else {
                merged.append(TakeRange(start: s.start, end: s.end, confidence: s.confidence, kind: s.kind))
                longest.append(s.end - s.start)
            }
        }
        return merged.map {
            let start = max(0, $0.start - pad)
            return TakeRange(start: start, end: $0.end + pad, confidence: $0.confidence,
                             padding: Double($0.start - start) / sampleRate, kind: $0.kind)
        }
    }
}
