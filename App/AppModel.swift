// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import StenmarkCore
import StenmarkWeb

/// What all windows share.
@MainActor @Observable
final class AppModel {
    let settings: SettingsStore
    let renderer = MarkdownRenderer()

    /// The folder set as the root, which is as high as a window can go: the
    /// sidebar's selector only offers this folder and what's below it. Empty
    /// until one is chosen.
    private(set) var ceiling = ""
    /// Bumped when a setting changes that open windows have to follow.
    private(set) var styleRevision = 0
    /// Notes and folders handed over by Finder, waiting for a window. They can
    /// arrive during launch, before any window model exists.
    var pendingOpens: [URL] = []
    /// Every open window, for the check on quitting.
    private var windows: [WeakWindow] = []

    private struct WeakWindow {
        weak var model: WindowModel?
    }

    func register(_ window: WindowModel) {
        windows = windows.filter { $0.model != nil } + [WeakWindow(model: window)]
    }

    var windowsWithUnsavedChanges: [WindowModel] {
        windows.compactMap(\.model).filter(\.hasUnsavedChanges)
    }

    func styleChanged() {
        styleRevision += 1
    }

    init() {
        #if DEBUG
        if let folder = ProcessInfo.processInfo.environment["STENMARK_CONFIG_DIR"] {
            settings = SettingsStore(fileURL: URL(fileURLWithPath: folder).appending(path: "settings.json"))
            ceiling = settings.value(Settings.rootDirectory)
            applyAppearance()
            return
        }
        #endif
        settings = SettingsStore()
        ceiling = settings.value(Settings.rootDirectory)
        applyAppearance()
    }

    /// The App Theme setting. For the whole app, Settings window included.
    func applyAppearance() {
        switch settings.value(Settings.theme) {
        case "light": NSApp?.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp?.appearance = NSAppearance(named: .darkAqua)
        default: NSApp?.appearance = nil
        }
    }

    /// Whether this launch is the first on a new version, recording that it was.
    /// A fresh install has nothing new to report.
    func shouldShowWhatsNew(version: String) -> Bool {
        guard settings.value(Settings.whatsNewSeen) != version else { return false }
        let isFirstRun = settings.isFirstRun
        try? settings.set(Settings.whatsNewSeen, to: version)
        return !isFirstRun && !WhatsNewView.notes.isEmpty
    }

    /// Asks for the root folder. This is the only place that offers the whole
    /// disk, and it's only reachable from the first-run screen and Settings.
    /// Returns what went wrong saving the choice, if anything.
    func chooseCeiling() -> Error? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = String(localized: "Choose the folder that holds your notes.")
        panel.prompt = String(localized: "Choose")
        if !ceiling.isEmpty { panel.directoryURL = URL(fileURLWithPath: ceiling) }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try settings.set(Settings.rootDirectory, to: url.path)
        } catch {
            return error
        }
        ceiling = url.path
        return nil
    }
}
