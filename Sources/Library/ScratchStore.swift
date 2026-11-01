import Foundation

/// Rolling on-disk copy of the last few minutes of processed audio, readable by range while
/// recording continues (the continuous .m4a files can't be read until they're closed).
/// Frames are stored as interleaved Int16 [voice, mixL, mixR]; one file per `segmentFrames`.
public final class ScratchStore {
    public let directory: URL
    public private(set) var written: Int64 = 0
    public var oldestRetained: Int64 { max(0, Int64(currentIndex - keepSegments + 1) * Int64(segmentFrames)) }

    private let segmentFrames: Int
    private let keepSegments: Int
    private var handle: FileHandle?
    private var currentIndex = -1
    private var packed: [Int16] = []

    public init(directory: URL, sampleRate: Double, segmentSeconds: Double = 60, keepSegments: Int = 12) throws {
        self.directory = directory
        segmentFrames = Int(sampleRate * segmentSeconds)
        self.keepSegments = keepSegments
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { try? handle?.close() }

    public func append(voice: UnsafeBufferPointer<Float>, mix: UnsafeBufferPointer<Float>, frames: Int) throws {
        var done = 0
        while done < frames {
            let index = Int(written / Int64(segmentFrames))
            if index != currentIndex { try roll(to: index) }
            let room = segmentFrames - Int(written % Int64(segmentFrames))
            let n = min(room, frames - done)
            packed.removeAll(keepingCapacity: true)
            for i in done..<(done + n) {
                packed.append(Self.int16(voice[i]))
                packed.append(Self.int16(mix[2 * i]))
                packed.append(Self.int16(mix[2 * i + 1]))
            }
            try packed.withUnsafeBytes { try handle?.write(contentsOf: $0) }
            written += Int64(n)
            done += n
        }
    }

    /// Voice (mono) and mix (interleaved stereo) for [start, end), clamped to what's retained.
    public func read(from start: Int64, to end: Int64) throws -> (voice: [Float], mix: [Float]) {
        let lo = max(start, oldestRetained), hi = min(end, written)
        guard hi > lo else { return ([], []) }
        var voice = [Float](), mix = [Float]()
        voice.reserveCapacity(Int(hi - lo)); mix.reserveCapacity(Int(hi - lo) * 2)
        var frame = lo
        while frame < hi {
            let index = Int(frame / Int64(segmentFrames))
            let offset = Int(frame % Int64(segmentFrames))
            let n = Int(min(hi - frame, Int64(segmentFrames - offset)))
            let reader = try FileHandle(forReadingFrom: url(index))
            defer { try? reader.close() }
            try reader.seek(toOffset: UInt64(offset * 6))
            let data = try reader.read(upToCount: n * 6) ?? Data()
            data.withUnsafeBytes { raw in
                let s = raw.bindMemory(to: Int16.self)
                for i in 0..<(s.count / 3) {
                    voice.append(Float(s[3 * i]) / 32_767)
                    mix.append(Float(s[3 * i + 1]) / 32_767)
                    mix.append(Float(s[3 * i + 2]) / 32_767)
                }
            }
            frame += Int64(n)
        }
        return (voice, mix)
    }

    /// Removes all scratch files (session end, after the last export).
    public func discard() throws {
        try handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func roll(to index: Int) throws {
        try handle?.close()
        FileManager.default.createFile(atPath: url(index).path, contents: nil)
        handle = try FileHandle(forWritingTo: url(index))
        currentIndex = index
        let expired = index - keepSegments
        if expired >= 0 { try? FileManager.default.removeItem(at: url(expired)) }
    }

    private func url(_ index: Int) -> URL { directory.appendingPathComponent("seg-\(index).raw") }

    private static func int16(_ x: Float) -> Int16 { Int16(max(-1, min(1, x)) * 32_767) }
}
