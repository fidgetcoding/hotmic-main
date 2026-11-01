import AppKit
import CoreAudio
import Darwin

public enum CaptureError: Error, CustomStringConvertible {
    case coreAudio(String, OSStatus)
    public var description: String {
        switch self { case let .coreAudio(what, status): return "\(what) failed (OSStatus \(status))" }
    }
}

public protocol CaptureSource: AnyObject {
    var sampleRate: Double { get }
    /// Starts pushing mono mic and interleaved-stereo session audio, frame-aligned, into the rings.
    func start(mic: RingBuffer, session: RingBuffer) throws
    func stop()
    /// mach host time of session frame 0 (0 until the first IO callback). Safe to read from any thread.
    var hostTimeAtFirstFrame: UInt64 { get }
    /// Speaker output + mic input hardware latency: how much later the mic hears what the tap captured.
    var roundTripLatencyFrames: Int { get }
    /// Mic input latency alone: how long after someone sings the mic frame is stamped.
    var inputLatencyFrames: Int { get }
}

public extension CaptureSource {
    var hostTimeAtFirstFrame: UInt64 { 0 }
    var roundTripLatencyFrames: Int { 0 }
    var inputLatencyFrames: Int { 0 }
}

/// Default mic + a process tap (one DAW, or all system audio) in ONE private aggregate device:
/// the mic is clock master and the tap is drift-compensated onto it, so streams stay sample-aligned.
///
/// If the DAW hasn't opened audio yet (common right after launch), capture starts on all system
/// audio except Hot Mic itself, then switches to the DAW-only tap the moment the DAW appears.
public final class CoreAudioCaptureSource: CaptureSource {
    /// `systemAudioWithOwn`: everything the Mac plays, Hot Mic's own window included (Beat mode: the beat
    /// plays in the window, so it belongs in the mix and in the echo reference).
    public enum Target { case process(pid_t), systemAudio, systemAudioWithOwn }

    public private(set) var sampleRate: Double = 48_000
    public var roundTripLatencyFrames: Int { Int(roundTripAtomic.value) }
    public var inputLatencyFrames: Int { Int(inputLatencyAtomic.value) }
    /// Problems worth showing the user (e.g. couldn't switch to the DAW-only tap); "" clears. Any thread.
    public var onProblem: ((String) -> Void)?
    /// Capture is dead and couldn't be restored; the session should end. Any thread.
    public var onFailure: ((String) -> Void)?
    public var hostTimeAtFirstFrame: UInt64 { anchor.value }
    /// True while recording everything because the DAW had no audio process yet.
    public var isUsingSystemFallback: Bool { onControl { fallbackActive } }

    private let target: Target
    private let control = DispatchQueue(label: "io.bluegum.hotmic.capture.control")
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var processListener: AudioObjectPropertyListenerBlock?
    private var fallbackActive = false
    private var rings: (mic: RingBuffer, session: RingBuffer)?
    private var pinnedMicUID: String?            // the session's mic, even if the default changes later
    private var sessionRate: Double?             // retargets must keep the rate the files use
    private var retargetFailures = 0
    private let controlKey = DispatchSpecificKey<Bool>()
    private let roundTripAtomic = AtomicU64(0)
    private let inputLatencyAtomic = AtomicU64(0)

    // Shared with the IO thread: atomics + preallocated memory only.
    private var pendingSilence = 0               // frames owed after an overflow (IO thread only)
    private let silence = UnsafeMutablePointer<Float>.allocate(capacity: 32_768)
    private let anchor = AtomicU64(0)            // host time of session frame 0
    private let framesDelivered = AtomicU64(0)
    private let ioCalls = AtomicU64(0)            // diagnostics: IO callbacks, and how many had no tap stream
    private let ioNoTap = AtomicU64(0)
    private let fillGap = AtomicU64(0)           // 1 = after a rebuild: pay back the gap as silence
    private let ticksPerSecond: Double
    private let micScratch = UnsafeMutablePointer<Float>.allocate(capacity: 16_384)
    private let stereoScratch = UnsafeMutablePointer<Float>.allocate(capacity: 32_768)
    private static let scratchFrames = 16_384

    public init(target: Target) {
        self.target = target
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        ticksPerSecond = 1e9 * Double(info.denom) / Double(info.numer)
        silence.initialize(repeating: 0, count: 32_768)
        control.setSpecific(key: controlKey, value: true)
    }

    /// Runs on the control queue; safe to call from it (the property listener, deinit via a release there).
    private func onControl<T>(_ body: () throws -> T) rethrows -> T {
        DispatchQueue.getSpecific(key: controlKey) == true ? try body() : try control.sync(execute: body)
    }

    deinit {
        stop()
        micScratch.deallocate()
        stereoScratch.deallocate()
        silence.deallocate()
    }

    public func start(mic: RingBuffer, session: RingBuffer) throws {
        try onControl {
            rings = (mic, session)
            // Listen BEFORE building, then re-check: a DAW that opens audio during build is never missed.
            if case let .process(pid) = target, Self.processObject(pid) == nil { watchForProcess(pid) }
            do {
                try build()
            } catch {
                unwatch()
                teardown()
                throw error
            }
            if !fallbackActive {
                unwatch()
            } else if case let .process(pid) = target, Self.processObject(pid) != nil {
                retarget()
            }
            stallChecks = 0
            scheduleStallCheck()
        }
    }

    /// Watchdog for the whole session: whenever no audio has arrived for a second (a device built under
    /// a permission prompt, or one another process knocked out mid-take), rebuild; give up after ~20 tries
    /// in a row and say so. Each stall is logged to ~/Library/Logs/Hot Mic/capture.log.
    private var stallChecks = 0

    static func diag(_ line: String) { HotMicLog.write("capture: " + line) }
    private var lastFrames: UInt64 = 0
    private func scheduleStallCheck() {
        control.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.rings != nil else { return }
            let frames = self.framesDelivered.value
            if frames > self.lastFrames { self.lastFrames = frames; self.stallChecks = 0; self.scheduleStallCheck(); return }
            // No new audio for a second: at the start (a device that never ran) or mid-session (another
            // process, e.g. corespeechd's voice processing, knocked the device out). Rebuild; the first
            // callback afterwards pays back the gap as silence so the timeline stays in step.
            self.stallChecks += 1
            Self.diag("stall \(frames == 0 ? "at start" : "mid-session at \(Int(Double(frames) / self.sampleRate)) s") #\(self.stallChecks): io callbacks=\(self.ioCalls.value) without tap stream=\(self.ioNoTap.value)")
            if self.stallChecks == 2 {
                Self.diag("  output running: " + Self.audioProcesses().filter { $0.output }.map { "\($0.bundle)[\($0.pid)]" }.joined(separator: ", "))
            }
            if self.stallChecks > 20 {
                self.onProblem?("No audio is coming in. Check System Settings → Privacy & Security → Microphone and Screen & System Audio Recording, then start again.")
                return
            }
            self.teardown()
            if frames > 0 { self.fillGap.value = 1 }
            do { try self.build(forceFallback: self.fallbackActive) } catch { Self.diag("rebuild failed: \(error)") }
            self.scheduleStallCheck()
        }
    }

    public func stop() {
        onControl {
            unwatch()
            teardown()
            rings = nil
            pinnedMicUID = nil
            sessionRate = nil
            retargetFailures = 0
        }
    }

    // MARK: - build / teardown (control queue)

    private func build(forceFallback: Bool = false) throws {
        guard let rings else { return }
        let system = AudioObjectID(kAudioObjectSystemObject)
        let micDevice: AudioObjectID
        if let uid = pinnedMicUID {
            guard let device = HAL.device(uid: uid) else { throw CaptureError.coreAudio("session microphone disconnected", -1) }
            micDevice = device
        } else {
            micDevice = try HAL.get(system, kAudioHardwarePropertyDefaultInputDevice, 0)
        }
        let outDevice: AudioObjectID = try HAL.get(system, kAudioHardwarePropertyDefaultOutputDevice, 0)
        let micStreams = try HAL.inputStreamChannels(micDevice).count

        let description = try tapDescription(forceFallback: forceFallback)
        try HAL.check(AudioHardwareCreateProcessTap(description, &tapID), "create process tap")

        let micUID = try HAL.uid(micDevice)
        pinnedMicUID = micUID
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Hot Mic",
            kAudioAggregateDeviceUIDKey: "io.bluegum.hotmic.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: micUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: false,   // true = IO waits for some app to play sound before running at all
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: micUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        try HAL.check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "create aggregate")
        let rate: Float64 = try HAL.get(aggregateID, kAudioDevicePropertyNominalSampleRate, Float64(0))
        if let sessionRate, sessionRate != rate {
            throw CaptureError.coreAudio("sample rate changed from \(Int(sessionRate)) to \(Int(rate)) Hz", -1)
        }
        sessionRate = rate
        sampleRate = rate
        let input = HAL.latencyFrames(micDevice, scope: kAudioObjectPropertyScopeInput)
        inputLatencyAtomic.value = UInt64(input)
        roundTripAtomic.value = UInt64(HAL.latencyFrames(outDevice, scope: kAudioObjectPropertyScopeOutput) + input)

        // nil queue: the block runs on the HAL's real-time IO thread.
        let (mic, session) = rings
        try HAL.check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { [unowned self] _, input, inputTime, _, _ in
            self.deliver(input, time: inputTime, micStreams: micStreams, mic: mic, session: session)
        }, "create IO proc")
        try HAL.check(AudioDeviceStart(aggregateID, procID), "start aggregate")
    }

    private func teardown() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)       // returns after the IO proc has finished
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func tapDescription(forceFallback: Bool) throws -> CATapDescription {
        let description: CATapDescription
        fallbackActive = false
        if forceFallback {
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.ownProcessObjects())
            fallbackActive = true
            description.uuid = UUID(); description.isPrivate = true; description.muteBehavior = .unmuted
            return description
        }
        switch target {
        case .systemAudio:
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.ownProcessObjects())
        case .systemAudioWithOwn:
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        case let .process(pid):
            if let object = Self.processObject(pid) {
                description = CATapDescription(stereoMixdownOfProcesses: [object])
            } else {
                description = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.ownProcessObjects())
                fallbackActive = true
            }
        }
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        return description
    }

    // MARK: - switching to the DAW once it opens audio

    private func watchForProcess(_ pid: pid_t) {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, Self.processObject(pid) != nil else { return }
            self.retarget()
        }
        processListener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, control, listener)
    }

    private func unwatch() {
        guard let listener = processListener else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, control, listener)
        processListener = nil
    }

    /// Runs on `control`. Rebuilds on the DAW-only tap. The first callback afterwards pays back the
    /// switch gap as silence, so the files stay in step with wall-clock time and bar stamps.
    private func retarget() {
        guard fallbackActive, rings != nil, retargetFailures < 3 else { return }
        teardown()
        fillGap.value = 1
        do {
            try build()
            if !fallbackActive { unwatch() }
            onProblem?("")                                   // clear any earlier warning
        } catch {
            // Never leave the session silent: go back to recording system audio and keep watching.
            retargetFailures += 1
            teardown()
            fillGap.value = 1
            do {
                try build(forceFallback: true)
            } catch {
                unwatch()
                onFailure?("Recording stopped: \(error)")
                return
            }
            onProblem?("Couldn't switch to your DAW's audio yet (\(error)); recording all system audio for now.")
        }
    }

    // MARK: - IO thread: atomics and preallocated memory only

    private func deliver(_ input: UnsafePointer<AudioBufferList>, time: UnsafePointer<AudioTimeStamp>,
                         micStreams: Int, mic: RingBuffer, session: RingBuffer) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        ioCalls.add(1)
        guard buffers.count > micStreams, let micData = buffers[0].mData,
              let tapData = buffers[micStreams].mData else { ioNoTap.add(1); return }
        let micChannels = max(Int(buffers[0].mNumberChannels), 1)
        let tapChannels = max(Int(buffers[micStreams].mNumberChannels), 1)
        let frames = min(Int(buffers[0].mDataByteSize) / (4 * micChannels),
                         Int(buffers[micStreams].mDataByteSize) / (4 * tapChannels), Self.scratchFrames)

        if time.pointee.mFlags.contains(.hostTimeValid) {
            if anchor.value == 0 {
                anchor.value = time.pointee.mHostTime             // session frame 0
            } else if fillGap.value == 1 {
                // Frames that should exist by now (wall clock) minus frames we have: the switch gap.
                let expected = Double(time.pointee.mHostTime &- anchor.value) / ticksPerSecond * sampleRate
                let gap = Int(expected) - Int(framesDelivered.value)
                if gap > 0 { pendingSilence += gap; framesDelivered.add(UInt64(gap)) }
                fillGap.value = 0
            }
        }

        let micSamples = micData.assumingMemoryBound(to: Float.self)
        let tapSamples = tapData.assumingMemoryBound(to: Float.self)
        let right = tapChannels > 1 ? 1 : 0
        for i in 0..<frames {
            micScratch[i] = micSamples[i * micChannels]
            stereoScratch[2 * i] = tapSamples[i * tapChannels]
            stereoScratch[2 * i + 1] = tapSamples[i * tapChannels + right]
        }
        framesDelivered.add(UInt64(frames))
        // After an overflow, pay back the lost time as silence first, so the files and the
        // bar-stamp timeline stay in step with real time.
        var paidThisCallback = 0
        while pendingSilence > 0, paidThisCallback < 4 * max(frames, 512) {   // bounded work per IO cycle
            let n = min(pendingSilence, 16_384, 4 * max(frames, 512) - paidThisCallback)
            guard mic.freeSpace >= n + frames, session.freeSpace >= (n + frames) * 2 else { break }
            if session.write(silence, count: n * 2) { mic.write(silence, count: n) }
            pendingSilence -= n
            paidThisCallback += n
        }
        // Write both or neither so the streams never drift apart.
        guard pendingSilence == 0, mic.freeSpace >= frames, session.freeSpace >= frames * 2 else {
            mic.noteDropped(frames)
            pendingSilence += frames
            return
        }
        if session.write(stereoScratch, count: frames * 2) { mic.write(micScratch, count: frames) }
    }

    // MARK: - process objects

    static func processObject(_ pid: pid_t) -> AudioObjectID? {
        let object: AudioObjectID? = try? HAL.get(AudioObjectID(kAudioObjectSystemObject),
                                                  kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                  AudioObjectID(0), qualifier: pid)
        guard let object, object != kAudioObjectUnknown else { return nil }
        return object
    }

    /// Every process Core Audio knows, with whether its output is running (diagnostics).
    static func audioProcesses() -> [(pid: pid_t, bundle: String, output: Bool)] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map { id in
            let pid: pid_t = (try? HAL.get(id, kAudioProcessPropertyPID, pid_t(0))) ?? 0
            let out: UInt32 = (try? HAL.get(id, kAudioProcessPropertyIsRunningOutput, UInt32(0))) ?? 0
            var b: CFString = "" as CFString
            var bs = UInt32(MemoryLayout<CFString>.size)
            var ba = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            _ = withUnsafeMutablePointer(to: &b) { AudioObjectGetPropertyData(id, &ba, 0, nil, &bs, $0) }
            return (pid, b as String, out != 0)
        }
    }

    /// Hot Mic's own audio (take previews) must never be in the reference or the mix.
    static func ownProcessObjects() -> [AudioObjectID] {
        processObject(getpid()).map { [$0] } ?? []
    }
}

/// Minimal typed Core Audio property access.
enum HAL {
    static func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr { throw CaptureError.coreAudio(what, status) }
    }

    static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                       qualifier: pid_t? = nil) throws -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { valuePtr -> OSStatus in
            if var q = qualifier {
                return AudioObjectGetPropertyData(object, &address, UInt32(MemoryLayout<pid_t>.size), &q, &size, valuePtr)
            }
            return AudioObjectGetPropertyData(object, &address, 0, nil, &size, valuePtr)
        }
        try check(status, "read property \(selector)")
        return value
    }

    static func device(uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &cf) { q in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), q, &size, &device)
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    static func uid(_ device: AudioObjectID) throws -> String {
        let value: Unmanaged<CFString>? = try get(device, kAudioDevicePropertyDeviceUID, nil)
        guard let value else { throw CaptureError.coreAudio("device UID", -1) }
        return value.takeRetainedValue() as String
    }

    static func inputStreamChannels(_ device: AudioObjectID) throws -> [Int] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size), "stream config size")
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw), "stream config")
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).map { Int($0.mNumberChannels) }
    }

    /// Device latency + safety offset + first stream's latency, in frames (0 if unreadable).
    static func latencyFrames(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        let latency: UInt32 = (try? get(device, kAudioDevicePropertyLatency, UInt32(0), scope: scope)) ?? 0
        let safety: UInt32 = (try? get(device, kAudioDevicePropertySafetyOffset, UInt32(0), scope: scope)) ?? 0
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        var streamLatency: UInt32 = 0
        if AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size >= UInt32(MemoryLayout<AudioObjectID>.size) {
            var streams = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams) == noErr, let first = streams.first {
                streamLatency = (try? get(first, kAudioStreamPropertyLatency, UInt32(0))) ?? 0
            }
        }
        return Int(latency) + Int(safety) + Int(streamLatency)
    }
}
