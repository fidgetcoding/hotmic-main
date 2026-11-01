import AVFoundation

/// Continuous AAC (.m4a) file. Not real-time safe — call from the drain queue, never the IO thread.
/// AAC can't encode above 48 kHz, so 88.2/96/192 kHz input is resampled to 48 kHz on the way in.
public final class AACFileWriter: AudioFileSink {
    public static let maxAACRate: Double = 48_000
    public let channels: Int
    public let fileSampleRate: Double
    private var file: AVAudioFile?
    private let inputFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private var inputBuffer: AVAudioPCMBuffer
    private var outputBuffer: AVAudioPCMBuffer?

    public init(url: URL, sampleRate: Double, channels: Int, bitRate: Int) throws {
        self.channels = channels
        fileSampleRate = min(sampleRate, Self.maxAACRate)
        // The AAC encoder's allowed bit rates depend on the sample rate: AirPods/Bluetooth mics run
        // at 16–24 kHz, where 96 kbps mono is rejected. Step down until the encoder accepts one;
        // last resort, let it pick.
        var file: AVAudioFile?
        var lastError: Error?
        for rate in Self.bitRateCandidates(requested: bitRate, channels: channels) {
            var settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: fileSampleRate,
                AVNumberOfChannelsKey: channels,
            ]
            if let rate { settings[AVEncoderBitRateKey] = rate }
            do {
                file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                break
            } catch {
                lastError = error
                try? FileManager.default.removeItem(at: url)
            }
        }
        guard let file else { throw lastError ?? CocoaError(.fileWriteUnknown) }
        self.file = file
        inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                    channels: AVAudioChannelCount(channels), interleaved: false)!
        converter = sampleRate == fileSampleRate ? nil : AVAudioConverter(from: inputFormat, to: file.processingFormat)
        inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 8_192)!
    }

    static func bitRateCandidates(requested: Int, channels: Int) -> [Int?] {
        let steps = [requested, requested * 3 / 4, requested / 2, 64_000 * channels, 48_000 * channels, 32_000 * channels]
        var seen = Set<Int>()
        return steps.filter { $0 <= requested && seen.insert($0).inserted }.map { Optional($0) } + [nil]
    }

    public func append(interleaved: UnsafeBufferPointer<Float>, frames: Int) throws {
        guard let file, frames > 0 else { return }
        if Int(inputBuffer.frameCapacity) < frames {
            inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frames))!
        }
        guard let planes = inputBuffer.floatChannelData else { return }
        for ch in 0..<channels {
            let plane = planes[ch]
            for i in 0..<frames { plane[i] = interleaved[i * channels + ch] }
        }
        inputBuffer.frameLength = AVAudioFrameCount(frames)

        guard let converter else { return try file.write(from: inputBuffer) }
        let capacity = AVAudioFrameCount(Double(frames) * fileSampleRate / inputFormat.sampleRate) + 64
        if outputBuffer == nil || outputBuffer!.frameCapacity < capacity {
            outputBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity)
        }
        guard let output = outputBuffer else { return }
        var supplied = false
        var error: NSError?
        let input = inputBuffer
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        if output.frameLength > 0 { try file.write(from: output) }
    }

    public func finish() throws {
        // Drain the resampler so the last few milliseconds aren't lost.
        if let converter, let file, let output = outputBuffer ?? AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096) {
            var error: NSError?
            repeat {
                output.frameLength = 0
                converter.convert(to: output, error: &error) { _, status in status.pointee = .endOfStream; return nil }
                if output.frameLength > 0 { try file.write(from: output) }
            } while output.frameLength > 0 && error == nil
        }
        if #available(macOS 15, *) { file?.close() }
        file = nil  // releasing the file also finalizes it on macOS 14
    }
}
