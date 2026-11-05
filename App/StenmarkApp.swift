// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

@main
struct StenmarkApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup(id: "main") {
            MainWindow()
                .frame(minWidth: 760, minHeight: 460)
                .environment(app)
                .task { delegate.app = app }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            SidebarCommands()
            StenmarkCommands()
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { delegate.updater.checkForUpdates(nil) }
                    .disabled(!delegate.updater.updater.canCheckForUpdates)
            }
        }

        Settings {
            SettingsView().environment(app)
        }
    }
}
