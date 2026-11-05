// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Foundation
import JavaScriptCore
import Testing
import WebKit
@testable import StenmarkWeb

@MainActor @Test func editorRoundTrip() async throws {
    let editor = EditorWebView()
    await editor.load()
    try await editor.setContent("# Hi\n\nsome word here\n")
    try await editor.call("setTheme", "dracula", true, false)
    let background = try await editor.webView.evaluateJavaScript(
        "getComputedStyle(document.querySelector('.cm-editor')).backgroundColor") as? String
    #expect(background == "rgb(40, 42, 54)")

    try await editor.call("gotoLine", 3, "word", false)
    try await editor.call("formatBold")
    try await Task.sleep(for: .milliseconds(300))
    #expect(editor.text == "# Hi\n\nsome ****word here\n")
}

@MainActor @Test func schemeHandlerStaysInsideBundledFolders() {
    let handler = WebSchemeHandler()
    #expect(handler.file(for: URL(string: "stenmark://editor/editor.html")!) != nil)
    #expect(handler.file(for: URL(string: "stenmark://editor/../../secret")!) == nil)
    #expect(handler.file(for: URL(string: "stenmark://other/x")!) == nil)
}

@MainActor @Test func documentURLsRoundTrip() {
    let base = WebSchemeHandler.documentBase(for: URL(fileURLWithPath: "/tmp/Mein Ordner ü"))
    let link = URL(string: "Other%20Note.md", relativeTo: base)!.absoluteURL
    #expect(WebSchemeHandler.documentPath(of: link) == "/tmp/Mein Ordner ü/Other Note.md")
}

typealias Reader = MarkdownRenderer

@MainActor @Test func readerKeepsLinkTargetsWithSpaces() throws {
    let reader = Reader()
    #expect(reader.html("[a](../Some Folder/My Note.md)").contains(#"href="../Some%20Folder/My%20Note.md""#))
    #expect(reader.html(#"[a](my note.md "T")"#).contains(#"title="T""#))
    #expect(reader.html("![a](my pic.png)").contains(#"src="my%20pic.png""#))
}

@MainActor @Test func readerMatchesSmarty() throws {
    let html = Reader().html("../up -- a --- b ... (c)")
    #expect(html.contains("../up \u{2013} a \u{2014} b \u{2026} (c)"))
}

@MainActor @Test func readerTakesHeadingsWithoutASpace() throws {
    let reader = Reader()
    #expect(reader.html("#NoSpace").contains("<h1"))
    #expect(reader.html("Para\n#Mid\nmore").contains("<h1"))
    #expect(!reader.html("#!/bin/sh").contains("<h1"))
}

@MainActor @Test func checkboxesKnowTheirOwnLine() throws {
    let reader = Reader()
    // The fence must not throw the count off, as it does on Linux.
    let html = reader.html("```\n- [ ] not a task\n```\n\n- [ ] real\n1. [x] numbered\n")
    #expect(html.components(separatedBy: "<input").count == 3)
    #expect(html.contains(#"data-task-line="5""#))
    #expect(html.contains(#"checked data-task-line="6""#))
}

@MainActor @Test func sourceLinesCountFromTheTopOfTheFile() throws {
    let html = Reader().html("\n# Heading\n\n- [ ] x\n", lineOffset: 4)
    #expect(html.contains(#"<h1 data-source-line="6""#))
    #expect(html.contains(#"data-task-line="8""#))
}

@MainActor @Test func attributeSyntaxFromBothDialects() throws {
    let reader = Reader()
    #expect(reader.html("A\n{: .note }").contains(#"class="note""#))
    #expect(!reader.html("A\n{: .note }").contains(":="))
    #expect(reader.html("A\n{.note}").contains(#"class="note""#))
}

@MainActor @Test func plainTextInABlockIsntColoured() {
    let reader = Reader()
    #expect(!reader.html("```\n- [ ] not a task, just an example\n```\n").contains("hljs-"))
    #expect(reader.html("```python\ndef greet(name):\n    return name\n```\n").contains("hljs-"))
    #expect(reader.html("```\n#include <stdio.h>\nint main(void) {\n  printf(\"hi\");\n  return 0;\n}\n```\n").contains("hljs-"))
}

/// Undo must stop at the note. Otherwise it brings back the previous note's
/// text inside this one, and saving writes that over this note.
@MainActor @Test func undoCantReachThePreviousNote() async throws {
    let editor = EditorWebView()
    await editor.load()
    try await editor.setContent("note A\n")
    try await editor.call("insertText", "typed in A ")
    try await editor.setContent("note B\n")
    try await Task.sleep(for: .milliseconds(100))
    _ = try await editor.webView.evaluateJavaScript("window.undoEdit(); 1")
    try await Task.sleep(for: .milliseconds(200))
    #expect(editor.text == "note B\n")
}

/// The other half of the test above: undo still works within a note.
@MainActor @Test func undoWorksWithinANote() async throws {
    let editor = EditorWebView()
    await editor.load()
    try await editor.setContent("note\n")
    try await editor.call("insertText", "typed ")
    try await Task.sleep(for: .milliseconds(100))
    #expect(editor.text == "typed note\n")
    _ = try await editor.webView.evaluateJavaScript("window.undoEdit(); 1")
    try await Task.sleep(for: .milliseconds(200))
    #expect(editor.text == "note\n")
}
