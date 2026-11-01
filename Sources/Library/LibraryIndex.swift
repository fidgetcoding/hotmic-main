import Enrichment
import Foundation

/// One recording session folder as the hub shows it.
public struct SessionSummary: Identifiable, Equatable, Sendable {
    public var id: String { folder.path }
    public var folder: URL
    public var name: String
    public var date: Date
    public var daw: String
    public var takes: [TakeRecord]
}

/// A song brought in from outside (finished audio or pasted lyrics) — joins the lyric memory.
public struct ImportedSong: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var addedAt: Date
    public var lyrics: String
    public var key: MusicalKey?
    public var sourceFile: String?

    public init(id: String = UUID().uuidString, title: String, addedAt: Date = Date(), lyrics: String,
                key: MusicalKey? = nil, sourceFile: String? = nil) {
        self.id = id; self.title = title; self.addedAt = addedAt; self.lyrics = lyrics; self.key = key; self.sourceFile = sourceFile
    }
}

/// Reads the whole library from disk: sessions (newest first) and imports.
public struct LibraryIndex {
    public let location: LibraryLocation
    public init(location: LibraryLocation) { self.location = location }

    public var importsFolder: URL { location.root.appendingPathComponent("Imports", isDirectory: true) }

    public func sessions() -> [SessionSummary] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: location.sessions, includingPropertiesForKeys: [.creationDateKey]) else { return [] }
        return folders.compactMap { folder -> SessionSummary? in
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            let takes = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "json" }
                .compactMap { try? LyricSheet.decoder.decode(TakeRecord.self, from: Data(contentsOf: $0)) }
                .sorted { $0.sessionStartSeconds < $1.sessionStartSeconds }
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return SessionSummary(folder: folder, name: folder.lastPathComponent, date: takes.first?.createdAt ?? created,
                                  daw: takes.first?.daw ?? "", takes: takes)
        }
        .sorted { $0.date > $1.date }
    }

    public func imports() -> [ImportedSong] {
        let files = (try? FileManager.default.contentsOfDirectory(at: importsFolder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? LyricSheet.decoder.decode(ImportedSong.self, from: Data(contentsOf: $0)) }
            .sorted { $0.addedAt > $1.addedAt }
    }

    public func save(_ song: ImportedSong) throws {
        try FileManager.default.createDirectory(at: importsFolder, withIntermediateDirectories: true)
        try LyricSheet.encoder.encode(song).write(to: importsFolder.appendingPathComponent("\(song.id).json"), options: .atomic)
    }

    /// Everything with words, for the lyric brain.
    public func lyricDocuments() -> [LyricIndex.Document] {
        var docs: [LyricIndex.Document] = []
        for session in sessions() {
            for take in session.takes where !(take.lyrics?.text.isEmpty ?? true) {
                docs.append(.init(id: take.id, title: "\(session.name) · \(take.id)", text: take.lyrics!.text))
            }
        }
        for song in imports() where !song.lyrics.isEmpty {
            docs.append(.init(id: song.id, title: song.title, text: song.lyrics))
        }
        return docs
    }
}
