// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import StenmarkCore
import StenmarkWeb

/// What the middle column shows.
enum ListMode {
    case documents, search, tags
}

/// Asking for a name, for creating or renaming.
struct NameRequest: Identifiable {
    let id = UUID()
    let title: String
    let action: String
    let initial: String
    let perform: (String) -> Void
}

struct MoveRequest: Identifiable {
    let id = UUID()
    let note: URL
}

struct TrashRequest: Identifiable {
    let id = UUID()
    let url: URL
    let isFolder: Bool
}

/// Managing notes, and finding them.
extension WindowModel {
    /// The folder new things go in: what the list is showing.
    var listFolder: URL? {
        if let folder = drilledFolders.last { return folder }
        if case .folder(let url) = selection { return url }
        return root
    }

    // MARK: Layout

    /// Whether the window shows the note and nothing else.
    var showsNoteOnly: Bool { hidesLists || columnLayout == .note }

    func loadLayout() {
        columnLayout = ColumnLayout(rawValue: app.settings.value(Settings.columnLayout)) ?? .all
        if columnLayout != .note { lastListLayout = columnLayout }
    }

    func setLayout(_ layout: ColumnLayout) {
        // Asking for the lists while editing means wanting them now.
        if layout != .note { hidesLists = false }
        guard layout != columnLayout else { return }
        columnLayout = layout
        if layout != .note { lastListLayout = layout }
        try? app.settings.set(Settings.columnLayout, to: layout.rawValue)
    }

    /// The note pane's button. A split view can't show the sidebar without the
    /// document column, so hiding the documents takes the sidebar with them,
    /// and bringing them back returns the sidebar to how it was.
    func toggleNoteOnly() {
        setLayout(showsNoteOnly ? lastListLayout : .note)
    }

    /// Search and tags live in the document column, so they need it on screen.
    private func revealDocumentColumn() {
        if showsNoteOnly { setLayout(lastListLayout) }
    }

    // MARK: Arranging lists

    private var loweredFilter: String {
        quickFilter.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Pinned first, then as listed, after the quick filter.
    func arranged(_ notes: [NoteSummary]) -> [NoteSummary] {
        let filter = loweredFilter
        let matching = filter.isEmpty ? notes : notes.filter { note in
            note.displayName.lowercased().contains(filter) || note.fileName.lowercased().contains(filter)
                || note.tags.contains { $0.contains(filter) }
        }
        return matching.filter { isPinned($0.url) } + matching.filter { !isPinned($0.url) }
    }

    func arranged(_ folders: [FolderSummary]) -> [FolderSummary] {
        let filter = loweredFilter
        let matching = filter.isEmpty ? folders : folders.filter { $0.name.lowercased().contains(filter) }
        return matching.filter { isFolderPinned($0.url) } + matching.filter { !isFolderPinned($0.url) }
    }

    // MARK: Pins

    func isPinned(_ url: URL) -> Bool { pinnedFiles.contains(url.path) }
    func isFolderPinned(_ url: URL) -> Bool { pinnedFolders.contains(url.path) }

    func loadPins() {
        try? app.settings.removeStalePins()
        pinnedFiles = Set(app.settings.value(Settings.pinnedFiles))
        pinnedFolders = Set(app.settings.value(Settings.pinnedFolders))
    }

    func togglePin(_ url: URL, isFolder: Bool) {
        do {
            try app.settings.togglePin(url.path, in: isFolder ? Settings.pinnedFolders : Settings.pinnedFiles)
        } catch {
            show(error, title: String(localized: "Couldn’t Save the Pin"))
        }
        pinnedFiles = Set(app.settings.value(Settings.pinnedFiles))
        pinnedFolders = Set(app.settings.value(Settings.pinnedFolders))
    }

    // MARK: Operations

    /// Runs a file operation away from the main thread, reports any failure,
    /// and returns its result.
    private func perform<Result: Sendable>(
        _ title: String, _ operation: @escaping @Sendable () throws -> Result
    ) async -> Result? {
        do {
            let result = try await Task.detached(operation: operation).value
            refreshLists()
            return result
        } catch {
            show(error, title: title)
            return nil
        }
    }

    func requestNewNote() {
        guard let folder = listFolder else { return }
        nameRequest = NameRequest(
            title: String(localized: "New Note"), action: String(localized: "Create"),
            initial: String(localized: "Untitled")
        ) { [weak self] name in
            self?.createNote(named: name, in: folder)
        }
    }

    func requestNewFolder() {
        guard let folder = listFolder else { return }
        nameRequest = NameRequest(
            title: String(localized: "New Folder"), action: String(localized: "Create"),
            initial: String(localized: "New Folder")
        ) { [weak self] name in
            self?.createFolder(named: name, in: folder)
        }
    }

    func createNote(named name: String, in folder: URL) {
        finishEditing { [weak self] in
            guard let self else { return }
            Task {
                let title = String(localized: "Couldn’t Create the Note")
                guard let url = await self.perform(title, { try NoteOperations.createNote(named: name, in: folder) }) else { return }
                self.open(url)
                // A new note is there to be written in, as on Linux.
                for _ in 0..<40 where self.openNote != url { try? await Task.sleep(for: .milliseconds(25)) }
                self.enterEdit(line: 2)
            }
        }
    }

    func createFolder(named name: String, in folder: URL) {
        Task {
            _ = await perform(String(localized: "Couldn’t Create the Folder")) {
                try NoteOperations.createFolder(named: name, in: folder)
            }
        }
    }

    func requestRename(_ url: URL) {
        nameRequest = NameRequest(
            title: String(localized: "Rename"), action: String(localized: "Rename"),
            initial: url.lastPathComponent
        ) { [weak self] name in
            self?.rename(url, to: name)
        }
    }

    func rename(_ url: URL, to name: String) {
        finishEditing { [weak self] in
            guard let self else { return }
            Task {
                let title = String(localized: "Couldn’t Rename It")
                guard let new = await self.perform(title, { try NoteOperations.rename(url, to: name) }) else { return }
                self.followMove(from: url, to: new)
            }
        }
    }

    func requestMove(_ note: URL) {
        moveRequest = MoveRequest(note: note)
    }

    func move(_ url: URL, to folder: URL) {
        guard folder.path != url.deletingLastPathComponent().path else { return }
        finishEditing { [weak self] in
            guard let self else { return }
            Task {
                let title = String(localized: "Couldn’t Move the Note")
                guard let new = await self.perform(title, { try NoteOperations.move(url, to: folder) }) else { return }
                self.followMove(from: url, to: new)
            }
        }
    }

    /// Everything that holds a path: pins, the open note, the history and the
    /// selection all have to go with the file.
    private func followMove(from old: URL, to new: URL) {
        func moved(_ url: URL) -> URL {
            if url.path == old.path { return new }
            if url.path.hasPrefix(old.path + "/") {
                return URL(fileURLWithPath: new.path + url.path.dropFirst(old.path.count))
            }
            return url
        }
        do {
            try app.settings.movePins(from: old, to: new)
        } catch {
            show(error, title: String(localized: "Couldn’t Save the Pin"))
        }
        pinnedFiles = Set(app.settings.value(Settings.pinnedFiles))
        pinnedFolders = Set(app.settings.value(Settings.pinnedFolders))
        relocateHistory(moved)
        if case .folder(let url) = selection { selectWithoutRefreshing(.folder(moved(url))) }
        relocateDrilledFolders(moved)
        if let note = openNote, moved(note) != note {
            openNote = moved(note)
            // The note's relative images and links now start somewhere else.
            reloadOpenNote()
        }
        refreshLists()
    }

    func requestTrash(_ url: URL, isFolder: Bool) {
        trashRequest = TrashRequest(url: url, isFolder: isFolder)
    }

    func trash(_ url: URL, isFolder: Bool) {
        finishEditing { [weak self] in
            guard let self else { return }
            Task {
                let title = String(localized: "Couldn’t Move It to the Trash")
                let done: Void? = await self.perform(title) {
                    if isFolder { try NoteOperations.trashEmptyFolder(url) } else { try NoteOperations.trash(url) }
                }
                guard done != nil else { return }
                if let note = self.openNote, note.path == url.path || note.path.hasPrefix(url.path + "/") {
                    self.closeOpenNote()
                }
                self.forgetInHistory(url)
                if case .folder(let selected) = self.selection, selected.path == url.path { self.select(.all) }
            }
        }
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copyPath(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    // MARK: Tags

    func rebuildTags() {
        guard let root else { return }
        let index = TagIndex(root: root)
        tagIndex = index
        Task {
            await index.rebuild()
            await refreshTags()
        }
    }

    func refreshTags() async {
        guard let tagIndex else { return }
        let tags = await tagIndex.allTags
        var counts: [String: Int] = [:]
        for tag in tags { counts[tag] = await tagIndex.count(of: tag) }
        allTags = tags
        tagCounts = counts
        selectedTags = selectedTags.intersection(tags)
        await refreshTagResults()
    }

    func refreshTagResults() async {
        guard let tagIndex else { return }
        let files = await tagIndex.files(matchingAll: Array(selectedTags))
        tagResults = await Task.detached { files.map(NoteLibrary.summary) }.value
    }

    func showTags(selecting tag: String? = nil) {
        revealDocumentColumn()
        listMode = .tags
        if let tag { selectedTags = [tag] }
        Task { await refreshTagResults() }
    }

    func toggleTag(_ tag: String) {
        if selectedTags.contains(tag) { selectedTags.remove(tag) } else { selectedTags.insert(tag) }
        Task { await refreshTagResults() }
    }

    /// The open note's tags.
    var openNoteTags: [String] {
        shown.map { Frontmatter.tags(in: $0.text) } ?? []
    }

    func setTags(_ tags: [String]) {
        guard let url = openNote, !isEditing else { return }
        Task {
            let title = String(localized: "Couldn’t Save the Tags")
            guard await perform(title, { try NoteOperations.tagged(url, tags) }) != nil else { return }
            reloadOpenNote()
            await tagIndex?.update(url)
            await refreshTags()
        }
    }

    // MARK: Search

    func showSearch() {
        revealDocumentColumn()
        listMode = .search
    }

    func closeLists() {
        listMode = .documents
        searchTask?.cancel()
        searchQuery = ""
        searchHits = []
    }

    /// Waits for a pause in typing, then searches what the list is showing.
    func runSearch() {
        searchTask?.cancel()
        searchHits = []
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, let root else {
            isSearching = false
            return
        }
        let scope = selection
        let folder = drilledFolders.last
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let files = await Task.detached {
                if let folder { return NoteLibrary.allNotes(under: folder) }
                switch scope {
                case .rootNotes: return NoteLibrary.notes(in: root)
                case .folder(let url): return NoteLibrary.allNotes(under: url)
                default: return NoteLibrary.allNotes(under: root)
                }
            }.value
            for await hit in NoteSearch.hits(for: query, in: files) {
                guard !Task.isCancelled else { return }
                searchHits.append(hit)
            }
            isSearching = false
        }
    }

    // MARK: Sharing

    private var currentText: String? {
        isEditing ? editor.text : shown?.text
    }

    func copyAsRichText() {
        guard let text = currentText else { return }
        let frontmatter = Frontmatter(in: text)
        let body = app.renderer.html(frontmatter?.body ?? text)
        let board = NSPasteboard.general
        board.clearContents()
        board.setString("<html><body>\(body)</body></html>", forType: .html)
        board.setString(text, forType: .string)
    }

    func exportPDF() {
        guard let note = openNote, let host = reader.webView.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = note.deletingPathExtension().lastPathComponent + ".pdf"
        panel.beginSheetModal(for: host) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await self?.reader.exportPDF(to: url) }
        }
    }

    func printNote() {
        reader.printNote()
    }

    func openExternally(_ url: URL, with app: URL) {
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// A note or folder handed over by Finder or `open`.
    func handleOpen(_ url: URL) {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return }
        if isFolder.boolValue {
            Task {
                // During launch the list of choices may still be on its way.
                await listTask?.value
                // The dropdown's limit holds here too.
                if rootChoices.contains(where: { $0.url.path == url.path }) {
                    switchRoot(to: url)
                } else {
                    present(Message(
                        title: String(localized: "Folder Outside the Notes Folder"),
                        text: String(localized: "“\(url.lastPathComponent)” isn’t in your notes folder. You can change that folder in Settings.")
                    ))
                }
            }
        } else if url.pathExtension.lowercased() == "md" {
            open(url)
            watchIfOutsideRoot(url)
        }
    }

    /// The root's watcher doesn't cover a note from elsewhere.
    private func watchIfOutsideRoot(_ url: URL) {
        guard let root, !url.path.hasPrefix(root.path + "/") else {
            outsideWatcher = nil
            return
        }
        outsideWatcher = FolderWatcher(folder: url.deletingLastPathComponent()) { [weak self] change in
            Task { @MainActor in self?.handle(change) }
        }
    }
}

extension NoteOperations {
    /// Saves a note's tags. A note can't change between the read and the write
    /// in `updateTags` in any way that matters, so an outcome of conflict means
    /// the file went away.
    static func tagged(_ url: URL, _ tags: [String]) throws {
        if case .removed = try NoteFile.updateTags(of: url, to: tags) {
            throw CocoaError(.fileNoSuchFile)
        }
    }
}
