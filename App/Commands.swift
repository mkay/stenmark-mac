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

    var body: some Commands {
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
        CommandMenu("Note") {
            Button(window?.isEditing == true ? "Done Editing" : "Edit Note") { window?.toggleEdit() }
                .keyboardShortcut("e")
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
            Button("Back") { window?.goBack() }
                .keyboardShortcut("[")
                .disabled(window?.canGoBack != true)
            Button("Forward") { window?.goForward() }
                .keyboardShortcut("]")
                .disabled(window?.canGoForward != true)
        }
    }
}
