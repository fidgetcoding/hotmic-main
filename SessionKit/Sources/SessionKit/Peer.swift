import Foundation
import Network

/// One encrypted, framed connection. Every callback arrives on `queue`.
public final class Peer: @unchecked Sendable {
    public let connection: NWConnection
    public let queue: DispatchQueue
    public let link: SecureLink
    public var onMessage: ((Message) -> Void)?
    /// Called once, when the connection ends for any reason.
    public var onClose: ((NWError?) -> Void)?
    /// Called once the encrypted link is up. The other side's key and the code are on `link` by then.
    public var onReady: (() -> Void)?
    private var decoder = FrameDecoder()
    private var closed = false
    /// Bytes handed to the network but not yet sent. Droppable traffic (the beat) is skipped when
    /// the link is backed up, so a slow phone never builds up seconds of lag.
    private var pendingBytes = 0

    public init(connection: NWConnection, queue: DispatchQueue, link: SecureLink) {
        self.connection = connection
        self.queue = queue
        self.link = link
    }

    /// TCP, no Nagle delay (control messages are tiny), keepalive. The encryption is SecureLink, above this.
    public static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 5
        return NWParameters(tls: nil, tcp: tcp)
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard self.link.role == .initiator else { return }
                do { self.write(try self.link.start()) } catch { self.connection.cancel() }
            case let .failed(error): self.finish(error)
            case let .waiting(error): self.finish(error)   // no route: let the owner retry
            case .cancelled: self.finish(nil)
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    public var isBackedUp: Bool { pendingBytes > 1 << 20 }

    /// `droppable`: skip when the link is backed up (live beat). Everything else always queues.
    public func send(_ message: Message, droppable: Bool = false) {
        guard !closed else { return }
        if droppable && isBackedUp { return }
        guard let data = try? link.seal(message.encoded()) else { return }     // not up yet: nothing is ever sent in the clear
        write(data)
    }

    private func write(_ data: Data) {
        pendingBytes += data.count
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.pendingBytes -= data.count
            if let error { self.finish(error) }
        })
    }

    /// Sends `bye` and closes after it's out.
    public func close() {
        guard !closed else { return }
        guard let bye = try? link.seal(Message.bye.encoded()) else { connection.cancel(); return }
        connection.send(content: bye, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.connection.cancel() }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                do {
                    let wasReady = self.link.isReady
                    let (reply, records) = try self.link.receive(data)
                    if !reply.isEmpty { self.write(reply) }
                    if !wasReady, self.link.isReady { self.onReady?(); self.onReady = nil }
                    for record in records {
                        for message in try self.decoder.push(record) {
                            if case .bye = message { self.connection.cancel(); return }
                            self.onMessage?(message)
                        }
                    }
                } catch {
                    self.connection.cancel()          // garbage, forged or oversized: drop the peer
                    return
                }
            }
            if complete || error != nil { self.connection.cancel(); return }
            self.receive()
        }
    }

    private func finish(_ error: NWError?) {
        guard !closed else { return }
        closed = true
        connection.cancel()
        let onClose = self.onClose
        self.onClose = nil
        onMessage = nil
        onClose?(error)
    }
}

/// This Mac's private IPv4 addresses on active, non-loopback interfaces (for the QR code).
public enum LocalAddresses {
    public static func ipv4() -> [String] {
        var result: [(name: String, address: String)] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let addr = ifa.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: host)
            guard JoinInvite.isValidAddress(address) else { continue }  // invites only carry private addresses
            result.append((String(cString: ifa.pointee.ifa_name), address))
        }
        // Wi-Fi / Ethernet (en*) first: that's where the phone is.
        return result.sorted { ($0.name.hasPrefix("en") ? 0 : 1, $0.name) < ($1.name.hasPrefix("en") ? 0 : 1, $1.name) }.map(\.address)
    }
}
