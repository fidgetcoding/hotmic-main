import Network
import SessionKit
import XCTest

/// A simulated phone against the real host code over real sockets on this Mac: no Bonjour, no other machine
/// can reach it, no audio device anywhere. The "mic" is numbers.
private final class Host: SessionServerDelegate, @unchecked Sendable {
    let server: SessionServer
    let lock = NSLock()
    var joined: [String] = [], left: [String] = [], requests: [JoinRequest] = [], audio: [AudioPacket] = [], trusted: Set<String> = []
    var resume: UInt64 = 0
    var answer: Bool? = true
    var port: UInt16 = 0
    let ready = XCTestExpectation(description: "listening")
    var onAudio: ((AudioPacket) -> Void)?
    var onJoined: ((String) -> Void)?
    var onRequest: ((JoinRequest) -> Void)?

    init(identity: SessionIdentity = SessionIdentity()) {
        server = SessionServer(hostName: "Test Mac", sessionName: "Test", identity: identity, onNetwork: false)
        server.delegate = self
        server.onListening = { [weak self] port, _ in self?.port = port ?? 0; self?.ready.fulfill() }
    }
    func server(_ server: SessionServer, shouldAdmit request: JoinRequest, decide: @escaping @Sendable (Bool) -> Void) {
        lock.withLock { requests.append(request) }
        onRequest?(request)
        if let answer { decide(answer) }
    }
    func server(_ server: SessionServer, isTrusted device: String) -> Bool { lock.withLock { trusted.contains(device) } }
    func server(_ server: SessionServer, resumeFrameFor device: String) -> UInt64 { lock.withLock { resume } }
    func server(_ server: SessionServer, joined member: Member) { lock.withLock { joined.append(member.device) }; onJoined?(member.device) }
    func server(_ server: SessionServer, member: Member, sent packet: AudioPacket) { lock.withLock { audio.append(packet) }; onAudio?(packet) }
    func server(_ server: SessionServer, member: Member, changedMode headphones: Bool) {}
    func server(_ server: SessionServer, left member: Member) { lock.withLock { left.append(member.device) } }
    func server(_ server: SessionServer, withdrew request: JoinRequest) {}

    var invite: JoinInvite { JoinInvite(hostName: "Test Mac", service: nil, addresses: ["127.0.0.1"], port: port, token: server.token) }
}

private final class PinStore: HostKeyStore, @unchecked Sendable {
    let lock = NSLock(); var keys: [String: Data] = [:]
    func key(forHost name: String) -> Data? { lock.withLock { keys[name] } }
    func remember(_ key: Data, forHost name: String) { lock.withLock { keys[name] = key } }
}

/// A byte pipe between phone and host that keeps everything it sees, and can change it.
private final class Tap: @unchecked Sendable {
    let queue = DispatchQueue(label: "tap")
    var listener: NWListener?
    var seen = Data()
    var connections: [NWConnection] = []
    var mutate: ((Data) -> Data)?
    let ready = XCTestExpectation(description: "tap listening")
    var port: UInt16 = 0

    func start(to hostPort: UInt16) throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let l = try NWListener(using: parameters)
        l.stateUpdateHandler = { [weak self, weak l] s in if case .ready = s, let self { self.port = l?.port?.rawValue ?? 0; self.ready.fulfill() } }
        l.newConnectionHandler = { [weak self] phone in
            guard let self else { return }
            let host = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: hostPort)!, using: .tcp)
            self.connections += [phone, host]
            phone.start(queue: self.queue); host.start(queue: self.queue)
            self.pump(phone, host, record: true); self.pump(host, phone, record: true)
        }
        l.start(queue: queue)
        listener = l
    }
    private func pump(_ from: NWConnection, _ to: NWConnection, record: Bool) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return }
            if var data, !data.isEmpty {
                if record { self.seen.append(data) }
                if let m = self.mutate { data = m(data) }
                to.send(content: data, completion: .idempotent)
            }
            if done || error != nil { to.cancel(); from.cancel(); return }
            self.pump(from, to, record: record)
        }
    }
    func stop() { listener?.cancel(); connections.forEach { $0.cancel() } }
}

final class SessionJoinSimulationTests: XCTestCase {
    private func started(_ host: Host) async {
        host.server.start()
        await fulfillment(of: [host.ready], timeout: 5)
        XCTAssertGreaterThan(host.port, 0)
    }

    private func phone(_ identity: SessionIdentity = SessionIdentity()) -> SessionClient {
        SessionClient(name: "Sim Phone", identity: identity, sampleRate: 48_000, headphones: false)
    }

    private func packet(_ first: UInt64, _ value: Int16, count: Int = 2_400) -> AudioPacket {
        AudioPacket(firstFrame: first, captureSeconds: Double(first) / 48_000, heardFrame: nil, sampleRate: 48_000, samples: [Int16](repeating: value, count: count))
    }

    /// The phone's states, on the main queue.
    private func watch(_ client: SessionClient, until done: @escaping (SessionClient.State) -> Bool) -> XCTestExpectation {
        let e = XCTestExpectation(description: "state")
        e.assertForOverFulfill = false
        client.onState = { if done($0) { e.fulfill() } }
        return e
    }
    private static func isJoined(_ s: SessionClient.State) -> Bool { if case .joined = s { return true }; return false }
    private static func isDenied(_ s: SessionClient.State) -> Bool { if case .denied = s { return true }; return false }

    func testQRJoinNeedsNoApprovalAndAudioArrivesIntact() async throws {
        let host = Host(); await started(host)
        defer { host.server.stop() }
        let identity = SessionIdentity(), client = phone(identity)
        let joined = watch(client, until: Self.isJoined)
        let got = XCTestExpectation(description: "audio")
        got.assertForOverFulfill = false
        host.onAudio = { if $0.firstFrame == 2_400 { got.fulfill() } }
        client.join(host.invite)
        await fulfillment(of: [joined], timeout: 10)
        client.send(packet(0, 111)); client.send(packet(2_400, 222))
        await fulfillment(of: [got], timeout: 10)
        XCTAssertEqual(host.lock.withLock { host.requests.count }, 0)
        XCTAssertEqual(host.lock.withLock { host.joined }, [identity.device])
        XCTAssertEqual(host.lock.withLock { host.audio.map(\.firstFrame) }, [0, 2_400])
        XCTAssertEqual(host.lock.withLock { host.audio[1].samples[0] }, 222)
        client.leave()
    }

    func testNothingReadableOnTheWire() async throws {
        let host = Host(); await started(host)
        defer { host.server.stop() }
        let tap = Tap()
        try tap.start(to: host.port)
        await fulfillment(of: [tap.ready], timeout: 5)
        defer { tap.stop() }
        let client = phone()
        let joined = watch(client, until: Self.isJoined)
        let got = XCTestExpectation(description: "audio"); got.assertForOverFulfill = false
        host.onAudio = { _ in got.fulfill() }
        var invite = host.invite
        invite.port = tap.port
        client.join(invite)
        await fulfillment(of: [joined], timeout: 10)
        // A tone as recognisable as it gets: the same two bytes over and over.
        client.send(packet(0, 0x4142, count: 4_800))
        await fulfillment(of: [got], timeout: 10)
        let seen = tap.queue.sync { tap.seen }
        XCTAssertGreaterThan(seen.count, 9_600)
        for text in ["Sim Phone", "Test Mac", host.server.token, "device", "sampleRate", String(repeating: "BA", count: 16)] {
            XCTAssertNil(seen.range(of: Data(text.utf8)), "\(text) went over the wire in the clear")
        }
        client.leave()
    }

    func testAWrongTokenNeverGetsIn() async throws {
        let host = Host(); await started(host)
        defer { host.server.stop() }
        let client = phone()
        let unreachable = watch(client) { if case .unreachable = $0 { return true }; return false }
        var invite = host.invite
        invite.token = "guessed-guessed-guessed"
        client.join(invite)
        await fulfillment(of: [unreachable], timeout: 10)
        XCTAssertEqual(host.lock.withLock { host.joined.count }, 0)
        client.leave()
    }

    func testChangedBytesOnTheWayEndTheLink() async throws {
        let host = Host(); await started(host)
        defer { host.server.stop() }
        let tap = Tap()
        try tap.start(to: host.port)
        await fulfillment(of: [tap.ready], timeout: 5)
        defer { tap.stop() }
        tap.mutate = { var d = $0; if d.count > 40 { d[d.startIndex + 30] ^= 0x01 }; return d }
        let client = phone()
        var invite = host.invite
        invite.port = tap.port
        let failed = watch(client) { if case .unreachable = $0 { return true }; return false }
        client.join(invite)
        await fulfillment(of: [failed], timeout: 10)
        XCTAssertEqual(host.lock.withLock { host.joined.count }, 0)
        client.leave()
    }

    func testNearbyWaitsForApprovalAndBothSidesShowTheSameCode() async throws {
        let host = Host(); await started(host)
        defer { host.server.stop() }
        host.answer = nil
        let asked = XCTestExpectation(description: "asked")
        host.onRequest = { _ in asked.fulfill() }
        let client = phone()
        let codes = PhoneCode()
        let waiting = XCTestExpectation(description: "waiting"); waiting.assertForOverFulfill = false
        client.onState = { if case let .waitingForApproval(code) = $0 { codes.set(code); waiting.fulfill() } }
        client.joinForTesting(endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: host.port)!), hostName: "Test Mac")
        await fulfillment(of: [asked, waiting], timeout: 10)
        let request = try XCTUnwrap(host.lock.withLock { host.requests.first })
        XCTAssertEqual(request.code, codes.value)
        XCTAssertEqual(request.code.count, 6)
        XCTAssertEqual(host.lock.withLock { host.joined.count }, 0, "nobody is in until the host says so")
        client.leave()
    }

    func testARememberedPhoneIsKnownByItsKeyNotItsWord() async throws {
        let host = Host(); await started(host)
        defer { host.server.stop() }
        let real = SessionIdentity()
        host.lock.withLock { host.trusted.insert(real.device) }
        host.answer = false

        // The real phone walks in, by proving its key.
        let client = phone(real)
        let joined = watch(client, until: Self.isJoined)
        client.joinForTesting(endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: host.port)!), hostName: "Test Mac")
        await fulfillment(of: [joined], timeout: 10)
        client.leave()

        // Someone who sniffed the ID, with their own key, says they're that phone: refused outright.
        let denied = XCTestExpectation(description: "denied")
        let thief = RawPhone(hello: Hello(name: "Thief", device: real.device, sampleRate: 48_000, headphones: false), port: host.port)
        thief.onMessage = { if case .denied = $0 { denied.fulfill() } }
        thief.start()
        await fulfillment(of: [denied], timeout: 10)
        XCTAssertEqual(host.lock.withLock { host.joined.filter { $0 == real.device }.count }, 1, "only the real phone got in")
        thief.stop()
    }

    func testAPhoneRefusesAHostWithADifferentKeyThanTheOneItRemembers() async throws {
        let first = Host(); await started(first)
        let pins = PinStore()
        let identity = SessionIdentity()
        var client = phone(identity)
        client.hostKeys = pins
        var joined = watch(client, until: Self.isJoined)
        client.joinForTesting(endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: first.port)!), hostName: "Test Mac")
        await fulfillment(of: [joined], timeout: 10)
        XCTAssertEqual(pins.key(forHost: "Test Mac"), first.server.identity.publicKey)
        client.leave()
        first.server.stop()

        // The same name on the network, another key.
        let impostor = Host(); await started(impostor)
        defer { impostor.server.stop() }
        client = phone(identity)
        client.hostKeys = pins
        let refused = watch(client, until: Self.isDenied)
        client.joinForTesting(endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: impostor.port)!), hostName: "Test Mac")
        await fulfillment(of: [refused], timeout: 10)
        XCTAssertEqual(impostor.lock.withLock { impostor.requests.count + impostor.joined.count }, 0, "no Hello ever reached it")
        client.leave()

        // A remembered host with the same key still joins.
        let same = Host(identity: first.server.identity); await started(same)
        defer { same.server.stop() }
        client = phone(identity)
        client.hostKeys = pins
        joined = watch(client, until: Self.isJoined)
        client.joinForTesting(endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: same.port)!), hostName: "Test Mac")
        await fulfillment(of: [joined], timeout: 10)
        client.leave()
    }

    func testAReconnectResumesWhereTheHostLeftOff() async throws {
        let host = Host(); await started(host)
        defer { host.server.stop() }
        let client = phone()
        var joined = watch(client, until: Self.isJoined)
        client.join(host.invite)
        await fulfillment(of: [joined], timeout: 10)
        let two = XCTestExpectation(description: "two"); two.assertForOverFulfill = false
        host.onAudio = { if $0.firstFrame == 2_400 { two.fulfill() } }
        client.send(packet(0, 1)); client.send(packet(2_400, 2))
        await fulfillment(of: [two], timeout: 10)

        // Host says it has the first packet and half the second; the phone rejoins on a new link.
        host.lock.withLock { host.resume = 3_600; host.audio.removeAll() }
        joined = watch(client, until: Self.isJoined)
        let tail = XCTestExpectation(description: "tail"); tail.assertForOverFulfill = false
        host.onAudio = { if $0.firstFrame == 3_600 { tail.fulfill() } }
        client.join(host.invite)
        await fulfillment(of: [joined, tail], timeout: 10)
        let resent = host.lock.withLock { host.audio }
        XCTAssertEqual(resent.map(\.firstFrame), [3_600])
        XCTAssertEqual(resent[0].samples.count, 1_200)
        XCTAssertEqual(resent[0].samples[0], 2)
        client.leave()
    }

    func testHeadphonesPhoneHearsTheBeat() async throws {
        let host = Host(); await started(host)
        defer { host.server.stop() }
        let client = SessionClient(name: "Sim", identity: SessionIdentity(), sampleRate: 48_000, headphones: true)
        let joined = watch(client, until: Self.isJoined)
        let beat = XCTestExpectation(description: "beat"); beat.assertForOverFulfill = false
        let received = BeatBox()
        client.onBeat = { received.set($0); beat.fulfill() }
        client.join(host.invite)
        await fulfillment(of: [joined], timeout: 10)
        let sent = BeatPacket(hostFrame: 99, sampleRate: 48_000, samples: [1, -2, 3, -4])
        host.server.broadcastBeat(sent)
        await fulfillment(of: [beat], timeout: 10)
        XCTAssertEqual(received.value, sent)
        client.leave()
    }

    func testGarbageConnectionsDontHurtTheRoom() async throws {
        let host = Host(); await started(host)
        defer { host.server.stop() }
        for bytes in [Data("GET / HTTP/1.1\r\n\r\n".utf8), Data(repeating: 0xFF, count: 4_096), Data([0x48, 0x4D, 2, 1, 0xFF, 0xFF])] {
            let c = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: host.port)!, using: .tcp)
            let closed = XCTestExpectation(description: "closed"); closed.assertForOverFulfill = false
            c.stateUpdateHandler = { if case .cancelled = $0 { closed.fulfill() } }
            c.start(queue: .global())
            c.send(content: bytes, completion: .idempotent)
            c.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, _, done, error in if done || error != nil { c.cancel() } }
            await fulfillment(of: [closed], timeout: 10)
        }
        let client = phone()
        let joined = watch(client, until: Self.isJoined)
        client.join(host.invite)
        await fulfillment(of: [joined], timeout: 10)
        client.leave()
    }

    func testFullRoomAndRemove() async throws {
        let host = Host(); await started(host)
        defer { host.server.stop() }
        var phones: [SessionClient] = []
        for _ in 0..<SessionServer.maxMembers {
            let c = phone()
            let joined = watch(c, until: Self.isJoined)
            c.join(host.invite)
            await fulfillment(of: [joined], timeout: 10)
            phones.append(c)
        }
        let extra = phone()
        let full = watch(extra, until: Self.isDenied)
        extra.join(host.invite)
        await fulfillment(of: [full], timeout: 10)

        let removedID = host.lock.withLock { host.joined[0] }
        let removed = watch(phones[0], until: Self.isDenied)
        host.server.remove(device: removedID)
        await fulfillment(of: [removed], timeout: 10)
        phones.forEach { $0.leave() }
    }
}

private final class PhoneCode: @unchecked Sendable {
    private let lock = NSLock(); private var code = ""
    func set(_ c: String) { lock.withLock { code = c } }
    var value: String { lock.withLock { code } }
}
private final class BeatBox: @unchecked Sendable {
    private let lock = NSLock(); private var packet: BeatPacket?
    func set(_ p: BeatPacket) { lock.withLock { packet = p } }
    var value: BeatPacket? { lock.withLock { packet } }
}

/// A client with its own key that says whatever it's told in Hello: what a thief would write.
private final class RawPhone: @unchecked Sendable {
    let peer: Peer
    let hello: Hello
    var onMessage: ((Message) -> Void)?
    init(hello: Hello, port: UInt16) {
        self.hello = hello
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: Peer.parameters())
        peer = Peer(connection: connection, queue: DispatchQueue(label: "raw"), link: SecureLink(initiator: SessionIdentity(), mode: .nearby, psk: SecureLink.noPSK))
    }
    func start() {
        peer.onReady = { [self] in peer.send(.hello(hello)) }
        peer.onMessage = { [self] in onMessage?($0) }
        peer.start()
    }
    func stop() { peer.connection.cancel() }
}
