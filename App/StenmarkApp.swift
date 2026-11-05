// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

@main
struct StenmarkApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup(id: "main") {
            MainWindow()
                .frame(minWidth: 760, minHeight: 460)
                .environment(app)
        }
        .defaultSize(width: 1100, height: 720)
        .commands { StenmarkCommands() }

        Settings {
            SettingsView().environment(app)
        }
    }
}
