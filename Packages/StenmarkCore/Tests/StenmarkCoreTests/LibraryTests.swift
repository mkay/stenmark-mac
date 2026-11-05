// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Testing
@testable import StenmarkCore

struct LibraryTests {
    @Test func onlyVisibleMarkdownFilesCount() throws {
        let folder = try TemporaryFolder()
        for name in ["b.md", "A.MD", "c.txt", ".hidden.md", "note.markdown"] {
            try folder.write("x", to: name)
        }
        try folder.write("x", to: ".git/x.md")
        try folder.write("x", to: "sub/inner.md")
        #expect(NoteLibrary.notes(in: folder.url).map(\.lastPathComponent) == ["A.MD", "b.md"])
        #expect(NoteLibrary.subfolders(of: folder.url).map(\.lastPathComponent) == ["sub"])
        #expect(NoteLibrary.noteCount(under: folder.url) == 3)
    }

    @Test("Finds a note whichever form its name is in", arguments: ["M\u{00FC}ller.md", "Mu\u{0308}ller.md"])
    func findsBothForms(name: String) throws {
        let folder = try TemporaryFolder()
        try folder.write("text", to: name)
        let found = try #require(NoteLibrary.notes(in: folder.url).first)
        #expect(found.lastPathComponent == name)
        #expect(try String(contentsOf: found, encoding: .utf8) == "text")
    }

    @Test func allNotesPutsAFoldersOwnNotesFirst() throws {
        let folder = try TemporaryFolder()
        for name in ["z.md", "a/1.md", "a/b/2.md", "c/3.md"] { try folder.write("x", to: name) }
        #expect(NoteLibrary.allNotes(under: folder.url).map(\.lastPathComponent) == ["z.md", "1.md", "2.md", "3.md"])
    }

    @Test func folderSymlinksArentFollowed() throws {
        let folder = try TemporaryFolder()
        try folder.write("x", to: "real/a.md")
        try FileManager.default.createSymbolicLink(
            at: folder.url.appending(path: "loop"), withDestinationURL: folder.url)
        #expect(NoteLibrary.noteCount(under: folder.url) == 1)
    }

    @Test func noteSymlinksAreNotes() throws {
        let folder = try TemporaryFolder()
        let real = try folder.write("x", to: "a.md")
        try FileManager.default.createSymbolicLink(at: folder.url.appending(path: "b.md"), withDestinationURL: real)
        #expect(NoteLibrary.notes(in: folder.url).count == 2)
    }

    @Test func theTreeStopsAtItsDepth() throws {
        let folder = try TemporaryFolder()
        try folder.write("x", to: "1/2/3/4/5/a.md")
        #expect(NoteLibrary.tree(under: folder.url).count == 4)
    }

    @Test func aMissingFolderIsEmpty() {
        #expect(NoteLibrary.notes(in: URL(fileURLWithPath: "/nonexistent/x")).isEmpty)
    }

    @Test func titles() throws {
        let folder = try TemporaryFolder()
        #expect(NoteLibrary.title(of: try folder.write("\n# Title \nx", to: "a.md")) == "Title")
        #expect(NoteLibrary.title(of: try folder.write("---\ntags: [a]\n---\n# T\n", to: "b.md")) == "T")
        #expect(NoteLibrary.title(of: try folder.write("Text\n# Later\n", to: "c.md")) == nil)
        #expect(NoteLibrary.title(of: try folder.write("## Two\n", to: "d.md")) == nil)
    }
}

struct TagIndexTests {
    private func makeIndex(_ folder: TemporaryFolder) async throws -> TagIndex {
        try folder.write("---\ntags: [a, b]\n---\n", to: "one.md")
        try folder.write("---\ntags: [B, c]\n---\n", to: "sub/two.md")
        try folder.write("no tags", to: "three.md")
        try folder.write("---\ntags: [hidden]\n---\n", to: ".skip/x.md")
        let index = TagIndex(root: folder.url)
        await index.rebuild()
        return index
    }

    @Test func indexesTheRoot() async throws {
        let folder = try TemporaryFolder()
        let index = try await makeIndex(folder)
        #expect(await index.allTags == ["a", "b", "c"])
        #expect(await index.count(of: "b") == 2)
        #expect(await index.tags(of: folder.url.appending(path: "one.md")) == ["a", "b"])
    }

    @Test func aFilterMatchesAllItsTags() async throws {
        let folder = try TemporaryFolder()
        let index = try await makeIndex(folder)
        #expect(await index.files(matchingAll: ["b", "c"]).map(\.lastPathComponent) == ["two.md"])
        #expect(await index.files(matchingAll: ["a", "c"]).isEmpty)
        #expect(await index.files(matchingAll: []).isEmpty)
    }

    @Test func followsChanges() async throws {
        let folder = try TemporaryFolder()
        let index = try await makeIndex(folder)
        let one = folder.url.appending(path: "one.md")
        try folder.write("---\ntags: [z]\n---\n", to: "one.md")
        await index.update(one)
        #expect(await index.allTags == ["b", "c", "z"])
        try FileManager.default.removeItem(at: one)
        await index.update(one)
        #expect(await index.allTags == ["b", "c"])
    }
}

struct TagIndexFormTests {
    @Test func aPathInTheOtherFormFindsTheSameNote() async throws {
        let folder = try TemporaryFolder()
        try folder.write("---\ntags: [a]\n---\n", to: "M\u{00FC}ller.md")
        let index = TagIndex(root: folder.url)
        await index.rebuild()
        let other = folder.url.path + "/Mu\u{0308}ller.md"
        #expect(await index.tags(of: URL(fileURLWithPath: other)) == ["a"])
    }
}

struct SearchTests {
    private let file = URL(fileURLWithPath: "/n.md")

    @Test func findsAnyCase() throws {
        let hit = try #require(NoteSearch.search("Find the NEEDLE here", for: "needle", file: file))
        #expect(hit.before == "Find the ")
        #expect(hit.match == "NEEDLE")
        #expect(hit.after == " here")
    }

    @Test func snapsToWordsAndMarksCuts() throws {
        let long = String(repeating: "word ", count: 40)
        let hit = try #require(NoteSearch.search(long + "needle " + long, for: "needle", file: file))
        #expect(hit.before.hasPrefix("\u{2026}word"))
        #expect(hit.after.hasSuffix("word\u{2026}"))
        #expect(hit.before.count < 70)
    }

    @Test func snippetsAreOneLine() throws {
        let hit = try #require(NoteSearch.search("a\nb\r\nneedle\nc", for: "needle", file: file))
        #expect(hit.before == "a b ")
        #expect(hit.after == " c")
    }

    @Test func noMatchNoHit() {
        #expect(NoteSearch.search("text", for: "q", file: file) == nil)
        #expect(NoteSearch.search("text", for: "", file: file) == nil)
    }

    @Test func streamsHitsAndSkipsUnreadableNotes() async throws {
        let folder = try TemporaryFolder()
        let a = try folder.write("has needle", to: "a.md")
        let b = try folder.write("nothing", to: "b.md")
        let c = try folder.write("needle too", to: "c.md")
        let gone = folder.url.appending(path: "gone.md")
        var found: [String] = []
        for await hit in NoteSearch.hits(for: "needle", in: [a, gone, b, c]) {
            found.append(hit.file.lastPathComponent)
        }
        #expect(found == ["a.md", "c.md"])
    }
}

struct SettingsTests {
    @Test func storesWithLinuxKeys() throws {
        let folder = try TemporaryFolder()
        let url = folder.url.appending(path: "x/settings.json")
        let store = SettingsStore(fileURL: url)
        #expect(store.isFirstRun)
        try store.set(Settings.fontSize, to: 18)
        let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(stored?["font_size"] as? Int == 18)
        let reopened = SettingsStore(fileURL: url)
        #expect(!reopened.isFirstRun)
        #expect(reopened.value(Settings.fontSize) == 18)
    }

    @Test func keepsUnknownKeys() throws {
        let folder = try TemporaryFolder()
        let url = try folder.write(#"{"from_the_future": [1], "font_size": 12}"#, to: "settings.json")
        try SettingsStore(fileURL: url).set(Settings.fontSize, to: 18)
        let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(stored?["from_the_future"] != nil)
    }

    @Test func refusesToOverwriteADamagedFile() throws {
        let folder = try TemporaryFolder()
        let url = try folder.write("{ damaged", to: "settings.json")
        let store = SettingsStore(fileURL: url)
        #expect(store.value(Settings.fontSize) == 16)
        #expect(throws: SettingsError.self) { try store.set(Settings.fontSize, to: 18) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "{ damaged")
    }

    @Test func aWrongTypeCountsAsUnset() throws {
        let folder = try TemporaryFolder()
        let url = try folder.write(#"{"pinned_files": "oops"}"#, to: "settings.json")
        #expect(SettingsStore(fileURL: url).value(Settings.pinnedFiles) == [])
    }

    @Test func overridesArentSaved() throws {
        let folder = try TemporaryFolder()
        let url = folder.url.appending(path: "settings.json")
        let store = SettingsStore(fileURL: url)
        store.setOverride(Settings.rootDirectory, to: "/session")
        #expect(store.value(Settings.rootDirectory) == "/session")
        try store.set(Settings.fontSize, to: 18)
        #expect(SettingsStore(fileURL: url).value(Settings.rootDirectory) == "")
    }

    @Test func pinsMatchEitherUnicodeForm() throws {
        let folder = try TemporaryFolder()
        let store = SettingsStore(fileURL: folder.url.appending(path: "settings.json"))
        try store.togglePin("/n/M\u{00FC}ller.md", in: Settings.pinnedFiles)
        #expect(store.isPinned("/n/Mu\u{0308}ller.md", in: Settings.pinnedFiles))
        try store.togglePin("/n/Mu\u{0308}ller.md", in: Settings.pinnedFiles)
        #expect(store.value(Settings.pinnedFiles).isEmpty)
    }

    @Test func forgetsStalePins() throws {
        let folder = try TemporaryFolder()
        let real = try folder.write("x", to: "a.md")
        let store = SettingsStore(fileURL: folder.url.appending(path: "settings.json"))
        try store.set(Settings.pinnedFiles, to: [real.path, "/nonexistent.md"])
        try store.removeStalePins()
        #expect(store.value(Settings.pinnedFiles) == [real.path])
    }
}
