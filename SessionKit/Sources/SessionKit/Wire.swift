import Foundation

/// The Session wire format. Every message is one frame: `[type: UInt8][length: UInt32 BE][payload]`.
/// Control messages carry JSON; audio carries a small binary header plus 16-bit PCM.
/// On the network every frame travels inside SecureLink: nothing is ever sent in the clear.
public enum Wire {
    public static let version = 2
    /// Bonjour service type the host advertises and phones browse for.
    public static let serviceType = "_hotmic._tcp"
    /// Anything bigger is a broken or hostile peer: the connection is dropped.
    public static let maxPayload = 1 << 20

    public enum Kind: UInt8, Sendable {
        case hello = 1, welcome, denied, audio, ping, pong, beat, status, take, bye, mode, waiting
    }
}

// MARK: - control messages (JSON)

/// Contributor → host, first message on every connection (also after a reconnect).
public struct Hello: Codable, Equatable, Sendable {
    public var version = Wire.version
    public var name: String
    /// `SessionIdentity.device`: stable per install, and the host checks it against the key the handshake
    /// proved. Lets the host resume the same singer after a dropped connection.
    public var device: String
    public var sampleRate: Double
    /// True when the phone plays the beat itself (headphones / booth), false when it hears the room.
    public var headphones: Bool
    public init(name: String, device: String, sampleRate: Double, headphones: Bool) {
        self.name = name; self.device = device; self.sampleRate = sampleRate; self.headphones = headphones
    }
}

/// Host → contributor: you're in.
public struct Welcome: Codable, Equatable, Sendable {
    public var hostName: String
    public var sessionName: String
    /// Mic frames the host already has from this device; the phone resends everything after it.
    public var nextFrame: UInt64
    public init(hostName: String, sessionName: String, nextFrame: UInt64) {
        self.hostName = hostName; self.sessionName = sessionName; self.nextFrame = nextFrame
    }
}

public struct Denied: Codable, Equatable, Sendable {
    public var reason: String
    public init(reason: String) { self.reason = reason }
}

/// Host → contributor, about once a second.
public struct Status: Codable, Equatable, Sendable {
    public enum Sync: String, Codable, Sendable { case searching, locked, clockOnly, headphones }
    public var sync: Sync
    /// Room mode: how far the phone sits from the speakers, in milliseconds of sound travel + latency.
    public var delayMs: Double?
    public var takes: Int
    public var singing: Bool
    public var recording: Bool
    public init(sync: Sync, delayMs: Double?, takes: Int, singing: Bool, recording: Bool) {
        self.sync = sync; self.delayMs = delayMs; self.takes = takes; self.singing = singing; self.recording = recording
    }
}

/// Host → contributor: one of your takes just landed.
public struct TakeNotice: Codable, Equatable, Sendable {
    public var title: String
    public var seconds: Int
    public init(title: String, seconds: Int) { self.title = title; self.seconds = seconds }
}

/// Contributor → host: switched between hearing the room and playing the beat on the phone.
public struct ModeChange: Codable, Equatable, Sendable {
    public var headphones: Bool
    public init(headphones: Bool) { self.headphones = headphones }
}

// MARK: - audio

/// Contributor → host: a chunk of mic audio.
public struct AudioPacket: Equatable, Sendable {
    /// Index of the first frame in this device's mic stream (starts at 0 when the app starts listening).
    public var firstFrame: UInt64
    /// Phone clock (seconds) when the first frame reached the mic, input latency removed.
    public var captureSeconds: Double
    /// Headphones mode: the host session frame the singer was hearing at the first frame. nil in room mode.
    public var heardFrame: Int64?
    public var sampleRate: Double
    public var samples: [Int16]
    public init(firstFrame: UInt64, captureSeconds: Double, heardFrame: Int64?, sampleRate: Double, samples: [Int16]) {
        self.firstFrame = firstFrame; self.captureSeconds = captureSeconds; self.heardFrame = heardFrame
        self.sampleRate = sampleRate; self.samples = samples
    }
}

/// Host → contributor in headphones mode: the session audio (mono) starting at a host frame.
public struct BeatPacket: Equatable, Sendable {
    public var hostFrame: Int64
    public var sampleRate: Double
    public var samples: [Int16]
    public init(hostFrame: Int64, sampleRate: Double, samples: [Int16]) {
        self.hostFrame = hostFrame; self.sampleRate = sampleRate; self.samples = samples
    }
}

public enum WireError: Error, Equatable { case malformed, tooLarge, unsupportedVersion }

// MARK: - encoding

public enum Message: Equatable, Sendable {
    case hello(Hello), welcome(Welcome), denied(Denied), waiting
    case audio(AudioPacket), beat(BeatPacket)
    case ping(Double), pong(sent: Double, peer: Double)
    case status(Status), take(TakeNotice), mode(ModeChange), bye

    public func encoded() -> Data {
        let (kind, payload): (Wire.Kind, Data)
        let json = JSONEncoder()
        switch self {
        case let .hello(m): (kind, payload) = (.hello, (try? json.encode(m)) ?? Data())
        case let .welcome(m): (kind, payload) = (.welcome, (try? json.encode(m)) ?? Data())
        case let .denied(m): (kind, payload) = (.denied, (try? json.encode(m)) ?? Data())
        case .waiting: (kind, payload) = (.waiting, Data())
        case let .status(m): (kind, payload) = (.status, (try? json.encode(m)) ?? Data())
        case let .take(m): (kind, payload) = (.take, (try? json.encode(m)) ?? Data())
        case let .mode(m): (kind, payload) = (.mode, (try? json.encode(m)) ?? Data())
        case .bye: (kind, payload) = (.bye, Data())
        case let .ping(t):
            var w = ByteWriter(); w.f64(t); (kind, payload) = (.ping, w.data)
        case let .pong(sent, peer):
            var w = ByteWriter(); w.f64(sent); w.f64(peer); (kind, payload) = (.pong, w.data)
        case let .audio(p):
            var w = ByteWriter(capacity: 32 + p.samples.count * 2)
            w.u64(p.firstFrame); w.f64(p.captureSeconds); w.i64(p.heardFrame ?? Int64.min); w.f64(p.sampleRate)
            w.pcm(p.samples)
            (kind, payload) = (.audio, w.data)
        case let .beat(p):
            var w = ByteWriter(capacity: 16 + p.samples.count * 2)
            w.i64(p.hostFrame); w.f64(p.sampleRate); w.pcm(p.samples)
            (kind, payload) = (.beat, w.data)
        }
        var frame = Data(capacity: 5 + payload.count)
        frame.append(kind.rawValue)
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    public static func decode(kind raw: UInt8, payload: Data) throws -> Message {
        guard let kind = Wire.Kind(rawValue: raw) else { throw WireError.malformed }
        let json = JSONDecoder()
        do {
            switch kind {
            case .hello:
                let m = try json.decode(Hello.self, from: payload)
                guard m.version == Wire.version else { throw WireError.unsupportedVersion }
                return .hello(m)
            case .welcome: return .welcome(try json.decode(Welcome.self, from: payload))
            case .denied: return .denied(try json.decode(Denied.self, from: payload))
            case .waiting: return .waiting
            case .status: return .status(try json.decode(Status.self, from: payload))
            case .take: return .take(try json.decode(TakeNotice.self, from: payload))
            case .mode: return .mode(try json.decode(ModeChange.self, from: payload))
            case .bye: return .bye
            case .ping:
                var r = ByteReader(payload); return .ping(try r.f64())
            case .pong:
                var r = ByteReader(payload); return .pong(sent: try r.f64(), peer: try r.f64())
            case .audio:
                var r = ByteReader(payload)
                let first = try r.u64(), capture = try r.f64(), heard = try r.i64(), rate = try r.f64()
                guard rate >= 8_000, rate <= 192_000, capture.isFinite else { throw WireError.malformed }
                return .audio(AudioPacket(firstFrame: first, captureSeconds: capture,
                                          heardFrame: heard == Int64.min ? nil : heard, sampleRate: rate, samples: try r.pcm()))
            case .beat:
                var r = ByteReader(payload)
                let frame = try r.i64(), rate = try r.f64()
                guard rate >= 8_000, rate <= 192_000 else { throw WireError.malformed }
                return .beat(BeatPacket(hostFrame: frame, sampleRate: rate, samples: try r.pcm()))
            }
        } catch let error as WireError {
            throw error
        } catch {
            throw WireError.malformed
        }
    }
}

/// Splits a byte stream into messages. Feed it whatever the socket delivers.
public struct FrameDecoder {
    private var buffer = Data()
    public init() {}

    /// Returns every complete message; throws on garbage or an oversized frame (drop the peer).
    public mutating func push(_ bytes: Data) throws -> [Message] {
        buffer.append(bytes)
        var out: [Message] = []
        while buffer.count >= 5 {
            let start = buffer.startIndex
            let kind = buffer[start]
            let length = Int(buffer[start + 1]) << 24 | Int(buffer[start + 2]) << 16 | Int(buffer[start + 3]) << 8 | Int(buffer[start + 4])
            guard length <= Wire.maxPayload else { throw WireError.tooLarge }
            guard buffer.count >= 5 + length else { break }
            let payload = buffer.subdata(in: (start + 5)..<(start + 5 + length))
            buffer.removeSubrange(start..<(start + 5 + length))
            out.append(try Message.decode(kind: kind, payload: payload))
        }
        if buffer.isEmpty { buffer = Data() }   // keep indices from drifting
        return out
    }
}

// MARK: - bytes

struct ByteWriter {
    var data: Data
    init(capacity: Int = 32) { data = Data(capacity: capacity) }
    mutating func u64(_ v: UInt64) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
    mutating func i64(_ v: Int64) { u64(UInt64(bitPattern: v)) }
    mutating func f64(_ v: Double) { u64(v.bitPattern) }
    mutating func pcm(_ samples: [Int16]) {
        var count = UInt32(samples.count).littleEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        samples.withUnsafeBufferPointer { data.append(UnsafeBufferPointer(start: UnsafeRawPointer($0.baseAddress)?.assumingMemoryBound(to: UInt8.self),
                                                                           count: $0.count * 2)) }
    }
}

struct ByteReader {
    let data: Data
    var offset: Int
    init(_ data: Data) { self.data = data; offset = data.startIndex }

    mutating func bytes(_ n: Int) throws -> Data {
        guard n >= 0, offset + n <= data.endIndex else { throw WireError.malformed }
        defer { offset += n }
        return data.subdata(in: offset..<(offset + n))
    }
    mutating func u64() throws -> UInt64 {
        let b = try bytes(8)
        return b.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
    }
    mutating func i64() throws -> Int64 { Int64(bitPattern: try u64()) }
    mutating func f64() throws -> Double { Double(bitPattern: try u64()) }
    mutating func pcm() throws -> [Int16] {
        let c = try bytes(4)
        let count = Int(c.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        guard count <= Wire.maxPayload / 2 else { throw WireError.tooLarge }
        let raw = try bytes(count * 2)
        return raw.withUnsafeBytes { buf in (0..<count).map { Int16(littleEndian: buf.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)) } }
    }
}

// MARK: - PCM

public enum PCM16 {
    public static func encode(_ samples: UnsafeBufferPointer<Float>) -> [Int16] {
        samples.map { Int16(max(-1, min(1, $0)) * 32_767) }
    }
    public static func encode(_ samples: [Float]) -> [Int16] { samples.withUnsafeBufferPointer { encode($0) } }
    public static func decode(_ samples: [Int16]) -> [Float] { samples.map { Float($0) / 32_767 } }
}
