import Foundation

/// The lyric brain, on-device: which lines you've sung before (and where), and which phrases you
/// keep reusing across your whole catalog. Word-level 3-gram overlap, so it survives small
/// wording changes and Whisper's punctuation.
public struct LyricIndex {
    public struct Document: Equatable, Sendable {
        public var id: String
        public var title: String
        public var text: String
        public init(id: String, title: String, text: String) { self.id = id; self.title = title; self.text = text }
    }

    public struct Echo: Equatable, Sendable {
        public var line: String          // the new line
        public var documentID: String    // where it was sung/written before
        public var title: String
        public var matchedLine: String
        public var overlap: Double       // 0…1 share of the new line's 3-grams found there
    }

    public struct Phrase: Equatable, Sendable {
        public var text: String
        public var songs: Int            // distinct documents using it
    }

    private let documents: [Document]
    private var linesByGram: [String: [(doc: Int, line: Int)]] = [:]
    private let lines: [[String]]         // per document: original lines

    public init(_ documents: [Document]) {
        self.documents = documents
        lines = documents.map { Self.lines($0.text) }
        for (d, docLines) in lines.enumerated() {
            for (l, line) in docLines.enumerated() {
                for gram in Set(Self.grams(line)) { linesByGram[gram, default: []].append((d, l)) }
            }
        }
    }

    /// Lines of `text` that already exist elsewhere in the catalog (excluding `excluding`).
    public func echoes(of text: String, excluding: String? = nil, threshold: Double = 0.6) -> [Echo] {
        echoes(of: text, excluding: excluding.map { [$0] } ?? [], threshold: threshold)
    }

    /// Same, skipping every document in `excluding` (e.g. the other takes of this session: those
    /// are versions of the song you're writing, not repetition).
    public func echoes(of text: String, excluding: Set<String>, threshold: Double = 0.6) -> [Echo] {
        var found: [Echo] = []
        for line in Self.lines(text) {
            let grams = Set(Self.grams(line))
            guard grams.count >= 2 else { continue }
            var hits: [String: Int] = [:]   // "doc:line" → shared grams
            for gram in grams {
                for (d, l) in linesByGram[gram] ?? [] where !excluding.contains(documents[d].id) { hits["\(d):\(l)", default: 0] += 1 }
            }
            guard let best = hits.max(by: { $0.value < $1.value }) else { continue }
            let overlap = Double(best.value) / Double(grams.count)
            guard overlap >= threshold else { continue }
            let parts = best.key.split(separator: ":").compactMap { Int($0) }
            found.append(Echo(line: line, documentID: documents[parts[0]].id, title: documents[parts[0]].title,
                              matchedLine: lines[parts[0]][parts[1]], overlap: overlap))
        }
        return found
    }

    /// Phrases (3–4 words) appearing in at least `minSongs` different songs/takes, most-reused first.
    public func repeatedPhrases(minSongs: Int = 3, limit: Int = 20) -> [Phrase] {
        var docsByPhrase: [String: Set<Int>] = [:]
        for (d, docLines) in lines.enumerated() {
            for line in docLines {
                let words = Self.words(line)
                for n in 3...4 where words.count >= n {
                    for i in 0...(words.count - n) {
                        let phrase = words[i..<(i + n)].joined(separator: " ")
                        if !Self.isFiller(words[i..<(i + n)]) { docsByPhrase[phrase, default: []].insert(d) }
                    }
                }
            }
        }
        return docsByPhrase.filter { $0.value.count >= minSongs }
            .map { Phrase(text: $0.key, songs: $0.value.count) }
            .sorted { $0.songs != $1.songs ? $0.songs > $1.songs : $0.text.count > $1.text.count }
            .prefix(limit).map { $0 }
    }

    static func lines(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: "\n.!?;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { words($0).count >= 3 }
    }

    static func words(_ line: String) -> [String] {
        line.lowercased().components(separatedBy: CharacterSet.alphanumerics.union(["'"]).inverted).filter { !$0.isEmpty }
    }

    static func grams(_ line: String) -> [String] {
        let w = words(line)
        guard w.count >= 3 else { return [] }
        return (0...(w.count - 3)).map { w[$0..<($0 + 3)].joined(separator: " ") }
    }

    static let stop: Set<String> = ["i", "you", "the", "a", "and", "to", "it", "in", "of", "me", "my", "we", "is", "on", "that", "oh", "yeah", "la", "na"]
    static func isFiller(_ words: ArraySlice<String>) -> Bool { words.allSatisfy { stop.contains($0) } }
}
