// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

#if DEBUG
import AppKit
import StenmarkCore
import StenmarkWeb
import WebKit

/// Drives the real window through what the reader does, against a throwaway
/// copy of `assets/demo/notes`, and reports each step. Nothing here is mocked:
/// clicks go to the page, and changes arrive through FSEvents.
@MainActor enum FocusLog {
    /// Presses that found the app in the background.
    static var lost = 0
}

@MainActor struct EndToEndCheck {
    let window: WindowModel

    private var web: WKWebViewLike { WKWebViewLike(reader: window.reader) }

    struct WKWebViewLike {
        let reader: ReaderWebView
        @MainActor func value(_ script: String) async -> String {
            let result = try? await reader.webView.evaluateJavaScript(script)
            return result.map { "\($0)" } ?? "nil"
        }
    }

    private func waitFor(_ seconds: Double = 5, _ condition: @MainActor () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await condition()
    }

    private func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func run(reportingTo path: String) async {
        var report = ""
        func check(_ name: String, _ passed: Bool) {
            report += "\(passed ? "ok  " : "FAIL") \(name)\n"
            // As it goes, so that a crash still shows how far it got.
            try? report.write(toFile: path, atomically: true, encoding: .utf8)
        }
        guard let root = window.root else { return }
        let welcome = root.appending(path: "Welcome.md")
        let linked = root.appending(path: "Sub Folder/Linked Note.md")
        let original = read(welcome)

        check("lists load", await waitFor { window.overview.totalNotes == 4 })
        check("sidebar folders", window.overview.folders.map(\.name) == ["Sub Folder"])
        check("all documents groups", window.documents.count == 2)
        check("titles from headings", window.documents.first?.notes.contains { $0.displayName == "Welcome to the Demo" } == true)
        check("tags in rows", window.documents.first?.notes.first { $0.fileName == "Welcome.md" }?.tags == ["demo", "tour"])

        window.select(.folder(root.appending(path: "Sub Folder")))
        check("folder selection", await waitFor { window.documents.first?.notes.map(\.fileName) == ["Hostile.md", "Linked Note.md"] })
        window.select(.all)
        _ = await waitFor { window.documents.count == 2 }

        check("selector lists the tree", window.rootChoices.map(\.name) == [root.lastPathComponent, "Sub Folder"])
        check("selector indents", window.rootChoices.map(\.depth) == [0, 1])
        let sub = root.appending(path: "Sub Folder")
        window.switchRoot(to: sub)
        check("switching root", await waitFor { window.overview.totalNotes == 2 && window.root == sub })
        check("selector still offers the ceiling", window.rootChoices.first?.url == root)
        window.switchRoot(to: URL(fileURLWithPath: "/tmp"))
        check("a folder outside the ceiling is refused", window.root == sub)
        check("the root folder stays as it was", window.app.settings.value(Settings.rootDirectory) != sub.path)
        check("the choice is remembered", window.app.settings.value(Settings.lastRootFolder) == sub.path)
        check("and would be restored", window.app.settings.rememberedRoot(under: root)?.path == sub.path)
        window.switchRoot(to: root)
        check("back to the ceiling", await waitFor { window.overview.totalNotes == 4 && window.documents.count == 2 })

        window.open(welcome)
        check("opens a note", await waitFor { window.openNote == welcome && !window.headings.isEmpty })
        check("page has the heading", await web.value("document.querySelector('h1').textContent") == "Welcome to the Demo")
        check("frontmatter isn't shown", !(await web.value("document.body.textContent")).contains("tags:"))
        check("source lines count frontmatter", window.headings.first?.line == 6)
        check("word count", window.wordCount > 10)
        check("relative image loads", await waitFor { await web.value("document.querySelector('img[alt=near]').naturalWidth") == "1" })
        check("image above the folder loads", await waitFor { await web.value("document.querySelector('img[alt=above]').naturalWidth") == "1" })
        check("code is highlighted", await web.value("document.querySelectorAll('pre .hljs-keyword, pre [class^=hljs-]').length") != "0")

        let renders = window.renderCount
        let before = read(welcome)
        _ = await web.value("document.querySelector('li.task-item input:not([checked])').click(); 1")
        check("tick reaches the file", await waitFor { read(welcome) != before })
        let after = read(welcome)
        check("tick changes one character", zip(before, after).filter { $0 != $1 }.count == 1 && before.count == after.count)
        try? await Task.sleep(for: .seconds(1.2))
        check("own save doesn't re-render", window.renderCount == renders)

        // A change from elsewhere, written the way sync does.
        let incoming = root.appending(path: ".incoming")
        try? Data((after + "\nA line from the other machine.\n").utf8).write(to: incoming)
        rename(incoming.path, welcome.path)
        check("change from sync reloads", await waitFor { await web.value("document.body.textContent").contains("the other machine") })

        // The reader is stale for a moment: ticking now must not hit the wrong line.
        let shifted = "first\n" + read(welcome)
        try? Data(shifted.utf8).write(to: incoming)
        rename(incoming.path, welcome.path)
        _ = await web.value("document.querySelector('li.task-item input').click(); 1")
        try? await Task.sleep(for: .seconds(1.5))
        check("stale tick changes nothing wrong", read(welcome) == shifted || window.message != nil)
        await click("OK")
        _ = await waitFor { await web.value("document.body.textContent").contains("first") }

        _ = await web.value("document.querySelector('a[href*=Linked]').click(); 1")
        check("link to a note with spaces", await waitFor { window.openNote?.path == linked.path })
        check("history has it", window.canGoBack)
        window.goBack()
        check("back", await waitFor { window.openNote == welcome })
        check("forward is available", window.canGoForward)
        window.goForward()
        check("forward", await waitFor { window.openNote?.path == linked.path })
        window.goBack()
        _ = await waitFor { window.openNote == welcome && !window.headings.isEmpty }

        window.showFind()
        window.findQuery = "demo"
        window.runFind()
        check("find counts", await waitFor { window.findState.count >= 2 })
        let count = window.findState.count
        window.findNext(1)
        check("find next", await waitFor { window.findState.current == 1 })
        window.findNext(-1)
        window.findNext(-1)
        check("find wraps", await waitFor { window.findState.current == count - 1 })
        window.closeFind()
        check("find clears", await waitFor { await web.value("document.querySelectorAll('mark').length") == "0" })

        let target = window.headings.last
        if let target { window.jump(to: target) }
        check("contents scrolls", await waitFor { await web.value("window.scrollY") != "0" })

        window.open(root.appending(path: "Sub Folder/Hostile.md"))
        check("hostile note opens", await waitFor { await web.value("document.body.textContent").contains("Harmless") })
        try? await Task.sleep(for: .milliseconds(400))
        check("its script doesn't run", await web.value("document.title") != "ran")
        check("it stays on the page", await web.value("typeof stenmark") == "object")

        let fresh = root.appending(path: "Brand New.md")
        try? Data("# Fresh\n".utf8).write(to: fresh)
        check("new note appears", await waitFor { window.overview.totalNotes == 5 })
        let open = root.appending(path: "Sub Folder/Hostile.md")
        try? FileManager.default.removeItem(at: open)
        check("deleted note closes", await waitFor { window.openNote == nil })
        check("list follows", await waitFor { window.overview.totalNotes == 4 })
        check("no error for a note that vanished", window.message == nil)

        window.isDark = true
        window.open(welcome)
        _ = await waitFor { window.openNote == welcome }
        check("dark theme", await waitFor { await web.value("getComputedStyle(document.body).backgroundColor") == "rgb(36, 36, 36)" })
        window.isDark = false
        check("back to light reloads", await waitFor { await web.value("getComputedStyle(document.body).backgroundColor") == "rgb(255, 255, 255)" })

        await editing(root: root, welcome: welcome, check: check)
        await library(root: root, welcome: welcome, original: original, check: check)
        report += "info focus lost before \(FocusLog.lost) key presses\n"
        try? report.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func library(root: URL, welcome: URL, original: String, check: (String, Bool) -> Void) async {
        let manager = FileManager.default
        let plain = root.appending(path: "Plain.md")
        let sub = root.appending(path: "Sub Folder")
        // The editing steps typed above the frontmatter, on purpose.
        syncWrite(original, to: welcome)
        window.select(.all)
        _ = await waitFor { window.documents.count == 2 && window.documents.first?.notes.contains { !$0.tags.isEmpty } == true }

        // Pins.
        window.togglePin(plain, isFolder: false)
        check("a pinned note comes first", window.arranged(window.documents.first?.notes ?? []).first?.url.path == plain.path)
        check("pins are saved", window.app.settings.value(Settings.pinnedFiles) == [plain.path])
        window.togglePin(sub, isFolder: true)
        check("folders pin too", window.isFolderPinned(sub))

        // Quick filter, which also looks at tags.
        window.quickFilter = "TOUR"
        let filtered = window.arranged(window.documents.first?.notes ?? []).map(\.fileName)
        check("filter matches tags \(filtered)", filtered == ["Welcome.md"])
        window.quickFilter = ""

        // Creating.
        window.createNote(named: "Mu\u{0308}ller", in: root)
        check("a new note opens for writing", await waitFor { window.isEditing && window.openNote?.lastPathComponent == "Müller.md" })
        let created = window.openNote ?? plain
        check("holds its heading", read(created) == "# Müller\n")
        try? await Task.sleep(for: .milliseconds(300))
        window.leaveEdit()
        _ = await waitFor { !window.isEditing }
        let names = (try? manager.contentsOfDirectory(atPath: root.path)) ?? []
        check("named in composed form", names.contains { Array($0.utf8) == Array("M\u{00FC}ller.md".utf8) })
        window.createNote(named: "../escape", in: root)
        check("a bad name is refused", await waitFor { window.message != nil })
        await click("OK")
        check("and nothing escaped", !manager.fileExists(atPath: root.deletingLastPathComponent().appending(path: "escape.md").path))

        // Renaming the open note, with a pin on it.
        window.togglePin(created, isFolder: false)
        window.rename(created, to: "Renamed")
        let renamed = root.appending(path: "Renamed.md")
        check("rename follows the open note", await waitFor { window.openNote?.path == renamed.path })
        check("and keeps the extension", manager.fileExists(atPath: renamed.path))
        check("and the pin", window.isPinned(renamed) && !window.isPinned(created))

        window.rename(renamed, to: "Welcome")
        check("a taken name is refused", await waitFor { window.message != nil })
        await click("OK")
        check("and overwrites nothing", read(welcome).contains("Welcome to the Demo") && manager.fileExists(atPath: renamed.path))

        // Moving, and renaming the folder around the open note.
        window.move(renamed, to: sub)
        let moved = sub.appending(path: "Renamed.md")
        check("move follows the open note", await waitFor { window.openNote?.path == moved.path })
        window.select(.folder(sub))
        _ = await waitFor { window.documents.first?.notes.contains { $0.fileName == "Renamed.md" } == true }
        window.rename(sub, to: "Other Folder")
        let other = root.appending(path: "Other Folder")
        let inside = other.appending(path: "Renamed.md")
        check("renaming a folder follows the note in it", await waitFor { window.openNote?.path == inside.path })
        check("and the selection", window.selection == .folder(other) || { if case .folder(let url) = window.selection { url.path == other.path } else { false } }())
        check("and the pins", window.isFolderPinned(other) && window.isPinned(inside))
        check("the page still shows it", await waitFor {
            ((try? await window.reader.webView.evaluateJavaScript("document.body.textContent")) as? String)?.contains("Müller") == true
        })

        // Tags.
        window.open(welcome)
        _ = await waitFor { window.openNote == welcome && window.openNoteTags == ["demo", "tour"] }
        check("tags index", await waitFor { window.allTags == ["demo", "tour"] })
        window.setTags(["demo", "tour", "2026-11-05"])
        check("adding a tag writes it as Linux would", await waitFor { read(welcome).hasPrefix("---\ntags:\n- '2026-11-05'\n- demo\n- tour\n---\n") })
        check("the index follows", await waitFor { window.allTags.contains("2026-11-05") })
        check("so does the note", await waitFor { window.openNoteTags.contains("2026-11-05") })
        window.showTags(selecting: "demo")
        check("tag filter finds it", await waitFor { window.tagResults.map(\.fileName) == ["Welcome.md"] })
        window.toggleTag("tour")
        check("two tags still match", await waitFor { window.tagResults.count == 1 })
        window.setTags(["demo", "tour"])
        check("removing a tag works", await waitFor { !read(welcome).contains("2026-11-05") })
        _ = await waitFor { !window.allTags.contains("2026-11-05") }
        window.closeLists()
        _ = await enter()
        let beforeTags = read(welcome)
        window.setTags(["nope"])
        try? await Task.sleep(for: .milliseconds(400))
        check("no tag edits while editing", read(welcome) == beforeTags)
        window.leaveEdit()
        _ = await waitFor { !window.isEditing }

        // Search.
        window.select(.all)
        window.showSearch()
        window.searchQuery = "PLANTS"
        window.runSearch()
        check("search finds any case", await waitFor { window.searchHits.map(\.file.lastPathComponent) == ["Welcome.md"] })
        check("with its context", window.searchHits.first?.match == "plants" && window.searchHits.first?.before.isEmpty == false)
        window.select(.folder(other))
        window.runSearch()
        check("search keeps to the folder", await waitFor { !window.isSearching })
        check("so nothing's found there", window.searchHits.isEmpty)
        window.closeLists()
        window.select(.all)

        // Rich text, with the clipboard put back afterwards.
        let board = NSPasteboard.general
        let clipboard = board.string(forType: .string)
        window.copyAsRichText()
        check("rich copy has HTML", board.string(forType: .html)?.contains("<h1") == true)
        check("and the Markdown", board.string(forType: .string)?.contains("# Welcome") == true)
        check("without frontmatter in the HTML", board.string(forType: .html)?.contains("tags:") == false)
        board.clearContents()
        if let clipboard { board.setString(clipboard, forType: .string) }

        // PDF.
        let pdf = root.deletingLastPathComponent().appending(path: "export.pdf")
        await window.reader.exportPDF(to: pdf)
        let document = CGPDFDocument(pdf as CFURL)
        check("PDF export", (document?.numberOfPages ?? 0) >= 1)
        check("Open With finds apps", !NSWorkspace.shared.urlsForApplications(toOpen: welcome).isEmpty)

        // From Finder.
        let outside = root.deletingLastPathComponent().appending(path: "Elsewhere/Outside.md")
        try? manager.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("# From Finder\n".utf8).write(to: outside)
        window.handleOpen(outside)
        check("opens a note from elsewhere", await waitFor { window.openNote?.path == outside.path })
        try? await Task.sleep(for: .milliseconds(400))
        syncWrite("# Changed Elsewhere\n", to: outside)
        check("and follows changes to it", await waitFor {
            ((try? await window.reader.webView.evaluateJavaScript("document.body.textContent")) as? String)?.contains("Changed Elsewhere") == true
        })
        window.handleOpen(outside.deletingLastPathComponent())
        check("a folder outside the root is refused", await waitFor { window.message != nil } && window.root?.path == root.path)
        await click("OK")
        window.handleOpen(other)
        check("a folder inside it is fine", await waitFor { window.root?.path == other.path })
        window.switchRoot(to: root)
        _ = await waitFor { window.root?.path == root.path }

        // Layouts, measured, with real keys for the first two. 1, 2 and 3 are key
        // codes 18, 19 and 20 on any layout.
        window.open(welcome)
        _ = await waitFor { window.openNote == welcome }
        let page = window.reader.webView
        await press(18, .maskCommand)
        check("⌘1 shows all columns", await waitFor { window.columnLayout == .all })
        try? await Task.sleep(for: .milliseconds(500))
        let allWidth = page.frame.width
        await press(19, .maskCommand)
        check("⌘2 keeps the documents", await waitFor { window.columnLayout == .documents })
        try? await Task.sleep(for: .milliseconds(700))
        let documentsWidth = page.frame.width
        check("the sidebar really goes (\(Int(allWidth)) to \(Int(documentsWidth)))", documentsWidth > allWidth + 50)
        await press(20, .maskCommand)
        let fullWidth = page.window?.frame.width ?? 0
        check("⌘3 gives the note the whole width", await waitFor { page.frame.width >= (page.window?.frame.width ?? 1) - 1 })
        check("wider than with the documents (\(Int(documentsWidth)) to \(Int(fullWidth)))", fullWidth > documentsWidth + 50)
        check("the layout is saved", window.app.settings.value(Settings.columnLayout) == "note")
        check("the note is still on the page", await web.value("document.querySelector('h1').textContent") == "Welcome to the Demo")
        window.toggleNoteOnly()
        check("the note's button brings back the layout it left", await waitFor { window.columnLayout == .documents })
        window.toggleNoteOnly()
        check("and returns to the note alone", await waitFor { window.columnLayout == .note })
        window.setLayout(.all)
        _ = await waitFor { !window.showsNoteOnly }
        try? await Task.sleep(for: .milliseconds(700))
        let sidebarButton = page.window?.toolbar?.items.first { $0.itemIdentifier.rawValue.lowercased().contains("sidebar") }
        check("the sidebar has its own button", sidebarButton != nil)
        await mouseClick(sidebarButton?.view)
        check("which hides only the sidebar", await waitFor { window.columnLayout == .documents })
        try? await Task.sleep(for: .milliseconds(700))
        await mouseClick(sidebarButton?.view)
        check("and shows it again", await waitFor { window.columnLayout == .all })
        try? await Task.sleep(for: .milliseconds(700))
        window.toggleNoteOnly()
        check("all columns go to the note alone", await waitFor { window.columnLayout == .note })
        window.toggleNoteOnly()
        check("and come back with the sidebar", await waitFor { window.columnLayout == .all })
        window.setLayout(.documents)
        _ = await waitFor { !window.showsNoteOnly }
        window.setLayout(.note)
        window.showSearch()
        check("search brings the documents back", await waitFor { window.columnLayout == .documents && window.listMode == .search })
        window.closeLists()
        window.setLayout(.note)
        window.showTags()
        check("so do tags", await waitFor { window.columnLayout == .documents && window.listMode == .tags })
        window.closeLists()
        window.setLayout(.documents)
        _ = await enter()
        check("editing takes the width from any layout", await waitFor { window.showsNoteOnly })
        window.leaveEdit()
        check("and returns to it", await waitFor { !window.isEditing && !window.showsNoteOnly && window.columnLayout == .documents })
        window.setLayout(.all)

        // The tint, which Settings turns off and on through the same two calls.
        check("the lists are tinted by default", window.listBackground != .clear)
        try? window.app.settings.set(Settings.tintSidebar, to: false)
        window.app.styleChanged()
        check("the tint can be turned off", window.listBackground == .clear)
        try? window.app.settings.set(Settings.tintSidebar, to: true)
        window.app.styleChanged()
        // A style change reloads the open note on the next update, which would
        // cancel a note opened in the same moment.
        try? await Task.sleep(for: .milliseconds(500))

        // The licences, which MIT and BSD need to ship with the app.
        check("the licences are bundled", ["@codemirror/view", "markdown-it", "highlight.js", "Yams", "libYAML", "Sparkle"].allSatisfy { LicencesView.text.contains($0) })
        window.showLicences = true
        check("and shown", await waitFor { NSApp.windows.contains { $0.sheetParent != nil } })
        let sheet = { NSApp.windows.first { $0.sheetParent != nil } }
        func focusSheet() async {
            NSApp.activate(ignoringOtherApps: true)
            sheet()?.makeKeyAndOrderFront(nil)
            _ = await waitFor(2) { NSApp.isActive && NSApp.keyWindow?.sheetParent != nil }
        }
        await focusSheet()
        check("the licences have text", (sheet()?.contentView.map { firstTextView(in: $0)?.string.count ?? 0 } ?? 0) > 1000)
        await press(36)
        check("Return closes them", await waitFor { !window.showLicences })
        try? await Task.sleep(for: .milliseconds(500))
        window.showLicences = true
        _ = await waitFor { sheet() != nil }
        try? await Task.sleep(for: .milliseconds(500))
        await focusSheet()
        // The sheet has 24 points of padding, and Close sits in its bottom corner.
        if let width = sheet()?.frame.width { await mouseClick(at: NSPoint(x: width - 50, y: 34), in: sheet()) }
        check("so does the Close button", await waitFor { !window.showLicences })
        try? await Task.sleep(for: .milliseconds(500))

        // The Trash. One note with a name of its own, cleaned up by the script.
        let doomed = root.appending(path: "stenmark-e2e-trash.md")
        try? Data("x".utf8).write(to: doomed)
        _ = await waitFor { window.overview.rootNotes > 0 }
        window.open(doomed)
        _ = await waitFor { window.openNote?.path == doomed.path }
        window.trash(doomed, isFolder: false)
        check("trashing closes the note", await waitFor { window.openNote == nil })
        check("and it's gone from here", !manager.fileExists(atPath: doomed.path))
        check("and from history", !window.history.contains { $0.path == doomed.path })
        window.trash(other, isFolder: true)
        check("a folder with notes is refused", await waitFor { window.message != nil })
        check("and stays", manager.fileExists(atPath: other.path))
        await click("OK")
        let empty = root.appending(path: "stenmark-e2e-empty")
        window.createFolder(named: "stenmark-e2e-empty", in: root)
        _ = await waitFor { window.rootChoices.contains { $0.url.path == empty.path } }
        window.switchRoot(to: empty)
        check("a folder without notes says so", await waitFor { window.root?.path == empty.path && window.isLibraryEmpty })
        window.switchRoot(to: root)
        check("and one with notes doesn't", await waitFor { window.root?.path == root.path && !window.isLibraryEmpty })
        window.trash(empty, isFolder: true)
        check("an empty folder goes", await waitFor { !manager.fileExists(atPath: empty.path) })
    }

    /// Writes a note the way sync does, by renaming a new file over it.
    private func syncWrite(_ text: String, to url: URL) {
        let incoming = url.deletingLastPathComponent().appending(path: ".incoming")
        try? Data(text.utf8).write(to: incoming)
        rename(incoming.path, url.path)
    }

    /// The key labelled Z on a German keyboard, which is where these run. Key
    /// codes are physical keys, and on QWERTY this one is Y.
    private let zKey: UInt16 = 16

    /// Clicks a button in the open alert, as a person would. Clearing the state
    /// from code instead would dismiss the alert during a SwiftUI update, which
    /// crashes, and which no person can do.
    private func click(_ title: String) async {
        func button(in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == title { return button }
            return view.subviews.lazy.compactMap(button(in:)).first
        }
        var target: NSButton?
        _ = await waitFor {
            target = NSApp.windows.compactMap(\.attachedSheet).compactMap { $0.contentView.flatMap(button(in:)) }.first
            return target != nil
        }
        target?.performClick(nil)
        _ = await waitFor { NSApp.windows.allSatisfy { $0.attachedSheet == nil } }
    }

    private func firstTextView(in view: NSView) -> NSTextView? {
        (view as? NSTextView) ?? view.subviews.lazy.compactMap(firstTextView(in:)).first
    }

    /// A real click in the middle of a view. SwiftUI's toolbar items have no
    /// action to send, so this is the only way to press one.
    private func mouseClick(_ view: NSView?) async {
        guard let view else { return }
        await mouseClick(at: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil), in: view.window)
    }

    private func mouseClick(at point: NSPoint, in target: NSWindow?) async {
        guard let target else { return }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: target.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ) else { continue }
            NSApp.sendEvent(event)
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// A real key press through NSApp, so that it meets the menu bar first.
    private func press(_ code: UInt16, _ flags: CGEventFlags = []) async {
        // Keys go to the key window, so someone using the Mac during a run would
        // otherwise take them away from the test.
        if !NSApp.isActive || NSApp.keyWindow == nil {
            FocusLog.lost += 1
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            _ = await waitFor(2) { NSApp.isActive && NSApp.keyWindow != nil }
            if window.isEditing { await window.editor.focus() }
        }
        for down in [true, false] {
            guard let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { continue }
            cgEvent.flags = flags
            if let event = NSEvent(cgEvent: cgEvent) { NSApp.sendEvent(event) }
        }
        try? await Task.sleep(for: .milliseconds(200))
    }

    private func enter() async -> Bool {
        window.enterEdit()
        let entered = await waitFor { window.isEditing }
        try? await Task.sleep(for: .milliseconds(300))
        return entered
    }

    private func type(_ text: String) async {
        try? await window.editor.call("insertText", text)
        _ = await waitFor { window.editor.text.contains(text) }
    }

    private func stamp(_ url: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return "\(attributes?[.systemFileNumber] ?? 0) \(attributes?[.modificationDate] ?? 0)"
    }

    private func editing(root: URL, welcome: URL, check: (String, Bool) -> Void) async {
        let plain = root.appending(path: "Plain.md")
        NSApp.activate(ignoringOtherApps: true)
        window.open(welcome)
        _ = await waitFor { window.openNote == welcome && !window.headings.isEmpty }

        // Nothing typed: the file must not even be touched.
        let before = stamp(welcome)
        check("enters edit mode", await enter())
        check("editor holds the note", window.editor.text == read(welcome))
        let wide = await waitFor {
            let editor = window.editor.webView
            guard let host = editor.window else { return false }
            return editor.frame.width > host.frame.width * 0.9
        }
        check("editing takes the window's width (\(Int(window.editor.webView.frame.width)) of \(Int(window.editor.webView.window?.frame.width ?? 0)))", wide)
        window.leaveEdit()
        check("leaves edit mode", await waitFor { !window.isEditing })
        check("the lists come back", await waitFor { !window.hidesLists })
        check("no edits means no write", stamp(welcome) == before)

        // Saving, and the keys, through the real event path.
        _ = await enter()
        await window.editor.focus()
        await type("typed ")
        check("an edit is unsaved", window.hasUnsavedChanges)
        await press(1, .maskCommand)
        check("⌘S saves", await waitFor { read(welcome).contains("typed ") })
        check("saved means clean", await waitFor { !window.hasUnsavedChanges })
        try? await Task.sleep(for: .seconds(1.2))
        check("own save raises no alarm", !window.diskChangedWhileEditing && window.conflict == nil)
        await press(zKey, .maskCommand)
        check("⌘Z undoes", await waitFor { !window.editor.text.contains("typed ") })
        await press(zKey, [.maskCommand, .maskShift])
        check("⇧⌘Z redoes", await waitFor { window.editor.text.contains("typed ") })
        await press(11, .maskCommand)
        check("⌘B formats", await waitFor { window.editor.text.contains("****") })
        await press(zKey, .maskCommand)
        _ = await waitFor { !window.editor.text.contains("****") }
        // Paste and cut meet the same menu, so they get real keys too. The
        // clipboard is put back afterwards.
        let board = NSPasteboard.general
        let clipboard = board.string(forType: .string)
        board.clearContents()
        board.setString("pasted ", forType: .string)
        await press(9, .maskCommand)
        check("⌘V pastes", await waitFor { window.editor.text.contains("pasted ") })
        await press(zKey, .maskCommand)
        check("undo takes the paste back", await waitFor { !window.editor.text.contains("pasted ") })
        await window.editor.goTo(line: 8, center: false)
        await press(0, .maskCommand)
        await press(8, .maskCommand)
        let copied = board.string(forType: .string) ?? ""
        check("⌘A then ⌘C copies everything", copied.contains("Welcome to the Demo") && copied.contains("The End"))
        await press(7, .maskCommand)
        check("⌘X cuts", await waitFor { window.editor.text.isEmpty })
        await press(zKey, .maskCommand)
        check("undo brings it back", await waitFor { window.editor.text.contains("The End") })
        board.clearContents()
        if let clipboard { board.setString(clipboard, forType: .string) }

        await press(3, .maskCommand)
        check("⌘F opens the editor's search", await waitFor {
            (try? await window.editor.webView.evaluateJavaScript("document.querySelectorAll('.cm-panel').length")) as? Int == 1
        })
        // Esc works outwards: the search panel, then a selection (undoing the
        // cut left everything selected), then edit mode.
        await press(53)
        await window.editor.focus()
        check("the first Esc closes search", window.isEditing)
        await press(53)
        check("the next clears the selection", window.isEditing)
        await press(53)
        check("the next leaves edit mode", await waitFor { !window.isEditing })

        // Changes arriving from sync while the note is open in the editor.
        _ = await enter()
        syncWrite(read(welcome) + "\nFrom sync, no edits here.\n", to: welcome)
        check("no edits: the editor follows", await waitFor { window.editor.text.contains("no edits here") })

        await type("mine ")
        let theirs = read(welcome) + "\nFrom sync, with edits here.\n"
        syncWrite(theirs, to: welcome)
        check("edits: a warning, not a reload", await waitFor { window.diskChangedWhileEditing })
        check("edits survive", window.editor.text.contains("mine "))
        window.saveNow()
        check("saving asks", await waitFor { window.conflict != nil })
        check("nothing was overwritten", read(welcome) == theirs)

        if let conflict = window.conflict { window.resolve(conflict, with: .cancel) }
        check("Keep Editing keeps the text", window.isEditing && window.editor.text.contains("mine ") && read(welcome) == theirs)
        window.saveNow()
        _ = await waitFor { window.conflict != nil }
        if let conflict = window.conflict { window.resolve(conflict, with: .keepBoth) }
        let copy = root.appending(path: "Welcome (Mac copy).md")
        check("Keep Both writes a copy", await waitFor { read(copy).contains("mine ") })
        check("and shows the other version", await waitFor { window.editor.text == theirs })
        check("and leaves it alone", read(welcome) == theirs)
        try? FileManager.default.removeItem(at: copy)

        await type("again ")
        syncWrite(theirs + "More.\n", to: welcome)
        _ = await waitFor { window.diskChangedWhileEditing }
        window.saveNow()
        _ = await waitFor { window.conflict != nil }
        if let conflict = window.conflict { window.resolve(conflict, with: .keepTheirs) }
        check("Use the Other Version", await waitFor { window.editor.text == theirs + "More.\n" && !window.hasUnsavedChanges })

        await type("final ")
        syncWrite(theirs, to: welcome)
        _ = await waitFor { window.diskChangedWhileEditing }
        window.saveNow()
        _ = await waitFor { window.conflict != nil }
        if let conflict = window.conflict { window.resolve(conflict, with: .keepMine) }
        check("Use Mine", await waitFor { read(welcome).contains("final ") })
        check("then it's clean", await waitFor { !window.hasUnsavedChanges && !window.diskChangedWhileEditing })

        // Leaving with unsaved edits.
        let saved = read(welcome)
        await type("discard me ")
        window.open(plain)
        check("leaving asks first", await waitFor { window.unsavedPrompt != nil })
        await click("Cancel")
        check("Cancel stays", window.isEditing && window.openNote == welcome)
        window.open(plain)
        _ = await waitFor { window.unsavedPrompt != nil }
        await click("Don’t Save")
        check("Don't Save moves on", await waitFor { window.openNote == plain && !window.isEditing })
        try? await Task.sleep(for: .milliseconds(300))
        check("Don't Save really doesn't save", read(welcome) == saved)

        window.open(welcome)
        _ = await waitFor { window.openNote == welcome }
        try? await Task.sleep(for: .milliseconds(300))
        _ = await enter()
        await type("keep me ")
        window.open(plain)
        _ = await waitFor { window.unsavedPrompt != nil }
        await click("Save")
        check("Save moves on", await waitFor { window.openNote == plain && !window.isEditing })
        check("Save saved", read(welcome).contains("keep me "))

        // Closing the window.
        _ = await enter()
        await type("close me ")
        let host = NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
        host?.performClose(nil)
        check("closing asks first", await waitFor { window.unsavedPrompt != nil })
        check("and the window stays", host?.isVisible == true)
        await click("Cancel")
        try? await window.editor.setContent(window.pristineText)
        _ = await waitFor { !window.hasUnsavedChanges }

        // The note going away, and a save failing.
        await type("orphan ")
        let keep = read(plain)
        try? FileManager.default.removeItem(at: plain)
        window.saveNow()
        check("a deleted note asks", await waitFor { window.conflict != nil && window.conflict?.theirs == nil })
        check("nothing is recreated by itself", !FileManager.default.fileExists(atPath: plain.path))
        if let conflict = window.conflict { window.resolve(conflict, with: .keepMine) }
        check("Save It Again recreates it", await waitFor { read(plain).contains("orphan ") })
        try? Data(keep.utf8).write(to: plain)
        _ = await waitFor { !window.hasUnsavedChanges }
        try? await Task.sleep(for: .seconds(1))

        let folder = plain.deletingLastPathComponent()
        await type("cant write ")
        let guarded = read(plain)
        try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        window.saveNow()
        check("a failed save says so", await waitFor { window.message != nil })
        check("and keeps the text", window.isEditing && window.editor.text.contains("cant write "))
        check("and leaves the file", read(plain) == guarded)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        await click("OK")
        window.leaveEdit()
        check("and works once it can", await waitFor { !window.isEditing && read(plain).contains("cant write ") })

        // Line endings.
        let windows = root.appending(path: "Windows.md")
        try? Data("one\r\ntwo\r\n".utf8).write(to: windows)
        _ = await waitFor { window.overview.totalNotes == 5 }
        window.open(windows)
        _ = await waitFor { window.openNote == windows }
        try? await Task.sleep(for: .milliseconds(300))
        _ = await enter()
        await type("x")
        window.leaveEdit()
        _ = await waitFor { !window.isEditing }
        let bytes = (try? Data(contentsOf: windows)) ?? Data()
        check("CRLF survives an edit", bytes.count > 9 && !String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "").contains("\n"))

        // The preview, and picking up in the right place.
        window.open(welcome)
        _ = await waitFor { window.openNote == welcome }
        try? await Task.sleep(for: .milliseconds(300))
        // Found, because the earlier steps moved it.
        let line = (read(welcome).components(separatedBy: "\n").firstIndex { $0.contains("shelves") } ?? 0) + 1
        window.enterEdit(line: line, word: "shelves")
        _ = await waitFor { window.isEditing }
        try? await Task.sleep(for: .milliseconds(400))
        let active = try? await window.editor.webView.evaluateJavaScript("document.querySelector('.cm-activeLine').textContent") as? String
        check("double click lands on its line", active?.contains("shelves") == true)
        if !window.isPreviewVisible { window.togglePreview() }
        _ = try? await window.preview.webView.evaluateJavaScript("window.marker = 1; 0")
        await type("Preview me ")
        check("preview follows typing", await waitFor {
            ((try? await window.preview.webView.evaluateJavaScript("document.body.textContent")) as? String)?.contains("Preview me") == true
        })
        check("without reloading", (try? await window.preview.webView.evaluateJavaScript("window.marker")) as? Int == 1)
        check("preview has its copy buttons", (try? await window.preview.webView.evaluateJavaScript("document.querySelectorAll('.copy-btn').length")) as? Int ?? 0 > 0)
        await type("\n\n## Fresh Heading\n\n")
        check("contents follow the text", await waitFor { window.headings.contains { $0.title == "Fresh Heading" } })
        window.toggleTypewriter()
        check("typewriter is remembered", window.app.settings.value(Settings.editorTypewriter) == window.isTypewriterOn)
        window.toggleTypewriter()
        window.togglePreview()
        try? await window.editor.setContent(window.pristineText)
        _ = await waitFor { !window.hasUnsavedChanges }
        window.leaveEdit()
        check("all done", await waitFor { !window.isEditing })
    }
}
#endif
