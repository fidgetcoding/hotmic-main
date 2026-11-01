// hotmic-export: turns a real Hot Mic session folder into a session file for the design lab.
// Usage: swift run hotmic-export "<session folder>" [<out.js>]
// Uses the same export as the app's window (LabSessionExport → the app's own Notebook).
import Foundation
import Library

let args = CommandLine.arguments
guard args.count >= 2 else { FileHandle.standardError.write("usage: hotmic-export <session folder> [out.js]\n".data(using: .utf8)!); exit(2) }
let folder = URL(fileURLWithPath: args[1], isDirectory: true)
let session = LabSessionExport.session(folder: folder)
guard !session.takes.isEmpty else { FileHandle.standardError.write("no takes found in \(folder.path)\n".data(using: .utf8)!); exit(1) }
let js = "window.HM_SESSION = \(LabSessionExport.json(session));\n"
if args.count >= 3 {
    try js.write(toFile: args[2], atomically: true, encoding: .utf8)
    print("wrote \(args[2]) · \(session.takes.count) takes · \(session.slots.count) lines")
} else { print(js) }
