import Foundation
import Library
import Session
import SessionKit
import XCTest

/// The whole Mac side of a session against a simulated phone, over real sockets on this Mac: encrypted link →
/// the room → the singer's own pipeline → a take on disk. No audio device anywhere: the phone's "mic" is a
/// made-up melody, and the DAW's audio is silence written straight into the reference tap.
final class RoomSimulationTests: XCTestCase {
    private var folder: URL!
    private let rate = 48_000.0

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    /// A quiet room with someone singing a little tune in it, from 4 s to 8 s.
    private func melody(seconds: Double) -> [Float] {
        var rng = SystemRandomNumberGenerator()
        var out = (0..<Int(seconds * rate)).map { _ in Float.random(in: -0.0005...0.0005, using: &rng) }
        let notes = [220.0, 261.6, 293.7, 246.9], per = Int(0.5 * rate), start = Int(4 * rate)
        for i in 0..<Int(4 * rate) {
            let p = 2 * Double.pi * notes[(i / per) % notes.count] * Double(i) / rate
            out[start + i] += Float(0.2 * (sin(p) + 0.5 * sin(2 * p)) / 1.5)
        }
        return out
    }

    func testAPhoneJoinsWithTheQRCodeAndItsSingingBecomesATake() async throws {
        let tap = ReferenceTap(sampleRate: rate)
        let start = Date(), folder = self.folder!, rate = self.rate
        let host = RemoteSinger.Host(
            tap: tap, secondsAtFrameZero: { 0 }, positionAt: { _ in nil },
            makePipeline: { singer, startFrame in
                let p = try TakePipeline(folder: folder, sampleRate: rate, sessionStart: start.addingTimeInterval(Double(startFrame) / rate), daw: "Sim", jam: false)
                p.options = .captureOnly
                return p
            }, folder: folder)
        let room = Room(hostName: "Sim Mac", sessionName: "Sim", host: host, isTrusted: { _ in false }, identity: SessionIdentity(), onNetwork: false)

        let takes = TakeBox()
        let tookOne = XCTestExpectation(description: "take"); tookOne.assertForOverFulfill = false
        room.onTake = { takes.add($0); tookOne.fulfill() }
        let listening = XCTestExpectation(description: "invite"); listening.assertForOverFulfill = false
        let invite = InviteBox()
        let joinedOnHost = XCTestExpectation(description: "on the host's list"); joinedOnHost.assertForOverFulfill = false
        room.onChange = { snapshot in
            if let i = snapshot.invite { invite.set(i); listening.fulfill() }
            if snapshot.singers.contains(where: { $0.name == "Sim Phone" }) { joinedOnHost.fulfill() }
        }
        room.start()
        await fulfillment(of: [listening], timeout: 10)
        var join = try XCTUnwrap(invite.value)
        join.addresses = ["127.0.0.1"]
        join.service = nil

        let phone = SessionClient(name: "Sim Phone", identity: SessionIdentity(), sampleRate: rate, headphones: true)
        let joined = XCTestExpectation(description: "joined"); joined.assertForOverFulfill = false
        phone.onState = { if case .joined = $0 { joined.fulfill() } }
        phone.join(join)
        await fulfillment(of: [joined, joinedOnHost], timeout: 10)

        // 20 s of session, faster than real time: the DAW's silence into the tap, the phone's melody over the link,
        // told which session frame it was hearing (headphones mode).
        let singing = melody(seconds: 20)
        let chunk = Int(rate / 10)
        let silence = [Float](repeating: 0, count: chunk * 2)
        for k in 0..<(singing.count / chunk) {
            let at = Int64(k * chunk)
            silence.withUnsafeBufferPointer { tap.append($0, frames: chunk, at: at) }
            let piece = Array(singing[(k * chunk)..<((k + 1) * chunk)])
            phone.send(AudioPacket(firstFrame: UInt64(at), captureSeconds: Double(at) / rate, heardFrame: at, sampleRate: rate, samples: PCM16.encode(piece)))
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        phone.leave()
        try await Task.sleep(nanoseconds: 500_000_000)
        room.stop()
        await fulfillment(of: [tookOne], timeout: 30)

        let got = takes.value
        XCTAssertFalse(got.isEmpty)
        XCTAssertEqual(got.first?.singer, "Sim Phone")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertTrue(files.contains { $0.contains("by-Sim-Phone") && $0.hasSuffix("__voice.m4a") }, "\(files)")
    }

    func testAskingTheTapForAudioFromBeforeTheSessionIsSilenceNotACrash() {
        // Found by the simulated phone: singing right at the start of a session crashed the host.
        let tap = ReferenceTap(sampleRate: rate, seconds: 1)
        let frames = [Float](repeating: 0.5, count: 200)
        frames.withUnsafeBufferPointer { tap.append($0, frames: 100, at: 0) }
        let got = tap.stereo(from: -50, count: 100)
        XCTAssertEqual(got.count, 200)
        XCTAssertEqual(got[0], 0, "before the session")
        XCTAssertEqual(got[99], 0)
        XCTAssertEqual(got[100], 0.5, "from frame 0 on")
        XCTAssertEqual(tap.mono(from: -500, count: 100), [Float](repeating: 0, count: 100))
    }

    func testTheHostKeyStaysTheSameBetweenSessionsAndIsPrivate() throws {
        let url = folder.appendingPathComponent("deep/host.key")
        let first = HostIdentity.load(from: url)
        XCTAssertEqual(HostIdentity.load(from: url).publicKey, first.publicKey)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        try Data("junk".utf8).write(to: url)
        XCTAssertNotEqual(HostIdentity.load(from: url).publicKey, first.publicKey, "a damaged file starts over")
    }
}

private final class TakeBox: @unchecked Sendable {
    private let lock = NSLock(); private var takes: [TakeRecord] = []
    func add(_ t: TakeRecord) { lock.withLock { takes.append(t) } }
    var value: [TakeRecord] { lock.withLock { takes } }
}
private final class InviteBox: @unchecked Sendable {
    private let lock = NSLock(); private var invite: JoinInvite?
    func set(_ i: JoinInvite) { lock.withLock { invite = i } }
    var value: JoinInvite? { lock.withLock { invite } }
}
