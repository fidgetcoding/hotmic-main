import Foundation
import UniformTypeIdentifiers
import WebKit

/// The rules for `hotmic-media://library/<absolute path>`: how the window's page reaches audio in the
/// library without read access to the rest of the disk.
public enum LibraryMedia {
    public static let scheme = "hotmic-media"
    static let host = "library"
    static let audioExtensions: Set<String> = ["m4a", "aac", "mp3", "mp4", "wav", "aif", "aiff", "caf", "flac"]

    /// The file a URL names, or nil unless it is an audio file inside `root` (symlinks resolved first).
    public static func resolve(_ url: URL, root: URL) -> URL? {
        guard url.scheme == scheme, url.host == host else { return nil }
        let file = URL(fileURLWithPath: url.path).standardizedFileURL.resolvingSymlinksInPath()
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard file.path.hasPrefix(base + "/"), audioExtensions.contains(file.pathExtension.lowercased()) else { return nil }
        return file
    }

    public enum Span: Equatable {
        case whole
        case part(ClosedRange<Int64>)
        case unsatisfiable
    }

    /// One `Range: bytes=…` header against a file of `size` bytes. Anything else is the whole file.
    public static func span(header: String?, size: Int64) -> Span {
        guard let header, header.hasPrefix("bytes="), !header.contains(",") else { return .whole }
        let parts = header.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return .whole }
        if parts[0].isEmpty {                                  // bytes=-500: the last 500
            guard let tail = Int64(parts[1]), tail > 0, size > 0 else { return .unsatisfiable }
            return .part(max(0, size - tail)...(size - 1))
        }
        guard let start = Int64(parts[0]), start >= 0 else { return .whole }
        guard start < size else { return .unsatisfiable }
        let end = parts[1].isEmpty ? size - 1 : (Int64(parts[1]) ?? size - 1)
        guard end >= start else { return .whole }
        return .part(start...min(end, size - 1))
    }
}

/// Serves library audio to the web view, with the byte ranges the media stack asks for.
public final class LibraryMediaSchemeHandler: NSObject, WKURLSchemeHandler {
    private let root: () -> URL?
    private let queue = DispatchQueue(label: "io.bluegum.hotmic.media", qos: .userInitiated)
    private var active = Set<ObjectIdentifier>()
    private static let chunk = 256 * 1024

    /// `root` is asked per request (main thread), so a newly chosen library applies at once.
    public init(root: @escaping () -> URL?) { self.root = root }

    public func webView(_ webView: WKWebView, start task: WKURLSchemeTask) { start(task) }
    public func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) { stop(task) }

    public func stop(_ task: WKURLSchemeTask) { active.remove(ObjectIdentifier(task)) }

    public func start(_ task: WKURLSchemeTask) {
        guard let url = task.request.url, let root = root(), let file = LibraryMedia.resolve(url, root: root),
              let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int64 else {
            respond(task, url: task.request.url, status: 404, headers: [:])
            task.didFinish()
            return
        }
        let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        var headers = ["Accept-Ranges": "bytes", "Content-Type": type]
        let range: ClosedRange<Int64>
        switch LibraryMedia.span(header: task.request.value(forHTTPHeaderField: "Range"), size: size) {
        case .unsatisfiable:
            respond(task, url: url, status: 416, headers: ["Content-Range": "bytes */\(size)"])
            task.didFinish()
            return
        case .whole:
            range = 0...max(0, size - 1)
            headers["Content-Length"] = String(size)
            respond(task, url: url, status: 200, headers: headers)
        case let .part(part):
            range = part
            headers["Content-Length"] = String(part.count)
            headers["Content-Range"] = "bytes \(part.lowerBound)-\(part.upperBound)/\(size)"
            respond(task, url: url, status: 206, headers: headers)
        }
        let id = ObjectIdentifier(task)
        active.insert(id)
        let empty = size == 0
        queue.async { [self] in
            var failure: Error?
            do {
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(range.lowerBound))
                var left = empty ? 0 : Int(range.upperBound - range.lowerBound + 1)
                while left > 0 {
                    guard let data = try handle.read(upToCount: min(Self.chunk, left)), !data.isEmpty else { break }
                    left -= data.count
                    // One chunk at a time, on the main thread, and only while the page still wants it.
                    let wanted = DispatchQueue.main.sync {
                        MainActor.assumeIsolated {
                            guard active.contains(id) else { return false }
                            task.didReceive(data)
                            return true
                        }
                    }
                    guard wanted else { return }
                }
            } catch {
                failure = error
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard active.remove(id) != nil else { return }
                    if let failure { task.didFailWithError(failure) } else { task.didFinish() }
                }
            }
        }
    }

    private func respond(_ task: WKURLSchemeTask, url: URL?, status: Int, headers: [String: String]) {
        let url = url ?? URL(string: "\(LibraryMedia.scheme)://\(LibraryMedia.host)/")!
        task.didReceive(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }
}
