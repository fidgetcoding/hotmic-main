/// Destination for continuous audio (AAC file in the app, a recorder in tests).
public protocol AudioFileSink: AnyObject {
    var channels: Int { get }
    func append(interleaved: UnsafeBufferPointer<Float>, frames: Int) throws
    func finish() throws
}

/// Turns raw mic + session reference into the voice signal (echo cancellation lives behind this).
public protocol VoiceProcessing {
    /// Frames the processed voice lags the input by; the mixer delays the session to match.
    var latencyFrames: Int { get }
    /// True when the session already contains the voice (DAW input monitoring): the mix must not add it again.
    var referenceContainsVoice: Bool { get }
    func process(mic: UnsafeMutableBufferPointer<Float>, reference: UnsafeBufferPointer<Float>, frames: Int)
}

public struct PassthroughVoice: VoiceProcessing {
    public init() {}
    public func process(mic: UnsafeMutableBufferPointer<Float>, reference: UnsafeBufferPointer<Float>, frames: Int) {}
}

/// Builds the two continuous streams from each aligned chunk:
/// `voice` = processed mic (mono), `mix` = session stereo + voice in both channels.
public final class SessionMixer {
    private let voiceSink: AudioFileSink
    private let mixSink: AudioFileSink
    private let processor: VoiceProcessing
    private var mixScratch: [Float] = []
    private var delayedSession: [Float]  // interleaved stereo, primed with `latencyFrames` of silence
    public private(set) var position: Int64 = 0  // session frames written so far

    /// Called on the drain queue after each chunk is written: processed voice (mono), mix
    /// (interleaved stereo), frame count, and the session position of the chunk's first frame.
    public var onMixed: ((UnsafeBufferPointer<Float>, UnsafeBufferPointer<Float>, Int, Int64) -> Void)?
    /// Called on the drain queue with each raw session chunk (interleaved stereo, before any delay)
    /// and its position: the beat the room hears, for phones joined to the session.
    public var onSession: ((UnsafeBufferPointer<Float>, Int, Int64) -> Void)?
    /// Called on the drain queue after the last chunk, before the files close.
    public var onFinish: (() throws -> Void)?

    /// `hardwareDelayFrames`: speaker + mic latency, so the singer lines up with what they heard.
    public init(voiceSink: AudioFileSink, mixSink: AudioFileSink, processor: VoiceProcessing = PassthroughVoice(),
                hardwareDelayFrames: Int = 0) {
        precondition(voiceSink.channels == 1 && mixSink.channels == 2, "voice is mono, mix is stereo")
        self.voiceSink = voiceSink
        self.mixSink = mixSink
        self.processor = processor
        delayedSession = [Float](repeating: 0, count: (processor.latencyFrames + max(0, hardwareDelayFrames)) * 2)
    }

    /// `mic` is mono and processed in place; `session` is interleaved stereo.
    public func consume(mic: inout [Float], session: [Float], frames: Int) throws {
        precondition(mic.count >= frames && session.count >= frames * 2)
        if let onSession { session.withUnsafeBufferPointer { onSession($0, frames, position) } }
        session.withUnsafeBufferPointer { ref in
            mic.withUnsafeMutableBufferPointer { processor.process(mic: $0, reference: ref, frames: frames) }
        }
        if mixScratch.count < frames * 2 { mixScratch = [Float](repeating: 0, count: frames * 2) }
        delayedSession.append(contentsOf: session.prefix(frames * 2))
        for i in 0..<frames {
            let voice = processor.referenceContainsVoice ? 0 : mic[i]
            mixScratch[2 * i] = delayedSession[2 * i] + voice
            mixScratch[2 * i + 1] = delayedSession[2 * i + 1] + voice
        }
        delayedSession.removeFirst(frames * 2)
        // A failed file write (e.g. a segment roll) must not desync voice, mix, takes and timeline:
        // everything still advances, and the first error is reported afterwards.
        var failure: Error?
        do { try mic.withUnsafeBufferPointer { try voiceSink.append(interleaved: $0, frames: frames) } } catch { failure = error }
        do { try mixScratch.withUnsafeBufferPointer { try mixSink.append(interleaved: $0, frames: frames) } } catch { failure = failure ?? error }
        if let onMixed {
            mic.withUnsafeBufferPointer { v in mixScratch.withUnsafeBufferPointer { onMixed(v, $0, frames, position) } }
        }
        position += Int64(frames)
        if let failure { throw failure }
    }

    /// Closes both files even if the final take export fails (an unclosed .m4a is unplayable).
    public func finish() throws {
        var firstError: Error?
        do { try onFinish?() } catch { firstError = error }
        do { try voiceSink.finish() } catch { firstError = firstError ?? error }
        do { try mixSink.finish() } catch { firstError = firstError ?? error }
        if let firstError { throw firstError }
    }
}
