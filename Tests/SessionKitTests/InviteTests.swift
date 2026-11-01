import SessionKit
import XCTest

final class InviteTests: XCTestCase {
    private func invite(addr: String) -> JoinInvite? {
        JoinInvite(url: URL(string: "hotmic://join?name=Host&addr=\(addr)&port=51234&token=abcdefghijklmnop")!)
    }

    func testPrivateAddressesJoin() {
        for address in ["10.0.0.4", "172.16.0.1", "172.20.10.2", "172.31.255.1", "192.168.1.20"] {
            XCTAssertEqual(invite(addr: address)?.addresses, [address])
        }
    }

    func testPublicAddressesAreRefused() {
        for address in ["8.8.8.8", "172.15.0.1", "172.32.0.1", "192.167.1.1", "100.64.0.1", "127.0.0.1", "169.254.1.1"] {
            XCTAssertNil(invite(addr: address), address)
        }
    }

    func testAddressesThatParseOddlyAreRefused() {
        for address in ["010.0.0.1", "10.0.0", "10.0.0.1.5", "+10.0.0.1", "10.0.0.256", "10.0.0.x", "example.com"] {
            XCTAssertNil(invite(addr: address), address)
        }
    }

    func testPublicAddressesDropOutOfAMixedList() {
        XCTAssertEqual(invite(addr: "8.8.8.8,192.168.1.20")?.addresses, ["192.168.1.20"])
    }

    func testBonjourNameStillJoinsWithoutAnAddress() {
        let url = URL(string: "hotmic://join?name=Host&service=Host&port=51234&token=abcdefghijklmnop")!
        XCTAssertEqual(JoinInvite(url: url)?.service, "Host")
    }

    func testAnInviteRoundTrips() {
        let original = JoinInvite(hostName: "Host", service: "Host", addresses: ["192.168.1.20"], port: 51234, token: "abcdefghijklmnop")
        XCTAssertEqual(JoinInvite(url: original.url), original)
    }
}
