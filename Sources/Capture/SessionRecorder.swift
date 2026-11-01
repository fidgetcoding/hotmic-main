import Foundation

/// Continuous whole-session recording: capture source → rings → (drain queue) → mixer → files.
public final class SessionRecorder {
    public private(set) var isRecording = false
    public var droppedFrames: UInt64 { (micRing?.dropped ?? 0) + (sessionRing?.dropped ?? 0) / 2 }

    private let source: CaptureSource
    private let makeMixer: (_ sampleRate: Double) throws -> SessionMixer
    private let drainInterval: DispatchTimeInterval
    private let queue = DispatchQueue(label: "io.bluegum.hotmic.drain", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var micRing: RingBuffer?
    private var sessionRing: RingBuffer?
    private var mixer: SessionMixer?
    private var micChunk: [Float] = []
    private var sessionChunk: [Float] = []

    public init(source: CaptureSource, drainInterval: DispatchTimeInterval = .milliseconds(50),
                makeMixer: @escaping (_ sampleRate: Double) throws -> SessionMixer) {
        self.source = source
        self.drainInterval = drainInterval
        self.makeMixer = makeMixer
    }

    public func start() throws {
        guard !isRecording else { return }
        let seconds = 10
        let mic = RingBuffer(capacity: 48_000 * seconds * 4)  // generous for up to 192 kHz
        let session = RingBuffer(capacity: 48_000 * seconds * 8)
        try source.start(mic: mic, session: session)
        do {
            mixer = try makeMixer(source.sampleRate)
        } catch {
            source.stop()   // never leave the mic running with nobody reading it
            throw error
        }
        micRing = mic
        sessionRing = session
        isRecording = true

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + drainInterval, repeating: drainInterval)
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        self.timer = timer
    }

    public func stop() throws {
        guard isRecording else { return }
        source.stop()
        timer?.cancel()
        timer = nil
        defer { isRecording = false; mixer = nil }
        try queue.sync {
            drain()
            try mixer?.finish()
        }
    }

    /// Moves every complete aligned frame from the rings to the mixer. Runs on `queue` (tests call it directly).
    func drain() {
        guard let micRing, let sessionRing, let mixer else { return }
        let frames = min(micRing.available, sessionRing.available / 2)
        guard frames > 0 else { return }
        if micChunk.count < frames { micChunk = [Float](repeating: 0, count: frames) }
        if sessionChunk.count < frames * 2 { sessionChunk = [Float](repeating: 0, count: frames * 2) }
        _ = micRing.read(into: &micChunk, count: frames)
        _ = sessionRing.read(into: &sessionChunk, count: frames * 2)
        do {
            try mixer.consume(mic: &micChunk, session: sessionChunk, frames: frames)
        } catch {
            NSLog("Hot Mic: write failed: \(error)")
        }
    }
}
