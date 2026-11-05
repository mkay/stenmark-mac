// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import JavaScriptCore

/// Turns Markdown into HTML with the bundled renderer in `web/reader`.
///
/// It runs in JavaScriptCore rather than in the reader's page, so that the page
/// can forbid scripts altogether.
@MainActor
public final class MarkdownRenderer {
    private let render: JSValue

    public init() {
        let url = WebSchemeHandler.bundledRoot("Reader").appending(path: "reader.bundle.js")
        let context = JSContext()!
        // The bundle ships in the app, so failing to read it is a broken build.
        context.evaluateScript(try! String(contentsOf: url, encoding: .utf8))
        render = context.objectForKeyedSubscript("StenmarkReader").objectForKeyedSubscript("render")
    }

    /// Renders a note's body. `lineOffset` is the number of lines of frontmatter
    /// above it, so that source lines count from the top of the file.
    public func html(_ body: String, lineOffset: Int = 0) -> String {
        render.call(withArguments: [body, lineOffset])?.toString() ?? ""
    }
}
