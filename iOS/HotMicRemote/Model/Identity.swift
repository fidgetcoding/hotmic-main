import Foundation

/// Who this phone is to the host. The device id survives relaunches so a producer who ticked
/// "always allow" isn't asked again, and a dropped connection resumes the same singer.
enum Identity {
    private static let deviceKey = "hotmic.deviceID"
    private static let nameKey = "hotmic.singerName"

    static var device: String {
        if let saved = UserDefaults.standard.string(forKey: deviceKey), !saved.isEmpty { return saved }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: deviceKey)
        return fresh
    }

    /// Empty until the singer types one: iOS no longer reveals the real device name to apps.
    static var name: String {
        get { UserDefaults.standard.string(forKey: nameKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: nameKey) }
    }
}
