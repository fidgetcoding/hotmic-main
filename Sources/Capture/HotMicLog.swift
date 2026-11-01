import Foundation

/// ~/Library/Logs/Hot Mic/hotmic.log: what capture and the take pipeline decided, line by line.
/// NSLog from this app doesn't reach the unified log, so problems in a real session are read here.
public enum HotMicLog {
    private static let queue = DispatchQueue(label: "io.bluegum.hotmic.log", qos: .utility)
    public static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Hot Mic/hotmic.log")

    public static func write(_ line: String) {
        let text = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        queue.async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close() }
            else { try? Data(text.utf8).write(to: url) }
        }
    }
}
