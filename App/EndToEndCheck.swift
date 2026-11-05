// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

#if DEBUG
import AppKit
import StenmarkCore
import StenmarkWeb

/// Drives the real window through what the reader does, against a throwaway
/// copy of `assets/demo/notes`, and reports each step. Nothing here is mocked:
/// clicks go to the page, and changes arrive through FSEvents.
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
        }
        guard let root = window.root else { return }
        let welcome = root.appending(path: "Welcome.md")
        let linked = root.appending(path: "Sub Folder/Linked Note.md")

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
        window.message = nil
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

        try? report.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
#endif
