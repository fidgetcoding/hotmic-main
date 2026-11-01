import Accelerate
import AVFoundation
import os
import SessionKit

/// The phone's audio: streams the mic to the session and, in headphones mode, plays the beat.
/// Main-queue API; the mic tap runs on Core Audio's tap thread, the beat on the render thread.
final class AudioEngine: @unchecked Sendable {
    /// Every ~100 ms of mic audio (tap thread). Goes straight to the session client.
    var onPacket: ((AudioPacket) -> Void)?
    /// Mic peak, 0…1 (main queue).
    var onLevel: ((Float) -> Void)?
    /// Headphones plugged in or pulled out (main queue).
    var onRouteChange: (() -> Void)?
    /// The system took the mic (phone call) or gave it back (main queue).
    var onInterrupted: ((Bool) -> Void)?

    let beat = BeatPlayer()
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var beatVolume: Float = 0.8
    private var wanted = false
    private var observers: [NSObjectProtocol] = []
    /// Tap-thread state: only touched there once the tap is installed.
    private var nextFrame: UInt64 = 0
    private let shared = OSAllocatedUnfairLock(initialState: (headphones: false, inputLatency: 0.0))

    init() {
        beat.onRateChange = { [weak self] rate in self?.rebuildBeatNode(rate: rate) }
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] in
                self?.interruption($0)
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] _ in
                self?.refreshLatency()
                self?.onRouteChange?()
            },
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                self?.restart()                               // new route or rate: tap format changed
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
                guard let self, self.wanted else { return }
                _ = try? self.prepareSession()
                self.restart()
            },
        ]
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    // MARK: - session

    /// Measurement mode turns off iOS voice processing and auto gain: the Mac needs the raw room,
    /// beat bleed and all, to find where the phone sits. Returns the hardware rate for the Hello.
    @discardableResult
    func prepareSession() throws -> Double {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetoothA2DP])
        try? session.setPreferredSampleRate(48_000)
        try? session.setPreferredIOBufferDuration(0.01)
        try session.setActive(true)
        refreshLatency()
        return session.sampleRate
    }

    static var headphonesConnected: Bool {
        let ears: Set<AVAudioSession.Port> = [.headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .usbAudio]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { ears.contains($0.portType) }
    }

    private func refreshLatency() {
        let session = AVAudioSession.sharedInstance()
        let input = session.inputLatency
        beat.setOutputLatency(session.outputLatency)
        shared.withLock { $0.inputLatency = input }
    }

    // MARK: - mic

    /// Starts listening. `firstFrame` continues the stream the host already has from this phone.
    func start(firstFrame: UInt64) throws {
        guard !wanted else { return }
        nextFrame = firstFrame
        wanted = true
        do {
            try startEngine()
        } catch {
            wanted = false
            throw error
        }
    }

    func stop() {
        wanted = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        beat.setEnabled(false)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        DispatchQueue.main.async { self.onLevel?(0) }
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw EngineError.noMicrophone }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate * 0.1), format: format) { [weak self] buffer, when in
            self?.captured(buffer, at: when)
        }
        connectBeatNode(rate: beat.sampleRate)
        engine.prepare()
        try engine.start()
    }

    /// After an interruption or route change: same stream, frame counter carries on.
    private func restart() {
        guard wanted else { return }
        engine.stop()
        refreshLatency()
        do { try startEngine() } catch { onInterrupted?(true) }
    }

    private func interruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            onInterrupted?(true)
        case .ended:
            guard wanted else { return }
            try? AVAudioSession.sharedInstance().setActive(true)
            restart()
            onInterrupted?(!engine.isRunning)
        @unknown default:
            break
        }
    }

    private func captured(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime) {
        guard let channels = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        let rate = buffer.format.sampleRate
        let channelCount = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: count)
        var peak: Float = 0
        mono.withUnsafeMutableBufferPointer { out in
            let p = out.baseAddress!, n = vDSP_Length(count)
            p.update(from: channels[0], count: count)
            if channelCount > 1 {
                for c in 1..<channelCount { vDSP_vadd(p, 1, channels[c], 1, p, 1, n) }
                var scale = 1 / Float(channelCount)
                vDSP_vsmul(p, 1, &scale, p, 1, n)
            }
            vDSP_maxmgv(p, 1, &peak, n)
        }

        let state = shared.withLock { $0 }
        let heardAt = when.isHostTimeValid
            ? HostClock.seconds(fromHostTime: when.hostTime)
            : HostClock.now() - Double(count) / rate
        let captureSeconds = heardAt - state.inputLatency
        let packet = AudioPacket(firstFrame: nextFrame, captureSeconds: captureSeconds,
                                 heardFrame: state.headphones ? beat.heardFrame(at: captureSeconds) : nil,
                                 sampleRate: rate, samples: PCM16.encode(mono))
        nextFrame += UInt64(count)
        onPacket?(packet)

        let db = 20 * log10(max(peak, 1e-6))
        let level = Float(max(0, min(1, (db + 60) / 60)))
        DispatchQueue.main.async { self.onLevel?(level) }
    }

    // MARK: - beat

    /// Only with headphones: a beat on the phone speaker would bleed into the mic.
    func setHeadphones(_ on: Bool) {
        shared.withLock { $0.headphones = on }
        beat.setEnabled(on)
        sourceNode?.volume = on ? beatVolume : 0
    }

    func setBeatVolume(_ volume: Float) {
        beatVolume = volume
        if shared.withLock({ $0.headphones }) { sourceNode?.volume = volume }
    }

    private func connectBeatNode(rate: Double) {
        if let node = sourceNode, node.outputFormat(forBus: 0).sampleRate == rate {
            engine.connect(node, to: engine.mainMixerNode, format: node.outputFormat(forBus: 0))
            return
        }
        if let old = sourceNode { engine.detach(old) }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return }
        let player = beat
        let node = AVAudioSourceNode(format: format) { _, timestamp, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let data = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            player.render(into: data, count: Int(frameCount), timestamp: timestamp.pointee)
            return noErr
        }
        node.volume = shared.withLock { $0.headphones } ? beatVolume : 0
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        sourceNode = node
    }

    private func rebuildBeatNode(rate: Double) {
        guard rate >= 8_000, rate <= 192_000, rate != beat.sampleRate else { return }
        beat.reconfigure(sampleRate: rate)
        connectBeatNode(rate: rate)
        if wanted, !engine.isRunning { try? engine.start() }
    }

    enum EngineError: LocalizedError {
        case noMicrophone
        var errorDescription: String? { "This iPhone's microphone isn't available right now." }
    }
}
