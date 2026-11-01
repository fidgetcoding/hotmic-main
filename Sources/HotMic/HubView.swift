import AppKit
import Enrichment
import Library
import SwiftUI
import UniformTypeIdentifiers

/// The songwriting hub: works with or without a DAW open.
struct HubView: View {
    @ObservedObject var model: HubModel
    @ObservedObject var phones: PhonesModel
    @State private var pastingLyrics = false

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Section("Live") {
                    HStack {
                        Label("Phones", systemImage: "iphone.gen3.radiowaves.left.and.right")
                        Spacer()
                        if !phones.snapshot.requests.isEmpty {
                            Text("\(phones.snapshot.requests.count) waiting").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                        } else if phones.recording, !phones.snapshot.singers.isEmpty {
                            Text("\(phones.snapshot.singers.count)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(HubModel.Pane.phones)
                }
                Section("Sessions") {
                    ForEach(model.sessions) { session in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.name).lineLimit(1)
                            Text("\(session.takes.count) take\(session.takes.count == 1 ? "" : "s")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(HubModel.Pane.session(session.id))
                        .contextMenu {
                            Button("Show in Finder") { model.reveal(session.folder) }
                            Divider()
                            Button("Move to Trash…", role: .destructive) { model.confirmDelete = session }
                                .disabled(model.recordingFolder()?.standardizedFileURL == session.folder.standardizedFileURL)
                        }
                    }
                }
                Section("Songbook") {
                    Label("Imported songs", systemImage: "music.note.list").tag(HubModel.Pane.imports)
                    Label("Lyric brain", systemImage: "brain").tag(HubModel.Pane.brain)
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .onDeleteCommand {
                if case let .session(id)? = model.selection { model.confirmDelete = model.sessions.first { $0.id == id } }
            }
            .confirmationDialog("Move “\(model.confirmDelete?.name ?? "")” to the Trash?",
                                isPresented: Binding(get: { model.confirmDelete != nil },
                                                     set: { if !$0 { model.confirmDelete = nil } })) {
                Button("Move to Trash", role: .destructive) { model.trash(model.confirmDelete) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(model.confirmDelete?.takes.count ?? 0) takes and the full session recording. You can put it back from the Trash.")
            }
        } detail: {
            switch model.selection {
            case let .session(id)?:
                if let session = model.sessions.first(where: { $0.id == id }) { SessionDetail(model: model, session: session) }
            case .imports?: ImportsDetail(model: model)
            case .phones?: PhonesView(phones: phones)
            case .brain?: BrainDetail(model: model)
            case nil: Text("Sing something while your DAW is open, or press Jam in the menu bar.").foregroundStyle(.secondary)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if let busy = model.busy { ProgressView().controlSize(.small); Text(busy).foregroundStyle(.secondary) }
                Button { chooseSongs() } label: { Label("Import song", systemImage: "square.and.arrow.down") }
                Button { pastingLyrics = true } label: { Label("Paste lyrics", systemImage: "text.badge.plus") }
                Button { model.reload() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
        }
        .sheet(isPresented: $pastingLyrics) { PasteLyricsSheet(model: model) }
        .onAppear { model.reload() }
        .frame(minWidth: 820, minHeight: 520)
    }

    private func chooseSongs() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        if panel.runModal() == .OK { model.importAudio(panel.urls) }
    }
}

private struct SessionDetail: View {
    @ObservedObject var model: HubModel
    let session: SessionSummary
    @State private var showNotebook = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $showNotebook) {
                Text("Takes").tag(false)
                Text("Notebook").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            .padding(.vertical, 8)
            if showNotebook {
                NotebookView(model: model, session: session)
            } else {
                takes
            }
        }
    }

    private var takes: some View {
        List {
            Section {
                ForEach(session.takes, id: \.id) { take in TakeRow(model: model, session: session, take: take) }
            } header: {
                HStack {
                    Text(session.name).font(.title3.weight(.semibold))
                    Spacer()
                    if FileManager.default.fileExists(atPath: session.folder.appendingPathComponent(LyricSheet.fileName).path) {
                        Button("Lyric sheet") { NSWorkspace.shared.open(session.folder.appendingPathComponent(LyricSheet.fileName)) }
                    }
                    Button("Show in Finder") { model.reveal(session.folder) }
                }
                .textCase(nil)
            }
        }
    }
}

/// Every line of the song once, with every version you've sung of it stacked underneath.
private struct NotebookView: View {
    @ObservedObject var model: HubModel
    let session: SessionSummary

    var body: some View {
        let book = model.notebook(for: session)
        List {
            if book.slots.isEmpty {
                Text("Sing a few passes. Every version of every line lines up here, so you can pick your favorites.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(book.slots.enumerated()), id: \.element.id) { n, slot in
                Section {
                    ForEach(slot.versions.reversed()) { version in
                        VersionRow(model: model, session: session, slot: slot, version: version)
                    }
                } header: {
                    Text("Line \(n + 1)\(slot.versions.count > 1 ? " · \(slot.versions.count) versions" : "")").textCase(nil)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { model.copyDraft(book) } label: { Label("Copy draft", systemImage: "doc.on.doc") }
                    .disabled(book.slots.isEmpty)
                Button { model.saveDraft(book, session: session) } label: { Label("Save draft", systemImage: "square.and.arrow.down.on.square") }
                    .disabled(book.slots.isEmpty)
            }
        }
    }
}

private struct VersionRow: View {
    @ObservedObject var model: HubModel
    let session: SessionSummary
    let slot: LineSlot
    let version: SungLine

    var isChosen: Bool { slot.chosen.id == version.id }
    var take: TakeRecord? { session.takes.first { $0.id == version.takeID } }

    var body: some View {
        HStack(spacing: 10) {
            Button { play() } label: {
                Image(systemName: model.playing == version.id ? "stop.fill" : "play.fill").frame(width: 20)
            }
            .buttonStyle(.plain)
            .disabled(take?.files["mix"] == nil)
            VStack(alignment: .leading, spacing: 2) {
                line.font(isChosen ? .body.weight(.semibold) : .body)
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let take, take.midiNotes != nil, let index = Int(version.id.split(separator: "#").last ?? "") {
                Image(systemName: "pianokeys")
                    .foregroundStyle(.secondary)
                    .help("Drag this line's MIDI into your DAW")
                    .onDrag {
                        MIDISlices.writeLine(index, of: take, in: session.folder).flatMap(NSItemProvider.init(contentsOf:))
                            ?? NSItemProvider()
                    }
            }
            if slot.versions.count > 1 {
                Button { model.pick(version, in: slot, session: session) } label: {
                    Image(systemName: slot.keeperID == version.id ? "star.fill" : "star")
                        .foregroundStyle(slot.keeperID == version.id ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(slot.keeperID == version.id ? "Your pick for this line (click to un-pick)" : "Keep this version")
            }
        }
        .padding(.vertical, 2)
    }

    /// Words that differ from the version in the draft are highlighted.
    var line: Text {
        guard !isChosen else { return Text(version.text) }
        return Notebook.diff(version.text, against: slot.chosen.text).reduce(Text("")) { text, token in
            text + Text(token.word + " ").foregroundColor(token.changed ? .orange : .primary)
        }
    }

    var caption: String {
        var parts: [String] = []
        if let bar = version.bar { parts.append("Bar \(Int(bar))") }
        parts.append(TakeRow.clock.string(from: version.createdAt))
        if slot.keeperID == nil, isChosen, slot.versions.count > 1 { parts.append("newest") }
        return parts.joined(separator: " · ")
    }

    func play() {
        guard let mix = take?.files["mix"] else { return }
        model.play(session.folder.appendingPathComponent(mix), id: version.id, from: max(0, version.start - 0.3),
                   for: version.end - version.start + 0.8)
    }
}

private struct TakeRow: View {
    @ObservedObject var model: HubModel
    let session: SessionSummary
    let take: TakeRecord

    var voiceURL: URL { session.folder.appendingPathComponent(take.files["voice"] ?? "") }
    var mixURL: URL { session.folder.appendingPathComponent(take.files["mix"] ?? "") }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button { model.play(mixURL, id: take.id) } label: {
                Image(systemName: model.playing == take.id ? "stop.fill" : "play.fill").frame(width: 20)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 4) {
                Text(badges.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                if let lyrics = take.lyrics?.text, !lyrics.isEmpty { Text(lyrics) } else if take.kind == "beatbox" {
                    Text("Beatbox → drum MIDI").italic()
                } else if take.kind == "whisper" {
                    Text("Whispered (words still transcribing, or too faint)").italic().foregroundStyle(.secondary)
                } else if take.kind == "playing" {
                    Text("Instrumental").italic().foregroundStyle(.secondary)
                } else {
                    Text("No words (hum or melody)").italic().foregroundStyle(.secondary)
                }
                if let chart = Self.chart(take.chords) {
                    Text(chart).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                }
                ForEach(take.echoes ?? [], id: \.line) { echo in
                    Label("“\(echo.line)” is already in \(echo.from)", systemImage: "arrow.uturn.backward")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            Text("\(Int(take.durationSeconds.rounded())) s").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .onDrag { NSItemProvider(contentsOf: voiceURL) ?? NSItemProvider() }
        .contextMenu {
            Button("Show in Finder") { model.reveal(voiceURL) }
            if let midi = take.files["midi"] ?? take.files["drums"] {
                Button("Show MIDI in Finder") { model.reveal(session.folder.appendingPathComponent(midi)) }
            }
            if take.midiNotes != nil {
                Button("MIDI by line & 4 bars…") {
                    if let folder = try? MIDISlices.write(take, in: session.folder) { NSWorkspace.shared.open(folder) }
                }
            }
        }
    }

    var badges: [String] {
        var b: [String] = []
        if let p = take.position, p.playing { b.append("Bar \(p.bar)"); b.append("\(Int(p.tempo.rounded())) BPM") }
        else if let t = take.tempo, t.confidence > 0.2 { b.append("\(Int(t.bpm.rounded())) BPM") }
        if let s = take.section { b.append("Section \(s)") }
        if let k = take.key { b.append(k.description) }
        if take.kind == "whisper" { b.append("Whisper") }
        if let singer = take.singer { b.append("Sung by \(singer)") }
        b.append(Self.clock.string(from: take.createdAt))
        return b
    }

    static let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM d, h:mm a"; return f }()

    /// "C  Am  F  G" — the chords in order, silences left out.
    static func chart(_ chords: [ChordSpan]?) -> String? {
        let names = (chords ?? []).map(\.name).filter { $0 != "N" }
        return names.isEmpty ? nil : names.joined(separator: "  ")
    }
}

private struct ImportsDetail: View {
    @ObservedObject var model: HubModel
    var body: some View {
        if model.imports.isEmpty {
            ContentUnavailableView("No imported songs yet", systemImage: "music.note.list",
                                   description: Text("Import finished songs or paste lyrics you wrote elsewhere, so Hot Mic knows your whole catalog."))
        } else {
            List(model.imports) { song in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(song.title).font(.headline)
                        if let key = song.key { Text(key.description).font(.caption).foregroundStyle(.secondary) }
                    }
                    Text(song.lyrics.isEmpty ? "No lyrics found" : song.lyrics).lineLimit(4).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
    }
}

private struct BrainDetail: View {
    @ObservedObject var model: HubModel
    var body: some View {
        List {
            Section("Search every lyric") {
                TextField("A word or line…", text: $model.query)
                ForEach(Array(model.searchResults.enumerated()), id: \.offset) { _, hit in
                    VStack(alignment: .leading) { Text(hit.line); Text(hit.title).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section("You keep coming back to") {
                if model.phrases.isEmpty { Text("Nothing repeated across songs yet.").foregroundStyle(.secondary) }
                ForEach(model.phrases, id: \.text) { phrase in
                    HStack { Text("“\(phrase.text)”"); Spacer(); Text("\(phrase.songs) songs").foregroundStyle(.secondary) }
                }
            }
        }
    }
}

private struct PasteLyricsSheet: View {
    @ObservedObject var model: HubModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add lyrics you wrote somewhere else").font(.headline)
            TextField("Song title", text: $title)
            TextEditor(text: $text).font(.body).frame(minHeight: 220).border(Color.secondary.opacity(0.3))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add to songbook") { model.importLyrics(title: title, text: text); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
