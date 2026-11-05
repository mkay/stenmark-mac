// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Foundation
import WebKit

/// A heading in the page, for the table of contents.
public struct ReaderHeading: Decodable, Sendable, Equatable, Identifiable {
    public let level: Int
    public let title: String
    public let line: Int
    public var id: Int { line }
}

/// How far a search in the note has got.
public struct FindState: Decodable, Sendable, Equatable {
    public var count = 0
    public var current = -1
    public init() {}
}

/// The web view, with WebKit's Back, Forward and Reload taken out of its menu.
/// They'd act on the web view's own history, which isn't the reader's.
final class ReaderView: WKWebView {
    var extraMenuItems: @MainActor () -> [NSMenuItem] = { [] }
    var onSideButton: @MainActor (Int) -> Void = { _ in }

    /// The mouse's back and forward buttons, which AppKit numbers 3 and 4.
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 3 || event.buttonNumber == 4 {
            onSideButton(event.buttonNumber == 3 ? -1 : 1)
        } else {
            super.otherMouseDown(with: event)
        }
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        let unwanted: Set<String> = ["WKMenuItemIdentifierGoBack", "WKMenuItemIdentifierGoForward", "WKMenuItemIdentifierReload"]
        for item in menu.items where unwanted.contains(item.identifier?.rawValue ?? "") {
            menu.removeItem(item)
        }
        let items = extraMenuItems()
        guard !items.isEmpty else { return }
        menu.insertItem(.separator(), at: 0)
        for item in items.reversed() { menu.insertItem(item, at: 0) }
    }
}

/// Shows rendered notes. Everything a note could use to leave the page goes
/// through `decidePolicyFor`, and only a load the app started is let through.
@MainActor
public final class ReaderWebView: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    public let webView: WKWebView
    /// A clicked link, for the app to follow.
    public var onLink: ((URL) -> Void)?
    /// A ticked checkbox: its line in the file, and its new state.
    public var onTaskToggled: ((Int, Bool) -> Void)?
    public var onCopyCode: ((String) -> Void)?
    /// A double click: the line, and the word it selected.
    public var onEditRequest: ((Int, String) -> Void)?
    /// Items for the top of the context menu.
    public var menuItems: @MainActor () -> [NSMenuItem] = { [] } {
        didSet { (webView as? ReaderView)?.extraMenuItems = menuItems }
    }

    /// The mouse's side buttons: -1 for back, 1 for forward.
    public var onSideButton: @MainActor (Int) -> Void = { _ in } {
        didSet { (webView as? ReaderView)?.onSideButton = onSideButton }
    }

    private var loading: CheckedContinuation<Void, Never>?
    private var loadInProgress = false

    public override init() {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(WebSchemeHandler(), forURLScheme: WebSchemeHandler.scheme)
        let url = WebSchemeHandler.bundledRoot("Reader").appending(path: "page.bundle.js")
        // The bundle ships in the app, so failing to read it is a broken build.
        let script = try! String(contentsOf: url, encoding: .utf8)
        configuration.userContentController.addUserScript(
            WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        webView = ReaderView(frame: .zero, configuration: configuration)
        super.init()
        for name in ["checkboxToggled", "copyCode", "editRequest"] {
            configuration.userContentController.add(self, name: name)
        }
        webView.navigationDelegate = self
    }

    /// Shows a page, with relative links and images resolving against `folder`.
    public func show(_ html: String, folder: URL) async {
        finishLoading()
        await withCheckedContinuation { continuation in
            loading = continuation
            loadInProgress = true
            webView.loadHTMLString(html, baseURL: WebSchemeHandler.documentBase(for: folder))
        }
    }

    private func finishLoading() {
        loadInProgress = false
        loading?.resume()
        loading = nil
    }

    private func call<Result: Decodable>(_ script: String, as type: Result.Type) async -> Result? {
        guard let value = try? await webView.evaluateJavaScript("JSON.stringify(\(script))") as? String else { return nil }
        return try? JSONDecoder().decode(type, from: Data(value.utf8))
    }

    private func literal(_ value: some Encodable) -> String {
        (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    /// Replaces the note in the page, keeping its scroll position.
    public func setBody(_ html: String) async {
        _ = try? await webView.evaluateJavaScript("stenmark.setBody(\(literal(html))); 0")
    }

    public func topSourceLine() async -> Int {
        await call("stenmark.topSourceLine()", as: Int.self) ?? 1
    }

    public func scroll(toLine line: Int, smooth: Bool = true) {
        webView.evaluateJavaScript("stenmark.scrollToSourceLine(\(line), \(smooth)); 0", completionHandler: nil)
    }

    public func headings() async -> [ReaderHeading] {
        await call("stenmark.headings()", as: [ReaderHeading].self) ?? []
    }

    public func find(_ query: String) async -> FindState {
        await call("stenmark.find(\(literal(query)))", as: FindState.self) ?? FindState()
    }

    public func findGoTo(_ index: Int) async -> FindState {
        await call("stenmark.findGoTo(\(index))", as: FindState.self) ?? FindState()
    }

    public func clearFind() {
        webView.evaluateJavaScript("stenmark.findClear(); 0", completionHandler: nil)
    }

    private struct TaskMessage: Decodable {
        let line: Int
        let checked: Bool
    }

    private struct EditMessage: Decodable {
        let line: Int
        let word: String
    }

    public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? String else { return }
        switch message.name {
        case "checkboxToggled":
            if let task = try? JSONDecoder().decode(TaskMessage.self, from: Data(body.utf8)) {
                onTaskToggled?(task.line, task.checked)
            }
        case "copyCode":
            onCopyCode?(body)
        case "editRequest":
            if let edit = try? JSONDecoder().decode(EditMessage.self, from: Data(body.utf8)) {
                onEditRequest?(edit.line, edit.word)
            }
        default:
            break
        }
    }

    public func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        if action.navigationType == .linkActivated, let url = action.request.url {
            decisionHandler(.cancel)
            onLink?(url)
        } else {
            // A note's <meta http-equiv="refresh"> comes through here too.
            decisionHandler(loadInProgress ? .allow : .cancel)
        }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoading()
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finishLoading()
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        finishLoading()
    }
}
