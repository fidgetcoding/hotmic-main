import AVFoundation
import Foundation

/// A take as the overlay shows it.
public struct OverlayTake: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var seconds: Int
    public var voiceURL: URL
    public var mixURL: URL
    public var lyrics: String?

    public init(id: String, title: String, seconds: Int, voiceURL: URL, mixURL: URL, lyrics: String? = nil) {
        self.id = id; self.title = title; self.seconds = seconds; self.voiceURL = voiceURL; self.mixURL = mixURL
        self.lyrics = lyrics
    }
}

/// What the overlay renders. The app updates it on the main queue; the view only reads + calls actions.
public final class OverlayState: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published public var isOn = false
    @Published public var source: String?          // DAW name, "Manual", or nil
    @Published public var level: Float = 0 {        // 0…1 mic level for the meter
        didSet { levels.append(level); if levels.count > 28 { levels.removeFirst(levels.count - 28) } }
    }
    /// The last ~2 s of levels, oldest first: the pill's moving waveform.
    @Published public private(set) var levels: [Float] = Array(repeating: 0, count: 28)
    @Published public var onSpeakers = false
    @Published public var takes: [OverlayTake] = []
    @Published public var pulse = 0                // increments on every new take
    @Published public var settings = OverlaySettings.load()
    /// Jam mode live readout (nil fields = not heard yet).
    @Published public var jamming = false
    /// The DAW closed; the session ends after a short grace period.
    @Published public var stopping = false
    @Published public var jamChord: String?
    @Published public var jamKey: String?
    @Published public var jamBPM: Int?
    @Published public var jamNote: String?

    public var toggle: () -> Void = {}
    public var startJam: () -> Void = {}
    public var openFolder: () -> Void = {}
    public var openHub: () -> Void = {}
    /// Called with the preview's length so capture can ignore Hot Mic's own playback.
    public var onPreview: (Double) -> Void = { _ in }

    private var player: AVAudioPlayer?
    public private(set) var playingID: String?

    public override init() { super.init() }

    public func add(_ take: OverlayTake) {
        takes = Array(([take] + takes).prefix(3))
        pulse += 1
    }

    /// Live lyric lane: words land on their take as soon as transcription finishes.
    public func setLyrics(_ text: String, forTake id: String) {
        guard let i = takes.firstIndex(where: { $0.id == id }) else { return }
        takes[i].lyrics = text
    }

    public func play(_ take: OverlayTake) {
        if playingID == take.id { player?.stop(); playingID = nil; objectWillChange.send(); return }
        player = try? AVAudioPlayer(contentsOf: take.mixURL)
        player?.delegate = self
        onPreview((player?.duration ?? 0) + 0.5)
        player?.play()
        playingID = take.id
        objectWillChange.send()
    }

    /// The play button returns to ▶︎ when a preview ends on its own.
    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            guard player === self.player else { return }
            self.playingID = nil
            self.objectWillChange.send()
        }
    }

    public func update(_ change: (inout OverlaySettings) -> Void) {
        change(&settings)
        settings.save()
    }
}
