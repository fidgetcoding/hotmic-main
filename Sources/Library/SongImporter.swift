import AVFoundation
import Enrichment
import Foundation

/// Brings outside songs into the lyric memory: finished audio (any format AVFoundation reads —
/// WAV, AIFF, MP3, M4A, FLAC) is transcribed and key-detected; pasted lyrics go in as-is.
public struct SongImporter {
    public let index: LibraryIndex
    public let transcriber: LyricTranscribing?

    public init(index: LibraryIndex, transcriber: LyricTranscribing?) {
        self.index = index
        self.transcriber = transcriber
    }

    @discardableResult
    public func importLyrics(title: String, text: String) throws -> ImportedSong {
        let song = ImportedSong(title: title.isEmpty ? "Untitled" : title, lyrics: text.trimmingCharacters(in: .whitespacesAndNewlines))
        try index.save(song)
        return song
    }

    @discardableResult
    public func importAudio(_ url: URL) async throws -> ImportedSong {
        let (samples, rate) = try Self.readMono(url)
        let key = KeyDetector().detect(samples, sampleRate: rate)
        // A failed transcription still imports the song (key, title); lyrics can be pasted later.
        let lyrics = (try? await transcriber?.transcribe(samples, sampleRate: rate).text) ?? ""
        let song = ImportedSong(title: url.deletingPathExtension().lastPathComponent, lyrics: lyrics, key: key,
                                sourceFile: url.lastPathComponent)
        try index.save(song)
        return song
    }

    static func readMono(_ url: URL) throws -> ([Float], Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            return ([], format.sampleRate)
        }
        try file.read(into: buffer)
        let n = Int(buffer.frameLength), channels = Int(format.channelCount)
        guard let data = buffer.floatChannelData else { return ([], format.sampleRate) }
        var mono = [Float](repeating: 0, count: n)
        for c in 0..<channels { for i in 0..<n { mono[i] += data[c][i] / Float(channels) } }
        return (mono, format.sampleRate)
    }
}
