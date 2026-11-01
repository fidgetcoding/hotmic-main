import SessionKit
import SwiftUI

/// Name, sessions on this Wi-Fi, and the QR scanner.
struct HomeView: View {
    @Environment(SessionModel.self) private var model
    @FocusState private var nameFocused: Bool

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                nameCard
                if let invite = model.pendingInvite { pendingCard(invite) }
                if let problem = model.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Color.ember)
                }
                nearbyCard
                Button { model.showScanner = true } label: {
                    Label("Scan QR code", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(BigButtonStyle())
                .disabled(!model.hasName)
                .opacity(model.hasName ? 1 : 0.5)
                Text("Or point your iPhone camera at the QR code in Hot Mic on the Mac.")
                    .font(.footnote)
                    .foregroundStyle(Color.inkSoft)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .sheet(isPresented: $model.showScanner, onDismiss: { model.scannerDismissed() }) {
            ScannerSheet { model.ask($0) }
        }
        .onAppear { if !model.hasName { nameFocused = true } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Hot Mic")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(Color.ink)
            Text("Sing into the producer's session from anywhere in the room.")
                .font(.subheadline)
                .foregroundStyle(Color.inkSoft)
        }
        .padding(.top, 12)
    }

    private var nameCard: some View {
        @Bindable var model = model
        return Card {
            Text("Your name").font(.caption.weight(.semibold)).foregroundStyle(Color.inkSoft)
            TextField("What should the producer call you?", text: $model.name)
                .font(.title3.weight(.semibold))
                .textContentType(.givenName)
                .submitLabel(.done)
                .focused($nameFocused)
                .foregroundStyle(Color.ink)
            if !model.hasName {
                Text("Takes land in the producer's bank under this name.")
                    .font(.footnote).foregroundStyle(Color.inkSoft)
            }
        }
    }

    private func pendingCard(_ invite: JoinInvite) -> some View {
        Card {
            Text("Join \(invite.hostName)'s session").font(.headline).foregroundStyle(Color.ink)
            Button("Join") { model.join(invite) }
                .buttonStyle(BigButtonStyle())
                .disabled(!model.hasName)
                .opacity(model.hasName ? 1 : 0.5)
        }
    }

    private var nearbyCard: some View {
        Card {
            HStack {
                Text("Nearby").font(.headline).foregroundStyle(Color.ink)
                Spacer()
                if model.nearby.isEmpty { ProgressView() }
            }
            if model.nearby.isEmpty {
                Text("Looking for Hot Mic sessions on this Wi-Fi…")
                    .font(.subheadline).foregroundStyle(Color.inkSoft)
            } else {
                ForEach(model.nearby) { host in
                    Button { model.join(host) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "flame.fill").foregroundStyle(Color.flame)
                            Text(host.name).font(.body.weight(.semibold)).foregroundStyle(Color.ink)
                            Spacer()
                            Text("Join").font(.subheadline.weight(.semibold)).foregroundStyle(Color.flame)
                        }
                        .frame(minHeight: 52)
                        .contentShape(Rectangle())
                    }
                    .disabled(!model.hasName)
                    .opacity(model.hasName ? 1 : 0.5)
                    if host != model.nearby.last { Divider() }
                }
                Text("The producer lets you in from the Mac.")
                    .font(.footnote).foregroundStyle(Color.inkSoft)
            }
        }
    }
}
