import SessionKit
import SwiftUI

/// Connecting, then waiting for the producer to tap Allow on the Mac.
struct WaitingView: View {
    @Environment(SessionModel.self) private var model

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView().controlSize(.large).tint(.flame)
            Text(model.phase == .waiting
                 ? "Waiting for \(model.hostLabel) to let you in…"
                 : "Connecting to \(model.hostLabel)…")
                .font(.title2.bold())
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.center)
            if model.phase == .waiting {
                Text("They'll see your name, \(model.name), on the Mac.")
                    .foregroundStyle(Color.inkSoft)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            Button("Cancel") { model.leave() }
                .buttonStyle(BigButtonStyle(filled: false))
        }
        .padding(24)
    }
}

/// Denied or unreachable: say why, and a way back home.
struct ProblemView: View {
    @Environment(SessionModel.self) private var model
    var title: String
    var message: String
    var symbol: String

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: symbol).font(.system(size: 48)).foregroundStyle(Color.flame)
            Text(title).font(.title2.bold()).foregroundStyle(Color.ink).multilineTextAlignment(.center)
            Text(message).foregroundStyle(Color.inkSoft).multilineTextAlignment(.center)
            Spacer()
            Button("Back") { model.leave() }
                .buttonStyle(BigButtonStyle())
        }
        .padding(24)
    }
}

/// Shown before any hotmic:// link or scanned code joins: a link can come from anyone.
struct JoinConfirmSheet: View {
    @Environment(SessionModel.self) private var model
    let invite: JoinInvite

    private var place: String { invite.addresses.first ?? invite.service ?? invite.hostName }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Join \(invite.hostName)'s session?")
                .font(.title2.weight(.bold))
                .foregroundStyle(Color.ink)
            Text("Your microphone turns on and streams to \(place) on this network, unencrypted. Only join if you know this Mac and you're on a network you trust.")
                .foregroundStyle(Color.inkSoft)
            Button("Join") { model.confirmInvite() }
                .buttonStyle(BigButtonStyle())
            Button("Not now") { model.inviteToConfirm = nil }
                .frame(maxWidth: .infinity)
        }
        .padding(24)
        .presentationDetents([.medium])
    }
}
