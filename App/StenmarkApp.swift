// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

import StenmarkCore
import StenmarkWeb
import SwiftUI

@main
struct StenmarkApp: App {
    var body: some Scene {
        WindowGroup {
            EditorPane()
                .frame(minWidth: 600, minHeight: 400)
                #if DEBUG
                .task { await DebugHooks.run() }
                #endif
        }
        .defaultSize(width: 1000, height: 700)
    }
}

/// The skeleton's only view: the editor, to show the pieces are connected.
struct EditorPane: NSViewRepresentable {
    @MainActor final class Coordinator {
        let editor = EditorWebView()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebViewHost {
        let editor = context.coordinator.editor
        Task {
            await editor.load()
            try? await editor.setContent("# Stenmark\n")
        }
        return WKWebViewHost(editor.webView)
    }

    func updateNSView(_ view: WKWebViewHost, context: Context) {}
}

final class WKWebViewHost: NSView {
    init(_ child: NSView) {
        super.init(frame: .zero)
        child.autoresizingMask = [.width, .height]
        addSubview(child)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}
