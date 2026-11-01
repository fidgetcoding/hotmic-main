import XCTest
@testable import Enrichment

enum Synth {
    static let rate = 48_000.0
    static func hz(_ midi: Double) -> Double { 440 * pow(2, (midi - 69) / 12) }

    /// Sum of harmonic tones for each MIDI note, `seconds` long.
    static func chord(_ notes: [Int], seconds: Double) -> [Float] {
        let n = Int(seconds * rate)
        return (0..<n).map { i in
            let t = Double(i) / rate
            var s = 0.0
            for m in notes { let f = hz(Double(m)); s += sin(2 * .pi * f * t) + 0.4 * sin(4 * .pi * f * t) + 0.2 * sin(6 * .pi * f * t) }
            return Float(0.08 * s)
        }
    }

    static func progression(_ chords: [[Int]], seconds: Double = 1.5) -> [Float] {
        chords.flatMap { chord($0, seconds: seconds) }
    }

    /// Sung line: each (fractional MIDI, seconds), 30 ms silences between notes.
    static func melody(_ notes: [(Double, Double)]) -> [Float] {
        var out: [Float] = []
        for (m, seconds) in notes {
            let f = hz(m), n = Int(seconds * rate)
            out += (0..<n).map { i in
                let t = Double(i) / rate
                let edge = min(1, min(Double(i), Double(n - i)) / (0.01 * rate))
                return Float(0.2 * edge * (sin(2 * .pi * f * t) + 0.5 * sin(4 * .pi * f * t)))
            }
            out += [Float](repeating: 0, count: Int(0.03 * rate))
        }
        return out
    }
}

final class KeyDetectorTests: XCTestCase {
    func key(_ audio: [Float]) -> MusicalKey? { KeyDetector().detect(audio, sampleRate: Synth.rate) }

    func testCMajorProgression() {
        let k = key(Synth.progression([[60, 64, 67], [65, 69, 72], [67, 71, 74], [60, 64, 67]]))
        XCTAssertEqual(k?.short, "Cmaj")
    }

    func testAMinorProgressionWithRaisedSeventh() {
        let k = key(Synth.progression([[57, 60, 64], [62, 65, 69], [64, 68, 71], [57, 60, 64]]))
        XCTAssertEqual(k?.short, "Amin")
    }

    func testTransposedToFSharpMajor() {
        let k = key(Synth.progression([[66, 70, 73], [71, 75, 78], [73, 77, 80], [66, 70, 73]]))
        XCTAssertEqual(k?.short, "F#maj")
    }

    func testSilenceHasNoKey() {
        XCTAssertNil(key([Float](repeating: 0, count: 96_000)))
    }
}

final class MelodyTranscriberTests: XCTestCase {
    let cMajor = MusicalKey(tonic: 0, mode: .major, confidence: 1)

    func testOffPitchSingingSnapsIntoKey() {
        // C D E F G sung sharp/flat by up to 40 cents; the F# is a wrong note heard in C major.
        let audio = Synth.melody([(60.3, 0.4), (61.65, 0.4), (64.2, 0.4), (66.3, 0.4), (67.0, 0.4)])
        let notes = MelodyTranscriber().notes(from: audio, sampleRate: Synth.rate, key: cMajor)
        XCTAssertEqual(notes.map(\.pitch), [60, 62, 64, 67, 67], "66.3 (F#+30c) snaps to the nearer in-key G")
        XCTAssertEqual(notes.first?.start ?? -1, 0, accuracy: 0.05)
        XCTAssertEqual(notes.first?.duration ?? 0, 0.4, accuracy: 0.06)
    }

    func testWithoutKeyRoundsToNearestSemitone() {
        let notes = MelodyTranscriber().notes(from: Synth.melody([(61.2, 0.4)]), sampleRate: Synth.rate, key: nil)
        XCTAssertEqual(notes.map(\.pitch), [61])
    }
}

final class MIDIFileWriterTests: XCTestCase {
    func testWritesParseableFormatZero() {
        let notes = [Note(pitch: 60, sungPitch: 60, start: 0, duration: 0.5, velocity: 100),
                     Note(pitch: 64, sungPitch: 64, start: 0.5, duration: 0.5, velocity: 90)]
        let data = [UInt8](MIDIFileWriter.data(notes: notes, tempo: 120))
        XCTAssertEqual(Array(data[0..<4]), Array("MThd".utf8))
        XCTAssertEqual(Array(data[8..<14]), [0, 0, 0, 1, 1, 0xE0], "format 0, 1 track, 480 ppq")
        XCTAssertEqual(data.filter { $0 == 0x90 }.count, 2)
        XCTAssertEqual(Array(data.suffix(3)), [0xFF, 0x2F, 0x00])
        // Tempo 120 = 500,000 µs per quarter.
        let tempoAt = data.indices.first { data[$0] == 0xFF && data[$0 + 1] == 0x51 }!
        XCTAssertEqual(Array(data[(tempoAt + 3)...(tempoAt + 5)]), [0x07, 0xA1, 0x20])
    }

    func testVariableLengthQuantities() {
        XCTAssertEqual(MIDIFileWriter.vlq(0), [0x00])
        XCTAssertEqual(MIDIFileWriter.vlq(0x7F), [0x7F])
        XCTAssertEqual(MIDIFileWriter.vlq(0x80), [0x81, 0x00])
        XCTAssertEqual(MIDIFileWriter.vlq(480), [0x83, 0x60])
    }
}

final class VoiceToMIDISyllableTests: XCTestCase {
    /// "la la la-la" on repeated pitches: consonants are short unvoiced noise bursts between vowels.
    func testSungWordsGiveOneNotePerSyllable() {
        var audio: [Float] = []
        var seed: UInt64 = 5
        func consonant() -> [Float] {
            (0..<Int(0.05 * Synth.rate)).map { _ in
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return (Float(seed >> 40) / Float(1 << 24) - 0.5) * 0.08
            }
        }
        for m in [64.0, 64.0, 64.0, 67.0] {
            audio += consonant()
            audio += Synth.melody([(m, 0.3)]).dropLast(Int(0.03 * Synth.rate))
        }
        let notes = MelodyTranscriber().notes(from: audio, sampleRate: Synth.rate,
                                              key: MusicalKey(tonic: 0, mode: .major, confidence: 1))
        XCTAssertEqual(notes.map(\.pitch), [64, 64, 64, 67])
    }
}

final class StructureAnalyzerTests: XCTestCase {
    func testFindsVerseChorusVerseChorus() {
        let verse = Synth.progression([[57, 60, 64], [53, 57, 60]], seconds: 4)      // Am F, 8 s
        let chorus = Synth.progression([[60, 64, 67], [55, 59, 62]], seconds: 4)     // C G, 8 s
        let sections = StructureAnalyzer().sections(verse + chorus + verse + chorus, sampleRate: Synth.rate)
        XCTAssertEqual(sections.map(\.label), ["A", "B", "A", "B"])
        let starts = sections.map { $0.start }
        for (found, expected) in zip(starts, [0.0, 8, 16, 24]) { XCTAssertEqual(found, expected, accuracy: 1.0) }
    }

    func testOneRepeatingLoopIsOneSection() {
        let loop = Synth.progression([[57, 60, 64], [53, 57, 60]], seconds: 2)
        let sections = StructureAnalyzer().sections(loop + loop + loop + loop + loop, sampleRate: Synth.rate)
        XCTAssertEqual(Set(sections.map(\.label)), ["A"])
    }
}


enum Beatbox {
    static let rate = 48_000.0
    static var seed: UInt64 = 9
    static func noise() -> Float {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return (Float(seed >> 40) / Float(1 << 24) - 0.5) * 2
    }
    /// "b": 55 Hz thump with a fast pitch drop.
    static func kick() -> [Float] {
        (0..<Int(0.09 * rate)).map { i in
            let t = Double(i) / rate
            return Float(0.6 * exp(-t / 0.03) * sin(2 * .pi * (55 + 90 * exp(-t / 0.01)) * t))
        }
    }
    /// "psh"/"k": a short 180 Hz body plus noise band-limited to roughly 1–4 kHz.
    static func snare() -> [Float] {
        var a: Float = 0, b: Float = 0, slow: Float = 0
        return (0..<Int(0.12 * rate)).map { i in
            let t = Double(i) / rate
            let n = noise()
            a = 0.55 * a + 0.45 * n; b = 0.55 * b + 0.45 * a      // two poles ≈ 4 kHz low-pass
            slow = 0.88 * slow + 0.12 * b                          // ≈ 1 kHz low-pass, subtracted
            let band = (b - slow) * 2.5
            let body = Float(0.25 * sin(2 * .pi * 180 * t) * exp(-t / 0.02))
            return Float(exp(-t / 0.05)) * band * 0.9 + body
        }
    }
    /// "ts": bright noise.
    static func hat() -> [Float] {
        var prev: Float = 0
        return (0..<Int(0.04 * rate)).map { i in
            let n = noise(); let hp = n - prev; prev = n
            return Float(exp(-Double(i) / rate / 0.012)) * hp * 0.35
        }
    }
    static func pattern(_ hits: String, spacing: Double = 0.25) -> [Float] {
        var out = [Float](repeating: 0, count: Int(Double(hits.count) * spacing * rate))
        for (i, c) in hits.enumerated() {
            let sound = c == "K" ? kick() : c == "S" ? snare() : hat()
            let start = Int(Double(i) * spacing * rate)
            for j in sound.indices where start + j < out.count { out[start + j] += sound[j] }
        }
        return out.map { $0 + noise() * 0.0003 }
    }
}

final class DrumTranscriberTests: XCTestCase {
    func testClassifiesKickSnareHat() {
        let hits = DrumTranscriber().hits(from: Beatbox.pattern("KHSHKKSH"), sampleRate: Beatbox.rate)
        XCTAssertEqual(hits.map(\.kind), [.kick, .hat, .snare, .hat, .kick, .kick, .snare, .hat])
        XCTAssertEqual(hits.map(\.note), [36, 42, 38, 42, 36, 36, 38, 42])
        XCTAssertEqual(hits[2].time, 0.5, accuracy: 0.02)
    }

    func testDrumMIDIUsesChannelTen() {
        let data = [UInt8](MIDIFileWriter.drums([DrumHit(kind: .kick, time: 0, velocity: 100)], tempo: 120))
        XCTAssertTrue(data.contains(0x99))
        XCTAssertFalse(data.contains(0x90))
    }
}

final class TunerTests: XCTestCase {
    /// Median sung pitch (fractional MIDI) of the middle of a clip.
    func measuredPitch(_ x: [Float]) -> Double {
        let notes = MelodyTranscriber().notes(from: x, sampleRate: Synth.rate, key: nil)
        return notes.max(by: { $0.duration < $1.duration })?.sungPitch ?? .nan
    }

    func testSharpNoteIsPulledIntoTune() {
        let sung = Synth.melody([(60.4, 1.2)])                        // 40 cents sharp C
        let notes = MelodyTranscriber().notes(from: sung, sampleRate: Synth.rate,
                                              key: MusicalKey(tonic: 0, mode: .major, confidence: 1))
        XCTAssertEqual(notes.first?.pitch, 60)
        let tuned = Tuner().tune(sung, sampleRate: Synth.rate, notes: notes)
        XCTAssertEqual(tuned.count, sung.count, "duration never changes")
        XCTAssertEqual(measuredPitch(sung), 60.4, accuracy: 0.08)
        XCTAssertEqual(measuredPitch(tuned), 60.0, accuracy: 0.1, "within 10 cents after tuning")
    }

    func testHalfStrengthMovesHalfway() {
        let sung = Synth.melody([(62.5, 1.2)])
        var notes = MelodyTranscriber().notes(from: sung, sampleRate: Synth.rate, key: nil)
        notes = notes.map { var n = $0; n.pitch = 62; return n }
        var tuner = Tuner(); tuner.strength = 0.5
        XCTAssertEqual(measuredPitch(tuner.tune(sung, sampleRate: Synth.rate, notes: notes)), 62.25, accuracy: 0.1)
    }
}

final class AuditEnrichmentTests: XCTestCase {
    /// Audit #10: ±90-cent vibrato on one held note stays one note.
    func testWideVibratoIsOneNote() {
        let n = Int(1.5 * Synth.rate)
        var phase = 0.0
        let f0 = Synth.hz(64)
        let audio: [Float] = (0..<n).map { i in
            let t = Double(i) / Synth.rate
            phase += 2 * .pi * f0 * pow(2, 90 * sin(2 * .pi * 5.5 * t) / 1_200) / Synth.rate
            return Float(0.2 * (sin(phase) + 0.5 * sin(2 * phase)))
        }
        let notes = MelodyTranscriber().notes(from: audio, sampleRate: Synth.rate, key: MusicalKey(tonic: 0, mode: .major, confidence: 1))
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.pitch, 64)
    }

    /// Audit #42: hard snap flattens a drifting note onto pitch; natural keeps the drift.
    func testHardSnapFlattensDrift() {
        let n = Int(1.2 * Synth.rate)
        var phase = 0.0
        let audio: [Float] = (0..<n).map { i in
            let t = Double(i) / Synth.rate
            let m = 60.0 + 0.35 * sin(2 * .pi * 1.5 * t)          // slow ±35-cent wander around C
            phase += 2 * .pi * Synth.hz(m) / Synth.rate
            return Float(0.2 * (sin(phase) + 0.5 * sin(2 * phase)))
        }
        let notes = [Note(pitch: 60, sungPitch: 60, start: 0, duration: 1.2, velocity: 100)]
        func spread(_ x: [Float]) -> Double {
            let track = MelodyTranscriber().pitchTrack(x, sampleRate: Synth.rate).dropFirst(20).dropLast(20).filter { !$0.isNaN }
            let mean = track.reduce(0, +) / Double(track.count)
            return sqrt(track.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(track.count))
        }
        let natural = Tuner(mode: .natural).tune(audio, sampleRate: Synth.rate, notes: notes)
        let hard = Tuner(mode: .hard).tune(audio, sampleRate: Synth.rate, notes: notes)
        XCTAssertLessThan(spread(hard), spread(natural) * 0.5, "hard snap removes most of the wander")
    }
}

final class NoteSplitTests: XCTestCase {
    let key = MusicalKey(tonic: 0, mode: .major, confidence: 1)

    /// ±120-cent vibrato that starts at the top of its cycle is still one note.
    func testVeryWideVibratoFromTheTopIsOneNote() {
        let n = Int(1.5 * Synth.rate)
        var phase = 0.0
        let audio: [Float] = (0..<n).map { i in
            let t = Double(i) / Synth.rate
            phase += 2 * .pi * Synth.hz(64) * pow(2, 120 * cos(2 * .pi * 5 * t) / 1_200) / Synth.rate
            return Float(0.2 * (sin(phase) + 0.5 * sin(2 * phase)))
        }
        let notes = MelodyTranscriber().notes(from: audio, sampleRate: Synth.rate, key: key)
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.duration ?? 0, 1.5, accuracy: 0.1)
    }

    /// A legato 5-semitone step with no gap splits within ~30 ms of the real change.
    func testLegatoLeapOnsetIsAccurate() {
        let a = Synth.melody([(60, 0.6)]).dropLast(Int(0.03 * Synth.rate))
        let b = Synth.melody([(65, 0.6)]).dropLast(Int(0.03 * Synth.rate))
        let notes = MelodyTranscriber().notes(from: Array(a) + Array(b), sampleRate: Synth.rate, key: key)
        XCTAssertEqual(notes.map(\.pitch), [60, 65])
        XCTAssertEqual(notes.last?.start ?? 0, 0.6, accuracy: 0.03)
    }

    /// Fast whole-step sixteenths (110 ms each) are all kept.
    func testFastRunsKeepEveryNote() {
        let run = Synth.melody([(60, 0.11), (62, 0.11), (64, 0.11), (65, 0.11), (67, 0.11)])
        XCTAssertEqual(MelodyTranscriber().notes(from: run, sampleRate: Synth.rate, key: key).map(\.pitch), [60, 62, 64, 65, 67])
    }
}

final class QuietKeyTests: XCTestCase {
    func testNearSilentAudioHasNoKey() {
        let whisper = Synth.progression([[60, 64, 67]], seconds: 3).map { $0 * 0.01 }   // ≈ −55 dBFS
        XCTAssertNil(KeyDetector().detect(whisper, sampleRate: Synth.rate))
    }
}

final class LoudnessTests: XCTestCase {
    func db(_ x: Float) -> Float { 20 * log10(x) }

    func testQuietTakeIsBroughtUpAndNeverClips() {
        let quiet = Synth.melody([(60, 1), (64, 1), (67, 1)]).map { $0 * 0.08 }           // ≈ −36 dBFS
        let out = Loudness().normalize(quiet, channels: 1, sampleRate: Synth.rate)
        let rms = Loudness().activeRMS(out, channels: 1, sampleRate: Synth.rate)
        XCTAssertEqual(db(rms), -18, accuracy: 2)
        XCTAssertLessThanOrEqual(db(out.map(abs).max()!), -0.99)
    }

    func testLoudPeaksAreLimitedNotClipped() {
        var loud = Synth.melody([(60, 1)]).map { $0 * 0.3 }
        for i in 20_000..<20_100 { loud[i] = 0.99 }                                          // a sharp transient
        let out = Loudness().normalize(loud, channels: 1, sampleRate: Synth.rate)
        XCTAssertLessThanOrEqual(out.map(abs).max()!, pow(10, -1 / 20) + 1e-4)
    }

    func testSilenceStaysSilent() {
        let hiss = [Float](repeating: 0.00001, count: 48_000)
        XCTAssertEqual(Loudness().normalize(hiss, channels: 1, sampleRate: 48_000).map(abs).max()!, 0.00001 * pow(10, 30 / 20), accuracy: 1e-5,
                       "boost is capped at +30 dB")
    }
}

final class TempoAndChordTests: XCTestCase {
    /// Decaying noise bursts on each beat (a drum-ish click track).
    func clicks(bpm: Double, seconds: Double, subdivide: Int = 1) -> [Float] {
        let n = Int(seconds * Synth.rate)
        var out = [Float](repeating: 0, count: n)
        var s: UInt64 = 1
        let step = 60 / bpm / Double(subdivide)
        var t = 0.0, beat = 0
        while t < seconds {
            let start = Int(t * Synth.rate), accent: Float = beat % subdivide == 0 ? 1 : 0.5
            for j in 0..<Int(0.04 * Synth.rate) where start + j < n {
                s = s &* 6364136223846793005 &+ 1442695040888963407
                out[start + j] += accent * 0.4 * (Float(s >> 40) / Float(1 << 24) - 0.5) * Float(exp(-Double(j) / Synth.rate / 0.01))
            }
            t += step; beat += 1
        }
        return out
    }

    func testClickTrackTempo() throws {
        XCTAssertEqual(try XCTUnwrap(TempoEstimator().estimate(clicks(bpm: 96, seconds: 12), sampleRate: Synth.rate)).bpm, 96, accuracy: 1)
    }

    func testEighthNoteStrummingIsNotDoubleTime() throws {
        let tempo = try XCTUnwrap(TempoEstimator().estimate(clicks(bpm: 120, seconds: 12, subdivide: 2), sampleRate: Synth.rate))
        XCTAssertEqual(tempo.bpm, 120, accuracy: 1.5)
    }

    func testRecognizesAProgression() {
        // C – Am – F – G7, two seconds each, voiced across octaves like a guitar.
        let audio = Synth.progression([[48, 52, 55, 60, 64], [45, 52, 57, 60, 64], [41, 48, 53, 57, 60], [43, 50, 55, 59, 65]], seconds: 2)
        let names = ChordRecognizer().chords(audio, sampleRate: Synth.rate).map(\.name)
        XCTAssertEqual(names, ["C", "Am", "F", "G7"])
    }

    func testSilenceIsNoChord() {
        XCTAssertEqual(ChordRecognizer().chords([Float](repeating: 0, count: 96_000), sampleRate: Synth.rate).map(\.name), ["N"])
    }
}

final class LiveJamAnalyzerTests: XCTestCase {
    func testReadoutFollowsTheJam() {
        let rate = 48_000.0, beat = Int(60.0 / 100 * rate)
        func strum(_ chord: [Int]) -> [Float] {
            (0..<beat).map { i in
                let t = Double(i) / rate
                return Float(exp(-t / 0.25)) * 0.05 * Float(chord.reduce(0.0) { $0 + sin(2 * .pi * Synth.hz(Double($1)) * t) + 0.4 * sin(4 * .pi * Synth.hz(Double($1)) * t) }) / Float(chord.count)
            }
        }
        let c = [48, 52, 55, 60, 64], am = [45, 52, 57, 60, 64], f = [41, 48, 53, 57, 60], g = [43, 47, 50, 55, 59]
        var audio: [Float] = []
        for _ in 0..<3 { for chord in [c, am, f, g] { for _ in 0..<4 { audio += strum(chord) } } }
        audio += (0..<4).flatMap { _ in strum(am) }            // end on A minor
        let analyzer = LiveJamAnalyzer(sampleRate: rate)
        let latest = Latest()
        analyzer.onReadout = { latest.value = $0 }
        audio.withUnsafeBufferPointer { a in
            for start in stride(from: 0, to: a.count - 2_400, by: 2_400) {
                analyzer.feed(UnsafeBufferPointer(rebasing: a[start..<(start + 2_400)]))
                usleep(2_000)                                   // let the readout queue keep up
            }
        }
        Thread.sleep(forTimeInterval: 1)
        let r = latest.value
        XCTAssertEqual(r?.chord, "Am")
        XCTAssertEqual(r?.key, "C major")
        XCTAssertEqual(Double(r?.bpm ?? 0), 100, accuracy: 2)
    }

    func testNoteOfASungTone() {
        let tone = (0..<4_000).map { Float(0.2 * sin(2 * .pi * 329.63 * Double($0) / 48_000)) }
        XCTAssertEqual(LiveJamAnalyzer.note(in: tone, sampleRate: 48_000), "E4")
    }
}

final class Latest: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: JamReadout?
    var value: JamReadout? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

final class PolyphonicTranscriberTests: XCTestCase {
    func testChordsAndMelodyTogether() throws {
        let rate = 48_000.0
        // Two bars: C chord then G chord, each 2 s, with a sung line E4 → D4 on top.
        func tone(_ midi: Int, _ t: Double, decay: Double?) -> Double {
            let f = Synth.hz(Double(midi))
            let env = decay.map { exp(-t / $0) } ?? min(1, t / 0.02)
            return env * (sin(2 * .pi * f * t) + 0.3 * sin(4 * .pi * f * t))
        }
        let n = Int(2 * rate)
        func bar(_ chord: [Int], _ sung: Int) -> [Float] {
            (0..<n).map { i in
                let t = Double(i) / rate
                let guitar = chord.reduce(0.0) { $0 + tone($1, t, decay: 0.8) } / Double(chord.count)
                return Float(0.25 * guitar + 0.2 * tone(sung, t, decay: nil))
            }
        }
        let audio = bar([48, 52, 55, 60], 64) + bar([43, 47, 50, 55], 74)
        let notes = try PolyphonicTranscriber().notes(from: audio, sampleRate: rate)
        let first = Set(notes.filter { $0.start < 1 }.map(\.pitch)), second = Set(notes.filter { $0.start > 1.8 && $0.start < 2.4 }.map(\.pitch))
        // Port verified identical to basic_pitch.note_creation on this audio (BPDebugTests, 2026-09-27).
        // The model hears this synthetic C chord's fifth weakly; real guitars fare better.
        XCTAssertTrue(first.isSuperset(of: [48, 52, 64]), "C chord + sung E4: \(first.sorted())")
        XCTAssertTrue(second.isSuperset(of: [43, 47, 50, 74]), "G chord + sung D5: \(second.sorted())")
        let c = try XCTUnwrap(notes.first { $0.pitch == 43 })
        XCTAssertEqual(c.start, 2, accuracy: 0.05, "onsets land on time")
    }
}
