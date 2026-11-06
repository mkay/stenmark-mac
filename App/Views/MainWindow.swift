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

    var body: some View {
        Group {
            if window.root == nil {
                WelcomeView(window: window)
            } else if window.showsNoteOnly {
                // Not a column visibility of .detailOnly, which a three-column
                // split view on macOS ignores.
                ReaderPane(window: window)
            } else {
                NavigationSplitView(columnVisibility: columnVisibility) {
                    FolderSidebar(window: window)
                        .navigationSplitViewColumnWidth(min: 170, ideal: 220)
                } content: {
                    DocumentList(window: window)
                        .navigationSplitViewColumnWidth(min: 240, ideal: 300)
                        // Items of its own are what give the toolbar a separator
                        // at this column's edge, so that it splits in two there.
                        .toolbar {
                            ToolbarItemGroup(placement: .navigation) { HistoryButtons(window: window) }
                        }
                } detail: {
                    ReaderPane(window: window)
                }
            }
        }
        .navigationTitle(window.openNote?.lastPathComponent ?? "Stenmark")
        // Still the window's name for the Window menu, but ReaderPane draws it.
        .toolbar(removing: window.root == nil ? nil : .title)
        .focusedSceneValue(\.windowModel, window)
        .modifier(WindowPrompts(window: window))
        .modifier(DebugHooksModifier(window: window))
    }
}

/// The window's observers, sheets and alerts. Apart from `WindowContent`,
/// because together they're more than the compiler will type-check in one go.
private struct WindowPrompts: ViewModifier {
    @Bindable var window: WindowModel
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
        .onChange(of: colorScheme, initial: true) { window.isDark = colorScheme == .dark }
        .onChange(of: app.ceiling) { window.adoptCeiling() }
        .onChange(of: app.styleRevision) { window.reloadOpenNote() }
        .sheet(isPresented: $window.showWhatsNew) { WhatsNewView() }
        .sheet(isPresented: $window.showSupport) { SupportView() }
        .task {
            if app.shouldShowWhatsNew(version: WhatsNewView.version) { window.showWhatsNew = true }
        }
        .background(CloseGuardInstaller(window: window))
        .onChange(of: app.pendingOpens, initial: true) {
            let urls = app.pendingOpens
            guard !urls.isEmpty else { return }
            app.pendingOpens = []
            for url in urls { window.handleOpen(url) }
        }
        .sheet(item: $window.nameRequest) { NameSheet(request: $0) }
        .sheet(item: $window.moveRequest) { MoveSheet(window: window, request: $0) }
        .alert(
            trashTitle, isPresented: trashIsPresented, presenting: window.trashRequest
        ) { request in
            Button(request.isFolder ? "Delete" : "Move to Trash", role: .destructive) {
                window.trash(request.url, isFolder: request.isFolder)
            }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text("“\(request.url.lastPathComponent)” will be moved to the Trash.")
        }
        .sheet(item: $window.conflict) { ConflictSheet(window: window, conflict: $0) }
        // Never change or clear `message` from code while this is up: dismissing
        // an alert during a SwiftUI update crashes. `WindowModel.present` holds
        // to that, and a click on OK takes a different path.
        .alert(
            window.message?.title ?? "", isPresented: messageIsPresented, presenting: window.message
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(verbatim: message.text)
        }
        .alert(
            "Save Your Changes?", isPresented: unsavedPromptIsPresented, presenting: window.unsavedPrompt
        ) { prompt in
            Button("Save") { window.answerUnsavedPrompt(prompt, save: true) }
            Button("Don’t Save", role: .destructive) { window.answerUnsavedPrompt(prompt, save: false) }
            Button("Cancel", role: .cancel) { window.unsavedPrompt = nil }
        } message: { _ in
            Text("The note has edits that aren’t saved.")
        }
    }
}

private extension WindowPrompts {
    var messageIsPresented: Binding<Bool> {
        Binding(get: { window.message != nil }, set: { if !$0 { window.message = nil } })
    }

    var trashTitle: LocalizedStringKey {
        window.trashRequest?.isFolder == true ? "Delete Folder?" : "Move to Trash?"
    }

    var trashIsPresented: Binding<Bool> {
        Binding(get: { window.trashRequest != nil }, set: { if !$0 { window.trashRequest = nil } })
    }

    var unsavedPromptIsPresented: Binding<Bool> {
        Binding(get: { window.unsavedPrompt != nil }, set: { if !$0 { window.unsavedPrompt = nil } })
    }
}

/// Asks for a name, with the part before the extension selected to type over.
private struct NameSheet: View {
    let request: NameRequest
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: request.title).font(.headline)
            TextField("Name", text: $name)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(request.action, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { name = request.initial }
    }

    private func submit() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        dismiss()
        request.perform(name)
    }
}

/// Moves a note to another folder under the root.
private struct MoveSheet: View {
    let window: WindowModel
    let request: MoveRequest
    @State private var target: URL?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Move “\(request.note.lastPathComponent)” to:").font(.headline)
            Picker("Folder", selection: $target) {
                ForEach(window.rootChoices) { folder in
                    Text(verbatim: String(repeating: "    ", count: folder.depth) + folder.name).tag(Optional(folder.url))
                }
            }
            .labelsHidden()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Move") {
                    dismiss()
                    if let target { window.move(request.note, to: target) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(target == nil)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            let current = request.note.deletingLastPathComponent().path
            target = window.rootChoices.first { $0.url.path == current }?.url
        }
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

private extension WindowContent {
    /// The split view's own sidebar button comes through here too.
    var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { window.columnLayout == .documents ? .doubleColumn : .all },
            set: { visibility in
                // The split view reports once more as it's taken away for the
                // note alone, which mustn't undo that layout.
                guard !window.showsNoteOnly else { return }
                window.setLayout(visibility == .all ? .all : .documents)
            }
        )
    }
}

private struct WelcomeView: View {
    let window: WindowModel

    var body: some View {
        ContentUnavailableView {
            Label { Text("Welcome to Stenmark") } icon: { StenmarkLogo() }
        } description: {
            Text("Choose the folder that holds your Markdown notes.")
        } actions: {
            Button("Choose Folder…") { window.chooseCeiling() }
                .buttonStyle(.borderedProminent)
        }
    }
}
