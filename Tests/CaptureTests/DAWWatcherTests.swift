import XCTest
@testable import Capture

final class FakeApps: RunningApplicationsSource {
    var runningBundleIDs: Set<String> = []
    var onChange: (() -> Void)?
    func set(_ ids: Set<String>) { runningBundleIDs = ids; onChange?() }
}

final class ManualScheduler: Scheduling {
    struct Job { let delay: Duration; let work: () -> Void; var cancelled = false }
    var jobs: [Job] = []
    func schedule(after delay: Duration, _ work: @escaping () -> Void) -> Cancellable {
        jobs.append(Job(delay: delay, work: work))
        let index = jobs.count - 1
        return BlockCancellable { [weak self] in self?.jobs[index].cancelled = true }
    }
    func fireAll() { for job in jobs where !job.cancelled { job.work() }; jobs.removeAll() }
}

final class DAWWatcherTests: XCTestCase {
    var apps: FakeApps!
    var scheduler: ManualScheduler!
    var events: [String]!
    var watcher: DAWWatcher!

    override func setUp() {
        apps = FakeApps()
        scheduler = ManualScheduler()
        events = []
        watcher = DAWWatcher(source: apps, catalog: .standard, scheduler: scheduler,
                             disarmGrace: .seconds(5),
                             onArm: { [unowned self] daw in events.append("arm:\(daw.name)") },
                             onDisarm: { [unowned self] in events.append("disarm") })
    }

    func testArmsWhenADAWLaunches() {
        watcher.start()
        apps.set(["com.ableton.live"])
        XCTAssertEqual(events, ["arm:Ableton Live"])
        XCTAssertTrue(watcher.isArmed)
    }

    func testIgnoresNonDAWApps() {
        watcher.start()
        apps.set(["com.apple.Safari", "com.spotify.client"])
        XCTAssertEqual(events, [])
    }

    func testArmsImmediatelyIfDAWAlreadyRunningAtStart() {
        apps.runningBundleIDs = ["com.apple.logic10"]
        watcher.start()
        XCTAssertEqual(events, ["arm:Logic Pro"])
    }

    func testDisarmWaitsForGracePeriod() {
        watcher.start()
        apps.set(["com.ableton.live"])
        apps.set([])
        XCTAssertEqual(events, ["arm:Ableton Live"], "must not disarm before the grace period")
        XCTAssertEqual(scheduler.jobs.first?.delay, .seconds(5))
        scheduler.fireAll()
        XCTAssertEqual(events, ["arm:Ableton Live", "disarm"])
        XCTAssertFalse(watcher.isArmed)
    }

    func testRelaunchWithinGraceCancelsDisarm() {
        watcher.start()
        apps.set(["com.ableton.live"])
        apps.set([])
        apps.set(["com.ableton.live"])
        scheduler.fireAll()
        XCTAssertEqual(events, ["arm:Ableton Live"])
        XCTAssertTrue(watcher.isArmed)
    }

    func testSecondDAWDoesNotReArm() {
        watcher.start()
        apps.set(["com.ableton.live"])
        apps.set(["com.ableton.live", "com.cockos.reaper"])
        XCTAssertEqual(events, ["arm:Ableton Live"])
    }

    func testVersionedBundleIDsMatch() {
        XCTAssertEqual(DAWCatalog.standard.match("com.steinberg.cubase14")?.name, "Cubase")
        XCTAssertEqual(DAWCatalog.standard.match("com.image-line.flstudio")?.name, "FL Studio")
        XCTAssertNil(DAWCatalog.standard.match("com.ableton.livestream"))
    }

    func testManualArmOverridesWithoutDAW() {
        watcher.start()
        watcher.armManually()
        XCTAssertEqual(events, ["arm:Manual"])
        apps.set(["com.apple.Safari"])
        scheduler.fireAll()
        XCTAssertTrue(watcher.isArmed, "manual arm stays on until the user turns it off")
    }
}

final class TurnOffStaysOffTests: XCTestCase {
    func testTurningOffWhileADAWRunsStaysOffUntilTheDAWQuits() {
        let apps = FakeApps(), scheduler = ManualScheduler()
        var events: [String] = []
        let watcher = DAWWatcher(source: apps, catalog: .standard, scheduler: scheduler, disarmGrace: .seconds(5),
                                 onArm: { events.append("arm:\($0.name)") }, onDisarm: { events.append("disarm") })
        watcher.start()
        apps.set(["com.ableton.live"])
        watcher.disarmManually()
        apps.set(["com.ableton.live", "com.apple.Safari"])          // any other app launches
        apps.set(["com.ableton.live"])                              // …or quits
        XCTAssertEqual(events, ["arm:Ableton Live", "disarm"], "stays off while Live keeps running")
        apps.set([])                                                // Live quits
        scheduler.fireAll()
        apps.set(["com.ableton.live"])                              // next time Live opens, auto-arm is back
        XCTAssertEqual(events.last, "arm:Ableton Live")
    }

    func testExtraBundleIDsAreRecognized() {
        let catalog = DAWCatalog.standard.adding(bundleIDs: ["com.renoise.renoise"])
        XCTAssertEqual(catalog.match("com.renoise.renoise")?.name, "com.renoise.renoise")
    }
}
