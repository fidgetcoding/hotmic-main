import AVFoundation
import CoreML
import Foundation

/// Every note in a recording, chords included: guitar, piano and voice together → MIDI.
/// Spotify's Basic Pitch model (ICASSP 2022, Apache-2.0) on Core ML, with its note extraction
/// ported from basic_pitch/note_creation.py (onset peaks, then the "melodia" sweep for held notes).
public final class PolyphonicTranscriber: @unchecked Sendable {
    public struct Settings: Sendable {
        public var onsetThreshold: Float = 0.5
        public var frameThreshold: Float = 0.3
        public var minNoteFrames = 11            // 127.7 ms at 86 frames/s
        public var energyTolerance = 11
        public var lowestMIDI = 36               // C2: below any voice or guitar string worth writing down
        public init() {}
    }

    static let rate = 22_050.0
    static let windowSamples = 43_844            // 2 s − one hop
    static let hop = 256
    static let framesPerWindow = 172
    static let overlapFrames = 30
    static let pitches = 88                      // A0…C8
    static let midiOffset = 21

    public var settings = Settings()
    /// Loaded once, on first use; nil if the model is missing from the build.
    public static let shared: PolyphonicTranscriber? = try? PolyphonicTranscriber()
    private let model: MLModel
    private let lock = NSLock()                  // MLModel.prediction isn't documented as reentrant

    public init() throws {
        guard let url = Self.modelURL() else { throw CocoaError(.fileNoSuchFile) }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        model = try MLModel(contentsOf: url, configuration: config)
    }

    /// The compiled model, from the app's Resources or the SwiftPM bundle (tests, `swift run`).
    static func modelURL() -> URL? {
        let name = "HotMic_Enrichment.bundle"
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent(name), Bundle.main.bundleURL.appendingPathComponent(name)]
        for case let url? in candidates {
            if let model = Bundle(url: url)?.url(forResource: "nmp", withExtension: "mlmodelc") { return model }
        }
        return Bundle.module.url(forResource: "nmp", withExtension: "mlmodelc")
    }

    /// Notes with times in seconds from the start of `samples`.
    public func notes(from samples: [Float], sampleRate: Double) throws -> [Note] {
        let audio = Self.resample(samples, from: sampleRate)
        guard !audio.isEmpty else { return [] }
        let (frames, onsets) = try activations(audio)
        return Self.extract(frames: frames, onsets: onsets, settings: settings).map { e in
            Note(pitch: e.pitch, sungPitch: Double(e.pitch), start: Self.time(ofFrame: e.start),
                 duration: Self.time(ofFrame: e.end) - Self.time(ofFrame: e.start),
                 velocity: max(1, min(127, Int((127 * e.amplitude).rounded()))))
        }
    }

    // MARK: - model

    /// (note activations, onset activations), each [frame][pitch], windows stitched together.
    func activations(_ audio: [Float]) throws -> ([[Float]], [[Float]]) {
        let overlapSamples = Self.overlapFrames * Self.hop
        let step = Self.windowSamples - overlapSamples
        let padded = [Float](repeating: 0, count: overlapSamples / 2) + audio
        var frames: [[Float]] = [], onsets: [[Float]] = []
        let trim = Self.overlapFrames / 2
        let input = try MLMultiArray(shape: [1, NSNumber(value: Self.windowSamples), 1], dataType: .float32)
        var start = 0
        while start < padded.count {
            let ptr = input.dataPointer.bindMemory(to: Float.self, capacity: Self.windowSamples)
            for i in 0..<Self.windowSamples { ptr[i] = start + i < padded.count ? padded[start + i] : 0 }
            let output = try lock.withLock {
                try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input_2": input]))
            }
            guard let note = output.featureValue(for: "Identity_1")?.multiArrayValue,
                  let onset = output.featureValue(for: "Identity_2")?.multiArrayValue else { throw CocoaError(.coderInvalidValue) }
            frames += Self.rows(note, from: trim, to: Self.framesPerWindow - trim)
            onsets += Self.rows(onset, from: trim, to: Self.framesPerWindow - trim)
            start += step
        }
        let expected = Int(Double(audio.count) / Double(step) * Double(Self.framesPerWindow - Self.overlapFrames))
        return (Array(frames.prefix(expected)), Array(onsets.prefix(expected)))
    }

    static func rows(_ array: MLMultiArray, from: Int, to: Int) -> [[Float]] {
        let strides = array.strides.map(\.intValue)
        let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
        return (from..<to).map { t in (0..<pitches).map { p in ptr[t * strides[1] + p * strides[2]] } }
    }

    /// Frame index → seconds, including the model's per-window alignment correction.
    static func time(ofFrame n: Int) -> Double {
        let windowOffset = Double(hop) / rate * (Double(framesPerWindow) - Double(windowSamples) / Double(hop)) + 0.0018
        return Double(n) * Double(hop) / rate - windowOffset * Double(n / framesPerWindow)
    }

    static func resample(_ x: [Float], from sampleRate: Double) -> [Float] {
        guard !x.isEmpty else { return [] }
        if sampleRate == rate { return x }
        guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(x.count)),
              let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(Double(x.count) * rate / sampleRate) + 1_024)
        else { return [] }
        converter.sampleRateConverterQuality = .max
        input.frameLength = AVAudioFrameCount(x.count)
        x.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: x.count) }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    // MARK: - note extraction (basic_pitch.note_creation.output_to_notes_polyphonic)

    struct Event: Equatable { var start: Int; var end: Int; var pitch: Int; var amplitude: Float }

    static func extract(frames: [[Float]], onsets rawOnsets: [[Float]], settings: Settings) -> [Event] {
        let n = frames.count
        guard n > 2 else { return [] }
        let low = max(0, settings.lowestMIDI - midiOffset)
        var frames = frames
        var onsets = rawOnsets
        for t in 0..<n { for p in 0..<low { frames[t][p] = 0; onsets[t][p] = 0 } }
        onsets = inferredOnsets(onsets, frames: frames)

        // Local maxima in time at each pitch, strongest-late first (the reference walks backwards).
        var peaks: [(t: Int, p: Int)] = []
        for t in 1..<(n - 1) {
            for p in 0..<pitches where onsets[t][p] >= settings.onsetThreshold
                && onsets[t][p] > onsets[t - 1][p] && onsets[t][p] > onsets[t + 1][p] {
                peaks.append((t, p))
            }
        }
        peaks.reverse()

        var remaining = frames
        var events: [Event] = []
        func clear(_ t: Int, _ p: Int) {
            remaining[t][p] = 0
            if p < pitches - 1 { remaining[t][p + 1] = 0 }
            if p > 0 { remaining[t][p - 1] = 0 }
        }
        func mean(_ a: Int, _ b: Int, _ p: Int) -> Float {
            b > a ? (a..<b).reduce(0) { $0 + frames[$1][p] } / Float(b - a) : 0
        }
        for (start, p) in peaks where start < n - 1 {
            var i = start + 1, k = 0
            while i < n - 1, k < settings.energyTolerance {
                k = remaining[i][p] < settings.frameThreshold ? k + 1 : 0
                i += 1
            }
            i -= k
            guard i - start > settings.minNoteFrames else { continue }
            for t in start..<i { clear(t, p) }
            events.append(Event(start: start, end: i, pitch: p + midiOffset, amplitude: mean(start, i, p)))
        }

        // Melodia trick: sustained notes whose onset the model missed.
        while true {
            var best: Float = settings.frameThreshold, mid = -1, p = -1
            for t in 0..<n { for q in 0..<pitches where remaining[t][q] > best { best = remaining[t][q]; mid = t; p = q } }
            guard mid >= 0 else { break }
            remaining[mid][p] = 0
            var i = mid + 1, k = 0
            while i < n - 1, k < settings.energyTolerance {
                k = remaining[i][p] < settings.frameThreshold ? k + 1 : 0
                clear(i, p)
                i += 1
            }
            let end = i - 1 - k
            i = mid - 1; k = 0
            while i > 0, k < settings.energyTolerance {
                k = remaining[i][p] < settings.frameThreshold ? k + 1 : 0
                clear(i, p)
                i -= 1
            }
            let start = i + 1 + k
            guard end - start > settings.minNoteFrames else { continue }
            events.append(Event(start: start, end: end, pitch: p + midiOffset, amplitude: mean(start, end, p)))
        }
        return events.sorted { ($0.start, $0.pitch) < ($1.start, $1.pitch) }
    }

    /// Extra onsets where a pitch's activation jumps (max of 1- and 2-frame rises), scaled to the model's onsets.
    static func inferredOnsets(_ onsets: [[Float]], frames: [[Float]]) -> [[Float]] {
        let n = frames.count
        var diff = [[Float]](repeating: [Float](repeating: 0, count: pitches), count: n)
        var maxDiff: Float = 0, maxOnset: Float = 0
        for t in 0..<n {
            for p in 0..<pitches {
                maxOnset = max(maxOnset, onsets[t][p])
                guard t >= 2 else { continue }
                let d = max(0, min(frames[t][p] - frames[t - 1][p], frames[t][p] - frames[t - 2][p]))
                diff[t][p] = d
                maxDiff = max(maxDiff, d)
            }
        }
        guard maxDiff > 0 else { return onsets }
        var out = onsets
        for t in 0..<n { for p in 0..<pitches { out[t][p] = max(onsets[t][p], maxOnset * diff[t][p] / maxDiff) } }
        return out
    }
}
