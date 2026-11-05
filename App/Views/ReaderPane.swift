// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

import StenmarkCore
import StenmarkWeb
import SwiftUI
import WebKit

struct ReaderPane: View {
    @Bindable var window: WindowModel

    var body: some View {
        VStack(spacing: 0) {
            if window.isFindVisible {
                FindBar(window: window)
                Divider()
            }
            if window.isEditing {
                EditorArea(window: window)
            } else {
                WebViewHost(webView: window.reader.webView)
                    .overlay {
                        if window.openNote == nil {
                            // Fills the pane, because the web view behind it is
                            // white until a note is loaded.
                            ContentUnavailableView("Select a Note", systemImage: "doc.text")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Color(nsColor: .windowBackgroundColor))
                        }
                    }
            }
            if window.openNote != nil {
                Divider()
                HStack(spacing: 12) {
                    Text("\(window.wordCount) words")
                    Text("\(window.readingMinutes) min read")
                    Spacer()
                    if window.isEditing {
                        Button(window.isTypewriterOn ? "Typewriter: On" : "Typewriter: Off") { window.toggleTypewriter() }
                            .buttonStyle(.plain)
                            .help("Keep the current line centred")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button("Back", systemImage: "chevron.left") { window.goBack() }
                    .disabled(!window.canGoBack)
                Button("Forward", systemImage: "chevron.right") { window.goForward() }
                    .disabled(!window.canGoForward)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if window.isEditing {
                    Toggle(isOn: Binding(get: { window.isPreviewVisible }, set: { _ in window.togglePreview() })) {
                        Label("Preview", systemImage: "rectangle.split.2x1")
                    }
                    .help("Toggle live preview")
                }
                Toggle(isOn: Binding(get: { window.isEditing }, set: { _ in window.toggleEdit() })) {
                    Label("Edit", systemImage: "pencil")
                }
                .disabled(window.openNote == nil)
                .help("Edit the note")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Table of Contents", systemImage: "list.bullet.indent") { window.isContentsVisible.toggle() }
                    .disabled(window.headings.isEmpty)
                    .popover(isPresented: $window.isContentsVisible, arrowEdge: .bottom) {
                        ContentsList(window: window)
                    }
            }
        }
    }
}

/// The editor, its formatting bar, and the preview beside it.
private struct EditorArea: View {
    let window: WindowModel

    var body: some View {
        VStack(spacing: 0) {
            if window.diskChangedWhileEditing {
                Label("This note changed on disk. Saving will ask which version to keep.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.yellow.opacity(0.2))
            }
            FormatBar(window: window)
            Divider()
            HSplitView {
                WebViewHost(webView: window.editor.webView)
                    .frame(minWidth: 240)
                if window.isPreviewVisible {
                    WebViewHost(webView: window.preview.webView)
                        .frame(minWidth: 240)
                }
            }
        }
    }
}

private struct FormatBar: View {
    let window: WindowModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...3, id: \.self) { level in
                Button { window.format("formatHeading", level) } label: {
                    Text(verbatim: "H\(level)").font(.system(size: 12, weight: .semibold))
                }
                .help("Heading \(level)")
            }
            Divider().frame(height: 16).padding(.horizontal, 4)
            tool("Bold (⌘B)", "bold", "formatBold")
            tool("Italic (⌘I)", "italic", "formatItalic")
            tool("Strikethrough (⇧⌘X)", "strikethrough", "formatStrike")
            tool("Inline code (⌃`)", "chevron.left.forwardslash.chevron.right", "formatCode")
            tool("Code block (⇧⌘K)", "curlybraces", "formatCodeBlock")
            Divider().frame(height: 16).padding(.horizontal, 4)
            tool("Link (⌘K)", "link", "formatLink")
            tool("Blockquote", "text.quote", "formatQuote")
            Divider().frame(height: 16).padding(.horizontal, 4)
            tool("Bullet list (⇧⌘U)", "list.bullet", "formatBullet")
            tool("Numbered list (⇧⌘O)", "list.number", "formatNumbered")
            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func tool(_ title: LocalizedStringKey, _ icon: String, _ function: String) -> some View {
        Button { window.format(function) } label: { Image(systemName: icon).frame(width: 20) }
            .help(title)
    }
}

private struct ContentsList: View {
    let window: WindowModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(window.headings) { heading in
                    Button { window.jump(to: heading) } label: {
                        Text(verbatim: heading.title)
                            .fontWeight(heading.level == 1 ? .semibold : .regular)
                            .foregroundStyle(heading.level >= 3 ? .secondary : .primary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, CGFloat(heading.level - 1) * 16)
                }
            }
            .padding(12)
        }
        .frame(width: 280)
        .frame(maxHeight: 420)
    }
}

private struct FindBar: View {
    @Bindable var window: WindowModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField("Find in note", text: $window.findQuery)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { window.findNext(1) }
                .onChange(of: window.findQuery) { window.runFind() }
                .onKeyPress(.escape) {
                    window.closeFind()
                    return .handled
                }
            if !window.findQuery.isEmpty {
                Text(status).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Button("Previous Match", systemImage: "chevron.up") { window.findNext(-1) }
                .labelStyle(.iconOnly)
            Button("Next Match", systemImage: "chevron.down") { window.findNext(1) }
                .labelStyle(.iconOnly)
            Button("Close", systemImage: "xmark") { window.closeFind() }
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .onAppear { focused = true }
    }

    private var status: String {
        let state = window.findState
        return state.count > 0 ? "\(state.current + 1)/\(state.count)" : String(localized: "No matches")
    }
}

/// Keeps one web view alive across SwiftUI updates.
///
/// When the layout changes, a new host and the old one exist together for a
/// moment, in no order to rely on. So a host takes the web view when it joins a
/// window, and never before: taking it any earlier could leave it in a host
/// that's on its way out, and then no key reaches the page.
struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    final class Host: NSView {
        var webView: WKWebView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, let webView else { return }
            webView.frame = bounds
            webView.autoresizingMask = [.width, .height]
            addSubview(webView)
        }
    }

    func makeNSView(context: Context) -> Host {
        let host = Host()
        host.webView = webView
        return host
    }

    func updateNSView(_ host: Host, context: Context) {}
}
