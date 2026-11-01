import AppKit
import CoreImage.CIFilterBuiltins
import Session
import SessionKit
import SwiftUI

/// A phone that joins by itself (the host ticked "Always let this phone in").
struct TrustedPhone: Codable, Identifiable, Equatable {
    var id: String { device }
    var device: String
    var name: String
}

/// Phones in the session, as the hub and menu show them. Main actor.
@MainActor
final class PhonesModel: ObservableObject {
    @Published var snapshot = Room.Snapshot()
    @Published var recording = false
    @Published private(set) var enabled = UserDefaults.standard.object(forKey: "phones.enabled") as? Bool ?? false
    @Published private(set) var trusted: [TrustedPhone] = {
        guard let data = UserDefaults.standard.data(forKey: "phones.trusted") else { return [] }
        return (try? JSONDecoder().decode([TrustedPhone].self, from: data)) ?? []
    }()
    /// Room actions (set by the app while a session records).
    var answer: (JoinRequest, Bool) -> Void = { _, _ in }
    var remove: (String) -> Void = { _ in }
    /// Called when turning phones on/off should apply to the running session.
    var onEnabledChange: (Bool) -> Void = { _ in }

    private var qrCache: (url: URL, image: NSImage)?

    init() { trustedDevices.replace(with: Set(trusted.map(\.device))) }

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: "phones.enabled")
        onEnabledChange(on)
    }

    func isTrusted(_ device: String) -> Bool { trusted.contains { $0.device == device } }

    /// Read from the network queue when a phone connects (never waits on the main thread).
    nonisolated let trustedDevices = LockedSet()


    func allow(_ request: JoinRequest, always: Bool) {
        if always, !isTrusted(request.device) {
            trusted.append(TrustedPhone(device: request.device, name: request.name))
            saveTrusted()
        }
        answer(request, true)
    }

    func deny(_ request: JoinRequest) { answer(request, false) }

    func forget(_ phone: TrustedPhone) {
        trusted.removeAll { $0.device == phone.device }
        saveTrusted()
    }

    private func saveTrusted() {
        trustedDevices.replace(with: Set(trusted.map(\.device)))
        if let data = try? JSONEncoder().encode(trusted) { UserDefaults.standard.set(data, forKey: "phones.trusted") }
    }

    /// The invite as a crisp QR image (cached: it only changes per session).
    func qrImage(for invite: JoinInvite) -> NSImage? {
        if let qrCache, qrCache.url == invite.url { return qrCache.image }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(invite.url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: output.extent.width / 2, height: output.extent.height / 2))
        qrCache = (invite.url, image)
        return image
    }
}

/// Hub pane: the QR code, who's waiting, who's singing.
struct PhonesView: View {
    @ObservedObject var phones: PhonesModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Phones").font(.title2.weight(.semibold))
                    Spacer()
                    Toggle("Let phones join", isOn: Binding(get: { phones.enabled }, set: { phones.setEnabled($0) }))
                        .toggleStyle(.switch)
                }
                Text("Experimental. Phone audio and the join code travel unencrypted over your local network, so only turn this on when you trust the network.")
                    .font(.callout).foregroundStyle(.secondary)
                if !phones.snapshot.requests.isEmpty { requests }
                if !phones.enabled {
                    Text("Phones can't join while this is off.").foregroundStyle(.secondary)
                } else if !phones.recording {
                    Text("Open your DAW (or press Turn on) and phones can join the session. Anyone in the room opens Hot Mic on their iPhone and hums — their takes land here, on the bar they sang them.")
                        .foregroundStyle(.secondary)
                } else {
                    join
                    singers
                }
                if let problem = phones.snapshot.problem { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                if !phones.trusted.isEmpty { trustedList }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    private var join: some View {
        HStack(alignment: .top, spacing: 24) {
            if let invite = phones.snapshot.invite, let image = phones.qrImage(for: invite) {
                Image(nsImage: image).interpolation(.none).resizable().frame(width: 200, height: 200)
                    .padding(10).background(.white).clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
            } else {
                ProgressView().frame(width: 220, height: 220)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Join from a phone").font(.headline)
                Text("Scan this with the iPhone camera and say yes on the phone. No approval needed here.")
                Text("Or open Hot Mic on the phone: this Mac shows up under Nearby, and you let them in.")
                    .foregroundStyle(.secondary)
                Text("Across the room, the phone hears your speakers and lines itself up with the beat. In a booth, they tap “Hear the beat on this phone” and wear headphones.")
                    .font(.callout).foregroundStyle(.secondary)
                if let invite = phones.snapshot.invite {
                    Button("Copy invite link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(invite.url.absoluteString, forType: .string)
                    }
                }
            }
        }
    }

    private var requests: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(phones.snapshot.requests) { request in
                HStack {
                    Image(systemName: "iphone.radiowaves.left.and.right").foregroundStyle(.orange)
                    Text("\(request.name) wants to join").font(.headline)
                    Spacer()
                    Button("Not now") { phones.deny(request) }
                    Button("Let in") { phones.allow(request, always: false) }
                    Button("Always let in") { phones.allow(request, always: true) }.buttonStyle(.borderedProminent)
                }
                .padding(12)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var singers: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(phones.snapshot.singers.isEmpty ? "No phones yet" : "In the session").font(.headline)
            ForEach(phones.snapshot.singers) { singer in
                HStack(spacing: 12) {
                    Circle().fill(singer.singing ? Color.orange : Color.secondary.opacity(0.3)).frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(singer.name).font(.body.weight(.medium))
                        Text(Self.syncText(singer)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ProgressView(value: Double(min(1, singer.level * 4))).frame(width: 80)
                    Text("\(singer.takes) take\(singer.takes == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                    Button("Remove") { phones.remove(singer.device) }.buttonStyle(.borderless)
                }
                .padding(.vertical, 6)
            }
        }
    }

    private var trustedList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("Phones that join by themselves").font(.headline)
            ForEach(phones.trusted) { phone in
                HStack {
                    Text(phone.name)
                    Spacer()
                    Button("Forget") { phones.forget(phone) }.buttonStyle(.borderless)
                }
            }
        }
    }

    static func syncText(_ s: RemoteSinger.Snapshot) -> String {
        switch s.sync {
        case .searching: return "Finding the beat…"
        case .locked: return "In time with the beat" + (s.delayMs.map { " · \(Int($0.rounded())) ms from the speakers" } ?? "")
        case .clockOnly: return "Can't hear the beat — timing from the clock"
        case .headphones: return "Hearing the beat on the phone"
        }
    }
}

final class LockedSet: @unchecked Sendable {
    private let lock = NSLock()
    private var items: Set<String> = []
    func contains(_ item: String) -> Bool { lock.withLock { items.contains(item) } }
    func replace(with new: Set<String>) { lock.withLock { items = new } }
}
