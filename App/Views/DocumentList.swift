// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

import StenmarkCore
import SwiftUI

struct DocumentList: View {
    let window: WindowModel

    private var selection: Binding<URL?> {
        Binding(get: { window.openNote }, set: { if let url = $0 { window.open(url) } })
    }

    var body: some View {
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
                } else {
                    Section { rows(of: group) } header: { Text(verbatim: group.title) }
                }
            }
        }
        // A faint accent tint, as in the Linux app and Edith.
        .scrollContentBackground(.hidden)
        .background(Color.accentColor.opacity(0.06))
        .overlay {
            if window.documents.allSatisfy({ $0.notes.isEmpty && $0.subfolders.isEmpty }) {
                ContentUnavailableView("No Documents", systemImage: "doc.text")
            }
        }
    }

    @ViewBuilder
    private func rows(of group: NoteGroup) -> some View {
        ForEach(group.subfolders) { folder in
            Button { window.drill(into: folder.url) } label: { FolderRow(folder: folder) }
                .buttonStyle(.plain)
        }
        ForEach(group.notes) { note in
            NoteRow(note: note).tag(note.url)
        }
    }
}

private struct FolderRow: View {
    let folder: FolderSummary

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").foregroundStyle(.secondary)
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

private struct NoteRow: View {
    let note: NoteSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: note.displayName).fontWeight(.semibold).lineLimit(1)
            Text(verbatim: subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if !note.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(note.tags, id: \.self) { tag in
                        Text(verbatim: tag)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.tint.opacity(0.15), in: .rect(cornerRadius: 4))
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        let details = Formatting.size(note.size) + " · " + Formatting.date(note.modified)
        return note.title == nil ? details : note.fileName + " · " + details
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
