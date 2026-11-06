// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

struct WindowModelKey: FocusedValueKey {
    typealias Value = WindowModel
}

extension FocusedValues {
    var windowModel: WindowModel? {
        get { self[WindowModelKey.self] }
        set { self[WindowModelKey.self] = newValue }
    }
}

struct StenmarkCommands: Commands {
    @FocusedValue(\.windowModel) private var window
    @Environment(\.openWindow) private var openWindow

    private func layoutItem(_ title: LocalizedStringKey, _ layout: ColumnLayout, key: KeyEquivalent) -> some View {
        Toggle(title, isOn: Binding(
            get: { window?.columnLayout == layout },
            set: { _ in window?.setLayout(layout) }
        ))
        .keyboardShortcut(key)
        .disabled(window?.root == nil)
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note…") { window?.requestNewNote() }
                .keyboardShortcut("n")
                .disabled(window?.root == nil)
            Button("New Folder…") { window?.requestNewFolder() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(window?.root == nil)
            Button("New Window") { openWindow(id: "main") }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .printItem) {
            Button("Export as PDF…") { window?.exportPDF() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(window?.openNote == nil || window?.isEditing == true)
            Button("Print…") { window?.printNote() }
                .keyboardShortcut("p")
                .disabled(window?.openNote == nil || window?.isEditing == true)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { window?.saveNow() }
                .keyboardShortcut("s")
                .disabled(window?.isEditing != true)
        }
        CommandGroup(after: .textEditing) {
            Divider()
            Button("Find in Note…") { window?.showFind() }
                .keyboardShortcut("f")
                .disabled(window?.openNote == nil)
            Button("Find Next") { window?.findNext(1) }
                .keyboardShortcut("g")
                .disabled(window?.isFindVisible != true)
            Button("Find Previous") { window?.findNext(-1) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(window?.isFindVisible != true)
        }
        CommandGroup(after: .sidebar) {
            Divider()
            layoutItem("All Columns", .all, key: "1")
            layoutItem("Documents and Note", .documents, key: "2")
            layoutItem("Note Only", .note, key: "3")
        }
        CommandGroup(replacing: .help) {
            Button("What’s New in Stenmark") { window?.showWhatsNew = true }
                .disabled(window == nil)
            Button("Support Stenmark…") { window?.showSupport = true }
                .disabled(window == nil)
            Button("Open Source Licences") { window?.showLicences = true }
                .disabled(window == nil)
        }
        CommandMenu("Note") {
            Button(window?.isEditing == true ? "Done Editing" : "Edit Note") { window?.toggleEdit() }
                .keyboardShortcut("e")
                .disabled(window?.openNote == nil)
            Button("Copy as Rich Text") { window?.copyAsRichText() }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(window?.openNote == nil)
            Divider()
            Button(window?.isPreviewVisible == true ? "Hide Preview" : "Show Preview") { window?.togglePreview() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(window?.isEditing != true)
            Button(window?.isTypewriterOn == true ? "Turn Off Typewriter Mode" : "Turn On Typewriter Mode") {
                window?.toggleTypewriter()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(window?.isEditing != true)
        }
        CommandMenu("Go") {
            Button("Search All Notes") { window?.showSearch() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(window?.root == nil)
            Button("Filter by Tag") { window?.showTags() }
                .keyboardShortcut("t")
                .disabled(window?.root == nil)
            Divider()
            Button("Back") { window?.goBack() }
                .keyboardShortcut("[")
                .disabled(window?.canGoBack != true)
            Button("Forward") { window?.goForward() }
                .keyboardShortcut("]")
                .disabled(window?.canGoForward != true)
        }
    }
}
