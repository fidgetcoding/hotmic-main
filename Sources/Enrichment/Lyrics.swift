/// Words sung in a take, with timing (seconds from the take start).
public struct Lyrics: Codable, Equatable, Sendable {
    public struct Word: Codable, Equatable, Sendable {
        public var text: String
        public var start: Double
        public var end: Double
        public init(text: String, start: Double, end: Double) { self.text = text; self.start = start; self.end = end }
    }

    public var text: String
    public var words: [Word]

    public init(text: String, words: [Word]) { self.text = text; self.words = words }
}

/// Speech/singing → text. WhisperKit in the app; a stub in tests.
public protocol LyricTranscribing: Sendable {
    func transcribe(_ samples: [Float], sampleRate: Double) async throws -> Lyrics
    /// `hint`: lines you've already sung this session — helps with mumbled and half-whispered words.
    func transcribe(_ samples: [Float], sampleRate: Double, hint: String?) async throws -> Lyrics
}

extension LyricTranscribing {
    public func transcribe(_ samples: [Float], sampleRate: Double, hint: String?) async throws -> Lyrics {
        try await transcribe(samples, sampleRate: sampleRate)
    }
}

extension Lyrics {
    /// Whisper's loop failure on music: one word over and over ("man, man, man, man, man" for a minute of
    /// beat and chatter, livestream test corpus). Five or more words, one of them ≥ 75% of the line.
    public static func isLoop(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
        guard words.count >= 5 else { return false }
        let top = Dictionary(grouping: words, by: { $0 }).values.map(\.count).max() ?? 0
        return Double(top) / Double(words.count) >= 0.75
    }

    /// Where to cut long audio so each piece is transcribed on its own (≤ `maxSeconds`): at the quietest
    /// 0.2 s in the last `searchSeconds` of every piece. One pass over a 10-minute take loses whole minutes
    /// and collapses word timings (bench 2026-10-28: 2 of 21 released lines vs 7 from 10 s pieces).
    public static func pieces(_ x: [Float], sampleRate rate: Double, maxSeconds: Double = 25,
                              searchSeconds: Double = 8) -> [Range<Int>] {
        let maxN = Int(maxSeconds * rate), hop = max(1, Int(0.2 * rate))
        guard x.count > maxN else { return [0..<x.count] }
        var out: [Range<Int>] = [], start = 0
        while x.count - start > maxN {
            let from = start + maxN - Int(searchSeconds * rate), until = start + maxN - hop
            var best = until, quietest = Float.greatestFiniteMagnitude
            for a in stride(from: from, through: until, by: hop) {
                var e: Float = 0
                for i in a..<(a + hop) { e += x[i] * x[i] }
                if e < quietest { quietest = e; best = a + hop / 2 }
            }
            out.append(start..<best)
            start = best
        }
        out.append(start..<x.count)
        return out
    }
}
