// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import WebKit

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
