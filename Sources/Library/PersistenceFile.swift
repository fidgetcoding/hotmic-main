import Capture
import Foundation

/// A failed read, encode or atomic write. Diagnostics identify the file and error code, never its lyrics.
public struct PersistenceFailure: Error, CustomStringConvertible {
    public let operation: String
    public let file: URL
    public let underlying: Error

    public var description: String {
        let error = underlying as NSError
        return "persistence \(operation) failed for \(file.lastPathComponent): \(error.domain) (\(error.code))"
    }
}

/// Shared only by the live-line and judge stores. Missing files start empty; damaged/inaccessible
/// files do not. Callers hold their store's transaction lock across read, mutation and write.
enum PersistenceFile {
    private static func missing(_ error: Error) -> Bool {
        let e = error as NSError
        return e.domain == NSCocoaErrorDomain &&
            [CocoaError.fileReadNoSuchFile.rawValue, CocoaError.fileNoSuchFile.rawValue].contains(e.code)
    }

    private static func perform<T>(_ operation: String, at url: URL, _ work: () throws -> T) throws -> T {
        do { return try work() }
        catch {
            let failure = PersistenceFailure(operation: operation, file: url, underlying: error)
            HotMicLog.write(failure.description)
            throw failure
        }
    }

    static func read<T: Decodable>(_ url: URL, default value: @autoclosure () -> T) throws -> T {
        try perform("read", at: url) {
            let data: Data
            do { data = try Data(contentsOf: url) }
            catch {
                if missing(error) {
                    // A dangling symlink is an existing entry, not a new store. Attributes inspect
                    // the entry itself, so it cannot be silently replaced after a failed target read.
                    do { _ = try FileManager.default.attributesOfItem(atPath: url.path) }
                    catch let probe { if missing(probe) { return value() } }
                }
                throw error
            }
            return try JSONDecoder().decode(T.self, from: data)
        }
    }

    static func write<T: Encodable>(_ value: T, to url: URL, pretty: Bool = false) throws {
        let data = try perform("encode", at: url) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
            return try encoder.encode(value)
        }
        try perform("write", at: url) { try data.write(to: url, options: .atomic) }
    }
}
