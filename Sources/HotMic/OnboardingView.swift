import AppKit
import AVFoundation
import SwiftUI

/// First launch: three short steps, then Hot Mic disappears into the menu bar.
struct OnboardingView: View {
    @ObservedObject var model: AppModel
    let done: () -> Void
    @State private var step = 0
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.system(size: 22, weight: .semibold))
            Group {
                switch step {
                case 0: welcome
                case 1: permissions
                default: sync
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            HStack {
                Text("blue gum").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                if step > 0 { Button("Back") { step -= 1 } }
                Button(step == 2 ? "Start listening" : "Continue") { step == 2 ? done() : (step += 1) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 560, height: 400)
    }

    private var title: String {
        ["Never lose an idea again", "Two permissions", "Bars and tempo (optional)"][step]
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Hot Mic listens while your music software is open and saves every idea you sing, hum or rap — automatically.")
            Text("It lives in the menu bar and a faint pill at the top of your screen. Hover it to see your latest takes and drag them straight into your session.")
            Text("Your audio stays on this Mac.").foregroundStyle(.secondary)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Image(systemName: micStatus == .authorized ? "checkmark.circle.fill" : "mic").foregroundStyle(micStatus == .authorized ? .green : .primary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Microphone").font(.headline)
                    Text("To hear you sing. Hot Mic only keeps the moments that sound like music.")
                    if micStatus == .notDetermined {
                        Button("Allow microphone") {
                            AVCaptureDevice.requestAccess(for: .audio) { _ in
                                DispatchQueue.main.async { micStatus = AVCaptureDevice.authorizationStatus(for: .audio) }
                            }
                        }
                    } else if micStatus != .authorized {
                        // macOS won't ask twice; the switch lives in System Settings.
                        Text("Microphone access is off for Hot Mic.").foregroundStyle(.secondary)
                        Button("Open Privacy & Security…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                        }
                    }
                }
            }
            HStack(alignment: .top) {
                Image(systemName: "speaker.wave.2")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Audio from your DAW").font(.headline)
                    Text("macOS asks the first time your DAW is open. It lets Hot Mic take the beat out of your voice recording when you're on speakers, and save a version with the music.")
                }
            }
        }
    }

    private var sync: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("To label takes with the bar and tempo, send MIDI clock from your DAW to **Hot Mic Sync** once:")
            ForEach(SettingsView.guides.prefix(3), id: \.0) { daw, steps in
                Text("**\(daw):** \(steps)").font(.callout)
            }
            Text("Other DAWs are in Settings → DAW Sync. You can skip this; takes still get a time stamp.").foregroundStyle(.secondary)
        }
    }
}
