// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI

/// Debug builds only: drives a window from the environment, for checking the
/// real signed app from a script. Launch with `open -n -W --env NAME=value`.
///
/// - `STENMARK_CONFIG_DIR=dir` keeps settings.json there instead.
/// - `STENMARK_ROOT=dir` sets the root folder for this run.
/// - `STENMARK_OPEN=a/b.md` opens that note, relative to the root.
/// - `STENMARK_SNAPSHOT=/path.png` saves the window after
///   `STENMARK_SNAPSHOT_DELAY` seconds, with a state dump beside it, then quits.
/// - `STENMARK_E2E=/path.txt` runs `EndToEndCheck`. It changes files in the
///   root, so point it at a throwaway copy of the demo notes.
/// - `STENMARK_SAVE_PROBE=dir` and `STENMARK_TYPING_PROBE=/path.txt` run those.
struct DebugHooksModifier: ViewModifier {
    let window: WindowModel

    func body(content: Content) -> some View {
        #if DEBUG
        content.task { await run() }
        #else
        content
        #endif
    }

    #if DEBUG
    private func run() async {
        let environment = ProcessInfo.processInfo.environment
        if let directory = environment["STENMARK_SAVE_PROBE"] {
            let report = environment["STENMARK_PROBE_OUT"] ?? "/dev/null"
            await SaveProbe.run(in: URL(fileURLWithPath: directory), reportingTo: report)
            exit(0)
        }
        if let path = environment["STENMARK_TYPING_PROBE"] {
            await TypingProbe.run(reportingTo: path)
            exit(0)
        }
        if let root = environment["STENMARK_ROOT"] {
            window.setCeiling(URL(fileURLWithPath: root))
        }
        if let path = environment["STENMARK_E2E"] {
            await EndToEndCheck(window: window).run(reportingTo: path)
            exit(0)
        }
        if let note = environment["STENMARK_OPEN"], let root = window.root {
            window.open(root.appending(path: note))
        }
        if let path = environment["STENMARK_SNAPSHOT"] {
            let delay = Double(environment["STENMARK_SNAPSHOT_DELAY"] ?? "") ?? 3
            try? await Task.sleep(for: .seconds(delay))
            await snapshot(to: URL(fileURLWithPath: path))
            exit(0)
        }
    }

    /// On macOS 26 the sidebar and toolbar are glass, which comes out white in
    /// an in-app snapshot, so the state dump covers those.
    private func snapshot(to url: URL) async {
        guard let main = NSApp.windows.first(where: \.isVisible), let view = main.contentView else { return }
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
        let image = try? await window.reader.webView.takeSnapshot(configuration: nil)
        if let tiff = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) {
            let reader = url.deletingPathExtension().appendingPathExtension("reader.png")
            try? bitmap.representation(using: .png, properties: [:])?.write(to: reader)
        }
        var dump = "root: \(window.root?.path ?? "-")\nselection: \(String(describing: window.selection))\n"
        dump += "selector: \(window.rootChoices.filter { $0.url.path == window.root?.path }.map(\.name)) of \(window.rootChoices.count)\n"
        dump += "overview: total \(window.overview.totalNotes) root \(window.overview.rootNotes)\n"
        for folder in window.overview.folders { dump += "  folder \(folder.name) \(folder.noteCount)\n" }
        for group in window.documents {
            dump += "group '\(group.title)'\n"
            for folder in group.subfolders { dump += "  > \(folder.name)\n" }
            for note in group.notes { dump += "  \(note.displayName) [\(note.tags.joined(separator: ","))]\n" }
        }
        dump += "open: \(window.openNote?.lastPathComponent ?? "-") words \(window.wordCount) headings \(window.headings.count)\n"
        dump += menuDump()
        try? dump.write(to: url.deletingPathExtension().appendingPathExtension("txt"), atomically: true, encoding: .utf8)
    }

    private func menuDump() -> String {
        var out = "menu:\n"
        for menu in NSApp.mainMenu?.items ?? [] {
            let items = menu.submenu?.items.filter { !$0.isSeparatorItem && !$0.keyEquivalent.isEmpty }
                .map { "\($0.title) ⌘\($0.keyEquivalent)" } ?? []
            out += "  \(menu.title): \(items.joined(separator: ", "))\n"
        }
        return out
    }
    #endif
}
