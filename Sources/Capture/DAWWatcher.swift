import Foundation

/// Where the list of running apps comes from (NSWorkspace in the app, a fake in tests).
public protocol RunningApplicationsSource: AnyObject {
    var runningBundleIDs: Set<String> { get }
    var onChange: (() -> Void)? { get set }
}

public protocol Cancellable { func cancel() }

public struct BlockCancellable: Cancellable {
    let block: () -> Void
    public init(_ block: @escaping () -> Void) { self.block = block }
    public func cancel() { block() }
}

public protocol Scheduling {
    func schedule(after delay: Duration, _ work: @escaping () -> Void) -> Cancellable
}

/// Arms when any known DAW is running; disarms after a grace period once all have quit,
/// so a DAW crash-and-relaunch doesn't split a session. A manual arm sticks until turned off.
public final class DAWWatcher {
    public static let manual = DAWCatalog.Entry(name: "Manual", bundleID: "")

    public private(set) var isArmed = false
    public private(set) var activeDAW: DAWCatalog.Entry?

    private let source: RunningApplicationsSource
    public var catalog: DAWCatalog
    private let scheduler: Scheduling
    private let disarmGrace: Duration
    private let onArm: (DAWCatalog.Entry) -> Void
    private let onDisarm: () -> Void
    private var pendingDisarm: Cancellable? { didSet { onClosing?(pendingDisarm != nil) } }
    /// True while every DAW has quit and the session is about to end (the grace period).
    public var onClosing: ((Bool) -> Void)?
    private var manuallyArmed = false
    /// "Turn off" while a DAW is open means off for this DAW session; auto-arm returns once all DAWs quit.
    private var suppressedWhileDAWRuns = false

    public init(source: RunningApplicationsSource, catalog: DAWCatalog = .standard, scheduler: Scheduling,
                disarmGrace: Duration = .seconds(5),
                onArm: @escaping (DAWCatalog.Entry) -> Void, onDisarm: @escaping () -> Void) {
        self.source = source
        self.catalog = catalog
        self.scheduler = scheduler
        self.disarmGrace = disarmGrace
        self.onArm = onArm
        self.onDisarm = onDisarm
    }

    public func start() {
        source.onChange = { [weak self] in self?.evaluate() }
        evaluate()
    }

    public func armManually() {
        suppressedWhileDAWRuns = false
        manuallyArmed = true
        arm(activeDAW ?? Self.manual)
    }

    /// Re-check running apps now (e.g. after the DAW list changed).
    public func refresh() { evaluate() }

    /// Capture couldn't start: disarm without "turn off" semantics, so the next app change retries.
    public func disarmAfterFailure() {
        manuallyArmed = false
        pendingDisarm?.cancel()
        pendingDisarm = nil
        if isArmed { disarm() }
    }

    public func disarmManually() {
        manuallyArmed = false
        suppressedWhileDAWRuns = source.runningBundleIDs.contains { catalog.match($0) != nil }
        pendingDisarm?.cancel()
        pendingDisarm = nil
        if isArmed { disarm() }
    }

    private func evaluate() {
        if let daw = source.runningBundleIDs.lazy.compactMap(catalog.match).first {
            pendingDisarm?.cancel()
            pendingDisarm = nil
            if !suppressedWhileDAWRuns { arm(daw) }
        } else if suppressedWhileDAWRuns {
            suppressedWhileDAWRuns = false            // all DAWs gone: next launch auto-arms again
        } else if isArmed, !manuallyArmed, pendingDisarm == nil {
            pendingDisarm = scheduler.schedule(after: disarmGrace) { [weak self] in
                guard let self else { return }
                self.pendingDisarm = nil
                self.disarm()
            }
        }
    }

    private func arm(_ daw: DAWCatalog.Entry) {
        guard !isArmed else { return }
        isArmed = true
        activeDAW = daw
        onArm(daw)
    }

    private func disarm() {
        isArmed = false
        activeDAW = nil
        onDisarm()
    }
}
