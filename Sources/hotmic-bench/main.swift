// hotmic-bench: runs a recording through Hot Mic headless, the way a dropped recording goes through the
// window (jam pipeline, Whisper lyrics), and writes what the window would show plus the stitched song.
// Usage:
//   hotmic-bench import <audio> <session folder> [--mix <audio>] [--no-lyrics] [--model <WhisperKit model>]
//   hotmic-bench export <session folder> <out.json>
//   hotmic-bench retranscribe <session folder> [--model m] [switches]     (the same takes decoded again; lyrics written to the folder)
//   hotmic-bench stitch <session folder> <out.m4a> [--voice] [--plan <out.json>]
//   hotmic-bench transcribe <audio> [--model <m>] [--hint "<earlier lyrics>"] [--no-prompt] [--no-vad] [--no-speech <0…1>]
//                                  (the app's Whisper on one file; the switches find what drops words)
//   hotmic-bench plan <session folder> <out.json>                          (the whole-song plan, no audio written)
//   hotmic-bench judge <session folder>                                    (the model pass; answers go in the folder)
//   hotmic-bench verdicts <session folder> <out.json> [--no-model] [--no-learner]    (every line's verdict and who decided)
//   hotmic-bench teach <line-judge.json> <folder>=<truth.jsonl> … [--budget <n>]      (a learner from simulated corrections)
//   hotmic-bench replay <folder>=<truth.jsonl> … [--budget <n per session>]  (simulated corrections teach the learner; see JudgeReplay)
import AVFoundation
import Foundation
import Library
import Transcription

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(2)
}

func option(_ name: String, in args: [String]) -> String? {
    args.firstIndex(of: name).flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil }
}

func writeJSON<T: Encodable>(_ value: T, to path: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: URL(fileURLWithPath: path))
}

func tuningOptions(_ args: [String]) -> WhisperTranscriber.Tuning {
    var tuning = WhisperTranscriber.Tuning()
    if args.contains("--no-prompt") { tuning.prompt = false }
    if args.contains("--no-vad") { tuning.vadChunking = false }
    if args.contains("--no-hint") { tuning.sessionHint = false }
    if let t = option("--no-speech", in: args).flatMap(Float.init) { tuning.noSpeechThreshold = t }
    if let l = option("--language", in: args) { tuning.language = l }
    tuning.debug = args.contains("--debug")
    if args.contains("--no-timestamps") { tuning.timestamps = false }
    if let t = option("--temperature", in: args).flatMap(Float.init) { tuning.temperature = t }
    if let p = option("--piece", in: args).flatMap(Double.init) { tuning.pieceSeconds = p; tuning.searchSeconds = min(tuning.searchSeconds, p / 3) }
    if let f = option("--fallbacks", in: args).flatMap(Int.init) { tuning.fallbacks = f }
    if let t = option("--logprob", in: args).flatMap(Float.init) { tuning.logProbThreshold = t }
    if args.contains("--no-logprob") { tuning.logProbThreshold = nil }
    if args.contains("--no-compression") { tuning.compressionThreshold = nil }
    if args.contains("--loopfix") { tuning.loopFix = true }
    if args.contains("--retries") { tuning.retries = true }
    if let m = option("--min-rate", in: args).flatMap(Double.init) { tuning.minWordsPerVoicedSecond = m }
    return tuning
}

setvbuf(stdout, nil, _IOLBF, 0)   // progress lines reach a log file as they happen
let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail("usage: hotmic-bench import|export|stitch …") }

switch command {
case "import":
    guard args.count >= 3 else { fail("usage: hotmic-bench import <audio> <session folder> [--mix <audio>] [--no-lyrics]") }
    let audio = URL(fileURLWithPath: args[1]), folder = URL(fileURLWithPath: args[2], isDirectory: true)
    let mix = option("--mix", in: args).map { URL(fileURLWithPath: $0) }
    let lyrics = !args.contains("--no-lyrics")
    let transcriber = option("--model", in: args).map { WhisperTranscriber(model: $0) } ?? WhisperTranscriber()
    let started = Date()
    if lyrics { try await transcriber.prepare() }
    var shown = -1
    // Same settings the app gives a dropped recording (PipelineSettings.configure, jam, every feature on).
    let takes = try await RecordingImport.run(url: audio, folder: folder, mix: mix, configure: { pipeline in
        pipeline.beatboxEnabled = false
        pipeline.options = ExportOptions()
        if lyrics { pipeline.transcriber = transcriber }
        pipeline.onLyrics = { id, l in print("lyrics \(id): \(l.text.prefix(80))") }
    }, progress: { p in
        let pct = Int(p * 100)
        if pct >= shown + 10 { shown = pct; print("read \(pct)%") }
    })
    print(String(format: "done: %d takes in %.0f s", takes.count, Date().timeIntervalSince(started)))

case "export":
    guard args.count >= 3 else { fail("usage: hotmic-bench export <session folder> <out.json>") }
    let session = LabSessionExport.session(folder: URL(fileURLWithPath: args[1], isDirectory: true))
    try LabSessionExport.json(session).write(toFile: args[2], atomically: true, encoding: .utf8)
    print("wrote \(args[2]) · \(session.takes.count) takes · \(session.slots.count) lines")

case "stitch":
    guard args.count >= 3 else { fail("usage: hotmic-bench stitch <session folder> <out.m4a> [--voice] [--plan <out.json>]") }
    let session = LabSessionExport.session(folder: URL(fileURLWithPath: args[1], isDirectory: true))
    let clips = WholeSong.plan(session.slots)
    let sources = (args.contains("--voice") ? session.sessionAudio : session.sessionMix).map { URL(fileURLWithPath: $0) }
    try WholeSong.render(clips, segments: sources, segmentSeconds: session.segmentSeconds, to: URL(fileURLWithPath: args[2]))
    if let plan = option("--plan", in: args) { try writeJSON(clips, to: plan) }
    let seconds = clips.reduce(0) { $0 + $1.end - $1.start }
    print(String(format: "wrote %@ · %d clips · %d lines · %.1f s", args[2], clips.count, clips.reduce(0) { $0 + $1.lines.count }, seconds))

case "plan":
    guard args.count >= 3 else { fail("usage: hotmic-bench plan <session folder> <out.json>") }
    let session = LabSessionExport.session(folder: URL(fileURLWithPath: args[1], isDirectory: true))
    try writeJSON(WholeSong.plan(session.slots), to: args[2])

case "retranscribe":
    // Decodes a session's takes again from its recording, with the same take boundaries, so transcription
    // settings can be compared without running detection again. Writes lyrics into the folder's sidecars.
    guard args.count >= 2 else { fail("usage: hotmic-bench retranscribe <session folder> [--model m] [switches]") }
    let folder = URL(fileURLWithPath: args[1], isDirectory: true)
    let transcriber = WhisperTranscriber(model: option("--model", in: args) ?? WhisperTranscriber.defaultModel, tuning: tuningOptions(args))
    let segments = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("session__voice_") && $0.pathExtension == "m4a" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard let first = segments.first else { fail("no session__voice files in \(folder.path)") }
    let rate = try AVAudioFile(forReading: first).processingFormat.sampleRate
    var hint = ""
    let started = Date()
    for take in LabSessionExport.unjudged(folder: folder).takes where take.kind != "beatbox" {
        let samples = WholeSong.read(take.sessionStartSeconds, take.sessionStartSeconds + take.durationSeconds, segments: segments, segmentSeconds: 300, channels: 1, rate: rate)[0]
        let lyrics = try await transcriber.transcribe(samples, sampleRate: rate, hint: hint)
        hint += " " + lyrics.text
        try LyricSheet.attach(lyrics, toTake: take.id, in: folder)
        print("\(take.id): \(Int(take.durationSeconds)) s, \(lyrics.words.count) words")
    }
    print(String(format: "retranscribed in %.0f s", Date().timeIntervalSince(started)))

case "transcribe":
    guard args.count >= 2 else { fail("usage: hotmic-bench transcribe <audio> [--hint \"…\"]") }
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: args[1]))
    guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
          let data = buf.floatChannelData else { fail("can't read \(args[1])") }
    try file.read(into: buf)
    let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(buf.frameLength)))
    let tuning = tuningOptions(args)
    let lyrics = try await WhisperTranscriber(model: option("--model", in: args) ?? WhisperTranscriber.defaultModel, tuning: tuning).transcribe(samples, sampleRate: file.processingFormat.sampleRate, hint: option("--hint", in: args))
    print("\(lyrics.words.count) words: \(lyrics.text)")

case "judge":
    guard args.count >= 2 else { fail("usage: hotmic-bench judge <session folder>") }
    let folder = URL(fileURLWithPath: args[1], isDirectory: true)
    let stored = await SessionJudge.pass(folder: folder, model: FoundationLineModel())
    print("\(stored.engine ?? "no model") · \(stored.stats.lines) lines · \(stored.stats.answered) answered · \(stored.stats.refused) refused · \(stored.stats.timedOut) timed out · \(stored.stats.failed) failed · \(Int(stored.stats.seconds)) s")

case "verdicts":
    guard args.count >= 3 else { fail("usage: hotmic-bench verdicts <session folder> <out.json> [--no-model] [--no-learner]") }
    let folder = URL(fileURLWithPath: args[1], isDirectory: true)
    let rows = SessionJudge.rows(folder: folder)
    let profile = LineJudgeProfile.read(LineJudgeProfile.url(forSession: folder))
    let decisions = LineJudge.decide(rows, stored: SessionJudgments.read(folder), learner: args.contains("--no-learner") ? nil : profile.learner,
                                     useModel: !args.contains("--no-model"), audio: LineAudioCache.read(folder))
    try writeJSON(rows.map { JudgeReplay.Row(id: $0.id, verdict: decisions[$0.id]?.verdict.rawValue ?? "writing", source: decisions[$0.id]?.source.rawValue ?? "rules") }, to: args[2])
    print("wrote \(args[2]) · \(rows.count) lines")

case "teach":
    guard args.count >= 3 else { fail("usage: hotmic-bench teach <line-judge.json> <folder>=<truth.jsonl> … [--budget <n per session>]") }
    let sessions = args.dropFirst(2).filter { $0.contains("=") }.map { pair -> (URL, URL) in
        let p = pair.split(separator: "=", maxSplits: 1).map(String.init)
        return (URL(fileURLWithPath: p[0], isDirectory: true), URL(fileURLWithPath: p[1]))
    }
    var profile = LineJudgeProfile()
    for s in try JudgeReplay.load(sessions) { JudgeReplay.teach(&profile.learner, from: s, budget: option("--budget", in: args).flatMap(Int.init) ?? 30) }
    profile.write(to: URL(fileURLWithPath: args[1]))
    print("taught \(profile.learner.corrections) corrections, \(profile.learner.weights.count) weights")

case "replay":
    let sessions = args.dropFirst().filter { $0.contains("=") }.map { pair -> (URL, URL) in
        let p = pair.split(separator: "=", maxSplits: 1).map(String.init)
        return (URL(fileURLWithPath: p[0], isDirectory: true), URL(fileURLWithPath: p[1]))
    }
    let report = try JudgeReplay.run(sessions: sessions, budget: option("--budget", in: args).flatMap(Int.init) ?? 30)
    try writeJSON(report, to: option("--out", in: args) ?? "/dev/stdout")

default:
    fail("unknown command \(command)")
}
