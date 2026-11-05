// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Finding notes and folders on disk, with the Linux app's rules: only `.md`
/// files count, anything starting with a dot is skipped, symlinks to folders
/// aren't followed, and names sort case-insensitively.
///
/// A URL always holds a name in decomposed form, whatever is on disk. That's
/// harmless for finding a file, because APFS treats the forms as the same name,
/// but a URL can't be used to tell which form a name has. Nothing here renames
/// anything, and `NoteFile` keeps names as they are.
public enum NoteLibrary {
    /// How deep the folder tree for the root picker goes, so that a deep tree
    /// can't turn it into a thousand-entry list.
    public static let treeDepth = 4

    private struct Entry {
        let url: URL
        let name: String
        let isFolder: Bool
        let isNote: Bool
    }

    private static func entries(of folder: URL) -> [Entry] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names
            .filter { !$0.hasPrefix(".") }
            .sorted { sortKey($0).lexicographicallyPrecedes(sortKey($1)) }
            .compactMap { name in
                let url = folder.appending(path: name)
                guard let attributes = try? manager.attributesOfItem(atPath: url.path) else { return nil }
                let type = attributes[.type] as? FileAttributeType
                let isNoteName = name.lowercased().hasSuffix(".md")
                var isNote = isNoteName && type == .typeRegular
                if isNoteName, type == .typeSymbolicLink {
                    var isDirectory: ObjCBool = false
                    isNote = manager.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
                }
                return Entry(url: url, name: name, isFolder: type == .typeDirectory, isNote: isNote)
            }
    }

    private static func sortKey(_ name: String) -> [Unicode.Scalar] {
        // Code point order of the lowercased name, as in the Linux lists, but
        // composed first so that both forms of a name sort to the same place.
        Array(name.lowercased().precomposedStringWithCanonicalMapping.unicodeScalars)
    }

    /// The folders directly in `folder`.
    public static func subfolders(of folder: URL) -> [URL] {
        entries(of: folder).filter(\.isFolder).map(\.url)
    }

    /// The notes directly in `folder`.
    public static func notes(in folder: URL) -> [URL] {
        entries(of: folder).filter(\.isNote).map(\.url)
    }

    /// Every note in `folder` and below, each folder's notes before its
    /// subfolders', which is the order the document panel groups them in.
    public static func allNotes(under folder: URL) -> [URL] {
        let entries = entries(of: folder)
        return entries.filter(\.isNote).map(\.url)
            + entries.filter(\.isFolder).flatMap { allNotes(under: $0.url) }
    }

    /// The number of notes in `folder` and below.
    public static func noteCount(under folder: URL) -> Int {
        allNotes(under: folder).count
    }

    /// Every folder below `folder`, depth first.
    public static func tree(under folder: URL, depth: Int = treeDepth) -> [URL] {
        guard depth > 0 else { return [] }
        return subfolders(of: folder).flatMap { [$0] + tree(under: $0, depth: depth - 1) }
    }

    /// The note's first `# ` heading, if the note starts with one. Reads only
    /// the start of the file, because this runs for every row in a list.
    public static func title(of url: URL) -> String? {
        guard let text = readStart(of: url, bytes: 4096) else { return nil }
        let body = Frontmatter(in: text)?.body ?? text
        for line in body.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                let title = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
                return title.isEmpty ? nil : title
            }
            if !trimmed.isEmpty { return nil }
        }
        return nil
    }

    /// The first `bytes` of a file as text. A character cut off at the end, or
    /// a file that isn't UTF-8, comes out as replacement characters, which is
    /// fine for looking at frontmatter.
    static func readStart(of url: URL, bytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: bytes) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
