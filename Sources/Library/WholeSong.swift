import AVFoundation
import Foundation

/// The finished song as one file you can listen through (Nate 2026-10-28): the version shown for every
/// line (your star, else the newest), in notebook order, cut from the session recording and joined.
/// Lines sung back to back in one pass stay one clip, so a section plays the way it was sung
/// (Nate 2026-10-12: a whole section beats patchwork lines).
public enum WholeSong {
    /// A stretch of the session recording that goes into the song, and the lines it carries.
    public struct Clip: Codable, Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var lines: [String]
        public init(start: Double, end: Double, lines: [String]) { self.start = start; self.end = end; self.lines = lines }
    }

    /// The version a line shows: your star, else the newest.
    public static func shown(_ slot: [LabSession.Version]) -> LabSession.Version? {
        slot.last(where: { $0.keeper }) ?? slot.last
    }

    /// Lines that are sung words with audio behind them: not hums, beatbox, chord rows, typed lines or chatter.
    static func isSungLine(_ v: LabSession.Version) -> Bool {
        let text = v.text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, v.takeID != "typed" else { return false }
        return !["hum-", "beat-", "chords-"].contains { v.id.hasPrefix($0) } && !isChatter(text)
    }

    /// Talking to the room between takes ("let me get some ad-libs real quick", "next one", "my bad"):
    /// never part of the song. Phrases from the livestream test corpus; a stopgap until talk is
    /// judged from the voice itself.
    static let chatter = ["let me ", "let's run", "next one", "hold up", "my bad", "one more time", "real quick", "one take",
                          "run it back", "from the top", "that's cool", "is that", "wasn't that", "do you have", "this computer",
                          "i mean", "turn it up", "turn me up", "play it back", "pull it up", "how was that"]
    static func isChatter(_ text: String) -> Bool {
        let t = " " + text.lowercased().replacingOccurrences(of: "’", with: "'") + " "
        return chatter.contains { t.contains(" " + $0) }
    }

    /// How long a version lasts. Whisper's word timings sometimes collapse to nothing on long takes: then
    /// ~0.35 s a word.
    static func duration(_ v: LabSession.Version) -> Double {
        let d = v.end - v.start
        return d > 0.2 ? d : max(1, 0.35 * Double(v.text.split(separator: " ").count))
    }

    /// Which stretches of the session make the song (Nate 2026-10-12: a whole section beats patchwork lines).
    /// Lines go in the order they were first sung. A pass is lines sung back to back (≤ `joinGap` s apart).
    /// From each line, the song takes the pass that sang the most of the following lines in order, newest
    /// first on a tie, and plays that stretch straight through; a starred version always wins its line.
    public static func plan(_ slots: [[LabSession.Version]], joinGap: Double = 2.5,
                            lead: Double = 0.25, tail: Double = 0.6) -> [Clip] {
        struct Sung { let slot: Int; let v: LabSession.Version; var start: Double { v.at }; var end: Double { v.at + WholeSong.duration(v) } }
        let lines = slots.map { $0.filter(isSungLine) }
        let order = lines.indices.filter { !lines[$0].isEmpty }
            .sorted { lines[$0].map(\.at).min()! < lines[$1].map(\.at).min()! }
        guard !order.isEmpty else { return [] }
        // Passes: every sung version in time order, chained while the gaps stay short.
        var passes: [[Sung]] = []
        for s in lines.indices.flatMap({ i in lines[i].map { Sung(slot: i, v: $0) } }).sorted(by: { $0.start < $1.start }) {
            if let last = passes.last?.last, s.start - last.end <= joinGap { passes[passes.count - 1].append(s) } else { passes.append([s]) }
        }
        let keeper = Dictionary(uniqueKeysWithValues: lines.indices.compactMap { i in lines[i].last(where: \.keeper).map { (i, $0.id) } })
        // From line `k` of the song order: how far pass `p` runs in order, and its versions.
        func run(_ p: [Sung], from k: Int) -> [Sung] {
            var out: [Sung] = [], after = -Double.infinity
            for slot in order[k...] {
                guard let s = p.first(where: { $0.slot == slot && $0.start >= after }),
                      keeper[slot].map({ $0 == s.v.id }) ?? true else { break }
                out.append(s); after = s.start
            }
            return out
        }
        var clips: [Clip] = [], k = 0
        while k < order.count {
            let best = passes.map { run($0, from: k) }.filter { !$0.isEmpty }
                .max { ($0.count, $0.last!.end) < ($1.count, $1.last!.end) }
            guard let best else { k += 1; continue }
            clips.append(Clip(start: max(0, best.first!.start - lead), end: best.map(\.end).max()! + tail, lines: best.map(\.v.text)))
            k += best.count
        }
        return clips
    }

    public enum RenderError: Error, CustomStringConvertible {
        case noAudio, noClips
        public var description: String {
            switch self {
            case .noAudio: return "The session has no recording to cut the song from."
            case .noClips: return "No sung lines to put in the song."
            }
        }
    }

    /// Cuts every clip out of the session's segment files (`session__mix_001.m4a`, … each
    /// `segmentSeconds` long) and writes them back to back as AAC, with a short fade at every seam.
    public static func render(_ clips: [Clip], segments: [URL], segmentSeconds: Double, to out: URL,
                              fade: Double = 0.02) throws {
        guard !clips.isEmpty else { throw RenderError.noClips }
        guard let first = segments.first, let probe = try? AVAudioFile(forReading: first) else { throw RenderError.noAudio }
        let rate = probe.processingFormat.sampleRate
        let channels = Int(probe.processingFormat.channelCount)
        var song = [[Float]](repeating: [], count: channels)
        let fadeFrames = max(1, Int(fade * rate))
        for clip in clips {
            var part = read(clip.start, clip.end, segments: segments, segmentSeconds: segmentSeconds, channels: channels, rate: rate)
            let n = part.first?.count ?? 0
            guard n > 0 else { continue }
            let f = min(fadeFrames, n / 2)
            for c in 0..<channels {
                for i in 0..<f {
                    let g = Float(i) / Float(f)
                    part[c][i] *= g
                    part[c][n - 1 - i] *= g
                }
                song[c] += part[c]
            }
        }
        let frames = song.first?.count ?? 0
        guard frames > 0 else { throw RenderError.noAudio }
        try? FileManager.default.removeItem(at: out)
        // Quality, not a fixed bit rate: the encoder refuses some rate/bit-rate pairs (96 kbps mono at 16 kHz).
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                                       AVNumberOfChannelsKey: channels, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
        let file = try AVAudioFile(forWriting: out, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 65_536
        var k = 0
        while k < frames {
            let m = min(chunk, frames - k)
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(m)),
                  let data = buf.floatChannelData else { throw RenderError.noAudio }
            for c in 0..<channels { song[c].withUnsafeBufferPointer { src in data[c].update(from: src.baseAddress! + k, count: m) } }
            buf.frameLength = AVAudioFrameCount(m)
            try file.write(from: buf)
            k += m
        }
    }

    /// Session seconds `a…b` as one array per channel, across segment boundaries.
    static func read(_ a: Double, _ b: Double, segments: [URL], segmentSeconds: Double, channels: Int, rate: Double) -> [[Float]] {
        var out = [[Float]](repeating: [], count: channels)
        var t = max(0, a)
        while t < b {
            let index = Int(t / segmentSeconds)
            guard index < segments.count, let file = try? AVAudioFile(forReading: segments[index]) else { break }
            let segStart = Double(index) * segmentSeconds
            let from = AVAudioFramePosition((t - segStart) * rate)
            let until = min(AVAudioFramePosition((min(b, segStart + segmentSeconds) - segStart) * rate), file.length)
            guard until > from, from < file.length else { t = segStart + segmentSeconds; continue }
            let count = AVAudioFrameCount(until - from)
            file.framePosition = from
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count),
                  (try? file.read(into: buf, frameCount: count)) != nil, let data = buf.floatChannelData else { break }
            let n = Int(buf.frameLength)
            let have = Int(file.processingFormat.channelCount)
            for c in 0..<channels { out[c] += UnsafeBufferPointer(start: data[min(c, have - 1)], count: n) }
            t = segStart + segmentSeconds
        }
        return out
    }
}
