// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI

/// Shown once after an update, and from the Help menu. The notes are in English
/// only, as on Linux.
struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// The bullets from whatsnew.md. Never fails: release notes are a nicety,
    /// and a bad file mustn't get in the way of the app.
    static var notes: [String] {
        guard let url = Bundle.main.url(forResource: "whatsnew", withExtension: "md"),
              var text = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }
        text.replace(/<!--[\s\S]*?-->/, with: "")
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let bullet = line.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-*•"))
                .trimmingCharacters(in: .whitespaces)
            return bullet.isEmpty ? nil : bullet
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What’s New in \(Self.version)").font(.title2.weight(.semibold))
            ForEach(Self.notes, id: \.self) { note in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "•")
                    Text((try? AttributedString(markdown: note)) ?? AttributedString(note))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

/// Help ▸ Open Source Licences. The licences are in English only, because
/// they're legal text, and the file comes from `scripts/make-notices.py`.
struct LicencesView: View {
    @Environment(\.dismiss) private var dismiss

    static var text: String {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt") else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Open Source Licences").font(.title2.weight(.semibold))
            PlainTextView(text: Self.text) { dismiss() }
                .clipShape(.rect(cornerRadius: 6))
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 640, height: 560)
    }
}

/// Read-only text that can be selected. An NSTextView, because a SwiftUI `Text`
/// lays out all of it at once, and this is hundreds of lines.
private struct PlainTextView: NSViewRepresentable {
    let text: String
    let onClose: () -> Void

    /// As first responder it would keep Return from the sheet's default button.
    private final class TextView: NSTextView {
        var onClose: () -> Void = {}

        override func keyDown(with event: NSEvent) {
            // Return, Enter and Escape.
            if [36, 76, 53].contains(event.keyCode) { onClose() } else { super.keyDown(with: event) }
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let view = TextView()
        view.isEditable = false
        view.onClose = onClose
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.textColor = .labelColor
        view.textContainerInset = NSSize(width: 8, height: 8)
        view.string = text
        view.isVerticallyResizable = true
        view.autoresizingMask = .width
        view.textContainer?.widthTracksTextView = true
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.documentView = view
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {}
}

/// Help ▸ Support Stenmark: the Linux app's "Keep this app alive".
struct SupportView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keep this app alive").font(.title2.weight(.semibold))
            Text("This app doesn't track. Anything.\nThe downside is I have no idea if or how often it's used or downloaded. Could be zero, could be a secret cult following. I genuinely don't know.")
            Text("Am I wasting my time publishing it? You tell me.")
            Text("There are three (maybe more) ways to keep me motivated:")
            way("The easy way", "Give it a like", "heart",
                "Opens a page on my website with a like button. Nothing is counted until you press it — just the press and an anonymised IP.",
                "https://singular.de/apps/feedback/?stenmark")
            way("The nerdy way", "Star it on GitHub", "star",
                "A star is a number I can actually see, and it helps others find it.",
                "https://github.com/mkay/stenmark")
            way("The generous way", "Support it on Ko-fi", "cup.and.saucer",
                "Entirely optional. Stenmark is and stays free either way.",
                "https://ko-fi.com/s1ngular")
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(24)
        .frame(width: 460)
    }

    private func way(
        _ title: LocalizedStringKey, _ action: LocalizedStringKey, _ icon: String,
        _ note: LocalizedStringKey, _ url: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Link(destination: URL(string: url)!) { Label(action, systemImage: icon) }
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }
}
