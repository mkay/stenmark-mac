// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

#if DEBUG
import Foundation
import StenmarkCore

/// Runs the real save path in a real synced folder, from the signed app.
/// `directory` must be a throwaway folder holding `probe.md` and `Müller.md`.
@MainActor enum SaveProbe {
    static func run(in directory: URL, reportingTo path: String) async {
        var report = ""
        func step(_ name: String, _ work: () throws -> String) {
            do {
                report += "\(name): \(try work())\n"
            } catch {
                report += "\(name): FAILED \(error.localizedDescription)\n"
            }
        }
        func outcome(_ result: SaveOutcome) -> String {
            switch result {
            case .saved: "saved"
            case .unchanged: "unchanged"
            case .conflict: "conflict"
            case .removed: "removed"
            }
        }

        let file = directory.appending(path: "probe.md")
        let umlaut = directory.appending(path: "M\u{00FC}ller.md")

        step("edit") {
            let note = try NoteFile.load(file)
            return outcome(try NoteFile.save("edited\n", to: file, format: note.format, expecting: note.fingerprint))
        }
        try? await Task.sleep(for: .seconds(4))
        step("no edit") {
            let note = try NoteFile.load(file)
            return outcome(try NoteFile.save(note.text, to: file, format: note.format, expecting: note.fingerprint))
        }
        step("stale copy") {
            let note = try NoteFile.load(file)
            _ = try NoteFile.overwrite(file, with: "someone else\n", format: note.format)
            return outcome(try NoteFile.save("mine\n", to: file, format: note.format, expecting: note.fingerprint))
        }
        step("umlaut name") {
            let note = try NoteFile.load(umlaut)
            return outcome(try NoteFile.save("edited\n", to: umlaut, format: note.format, expecting: note.fingerprint))
        }
        step("copy") {
            try NoteFile.saveCopy(of: umlaut, text: "copy\n", format: NoteFormat()).lastPathComponent
        }
        step("tags") {
            outcome(try NoteFile.updateTags(of: file, to: ["a", "2026-11-05"]))
        }
        step("create") { try NoteOperations.createNote(named: "Neu Mu\u{0308}ller", in: directory).lastPathComponent }
        step("new folder") { try NoteOperations.createFolder(named: "Sub", in: directory).lastPathComponent }
        try? await Task.sleep(for: .seconds(6))
        step("rename") { try NoteOperations.rename(file, to: "renamed").lastPathComponent }
        try? await Task.sleep(for: .seconds(6))
        let renamed = directory.appending(path: "renamed.md")
        step("move") { try NoteOperations.move(renamed, to: directory.appending(path: "Sub")).path }
        try? await Task.sleep(for: .seconds(6))
        step("trash") {
            try NoteOperations.trash(directory.appending(path: "M\u{00FC}ller (Mac copy).md"))
            return "ok"
        }
        try? await Task.sleep(for: .seconds(6))
        try? report.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
#endif
