import Foundation
import Library
import SessionKit

/// The host's side of a Session: while a session records, phones can join (QR code, Nearby,
/// remembered phones) and every singer's takes land in the same session folder.
public final class Room: SessionServerDelegate, @unchecked Sendable {
    public struct Snapshot: Equatable, Sendable {
        public var invite: JoinInvite?
        public var singers: [RemoteSinger.Snapshot] = []
        /// Phones waiting for the host to allow them.
        public var requests: [JoinRequest] = []
        public var problem: String?
        public init(invite: JoinInvite? = nil, singers: [RemoteSinger.Snapshot] = [], requests: [JoinRequest] = [], problem: String? = nil) {
            self.invite = invite; self.singers = singers; self.requests = requests; self.problem = problem
        }
    }

    /// Main queue, about twice a second and on every change.
    public var onChange: ((Snapshot) -> Void)?
    /// Someone new wants in (main queue). The UI calls `answer`.
    public var onRequest: ((JoinRequest) -> Void)?
    /// A phone singer's take landed (any queue).
    public var onTake: ((TakeRecord) -> Void)?

    public let tap: ReferenceTap
    private let server: SessionServer
    private let host: RemoteSinger.Host
    private let isTrusted: (String) -> Bool
    private let lock = NSLock()
    private var singers: [String: RemoteSinger] = [:]
    private var connected: Set<String> = []
    private var requests: [JoinRequest] = []
    private var decisions: [String: @Sendable (Bool) -> Void] = [:]
    private var invite: JoinInvite?
    private var problem: String?
    private var ticker: DispatchSourceTimer?
    private var beatBuffer: [Int16] = []
    private var beatStart: Int64 = 0

    /// `identity` and `onNetwork` are for tests: a throwaway key, and only this Mac can connect.
    public init(hostName: String, sessionName: String, host: RemoteSinger.Host, isTrusted: @escaping (String) -> Bool,
                identity: SessionIdentity = HostIdentity.load(), onNetwork: Bool = true) {
        tap = host.tap
        self.host = host
        self.isTrusted = isTrusted
        server = SessionServer(hostName: hostName, sessionName: sessionName, identity: identity, onNetwork: onNetwork)
    }

    public func start() {
        server.delegate = self
        server.onListening = { [weak self] port, problem in
            guard let self else { return }
            self.lock.withLock {
                self.invite = port.map { self.server.invite(port: $0) }
                self.problem = problem
            }
            self.publish()
        }
        server.start()
        let timer = DispatchSource.makeTimerSource(queue: server.queue)
        timer.schedule(deadline: .now() + 1, repeating: 0.5)
        var tick = 0
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            tick += 1
            if tick % 2 == 0 { self.sendStatus() }
            self.publish()
        }
        timer.resume()
        ticker = timer
    }

    /// Session over: phones are told, every singer's last take is written. Blocks until done.
    public func stop() {
        ticker?.cancel(); ticker = nil
        server.stop()
        let all = lock.withLock { () -> [RemoteSinger] in
            for decide in decisions.values { decide(false) }
            decisions.removeAll(); requests.removeAll(); connected.removeAll()
            return Array(singers.values)
        }
        for singer in all { singer.finish() }
        publish()
    }

    public func waitForLyrics() async {
        for singer in lock.withLock({ Array(singers.values) }) { await singer.waitForLyrics() }
    }

    /// The host's answer to a join request. `remember`: this phone joins by itself next time.
    public func answer(_ request: JoinRequest, allow: Bool) {
        let decide = lock.withLock { () -> (@Sendable (Bool) -> Void)? in
            requests.removeAll { $0.device == request.device }
            return decisions.removeValue(forKey: request.device)
        }
        decide?(allow)
        publish()
    }

    public func remove(device: String) { server.remove(device: device) }

    /// Drain queue, after the chunk went into `tap`: streams it as mono to anyone listening on headphones.
    public func beat(_ interleaved: UnsafeBufferPointer<Float>, frames: Int, at position: Int64) {
        let anyHeadphones = lock.withLock { singers.values.contains { $0.headphones && connected.contains($0.device) } }
        guard anyHeadphones else { beatBuffer.removeAll(keepingCapacity: true); return }
        if beatBuffer.isEmpty || beatStart + Int64(beatBuffer.count) != position {   // start fresh after a gap
            beatBuffer.removeAll(keepingCapacity: true)
            beatStart = position
        }
        for i in 0..<frames {
            let m = 0.5 * (interleaved[2 * i] + interleaved[2 * i + 1])
            beatBuffer.append(Int16(max(-1, min(1, m)) * 32_767))
        }
        if beatBuffer.count >= Int(tap.sampleRate / 20) {       // 50 ms packets
            server.broadcastBeat(BeatPacket(hostFrame: beatStart, sampleRate: tap.sampleRate, samples: beatBuffer))
            beatStart += Int64(beatBuffer.count)
            beatBuffer.removeAll(keepingCapacity: true)
        }
    }

    // MARK: - SessionServerDelegate (server queue)

    public func server(_ server: SessionServer, shouldAdmit request: JoinRequest, decide: @escaping @Sendable (Bool) -> Void) {
        lock.withLock {
            decisions[request.device]?(false)
            decisions[request.device] = decide
            requests.removeAll { $0.device == request.device }
            requests.append(request)
        }
        DispatchQueue.main.async { self.onRequest?(request) }
        publish()
    }

    public func server(_ server: SessionServer, withdrew request: JoinRequest) {
        lock.withLock {
            requests.removeAll { $0.device == request.device }
            decisions[request.device] = nil
        }
        publish()
    }

    public func server(_ server: SessionServer, isTrusted device: String) -> Bool { isTrusted(device) }

    public func server(_ server: SessionServer, resumeFrameFor device: String) -> UInt64 {
        lock.withLock { singers[device] }?.resumeFrame ?? 0
    }

    public func server(_ server: SessionServer, joined member: Member) {
        let singer = lock.withLock { () -> RemoteSinger in
            connected.insert(member.device)
            if let existing = singers[member.device] { return existing }
            let singer = RemoteSinger(device: member.device, name: member.name, sampleRate: member.sampleRate,
                                      headphones: member.headphones, host: host)
            singer.onTake = { [weak self] take in
                let seconds = Int(take.durationSeconds.rounded())
                let title = take.position.map { $0.playing ? "Bar \($0.bar)" : "Take" } ?? "Take"
                self?.server.send(.take(TakeNotice(title: title, seconds: seconds)), to: member.device)
                self?.onTake?(take)
            }
            singers[member.device] = singer
            return singer
        }
        if singer.headphones != member.headphones { singer.setHeadphones(member.headphones) }
        publish()
    }

    public func server(_ server: SessionServer, member: Member, sent packet: AudioPacket) {
        lock.withLock { singers[member.device] }?.ingest(packet, clockOffset: member.clockOffset)
    }

    public func server(_ server: SessionServer, member: Member, changedMode headphones: Bool) {
        lock.withLock { singers[member.device] }?.setHeadphones(headphones)
        publish()
    }

    /// The phone went away; its singer stays (a reconnect picks up where it left off).
    public func server(_ server: SessionServer, left member: Member) {
        _ = lock.withLock { connected.remove(member.device) }
        publish()
    }

    // MARK: - status

    private func sendStatus() {
        let live = lock.withLock { singers.values.filter { connected.contains($0.device) } }
        for singer in live {
            let s = singer.snapshot
            server.send(.status(Status(sync: s.sync, delayMs: s.delayMs, takes: s.takes, singing: s.singing, recording: true)),
                        to: singer.device)
        }
    }

    private func publish() {
        guard let onChange else { return }
        lock.lock()
        let invite = self.invite, requests = self.requests, problem = self.problem
        let live: [RemoteSinger] = singers.values.filter { connected.contains($0.device) }
        lock.unlock()
        let singers: [RemoteSinger.Snapshot] = live.map { $0.snapshot }
        let snapshot = Snapshot(invite: invite, singers: singers.sorted { $0.name < $1.name },
                                requests: requests, problem: problem)
        DispatchQueue.main.async { onChange(snapshot) }
    }
}

/// This Mac's long-term session key, kept between sessions so a phone can tell it's the same Mac.
/// A file only this user can read, not the Keychain: a build that isn't signed with a stable identity would
/// ask for the Keychain password on every launch.
public enum HostIdentity {
    public static let defaultURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Hot Mic/session-host.key")

    public static func load(from url: URL = defaultURL) -> SessionIdentity {
        if let data = try? Data(contentsOf: url), let saved = SessionIdentity(rawRepresentation: data) { return saved }
        let fresh = SessionIdentity()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: fresh.rawRepresentation, attributes: [.posixPermissions: 0o600])
        return fresh
    }
}
