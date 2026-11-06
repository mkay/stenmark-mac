// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Synchronization

/// A setting: its key in settings.json and its value when none is stored.
public struct Setting<Value: Sendable>: Sendable {
    public let key: String
    public let defaultValue: Value

    public init(_ key: String, _ defaultValue: Value) {
        self.key = key
        self.defaultValue = defaultValue
    }
}

/// The Linux keys, for what means the same here. The defaults differ only for
/// the fonts, because "Sans" and "Monospace" are fontconfig names.
public enum Settings {
    public static let rootDirectory = Setting("root_directory", "")
    public static let language = Setting("language", "")
    public static let fontFamily = Setting("font_family", "-apple-system")
    public static let fontSize = Setting("font_size", 16)
    public static let theme = Setting("theme", "system")
    public static let viewerTheme = Setting("viewer_theme", "auto")
    public static let editorFontFamily = Setting("editor_font_family", "Menlo")
    public static let editorFontSize = Setting("editor_font_size", 14)
    public static let editorTheme = Setting("editor_theme", "auto")
    public static let editorThemeMatchSystem = Setting("editor_theme_match_system", false)
    public static let editorLineNumbers = Setting("editor_line_numbers", true)
    public static let editorLineWrap = Setting("editor_line_wrap", true)
    public static let editorTypewriter = Setting("editor_typewriter", false)
    public static let doubleClickToEdit = Setting("double_click_to_edit", true)
    public static let hideSidebarOnEdit = Setting("hide_sidebar_on_edit", true)
    public static let fileWatching = Setting("file_watching", true)
    // On by default here, unlike Linux.
    public static let rememberLastFolder = Setting("remember_last_folder", true)
    public static let showSidebarTags = Setting("show_sidebar_tags", false)
    public static let tintSidebar = Setting("tint_sidebar", true)
    public static let previewEnabled = Setting("preview_enabled", false)
    public static let lastRootFolder = Setting("last_root_folder", "")
    public static let whatsNewSeen = Setting("whats_new_seen", "")
    /// Mac only: which columns a window shows.
    public static let columnLayout = Setting("mac_column_layout", "all")
    public static let pinnedFiles = Setting("pinned_files", [String]())
    public static let pinnedFolders = Setting("pinned_folders", [String]())
}

public enum SettingsError: Error, LocalizedError {
    /// The file exists but isn't valid JSON. Writes are refused, so that
    /// changing one preference can't replace a damaged file with near-empty
    /// defaults and lose the rest.
    case unreadable(URL, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let url, let error):
            String(localized: "The settings file \(url.path) can't be read: \(error.localizedDescription)", bundle: .module)
        }
    }
}

/// settings.json. It's per machine and never in the notes folder.
///
/// Keys this version doesn't know are kept. An override lasts for the session
/// and is never written, for a folder opened from the command line.
public final class SettingsStore: Sendable {
    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "Stenmark/settings.json")
    }

    private struct State: @unchecked Sendable {
        var values: [String: Any] = [:]
        var overrides: [String: Any] = [:]
        var damage: Error?
    }

    public let fileURL: URL
    /// True until settings are first saved, which tells a fresh install from an
    /// upgrade when deciding whether to show What's New.
    public let isFirstRun: Bool
    private let state: Mutex<State>

    public init(fileURL: URL = SettingsStore.defaultURL) {
        self.fileURL = fileURL
        var initial = State()
        isFirstRun = !FileManager.default.fileExists(atPath: fileURL.path)
        if !isFirstRun {
            do {
                let data = try Data(contentsOf: fileURL)
                guard let values = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw CocoaError(.propertyListReadCorrupt)
                }
                initial.values = values
            } catch {
                initial.damage = error
            }
        }
        state = Mutex(initial)
    }

    /// Whether the file couldn't be read, so that nothing can be saved to it.
    public var isDamaged: Bool {
        state.withLock { $0.damage != nil }
    }

    /// The setting's value. A stored value of the wrong type counts as unset.
    public func value<Value>(_ setting: Setting<Value>) -> Value {
        state.withLock { state in
            (state.overrides[setting.key] ?? state.values[setting.key]) as? Value ?? setting.defaultValue
        }
    }

    public func set<Value>(_ setting: Setting<Value>, to value: Value) throws {
        try state.withLock { state in
            if let damage = state.damage { throw SettingsError.unreadable(fileURL, underlying: damage) }
            var values = state.values
            values[setting.key] = value
            try Self.write(values, to: fileURL)
            state.values = values
        }
    }

    public func setOverride<Value>(_ setting: Setting<Value>, to value: Value) {
        state.withLock { $0.overrides[setting.key] = value }
    }

    private static func write(_ values: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    // MARK: Root folder

    /// The folder to start in: the one last selected, if that's still somewhere
    /// the selector could go. It has to exist and be below `ceiling`, so that a
    /// folder deleted or a root changed since doesn't leave a window stranded.
    public func rememberedRoot(under ceiling: URL) -> URL? {
        guard value(Settings.rememberLastFolder) else { return nil }
        let stored = value(Settings.lastRootFolder)
        guard !stored.isEmpty else { return nil }
        // Standardised only for comparing, which resolves any "..". It also
        // strips /private, so the result would no longer match the selector's
        // paths. With the slash, or "/Notes2" would count as inside "/Notes".
        let resolved = URL(fileURLWithPath: stored).standardizedFileURL.path
        guard resolved.hasPrefix(ceiling.standardizedFileURL.path + "/") else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return URL(fileURLWithPath: stored)
    }

    // MARK: Pins

    /// Swift compares strings by canonical equivalence, so a composed and a
    /// decomposed "ü" count as the same path here.
    public func isPinned(_ path: String, in setting: Setting<[String]>) -> Bool {
        value(setting).contains(path)
    }

    public func togglePin(_ path: String, in setting: Setting<[String]>) throws {
        var pins = value(setting)
        if let index = pins.firstIndex(of: path) {
            pins.remove(at: index)
        } else {
            pins.append(path)
        }
        try set(setting, to: pins)
    }

    /// Forgets pins whose file or folder no longer exists.
    public func removeStalePins() throws {
        for setting in [Settings.pinnedFiles, Settings.pinnedFolders] {
            let pins = value(setting)
            let valid = pins.filter { FileManager.default.fileExists(atPath: $0) }
            if valid.count != pins.count { try set(setting, to: valid) }
        }
    }
}
