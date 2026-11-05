// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

#if DEBUG
import Foundation

/// Hooks for testing the real signed app from a script. Launch with
/// `open -n -W --env NAME=value`.
enum DebugHooks {
    @MainActor static func run() async {
        if let directory = ProcessInfo.processInfo.environment["STENMARK_SAVE_PROBE"] {
            await SaveProbe.run(in: URL(fileURLWithPath: directory))
            exit(0)
        }
        if let path = ProcessInfo.processInfo.environment["STENMARK_TYPING_PROBE"] {
            await TypingProbe.run(reportingTo: path)
            exit(0)
        }
    }
}
#endif
