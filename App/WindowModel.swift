// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import StenmarkCore
import StenmarkWeb

/// What the sidebar can select.
enum SidebarItem: Hashable {
    case all
    /// Notes directly in the root.
    case rootNotes
    case folder(URL)
}

struct Message: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}

/// One window: a root folder, what's listed from it, and the open note.
@MainActor @Observable
final class WindowModel {
    let app: AppModel
    let reader = ReaderWebView()

    /// The folder this window shows. It can be anywhere from `ceiling` down.
    private(set) var root: URL?
    /// The highest folder the selector offers.
    private(set) var ceiling: URL?
    /// What the selector offers: `ceiling` and the folders below it.
    private(set) var rootChoices: [FolderNode] = []
    private(set) var overview = LibraryOverview()
    private(set) var documents: [NoteGroup] = []
    private(set) var selection: SidebarItem? = .all
    /// Subfolders opened from the document list, below the selected folder.
    private(set) var drilledFolders: [URL] = []

    private(set) var openNote: URL?
    private(set) var headings: [ReaderHeading] = []
    private(set) var wordCount = 0
    private(set) var history: [URL] = []
    private(set) var historyIndex = -1

    var isFindVisible = false
    var findQuery = ""
    private(set) var findState = FindState()
    var isContentsVisible = false
    var message: Message?

    /// The version of the open note on the page, to tell a real change from the
    /// echo of the app's own save when the watcher fires.
    private var shown: LoadedNote?
    private var watcher: FolderWatcher?
    private var listTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?

    #if DEBUG
    /// How often a note was rendered, for the end-to-end check.
    private(set) var renderCount = 0
    #endif

    var isDark = false {
        didSet {
            if isDark != oldValue { reloadOpenNote() }
        }
    }

    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex + 1 < history.count }
    var readingMinutes: Int { max(1, Int((Double(wordCount) / 200).rounded())) }
    var currentFolder: URL? { drilledFolders.last }

    init(app: AppModel) {
        self.app = app
        reader.onLink = { [weak self] in self?.follow($0) }
        reader.onTaskToggled = { [weak self] in self?.setTask($1, onLine: $0) }
        reader.onCopyCode = { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        reader.onSideButton = { [weak self] direction in
            if direction < 0 { self?.goBack() } else { self?.goForward() }
        }
        reader.menuItems = { [weak self] in self?.readerMenuItems() ?? [] }

        adoptCeiling()
        if let ceiling, let remembered = app.settings.rememberedRoot(under: ceiling) {
            show(root: remembered)
        }
        if app.settings.isDamaged {
            message = Message(
                title: String(localized: "Settings Can’t Be Read"),
                text: String(localized: "\(app.settings.fileURL.path) is damaged. Stenmark won’t change it, so settings you change now will not be saved.")
            )
        }
    }

    // MARK: Root and lists

    func chooseCeiling() {
        if let error = app.chooseCeiling() {
            show(error, title: String(localized: "Couldn’t Save the Folder"))
        }
    }

    /// Picks up the root folder from the settings.
    func adoptCeiling() {
        guard !app.ceiling.isEmpty else { return }
        setCeiling(URL(fileURLWithPath: (app.ceiling as NSString).expandingTildeInPath))
    }

    func setCeiling(_ url: URL) {
        ceiling = url
        show(root: url)
    }

    /// Moves this window to a folder from the selector. It doesn't change the
    /// root folder itself, and anything outside `ceiling` is refused here and
    /// not just left out of the menu. The choice is saved straight away rather
    /// than on closing, so that a crash doesn't lose it.
    func switchRoot(to url: URL) {
        // By path: URL equality also depends on a trailing slash.
        guard url.path != root?.path, rootChoices.contains(where: { $0.url.path == url.path }) else { return }
        show(root: url)
        do {
            try app.settings.set(Settings.lastRootFolder, to: url.path)
        } catch {
            show(error, title: String(localized: "Couldn’t Save the Folder"))
        }
    }

    private func show(root url: URL) {
        root = url
        selection = .all
        drilledFolders = []
        closeNote()
        history = []
        historyIndex = -1
        watcher = FolderWatcher(folder: url) { [weak self] change in
            Task { @MainActor in self?.handle(change) }
        }
        refreshLists()
    }

    func select(_ item: SidebarItem?) {
        guard item != selection else { return }
        selection = item
        drilledFolders = []
        refreshLists()
    }

    func drill(into folder: URL) {
        drilledFolders.append(folder)
        refreshLists()
    }

    func drillOut() {
        _ = drilledFolders.popLast()
        refreshLists()
    }

    /// Scanning reads the start of every listed note, and any of those reads
    /// can wait for a download, so it stays off the main thread.
    func refreshLists() {
        guard let root, let ceiling else { return }
        let selection = selection
        let folder = drilledFolders.last
        listTask?.cancel()
        listTask = Task {
            let (overview, documents, choices) = await Task.detached(priority: .userInitiated) {
                (
                    NoteLibrary.overview(of: root),
                    Self.listing(root: root, selection: selection, folder: folder),
                    NoteLibrary.folderTree(under: ceiling)
                )
            }.value
            guard !Task.isCancelled else { return }
            self.overview = overview
            self.documents = documents
            self.rootChoices = choices
        }
    }

    nonisolated private static func listing(root: URL, selection: SidebarItem?, folder: URL?) -> [NoteGroup] {
        if let folder { return [NoteLibrary.group(for: folder)] }
        switch selection {
        case .all, nil:
            return NoteLibrary.allGroups(under: root)
        case .rootNotes:
            let group = NoteLibrary.group(for: root)
            return [NoteGroup(folder: root, title: "", subfolders: [], notes: group.notes)]
        case .folder(let url):
            return [NoteLibrary.group(for: url)]
        }
    }

    private func handle(_ change: FolderChange) {
        refreshLists()
        guard app.settings.value(Settings.fileWatching), let openNote else { return }
        guard change.needsFullRescan || change.notes.contains(openNote.path) else { return }
        let fingerprint = shown?.fingerprint
        Task {
            let same = await Task.detached {
                fingerprint.map { NoteFile.matches(openNote, $0) } ?? false
            }.value
            // It's the echo of the app's own save, or a date changing.
            guard !same, self.openNote == openNote else { return }
            self.load(openNote, keepPosition: true)
        }
    }

    // MARK: The open note

    func open(_ url: URL) {
        guard url != openNote else { return }
        history = Array(history.prefix(historyIndex + 1)) + [url]
        historyIndex = history.count - 1
        load(url, keepPosition: false)
    }

    func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        load(history[historyIndex], keepPosition: false)
    }

    func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        load(history[historyIndex], keepPosition: false)
    }

    func reloadOpenNote() {
        if let openNote { load(openNote, keepPosition: true) }
    }

    private func load(_ url: URL, keepPosition: Bool) {
        loadTask?.cancel()
        loadTask = Task {
            do {
                let note = try await Task.detached { try NoteFile.load(url) }.value
                guard !Task.isCancelled else { return }
                await display(note, of: url, keepPosition: keepPosition)
            } catch {
                guard !Task.isCancelled else { return }
                closeNote()
                // A note that vanished through sync isn't an error to report.
                if FileManager.default.fileExists(atPath: url.path) {
                    show(error, title: String(localized: "Couldn’t Open the Note"))
                }
            }
        }
    }

    private func display(_ note: LoadedNote, of url: URL, keepPosition: Bool) async {
        let line = keepPosition ? await reader.topSourceLine() : nil
        let frontmatter = Frontmatter(in: note.text)
        let body = app.renderer.html(frontmatter?.body ?? note.text, lineOffset: frontmatter?.lineCount ?? 0)
        await reader.show(ReaderPage.html(body: body, style: style), folder: url.deletingLastPathComponent())
        guard !Task.isCancelled else { return }
        if let line { reader.scroll(toLine: line, smooth: false) }

        openNote = url
        shown = note
        wordCount = note.text.split(whereSeparator: \.isWhitespace).count
        headings = await reader.headings()
        if isFindVisible, !findQuery.isEmpty { findState = await reader.find(findQuery) }
        #if DEBUG
        renderCount += 1
        #endif
    }

    private func closeNote() {
        loadTask?.cancel()
        openNote = nil
        shown = nil
        headings = []
        wordCount = 0
        closeFind()
    }

    private var style: ReaderStyle {
        let settings = app.settings
        return ReaderStyle(
            fontFamily: settings.value(Settings.fontFamily),
            fontSize: settings.value(Settings.fontSize),
            theme: settings.value(Settings.viewerTheme),
            isDark: isDark,
            editOnDoubleClick: settings.value(Settings.doubleClickToEdit)
        )
    }

    private func follow(_ link: URL) {
        if ["http", "https", "mailto"].contains(link.scheme?.lowercased()) {
            NSWorkspace.shared.open(link)
        } else if let path = WebSchemeHandler.documentPath(of: link), path.lowercased().hasSuffix(".md") {
            if FileManager.default.fileExists(atPath: path) {
                open(URL(fileURLWithPath: path))
            } else {
                message = Message(
                    title: String(localized: "Note Not Found"),
                    text: String(localized: "“\((path as NSString).lastPathComponent)” doesn’t exist.")
                )
            }
        }
    }

    private func setTask(_ checked: Bool, onLine line: Int) {
        guard let url = openNote, let fingerprint = shown?.fingerprint else { return }
        Task {
            do {
                let outcome = try await Task.detached {
                    try NoteFile.setTask(checked, onLine: line, of: url, expecting: fingerprint)
                }.value
                guard case .saved = outcome else {
                    // The note moved on since this page was rendered, so the
                    // checkbox may have meant another line. Show what's there.
                    message = Message(
                        title: String(localized: "The Note Has Changed"),
                        text: String(localized: "It changed since it was shown, so the checkbox wasn’t saved. Stenmark has reloaded it.")
                    )
                    reloadOpenNote()
                    return
                }
                // The page already shows the tick. Rendering again would only
                // make it jump, so this just notes what's on disk now.
                shown = try await Task.detached { try NoteFile.load(url) }.value
            } catch {
                show(error, title: String(localized: "Couldn’t Save the Checkbox"))
                reloadOpenNote()
            }
        }
    }

    // MARK: Find and contents

    func showFind() {
        isFindVisible = true
    }

    func closeFind() {
        isFindVisible = false
        findQuery = ""
        findState = FindState()
        reader.clearFind()
    }

    func runFind() {
        let query = findQuery
        Task { findState = await reader.find(query) }
    }

    func findNext(_ step: Int) {
        guard findState.count > 0 else { return }
        let index = (findState.current + step + findState.count) % findState.count
        // Straight away, not when the page answers: pressing ⌘G quickly would
        // otherwise step from the same place twice.
        findState.current = index
        Task { _ = await reader.findGoTo(index) }
    }

    func jump(to heading: ReaderHeading) {
        isContentsVisible = false
        reader.scroll(toLine: heading.line)
    }

    // MARK: Helpers

    private func show(_ error: Error, title: String) {
        message = Message(title: title, text: error.localizedDescription)
    }

    private func readerMenuItems() -> [NSMenuItem] {
        let back = ClosureMenuItem(String(localized: "Back")) { [weak self] in self?.goBack() }
        back.isEnabled = canGoBack
        let forward = ClosureMenuItem(String(localized: "Forward")) { [weak self] in self?.goForward() }
        forward.isEnabled = canGoForward
        return [back, forward]
    }
}

/// A menu item that runs a closure, for menus built in code.
final class ClosureMenuItem: NSMenuItem {
    private let run: @MainActor () -> Void

    init(_ title: String, run: @escaping @MainActor () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(activate), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @MainActor @objc private func activate() { run() }

}
