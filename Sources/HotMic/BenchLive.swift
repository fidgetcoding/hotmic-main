import AVFoundation
import Capture
import Detection
import Enrichment
import Foundation
import Library
import Transcription

/// Bench: plays a recording through the live session path in real time, the way a Freestyle session
/// records it: Apple live words → lines (`live-lines.json`) → Whisper on each line, and the jam take
/// pipeline beside it. Capture, echo cancelling and the window are left out; everything after them is
/// the session's own code. `--beat` judges like Beat mode (the beat's bleed is never your playing).
///   open -n ".build/Hot Mic.app" --args --bench-live <voice file> --out <session folder> [--mix <file>] [--beat]
/// Logs to hotmic.log ("bench-live: …") and quits when the folder is complete.
enum BenchLive {
    static func start(arguments args: [String], settings: PipelineSettings, lineTranscriber: WhisperTranscriber?) -> Bool {
        guard let i = args.firstIndex(of: "--bench-live"), args.count > i + 1,
              let o = args.firstIndex(of: "--out"), args.count > o + 1 else { return false }
        let voice = URL(fileURLWithPath: args[i + 1]), folder = URL(fileURLWithPath: args[o + 1], isDirectory: true)
        let mix = args.firstIndex(of: "--mix").flatMap { args.count > $0 + 1 ? URL(fileURLWithPath: args[$0 + 1]) : nil }
        let beat = args.contains("--beat")
        LiveWords.requestPermission { ok in
            HotMicLog.write("bench-live: \(voice.lastPathComponent) → \(folder.path), speech permission \(ok)")
            guard ok else { exit(1) }
            Thread.detachNewThread {
                do {
                    try run(voice: voice, mix: mix, folder: folder, beat: beat, settings: settings, lineTranscriber: lineTranscriber)
                } catch {
                    HotMicLog.write("bench-live: failed \(error)")
                    exit(1)
                }
            }
        }
        return true
    }

    private static func read(_ url: URL) throws -> (channels: [[Float]], rate: Double) {
        let file = try AVAudioFile(forReading: url)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              let data = buf.floatChannelData else { throw RecordingImport.ImportError.empty }
        try file.read(into: buf)
        let n = Int(buf.frameLength)
        let channels = (0..<Int(file.processingFormat.channelCount)).map { Array(UnsafeBufferPointer(start: data[$0], count: n)) }
        return (channels, file.processingFormat.sampleRate)
    }

    private static func run(voice voiceURL: URL, mix mixURL: URL?, folder: URL, beat: Bool,
                            settings: PipelineSettings, lineTranscriber: WhisperTranscriber?) throws {
        let (voiceChannels, rate) = try read(voiceURL)
        let voice = voiceChannels.count == 1 ? voiceChannels[0]
            : zip(voiceChannels[0], voiceChannels[1]).map { ($0 + $1) / 2 }
        let mix = try mixURL.map { try read($0) }
        if let mix, mix.rate != rate { throw RecordingImport.ImportError.mixRate }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let pipeline = try TakePipeline(folder: folder, sampleRate: rate, sessionStart: Date(), daw: "Jam", jam: true)
        settings.configure(pipeline, jam: true, onLyrics: { _, _ in })
        if beat { pipeline.judge = JamJudge(beat: true) }
        let live = LiveWords()
        let fixes = DispatchGroup()
        var recent: [String] = []
        // Same as a session's onLine (HotMicApp.startSession): keep the line, then Whisper just its audio.
        live.onLine = { text, at, end, audio, cut in
            LiveLines.append(LiveLine(text: text, at: at, end: end, cut: cut ? true : nil), to: folder)
            HotMicLog.write(String(format: "bench-live: line %.1f–%.1f \"%@\"", at, end, text))
            guard let lineTranscriber, audio.count > Int(rate * 0.3) else { return }
            let hint = recent.suffix(4).joined(separator: " ")
            recent.append(text)
            fixes.enter()
            Task.detached(priority: .userInitiated) {
                defer { fixes.leave() }
                let levelled = Loudness().normalize(audio, channels: 1, sampleRate: rate)
                guard let lyrics = try? await lineTranscriber.transcribe(levelled, sampleRate: rate, hint: hint) else { return }
                let fixed = lyrics.text.trimmingCharacters(in: .whitespacesAndNewlines)
                HotMicLog.write(String(format: "bench-live: line fix %.1f s: \"%@\" → \"%@\"", at, text, fixed))
                guard !fixed.isEmpty, !LiveLines.isJunk(fixed) else { return }
                LiveLines.fix(at: at, text: fixed, in: folder)
            }
        }
        live.onNotice = { n in if let n { HotMicLog.write("bench-live: notice \(n)") } }
        pipeline.onTake = { _ in live.nextLine() }
        live.start(sampleRate: rate)

        let voiceSink = try SegmentedAACWriter(folder: folder, baseName: "session__voice", sampleRate: rate, channels: 1, bitRate: 96_000)
        let mixSink = try SegmentedAACWriter(folder: folder, baseName: "session__mix", sampleRate: rate, channels: 2, bitRate: 192_000)
        let hop = 1_024, total = voice.count
        var stereo = [Float](repeating: 0, count: hop * 2)
        let clockStart = Date()
        var k = 0
        while k < total {
            let n = min(hop, total - k)
            for j in 0..<n {
                let l = mix.map { $0.channels[0][k + j] } ?? voice[k + j]
                let r = mix.map { $0.channels[min(1, $0.channels.count - 1)][k + j] } ?? voice[k + j]
                stereo[2 * j] = l; stereo[2 * j + 1] = r
            }
            try voice[k..<(k + n)].withUnsafeBufferPointer { v in
                try stereo.withUnsafeBufferPointer { m in
                    try voiceSink.append(interleaved: v, frames: n)
                    try mixSink.append(interleaved: UnsafeBufferPointer(rebasing: m[0..<(2 * n)]), frames: n)
                    pipeline.consume(voice: v, mix: m, frames: n, position: Int64(k))
                    live.feed(v)
                }
            }
            k += n
            // Real time: Apple's recognizer is fed at the pace a session would feed it.
            let ahead = Double(k) / rate - Date().timeIntervalSince(clockStart)
            if ahead > 0 { Thread.sleep(forTimeInterval: ahead) }
        }
        DispatchQueue.main.sync { live.stop() }
        Thread.sleep(forTimeInterval: 3)           // the last line commits, its Whisper starts
        try pipeline.finish()
        try voiceSink.finish()
        try mixSink.finish()
        let done = DispatchSemaphore(value: 0)
        Task.detached { await pipeline.waitForLyrics(); done.signal() }
        done.wait()
        fixes.wait()
        HotMicLog.write(String(format: "bench-live: done, %d takes, %.0f s", pipeline.takes.count, Date().timeIntervalSince(clockStart)))
        exit(0)
    }
}
