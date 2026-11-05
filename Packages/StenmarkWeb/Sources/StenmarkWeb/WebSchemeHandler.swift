// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves `stenmark://editor/…` from the bundled editor, `stenmark://reader/…`
/// from the bundled reader, and `stenmark://doc/<absolute path>` from disk.
///
/// A note's images and links resolve against a `stenmark://doc/` base URL, so
/// they work wherever they point, including outside the note's folder, without
/// the page having read access to file:// URLs in general.
public final class WebSchemeHandler: NSObject, WKURLSchemeHandler {
    public static let scheme = "stenmark"
    public static let editorURL = URL(string: "\(scheme)://editor/editor.html")!

    /// The base URL for a note in `folder`.
    public static func documentBase(for folder: URL) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "doc"
        components.path = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        return components.url!
    }

    /// The file behind a `stenmark://doc/` URL, for handling a clicked link.
    public static func documentPath(of url: URL) -> String? {
        guard url.scheme == scheme, url.host == "doc" else { return nil }
        return url.path(percentEncoded: false)
    }

    nonisolated static func bundledRoot(_ name: String) -> URL {
        Bundle.module.resourceURL!.appendingPathComponent(name, isDirectory: true).standardizedFileURL
    }

    func file(for url: URL) -> URL? {
        guard url.scheme == Self.scheme else { return nil }
        switch url.host {
        case "doc":
            return URL(fileURLWithPath: url.path(percentEncoded: false))
        case "editor", "reader":
            let root = Self.bundledRoot(url.host == "editor" ? "Editor" : "Reader")
            let file = root.appendingPathComponent(url.path).standardizedFileURL
            return file.path.hasPrefix(root.path + "/") ? file : nil
        default:
            return nil
        }
    }

    public func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let file = file(for: url), let data = try? Data(contentsOf: file) else {
            let response = HTTPURLResponse(url: task.request.url!, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
            task.didReceive(response)
            task.didFinish()
            return
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": mime,
            "Content-Length": String(data.count),
        ])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    public func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
