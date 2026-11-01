import Foundation

/// Whole-session recording that survives crashes: rolls to a new, fully closed .m4a every
/// `segmentSeconds` (default 5 min), so a crash, force-quit or power cut loses at most the
/// segment in progress instead of the whole session. Files: `<base>_001.m4a`, `<base>_002.m4a`, …
public final class SegmentedAACWriter: AudioFileSink {
    public let channels: Int
    public private(set) var segments: [URL] = []
    private let folder: URL
    private let baseName: String
    private let sampleRate: Double
    private let bitRate: Int
    private let segmentFrames: Int
    private var current: AACFileWriter?
    private var framesInSegment = 0
    private let firstIndex: Int

    public init(folder: URL, baseName: String, sampleRate: Double, channels: Int, bitRate: Int,
                segmentSeconds: Double = 300, firstIndex: Int = 1) throws {
        self.firstIndex = firstIndex
        self.folder = folder
        self.baseName = baseName
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitRate = bitRate
        segmentFrames = max(1, Int(segmentSeconds * sampleRate))
        try roll()
    }

    public func append(interleaved: UnsafeBufferPointer<Float>, frames: Int) throws {
        var done = 0
        while done < frames {
            if framesInSegment >= segmentFrames { try roll() }
            let n = min(frames - done, segmentFrames - framesInSegment)
            try current?.append(interleaved: UnsafeBufferPointer(rebasing: interleaved[(done * channels)..<((done + n) * channels)]), frames: n)
            framesInSegment += n
            done += n
        }
    }

    public func finish() throws {
        try current?.finish()
        current = nil
    }

    private func roll() throws {
        try current?.finish()
        let url = folder.appendingPathComponent(String(format: "%@_%03d.m4a", baseName, segments.count + firstIndex))
        current = try AACFileWriter(url: url, sampleRate: sampleRate, channels: channels, bitRate: bitRate)
        segments.append(url)
        framesInSegment = 0
    }
}
