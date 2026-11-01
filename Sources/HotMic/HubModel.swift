import AppKit
import AVFoundation
import Enrichment
import Library

/// State behind the hub window: the whole library, read from disk off the main thread.
@MainActor
final class HubModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    enum Pane: Hashable { case session(String), imports, brain, phones }

    @Published var sessions: [SessionSummary] = []
    @Published var imports: [ImportedSong] = []
    @Published var phrases: [LyricIndex.Phrase] = []
    @Published var selection: Pane?
    @Published var query = ""
    @Published var busy: String?
    @Published var playing: String?
    /// The session waiting on "Move to Trash?" confirmation.
    @Published var confirmDelete: SessionSummary?
    /// The folder being recorded right now (can't be trashed mid-recording).
    var recordingFolder: () -> URL? = { nil }
    /// Bumped when a keeper pick changes, so the notebook redraws.
    @Published private var notebookRevision = 0

    private(set) var index: LibraryIndex
    private let transcriber: LyricTranscribing?
    private var documents: [LyricIndex.Document] = []
    private var player: AVAudioPlayer?
    /// Called with the preview's length so capture can ignore Hot Mic's own playback.
    var onPreview: (Double) -> Void = { _ in }

    private var generation = 0

    init(index: LibraryIndex, transcriber: LyricTranscribing?) {
        self.index = index
        self.transcriber = transcriber
    }

    func use(_ index: LibraryIndex) { self.index = index; reload() }

    func reload() {
        let index = self.index
        generation += 1
        let mine = generation
        Task.detached(priority: .userInitiated) {
            let sessions = index.sessions(), imports = index.imports(), docs = index.lyricDocuments()
            let phrases = LyricIndex(docs).repeatedPhrases(minSongs: 2)
            await MainActor.run {
                guard mine == self.generation else { return }   // a newer reload (e.g. new folder) wins
                self.sessions = sessions
                self.imports = imports
                self.documents = docs
                self.phrases = phrases
                if self.selection == nil { self.selection = sessions.first.map { .session($0.id) } ?? .imports }
            }
        }
    }

    /// Lines across the whole catalog containing the query.
    var searchResults: [(title: String, line: String)] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 2 else { return [] }
        return documents.flatMap { doc in
            doc.text.components(separatedBy: CharacterSet(charactersIn: "\n.!?"))
                .filter { $0.lowercased().contains(q) }
                .map { (doc.title, $0.trimmingCharacters(in: .whitespaces)) }
        }
    }

    func importAudio(_ urls: [URL]) {
        let importer = SongImporter(index: index, transcriber: transcriber)
        busy = "Importing \(urls.count) song\(urls.count == 1 ? "" : "s")…"
        Task {
            for url in urls { _ = try? await importer.importAudio(url) }
            busy = nil
            reload()
        }
    }

    func importLyrics(title: String, text: String) {
        _ = try? SongImporter(index: index, transcriber: nil).importLyrics(title: title, text: text)
        reload()
    }

    func play(_ url: URL, id: String) {
        if playing == id { player?.stop(); playing = nil; return }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.delegate = self
        onPreview((player?.duration ?? 0) + 0.5)
        player?.play()
        playing = id
    }

    /// Plays just one line of a take: from `start`, for `length` seconds.
    func play(_ url: URL, id: String, from start: Double, for length: Double) {
        if playing == id { player?.stop(); playing = nil; return }
        player?.stop()
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        self.player = player
        player.delegate = self
        player.currentTime = min(start, player.duration)
        onPreview(length + 0.5)
        player.play()
        playing = id
        let started = ObjectIdentifier(player)
        DispatchQueue.main.asyncAfter(deadline: .now() + length) { [weak self] in
            guard let self, let current = self.player, ObjectIdentifier(current) == started, current.isPlaying else { return }
            current.stop()
            self.playing = nil
        }
    }

    // MARK: - notebook

    func notebook(for session: SessionSummary) -> Notebook {
        _ = notebookRevision
        return Notebook(takes: session.takes, keepers: NotebookStore(folder: session.folder).keepers())
    }

    func pick(_ version: SungLine, in slot: LineSlot, session: SessionSummary) {
        try? NotebookStore(folder: session.folder).pick(version.id, in: slot)
        notebookRevision += 1
    }

    func copyDraft(_ book: Notebook) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(book.draft, forType: .string)
    }

    func saveDraft(_ book: Notebook, session: SessionSummary) {
        if let url = try? NotebookStore(folder: session.folder).writeDraft(book, title: session.name) { reveal(url) }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = ObjectIdentifier(player)
        Task { @MainActor in
            guard let current = self.player, ObjectIdentifier(current) == finished else { return }  // a newer preview is playing
            self.playing = nil
        }
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    /// Session → Trash (recoverable), then the list refreshes.
    func trash(_ session: SessionSummary?) {
        guard let session else { return }
        confirmDelete = nil
        guard recordingFolder()?.standardizedFileURL != session.folder.standardizedFileURL else { NSSound.beep(); return }
        if case .session(session.id)? = selection { selection = nil }
        player?.stop(); playing = nil
        do { try FileManager.default.trashItem(at: session.folder, resultingItemURL: nil) } catch {
            NSSound.beep()
            NSLog("Hot Mic: couldn't trash \(session.folder.path): \(error)")
        }
        reload()
    }
}
