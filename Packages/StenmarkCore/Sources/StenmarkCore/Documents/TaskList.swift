// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Task list items in a note's text.
public enum TaskList {
    /// Returns `text` with the checkbox on `line` (counting from 1) set to
    /// `checked`, or nil if that line holds no checkbox. Only the one character
    /// in the brackets changes.
    public static func setting(_ checked: Bool, onLine line: Int, in text: String) -> String? {
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(line - 1),
              let match = lines[line - 1].firstMatch(of: /^[\s>]*(?:[-*+]|\d+[.)])\s+\[([ xX])\]/)
        else { return nil }
        lines[line - 1].replaceSubrange(match.output.1.startIndex..<match.output.1.endIndex, with: checked ? "x" : " ")
        return lines.joined(separator: "\n")
    }
}

extension NoteFile {
    /// Ticks or clears a checkbox in the file. `fingerprint` is the version the
    /// reader is showing: if the file has moved on, the line number may point
    /// at something else, so it reports a conflict and changes nothing.
    public static func setTask(
        _ checked: Bool, onLine line: Int, of url: URL, expecting fingerprint: NoteFingerprint
    ) throws -> SaveOutcome {
        let note = try load(url)
        guard note.fingerprint == fingerprint,
              let updated = TaskList.setting(checked, onLine: line, in: note.text)
        else { return .conflict(note) }
        return try save(updated, to: url, format: note.format, expecting: note.fingerprint)
    }
}
