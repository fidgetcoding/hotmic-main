import SwiftUI
import UniformTypeIdentifiers

/// Collapsed: a thin glass pill. Expanded: one big on/off, live level, route badge, last 3 takes.
public struct OverlayView: View {
    @ObservedObject var state: OverlayState
    let expanded: Bool

    public init(state: OverlayState, expanded: Bool) {
        self.state = state
        self.expanded = expanded
    }

    public var body: some View {
        Group {
            if expanded { panel } else { pill }
        }
        .animation(.easeOut(duration: 0.15), value: expanded)
    }

    @ViewBuilder private var pill: some View {
        if state.isOn {
            HStack(spacing: 6) {
                Circle().fill(state.stopping ? Color.orange : Color.red).frame(width: 8, height: 8)
                if state.stopping {
                    Text("Stopping…").font(.system(size: 11, weight: .semibold)).lineLimit(1)
                } else {
                    PillWave(levels: state.levels)
                }
            }
            .padding(.horizontal, 10)
            .frame(width: 190, height: 24)
            .background(Capsule().fill(.regularMaterial))
            .overlay(Capsule().strokeBorder(Color.red.opacity(0.35), lineWidth: 1))
            .contentShape(Capsule())
            .onTapGesture { state.openHub() }
            .help("Hot Mic is recording. Click to open it.")
        } else {
            Capsule()
                .fill(.regularMaterial)
                .overlay(Capsule().fill(Color.gray.opacity(0.3)).frame(width: 18, height: 4))
                .frame(width: 120, height: 10)
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button(action: state.toggle) {
                    Image(systemName: state.isOn ? "mic.fill" : "mic.slash")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(state.isOn ? Color.red.opacity(0.85) : Color.secondary.opacity(0.2)))
                        .foregroundStyle(state.isOn ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .help(state.isOn ? "Turn Hot Mic off" : "Turn Hot Mic on")

                VStack(alignment: .leading, spacing: 6) {
                    Text(state.source.map { "Listening · \($0)" } ?? "Off")
                        .font(.system(size: 13, weight: .semibold))
                    LevelMeter(level: state.isOn ? state.level : 0)
                }
                Spacer(minLength: 0)
                if !state.isOn {
                    Button("Jam", action: state.startJam)
                        .help("Record a songwriting jam: no DAW needed, instrument and voice together")
                }
                Image(systemName: state.onSpeakers ? "speaker.wave.2" : "headphones")
                    .foregroundStyle(.secondary)
                    .help(state.onSpeakers ? "Speakers: removing the music from your voice" : "Headphones")
            }

            if state.jamming {
                JamReadoutRow(state: state)
            }

            if !state.takes.isEmpty {
                Divider()
                ForEach(state.takes) { take in
                    TakeRow(take: take, playing: state.playingID == take.id) { state.play(take) }
                }
            }

            HStack {
                Button("Open Hot Mic") { state.openHub() }
                    .buttonStyle(.link)
                Button("Takes folder") { state.openFolder() }
                    .buttonStyle(.link)
                Spacer()
                Text("blue gum").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))
    }
}

/// Big current chord, then key · tempo · the note you're on.
private struct JamReadoutRow: View {
    @ObservedObject var state: OverlayState
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(state.jamChord ?? "–")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .frame(minWidth: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.jamKey ?? "listening for the key…").font(.system(size: 12))
                Text([state.jamBPM.map { "\($0) BPM" }, state.jamNote.map { "singing \($0)" }]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct LevelMeter: View {
    let level: Float
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule().fill(Color.green.opacity(0.8))
                    .frame(width: geo.size.width * CGFloat(min(1, max(0, level))))
            }
        }
        .frame(height: 4)
    }
}

private struct TakeRow: View {
    let take: OverlayTake
    let playing: Bool
    let play: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: play) { Image(systemName: playing ? "stop.fill" : "play.fill") }
                .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 1) {
                Text(take.title).font(.system(size: 12)).lineLimit(1)
                if let lyrics = take.lyrics {
                    Text(lyrics).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            Text("\(take.seconds) s").font(.system(size: 11)).foregroundStyle(.secondary)
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).help("Drag into your DAW")
        }
        .contentShape(Rectangle())
        .onDrag { NSItemProvider(contentsOf: take.voiceURL) ?? NSItemProvider() }
    }
}

/// The recording pill's live waveform: mirrored bars, newest on the right.
struct PillWave: View {
    let levels: [Float]
    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, l in
                Capsule().fill(Color.primary.opacity(0.85))
                    .frame(width: 3, height: max(2, CGFloat(l) * 16))
            }
        }
        .frame(height: 16)
        .animation(.linear(duration: 0.06), value: levels)
    }
}
