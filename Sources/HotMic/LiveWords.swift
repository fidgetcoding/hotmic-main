import AVFoundation
import Capture
import Library
import Speech

/// Words as you sing them: Apple's on-device recognizer on the session's voice signal.
/// What you see is what you keep: a pause (≥ 0.9 s between words), 12 words, or 1.2 s of quiet
/// finishes a line, which is committed with its session time (`onLine`) and never cleared. Only the
/// line in progress is "live" (`onWords`). Whisper later corrects committed lines where a take covers them.
/// Nothing leaves the Mac (on-device only; if the Mac can't recognize on-device, it stays off).
final class LiveWords: @unchecked Sendable {
    /// The line in progress (text, final) — called on the main queue. "" = nothing in progress.
    var onWords: ((String, Bool) -> Void)?
    /// A finished line: (text, session seconds start, end, its audio padded a little, cut by Stop) — main queue.
    var onLine: ((String, Double, Double, [Float], Bool) -> Void)?
    /// Set while Stop commits the line you were still singing.
    private var stopping = false
    /// The last minute of voice, so each finished line's own audio can go to Whisper.
    private var history: [Float] = []
    private var historyStart: Int64 = 0        // session frame of history[0]

    static let lineGap = LyricArranger.lineGap, maxWords = LyricArranger.maxWords, settle = 1.2, maxRequest = 10.0
    /// Where the last committed line ended (session seconds, main queue): the next clip never starts before it.
    private var lastLineEnd = -Double.infinity

    /// One recognition request: where it starts in the session, and how many of its words are lines already.
    private final class Pass {
        let base: Double
        var committed = 0
        var last: [(text: String, start: Double, end: Double)] = []
        /// When each word first showed up (request seconds). Partial results carry no timings (Apple
        /// fills them in only when a request ends), so arrival time is what places words and finds pauses.
        var arrived: [Double] = []
        var timer: DispatchWorkItem?
        /// Apple sent anything at all for this request (set on the recognizer's queue, read on the audio thread).
        var heard = false
        /// Replaced by a fresh request that re-hears its audio: whatever it sends late is dropped (no doubled lines).
        var abandoned = false
        init(base: Double) { self.base = base }
    }
    private var pass: Pass?                 // the current request's (set under lock, used on main)
    private var framesFed: Int64 = 0
    /// Recording more into an existing session: seconds already recorded.
    var timeOffset: Double = 0
    /// Permission or capability problem worth one line in the window (nil = fine).
    var onNotice: ((String?) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var format: AVAudioFormat?
    private var started = Date.distantPast
    private var running = false
    private var rate: Double = 48_000

    static var authorized: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }

    /// Asks once (the first time you record). Calls back on the main queue.
    static func requestPermission(_ done: @escaping (Bool) -> Void) {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: done(true)
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { s in DispatchQueue.main.async { done(s == .authorized) } }
        default: done(false)
        }
    }

    func start(sampleRate: Double) {
        lock.lock(); rate = sampleRate; let gone = stopped; lock.unlock()
        if gone { return }
        guard Self.authorized else { DispatchQueue.main.async { self.onNotice?("Live words are off: allow Speech Recognition for Hot Mic in System Settings › Privacy. Lyrics still arrive after each take.") }; return }
        guard let recognizer, recognizer.supportsOnDeviceRecognition else {
            DispatchQueue.main.async { self.onNotice?("Live words need on-device speech recognition, which this Mac doesn't have. Lyrics still arrive after each take.") }
            return
        }
        lock.lock(); format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1); running = true; lock.unlock()
        DispatchQueue.main.async { self.onNotice?(nil) }
        restart()
    }

    /// Permission just arrived: switch on for the running session.
    func retry() { lock.lock(); let r = rate, on = running; lock.unlock(); if !on { start(sampleRate: r) } }

    private var stopped = false

    func stop() {
        // The line you were still singing when you hit stop is a line too.
        if let p = lock.withLock({ pass }) {
            DispatchQueue.main.async { [weak self] in
                guard let self, p.committed < p.last.count else { return }
                p.timer?.cancel()
                self.stopping = true
                self.commit(Array(p.last.dropFirst(p.committed)), in: p)
                self.stopping = false
            }
        }
        lock.lock(); stopped = true; lock.unlock()
        lock.lock(); running = false; let r = request, t = task; request = nil; task = nil; lock.unlock()
        r?.endAudio(); t?.finish()
        DispatchQueue.main.async { self.onWords?("", true) }
    }

    /// A take landed. Lines stay where they are (Whisper corrects them later), so nothing to do.
    func nextLine() {}

    /// Audio thread: the processed voice, mono float.
    func feed(_ samples: UnsafeBufferPointer<Float>) {
        lock.lock()
        guard running, let request, let format, samples.count > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { lock.unlock(); return }
        let tooLong = Date().timeIntervalSince(started) > 50     // Apple caps a request at about a minute
        // A request that hears you singing but sends nothing back is stuck (Nate's 2026-10-14 tests: four sessions,
        // 5–45 s, not one word until Stop, then "No speech detected"). After 3.5 s of that, start a fresh request
        // and hand it the last 3 s again so the words that went unheard still land.
        let deaf = sinceDeafCheck(samples.count) && LiveVoice.isStuck(
            heardAnything: pass?.heard ?? true, secondsSinceStart: Date().timeIntervalSince(started),
            recent: history[max(0, history.count - Int(rate * min(6, Date().timeIntervalSince(started))))...], rate: rate)
        framesFed += Int64(samples.count)
        history.append(contentsOf: samples)
        let keep = Int(rate * 60)
        if history.count > keep + Int(rate * 10) {
            let drop = history.count - keep
            history.removeFirst(drop); historyStart += Int64(drop)
        }
        lock.unlock()
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let dst = buffer.floatChannelData?[0], let src = samples.baseAddress { dst.update(from: src, count: samples.count) }
        request.append(buffer)
        if tooLong { restart() }
        else if deaf { HotMicLog.write("live: request heard nothing through 2.5 s of singing, starting over with what it missed"); pass?.abandoned = true; restart(replay: min(6, Date().timeIntervalSince(started))) }
    }

    private var deafCheckFrames = 0
    /// True about once a second (audio thread, under the lock).
    private func sinceDeafCheck(_ n: Int) -> Bool {
        deafCheckFrames += n
        if deafCheckFrames < Int(rate) { return false }
        deafCheckFrames = 0; return true
    }
    private func restart(replay: Double = 0) {
        lock.lock()
        let oldReq = request, oldTask = task
        guard running, let recognizer else { lock.unlock(); return }
        let back = min(Int(rate * replay), history.count)
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        req.taskHint = .dictation
        request = req
        started = Date()
        let p = Pass(base: Double(framesFed - Int64(back)) / rate + timeOffset)
        pass = p
        HotMicLog.write(String(format: "live: new request at %.1f s", p.base))
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            // Apple ends a request with an error after a pause ("no speech", or a timeout). Live words
            // went quiet for the rest of the take; keep the words so far and listen again.
            guard let result else {
                if let error {
                    HotMicLog.write(String(format: "live: request at %.1f s ended with %@", p.base, "\(error)"))
                    DispatchQueue.main.async { self.handle(p.last, final: true, in: p) }
                }
                return
            }
            if !result.bestTranscription.segments.isEmpty { p.heard = true }
            let segs = result.bestTranscription.segments.map { (text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration) }
            let final = result.isFinal
            DispatchQueue.main.async { self.handle(segs, final: final, in: p) }
        }
        // Replay: the new request starts by hearing the last few seconds again.
        if back > 0, let format, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(back)), let dst = buf.floatChannelData?[0] {
            buf.frameLength = AVAudioFrameCount(back)
            history.withUnsafeBufferPointer { src in dst.update(from: src.baseAddress! + (src.count - back), count: back) }
            req.append(buf)
        }
        lock.unlock()
        oldReq?.endAudio(); oldTask?.finish()
    }

    // MARK: - lines (main queue)

    private func handle(_ raw: [(text: String, start: Double, end: Double)], final: Bool, in p: Pass) {
        if p.abandoned { return }
        let now = lock.withLock { Double(framesFed) / rate + timeOffset } - p.base - 0.35   // recognizer lag
        while p.arrived.count < raw.count { p.arrived.append(max(0, now)) }
        let segs = raw.enumerated().map { i, s in
            s.end > 0 ? s : (text: s.text, start: p.arrived[i], end: p.arrived[i] + 0.3)
        }
        p.last = segs
        let current = lock.withLock { pass === p }
        // The cut (a pause, or the word limit) lives in Library so the lyric scenario harness runs the same rule.
        let lines = LyricArranger.lines(words: segs.dropFirst(min(p.committed, segs.count)).map { TimedWord(text: $0.text, start: $0.start, end: $0.end) },
                                        voiced: { [weak self] a, b in self?.voiced(from: p.base + a, to: p.base + b) ?? false })
            .map { $0.map { (text: $0.text, start: $0.start, end: $0.end) } }
        // Every line but the one still being sung is finished (all of them once Apple calls it final).
        for line in (final || !current ? lines : Array(lines.dropLast())) { commit(line, in: p) }
        guard current else { return }
        let tail = final ? "" : (lines.last.map { $0.map(\.text).joined(separator: " ") } ?? "")
        onWords?(tail, false)
        // Quiet for a moment: the line in progress is done too.
        p.timer?.cancel()
        if !tail.isEmpty, let line = lines.last {
            let count = segs.count
            let work = DispatchWorkItem { [weak self] in
                guard let self, p.last.count == count, p.committed < count else { return }
                // Still mumbling: the line isn't done, wait for the words after it (up to `maxSpan`).
                let now = self.lock.withLock { Double(self.framesFed) / self.rate + self.timeOffset }
                if let first = line.first, now - (p.base + first.start) < LyricArranger.maxSpan, self.voiced(from: now - 0.6, to: now) {
                    self.handle(p.last, final: false, in: p); return
                }
                self.commit(line, in: p)
                // A pause: start a fresh request. Long continuous requests make Apple's on-device
                // recognizer lag and then stop (2026-10-12 tests stalled at 7–18 s).
                if self.lock.withLock({ self.pass === p }) { self.onWords?("", false); self.restart() }
            }
            p.timer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle, execute: work)
        }
        if final, current { restart() }     // an old request finishing late must not cut off the new one
    }

    /// Sound between `a` and `b` (session seconds).
    private func voiced(from a: Double, to b: Double) -> Bool {
        lock.withLock {
            let from = max(0, Int((a - timeOffset) * rate) - Int(historyStart)), to = min(history.count, Int((b - timeOffset) * rate) - Int(historyStart))
            return from < to && LiveVoice.isVoiced(history[from..<to], rate: rate)
        }
    }

    private func commit(_ line: [(text: String, start: Double, end: Double)], in p: Pass) {
        guard let first = line.first, let last = line.last else { return }
        p.committed += line.count
        // Rapping straight through never leaves a pause to restart on: after ~10 s, restart at this line
        // boundary anyway (requests that run longer stall at 7–18 s). Words already in flight finish in
        // the old request and arrive as their own line.
        if lock.withLock({ pass === p }), Date().timeIntervalSince(lock.withLock { started }) > Self.maxRequest {
            DispatchQueue.main.async { [weak self] in if self?.lock.withLock({ self?.pass === p }) == true { self?.restart() } }
        }
        let text = line.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        HotMicLog.write(String(format: "live: line %.1f–%.1f s", p.base + first.start, p.base + last.end))
        let (a, b) = (p.base + first.start, p.base + last.end)
        // Words are placed by when they ARRIVED, up to ~1 s after they were sung (Nate's 2026-10-13 test:
        // 0.35–0.95 s late), so a 0.4 s lead cut the first word off: Whisper heard "I don't, what it?" for
        // "because I don't want", and nothing at all for three short lines. Reach back further, never into the line before.
        let start = LiveVoice.clipStart(lineStart: a, previousLineEnd: lastLineEnd)
        lastLineEnd = b
        let audio: [Float] = lock.withLock {
            let from = max(0, Int((start - timeOffset) * rate) - Int(historyStart)), to = min(history.count, Int((b - timeOffset + 0.6) * rate) - Int(historyStart))
            return from < to ? Array(history[from..<to]) : []
        }
        onLine?(text, a, b, audio, stopping)
    }
}
