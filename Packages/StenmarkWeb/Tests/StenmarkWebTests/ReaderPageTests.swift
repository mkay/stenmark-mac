// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Foundation
import Testing
import WebKit
@testable import StenmarkWeb

/// The real page in a real web view, so these run one at a time.
@MainActor @Suite(.serialized) struct ReaderPageTests {
    let style = ReaderStyle(fontFamily: "Helvetica", fontSize: 16, theme: "auto", isDark: false, editOnDoubleClick: true)
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())

    private func show(_ markdown: String, offset: Int = 0) async -> ReaderWebView {
        let reader = ReaderWebView()
        let html = MarkdownRenderer().html(markdown, lineOffset: offset)
        await reader.show(ReaderPage.html(body: html, style: style), folder: folder)
        return reader
    }

    private func value(_ reader: ReaderWebView, _ script: String) async -> String {
        let result = try? await reader.webView.evaluateJavaScript(script)
        return result.map { "\($0)" } ?? "nil"
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(250))
    }

    @Test("Nothing in a note runs", arguments: [
        "<script>document.title='ran'</script>",
        "<img src=x onerror=\"document.title='ran'\">",
        "<svg onload=\"document.title='ran'\"></svg>",
        "<a id=l href=\"javascript:document.title='ran'\">x</a>",
        "<iframe srcdoc=\"<script>parent.document.title='ran'</script>\"></iframe>",
        "<body onload=\"document.title='ran'\">",
        "<details open ontoggle=\"document.title='ran'\">x</details>",
        "<style>@import url(https://example.com/x.css);</style>",
    ])
    func blocksScripts(html: String) async {
        let reader = await show(html + "\n\nAfter\n")
        _ = await value(reader, "document.getElementById('l')?.click(); 1")
        await settle()
        #expect(await value(reader, "document.title") != "ran")
        #expect(await value(reader, "typeof stenmark") == "object", "the page's own script still works")
    }

    /// Without this, the test above could pass because the attacks are broken.
    @Test func thePolicyIsWhatStopsThem() async {
        let reader = ReaderWebView()
        let body = MarkdownRenderer().html("<script>document.title='ran'</script>\n")
        let open = ReaderPage.html(body: body, style: style)
            .replacingOccurrences(of: ReaderPage.contentSecurityPolicy, with: "default-src * 'unsafe-inline'")
        await reader.show(open, folder: folder)
        await settle()
        #expect(await value(reader, "document.title") == "ran")
    }

    @Test func aRedirectInANoteGoesNowhere() async {
        let reader = await show("<meta http-equiv=\"refresh\" content=\"0;url=https://example.com/\">\n\nStays\n")
        await settle()
        await settle()
        #expect(await value(reader, "document.body.textContent").contains("Stays"))
    }

    @Test func remoteImagesArentFetched() async {
        let reader = await show("![x](https://example.com/x.png)\n")
        await settle()
        #expect(await value(reader, "document.querySelector('img').naturalWidth") == "0")
    }

    @Test func clickedLinksGoToTheApp() async {
        let reader = await show("[a](Some Note.md) [b](https://example.com/)\n")
        var links: [URL] = []
        reader.onLink = { links.append($0) }
        _ = await value(reader, "document.querySelectorAll('a').forEach(a => a.click()); 1")
        await settle()
        #expect(links.count == 2)
        #expect(WebSchemeHandler.documentPath(of: links[0])?.hasSuffix("/Some Note.md") == true)
        #expect(links[1].absoluteString == "https://example.com/")
        #expect(await value(reader, "typeof stenmark") == "object", "the page stayed")
    }

    @Test func checkboxesReportTheirOwnLine() async {
        let reader = await show("```\n- [ ] not a task\n```\n\n- [ ] real\n", offset: 4)
        var toggles: [(Int, Bool)] = []
        reader.onTaskToggled = { toggles.append(($0, $1)) }
        _ = await value(reader, "document.querySelector('input').click(); 1")
        await settle()
        #expect(toggles.count == 1)
        #expect(toggles.first?.0 == 9)
        #expect(toggles.first?.1 == true)
    }

    @Test func theCopyButtonCopiesEverything() async {
        let reader = await show("```sh\n#!/bin/sh\n\n# a comment\necho hi\n```\n")
        var copied: [String] = []
        reader.onCopyCode = { copied.append($0) }
        _ = await value(reader, "document.querySelector('.copy-btn').click(); 1")
        await settle()
        #expect(copied == ["#!/bin/sh\n\n# a comment\necho hi\n"])
    }

    @Test func headingsKnowTheirLines() async {
        let reader = await show("Title\n=====\n\n#NoSpace\n\n## Real\n", offset: 2)
        let headings = await reader.headings()
        #expect(headings.map(\.title) == ["Title", "NoSpace", "Real"])
        #expect(headings.map(\.line) == [3, 6, 8])
        #expect(headings.map(\.level) == [1, 1, 2])
    }

    @Test func findsAndClears() async {
        let reader = await show("One needle, two NEEDLE\n\n```\nneedle\n```\n")
        var state = await reader.find("needle")
        #expect(state.count == 3)
        #expect(state.current == 0)
        state = await reader.findGoTo(2)
        #expect(state.current == 2)
        #expect(await value(reader, "document.querySelectorAll('.sf-current').length") == "1")
        reader.clearFind()
        await settle()
        #expect(await value(reader, "document.querySelectorAll('mark').length") == "0")
    }

    @Test func aQueryIsNeverCode() async {
        let reader = await show("Text\n")
        let state = await reader.find("'); document.title='ran'; ('")
        #expect(state.count == 0)
        #expect(await value(reader, "document.title") != "ran")
    }

    @Test func doubleClickNamesTheLine() async {
        let reader = await show("First\n\nSecond para\n", offset: 3)
        var edits: [(Int, String)] = []
        reader.onEditRequest = { edits.append(($0, $1)) }
        _ = await value(reader, "document.querySelectorAll('p')[1].dispatchEvent(new MouseEvent('dblclick', {bubbles: true})); 1")
        await settle()
        #expect(edits.first?.0 == 6)
    }

    @Test func aFontNameCantBreakOutOfTheStyleSheet() {
        var hostile = style
        hostile.fontFamily = "x\"; } </style><script>alert(1)</script>"
        #expect(!ReaderPage.html(body: "", style: hostile).contains("<script>"))
    }

    @Test func everyThemeHasItsHighlightFile() {
        for (name, theme) in ReaderPage.themes {
            let url = WebSchemeHandler.bundledRoot("Reader").appending(path: "highlight/\(theme.highlight).min.css")
            #expect(FileManager.default.fileExists(atPath: url.path), "\(name)")
        }
    }
}
