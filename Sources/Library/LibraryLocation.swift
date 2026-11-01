import Foundation

/// Where sessions and takes live. Default = iCloud Drive (spec: sync = the user's own cloud folder),
/// falling back to ~/Music when iCloud Drive isn't set up. The user can pick any folder
/// (Dropbox, Google Drive, a NAS…).
public struct LibraryLocation: Equatable, Sendable {
    public static let folderName = "Hot Mic"
    public var root: URL

    public init(root: URL) { self.root = root }

    public var sessions: URL { root.appendingPathComponent("Sessions", isDirectory: true) }

    public static func defaultLocation(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                       fileManager: FileManager = .default) -> LibraryLocation {
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: iCloud.path, isDirectory: &isDir), isDir.boolValue {
            return LibraryLocation(root: iCloud.appendingPathComponent(folderName, isDirectory: true))
        }
        return LibraryLocation(root: home.appendingPathComponent("Music/\(folderName)", isDirectory: true))
    }

    /// The saved choice, or the default.
    public static func current(_ defaults: UserDefaults = .standard) -> LibraryLocation {
        if let path = defaults.string(forKey: "library.root") { return LibraryLocation(root: URL(fileURLWithPath: path, isDirectory: true)) }
        return defaultLocation()
    }

    public func save(_ defaults: UserDefaults = .standard) { defaults.set(root.path, forKey: "library.root") }
}

/// Keeps the library small: the whole-session recordings (the big files) expire after `days`;
/// takes, MIDI and sidecars are kept forever.
public struct Retention: Sendable {
    /// Whole-session recordings are `session__voice_NNN.m4a` / `session__mix_NNN.m4a` segments.
    public static let sessionFilePrefixes = ["session__voice", "session__mix"]
    public static func isSessionFile(_ name: String) -> Bool {
        name.hasSuffix(".m4a") && sessionFilePrefixes.contains { name.hasPrefix($0) }
    }
    public var days: Int

    public init(days: Int = 14) { self.days = days }

    public static func current(_ defaults: UserDefaults = .standard) -> Retention {
        let d = defaults.integer(forKey: "library.retentionDays")
        return Retention(days: d > 0 ? d : 14)
    }

    /// Deletes expired session recordings under `sessions`. Returns the files removed.
    @discardableResult
    public func sweep(_ sessions: URL, now: Date = Date(), fileManager: FileManager = .default) -> [URL] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        guard let folders = try? fileManager.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil) else { return [] }
        var removed: [URL] = []
        for folder in folders {
            let names = ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []).filter(Self.isSessionFile)
            for name in names {
                let file = folder.appendingPathComponent(name)
                guard let modified = (try? fileManager.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date,
                      modified < cutoff else { continue }
                if (try? fileManager.removeItem(at: file)) != nil { removed.append(file) }
            }
        }
        return removed
    }
}
