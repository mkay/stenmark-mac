// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

#if DEBUG
import Foundation

/// Phase 0: how should a save work inside the Nextcloud folder? Tries each
/// method from the signed app in a test folder and reports what happened to
/// the file. `directory` must be a throwaway folder made for this.
@MainActor enum SaveProbe {
    private static var report = ""

    private static func say(_ line: String) {
        report += line + "\n"
    }

    private static func describe(_ url: URL) -> String {
        guard let values = try? FileManager.default.attributesOfItem(atPath: url.path) else { return "missing" }
        let inode = values[.systemFileNumber] as? Int ?? -1
        let size = values[.size] as? Int ?? -1
        let attributes = listxattr(url.path, nil, 0, 0)
        return "inode=\(inode) size=\(size) xattrBytes=\(attributes)"
    }

    private static func listing(_ directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.sorted() ?? ["<unreadable>"]
    }

    private static func attempt(_ name: String, in directory: URL, _ write: (URL, Data) throws -> Void) {
        let file = directory.appendingPathComponent("\(name).md")
        let first = Data("first version\n".utf8)
        let second = Data("second version, a little longer\n".utf8)
        do {
            try first.write(to: file)
            let before = describe(file)
            let start = Date()
            try write(file, second)
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            let matches = (try? Data(contentsOf: file)) == second
            say("\(name): ok \(elapsed)ms content=\(matches ? "right" : "WRONG")")
            say("  before \(before)")
            say("  after  \(describe(file))")
        } catch {
            say("\(name): FAILED \(error)")
        }
    }

    static func run(in directory: URL) async {
        say("readable: \(listing(directory))")

        attempt("in-place", in: directory) { file, data in
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: data)
            try handle.close()
        }
        attempt("atomic", in: directory) { file, data in
            try data.write(to: file, options: .atomic)
        }
        attempt("replace-item", in: directory) { file, data in
            let scratch = try FileManager.default.url(
                for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: file, create: true)
            let temporary = scratch.appendingPathComponent(file.lastPathComponent)
            try data.write(to: temporary)
            _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
            try? FileManager.default.removeItem(at: scratch)
        }
        attempt("coordinated-atomic", in: directory) { file, data in
            var coordinationError: NSError?
            var writeError: Error?
            NSFileCoordinator().coordinate(writingItemAt: file, options: .forReplacing, error: &coordinationError) { url in
                do { try data.write(to: url, options: .atomic) } catch { writeError = error }
            }
            if let failure = coordinationError ?? writeError { throw failure }
        }

        say("after saves: \(listing(directory))")
        for seconds in [5, 15, 30] {
            try? await Task.sleep(for: .seconds(seconds))
            say("+\(seconds)s: \(listing(directory))")
        }
        let out = directory.deletingLastPathComponent().appendingPathComponent("stenmark-save-probe.txt")
        let target = ProcessInfo.processInfo.environment["STENMARK_PROBE_OUT"].map(URL.init(fileURLWithPath:)) ?? out
        try? report.write(to: target, atomically: true, encoding: .utf8)
    }
}
#endif
