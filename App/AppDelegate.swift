// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI

/// Asks before quitting with unsaved edits.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var app: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let unsaved = app?.windowsWithUnsavedChanges ?? []
        guard !unsaved.isEmpty else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = String(localized: "Save Changes Before Quitting?")
        alert.informativeText = unsaved.compactMap { $0.openNote?.lastPathComponent }.joined(separator: "\n")
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Don’t Save")).hasDestructiveAction = true
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task {
                var allSaved = true
                for window in unsaved {
                    // A conflict stays open in its window, so quitting stops.
                    if await !window.save(then: nil) { allSaved = false }
                }
                sender.reply(toApplicationShouldTerminate: allSaved)
            }
            return .terminateLater
        case .alertThirdButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}

/// Sits in front of SwiftUI's window delegate to answer windowShouldClose,
/// which SwiftUI has no API for, and passes everything else through.
@MainActor
final class WindowCloseGuard: NSObject, NSWindowDelegate {
    /// Strong, and that matters. AppKit asks `responds(to:)` once and then sends
    /// notifications here, so if this delegate went away those would have
    /// nowhere to go and the app would crash, as it did on a window regaining
    /// focus after an alert.
    private let original: (any NSWindowDelegate)?
    private let shouldClose: () -> Bool

    init(window: NSWindow, shouldClose: @escaping () -> Bool) {
        self.original = window.delegate
        self.shouldClose = shouldClose
        super.init()
        window.delegate = self
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || original?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard shouldClose() else { return false }
        return original?.windowShouldClose?(sender) ?? true
    }
}

/// Fits a `WindowCloseGuard` to the window this sits in.
struct CloseGuardInstaller: NSViewRepresentable {
    let window: WindowModel

    final class Host: NSView {
        var install: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { install?(window) }
        }
    }

    final class Coordinator {
        var closeGuard: WindowCloseGuard?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> Host {
        let host = Host()
        let model = window
        let coordinator = context.coordinator
        host.install = { nsWindow in
            guard coordinator.closeGuard == nil else { return }
            coordinator.closeGuard = WindowCloseGuard(window: nsWindow) { [weak nsWindow] in
                guard model.hasUnsavedChanges else { return true }
                // Refused for now: the answer to the prompt closes the window.
                model.finishEditing { nsWindow?.close() }
                return false
            }
        }
        return host
    }

    func updateNSView(_ view: Host, context: Context) {}
}
