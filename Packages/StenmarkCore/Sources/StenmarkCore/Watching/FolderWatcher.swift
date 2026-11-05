// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

import CoreServices
import Foundation
import Synchronization

/// What changed in a watched folder during one debounce period.
public struct FolderChange: Sendable, Equatable {
    /// Notes whose contents may have changed, or that came or went.
    public var notes: Set<String> = []
    /// Notes or folders came, went or were renamed, so lists need refreshing.
    public var structureChanged = false
    /// Events were lost. Treat everything as changed.
    public var needsFullRescan = false

    var isEmpty: Bool { notes.isEmpty && !structureChanged && !needsFullRescan }
}

/// Watches a folder tree with FSEvents.
///
/// It watches the folder and not the open file on purpose. A sync client
/// replaces a file by renaming a new one over it, and a watch on the old file
/// goes quiet after that. A path-based stream doesn't care what happened to the
/// file that used to be there.
///
/// Paths are reported under the folder as it was passed in. FSEvents gives them
/// with symlinks resolved, so /tmp would otherwise arrive as /private/tmp and
/// not match the path of the open note.
public final class FolderWatcher: Sendable {
    public static let defaultDebounce: Duration = .milliseconds(500)

    /// The stream is only touched under the lock and on `queue`.
    private struct Stream: @unchecked Sendable {
        let ref: FSEventStreamRef
    }

    private struct State {
        var stream: Stream?
        var pending = FolderChange()
        var flush: DispatchWorkItem?
    }

    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "de.singular.stenmark.watcher")
    private let debounce: Duration
    private let watchedRoot: String
    private let resolvedRoot: String
    private let handler: @Sendable (FolderChange) -> Void

    /// `handler` runs on a private queue.
    public init(
        folder: URL, debounce: Duration = FolderWatcher.defaultDebounce,
        handler: @escaping @Sendable (FolderChange) -> Void
    ) {
        self.debounce = debounce
        self.handler = handler
        watchedRoot = folder.path
        resolvedRoot = realpath(folder.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? folder.path

        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagUseCFTypes
        let stream = FSEventStreamCreate(
            nil, Self.callback, &context, [folder.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, FSEventStreamCreateFlags(flags))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
            let box = Stream(ref: stream)
            state.withLock { $0.stream = box }
        }
    }

    deinit {
        stop()
    }

    public func stop() {
        state.withLock { state in
            state.flush?.cancel()
            state.flush = nil
            guard let stream = state.stream?.ref else { return }
            state.stream = nil
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
        let list = unsafeBitCast(paths, to: NSArray.self)
        var change = FolderChange()
        for index in 0..<count {
            guard let path = list[index] as? String else { continue }
            FolderWatcher.record(watcher.reported(path), flags[index], in: &change)
        }
        watcher.add(change)
    }

    private func reported(_ path: String) -> String {
        path.hasPrefix(resolvedRoot) ? watchedRoot + path.dropFirst(resolvedRoot.count) : path
    }

    static func record(_ path: String, _ flags: FSEventStreamEventFlags, in change: inout FolderChange) {
        func has(_ flag: Int) -> Bool { flags & FSEventStreamEventFlags(flag) != 0 }

        if has(kFSEventStreamEventFlagMustScanSubDirs) || has(kFSEventStreamEventFlagRootChanged) {
            change.needsFullRescan = true
        }
        let name = (path as NSString).lastPathComponent
        // Hidden files include the temporary files of other apps and sync
        // clients. Nothing here shows them, so they aren't changes.
        guard !name.hasPrefix(".") else { return }

        let cameOrWent = has(kFSEventStreamEventFlagItemCreated) || has(kFSEventStreamEventFlagItemRemoved)
            || has(kFSEventStreamEventFlagItemRenamed)
        if has(kFSEventStreamEventFlagItemIsDir) {
            if cameOrWent { change.structureChanged = true }
        } else if name.lowercased().hasSuffix(".md") {
            change.notes.insert(path)
            if cameOrWent { change.structureChanged = true }
        }
    }

    private func add(_ change: FolderChange) {
        guard !change.isEmpty else { return }
        state.withLock { state in
            guard state.stream != nil else { return }
            state.pending.notes.formUnion(change.notes)
            state.pending.structureChanged = state.pending.structureChanged || change.structureChanged
            state.pending.needsFullRescan = state.pending.needsFullRescan || change.needsFullRescan
            state.flush?.cancel()
            let flush = DispatchWorkItem { [weak self] in self?.deliver() }
            state.flush = flush
            queue.asyncAfter(deadline: .now() + debounce.seconds, execute: flush)
        }
    }

    private func deliver() {
        let change = state.withLock { state in
            let change = state.pending
            state.pending = FolderChange()
            state.flush = nil
            return change
        }
        if !change.isEmpty { handler(change) }
    }
}

private extension Duration {
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
