import SessionKit
import SwiftUI

/// Joined: the level ring, how the Mac is lining the phone up, and the takes that landed.
struct SessionView: View {
    @Environment(SessionModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if model.reconnecting || model.interrupted { banner }
            ScrollView {
                VStack(spacing: 20) {
                    header
                    LevelRing(level: model.level)
                    syncLine
                    Text("You can lock your phone — Hot Mic keeps listening.")
                        .font(.footnote)
                        .foregroundStyle(Color.inkSoft)
                        .multilineTextAlignment(.center)
                    modeCard
                    takesCard
                    Button("Leave session", role: .destructive) { model.leave() }
                        .buttonStyle(BigButtonStyle(filled: false))
                }
                .padding(20)
            }
        }
    }

    private var banner: some View {
        HStack(spacing: 10) {
            ProgressView().tint(.white)
            Text(model.interrupted ? "Microphone paused by another app…" : "Reconnecting — still recording on this phone…")
                .font(.subheadline.weight(.semibold))
            Spacer()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(Color.ember)
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text(model.welcome?.hostName ?? model.hostLabel)
                .font(.system(.title, design: .rounded, weight: .bold))
                .foregroundStyle(Color.ink)
            if let session = model.welcome?.sessionName, !session.isEmpty {
                Text(session).font(.subheadline).foregroundStyle(Color.inkSoft)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.top, 8)
    }

    private var syncLine: some View {
        let (text, symbol, good) = syncDescription
        return VStack(spacing: 4) {
            Label(text, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(good ? Color.ink : Color.inkSoft)
            if model.status?.sync == .locked, let ms = model.status?.delayMs {
                Text("\(Int(ms.rounded())) ms from the speakers")
                    .font(.caption).foregroundStyle(Color.inkSoft)
            }
        }
    }

    private var syncDescription: (String, String, Bool) {
        switch model.status?.sync {
        case .searching, nil: ("Finding the beat…", "waveform", false)
        case .locked: ("In time with the beat", "checkmark.circle.fill", true)
        case .clockOnly: ("Beat not heard — timing from the clock", "clock", false)
        case .headphones: ("Playing the beat on this phone", "headphones", true)
        }
    }

    private var modeCard: some View {
        @Bindable var model = model
        return Card {
            Toggle(isOn: $model.headphonesMode) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hear the beat on this phone").font(.body.weight(.semibold)).foregroundStyle(Color.ink)
                    Text("Headphones or booth").font(.caption).foregroundStyle(Color.inkSoft)
                }
            }
            .tint(.flame)
            if model.headphonesMissing {
                Label("Plug in headphones first — from the phone's speaker the beat would leak into your takes.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Color.ember)
            } else if model.beatOnPhone {
                HStack(spacing: 10) {
                    Image(systemName: "speaker.fill").foregroundStyle(Color.inkSoft)
                    Slider(value: $model.beatVolume, in: 0...1)
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(Color.inkSoft)
                }
                .accessibilityLabel("Beat volume")
            }
        }
    }

    private var takesCard: some View {
        Card {
            HStack {
                Text("Takes landed").font(.headline).foregroundStyle(Color.ink)
                Spacer()
                Text("\(max(model.status?.takes ?? 0, model.takes.count))")
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .foregroundStyle(Color.flame)
                    .contentTransition(.numericText())
            }
            if model.takes.isEmpty {
                Text("Hum or rap whenever you're ready. Each take lands in the producer's bank.")
                    .font(.subheadline).foregroundStyle(Color.inkSoft)
            } else {
                ForEach(Array(model.takes.enumerated()), id: \.offset) { index, take in
                    HStack {
                        Image(systemName: "flame.fill").foregroundStyle(Color.flame)
                        Text(take.title).foregroundStyle(Color.ink).lineLimit(1)
                        Spacer()
                        Text(duration(take.seconds)).font(.caption.monospacedDigit()).foregroundStyle(Color.inkSoft)
                    }
                    .frame(minHeight: 36)
                    if index < model.takes.count - 1 { Divider() }
                }
            }
        }
        .animation(.default, value: model.takes)
    }

    private func duration(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
