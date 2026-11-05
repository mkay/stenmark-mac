// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

/// The rest of the settings arrive in Phase 5. This one is here already because
/// the sidebar's selector can't leave the root folder, so this is the only way
/// to change it.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var failure: String?

    var body: some View {
        Form {
            LabeledContent("Notes folder") {
                HStack {
                    Text(verbatim: app.ceiling.isEmpty ? "—" : app.ceiling)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Button("Choose…") { failure = app.chooseCeiling()?.localizedDescription }
                }
            }
            if let failure {
                Text(verbatim: failure).foregroundStyle(.red)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
