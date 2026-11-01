import AppKit
import XCTest
@testable import Overlay

final class HoverControllerTests: XCTestCase {
    func testExpandsOnHotZoneAndCollapsesOneSecondAfterLeaving() {
        var h = HoverController()
        XCTAssertEqual(h.update(mouseInHotZone: true, mouseInPanel: false, now: 0), .expanded)
        XCTAssertEqual(h.update(mouseInHotZone: false, mouseInPanel: true, now: 1), .expanded, "over the panel keeps it open")
        XCTAssertEqual(h.update(mouseInHotZone: false, mouseInPanel: false, now: 2), .expanded, "starts the 1 s grace")
        XCTAssertEqual(h.update(mouseInHotZone: false, mouseInPanel: false, now: 2.5), .expanded)
        XCTAssertEqual(h.update(mouseInHotZone: false, mouseInPanel: false, now: 3.01), .collapsed)
    }

    func testReturningDuringGraceCancelsCollapse() {
        var h = HoverController()
        h.update(mouseInHotZone: true, mouseInPanel: false, now: 0)
        h.update(mouseInHotZone: false, mouseInPanel: false, now: 1)
        h.update(mouseInHotZone: false, mouseInPanel: true, now: 1.5)
        XCTAssertEqual(h.update(mouseInHotZone: false, mouseInPanel: true, now: 5), .expanded)
    }

    func testPanelAloneDoesNotExpandFromCollapsed() {
        var h = HoverController()
        XCTAssertEqual(h.update(mouseInHotZone: false, mouseInPanel: true, now: 0), .collapsed)
    }
}

final class OverlaySettingsTests: XCTestCase {
    func testRoundTripsAndIdleAlpha() {
        let defaults = UserDefaults(suiteName: "hm-test-\(UUID())")!
        XCTAssertEqual(OverlaySettings.load(defaults), OverlaySettings(), "ghost by default")
        var s = OverlaySettings()
        s.idleMode = .invisible; s.ghostOpacity = 0.3; s.position = .bottomRight; s.flashOnTake = false
        s.save(defaults)
        XCTAssertEqual(OverlaySettings.load(defaults), s)
        XCTAssertEqual(s.idleAlpha, 0)
        XCTAssertEqual(OverlaySettings().idleAlpha, 0.15)
    }
}

final class OverlayPanelTests: XCTestCase {
    func testPanelCanNeverTakeFocusFromTheDAW() {
        let panel = OverlayPanel()
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(panel.ignoresMouseEvents, "click-through until hovered")
    }
}

final class OverlayStateTests: XCTestCase {
    func testKeepsLastThreeTakesNewestFirstAndPulses() {
        let state = OverlayState()
        for i in 1...4 {
            let url = URL(fileURLWithPath: "/tmp/\(i).m4a")
            state.add(OverlayTake(id: "\(i)", title: "\(i)", seconds: i, voiceURL: url, mixURL: url))
        }
        XCTAssertEqual(state.takes.map(\.id), ["4", "3", "2"])
        XCTAssertEqual(state.pulse, 4)
    }
}
