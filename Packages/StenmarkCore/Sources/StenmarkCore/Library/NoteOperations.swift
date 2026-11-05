// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

public enum OperationError: Error, LocalizedError, Equatable {
    case invalidName(String)
    case alreadyExists(String)
    case folderNotEmpty(String)
    case failed(String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let name):
            String(localized: "“\(name)” can’t be used as a name.", bundle: .module)
        case .alreadyExists(let name):
            String(localized: "“\(name)” already exists.", bundle: .module)
        case .folderNotEmpty(let name):
            String(localized: "“\(name)” still contains files or folders. Remove its contents first.", bundle: .module)
        case .failed(let name, let reason):
            String(localized: "“\(name)”: \(reason)", bundle: .module)
        }
    }
}

/// Creating, renaming, moving and trashing notes and folders.
///
/// New names go in composed form through POSIX calls, because Foundation
/// decomposes every name it creates and Linux compares names byte for byte.
/// All of this blocks, so call it away from the main thread.
public enum NoteOperations {
    /// A name typed by someone: trimmed, and with nothing in it that could reach
    /// another folder or make the file invisible here and on Linux.
    static func cleaned(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("."), !trimmed.contains("/"), !trimmed.contains("\0") else {
            throw OperationError.invalidName(name)
        }
        return trimmed.precomposedStringWithCanonicalMapping
    }

    /// With the extension, so that the note doesn't drop out of every list.
    private static func noteName(_ name: String) throws -> String {
        let cleaned = try cleaned(name)
        return cleaned.lowercased().hasSuffix(".md") ? cleaned : cleaned + ".md"
    }

    private static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    private static func inode(_ path: String) -> ino_t? {
        var info = stat()
        return lstat(path, &info) == 0 ? info.st_ino : nil
    }

    /// Makes a note holding a heading of its name, as on Linux.
    @discardableResult
    public static func createNote(named name: String, in folder: URL) throws -> URL {
        let file = try noteName(name)
        let url = folder.appending(path: file)
        guard !exists(url.path) else { throw OperationError.alreadyExists(file) }
        let stem = (file as NSString).deletingPathExtension
        do {
            try NoteFile.create(url, with: Data("# \(stem)\n".utf8))
        } catch {
            throw OperationError.failed(file, reason: error.localizedDescription)
        }
        return url
    }

    @discardableResult
    public static func createFolder(named name: String, in folder: URL) throws -> URL {
        let cleaned = try cleaned(name)
        let path = folder.path + "/" + cleaned
        guard !exists(path) else { throw OperationError.alreadyExists(cleaned) }
        guard mkdir(path, 0o755) == 0 else {
            throw OperationError.failed(cleaned, reason: String(cString: strerror(errno)))
        }
        return URL(fileURLWithPath: path)
    }

    /// Renames in place. A note keeps its extension. Changing only the case or
    /// the Unicode form of a name is allowed, even though APFS says the new name
    /// already exists, because it's the same file.
    @discardableResult
    public static func rename(_ url: URL, to name: String) throws -> URL {
        var isFolder: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
        let target = isFolder.boolValue ? try cleaned(name) : try noteName(name)
        return try relocate(url, to: url.deletingLastPathComponent(), named: target)
    }

    /// Moves into `folder`, keeping the name. Nothing is ever overwritten.
    @discardableResult
    public static func move(_ url: URL, to folder: URL) throws -> URL {
        try relocate(url, to: folder, named: url.lastPathComponent.precomposedStringWithCanonicalMapping)
    }

    private static func relocate(_ url: URL, to folder: URL, named name: String) throws -> URL {
        let source = url.path
        let destination = folder.path + "/" + name
        if exists(destination), inode(destination) != inode(source) {
            throw OperationError.alreadyExists(name)
        }
        var coordinationError: NSError?
        var failure: Error?
        let target = URL(fileURLWithPath: destination)
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(
            writingItemAt: url, options: .forMoving, writingItemAt: target, options: .forReplacing,
            error: &coordinationError
        ) { from, to in
            // renamex_np refuses to replace anything, so a file that appeared
            // since the check above is safe. A change of case or form is the
            // same file, which only plain rename can do.
            let sameFile = inode(destination) == inode(source)
            let result = sameFile ? Foundation.rename(source, destination) : renamex_np(source, destination, UInt32(RENAME_EXCL))
            if result == 0 {
                coordinator.item(at: from, didMoveTo: to)
            } else {
                failure = OperationError.failed(url.lastPathComponent, reason: String(cString: strerror(errno)))
            }
        }
        if let error = coordinationError ?? failure {
            throw error is OperationError ? error : OperationError.failed(url.lastPathComponent, reason: error.localizedDescription)
        }
        return target
    }

    /// To the Trash, from where it can be put back.
    public static func trash(_ url: URL) throws {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            throw OperationError.failed(url.lastPathComponent, reason: error.localizedDescription)
        }
    }

    /// To the Trash, but only if nothing visible is in it, as on Linux. A
    /// hidden file doesn't count, and goes along with the folder.
    public static func trashEmptyFolder(_ url: URL) throws {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        guard names.allSatisfy({ $0.hasPrefix(".") }) else {
            throw OperationError.folderNotEmpty(url.lastPathComponent)
        }
        try trash(url)
    }
}

extension SettingsStore {
    /// Carries pins along when something is renamed or moved, including
    /// anything pinned inside a folder that moved.
    public func movePins(from old: URL, to new: URL) throws {
        for setting in [Settings.pinnedFiles, Settings.pinnedFolders] {
            let pins = value(setting)
            let moved = pins.map { pin -> String in
                if pin == old.path { return new.path }
                if pin.hasPrefix(old.path + "/") { return new.path + pin.dropFirst(old.path.count) }
                return pin
            }
            if moved != pins { try set(setting, to: moved) }
        }
    }
}
