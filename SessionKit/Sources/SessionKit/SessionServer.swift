import Foundation
import Network

/// Someone asking to join. Nearby joins without a token wait for the host to allow them.
public struct JoinRequest: Identifiable, Equatable, Sendable {
    public var id: String { device }
    public var name: String
    public var device: String
}

/// One joined singer, as the host sees them. Callbacks and properties are used on the server queue.
public final class Member: @unchecked Sendable {
    public let device: String
    public let name: String
    public internal(set) var headphones: Bool
    public let sampleRate: Double
    /// Phone clock − host clock (seconds), once enough pings have come back.
    public var clockOffset: Double? { clock.offset }
    var clock = ClockSync()
    let peer: Peer

    init(hello: Hello, peer: Peer) {
        device = hello.device
        name = NameRules.clean(hello.name).nonEmpty ?? "Guest"
        headphones = hello.headphones
        sampleRate = hello.sampleRate
        self.peer = peer
    }

    public func send(_ message: Message, droppable: Bool = false) { peer.send(message, droppable: droppable) }
}

/// Everything the host app decides or hears about. Called on the server queue.
public protocol SessionServerDelegate: AnyObject {
    /// Nearby join without a valid token and not a trusted device: call `decide` once (any thread).
    func server(_ server: SessionServer, shouldAdmit request: JoinRequest, decide: @escaping @Sendable (Bool) -> Void)
    /// Is this device on the host's "always allow" list?
    func server(_ server: SessionServer, isTrusted device: String) -> Bool
    /// Mic frames already received from this device this session (so a reconnect resumes there).
    func server(_ server: SessionServer, resumeFrameFor device: String) -> UInt64
    func server(_ server: SessionServer, joined member: Member)
    func server(_ server: SessionServer, member: Member, sent packet: AudioPacket)
    func server(_ server: SessionServer, member: Member, changedMode headphones: Bool)
    func server(_ server: SessionServer, left member: Member)
    /// A request the host hadn't answered yet went away (phone gave up or left).
    func server(_ server: SessionServer, withdrew request: JoinRequest)
}

/// Listens for phones while a session records: Bonjour for Nearby, a fixed port for QR codes.
public final class SessionServer: @unchecked Sendable {
    public static let maxMembers = 8
    /// How long a phone may hold a join slot waiting for the host to answer.
    public static let approvalTimeout: TimeInterval = 60
    public let queue = DispatchQueue(label: "io.bluegum.hotmic.session", qos: .userInitiated)
    public let hostName: String
    public let sessionName: String
    /// Carried by the QR code: joining with it needs no approval. New for every session.
    public let token = JoinInvite.newToken()
    public weak var delegate: SessionServerDelegate?
    /// Called (on the server queue) with the port once listening, or an error message.
    public var onListening: ((UInt16?, String?) -> Void)?

    private var listener: NWListener?
    private var members: [String: Member] = [:]
    private var pending: [ObjectIdentifier: Peer] = [:]
    private var pingTimer: DispatchSourceTimer?

    public init(hostName: String, sessionName: String) {
        self.hostName = NameRules.clean(hostName, max: 40).nonEmpty ?? "Hot Mic"
        self.sessionName = NameRules.clean(sessionName, max: 60)
    }

    public func start() {
        queue.async { [self] in
            do {
                let listener = try NWListener(using: Peer.parameters())
                listener.service = NWListener.Service(name: hostName, type: Wire.serviceType)
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready: self.onListening?(listener.port?.rawValue, nil)
                    case let .failed(error): self.onListening?(nil, "Phones can't join: \(error.localizedDescription)")
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] in self?.accept($0) }
                listener.start(queue: queue)
                self.listener = listener
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + 0.5, repeating: 1.0)
                timer.setEventHandler { [weak self] in self?.pingAll() }
                timer.resume()
                pingTimer = timer
            } catch {
                onListening?(nil, "Phones can't join: \(error.localizedDescription)")
            }
        }
    }

    /// Ends the room: everyone is told goodbye.
    public func stop() {
        queue.sync {
            pingTimer?.cancel(); pingTimer = nil
            listener?.cancel(); listener = nil
            for member in members.values { member.peer.close() }
            for peer in pending.values { peer.close() }
            members.removeAll(); pending.removeAll()
        }
    }

    public func invite(port: UInt16) -> JoinInvite {
        JoinInvite(hostName: hostName, service: hostName, addresses: LocalAddresses.ipv4(), port: port, token: token)
    }

    /// Server queue. Removes a member (host pressed "Remove").
    public func remove(device: String) {
        queue.async { [self] in
            guard let member = members.removeValue(forKey: device) else { return }
            member.send(.denied(Denied(reason: "\(hostName) removed you from the session.")))
            member.peer.close()
            delegate?.server(self, left: member)
        }
    }

    /// Sends the live beat to everyone listening on headphones. Any thread.
    public func broadcastBeat(_ packet: BeatPacket) {
        queue.async { [self] in
            let message = Message.beat(packet)
            for member in members.values where member.headphones { member.send(message, droppable: true) }
        }
    }

    public func send(_ message: Message, to device: String) {
        queue.async { [self] in members[device]?.send(message) }
    }

    // MARK: - connections

    private func accept(_ connection: NWConnection) {
        let peer = Peer(connection: connection, queue: queue)
        let key = ObjectIdentifier(peer)
        guard pending.count < 16 else { connection.cancel(); return }
        pending[key] = peer
        var pendingRequest: JoinRequest?
        peer.onMessage = { [weak self, weak peer] message in
            guard let self, let peer else { return }
            if case let .hello(hello) = message {
                guard pendingRequest == nil else { return }
                self.admit(hello, peer: peer) { pendingRequest = $0 }
            } else if let member = self.members.values.first(where: { $0.peer === peer }) {
                self.handle(message, from: member)
            }
        }
        peer.onClose = { [weak self] _ in
            guard let self else { return }
            self.pending[key] = nil
            if let request = pendingRequest { self.delegate?.server(self, withdrew: request) }
            if let (device, member) = self.members.first(where: { $0.value.peer === peer }) {
                self.members[device] = nil
                self.delegate?.server(self, left: member)
            }
        }
        // Say hello within 10 s or go.
        queue.asyncAfter(deadline: .now() + 10) { [weak self, weak peer] in
            guard let self, let peer, self.pending[key] != nil, !self.members.values.contains(where: { $0.peer === peer }),
                  pendingRequest == nil else { return }
            peer.connection.cancel()
        }
        peer.start()
    }

    private func admit(_ hello: Hello, peer: Peer, waiting: (JoinRequest?) -> Void) {
        guard hello.sampleRate >= 8_000, hello.sampleRate <= 192_000, !hello.device.isEmpty, hello.device.count <= 64,
              hello.device.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            peer.send(.denied(Denied(reason: "This version of Hot Mic can't join."))); peer.close(); return
        }
        let request = JoinRequest(name: NameRules.clean(hello.name).nonEmpty ?? "Guest", device: hello.device)
        let welcomeNow = tokensMatch(hello.token, token) || delegate?.server(self, isTrusted: hello.device) == true
        if welcomeNow { welcome(hello, peer: peer); return }
        guard let delegate else { peer.send(.denied(Denied(reason: "Not accepting guests."))); peer.close(); return }
        peer.send(.waiting)
        waiting(request)
        queue.asyncAfter(deadline: .now() + Self.approvalTimeout) { [weak self, weak peer] in
            guard let self, let peer, self.pending[ObjectIdentifier(peer)] != nil else { return }   // answered or left
            peer.send(.denied(Denied(reason: "\(self.hostName) didn't answer. Try again.")))
            peer.close()
        }
        delegate.server(self, shouldAdmit: request) { [weak self, weak peer] allowed in
            guard let self else { return }
            self.queue.async {
                guard let peer, self.pending[ObjectIdentifier(peer)] != nil else { return }   // left while waiting
                if allowed { self.welcome(hello, peer: peer) } else {
                    peer.send(.denied(Denied(reason: "\(self.hostName) didn't let you in this time.")))
                    peer.close()
                }
            }
        }
    }

    private func welcome(_ hello: Hello, peer: Peer) {
        if let old = members[hello.device] {                  // the same phone reconnecting: the new link wins
            old.peer.onClose = nil
            old.peer.connection.cancel()
            members[hello.device] = nil
        }
        guard members.count < Self.maxMembers else {
            peer.send(.denied(Denied(reason: "The session is full (\(Self.maxMembers) singers).")))
            peer.close()
            return
        }
        let member = Member(hello: hello, peer: peer)
        members[member.device] = member
        pending[ObjectIdentifier(peer)] = nil
        let resume = delegate?.server(self, resumeFrameFor: member.device) ?? 0
        member.send(.welcome(Welcome(hostName: hostName, sessionName: sessionName, nextFrame: resume)))
        delegate?.server(self, joined: member)
    }

    private func handle(_ message: Message, from member: Member) {
        switch message {
        case let .audio(packet):
            guard packet.samples.count <= 96_000 else { return }
            delegate?.server(self, member: member, sent: packet)
        case let .pong(sent, peerTime):
            member.clock.add(sent: sent, peer: peerTime, received: HostClock.now())
        case let .ping(t):
            member.send(.pong(sent: t, peer: HostClock.now()))
        case let .mode(change):
            member.headphones = change.headphones
            delegate?.server(self, member: member, changedMode: change.headphones)
        default:
            break
        }
    }

    private func pingAll() {
        let now = HostClock.now()
        for member in members.values { member.send(.ping(now)) }
    }
}
