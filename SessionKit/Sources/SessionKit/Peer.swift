import Foundation
import Network

/// One framed connection. Every callback arrives on `queue`.
public final class Peer: @unchecked Sendable {
    public let connection: NWConnection
    public let queue: DispatchQueue
    public var onMessage: ((Message) -> Void)?
    /// Called once, when the connection ends for any reason.
    public var onClose: ((NWError?) -> Void)?
    /// Called once the connection is up (client side).
    public var onReady: (() -> Void)?
    private var decoder = FrameDecoder()
    private var closed = false
    /// Bytes handed to the network but not yet sent. Droppable traffic (the beat) is skipped when
    /// the link is backed up, so a slow phone never builds up seconds of lag.
    private var pendingBytes = 0

    public init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// Parameters both sides use: TCP, no Nagle delay (control messages are tiny), keepalive.
    public static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 5
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = true      // phone ↔ Mac even without a shared Wi-Fi router (AWDL)
        return params
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.onReady?(); self.onReady = nil
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
        let data = message.encoded()
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
        connection.send(content: Message.bye.encoded(), completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.connection.cancel() }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                do {
                    for message in try self.decoder.push(data) {
                        if case .bye = message { self.connection.cancel(); return }
                        self.onMessage?(message)
                    }
                } catch {
                    self.connection.cancel()          // garbage or oversized: drop the peer
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
