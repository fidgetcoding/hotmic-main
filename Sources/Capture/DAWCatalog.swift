/// Music software that arms Hot Mic. Matches exact bundle IDs and versioned variants
/// ("com.steinberg.cubase" matches "com.steinberg.cubase14", "…cubase.pro"), never look-alikes.
public struct DAWCatalog: Sendable {
    public struct Entry: Sendable, Equatable {
        public let name: String
        public let bundleID: String
        /// User-added entries match exactly (no versioned-prefix matching).
        public let exact: Bool
        public init(name: String, bundleID: String, exact: Bool = false) { self.name = name; self.bundleID = bundleID; self.exact = exact }
    }

    public let entries: [Entry]
    public init(entries: [Entry]) { self.entries = entries }

    /// Verified on this machine 2026-09-27: Ableton Live, FL Studio. Others from vendor conventions.
    public static let standard = DAWCatalog(entries: [
        Entry(name: "Ableton Live", bundleID: "com.ableton.live"),
        Entry(name: "Logic Pro", bundleID: "com.apple.logic"),
        Entry(name: "GarageBand", bundleID: "com.apple.garageband"),
        Entry(name: "FL Studio", bundleID: "com.image-line.flstudio"),
        Entry(name: "Bitwig Studio", bundleID: "com.bitwig.BitwigStudio"),
        Entry(name: "REAPER", bundleID: "com.cockos.reaper"),
        Entry(name: "Cubase", bundleID: "com.steinberg.cubase"),
        Entry(name: "Studio One", bundleID: "com.presonus.studioone"),
    ])

    /// A plausible reverse-DNS bundle ID (at least three parts, no spaces), e.g. com.renoise.renoise.
    public static func isValidBundleID(_ id: String) -> Bool {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 3 && parts.allSatisfy { !$0.isEmpty } && !id.contains(" ") && id.count >= 8
    }

    /// Adds user-supplied bundle IDs (Settings → DAWs), matched exactly and named by their bundle ID.
    public func adding(bundleIDs: [String]) -> DAWCatalog {
        let extra = bundleIDs.map { $0.trimmingCharacters(in: .whitespaces) }.filter(Self.isValidBundleID)
            .map { Entry(name: $0, bundleID: $0, exact: true) }
        return DAWCatalog(entries: entries + extra)
    }

    public func match(_ bundleID: String) -> Entry? {
        entries.first { entry in
            if entry.exact { return bundleID == entry.bundleID }
            guard bundleID.hasPrefix(entry.bundleID) else { return false }
            let rest = bundleID.dropFirst(entry.bundleID.count)
            return rest.isEmpty || rest.hasPrefix(".") || rest.allSatisfy(\.isNumber)
        }
    }
}
