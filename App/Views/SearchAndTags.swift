// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

import StenmarkCore
import SwiftUI

/// Full-text search across what the list was showing.
struct SearchPanel: View {
    @Bindable var window: WindowModel
    @FocusState private var focused: Bool

    private var selection: Binding<URL?> {
        Binding(get: { window.openNote }, set: { if let url = $0 { window.open(url) } })
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Search", window: window)
            TextField("Search notes", text: $window.searchQuery)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
                .onChange(of: window.searchQuery) { window.runSearch() }
                .onKeyPress(.escape) {
                    window.closeLists()
                    return .handled
                }
            List(window.searchHits, id: \.file, selection: selection) { hit in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: hit.file.deletingPathExtension().lastPathComponent).fontWeight(.semibold).lineLimit(1)
                    snippet(hit).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                .tag(hit.file)
            }
            .scrollContentBackground(.hidden)
            .background(Color.accentColor.opacity(0.06))
            .overlay {
                if !window.searchQuery.isEmpty, window.searchHits.isEmpty, !window.isSearching {
                    ContentUnavailableView("No Results", systemImage: "magnifyingglass")
                }
            }
            if !window.searchHits.isEmpty {
                Text("\(window.searchHits.count) results")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
        }
        .onAppear { focused = true }
    }

    private func snippet(_ hit: SearchHit) -> Text {
        var match = AttributedString(hit.match)
        match.font = .caption.bold()
        return Text(AttributedString(hit.before) + match + AttributedString(hit.after))
    }
}

/// Notes having all of the selected tags.
struct TagPanel: View {
    let window: WindowModel

    private var selection: Binding<URL?> {
        Binding(get: { window.openNote }, set: { if let url = $0 { window.open(url) } })
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Tags", window: window)
            ScrollView {
                TagFlow(spacing: 6) {
                    ForEach(window.allTags, id: \.self) { tag in
                        Button { window.toggleTag(tag) } label: {
                            Text(verbatim: "\(tag) \(window.tagCounts[tag] ?? 0)")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    window.selectedTags.contains(tag) ? AnyShapeStyle(.tint.opacity(0.4)) : AnyShapeStyle(.quaternary),
                                    in: .capsule
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
            }
            .frame(maxHeight: 160)
            Divider().padding(.top, 6)
            List(window.tagResults, selection: selection) { note in
                NoteRow(window: window, note: note).tag(note.url)
            }
            .scrollContentBackground(.hidden)
            .background(Color.accentColor.opacity(0.06))
            .overlay {
                if window.selectedTags.isEmpty {
                    ContentUnavailableView("Select Tags", systemImage: "tag")
                } else if window.tagResults.isEmpty {
                    ContentUnavailableView("No Matching Notes", systemImage: "tag")
                }
            }
        }
    }
}

private struct PanelHeader: View {
    let title: LocalizedStringKey
    let window: WindowModel

    var body: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            Button("Close", systemImage: "xmark") { window.closeLists() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

/// Lays chips out in rows, wrapping at the available width.
struct TagFlow: Layout {
    var spacing: CGFloat

    private func rows(_ subviews: Subviews, width: CGFloat) -> [[LayoutSubviews.Element]] {
        var rows: [[LayoutSubviews.Element]] = [[]]
        var x: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, !rows[rows.count - 1].isEmpty {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append(view)
            x += size.width + spacing
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        let height = rows(subviews, width: width).reduce(CGFloat(0)) { total, row in
            total + (row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0) + spacing
        }
        return CGSize(width: width, height: max(0, height - spacing))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = bounds.minX
            let height = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            for view in row {
                let size = view.sizeThatFits(.unspecified)
                view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += height + spacing
        }
    }
}

/// The open note's tags: chips to remove, and a field to add with suggestions.
struct TagEditor: View {
    let window: WindowModel
    @State private var entry = ""

    private var tags: [String] { window.openNoteTags }

    private var suggestions: [String] {
        let typed = entry.trimmingCharacters(in: .whitespaces).lowercased()
        guard !typed.isEmpty else { return [] }
        return window.allTags.filter { $0.contains(typed) && !tags.contains($0) }.prefix(6).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TagFlow(spacing: 4) {
                ForEach(tags, id: \.self) { tag in
                    HStack(spacing: 3) {
                        Text(verbatim: tag).font(.caption)
                        Button("Remove", systemImage: "xmark") { window.setTags(tags.filter { $0 != tag }) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                            .font(.caption2)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.tint.opacity(0.15), in: .capsule)
                }
            }
            TextField("Add tag…", text: $entry)
                .textFieldStyle(.roundedBorder)
                .onSubmit { add(entry) }
            ForEach(suggestions, id: \.self) { tag in
                Button { add(tag) } label: {
                    Text(verbatim: tag).frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .frame(width: 260)
    }

    private func add(_ text: String) {
        let tag = text.trimmingCharacters(in: .whitespaces).lowercased()
        entry = ""
        guard !tag.isEmpty, !tags.contains(tag) else { return }
        window.setTags(tags + [tag])
    }
}
