import CryptoKit
import Foundation

/// A device's long-term key. The host trusts this key, not a name a phone says it has: `device` is
/// derived from the key and proven in the handshake, so a sniffed ID can't pass for a remembered phone.
public struct SessionIdentity: Sendable {
    let key: Curve25519.KeyAgreement.PrivateKey

    public init() { key = Curve25519.KeyAgreement.PrivateKey() }
    public init?(rawRepresentation: Data) {
        guard let k = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawRepresentation) else { return nil }
        key = k
    }
    /// Keep this secret (the Keychain on a phone).
    public var rawRepresentation: Data { key.rawRepresentation }
    public var publicKey: Data { key.publicKey.rawRepresentation }
    public var device: String { Self.device(forPublicKey: publicKey) }

    public static func device(forPublicKey key: Data) -> String {
        SHA256.hash(data: key).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

public enum SecureLinkError: Error, Equatable { case badHeader, tooLarge, malformed, authentication, commitment, notReady }

/// The Noise protocol `Noise_XXpsk3_25519_ChaChaPoly_SHA256` (noiseprotocol.org, rev 34): a published
/// pattern, checked against a public test vector in the tests. Both sides prove a long-term key, and a
/// shared secret goes into the keys, so someone without it can't read, write or sit in the middle.
public struct NoiseHandshake {
    public static let protocolName = "Noise_XXpsk3_25519_ChaChaPoly_SHA256"
    public enum Role: Sendable { case initiator, responder }

    private let role: Role
    private let staticKey: Curve25519.KeyAgreement.PrivateKey
    private var ephemeral: Curve25519.KeyAgreement.PrivateKey
    private let psk: Data
    private var remoteEphemeral: Curve25519.KeyAgreement.PublicKey?
    public private(set) var remoteStatic: Data?
    private var ck: Data
    private var h: Data
    private var cipherKey: SymmetricKey?
    private var nonce: UInt64 = 0
    private var step = 0

    /// `ephemeral` is for test vectors; leave it out everywhere else.
    public init(role: Role, identity: SessionIdentity, psk: Data, prologue: Data, ephemeral: Data? = nil) {
        self.role = role
        staticKey = identity.key
        self.ephemeral = ephemeral.flatMap { try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: $0) } ?? Curve25519.KeyAgreement.PrivateKey()
        self.psk = psk
        ck = Data(SHA256.hash(data: Data(Self.protocolName.utf8)))
        h = ck
        mixHash(prologue)
    }

    public var handshakeHash: Data { h }
    public var isComplete: Bool { step == 3 }

    // MARK: messages

    /// The next message from this side, carrying `payload`.
    public mutating func write(payload: Data) throws -> Data {
        var out = Data()
        switch step {
        case 0:     // -> e
            let e = ephemeral.publicKey.rawRepresentation
            out += e; mixHash(e); mixKey(e)
        case 1:     // <- e, ee, s, es
            let e = ephemeral.publicKey.rawRepresentation
            out += e; mixHash(e); mixKey(e)
            mixKey(try dh(ephemeral, remoteEphemeral))
            out += try encryptAndHash(staticKey.publicKey.rawRepresentation)
            mixKey(try dh(staticKey, remoteEphemeral))
        case 2:     // -> s, se, psk
            out += try encryptAndHash(staticKey.publicKey.rawRepresentation)
            mixKey(try dh(staticKey, remoteEphemeral))
            mixPSK()
        default:
            throw SecureLinkError.notReady
        }
        out += try encryptAndHash(payload)
        step += 1
        return out
    }

    /// Reads the other side's next message and returns its payload.
    public mutating func read(_ message: Data) throws -> Data {
        var rest = message
        func take(_ n: Int) throws -> Data {
            guard rest.count >= n else { throw SecureLinkError.malformed }
            defer { rest = Data(rest.dropFirst(n)) }
            return Data(rest.prefix(n))
        }
        switch step {
        case 0:
            let e = try take(32)
            remoteEphemeral = try key(e); mixHash(e); mixKey(e)
        case 1:
            let e = try take(32)
            remoteEphemeral = try key(e); mixHash(e); mixKey(e)
            mixKey(try dh(ephemeral, remoteEphemeral))
            let s = try decryptAndHash(try take(48))
            remoteStatic = s
            mixKey(try dh(ephemeral, try key(s)))
        case 2:
            let s = try decryptAndHash(try take(48))
            remoteStatic = s
            mixKey(try dh(ephemeral, try key(s)))
            mixPSK()
        default:
            throw SecureLinkError.notReady
        }
        let payload = try decryptAndHash(rest)
        step += 1
        return payload
    }

    /// After message 3: the keys for each direction.
    public func split() throws -> (send: TransportCipher, receive: TransportCipher) {
        guard isComplete else { throw SecureLinkError.notReady }
        let keys = Self.hkdf(ck, Data(), outputs: 2)
        let (a, b) = (TransportCipher(key: keys[0]), TransportCipher(key: keys[1]))
        return role == .initiator ? (a, b) : (b, a)
    }

    // MARK: Noise's symmetric state

    private func key(_ raw: Data) throws -> Curve25519.KeyAgreement.PublicKey {
        do { return try Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw) } catch { throw SecureLinkError.malformed }
    }

    private func dh(_ mine: Curve25519.KeyAgreement.PrivateKey, _ theirs: Curve25519.KeyAgreement.PublicKey?) throws -> Data {
        guard let theirs else { throw SecureLinkError.malformed }
        do { return try mine.sharedSecretFromKeyAgreement(with: theirs).withUnsafeBytes { Data($0) } } catch { throw SecureLinkError.authentication }
    }

    private mutating func mixHash(_ data: Data) { h = Data(SHA256.hash(data: h + data)) }

    private mutating func mixKey(_ material: Data) {
        let out = Self.hkdf(ck, material, outputs: 2)
        ck = out[0]; cipherKey = SymmetricKey(data: out[1]); nonce = 0
    }

    private mutating func mixPSK() {
        let out = Self.hkdf(ck, psk, outputs: 3)
        ck = out[0]; mixHash(out[1]); cipherKey = SymmetricKey(data: out[2]); nonce = 0
    }

    private mutating func encryptAndHash(_ plain: Data) throws -> Data {
        guard let cipherKey else { mixHash(plain); return plain }
        let c = try TransportCipher.seal(plain, key: cipherKey, nonce: nonce, ad: h)
        nonce += 1
        mixHash(c)
        return c
    }

    private mutating func decryptAndHash(_ cipher: Data) throws -> Data {
        guard let cipherKey else { mixHash(cipher); return cipher }
        let p = try TransportCipher.open(cipher, key: cipherKey, nonce: nonce, ad: h)
        nonce += 1
        mixHash(cipher)
        return p
    }

    static func hkdf(_ salt: Data, _ material: Data, outputs: Int) -> [Data] {
        let prk = Data(HMAC<SHA256>.authenticationCode(for: material, using: SymmetricKey(data: salt)))
        var out: [Data] = [], last = Data()
        for i in 1...outputs {
            last = Data(HMAC<SHA256>.authenticationCode(for: last + [UInt8(i)], using: SymmetricKey(data: prk)))
            out.append(last)
        }
        return out
    }
}

/// One direction of the link after the handshake: every message sealed, numbered in order.
public struct TransportCipher {
    private let key: SymmetricKey
    private var nonce: UInt64 = 0
    init(key: Data) { self.key = SymmetricKey(data: key) }

    public mutating func seal(_ plain: Data) throws -> Data {
        defer { nonce += 1 }
        return try Self.seal(plain, key: key, nonce: nonce, ad: Data())
    }
    public mutating func open(_ cipher: Data) throws -> Data {
        defer { nonce += 1 }
        return try Self.open(cipher, key: key, nonce: nonce, ad: Data())
    }

    static func nonceBytes(_ n: UInt64) throws -> ChaChaPoly.Nonce {
        var le = n.littleEndian
        var bytes = Data(count: 4)
        withUnsafeBytes(of: &le) { bytes.append(contentsOf: $0) }
        return try ChaChaPoly.Nonce(data: bytes)
    }
    static func seal(_ plain: Data, key: SymmetricKey, nonce: UInt64, ad: Data) throws -> Data {
        let box = try ChaChaPoly.seal(plain, using: key, nonce: nonceBytes(nonce), authenticating: ad)
        return box.ciphertext + box.tag
    }
    static func open(_ cipher: Data, key: SymmetricKey, nonce: UInt64, ad: Data) throws -> Data {
        guard cipher.count >= 16 else { throw SecureLinkError.authentication }
        do {
            let box = try ChaChaPoly.SealedBox(nonce: nonceBytes(nonce), ciphertext: cipher.dropLast(16), tag: cipher.suffix(16))
            return try ChaChaPoly.open(box, using: key, authenticating: ad)
        } catch { throw SecureLinkError.authentication }
    }
}

/// How a phone comes in, and what the keys rest on.
public enum JoinMode: UInt8, Sendable {
    /// Nearby: no shared secret. Anyone can connect; the host decides, comparing the code on both screens.
    case nearby = 0
    /// QR code or invite link: its token is the shared secret and is never sent.
    case invite = 1
}

/// The whole encrypted link as a state machine with no network in it: bytes in, bytes out.
///
/// On the wire: a 4-byte header (`HM`, wire version, join mode), three handshake messages each
/// `[length: UInt16 BE][bytes]`, then records `[length: UInt32 BE][sealed message]`. The header goes into
/// the handshake, so changing the mode on the way breaks it.
///
/// Message 1 commits to a random value that message 3 reveals, with the host's value in message 2. The
/// six-digit code comes from those and the handshake: someone in the middle has to fix their values
/// before seeing the ones that decide the code, so they can't search for keys that make both screens match.
public final class SecureLink {
    public static let maxHandshakeMessage = 512
    public static let maxRecord = Wire.maxPayload + 5 + 16

    public let role: NoiseHandshake.Role
    public private(set) var mode: JoinMode?
    /// The other side's long-term key, once it has proven it.
    public private(set) var remoteKey: Data?
    /// Six digits to compare on both screens (Nearby). Set when the link is ready.
    public private(set) var code: String?
    public var isReady: Bool { sendCipher != nil }

    private let identity: SessionIdentity
    private let pskForMode: (JoinMode) -> Data?
    private var handshake: NoiseHandshake?
    private var sendCipher: TransportCipher?
    private var receiveCipher: TransportCipher?
    private var buffer = Data()
    private var ownRandom = Data()
    private var commitment = Data()
    private var theirRandom = Data()
    private var headerSeen = false
    private let randomness: () -> Data

    public static func psk(forToken token: String) -> Data {
        Data(SHA256.hash(data: Data("hotmic-invite-v2:\(token)".utf8)))
    }
    /// Nearby has nothing shared; Noise's slot for a secret stays zeros.
    public static let noPSK = Data(repeating: 0, count: 32)

    /// The phone's side.
    public init(initiator identity: SessionIdentity, mode: JoinMode, psk: Data, randomness: @escaping () -> Data = SecureLink.random32) {
        role = .initiator
        self.mode = mode
        self.identity = identity
        pskForMode = { _ in psk }
        self.randomness = randomness
    }

    /// The host's side. `token`: this session's invite secret.
    public init(responder identity: SessionIdentity, token: String, randomness: @escaping () -> Data = SecureLink.random32) {
        role = .responder
        self.identity = identity
        pskForMode = { $0 == .invite ? SecureLink.psk(forToken: token) : SecureLink.noPSK }
        self.randomness = randomness
    }

    public static func random32() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }

    private static func header(_ mode: JoinMode) -> Data { Data([0x48, 0x4D, UInt8(Wire.version), mode.rawValue]) }

    private static func framed(_ message: Data) -> Data {
        var length = UInt16(message.count).bigEndian
        return withUnsafeBytes(of: &length) { Data($0) } + message
    }

    /// The first bytes the phone sends. The host sends nothing until it has read them.
    public func start() throws -> Data {
        guard role == .initiator, let mode, let psk = pskForMode(mode) else { throw SecureLinkError.notReady }
        let header = Self.header(mode)
        var noise = NoiseHandshake(role: .initiator, identity: identity, psk: psk, prologue: header)
        ownRandom = randomness()
        let message = try noise.write(payload: Data(SHA256.hash(data: ownRandom)))
        handshake = noise
        headerSeen = true
        return header + Self.framed(message)
    }

    /// Whatever the socket delivered. Returns bytes to send back, and any messages that arrived whole.
    /// Throws when the other side is broken or lying: drop the connection.
    public func receive(_ bytes: Data) throws -> (reply: Data, messages: [Data]) {
        buffer.append(bytes)
        var reply = Data(), messages: [Data] = []
        if !headerSeen {
            guard buffer.count >= 4 else {
                try checkHeaderPrefix()
                return (reply, messages)
            }
            try checkHeaderPrefix()
            guard let m = JoinMode(rawValue: buffer[buffer.startIndex + 3]), let psk = pskForMode(m) else { throw SecureLinkError.badHeader }
            mode = m
            handshake = NoiseHandshake(role: .responder, identity: identity, psk: psk, prologue: Data(buffer.prefix(4)))
            buffer = Data(buffer.dropFirst(4))
            headerSeen = true
        }
        while !isReady {
            guard buffer.count >= 2 else { return (reply, messages) }
            let length = Int(buffer[buffer.startIndex]) << 8 | Int(buffer[buffer.startIndex + 1])
            guard length <= Self.maxHandshakeMessage else { throw SecureLinkError.tooLarge }
            guard buffer.count >= 2 + length else { return (reply, messages) }
            let message = Data(buffer.dropFirst(2).prefix(length))
            buffer = Data(buffer.dropFirst(2 + length))
            reply += try advance(message)
        }
        while buffer.count >= 4 {
            let s = buffer.startIndex
            let length = Int(buffer[s]) << 24 | Int(buffer[s + 1]) << 16 | Int(buffer[s + 2]) << 8 | Int(buffer[s + 3])
            guard length <= Self.maxRecord else { throw SecureLinkError.tooLarge }
            guard buffer.count >= 4 + length else { break }
            messages.append(try receiveCipher!.open(Data(buffer.dropFirst(4).prefix(length))))
            buffer = Data(buffer.dropFirst(4 + length))
        }
        return (reply, messages)
    }

    /// One message, sealed and framed for the wire.
    public func seal(_ message: Data) throws -> Data {
        guard sendCipher != nil else { throw SecureLinkError.notReady }
        let sealed = try sendCipher!.seal(message)
        var length = UInt32(sealed.count).bigEndian
        return withUnsafeBytes(of: &length) { Data($0) } + sealed
    }

    private func checkHeaderPrefix() throws {
        let expected: [UInt8] = [0x48, 0x4D, UInt8(Wire.version)]
        for (i, b) in buffer.prefix(3).enumerated() where b != expected[i] { throw SecureLinkError.badHeader }
    }

    private func advance(_ message: Data) throws -> Data {
        guard var noise = handshake else { throw SecureLinkError.notReady }
        defer { handshake = noise }
        switch role {
        case .responder where theirRandom.isEmpty && commitment.isEmpty:
            commitment = try noise.read(message)
            guard commitment.count == 32 else { throw SecureLinkError.commitment }
            ownRandom = randomness()
            return Self.framed(try noise.write(payload: ownRandom))
        case .responder:
            theirRandom = try noise.read(message)
            guard Data(SHA256.hash(data: theirRandom)) == commitment else { throw SecureLinkError.commitment }
            remoteKey = noise.remoteStatic
            try finish(noise, phoneRandom: theirRandom, hostRandom: ownRandom)
            return Data()
        case .initiator:
            theirRandom = try noise.read(message)
            guard theirRandom.count == 32 else { throw SecureLinkError.commitment }
            remoteKey = noise.remoteStatic
            let out = Self.framed(try noise.write(payload: ownRandom))
            try finish(noise, phoneRandom: ownRandom, hostRandom: theirRandom)
            return out
        }
    }

    private func finish(_ noise: NoiseHandshake, phoneRandom: Data, hostRandom: Data) throws {
        let keys = try noise.split()
        sendCipher = keys.send
        receiveCipher = keys.receive
        let digest = SHA256.hash(data: noise.handshakeHash + phoneRandom + hostRandom)
        let n = digest.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 1_000_000
        code = String(format: "%06d", n)
    }
}
