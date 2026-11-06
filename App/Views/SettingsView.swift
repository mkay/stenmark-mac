// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

import StenmarkCore
import StenmarkWeb
import SwiftUI

/// The Linux app's Preferences, less its window size (a Mac window keeps its
/// own) and its shortcut fields (System Settings ▸ Keyboard does that for every
/// app).
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            FontSettings().tabItem { Label("Fonts", systemImage: "textformat") }
            EditorSettings().tabItem { Label("Editor", systemImage: "pencil") }
        }
        .frame(width: 500, height: 560)
    }
}

/// Reads and writes a setting, and tells open windows to follow it.
@MainActor private func binding<Value>(_ setting: Setting<Value>, in app: AppModel, failure: Binding<String?>) -> Binding<Value> {
    Binding(
        get: {
            _ = app.styleRevision
            return app.settings.value(setting)
        },
        set: { value in
            do {
                try app.settings.set(setting, to: value)
                app.applyAppearance()
                app.styleChanged()
            } catch {
                failure.wrappedValue = error.localizedDescription
            }
        }
    )
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var app
    @State private var failure: String?

    /// Each language named in itself: someone looking for German shouldn't have
    /// to know the English word for it.
    private let languages = [("en", "English"), ("de", "Deutsch"), ("ru", "Русский")]

    private let viewerThemes: [(String, LocalizedStringKey)] = [
        ("auto", "Automatic"), ("light", "Light"), ("dark", "Dark"), ("github", "GitHub"),
        ("github-dark", "GitHub Dark"), ("sepia", "Sepia"), ("solarized-light", "Solarized Light"),
        ("solarized-dark", "Solarized Dark"),
    ]

    private var language: Binding<String> {
        Binding(
            get: { app.settings.value(Settings.language) },
            set: { code in
                try? app.settings.set(Settings.language, to: code)
                // How a Mac app picks its language. Takes effect on the next launch.
                if code.isEmpty {
                    UserDefaults.standard.removeObject(forKey: "AppleLanguages")
                } else {
                    UserDefaults.standard.set([code], forKey: "AppleLanguages")
                }
                app.styleChanged()
            }
        )
    }

    var body: some View {
        Form {
            Section("Files") {
                LabeledContent("Notes folder") {
                    HStack {
                        Text(verbatim: app.ceiling.isEmpty ? "—" : app.ceiling)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…") { failure = app.chooseCeiling()?.localizedDescription }
                    }
                }
                Toggle("Reload notes when they change on disk", isOn: binding(Settings.fileWatching, in: app, failure: $failure))
                Toggle("Remember the last selected folder", isOn: binding(Settings.rememberLastFolder, in: app, failure: $failure))
                Toggle("Show tags in the sidebar", isOn: binding(Settings.showSidebarTags, in: app, failure: $failure))
            }
            Section("Appearance") {
                Picker("Language", selection: language) {
                    Text("System default").tag("")
                    ForEach(languages, id: \.0) { Text(verbatim: $0.1).tag($0.0) }
                }
                Text("Applied when Stenmark restarts.").font(.caption).foregroundStyle(.secondary)
                Picker("App theme", selection: binding(Settings.theme, in: app, failure: $failure)) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                Picker("Viewer theme", selection: binding(Settings.viewerTheme, in: app, failure: $failure)) {
                    ForEach(viewerThemes, id: \.0) { Text($0.1).tag($0.0) }
                }
                Toggle(isOn: binding(Settings.tintSidebar, in: app, failure: $failure)) {
                    Text("Tint the lists")
                    Text("Mixes the accent colour from System Settings ▸ Appearance into the sidebar and document list.")
                }
            }
            if let failure {
                Text(verbatim: failure).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
    }
}

private struct FontSettings: View {
    @Environment(AppModel.self) private var app
    @State private var failure: String?

    var body: some View {
        Form {
            Section("Reader") {
                TextField("Font family", text: binding(Settings.fontFamily, in: app, failure: $failure))
                Stepper(value: binding(Settings.fontSize, in: app, failure: $failure), in: 8...32) {
                    Text("Size: \(app.settings.value(Settings.fontSize))")
                }
            }
            Section("Editor") {
                TextField("Font family", text: binding(Settings.editorFontFamily, in: app, failure: $failure))
                Stepper(value: binding(Settings.editorFontSize, in: app, failure: $failure), in: 8...32) {
                    Text("Size: \(app.settings.value(Settings.editorFontSize))")
                }
            }
            if let failure {
                Text(verbatim: failure).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
    }
}

private struct EditorSettings: View {
    @Environment(AppModel.self) private var app
    @State private var failure: String?

    var body: some View {
        Form {
            Section("Colour Theme") {
                Picker("Theme", selection: binding(Settings.editorTheme, in: app, failure: $failure)) {
                    ForEach(EditorTheme.all) { Text(verbatim: $0.label).tag($0.key) }
                }
                Toggle("Match light and dark mode", isOn: binding(Settings.editorThemeMatchSystem, in: app, failure: $failure))
            }
            Section("Appearance") {
                Toggle("Line numbers", isOn: binding(Settings.editorLineNumbers, in: app, failure: $failure))
                Toggle("Line wrap", isOn: binding(Settings.editorLineWrap, in: app, failure: $failure))
            }
            Section("Behaviour") {
                Toggle("Double-click to edit", isOn: binding(Settings.doubleClickToEdit, in: app, failure: $failure))
                Toggle("Hide the lists while editing", isOn: binding(Settings.hideSidebarOnEdit, in: app, failure: $failure))
            }
            if let failure {
                Text(verbatim: failure).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
    }
}
