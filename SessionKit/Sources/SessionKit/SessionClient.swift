import Foundation
import Network

/// A Hot Mic session found on the local network (Bonjour).
public struct NearbyHost: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public var name: String
    public var endpoint: NWEndpoint
}

/// Watches the network for hosts that are recording.
public final class SessionBrowser: @unchecked Sendable {
    public var onChange: (([NearbyHost]) -> Void)?
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "io.bluegum.hotmic.browse")

    public init() {}

    public func start() {
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: Wire.serviceType, domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let hosts = results.compactMap { result -> NearbyHost? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return NearbyHost(name: name, endpoint: result.endpoint)
            }.sorted { $0.name < $1.name }
            DispatchQueue.main.async { self?.onChange?(hosts) }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    public func stop() { browser?.cancel(); browser = nil }
}

/// The phone's side of a session: connects, waits for approval, streams the mic, resends what a
/// dropped connection missed, and plays nothing itself (the app owns audio).
/// Public methods are thread-safe; callbacks arrive on the main queue.
public final class SessionClient: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case idle, connecting, waitingForApproval, joined(Welcome), reconnecting, denied(String), unreachable
    }

    public var onState: ((State) -> Void)?
    public var onStatus: ((Status) -> Void)?
    public var onTake: ((TakeNotice) -> Void)?
    /// Headphones mode: beat audio from the host. Called on the client queue (audio code buffers it).
    public var onBeat: ((BeatPacket) -> Void)?

    private let queue = DispatchQueue(label: "io.bluegum.hotmic.client", qos: .userInitiated)
    private var hello: Hello
    private var candidates: [NWEndpoint] = []
    private var candidateIndex = 0
    private var peer: Peer?
    private var joined = false
    private var leaving = true
    private var state: State = .idle {
        didSet { let s = state; DispatchQueue.main.async { self.onState?(s) } }
    }
    /// Everything captured in the last few minutes: resent after a reconnect.
    private var history: [AudioPacket] = []
    private var historyFrames = 0
    private let historySeconds: Double = 300
    private var retry: DispatchWorkItem?

    public init(name: String, device: String, sampleRate: Double, headphones: Bool) {
        hello = Hello(name: NameRules.clean(name), device: device, token: nil, sampleRate: sampleRate, headphones: headphones)
    }

    /// From a QR code or invite link: tries Bonjour first, then each address.
    public func join(_ invite: JoinInvite) {
        var endpoints: [NWEndpoint] = []
        if let service = invite.service { endpoints.append(.service(name: service, type: Wire.serviceType, domain: "local.", interface: nil)) }
        for address in invite.addresses {
            endpoints.append(.hostPort(host: NWEndpoint.Host(address), port: NWEndpoint.Port(rawValue: invite.port)!))
        }
        start(endpoints, token: invite.token)
    }

    /// Tapped in the Nearby list: the host approves (or remembers this phone).
    public func join(_ host: NearbyHost) { start([host.endpoint], token: nil) }

    public func leave() {
        queue.async { [self] in
            leaving = true
            retry?.cancel()
            peer?.close()
            peer = nil
            joined = false
            history.removeAll(); historyFrames = 0
            state = .idle
        }
    }

    public func setName(_ name: String) { queue.async { self.hello.name = NameRules.clean(name) } }

    public func setHeadphones(_ on: Bool) {
        queue.async { [self] in
            hello.headphones = on
            if joined { peer?.send(.mode(ModeChange(headphones: on))) }
        }
    }

    /// Mic audio, any thread. Always kept for resend; sent live while joined.
    public func send(_ packet: AudioPacket) {
        queue.async { [self] in
            history.append(packet)
            historyFrames += packet.samples.count
            let keep = Int(historySeconds * packet.sampleRate)
            while historyFrames > keep, let first = history.first {
                historyFrames -= first.samples.count
                history.removeFirst()
            }
            if joined { peer?.send(.audio(packet)) }
        }
    }

    // MARK: - connection

    private func start(_ endpoints: [NWEndpoint], token: String?) {
        queue.async { [self] in
            retry?.cancel()
            peer?.close()
            leaving = false
            joined = false
            hello.token = token
            candidates = endpoints
            candidateIndex = 0
            state = .connecting
            connectNext()
        }
    }

    private func connectNext() {
        guard !leaving, !candidates.isEmpty else { return }
        let endpoint = candidates[candidateIndex % candidates.count]
        let peer = Peer(connection: NWConnection(to: endpoint, using: Peer.parameters()), queue: queue)
        self.peer = peer
        peer.onReady = { [weak self, weak peer] in
            guard let self, let peer else { return }
            peer.send(.hello(self.hello))
        }
        peer.onMessage = { [weak self] in self?.handle($0) }
        peer.onClose = { [weak self, weak peer] _ in
            guard let self, let peer, self.peer === peer else { return }
            self.peer = nil
            let wasJoined = self.joined
            self.joined = false
            guard !self.leaving else { return }
            if case .denied = self.state { return }
            self.candidateIndex += 1
            // A whole round of addresses failed before ever getting in: tell the user, keep trying slowly.
            let exhausted = !wasJoined && self.candidateIndex % self.candidates.count == 0
            if wasJoined || { if case .reconnecting = self.state { return true }; return false }() {
                self.state = .reconnecting
            } else if exhausted {
                self.state = .unreachable
            }
            let work = DispatchWorkItem { [weak self] in self?.connectNext() }
            self.retry = work
            self.queue.asyncAfter(deadline: .now() + (exhausted ? 3 : 0.3), execute: work)
        }
        peer.start()
    }

    private func handle(_ message: Message) {
        switch message {
        case .waiting:
            state = .waitingForApproval
        case let .welcome(welcome):
            joined = true
            state = .joined(welcome)
            resend(from: welcome.nextFrame)
        case let .denied(denied):
            leaving = true
            joined = false
            state = .denied(denied.reason)
        case let .ping(t):
            peer?.send(.pong(sent: t, peer: HostClock.now()))
        case let .status(status):
            DispatchQueue.main.async { self.onStatus?(status) }
        case let .take(take):
            DispatchQueue.main.async { self.onTake?(take) }
        case let .beat(beat):
            onBeat?(beat)
        default:
            break
        }
    }

    /// After (re)joining: send everything the host hasn't got yet, oldest first.
    private func resend(from frame: UInt64) {
        for packet in history {
            let end = packet.firstFrame + UInt64(packet.samples.count)
            guard end > frame else { continue }
            if packet.firstFrame >= frame { peer?.send(.audio(packet)); continue }
            let skip = Int(frame - packet.firstFrame)
            var tail = packet
            tail.firstFrame = frame
            tail.captureSeconds += Double(skip) / packet.sampleRate
            tail.heardFrame = packet.heardFrame.map { $0 + Int64(skip) }
            tail.samples = Array(packet.samples[skip...])
            peer?.send(.audio(tail))
        }
    }
}
