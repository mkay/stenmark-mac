// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import WebKit

/// How the editor looks. The names are those of the Linux settings.
public struct EditorStyle: Sendable, Equatable {
    public var theme: String
    public var matchSystem: Bool
    public var isDark: Bool
    public var fontFamily: String
    public var fontSize: Int
    public var lineNumbers: Bool
    public var lineWrap: Bool
    public var typewriter: Bool

    public init(
        theme: String, matchSystem: Bool, isDark: Bool, fontFamily: String, fontSize: Int,
        lineNumbers: Bool, lineWrap: Bool, typewriter: Bool
    ) {
        self.theme = theme
        self.matchSystem = matchSystem
        self.isDark = isDark
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.lineNumbers = lineNumbers
        self.lineWrap = lineWrap
        self.typewriter = typewriter
    }
}

/// An entry in the editor's theme list.
public struct EditorTheme: Decodable, Sendable, Identifiable, Hashable {
    public let key: String
    public let label: String
    public var id: String { key }

    /// themes.json is what the bundle builds its own list from, so this can't
    /// offer a theme the editor lacks.
    public static let all: [EditorTheme] = {
        let url = WebSchemeHandler.bundledRoot("Editor").appending(path: "themes.json")
        return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([EditorTheme].self, from: $0) } ?? []
    }()
}

/// Hosts the CodeMirror editor. `web/editor/src/editor.js` is the other half of
/// this bridge; its handler names are the same as in the Linux app.
@MainActor
public final class EditorWebView: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    public let webView: WKWebView
    public private(set) var text = ""
    public var onTextChanged: ((String) -> Void)?
    public var onSave: (() -> Void)?
    public var onEscape: (() -> Void)?
    public var onScrollLine: ((Int) -> Void)?

    private var loaded: CheckedContinuation<Void, Never>?

    public override init() {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(WebSchemeHandler(), forURLScheme: WebSchemeHandler.scheme)
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        for name in ["textChanged", "saveRequest", "scrollLine", "escapeRequest"] {
            configuration.userContentController.add(self, name: name)
        }
        webView.navigationDelegate = self
    }

    public func load() async {
        await withCheckedContinuation { continuation in
            loaded = continuation
            webView.load(URLRequest(url: WebSchemeHandler.editorURL))
        }
    }

    public func setContent(_ text: String) async throws {
        self.text = text
        try await call("setContent", text)
    }

    public func apply(_ style: EditorStyle) async {
        _ = try? await call("setTheme", style.theme, style.isDark, style.matchSystem)
        _ = try? await call("setFont", style.fontFamily, style.fontSize)
        _ = try? await call("setLineNumbers", style.lineNumbers)
        _ = try? await call("setLineWrap", style.lineWrap)
        _ = try? await call("setTypewriter", style.typewriter)
    }

    /// Puts the caret on `line`, at `word` if it's there.
    public func goTo(line: Int, word: String = "", center: Bool = true) async {
        _ = try? await call("gotoLine", line, word, center)
    }

    public func scrollTo(line: Int) async {
        _ = try? await call("scrollToLine", line)
    }

    /// The first line in view.
    public func topLine() async -> Int {
        (try? await call("topLine")) as? Int ?? 1
    }

    /// Takes keyboard focus. CodeMirror's own focus isn't enough: unless the web
    /// view is the window's first responder, keys never reach the page.
    public func focus() async {
        webView.window?.makeFirstResponder(webView)
        _ = try? await call("focusEditor")
    }

    /// Calls one of the editor's global functions, passing arguments as JSON
    /// so that no text from a note is ever parsed as code.
    @discardableResult
    public func call(_ function: String, _ arguments: any Encodable...) async throws -> Any? {
        let encoder = JSONEncoder()
        let list = try arguments.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        return try await webView.evaluateJavaScript("\(function)(\(list.joined(separator: ",")))")
    }

    public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case "textChanged":
            guard let body = message.body as? String else { return }
            text = body
            onTextChanged?(body)
        case "saveRequest":
            onSave?()
        case "escapeRequest":
            onEscape?()
        case "scrollLine":
            if let line = (message.body as? String).flatMap(Int.init) { onScrollLine?(line) }
        default:
            break
        }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume()
        loaded = nil
    }
}
