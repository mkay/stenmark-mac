// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

import StenmarkCore
import SwiftUI

/// One Stenmark window: folders, the documents in them, and the open note.
/// Linux swaps the middle and right parts in one stack; a Mac window has the
/// width to show all three.
struct MainWindow: View {
    @Environment(AppModel.self) private var app
    @State private var window: WindowModel?

    var body: some View {
        Group {
            if let window { WindowContent(window: window) }
        }
        .task {
            if window == nil { window = WindowModel(app: app) }
        }
    }
}

private struct WindowContent: View {
    @Bindable var window: WindowModel
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if window.root == nil {
                WelcomeView(window: window)
            } else {
                NavigationSplitView {
                    FolderSidebar(window: window)
                        .navigationSplitViewColumnWidth(min: 170, ideal: 220)
                } content: {
                    DocumentList(window: window)
                        .navigationSplitViewColumnWidth(min: 220, ideal: 300)
                } detail: {
                    ReaderPane(window: window)
                }
            }
        }
        .navigationTitle(window.openNote?.deletingPathExtension().lastPathComponent ?? "Stenmark")
        .focusedSceneValue(\.windowModel, window)
        .onChange(of: colorScheme, initial: true) { window.isDark = colorScheme == .dark }
        .onChange(of: app.ceiling) { window.adoptCeiling() }
        .alert(item: $window.message) { message in
            Alert(title: Text(message.title), message: Text(message.text))
        }
        .modifier(DebugHooksModifier(window: window))
    }
}

private struct WelcomeView: View {
    let window: WindowModel

    var body: some View {
        ContentUnavailableView {
            Label("Welcome to Stenmark", systemImage: "books.vertical")
        } description: {
            Text("Choose the folder that holds your Markdown notes.")
        } actions: {
            Button("Choose Folder…") { window.chooseCeiling() }
                .buttonStyle(.borderedProminent)
        }
    }
}
