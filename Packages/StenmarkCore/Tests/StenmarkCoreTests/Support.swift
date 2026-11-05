// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// A throwaway folder with symlinks resolved, so that paths compare equal to
/// the ones FSEvents reports.
final class TemporaryFolder {
    let url: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        url = base.appending(path: "stenmark-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func write(_ text: String, to name: String) throws -> URL {
        let file = url.appending(path: name)
        let folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Through POSIX, because Foundation would change the form of the name.
        let last = name.split(separator: "/").last.map(String.init) ?? name
        let descriptor = open(folder.path + "/" + last, O_CREAT | O_TRUNC | O_WRONLY, 0o644)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
        return file
    }

    /// Replaces a file the way a sync client does: a new file renamed over it.
    func syncReplace(_ file: URL, with text: String) throws {
        let incoming = url.appending(path: ".incoming-\(UUID().uuidString)")
        try Data(text.utf8).write(to: incoming)
        guard rename(incoming.path, file.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Entry names as raw bytes, straight from readdir. FileManager and Swift's
    /// String equality could both hide a change of Unicode form.
    func rawNames() -> [[UInt8]] {
        guard let directory = opendir(url.path) else { return [] }
        defer { closedir(directory) }
        var names: [[UInt8]] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(Array(name.utf8)) }
        }
        return names
    }
}
