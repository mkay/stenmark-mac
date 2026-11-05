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
            } else if window.hidesLists {
                // Not a column visibility of .detailOnly, which a three-column
                // split view on macOS ignores.
                ReaderPane(window: window)
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
        .onChange(of: app.styleRevision) { window.reloadOpenNote() }
        .background(CloseGuardInstaller(window: window))
        .sheet(item: $window.conflict) { ConflictSheet(window: window, conflict: $0) }
        .alert(
            "Save Your Changes?", isPresented: unsavedPromptIsPresented, presenting: window.unsavedPrompt
        ) { prompt in
            Button("Save") { window.answerUnsavedPrompt(prompt, save: true) }
            Button("Don’t Save", role: .destructive) { window.answerUnsavedPrompt(prompt, save: false) }
            Button("Cancel", role: .cancel) { window.unsavedPrompt = nil }
        } message: { _ in
            Text("The note has edits that aren’t saved.")
        }
        .alert(item: $window.message) { message in
            Alert(title: Text(message.title), message: Text(message.text))
        }
        .modifier(DebugHooksModifier(window: window))
    }
}

private extension WindowContent {
    var unsavedPromptIsPresented: Binding<Bool> {
        Binding(get: { window.unsavedPrompt != nil }, set: { if !$0 { window.unsavedPrompt = nil } })
    }
}

/// What to do when a save finds the file isn't what it was.
private struct ConflictSheet: View {
    let window: WindowModel
    let conflict: SaveConflict

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if conflict.theirs == nil {
                Text("This Note Is Gone").font(.headline)
                Text("It was moved or deleted, perhaps on another machine. Your text is still here.")
            } else {
                Text("This Note Has Changed").font(.headline)
                Text("It changed since you started editing, perhaps on another machine. Which version do you want to keep?")
            }
            HStack {
                Button("Keep Editing", role: .cancel) { window.resolve(conflict, with: .cancel) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if conflict.theirs != nil {
                    Button("Use the Other Version") { window.resolve(conflict, with: .keepTheirs) }
                    Button("Keep Both") { window.resolve(conflict, with: .keepBoth) }
                    Button("Use Mine") { window.resolve(conflict, with: .keepMine) }
                } else {
                    Button("Discard My Text", role: .destructive) { window.resolve(conflict, with: .keepTheirs) }
                    Button("Save It Again") { window.resolve(conflict, with: .keepMine) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
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
