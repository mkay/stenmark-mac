// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

import StenmarkCore
import SwiftUI

/// The middle column: documents, search results or tag results.
struct DocumentList: View {
    @Bindable var window: WindowModel

    var body: some View {
        switch window.listMode {
        case .documents: documents
        case .search: SearchPanel(window: window)
        case .tags: TagPanel(window: window)
        }
    }

    private var selection: Binding<URL?> {
        Binding(get: { window.openNote }, set: { if let url = $0 { window.open(url) } })
    }

    private var documents: some View {
        List(selection: selection) {
            if let folder = window.currentFolder {
                Button { window.drillOut() } label: {
                    Label { Text(verbatim: folder.lastPathComponent) } icon: { Image(systemName: "chevron.left") }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            ForEach(window.documents) { group in
                if group.title.isEmpty {
                    rows(of: group)
                } else if !window.arranged(group.notes).isEmpty {
                    Section { rows(of: group) } header: { Text(verbatim: group.title) }
                }
            }
        }
        .contextMenu {
            Button("New Note…") { window.requestNewNote() }
            Button("New Folder…") { window.requestNewFolder() }
            Divider()
            Button("Refresh") { window.refreshLists() }
        }
        .safeAreaInset(edge: .top) {
            TextField("Filter", text: $window.quickFilter)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        // A faint accent tint, as in the Linux app and Edith.
        .scrollContentBackground(.hidden)
        .background(Color.accentColor.opacity(0.06))
        .overlay {
            if window.documents.allSatisfy({ window.arranged($0.notes).isEmpty && window.arranged($0.subfolders).isEmpty }) {
                ContentUnavailableView("No Documents", systemImage: "doc.text")
            }
        }
    }

    @ViewBuilder
    private func rows(of group: NoteGroup) -> some View {
        ForEach(window.arranged(group.subfolders)) { folder in
            Button { window.drill(into: folder.url) } label: {
                FolderRow(folder: folder, isPinned: window.isFolderPinned(folder.url))
            }
            .buttonStyle(.plain)
            .contextMenu { FolderMenu(window: window, url: folder.url) }
        }
        ForEach(window.arranged(group.notes)) { note in
            NoteRow(window: window, note: note).tag(note.url)
        }
    }
}

private struct FolderRow: View {
    let folder: FolderSummary
    let isPinned: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isPinned ? "pin" : "folder").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: folder.name).fontWeight(.semibold)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
    }

    private var subtitle: String {
        var parts: [String] = []
        if folder.noteCount > 0 { parts.append(String(localized: "\(folder.noteCount) documents")) }
        if folder.subfolderCount > 0 { parts.append(String(localized: "\(folder.subfolderCount) folders")) }
        if parts.isEmpty { parts.append(String(localized: "Empty")) }
        if let modified = folder.modified { parts.append(Formatting.date(modified)) }
        return parts.joined(separator: " · ")
    }
}

struct NoteRow: View {
    let window: WindowModel
    let note: NoteSummary

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: note.displayName).fontWeight(.semibold).lineLimit(1)
                Text(verbatim: subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !note.tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(note.tags, id: \.self) { tag in
                            Button { window.showTags(selecting: tag) } label: {
                                Text(verbatim: tag)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(.tint.opacity(0.15), in: .rect(cornerRadius: 4))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            Spacer()
            if window.isPinned(note.url) {
                Button { window.togglePin(note.url, isFolder: false) } label: { Image(systemName: "pin") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Remove pin")
            }
        }
        .padding(.vertical, 2)
        .contextMenu { NoteMenu(window: window, url: note.url) }
    }

    private var subtitle: String {
        let details = Formatting.size(note.size) + " · " + Formatting.date(note.modified)
        return note.title == nil ? details : note.fileName + " · " + details
    }
}

struct NoteMenu: View {
    let window: WindowModel
    let url: URL

    var body: some View {
        Button(window.isPinned(url) ? "Unpin" : "Pin to Top") { window.togglePin(url, isFolder: false) }
        Divider()
        OpenWithMenu(window: window, url: url)
        Button("Rename…") { window.requestRename(url) }
        Button("Move to Folder…") { window.requestMove(url) }
        Button("Move to Trash") { window.requestTrash(url, isFolder: false) }
        Button("Show in Finder") { window.reveal(url) }
        Divider()
        Button("Copy Path") { window.copyPath(url) }
    }
}

struct FolderMenu: View {
    let window: WindowModel
    let url: URL

    var body: some View {
        Button(window.isFolderPinned(url) ? "Unpin" : "Pin to Top") { window.togglePin(url, isFolder: true) }
        Divider()
        Button("Rename…") { window.requestRename(url) }
        Button("Delete Folder…") { window.requestTrash(url, isFolder: true) }
        Button("Show in Finder") { window.reveal(url) }
        Divider()
        Button("Copy Path") { window.copyPath(url) }
    }
}

/// The apps that can open a note, leaving out this one.
struct OpenWithMenu: View {
    let window: WindowModel
    let url: URL

    var body: some View {
        Menu("Open With") {
            ForEach(apps, id: \.self) { app in
                Button(FileManager.default.displayName(atPath: app.path)) { window.openExternally(url, with: app) }
            }
        }
    }

    private var apps: [URL] {
        NSWorkspace.shared.urlsForApplications(toOpen: url).filter { $0.path != Bundle.main.bundleURL.path }
    }
}

enum Formatting {
    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Relative for the last day, as on Linux, and a plain date after that.
    static func date(_ date: Date) -> String {
        let age = Date().timeIntervalSince(date)
        if age < 60 { return String(localized: "just now") }
        if age < 86_400 {
            return date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
