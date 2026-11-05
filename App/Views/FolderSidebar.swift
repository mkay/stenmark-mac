// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import StenmarkCore
import SwiftUI

struct FolderSidebar: View {
    let window: WindowModel

    private var selection: Binding<SidebarItem?> {
        Binding(get: { window.selection }, set: { window.select($0) })
    }

    var body: some View {
        List(selection: selection) {
            row("All Documents", icon: "tray.full", count: window.overview.totalNotes)
                .tag(SidebarItem.all)
            if window.overview.rootNotes > 0 {
                row("No Folder", icon: "doc.text", count: window.overview.rootNotes)
                    .tag(SidebarItem.rootNotes)
            }
            ForEach(window.overview.folders) { folder in
                row(verbatim: folder.name, icon: "folder", count: folder.noteCount)
                    .tag(SidebarItem.folder(folder.url))
            }
        }
        // A faint accent tint, as in the Linux app and Edith.
        .scrollContentBackground(.hidden)
        .background(Color.accentColor.opacity(0.06))
        .safeAreaInset(edge: .top) {
            RootSelector(choices: window.rootChoices, current: window.root) { window.switchRoot(to: $0) }
                .help("Change root folder")
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
    }

    private func row(_ title: LocalizedStringKey, icon: String, count: Int) -> some View {
        Label(title, systemImage: icon).badge(count)
    }

    /// A folder's name is the user's, so it isn't looked up for translation.
    private func row(verbatim title: String, icon: String, count: Int) -> some View {
        Label { Text(verbatim: title) } icon: { Image(systemName: icon) }.badge(count)
    }
}

/// The dropdown at the top of the sidebar. An NSPopUpButton because the tree
/// needs real indentation, which a SwiftUI Picker can't do.
private struct RootSelector: NSViewRepresentable {
    let choices: [FolderNode]
    let current: URL?
    let onSelect: (URL) -> Void

    @MainActor final class Coordinator: NSObject {
        var onSelect: (URL) -> Void = { _ in }
        var shown: [FolderNode] = []

        @objc func selected(_ sender: NSPopUpButton) {
            if let url = sender.selectedItem?.representedObject as? URL { onSelect(url) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selected(_:))
        button.autoenablesItems = false
        (button.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingTail
        // A long folder name mustn't widen the sidebar.
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.onSelect = onSelect
        if context.coordinator.shown != choices {
            context.coordinator.shown = choices
            button.removeAllItems()
            for choice in choices {
                let item = NSMenuItem(title: choice.name, action: nil, keyEquivalent: "")
                item.representedObject = choice.url
                item.indentationLevel = choice.depth
                item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                button.menu?.addItem(item)
            }
        }
        if let index = choices.firstIndex(where: { $0.url.path == current?.path }) {
            button.selectItem(at: index)
        }
    }
}
