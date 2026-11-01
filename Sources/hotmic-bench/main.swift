// hotmic-bench: runs a recording through Hot Mic headless, the way a dropped recording goes through the
// window (jam pipeline, Whisper lyrics), and writes what the window would show plus the stitched song.
// Usage:
//   hotmic-bench import <audio> <session folder> [--mix <audio>] [--no-lyrics] [--model <WhisperKit model>]
//   hotmic-bench export <session folder> <out.json>
//   hotmic-bench stitch <session folder> <out.m4a> [--voice] [--plan <out.json>]
//   hotmic-bench transcribe <audio> [--model <m>] [--hint "<earlier lyrics>"] [--no-prompt] [--no-vad] [--no-speech <0…1>]
//                                  (the app's Whisper on one file; the switches find what drops words)
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

case "transcribe":
    guard args.count >= 2 else { fail("usage: hotmic-bench transcribe <audio> [--hint \"…\"]") }
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: args[1]))
    guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
          let data = buf.floatChannelData else { fail("can't read \(args[1])") }
    try file.read(into: buf)
    let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(buf.frameLength)))
    var tuning = WhisperTranscriber.Tuning()
    if args.contains("--no-prompt") { tuning.prompt = false }
    if args.contains("--no-vad") { tuning.vadChunking = false }
    if let t = option("--no-speech", in: args).flatMap(Float.init) { tuning.noSpeechThreshold = t }
    if let l = option("--language", in: args) { tuning.language = l }
    tuning.debug = args.contains("--debug")
    if args.contains("--no-timestamps") { tuning.timestamps = false }
    if let t = option("--temperature", in: args).flatMap(Float.init) { tuning.temperature = t }
    let lyrics = try await WhisperTranscriber(model: option("--model", in: args) ?? WhisperTranscriber.defaultModel, tuning: tuning).transcribe(samples, sampleRate: file.processingFormat.sampleRate, hint: option("--hint", in: args))
    print("\(lyrics.words.count) words: \(lyrics.text)")

default:
    fail("unknown command \(command)")
}
