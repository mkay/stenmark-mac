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
            WebViewHost(webView: window.reader.webView)
                .overlay {
                    if window.openNote == nil {
                        // Fills the pane, because the web view behind it is white
                        // until a note is loaded.
                        ContentUnavailableView("Select a Note", systemImage: "doc.text")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(nsColor: .windowBackgroundColor))
                    }
                }
            if window.openNote != nil {
                Divider()
                HStack(spacing: 12) {
                    Text("\(window.wordCount) words")
                    Text("\(window.readingMinutes) min read")
                    Spacer()
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
struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        webView.frame = host.bounds
        webView.autoresizingMask = [.width, .height]
        host.addSubview(webView)
        return host
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
