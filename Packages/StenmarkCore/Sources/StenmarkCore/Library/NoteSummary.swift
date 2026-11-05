// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// What a list shows about a note.
public struct NoteSummary: Identifiable, Sendable, Hashable {
    public let url: URL
    public let title: String?
    public let size: Int
    public let modified: Date
    public let tags: [String]

    public var id: URL { url }
    public var fileName: String { url.lastPathComponent }
    /// The note's heading, or its file name without the extension.
    public var displayName: String { title ?? url.deletingPathExtension().lastPathComponent }
}

/// What a list shows about a folder.
public struct FolderSummary: Identifiable, Sendable, Hashable {
    public let url: URL
    public let noteCount: Int
    public let subfolderCount: Int
    public let modified: Date?

    public var id: URL { url }
    public var name: String { url.lastPathComponent }
}

/// A folder in the root selector.
public struct FolderNode: Identifiable, Sendable, Hashable {
    public let url: URL
    public let depth: Int

    public var id: URL { url }
    public var name: String { url.lastPathComponent }
}

/// The sidebar's contents.
public struct LibraryOverview: Sendable, Equatable {
    public var totalNotes = 0
    public var rootNotes = 0
    public var folders: [FolderSummary] = []

    public init() {}
}

/// A folder's section of the document list.
public struct NoteGroup: Identifiable, Sendable, Equatable {
    public let folder: URL
    /// Empty for the section the list is showing itself.
    public let title: String
    public let subfolders: [FolderSummary]
    public let notes: [NoteSummary]

    public var id: URL { folder }

    public init(folder: URL, title: String, subfolders: [FolderSummary], notes: [NoteSummary]) {
        self.folder = folder
        self.title = title
        self.subfolders = subfolders
        self.notes = notes
    }
}

extension NoteLibrary {
    /// Reads the start of the note, so this can wait on a download.
    public static func summary(of url: URL) -> NoteSummary {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let start = readStart(of: url, bytes: 8192) ?? ""
        return NoteSummary(
            url: url,
            title: title(inStartOfNote: start),
            size: attributes?[.size] as? Int ?? 0,
            modified: attributes?[.modificationDate] as? Date ?? .distantPast,
            tags: Frontmatter.tags(in: start)
        )
    }

    public static func folderSummary(of url: URL) -> FolderSummary {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return FolderSummary(
            url: url,
            noteCount: noteCount(under: url),
            subfolderCount: subfolders(of: url).count,
            modified: attributes?[.modificationDate] as? Date
        )
    }

    public static func overview(of root: URL) -> LibraryOverview {
        var overview = LibraryOverview()
        overview.totalNotes = noteCount(under: root)
        overview.rootNotes = notes(in: root).count
        overview.folders = subfolders(of: root).map(folderSummary)
        return overview
    }

    /// One folder's own subfolders and notes.
    public static func group(for folder: URL) -> NoteGroup {
        NoteGroup(
            folder: folder, title: "",
            subfolders: subfolders(of: folder).map(folderSummary),
            notes: notes(in: folder).map(summary)
        )
    }

    /// Every folder with notes under `root`, each titled with its path below
    /// the root, for All Documents.
    public static func allGroups(under root: URL) -> [NoteGroup] {
        var groups: [NoteGroup] = []
        func visit(_ folder: URL, title: String) {
            let found = notes(in: folder).map(summary)
            if !found.isEmpty {
                groups.append(NoteGroup(folder: folder, title: title, subfolders: [], notes: found))
            }
            for child in subfolders(of: folder) {
                visit(child, title: title.isEmpty ? child.lastPathComponent : title + " / " + child.lastPathComponent)
            }
        }
        visit(root, title: "")
        return groups
    }
}
