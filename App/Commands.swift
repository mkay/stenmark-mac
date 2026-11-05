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
