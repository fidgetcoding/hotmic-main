import SwiftUI

/// Hot Mic for iPhone: join the producer's session from across the room and just sing.
@main
struct HotMicApp: App {
    @State private var model = SessionModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(.flame)
                .preferredColorScheme(.light)
                .onOpenURL { model.open($0) }
        }
    }
}

/// One screen per phase of the session; the scanner is a sheet over home.
struct RootView: View {
    @Environment(SessionModel.self) private var model

    var body: some View {
        ZStack {
            Color.paper.ignoresSafeArea()
            switch model.phase {
            case .home:
                HomeView()
            case .connecting, .waiting:
                WaitingView()
            case .joined:
                SessionView()
            case let .denied(reason):
                ProblemView(title: "Not this time", message: reason, symbol: "hand.raised")
            case .unreachable:
                ProblemView(title: "Can't reach \(model.hostLabel)",
                            message: "Make sure this iPhone is on the same Wi-Fi as the Mac and Hot Mic is still recording. Still trying…",
                            symbol: "wifi.exclamationmark")
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.phase)
        .sheet(isPresented: Binding(get: { model.inviteToConfirm != nil }, set: { if !$0 { model.inviteToConfirm = nil } })) {
            if let invite = model.inviteToConfirm { JoinConfirmSheet(invite: invite) }
        }
    }
}
