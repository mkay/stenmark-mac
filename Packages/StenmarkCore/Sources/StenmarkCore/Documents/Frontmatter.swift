// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Yams

/// A note's YAML frontmatter, in the Linux app's format.
///
/// Reading goes through Yams, but writing edits the text of the `tags` key and
/// nothing else. Parsing and re-serialising would lose comments and reformat
/// values, and any change a sync client sees is a change the other machine has
/// to download.
public struct Frontmatter: Sendable {
    /// The lines between the two `---` lines, each with its line ending.
    private var lines: [String]
    private let opening: String
    private let closing: String
    /// Everything after the closing `---` line.
    public let body: String

    /// Lines taken up by the frontmatter, for turning a line number in the body
    /// into a line number in the file.
    public var lineCount: Int { lines.count + 2 }

    /// Finds the frontmatter in a note. Nil if there is none, which includes a
    /// block that isn't a valid YAML mapping: that's just a rule and some text.
    public init?(in text: String) {
        guard text.hasPrefix("---") else { return nil }
        let all = Self.splitLines(text)
        guard let first = all.first, Self.isFence(first),
              let end = all.dropFirst().firstIndex(where: Self.isFence), end > 1
        else { return nil }

        let inner = Array(all[1..<end])
        guard case .mapping? = try? Yams.compose(yaml: inner.joined()) else { return nil }
        lines = inner
        opening = first
        closing = all[end]
        body = all[(end + 1)...].joined()
    }

    /// The note's tags, trimmed and lowercased as on Linux.
    public var tags: [String] {
        guard let node = try? Yams.compose(yaml: lines.joined()),
              let value = node.mapping?["tags"]
        else { return [] }
        let raw: [String]
        if let sequence = value.sequence {
            raw = sequence.compactMap(\.string)
        } else if value.null != nil {
            raw = []
        } else {
            raw = [value.string].compactMap { $0 }
        }
        return raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    /// The tags of a note, or none if it has no frontmatter.
    public static func tags(in text: String) -> [String] {
        Frontmatter(in: text)?.tags ?? []
    }

    /// Returns the note with its tags replaced. Everything else, down to line
    /// endings and comments, stays as it was. Empty `tags` removes the key, and
    /// the whole block if that leaves nothing in it.
    public static func updatingTags(in text: String, to tags: [String]) -> String {
        guard var frontmatter = Frontmatter(in: text) else {
            guard !tags.isEmpty else { return text }
            let newline = text.contains("\r\n") ? "\r\n" : "\n"
            return "---" + newline + tagLines(tags, newline).joined() + "---" + newline + text
        }
        frontmatter.setTags(tags)
        let isEmpty = frontmatter.lines.allSatisfy {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if isEmpty { return frontmatter.body }
        return frontmatter.opening + frontmatter.lines.joined() + frontmatter.closing + frontmatter.body
    }

    private mutating func setTags(_ tags: [String]) {
        let newline = opening.hasSuffix("\r\n") ? "\r\n" : "\n"
        let replacement = tags.isEmpty ? [] : Self.tagLines(tags, newline)

        if let start = lines.firstIndex(where: { Self.key(of: $0) == "tags" }) {
            var end = start + 1
            while end < lines.count, Self.belongsToPreviousKey(lines[end]) { end += 1 }
            lines.replaceSubrange(start..<end, with: replacement)
        } else if !replacement.isEmpty {
            // PyYAML sorts keys, so this is where Linux would put it. A block
            // that isn't sorted just gets the first spot that fits.
            let index = lines.firstIndex { (Self.key(of: $0) ?? "") > "tags" } ?? lines.count
            lines.insert(contentsOf: replacement, at: index)
        }
    }

    private static func tagLines(_ tags: [String], _ newline: String) -> [String] {
        // Python sorts by code point. Swift's own String order differs from
        // that for characters with more than one Unicode form.
        let sorted = tags.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
        return ["tags:" + newline] + sorted.map { "- " + PyYAMLScalar.string($0) + newline }
    }

    /// The top-level key a line starts, if it starts one.
    private static func key(of line: String) -> String? {
        guard let first = line.unicodeScalars.first, !" \t\r\n#".unicodeScalars.contains(first),
              !belongsToPreviousKey(line), let colon = line.range(of: ":")
        else { return nil }
        let rest = line[colon.upperBound...]
        guard rest.isEmpty || rest.first!.isWhitespace else { return nil }
        return String(line[..<colon.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    /// Whether a line continues the value of the key above it. PyYAML writes
    /// sequences unindented, so "- a" counts. Comments don't: they aren't part
    /// of the value and have to survive a change to it.
    private static func belongsToPreviousKey(_ line: String) -> Bool {
        if line.hasPrefix("- ") || line.hasPrefix("-\n") || line.hasPrefix("-\r\n") { return true }
        guard let first = line.unicodeScalars.first, first == " " || first == "\t" else { return false }
        return !line.trimmingCharacters(in: .whitespaces).hasPrefix("#")
    }

    /// A `---` line. Must have a line ending, as in the Linux app's pattern.
    private static func isFence(_ line: String) -> Bool {
        // Bytes, not hasSuffix: "\r\n" is one Character, so it doesn't end in "\n".
        guard line.hasPrefix("---"), line.utf8.last == 0x0A else { return false }
        return line.dropFirst(3).unicodeScalars.allSatisfy { " \t\r\n".unicodeScalars.contains($0) }
    }

    /// Splits after every "\n", keeping the endings. Works on bytes, because
    /// Swift treats "\r\n" as one Character and would hide the "\n" in it.
    private static func splitLines(_ text: String) -> [String] {
        var lines: [String] = []
        var current: [UInt8] = []
        for byte in text.utf8 {
            current.append(byte)
            if byte == 0x0A {
                lines.append(String(decoding: current, as: UTF8.self))
                current.removeAll(keepingCapacity: true)
            }
        }
        if !current.isEmpty { lines.append(String(decoding: current, as: UTF8.self)) }
        return lines
    }
}
