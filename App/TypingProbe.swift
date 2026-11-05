// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

#if DEBUG
import AppKit
import StenmarkWeb

/// Phase 0: do dead keys and shortcuts reach CodeMirror on a real keyboard
/// layout? The Linux app needs a workaround for dead keys, and this shows
/// whether the Mac app does. Key codes are physical keys, so what they produce
/// depends on the layout that's selected; the expectations are for German.
@MainActor enum TypingProbe {
    private struct Key {
        let code: UInt16
        var flags: NSEvent.ModifierFlags = []
    }

    private static let acute = Key(code: 24)
    private static let grave = Key(code: 24, flags: .shift)
    private static let circumflex = Key(code: 10)
    private static let tilde = Key(code: 45, flags: .option)
    private static let space = Key(code: 49)
    private static let e = Key(code: 14)
    private static let o = Key(code: 31)
    private static let n = Key(code: 45)
    private static let uUmlaut = Key(code: 33)
    private static let escape = Key(code: 53)

    /// Goes through CGEvent because that fills in the characters from the
    /// selected layout, which NSEvent.keyEvent leaves to the caller. Sent to the
    /// window directly: nothing is posted to the system, so this needs no
    /// Accessibility permission and can't type into another app.
    private static func send(_ key: Key, to window: NSWindow) async {
        var flags: CGEventFlags = []
        if key.flags.contains(.shift) { flags.insert(.maskShift) }
        if key.flags.contains(.option) { flags.insert(.maskAlternate) }
        if key.flags.contains(.command) { flags.insert(.maskCommand) }
        for down in [true, false] {
            guard let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: key.code, keyDown: down) else { continue }
            cgEvent.flags = flags
            guard let event = NSEvent(cgEvent: cgEvent) else { continue }
            window.sendEvent(event)
        }
        try? await Task.sleep(for: .milliseconds(120))
    }

    static func run(reportingTo path: String) async {
        var report = ""
        let editor = EditorWebView()
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 700, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor.webView
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        await editor.load()
        try? await Task.sleep(for: .seconds(1))
        window.makeFirstResponder(editor.webView)
        report += "active=\(NSApp.isActive) key=\(window.isKeyWindow) responder=\(type(of: window.firstResponder as Any))\n"

        var saves = 0
        var escapes = 0
        editor.onSave = { saves += 1 }
        editor.onEscape = { escapes += 1 }

        func check(_ name: String, _ keys: [Key], expect: String) async {
            try? await editor.setContent("")
            window.makeFirstResponder(editor.webView)
            try? await editor.call("focusEditor")
            try? await Task.sleep(for: .milliseconds(200))
            for key in keys { await send(key, to: window) }
            try? await Task.sleep(for: .milliseconds(250))
            let result = editor.text
            report += "\(result == expect ? "ok  " : "FAIL") \(name): \(result.debugDescription)\n"
        }

        await check("plain ü", [uUmlaut], expect: "ü")
        await check("backtick: dead grave + space", [grave, space], expect: "`")
        await check("three backticks", [grave, space, grave, space, grave, space], expect: "```")
        await check("è: dead grave + e", [grave, e], expect: "è")
        await check("é: dead acute + e", [acute, e], expect: "é")
        await check("ô: dead circumflex + o", [circumflex, o], expect: "ô")
        await check("^: dead circumflex + space", [circumflex, space], expect: "^")
        await check("~: option-n + space", [tilde, space], expect: "~")
        await check("ñ: option-n + n", [tilde, n], expect: "ñ")

        try? await editor.setContent("word")
        try? await editor.webView.evaluateJavaScript("gotoLine(1,'word',false)")
        window.makeFirstResponder(editor.webView)
        await send(Key(code: 11, flags: .command), to: window)
        try? await Task.sleep(for: .milliseconds(250))
        report += "\(editor.text.contains("**") ? "ok  " : "FAIL") Cmd-B: \(editor.text.debugDescription)\n"

        await send(Key(code: 1, flags: .command), to: window)
        try? await Task.sleep(for: .milliseconds(250))
        report += "\(saves == 1 ? "ok  " : "FAIL") Cmd-S saves: \(saves)\n"

        // A pending dead key followed by Escape locked Linux in edit mode.
        await send(circumflex, to: window)
        await send(escape, to: window)
        await send(escape, to: window)
        try? await Task.sleep(for: .milliseconds(250))
        report += "\(escapes >= 1 ? "ok  " : "FAIL") dead key then Escape leaves: \(escapes)\n"

        try? report.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
#endif
