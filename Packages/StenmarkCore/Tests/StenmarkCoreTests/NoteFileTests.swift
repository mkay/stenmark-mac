// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Testing
@testable import StenmarkCore

/// The shared folder rules from the plan. Each of these is something that would
/// cause trouble for the Linux app, or lose someone's edits, if it broke.
struct NoteFileTests {
    private func bytes(_ url: URL) throws -> [UInt8] {
        Array(try Data(contentsOf: url))
    }

    private func save(_ text: String, _ note: LoadedNote, _ url: URL) throws -> SaveOutcome {
        try NoteFile.save(text, to: url, format: note.format, expecting: note.fingerprint)
    }

    @Test func savesAnEdit() throws {
        let folder = try TemporaryFolder()
        let file = try folder.write("one\n", to: "a.md")
        let note = try NoteFile.load(file)
        guard case .saved(let fingerprint) = try save("two\n", note, file) else {
            Issue.record("not saved")
            return
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "two\n")
        #expect(NoteFile.matches(file, fingerprint))
    }

    @Test func unchangedTextIsNotWritten() throws {
        let folder = try TemporaryFolder()
        let file = try folder.write("one\n", to: "a.md")
        let old = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
        let inode = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? Int

        let note = try NoteFile.load(file)
        guard case .unchanged = try save(note.text, note, file) else {
            Issue.record("expected unchanged")
            return
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect(attributes[.modificationDate] as? Date == old)
        #expect(attributes[.systemFileNumber] as? Int == inode)
    }

    @Test func aNewerSyncedVersionIsNotOverwritten() throws {
        let folder = try TemporaryFolder()
        let file = try folder.write("old\n", to: "a.md")
        let note = try NoteFile.load(file)

        try folder.syncReplace(file, with: "edited on the other machine\n")

        guard case .conflict(let theirs) = try save("my edit\n", note, file) else {
            Issue.record("expected a conflict")
            return
        }
        #expect(theirs.text == "edited on the other machine\n")
        #expect(try String(contentsOf: file, encoding: .utf8) == "edited on the other machine\n")
    }

    /// The Linux bug: leaving edit mode without typing wrote the old text back.
    @Test func anUneditedOldCopyIsNotWrittenBack() throws {
        let folder = try TemporaryFolder()
        let file = try folder.write("old\n", to: "a.md")
        let note = try NoteFile.load(file)
        try folder.syncReplace(file, with: "newer\n")

        _ = try save(note.text, note, file)
        #expect(try String(contentsOf: file, encoding: .utf8) == "newer\n")
    }

    @Test func bothMachinesMakingTheSameEditIsNotAConflict() throws {
        let folder = try TemporaryFolder()
        let file = try folder.write("old\n", to: "a.md")
        let note = try NoteFile.load(file)
        try folder.syncReplace(file, with: "same\n")
        guard case .unchanged = try save("same\n", note, file) else {
            Issue.record("expected unchanged")
            return
        }
    }

    @Test func aDateChangeAloneIsNotAConflict() throws {
        let folder = try TemporaryFolder()
        let file = try folder.write("old\n", to: "a.md")
        let note = try NoteFile.load(file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 5)], ofItemAtPath: file.path)
        guard case .saved = try save("new\n", note, file) else {
            Issue.record("expected saved")
            return
        }
    }

    @Test func aRemovedNoteIsReportedAndNotRecreated() throws {
        let folder = try TemporaryFolder()
        let file = try folder.write("old\n", to: "a.md")
        let note = try NoteFile.load(file)
        try FileManager.default.removeItem(at: file)
        #expect(try save("new\n", note, file) == .removed)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aConflictCanBeResolvedEitherWay() throws {
        let folder = try TemporaryFolder()
        let file = try folder.write("theirs\n", to: "My Note.md")
        let copy = try NoteFile.saveCopy(of: file, text: "mine\n", format: NoteFormat())
        #expect(copy.lastPathComponent == "My Note (Mac copy).md")
        #expect(try String(contentsOf: copy, encoding: .utf8) == "mine\n")
        #expect(try String(contentsOf: file, encoding: .utf8) == "theirs\n")

        let second = try NoteFile.saveCopy(of: file, text: "mine again\n", format: NoteFormat())
        #expect(second.lastPathComponent == "My Note (Mac copy 2).md")

        try NoteFile.overwrite(file, with: "mine\n", format: NoteFormat())
        #expect(try String(contentsOf: file, encoding: .utf8) == "mine\n")
    }

    @Test func aFailedSaveThrows() throws {
        let folder = try TemporaryFolder()
        let file = try folder.write("old\n", to: "a.md")
        let note = try NoteFile.load(file)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.url.path) }
        #expect(throws: NoteError.self) { try save("new\n", note, file) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "old\n")
    }

    @Test func leavesNothingBesideTheNote() throws {
        let folder = try TemporaryFolder()
        let file = try folder.write("old\n", to: "a.md")
        let note = try NoteFile.load(file)
        _ = try save("new\n", note, file)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path) == ["a.md"])
    }

    @Test func keepsWindowsLineEndings() throws {
        let folder = try TemporaryFolder()
        let file = try folder.write("a\r\nb\r\n", to: "a.md")
        let note = try NoteFile.load(file)
        #expect(note.text == "a\nb\n")
        #expect(note.format.lineEnding == .crlf)
        _ = try save("a\nb\nc\n", note, file)
        #expect(try bytes(file) == Array("a\r\nb\r\nc\r\n".utf8))
    }

    @Test func openingAndClosingAMixedFileChangesNothing() throws {
        let folder = try TemporaryFolder()
        let file = try folder.write("a\r\nb\nc\n", to: "a.md")
        let note = try NoteFile.load(file)
        guard case .unchanged = try save(note.text, note, file) else {
            Issue.record("expected unchanged")
            return
        }
        #expect(try bytes(file) == Array("a\r\nb\nc\n".utf8))
    }

    @Test func keepsTheByteOrderMark() throws {
        let folder = try TemporaryFolder()
        let file = folder.url.appending(path: "a.md")
        try Data([0xEF, 0xBB, 0xBF] + Array("ü\n".utf8)).write(to: file)
        let note = try NoteFile.load(file)
        #expect(note.text == "ü\n")
        _ = try save("ä\n", note, file)
        #expect(try bytes(file) == [0xEF, 0xBB, 0xBF] + Array("ä\n".utf8))
    }

    @Test func keepsLatin1() throws {
        let folder = try TemporaryFolder()
        let file = folder.url.appending(path: "a.md")
        try Data([0xFC, 0x0A]).write(to: file)
        let note = try NoteFile.load(file)
        #expect(note.text == "ü\n")
        _ = try save("üü\n", note, file)
        #expect(try bytes(file) == [0xFC, 0xFC, 0x0A])
    }

    @Test func textOutsideLatin1IsNotLost() throws {
        let format = NoteFormat(encoding: .latin1)
        #expect(String(bytes: NoteFile.encode("日本語\n", format), encoding: .utf8) == "日本語\n")
    }

    @Test("Saving keeps the exact bytes of the name", arguments: [
        "M\u{00FC}ller.md", "Mu\u{0308}ller.md", "a:b.md", "with space.md", "Ordner ?.md",
    ])
    func keepsNames(name: String) throws {
        let folder = try TemporaryFolder()
        let file = try folder.write("old\n", to: name)
        let before = folder.rawNames()
        #expect(before == [Array(name.utf8)])
        let note = try NoteFile.load(file)
        _ = try save("new\n", note, file)
        #expect(folder.rawNames() == before)
        #expect(try String(contentsOf: file, encoding: .utf8) == "new\n")
    }

    @Test("A path in the other form keeps the name on disk", arguments: [
        ("M\u{00FC}ller.md", "Mu\u{0308}ller.md"), ("Mu\u{0308}ller.md", "M\u{00FC}ller.md"),
    ])
    func keepsTheFormOnDisk(onDisk: String, path: String) throws {
        let folder = try TemporaryFolder()
        try folder.write("old\n", to: onDisk)
        let file = URL(fileURLWithPath: folder.url.path + "/" + path)
        let note = try NoteFile.load(file)
        _ = try save("new\n", note, file)
        #expect(folder.rawNames() == [Array(onDisk.utf8)])
    }

    /// Foundation would write this decomposed, and Linux compares bytes.
    @Test func newFilesGetComposedNames() throws {
        let folder = try TemporaryFolder()
        let file = try folder.write("x", to: "Mu\u{0308}ller.md")
        _ = try NoteFile.saveCopy(of: file, text: "y", format: NoteFormat())
        let composed = Array("M\u{00FC}ller (Mac copy).md".utf8)
        #expect(folder.rawNames().contains(composed))
    }

    @Test func creatingNeverOverwrites() throws {
        let folder = try TemporaryFolder()
        let file = try folder.write("x", to: "a.md")
        #expect(throws: (any Error).self) { try NoteFile.create(file, with: Data("y".utf8)) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "x")
    }

    @Test func aSymlinkedNoteStaysALink() throws {
        let folder = try TemporaryFolder()
        let real = try folder.write("old\n", to: "real.md")
        let link = folder.url.appending(path: "link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let note = try NoteFile.load(link)
        _ = try save("new\n", note, link)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == real.path)
        #expect(try String(contentsOf: real, encoding: .utf8) == "new\n")
    }

    @Test func keepsPermissionsAndExtendedAttributes() throws {
        let folder = try TemporaryFolder()
        let file = try folder.write("old\n", to: "a.md")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(setxattr(file.path, "de.singular.test", "x", 1, 0, 0) == 0)
        let note = try NoteFile.load(file)
        _ = try save("new\n", note, file)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        #expect(getxattr(file.path, "de.singular.test", nil, 0, 0, 0) == 1)
    }

    @Test func updatesTagsThroughTheSamePath() throws {
        let folder = try TemporaryFolder()
        let file = try folder.write("---\ntags:\n- a\n---\nBody\n", to: "a.md")
        _ = try NoteFile.updateTags(of: file, to: ["b"])
        #expect(try String(contentsOf: file, encoding: .utf8) == "---\ntags:\n- b\n---\nBody\n")
        guard case .unchanged = try NoteFile.updateTags(of: file, to: ["b"]) else {
            Issue.record("expected unchanged")
            return
        }
    }

    @Test func aMissingNoteCantBeLoaded() throws {
        let folder = try TemporaryFolder()
        #expect(throws: NoteError.self) { try NoteFile.load(folder.url.appending(path: "gone.md")) }
    }
}
