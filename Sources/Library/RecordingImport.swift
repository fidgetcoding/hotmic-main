import AVFoundation
import Capture
import Foundation

/// A recording made outside Hot Mic (a Voice Memo, a phone recording, any file AVFoundation opens:
/// M4A, WAV, AIFF, MP3, CAF, FLAC) becomes a session. It streams through the same take pipeline a
/// live jam uses, so it splits into takes, drops talk and gets lyrics, chords and key the same way.
public enum RecordingImport {
    /// Audio types the window accepts on drop.
    public static let extensions: Set<String> = ["m4a", "wav", "aif", "aiff", "aifc", "mp3", "caf", "flac", "mp4", "mov", "qta"]

    public static func accepts(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    /// Runs the import into `folder` (created here). `configure` applies the app's pipeline
    /// settings; `progress` gets 0…1 as the file is read. Returns the takes it found.
    /// `mix`: what was playing alongside the voice (same rate, same length), for a recording whose voice
    /// was split off (the bench's Beat-mode runs: vocal stem = mic, full song = mix). Without it the
    /// mix is the recording itself.
    @discardableResult
    public static func run(url: URL, folder: URL, mix mixURL: URL? = nil, configure: (TakePipeline) -> Void = { _ in },
                           progress: ((Double) -> Void)? = nil) async throws -> [TakeRecord] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let rate = format.sampleRate, channels = Int(format.channelCount)
        guard file.length > 0, channels > 0 else { throw ImportError.empty }
        let mixFile = try mixURL.map { try AVAudioFile(forReading: $0) }
        if let mixFile, mixFile.processingFormat.sampleRate != rate { throw ImportError.mixRate }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Takes are stamped from when the recording was made, not when it was dropped.
        let made = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        let pipeline = try TakePipeline(folder: folder, sampleRate: rate, sessionStart: made, daw: "Jam", jam: true)
        configure(pipeline)
        let voiceSink: SegmentedAACWriter, mixSink: SegmentedAACWriter
        do {
            voiceSink = try SegmentedAACWriter(folder: folder, baseName: "session__voice", sampleRate: rate, channels: 1, bitRate: 96_000)
            mixSink = try SegmentedAACWriter(folder: folder, baseName: "session__mix", sampleRate: rate, channels: 2, bitRate: 192_000)
        } catch {
            pipeline.abandon()
            throw error
        }

        let chunk: AVAudioFrameCount = 4_096
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { throw ImportError.empty }
        let mixBuffer = mixFile.flatMap { AVAudioPCMBuffer(pcmFormat: $0.processingFormat, frameCapacity: chunk) }
        var mono = [Float](repeating: 0, count: Int(chunk))
        var stereo = [Float](repeating: 0, count: Int(chunk) * 2)
        var position: Int64 = 0
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: chunk)
            let n = Int(buffer.frameLength)
            guard n > 0, let data = buffer.floatChannelData else { break }
            var mixData: UnsafePointer<UnsafeMutablePointer<Float>>?, mixChannels = 0
            if let mixFile, let mixBuffer, mixFile.framePosition < mixFile.length {
                try mixFile.read(into: mixBuffer, frameCount: AVAudioFrameCount(n))
                if Int(mixBuffer.frameLength) == n { mixData = mixBuffer.floatChannelData.map { UnsafePointer($0) }; mixChannels = Int(mixFile.processingFormat.channelCount) }
            }
            for i in 0..<n {
                var sum: Float = 0
                for c in 0..<channels { sum += data[c][i] }
                mono[i] = sum / Float(channels)
                // One mic, nothing playing from the Mac: the "mix" is the recording itself.
                stereo[2 * i] = channels > 1 ? data[0][i] : mono[i]
                stereo[2 * i + 1] = channels > 1 ? data[1][i] : mono[i]
                if let mixData {
                    stereo[2 * i] = mixData[0][i]
                    stereo[2 * i + 1] = mixData[min(1, mixChannels - 1)][i]
                }
            }
            try mono.withUnsafeBufferPointer { v in
                try stereo.withUnsafeBufferPointer { m in
                    try voiceSink.append(interleaved: UnsafeBufferPointer(rebasing: v[0..<n]), frames: n)
                    try mixSink.append(interleaved: UnsafeBufferPointer(rebasing: m[0..<(2 * n)]), frames: n)
                    pipeline.consume(voice: v, mix: m, frames: n, position: position)
                }
            }
            position += Int64(n)
            progress?(Double(file.framePosition) / Double(file.length))
        }
        try pipeline.finish()
        try voiceSink.finish()
        try mixSink.finish()
        await pipeline.waitForLyrics()
        return pipeline.takes
    }

    public enum ImportError: Error, CustomStringConvertible {
        case empty, mixRate
        public var description: String {
            switch self {
            case .empty: return "That file has no audio Hot Mic can read."
            case .mixRate: return "The mix file's sample rate doesn't match the voice file."
            }
        }
    }
}
