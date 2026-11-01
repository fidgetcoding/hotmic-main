import AppKit

/// Live running-app list from NSWorkspace launch/terminate notifications.
public final class WorkspaceApplications: RunningApplicationsSource {
    public var onChange: (() -> Void)?
    private var observers: [NSObjectProtocol] = []

    public init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.onChange?()
            })
        }
    }

    deinit { observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver) }

    public var runningBundleIDs: Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }
}

/// Main-queue scheduler for the app.
public struct MainQueueScheduler: Scheduling {
    public init() {}
    public func schedule(after delay: Duration, _ work: @escaping () -> Void) -> Cancellable {
        let item = DispatchWorkItem(block: work)
        let (seconds, attoseconds) = delay.components
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(seconds) + Double(attoseconds) / 1e18, execute: item)
        return BlockCancellable { item.cancel() }
    }
}
