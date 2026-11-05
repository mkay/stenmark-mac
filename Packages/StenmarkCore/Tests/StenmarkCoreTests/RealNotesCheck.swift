// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Synchronization
import Testing
@testable import StenmarkCore

/// Compares this package with the Linux app on a real notes folder. It only
/// reads, and reports counts rather than anything from the notes. It's skipped
/// unless pointed at a folder; see scripts/dump-notes-for-check.py.
struct RealNotesCheck {
    struct LinuxNote: Decodable {
        let path: String
        let tags: [String]
        let title: String?
    }

    private static let environment = ProcessInfo.processInfo.environment

    @Test(.enabled(if: environment["STENMARK_REAL_NOTES"] != nil))
    func agreesWithLinux() throws {
        let root = URL(fileURLWithPath: Self.environment["STENMARK_REAL_NOTES"]!)
        let json = URL(fileURLWithPath: Self.environment["STENMARK_REAL_NOTES_JSON"]!)
        let linux = try JSONDecoder().decode([LinuxNote].self, from: Data(contentsOf: json))

        let prefix = root.path + "/"
        let found = NoteLibrary.allNotes(under: root).map { String($0.path.dropFirst(prefix.count)) }
        #expect(Set(found) == Set(linux.map(\.path)), "the same notes")
        #expect(found.count == linux.count)

        var tagDifferences = 0
        var titleDifferences = 0
        var notByteForByte = 0
        for note in linux {
            let url = root.appending(path: note.path)
            let start = NoteLibrary.readStart(of: url, bytes: 8192) ?? ""
            if Frontmatter.tags(in: start) != note.tags { tagDifferences += 1 }
            if NoteLibrary.title(of: url) != note.title { titleDifferences += 1 }
            let bytes = try Data(contentsOf: url)
            let decoded = NoteFile.decode(bytes)
            if NoteFile.encode(decoded.text, decoded.format) != bytes { notByteForByte += 1 }
        }
        print("checked \(linux.count) notes: tags differ \(tagDifferences), titles differ \(titleDifferences), round trip differs \(notByteForByte)")
        #expect(tagDifferences == 0)
        #expect(titleDifferences == 0)
        #expect(notByteForByte == 0)
    }

    /// Waits for a real change to arrive through sync, for a note edited on
    /// another machine or the web. Reads only. Set STENMARK_REAL_NOTE_EDIT to
    /// the note's path relative to the folder.
    @Test(.enabled(if: environment["STENMARK_REAL_NOTE_EDIT"] != nil))
    func seesAnEditFromTheServer() async throws {
        let root = URL(fileURLWithPath: Self.environment["STENMARK_REAL_NOTES"]!)
        let note = root.appending(path: Self.environment["STENMARK_REAL_NOTE_EDIT"]!)
        let before = try NoteFile.load(note)
        let seen = Mutex<[FolderChange]>([])
        let started = Date()
        let watcher = FolderWatcher(folder: root) { change in
            print("+\(Int(Date().timeIntervalSince(started)))s change: notes=\(change.notes.count) structure=\(change.structureChanged) rescan=\(change.needsFullRescan)")
            seen.withLock { $0.append(change) }
        }
        defer { watcher.stop() }
        print("watching")

        var noticed = false
        while Date().timeIntervalSince(started) < 600 {
            try await Task.sleep(for: .seconds(1))
            if seen.withLock({ $0.contains { $0.notes.contains(note.path) } }) {
                noticed = true
                break
            }
        }
        #expect(noticed, "the watcher saw the note change")
        guard noticed else { return }

        // The event can come before the new contents are there, so give them
        // time. Never call save here: this runs on someone's real note.
        // `matches` is the comparison that makes a save a conflict.
        var differs = false
        for _ in 0..<60 where !differs {
            differs = !NoteFile.matches(note, before.fingerprint)
            if !differs { try await Task.sleep(for: .seconds(1)) }
        }
        print("+\(Int(Date().timeIntervalSince(started)))s contents differ: \(differs)")
        #expect(differs, "a stale save would be a conflict")
    }

    /// What a tag edit would write, for every note that has tags, compared with
    /// the note as it is. Setting a note's own tags must change nothing at all.
    @Test(.enabled(if: environment["STENMARK_REAL_NOTES"] != nil))
    func resavingTagsChangesNothing() throws {
        let root = URL(fileURLWithPath: Self.environment["STENMARK_REAL_NOTES"]!)
        var checked = 0
        var changed = 0
        for url in NoteLibrary.allNotes(under: root) {
            let note = NoteFile.decode(try Data(contentsOf: url))
            let tags = Frontmatter.tags(in: note.text)
            guard !tags.isEmpty else { continue }
            checked += 1
            if Frontmatter.updatingTags(in: note.text, to: tags) != note.text { changed += 1 }
        }
        print("re-tagged \(checked) notes in memory: \(changed) would change")
        #expect(changed == 0)
    }
}
