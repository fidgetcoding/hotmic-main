import Foundation

/// What a QR code (or invite link) carries: where the host is and a token that skips approval.
/// `hotmic://join?name=Mike&service=Mike%27s%20Mac&addr=192.168.1.20,10.0.0.4&port=51234&token=…`
public struct JoinInvite: Equatable, Sendable {
    public var hostName: String
    /// Bonjour service name (preferred when the phone is on the same network).
    public var service: String?
    /// Direct addresses to try when Bonjour doesn't find it (other subnet, hotspot).
    public var addresses: [String]
    public var port: UInt16
    public var token: String

    public init(hostName: String, service: String?, addresses: [String], port: UInt16, token: String) {
        self.hostName = hostName; self.service = service; self.addresses = addresses; self.port = port; self.token = token
    }

    public var url: URL {
        var c = URLComponents()
        c.scheme = "hotmic"
        c.host = "join"
        c.queryItems = [URLQueryItem(name: "name", value: hostName),
                        URLQueryItem(name: "addr", value: addresses.joined(separator: ",")),
                        URLQueryItem(name: "port", value: String(port)),
                        URLQueryItem(name: "token", value: token)]
        if let service { c.queryItems?.insert(URLQueryItem(name: "service", value: service), at: 1) }
        return c.url!
    }

    /// Rejects anything that isn't a well-formed Hot Mic invite (the camera will hand us any QR).
    public init?(url: URL) {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme == "hotmic", c.host == "join" else { return nil }
        let items = Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard let portText = items["port"], let port = UInt16(portText), port > 0,
              let token = items["token"], Self.isValidToken(token) else { return nil }
        let addresses = (items["addr"] ?? "").split(separator: ",").map(String.init).filter(Self.isValidAddress).prefix(8)
        let service = items["service"].map { NameRules.clean($0, max: 63) }.flatMap { $0.isEmpty ? nil : $0 }
        guard !addresses.isEmpty || service != nil else { return nil }
        self.init(hostName: NameRules.clean(items["name"] ?? "", max: 40).nonEmpty ?? "Hot Mic",
                  service: service, addresses: Array(addresses), port: port, token: token)
    }

    public static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 18)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func isValidToken(_ t: String) -> Bool {
        t.count >= 16 && t.count <= 64 && t.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// Plain dotted IPv4 in a private range (RFC 1918): a link can never point a phone's mic at the
    /// internet. Leading zeros are refused because some parsers read them as octal.
    public static func isValidAddress(_ a: String) -> Bool {
        let parts = a.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var octets: [UInt8] = []
        for part in parts {
            guard part.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), part.count == 1 || part.first != "0",
                  let octet = UInt8(part) else { return false }
            octets.append(octet)
        }
        switch (octets[0], octets[1]) {
        case (10, _), (172, 16...31), (192, 168): return true
        default: return false
        }
    }
}

/// Constant-time comparison so a token can't be guessed byte by byte.
public func tokensMatch(_ a: String?, _ b: String) -> Bool {
    guard let a else { return false }
    let x = Array(a.utf8), y = Array(b.utf8)
    guard x.count == y.count else { return false }
    var diff: UInt8 = 0
    for i in x.indices { diff |= x[i] ^ y[i] }
    return diff == 0
}

/// Names come from other people's phones: they end up in file names and on screen.
public enum NameRules {
    /// Printable, no path separators or control characters, trimmed, capped.
    public static func clean(_ raw: String, max: Int = 40) -> String {
        let allowed = raw.unicodeScalars.filter { s in
            !CharacterSet.controlCharacters.contains(s) && !"/\\:*?\"<>|".unicodeScalars.contains(s)
        }
        var name = String(String.UnicodeScalarView(allowed)).trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        return String(name.prefix(max))
    }

    /// For file names: letters, digits, dashes only.
    public static func fileSafe(_ raw: String) -> String {
        let cleaned = clean(raw, max: 24).map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let collapsed = cleaned.split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "guest" : collapsed
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - clocks

/// Seconds on this device's monotonic audio clock (the same clock Core Audio timestamps use).
public enum HostClock {
    private static let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()
    public static func now() -> Double { seconds(fromHostTime: mach_absolute_time()) }
    public static func seconds(fromHostTime t: UInt64) -> Double { Double(t) * timebase }
}

/// Estimates (peer clock − host clock) from ping/pong round trips. Keeps the samples with the
/// shortest round trip: those have the least queueing delay, so the smallest error.
public struct ClockSync: Sendable {
    private var samples: [(rtt: Double, offset: Double)] = []
    public init() {}

    public mutating func add(sent t1: Double, peer t2: Double, received t3: Double) {
        let rtt = t3 - t1
        guard rtt >= 0, rtt < 2 else { return }
        samples.append((rtt, t2 - (t1 + t3) / 2))
        if samples.count > 32 { samples.removeFirst(samples.count - 32) }
    }

    /// nil until at least three round trips have come back.
    public var offset: Double? {
        guard samples.count >= 3 else { return nil }
        let best = samples.sorted { $0.rtt < $1.rtt }.prefix(4)
        return best.map(\.offset).reduce(0, +) / Double(best.count)
    }

    /// Half the best round trip: the worst-case error of `offset`.
    public var uncertainty: Double? { samples.map(\.rtt).min().map { $0 / 2 } }
}
