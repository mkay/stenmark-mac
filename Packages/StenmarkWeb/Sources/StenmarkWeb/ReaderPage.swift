// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// How the reader looks.
public struct ReaderStyle: Sendable, Equatable {
    public var fontFamily: String
    public var fontSize: Int
    /// "auto" follows `isDark`. Otherwise one of the names in `ReaderPage.themes`.
    public var theme: String
    public var isDark: Bool
    public var editOnDoubleClick: Bool

    public init(fontFamily: String, fontSize: Int, theme: String, isDark: Bool, editOnDoubleClick: Bool) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.theme = theme
        self.isDark = isDark
        self.editOnDoubleClick = editOnDoubleClick
    }
}

/// Wraps rendered Markdown in a page.
public enum ReaderPage {
    struct Theme {
        let background, text, link, codeBackground, border, headingBorder: String
        let quoteBorder, quoteText, tableHeader, tableBorder, rule: String
        /// A file in Resources/Reader/highlight.
        let highlight: String
    }

    /// The Linux app's viewer themes. Syntax colours come from highlight.js now,
    /// so those are the nearest match to each theme's Pygments style.
    static let themes: [String: Theme] = [
        "light": Theme(
            background: "#ffffff", text: "#1a1a1a", link: "#0366d6", codeBackground: "#f5f5f5", border: "#ddd",
            headingBorder: "#ddd", quoteBorder: "#ddd", quoteText: "#666", tableHeader: "#f5f5f5",
            tableBorder: "#ddd", rule: "#ddd", highlight: "github"),
        "dark": Theme(
            background: "#242424", text: "#e0e0e0", link: "#6ea8fe", codeBackground: "#363636", border: "#555",
            headingBorder: "#444", quoteBorder: "#555", quoteText: "#aaa", tableHeader: "#363636",
            tableBorder: "#444", rule: "#444", highlight: "monokai"),
        "github": Theme(
            background: "#ffffff", text: "#24292f", link: "#0969da", codeBackground: "#f6f8fa", border: "#d0d7de",
            headingBorder: "#d0d7de", quoteBorder: "#d0d7de", quoteText: "#57606a", tableHeader: "#f6f8fa",
            tableBorder: "#d0d7de", rule: "#d0d7de", highlight: "github"),
        "github-dark": Theme(
            background: "#0d1117", text: "#c9d1d9", link: "#58a6ff", codeBackground: "#161b22", border: "#30363d",
            headingBorder: "#21262d", quoteBorder: "#3b434b", quoteText: "#8b949e", tableHeader: "#161b22",
            tableBorder: "#30363d", rule: "#21262d", highlight: "github-dark"),
        "sepia": Theme(
            background: "#f8f0e3", text: "#3c3836", link: "#8f3f71", codeBackground: "#ede8d8", border: "#c4b89a",
            headingBorder: "#c4b89a", quoteBorder: "#c4b89a", quoteText: "#7c6f64", tableHeader: "#ede8d8",
            tableBorder: "#c4b89a", rule: "#c4b89a", highlight: "github"),
        "solarized-light": Theme(
            background: "#fdf6e3", text: "#657b83", link: "#268bd2", codeBackground: "#eee8d5", border: "#93a1a1",
            headingBorder: "#93a1a1", quoteBorder: "#93a1a1", quoteText: "#839496", tableHeader: "#eee8d5",
            tableBorder: "#93a1a1", rule: "#93a1a1", highlight: "solarized-light"),
        "solarized-dark": Theme(
            background: "#002b36", text: "#839496", link: "#268bd2", codeBackground: "#073642", border: "#586e75",
            headingBorder: "#586e75", quoteBorder: "#586e75", quoteText: "#657b83", tableHeader: "#073642",
            tableBorder: "#586e75", rule: "#586e75", highlight: "solarized-dark"),
    ]

    /// Notes can hold raw HTML, and notes arrive through sync from anywhere, so
    /// this page runs nothing and fetches nothing from the network. The page's
    /// own script is a WKUserScript, which a policy doesn't apply to.
    static let contentSecurityPolicy = [
        "default-src 'none'",
        "img-src stenmark: data:",
        "media-src stenmark:",
        "font-src stenmark: data:",
        "style-src 'unsafe-inline'",
        "base-uri 'none'",
        "form-action 'none'",
    ].joined(separator: "; ")

    public static func html(body: String, style: ReaderStyle) -> String {
        let name = style.theme == "auto" ? (style.isDark ? "dark" : "light") : style.theme
        let theme = themes[name] ?? themes["light"]!
        let copy = attribute(String(localized: "Copy code", bundle: .module))
        let copied = attribute(String(localized: "Copied!", bundle: .module))
        return """
        <!DOCTYPE html>
        <html data-copy-label="\(copy)" data-copied-label="\(copied)" data-edit-on-double-click="\(style.editOnDoubleClick)">
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
        <style>\(highlightCSS(theme.highlight))</style>
        <style>\(css(theme, style))</style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    private static func attribute(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
    }

    private static func highlightCSS(_ name: String) -> String {
        let url = WebSchemeHandler.bundledRoot("Reader").appending(path: "highlight/\(name).min.css")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private static func css(_ theme: Theme, _ style: ReaderStyle) -> String {
        // A setting, but still not to be trusted inside a style sheet.
        let family = style.fontFamily.filter { $0 != "\"" && $0 != ";" && $0 != "<" && $0 != "\\" }
        return """
        body {
            font-family: "\(family)", -apple-system, sans-serif;
            font-size: \(style.fontSize)px;
            line-height: 1.6;
            color: \(theme.text);
            max-width: 800px;
            margin: 0 auto;
            padding: 20px;
            background: \(theme.background);
        }
        html { background: \(theme.background); }
        h1, h2, h3, h4, h5, h6 { margin-top: 1.2em; margin-bottom: 0.4em; line-height: 1.3; }
        h1 { font-size: 1.8em; border-bottom: 1px solid \(theme.headingBorder); padding-bottom: 0.2em; }
        h2 { font-size: 1.5em; border-bottom: 1px solid \(theme.headingBorder); padding-bottom: 0.2em; }
        h3 { font-size: 1.25em; }
        a { color: \(theme.link); text-decoration: none; }
        a:hover { text-decoration: underline; }
        code {
            font-family: ui-monospace, Menlo, monospace;
            background: \(theme.codeBackground);
            padding: 2px 6px;
            border-radius: 3px;
            font-size: 0.9em;
        }
        pre {
            position: relative;
            background: \(theme.codeBackground);
            padding: 12px;
            border-radius: 6px;
            overflow-x: auto;
            line-height: 1.4;
            white-space: pre;
        }
        pre code, pre code.hljs { background: none; padding: 0; }
        .copy-btn {
            position: absolute;
            top: 6px;
            right: 6px;
            background: none;
            border: 1px solid \(theme.border);
            border-radius: 4px;
            cursor: pointer;
            padding: 4px;
            opacity: 0;
            transition: opacity 0.15s;
            display: flex;
            align-items: center;
            justify-content: center;
            color: \(theme.text);
        }
        pre:hover .copy-btn { opacity: 0.7; }
        .copy-btn:hover { opacity: 1 !important; background: \(theme.codeBackground); }
        .copy-btn:active { transform: scale(0.95); }
        .copy-btn.copied { opacity: 1; }
        blockquote {
            margin: 0.8em 0;
            padding: 0.4em 1em;
            border-left: 4px solid \(theme.quoteBorder);
            color: \(theme.quoteText);
        }
        table { border-collapse: collapse; width: 100%; margin: 1em 0; }
        table th, table td { border: 1px solid \(theme.tableBorder); padding: 8px 12px; text-align: left; }
        table th { background: \(theme.tableHeader); font-weight: 600; }
        img { max-width: 100%; height: auto; }
        hr { border: none; border-top: 1px solid \(theme.rule); margin: 1.5em 0; }
        ul, ol { padding-left: 1.5em; }
        li { margin: 0.3em 0; }
        li.task-item { list-style: none; margin-left: -1.2em; }
        li.task-item input[type="checkbox"] {
            cursor: pointer;
            width: 1em;
            height: 1em;
            margin-right: 0.4em;
            vertical-align: -0.1em;
            accent-color: \(theme.link);
        }
        mark.sf-match { background: rgba(255, 221, 0, 0.5); color: inherit; border-radius: 2px; }
        mark.sf-current { background: rgba(255, 106, 0, 0.35); }
        """
    }
}
