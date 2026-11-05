// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Synchronization
import Testing
@testable import StenmarkCore

/// Real FSEvents on a real folder, so these run one at a time.
@Suite(.serialized) struct FolderWatcherTests {
    final class Log: Sendable {
        let changes = Mutex<[FolderChange]>([])
        var notes: Set<String> { changes.withLock { $0.reduce(into: []) { $0.formUnion($1.notes) } } }
        var structureChanged: Bool { changes.withLock { $0.contains(where: \.structureChanged) } }
        var count: Int { changes.withLock(\.count) }
        func clear() { changes.withLock { $0.removeAll() } }

        func wait(until condition: () -> Bool) async -> Bool {
            for _ in 0..<60 {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return condition()
        }
    }

    private func watch(_ folder: TemporaryFolder) async -> (FolderWatcher, Log) {
        let log = Log()
        let watcher = FolderWatcher(folder: folder.url, debounce: .milliseconds(50)) { change in
            log.changes.withLock { $0.append(change) }
        }
        // FSEvents can report what happened just before the stream started.
        try? await Task.sleep(for: .milliseconds(300))
        log.clear()
        return (watcher, log)
    }

    /// This is what a watch on the single file failed: it went quiet after the
    /// second replacement.
    @Test func keepsSeeingRepeatedReplacement() async throws {
        let folder = try TemporaryFolder()
        let file = try folder.write("0\n", to: "a.md")
        let (watcher, log) = await watch(folder)
        defer { watcher.stop() }
        for round in 1...4 {
            log.clear()
            try folder.syncReplace(file, with: "\(round)\n")
            #expect(await log.wait { log.notes.contains(file.path) }, "replacement \(round)")
        }
    }

    @Test func seesNestedNotesComingAndGoing() async throws {
        let folder = try TemporaryFolder()
        try folder.write("x", to: "sub/keep.md")
        let (watcher, log) = await watch(folder)
        defer { watcher.stop() }

        let file = try folder.write("x", to: "sub/new.md")
        #expect(await log.wait { log.notes.contains(file.path) && log.structureChanged })

        log.clear()
        try FileManager.default.removeItem(at: file)
        #expect(await log.wait { log.structureChanged })
    }

    @Test func seesFoldersComing() async throws {
        let folder = try TemporaryFolder()
        let (watcher, log) = await watch(folder)
        defer { watcher.stop() }
        try FileManager.default.createDirectory(at: folder.url.appending(path: "new"), withIntermediateDirectories: false)
        #expect(await log.wait { log.structureChanged })
    }

    @Test func ignoresWhatTheAppDoesntShow() async throws {
        let folder = try TemporaryFolder()
        let (watcher, log) = await watch(folder)
        defer { watcher.stop() }
        try folder.write("x", to: "note.txt")
        try folder.write("x", to: ".hidden.md")
        try await Task.sleep(for: .milliseconds(400))
        #expect(log.count == 0)
    }

    @Test func aBurstArrivesAsOneChange() async throws {
        let folder = try TemporaryFolder()
        let file = try folder.write("0\n", to: "a.md")
        let (watcher, log) = await watch(folder)
        defer { watcher.stop() }
        for round in 1...5 { try folder.syncReplace(file, with: "\(round)\n") }
        #expect(await log.wait { log.count > 0 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(log.count <= 2)
    }

    /// Saving triggers the watcher like any other change. The fingerprint is
    /// how the app tells its own save from someone else's.
    @Test func ownSavesCanBeToldApart() async throws {
        let folder = try TemporaryFolder()
        let file = try folder.write("old\n", to: "a.md")
        let (watcher, log) = await watch(folder)
        defer { watcher.stop() }

        let note = try NoteFile.load(file)
        guard case .saved(let fingerprint) = try NoteFile.save(
            "mine\n", to: file, format: note.format, expecting: note.fingerprint) else {
            Issue.record("not saved")
            return
        }
        #expect(await log.wait { log.notes.contains(file.path) })
        #expect(NoteFile.matches(file, fingerprint))

        try folder.syncReplace(file, with: "theirs\n")
        #expect(!NoteFile.matches(file, fingerprint))
    }

    /// A save must not show the watcher any file but the note itself, or a sync
    /// client watching the same folder would see those files too.
    @Test func savingShowsNoOtherFile() async throws {
        let folder = try TemporaryFolder()
        let file = try folder.write("old\n", to: "a.md")
        let raw = Mutex<[String]>([])
        let (watcher, _) = await watch(folder)
        defer { watcher.stop() }
        let note = try NoteFile.load(file)
        _ = try NoteFile.save("new\n", to: file, format: note.format, expecting: note.fingerprint)
        raw.withLock { $0 = (try? FileManager.default.contentsOfDirectory(atPath: folder.url.path)) ?? [] }
        #expect(raw.withLock { $0 } == ["a.md"])
    }

    @Test func stoppingEndsDelivery() async throws {
        let folder = try TemporaryFolder()
        let (watcher, log) = await watch(folder)
        watcher.stop()
        try folder.write("x", to: "a.md")
        try await Task.sleep(for: .milliseconds(300))
        #expect(log.count == 0)
    }
}
