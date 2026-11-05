// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Testing
@testable import StenmarkCore

struct NoteOperationsTests {
    private func text(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    @Test func createsANoteWithAHeading() throws {
        let folder = try TemporaryFolder()
        let url = try NoteOperations.createNote(named: " Shopping ", in: folder.url)
        #expect(url.lastPathComponent == "Shopping.md")
        #expect(try text(url) == "# Shopping\n")
    }

    @Test func keepsAnExtensionThatsThere() throws {
        let folder = try TemporaryFolder()
        #expect(try NoteOperations.createNote(named: "a.MD", in: folder.url).lastPathComponent == "a.MD")
    }

    @Test("Refuses a name that could leave the folder or hide the note", arguments: [
        "", "  ", "../x", "a/b", ".hidden", "/etc/x",
    ])
    func refusesNames(name: String) throws {
        let folder = try TemporaryFolder()
        let file = try folder.write("x", to: "a.md")
        #expect(throws: OperationError.self) { try NoteOperations.createNote(named: name, in: folder.url) }
        #expect(throws: OperationError.self) { try NoteOperations.createFolder(named: name, in: folder.url) }
        #expect(throws: OperationError.self) { try NoteOperations.rename(file, to: name) }
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func neverOverwritesOnCreate() throws {
        let folder = try TemporaryFolder()
        let file = try folder.write("keep", to: "a.md")
        #expect(throws: OperationError.alreadyExists("a.md")) { try NoteOperations.createNote(named: "a", in: folder.url) }
        #expect(try text(file) == "keep")
    }

    @Test func newNamesAreComposed() throws {
        let folder = try TemporaryFolder()
        try NoteOperations.createNote(named: "Mu\u{0308}ller", in: folder.url)
        try NoteOperations.createFolder(named: "Bu\u{0308}ro", in: folder.url)
        let names = folder.rawNames()
        #expect(names.contains(Array("M\u{00FC}ller.md".utf8)))
        #expect(names.contains(Array("B\u{00FC}ro".utf8)))
    }

    @Test func renameKeepsTheNoteANote() throws {
        let folder = try TemporaryFolder()
        let file = try folder.write("keep", to: "a.md")
        let renamed = try NoteOperations.rename(file, to: "b")
        #expect(renamed.lastPathComponent == "b.md")
        #expect(try text(renamed) == "keep")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(NoteLibrary.notes(in: folder.url).count == 1)
    }

    @Test func renamedNamesAreComposedOnDisk() throws {
        let folder = try TemporaryFolder()
        let file = try folder.write("x", to: "a.md")
        try NoteOperations.rename(file, to: "Mu\u{0308}ller")
        #expect(folder.rawNames() == [Array("M\u{00FC}ller.md".utf8)])
    }

    @Test func renameRefusesAnotherFilesName() throws {
        let folder = try TemporaryFolder()
        let file = try folder.write("mine", to: "a.md")
        let other = try folder.write("theirs", to: "b.md")
        #expect(throws: OperationError.alreadyExists("b.md")) { try NoteOperations.rename(file, to: "b") }
        #expect(try text(other) == "theirs")
        #expect(try text(file) == "mine")
    }

    /// APFS treats these as the same name, so "already exists" would be wrong.
    @Test func aChangeOfCaseIsARename() throws {
        let folder = try TemporaryFolder()
        let file = try folder.write("x", to: "note.md")
        try NoteOperations.rename(file, to: "NOTE")
        #expect(folder.rawNames() == [Array("NOTE.md".utf8)])
    }

    @Test func aChangeOfUnicodeFormIsARename() throws {
        let folder = try TemporaryFolder()
        let file = try folder.write("x", to: "Mu\u{0308}ller.md")
        try NoteOperations.rename(file, to: "M\u{00FC}ller")
        #expect(folder.rawNames() == [Array("M\u{00FC}ller.md".utf8)])
    }

    @Test func renamesFoldersWithoutAddingAnExtension() throws {
        let folder = try TemporaryFolder()
        try folder.write("x", to: "old/a.md")
        let renamed = try NoteOperations.rename(folder.url.appending(path: "old"), to: "new")
        #expect(renamed.lastPathComponent == "new")
        #expect(NoteLibrary.noteCount(under: renamed) == 1)
    }

    @Test func movesAndRefusesToOverwrite() throws {
        let folder = try TemporaryFolder()
        let file = try folder.write("mine", to: "a.md")
        try folder.write("theirs", to: "sub/a.md")
        let other = try folder.write("other", to: "b.md")
        let sub = folder.url.appending(path: "sub")
        #expect(throws: OperationError.alreadyExists("a.md")) { try NoteOperations.move(file, to: sub) }
        #expect(try text(file) == "mine")
        let moved = try NoteOperations.move(other, to: sub)
        #expect(try text(moved) == "other")
        #expect(!FileManager.default.fileExists(atPath: other.path))
    }

    @Test func aMissingFileIsAnError() throws {
        let folder = try TemporaryFolder()
        #expect(throws: OperationError.self) { try NoteOperations.rename(folder.url.appending(path: "gone.md"), to: "x") }
    }

    @Test func trashingOnlyEmptyFolders() throws {
        let folder = try TemporaryFolder()
        try folder.write("x", to: "full/a.md")
        let full = folder.url.appending(path: "full")
        #expect(throws: OperationError.folderNotEmpty("full")) { try NoteOperations.trashEmptyFolder(full) }
        #expect(FileManager.default.fileExists(atPath: full.path))
    }

    @Test func pinsFollowARename() throws {
        let folder = try TemporaryFolder()
        let store = SettingsStore(fileURL: folder.url.appending(path: "settings.json"))
        try store.set(Settings.pinnedFiles, to: ["/n/old/a.md", "/n/oldish/b.md", "/n/c.md"])
        try store.set(Settings.pinnedFolders, to: ["/n/old", "/n/old/sub"])
        try store.movePins(from: URL(fileURLWithPath: "/n/old"), to: URL(fileURLWithPath: "/n/new"))
        #expect(store.value(Settings.pinnedFiles) == ["/n/new/a.md", "/n/oldish/b.md", "/n/c.md"])
        #expect(store.value(Settings.pinnedFolders) == ["/n/new", "/n/new/sub"])
    }
}
