import CryptoKit
import SessionKit
import XCTest

private func hex(_ s: String) -> Data {
    var out = Data(), i = s.startIndex
    while i < s.endIndex { let j = s.index(i, offsetBy: 2); out.append(UInt8(s[i..<j], radix: 16)!); i = j }
    return out
}
private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

/// The published Noise pattern, against the public cacophony test vector for it.
final class NoiseVectorTests: XCTestCase {
    func testMatchesThePublishedVector() throws {
        let prologue = hex("4a6f686e2047616c74")
        let psk = hex("54686973206973206d7920417573747269616e20706572737065637469766521")
        var a = NoiseHandshake(role: .initiator, identity: SessionIdentity(rawRepresentation: hex("e61ef9919cde45dd5f82166404bd08e38bceb5dfdfded0a34c8df7ed542214d1"))!,
                               psk: psk, prologue: prologue, ephemeral: hex("893e28b9dc6ca8d611ab664754b8ceb7bac5117349a4439a6b0569da977c464a"))
        var b = NoiseHandshake(role: .responder, identity: SessionIdentity(rawRepresentation: hex("4a3acbfdb163dec651dfa3194dece676d437029c62a408b4c5ea9114246e4893"))!,
                               psk: psk, prologue: prologue, ephemeral: hex("bbdb4cdbd309f1a1f2e1456967fe288cadd6f712d65dc7b7793d5e63da6b375b"))
        let messages: [(String, String)] = [
            ("4c756477696720766f6e204d69736573", "ca35def5ae56cec33dc2036731ab14896bc4c75dbb07a61f879f8e3afa4c7944c9f5ff0e8079630cb7e270c20bbf480821b77a384a645c71a2fd9b3db1c16a5f"),
            ("4d757272617920526f746862617264", "95ebc60d2b1fa672c1f46a8aa265ef51bfe38e7ccb39ec5be34069f144808843b123def17f71e6ae8e57e0e1dec5949c5f7415c6f33517398747d821a06dc23ad430aa1fd7381d46195c378a819fd574425462cbb2d4ca339e738a0b7001dc91423fbf55a99af0c6f1df21012ceb2f"),
            ("462e20412e20486179656b", "52187316111b118d4c060364f7b975dc0809b2590779aff2d63113c564f11744493384db7bf32d5ae6686df6ab06d508d2e07caaf1d6afc010b978735fc78900e71ae1d314130d042e729a"),
        ]
        var sent = try a.write(payload: hex(messages[0].0))
        XCTAssertEqual(hex(sent), messages[0].1)
        XCTAssertEqual(hex(try b.read(sent)), messages[0].0)
        sent = try b.write(payload: hex(messages[1].0))
        XCTAssertEqual(hex(sent), messages[1].1)
        XCTAssertEqual(hex(try a.read(sent)), messages[1].0)
        sent = try a.write(payload: hex(messages[2].0))
        XCTAssertEqual(hex(sent), messages[2].1)
        XCTAssertEqual(hex(try b.read(sent)), messages[2].0)
        XCTAssertEqual(hex(a.handshakeHash), "a477edf6a131bbdb54707f6ea30eab6cd935d9b560f0e5fd1f053a95a99669fb")
        XCTAssertEqual(hex(b.handshakeHash), hex(a.handshakeHash))

        var (aSend, aReceive) = try a.split()
        var (bSend, bReceive) = try b.split()
        let transport: [(String, String)] = [
            ("4361726c204d656e676572", "eaedc672d4c21e0e2955758756fb98f194c4e90d5deb5b6cf30b27"),
            ("4a65616e2d426170746973746520536179", "522d543c5fe799d09a3d9da7ff54d0dc03c8af1dc7751d2ff708339d2290943e98"),
            ("457567656e2042f6686d20766f6e2042617765726b", "7d4e2c3873eef6a213b04e72f9df60a91666072d3544c5d96c34a09e2329b5030bee796741"),
        ]
        // Noise test vectors keep alternating senders after the handshake: responder, initiator, responder.
        var c = try bSend.seal(hex(transport[0].0))
        XCTAssertEqual(hex(c), transport[0].1)
        XCTAssertEqual(hex(try aReceive.open(c)), transport[0].0)
        c = try aSend.seal(hex(transport[1].0))
        XCTAssertEqual(hex(c), transport[1].1)
        XCTAssertEqual(hex(try bReceive.open(c)), transport[1].0)
        c = try bSend.seal(hex(transport[2].0))
        XCTAssertEqual(hex(c), transport[2].1)
    }
}

/// The whole link with no network in it: two state machines passing bytes.
final class SecureLinkTests: XCTestCase {
    private func pair(phoneToken: String? = "the-token-the-token", hostToken: String = "the-token-the-token") -> (phone: SecureLink, host: SecureLink) {
        let phone = SecureLink(initiator: SessionIdentity(), mode: phoneToken == nil ? .nearby : .invite,
                               psk: phoneToken.map(SecureLink.psk(forToken:)) ?? SecureLink.noPSK)
        return (phone, SecureLink(responder: SessionIdentity(), token: hostToken))
    }

    /// Runs the handshake; throws when a side refuses.
    private func connect(_ phone: SecureLink, _ host: SecureLink) throws {
        var toHost = try phone.start()
        while !toHost.isEmpty {
            let fromHost = try host.receive(toHost).reply
            toHost = fromHost.isEmpty ? Data() : try phone.receive(fromHost).reply
        }
    }

    func testBothSidesProveTheirKeysAndShareACode() throws {
        let (phone, host) = pair()
        try connect(phone, host)
        XCTAssertTrue(phone.isReady && host.isReady)
        XCTAssertEqual(phone.code, host.code)
        XCTAssertEqual(phone.code?.count, 6)
        XCTAssertEqual(host.mode, .invite)
        XCTAssertNotNil(host.remoteKey)
        XCTAssertNotEqual(host.remoteKey, phone.remoteKey)
    }

    func testMessagesTravelBothWaysAndAreNotInTheClear() throws {
        let (phone, host) = pair()
        try connect(phone, host)
        let secret = Data("moonlight on my new song".utf8)
        let wire = try phone.seal(secret)
        XCTAssertNil(wire.range(of: secret))
        XCTAssertEqual(try host.receive(wire).messages, [secret])
        XCTAssertEqual(try phone.receive(try host.seal(secret)).messages, [secret])
    }

    func testAWrongTokenNeverCompletes() throws {
        let (phone, host) = pair(phoneToken: "not-the-token-at-all")
        var thrown: Error?
        do { try connect(phone, host) } catch { thrown = error }
        XCTAssertEqual(thrown as? SecureLinkError, .authentication)
        XCTAssertFalse(host.isReady)
    }

    func testNearbyAgainstAnInviteSecretWorksWithoutTheToken() throws {
        // Nearby has no secret; the host just knows this phone came in that way, and has to approve it.
        let (phone, host) = pair(phoneToken: nil)
        try connect(phone, host)
        XCTAssertEqual(host.mode, .nearby)
    }

    func testChangingTheModeOnTheWayBreaksTheHandshake() throws {
        let (phone, host) = pair()
        var first = try phone.start()
        first[first.startIndex + 3] = JoinMode.nearby.rawValue
        var thrown: Error?
        do {
            let reply = try host.receive(first).reply
            _ = try phone.receive(reply)
        } catch { thrown = error }
        XCTAssertEqual(thrown as? SecureLinkError, .authentication)
    }

    func testAnyFlippedBitIsCaught() throws {
        let (phone, host) = pair()
        try connect(phone, host)
        var wire = try phone.seal(Data("a line".utf8))
        wire[wire.count - 1] ^= 1
        XCTAssertThrowsError(try host.receive(wire))
    }

    func testARecordCannotBeReplayedOrReordered() throws {
        let (phone, host) = pair()
        try connect(phone, host)
        let one = try phone.seal(Data("one".utf8))
        XCTAssertEqual(try host.receive(one).messages, [Data("one".utf8)])
        XCTAssertThrowsError(try host.receive(one), "replay")
        let (p2, h2) = pair()
        try connect(p2, h2)
        _ = try p2.seal(Data("skipped".utf8))
        XCTAssertThrowsError(try h2.receive(try p2.seal(Data("second".utf8))), "out of order")
    }

    func testBytesCanArriveOneAtATime() throws {
        let (phone, host) = pair()
        var hostOut = Data(), phoneOut = Data()
        for b in try phone.start() { hostOut += try host.receive(Data([b])).reply }
        for b in hostOut { phoneOut += try phone.receive(Data([b])).reply }
        for b in phoneOut { _ = try host.receive(Data([b])) }
        XCTAssertTrue(host.isReady)
        var got: [Data] = []
        for b in try phone.seal(Data("slowly".utf8)) { got += try host.receive(Data([b])).messages }
        XCTAssertEqual(got, [Data("slowly".utf8)])
    }

    func testOldPlainClientsAndGarbageAreRefused() throws {
        // A version 1 phone opened with a plain Hello frame: kind 1, then a length.
        let old = Message.hello(Hello(name: "x", device: "y", sampleRate: 48_000, headphones: false)).encoded()
        XCTAssertThrowsError(try SecureLink(responder: SessionIdentity(), token: "t").receive(old))
        XCTAssertThrowsError(try SecureLink(responder: SessionIdentity(), token: "t").receive(Data("GET / HTTP/1.1\r\n".utf8)))
        XCTAssertThrowsError(try SecureLink(responder: SessionIdentity(), token: "t").receive(Data([0x48, 0x4D, UInt8(Wire.version), 9])), "unknown mode")
    }

    func testOversizedLengthsAreRefusedBeforeAnyMemoryIsTaken() throws {
        let host = SecureLink(responder: SessionIdentity(), token: "t")
        XCTAssertThrowsError(try host.receive(Data([0x48, 0x4D, UInt8(Wire.version), 1, 0xFF, 0xFF])))
        let (phone, ready) = pair()
        try connect(phone, ready)
        XCTAssertThrowsError(try ready.receive(Data([0xFF, 0xFF, 0xFF, 0xFF])))
    }

    func testRevealMustMatchTheCommitment() throws {
        // The phone commits in message 1 to the value it reveals in message 3. One that changes it is refused.
        let host = SecureLink(responder: SessionIdentity(), token: "t")
        let identity = SessionIdentity()
        let header = Data([0x48, 0x4D, UInt8(Wire.version), JoinMode.nearby.rawValue])
        var noise = NoiseHandshake(role: .initiator, identity: identity, psk: SecureLink.noPSK, prologue: header)
        func framed(_ d: Data) -> Data { Data([UInt8(d.count >> 8), UInt8(d.count & 255)]) + d }
        let m1 = try noise.write(payload: Data(SHA256.hash(data: Data(repeating: 1, count: 32))))
        let reply = try host.receive(header + framed(m1)).reply
        _ = try noise.read(reply.dropFirst(2))
        let m3 = try noise.write(payload: Data(repeating: 2, count: 32))
        XCTAssertThrowsError(try host.receive(framed(m3))) { XCTAssertEqual($0 as? SecureLinkError, .commitment) }
        XCTAssertFalse(host.isReady)
    }

    /// Someone in the middle runs a handshake with each side. The codes come out different, because they
    /// had to commit before seeing the values that decide each code.
    func testAManInTheMiddleOnNearbyShowsDifferentCodes() throws {
        var matches = 0
        for _ in 0..<50 {
            let phone = SecureLink(initiator: SessionIdentity(), mode: .nearby, psk: SecureLink.noPSK)
            let fakeHost = SecureLink(responder: SessionIdentity(), token: "t")
            let fakePhone = SecureLink(initiator: SessionIdentity(), mode: .nearby, psk: SecureLink.noPSK)
            let host = SecureLink(responder: SessionIdentity(), token: "t")
            try connect(phone, fakeHost)
            try connect(fakePhone, host)
            if phone.code == host.code { matches += 1 }
        }
        XCTAssertEqual(matches, 0)
    }

    func testAManInTheMiddleOnAnInviteCannotFinish() throws {
        // Without the token the fake host can't get through message 3.
        let phone = SecureLink(initiator: SessionIdentity(), mode: .invite, psk: SecureLink.psk(forToken: "real-token-real-token"))
        let fakeHost = SecureLink(responder: SessionIdentity(), token: "guessed-token-guessed")
        XCTAssertThrowsError(try connect(phone, fakeHost))
        XCTAssertFalse(fakeHost.isReady)
    }

    func testDeviceComesFromTheKey() {
        let a = SessionIdentity()
        XCTAssertEqual(a.device, SessionIdentity.device(forPublicKey: a.publicKey))
        XCTAssertEqual(a.device.count, 32)
        XCTAssertNotEqual(a.device, SessionIdentity().device)
        XCTAssertEqual(SessionIdentity(rawRepresentation: a.rawRepresentation)?.device, a.device)
    }
}
