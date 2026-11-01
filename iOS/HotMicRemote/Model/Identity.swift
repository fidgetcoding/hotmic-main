import Foundation
import Security
import SessionKit

/// Who this phone is to the host: a private key that stays in this phone's Keychain. The host remembers
/// the key, so a producer who ticked "always allow" isn't asked again, a dropped connection resumes
/// the same singer, and nobody who sniffs the network can pass for this phone.
enum Identity {
    private static let keyTag = "io.bluegum.hotmic.identity"
    private static let nameKey = "hotmic.singerName"

    static let session: SessionIdentity = {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: keyTag]
        var found: CFTypeRef?
        var lookup = query
        lookup[kSecReturnData as String] = true
        if SecItemCopyMatching(lookup as CFDictionary, &found) == errSecSuccess, let data = found as? Data,
           let saved = SessionIdentity(rawRepresentation: data) { return saved }
        let fresh = SessionIdentity()
        var add = query
        add[kSecValueData as String] = fresh.rawRepresentation
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemDelete(query as CFDictionary)
        SecItemAdd(add as CFDictionary, nil)
        return fresh
    }()

    /// Empty until the singer types one: iOS no longer reveals the real device name to apps.
    static var name: String {
        get { UserDefaults.standard.string(forKey: nameKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: nameKey) }
    }
}

/// Hosts this phone has joined, name → public key: a Nearby host answering with another key is refused.
final class SavedHostKeys: HostKeyStore, @unchecked Sendable {
    private let defaultsKey = "hotmic.hostKeys"
    func key(forHost name: String) -> Data? { (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data])?[name] }
    func remember(_ key: Data, forHost name: String) {
        var all = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data]) ?? [:]
        all[name] = key
        UserDefaults.standard.set(all, forKey: defaultsKey)
    }
}
