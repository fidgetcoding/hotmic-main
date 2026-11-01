import WebKit
import XCTest
@testable import MediaScheme

final class LibraryMediaRulesTests: XCTestCase {
    private func url(_ path: String) -> URL { URL(string: "hotmic-media://library\(path)")! }
    private let root = URL(fileURLWithPath: "/Users/someone/Music/Hot Mic", isDirectory: true)

    func testServesAudioInsideTheLibrary() {
        let file = LibraryMedia.resolve(url("/Users/someone/Music/Hot%20Mic/Sessions/a/session__voice_001.m4a"), root: root)
        XCTAssertEqual(file?.lastPathComponent, "session__voice_001.m4a")
    }

    func testRefusesAnythingOutsideTheLibrary() {
        XCTAssertNil(LibraryMedia.resolve(url("/Users/someone/secret.m4a"), root: root))
        XCTAssertNil(LibraryMedia.resolve(url("/Users/someone/Music/Hot%20Mic/../secret.m4a"), root: root))
        XCTAssertNil(LibraryMedia.resolve(url("/Users/someone/Music/Hot%20Mic/%2E%2E/secret.m4a"), root: root))
        XCTAssertNil(LibraryMedia.resolve(url("/Users/someone/Music/Hot%20Mic%20Other/a.m4a"), root: root), "a sibling with the same prefix")
    }

    func testRefusesFilesThatArentAudio() {
        XCTAssertNil(LibraryMedia.resolve(url("/Users/someone/Music/Hot%20Mic/Sessions/a/take.json"), root: root))
        XCTAssertNil(LibraryMedia.resolve(url("/Users/someone/Music/Hot%20Mic/Your%20words.txt"), root: root))
    }

    func testRefusesOtherHostsAndSchemes() {
        XCTAssertNil(LibraryMedia.resolve(URL(string: "hotmic-media://other/Users/someone/Music/Hot%20Mic/a.m4a")!, root: root))
        XCTAssertNil(LibraryMedia.resolve(URL(string: "file:///Users/someone/Music/Hot%20Mic/a.m4a")!, root: root))
    }

    func testRefusesASymlinkThatLeavesTheLibrary() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let library = base.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let outside = base.appendingPathComponent("outside.m4a")
        try Data([1]).write(to: outside)
        try FileManager.default.createSymbolicLink(at: library.appendingPathComponent("link.m4a"), withDestinationURL: outside)
        XCTAssertNil(LibraryMedia.resolve(url(library.appendingPathComponent("link.m4a").path), root: library))
    }

    func testEveryServedFileHasAPlayableType() {
        for ext in LibraryMedia.audioExtensions {
            XCTAssertTrue(LibraryMedia.type(of: URL(fileURLWithPath: "/a.\(ext)")).hasPrefix("audio/"), ext)
        }
        XCTAssertEqual(LibraryMedia.type(of: URL(fileURLWithPath: "/a.M4A")), "audio/mp4", "case doesn't matter")
    }

    func testRanges() {
        XCTAssertEqual(LibraryMedia.span(header: nil, size: 100), .whole)
        XCTAssertEqual(LibraryMedia.span(header: "bytes=0-1", size: 100), .part(0...1))
        XCTAssertEqual(LibraryMedia.span(header: "bytes=10-", size: 100), .part(10...99))
        XCTAssertEqual(LibraryMedia.span(header: "bytes=90-500", size: 100), .part(90...99))
        XCTAssertEqual(LibraryMedia.span(header: "bytes=-10", size: 100), .part(90...99))
        XCTAssertEqual(LibraryMedia.span(header: "bytes=100-", size: 100), .unsatisfiable)
        XCTAssertEqual(LibraryMedia.span(header: "bytes=0-1,5-6", size: 100), .whole)
        XCTAssertEqual(LibraryMedia.span(header: "items=0-1", size: 100), .whole)
        XCTAssertEqual(LibraryMedia.span(header: "bytes=99-99", size: 100), .part(99...99), "the last byte, as a seek to the end asks")
        XCTAssertEqual(LibraryMedia.span(header: "bytes=-500", size: 100), .part(0...99), "a tail longer than the file")
        XCTAssertEqual(LibraryMedia.span(header: "bytes=-0", size: 100), .unsatisfiable)
        XCTAssertEqual(LibraryMedia.span(header: "bytes=0-", size: 0), .unsatisfiable, "an empty file")
        XCTAssertEqual(LibraryMedia.span(header: "bytes=5-3", size: 100), .whole, "an impossible range is ignored")
    }
}

@MainActor
final class LibraryMediaHandlerTests: XCTestCase {
    private final class FakeTask: NSObject, WKURLSchemeTask {
        let request: URLRequest
        var response: HTTPURLResponse?
        var body = Data()
        var finished: XCTestExpectation?
        init(_ request: URLRequest) { self.request = request }
        func didReceive(_ response: URLResponse) { self.response = response as? HTTPURLResponse }
        func didReceive(_ data: Data) { body.append(data) }
        func didFinish() { finished?.fulfill() }
        func didFailWithError(_ error: Error) { XCTFail("\(error)"); finished?.fulfill() }
    }

    private var library: URL!

    override func setUp() async throws {
        library = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try Data((0..<255).map { UInt8($0) }).write(to: library.appendingPathComponent("take a.m4a"))
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: library) }

    private func run(_ path: String, range: String? = nil) async -> FakeTask {
        var request = URLRequest(url: URL(string: "hotmic-media://library\(path)")!)
        request.setValue(range, forHTTPHeaderField: "Range")
        let task = FakeTask(request), done = expectation(description: "finished")
        task.finished = done
        let root = library
        LibraryMediaSchemeHandler { root }.start(task)
        await fulfillment(of: [done], timeout: 5)
        return task
    }

    private var takePath: String { library.appendingPathComponent("take a.m4a").path.replacingOccurrences(of: " ", with: "%20") }

    func testWholeFile() async {
        let task = await run(takePath)
        XCTAssertEqual(task.response?.statusCode, 200)
        XCTAssertEqual(task.response?.value(forHTTPHeaderField: "Accept-Ranges"), "bytes")
        XCTAssertEqual(task.response?.value(forHTTPHeaderField: "Content-Length"), "255")
        XCTAssertEqual(task.body.count, 255)
    }

    func testPartialFile() async {
        let task = await run(takePath, range: "bytes=10-19")
        XCTAssertEqual(task.response?.statusCode, 206)
        XCTAssertEqual(task.response?.value(forHTTPHeaderField: "Content-Range"), "bytes 10-19/255")
        XCTAssertEqual([UInt8](task.body), (10...19).map { UInt8($0) })
    }

    func testTheFirstProbeAndASeekAnswerLikeAServer() async {
        // What the media stack asks first (two bytes), then a seek to the tail.
        let probe = await run(takePath, range: "bytes=0-1")
        XCTAssertEqual(probe.response?.statusCode, 206)
        XCTAssertEqual(probe.response?.value(forHTTPHeaderField: "Content-Type"), "audio/mp4")
        XCTAssertEqual(probe.response?.value(forHTTPHeaderField: "Content-Length"), "2")
        XCTAssertEqual(probe.response?.value(forHTTPHeaderField: "Content-Range"), "bytes 0-1/255")
        XCTAssertEqual(probe.body.count, 2)
        let seek = await run(takePath, range: "bytes=200-")
        XCTAssertEqual(seek.response?.value(forHTTPHeaderField: "Content-Range"), "bytes 200-254/255")
        XCTAssertEqual([UInt8](seek.body), (200...254).map { UInt8($0) })
    }

    func testOutsideTheLibraryIsNotFound() async {
        let task = await run("/etc/hosts.m4a")
        XCTAssertEqual(task.response?.statusCode, 404)
        XCTAssertTrue(task.body.isEmpty)
    }

    func testRangePastTheEnd() async {
        let task = await run(takePath, range: "bytes=500-")
        XCTAssertEqual(task.response?.statusCode, 416)
        XCTAssertEqual(task.response?.value(forHTTPHeaderField: "Content-Range"), "bytes */255")
    }
}
