// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// A note containing the search text, with the text around the first match.
public struct SearchHit: Sendable, Equatable {
    public let file: URL
    public let before: String
    public let match: String
    public let after: String
}

/// Full-text search across notes.
public enum NoteSearch {
    private static let context = 60

    /// Searches `files` in order, yielding hits as they're found so that a list
    /// can fill in while a slow download holds up a later note. Stop consuming
    /// the stream to cancel the search.
    public static func hits(for query: String, in files: [URL]) -> AsyncStream<SearchHit> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                for file in files {
                    if Task.isCancelled { break }
                    // A note that can't be read has nothing to find in it.
                    guard let data = try? Data(contentsOf: file) else { continue }
                    if let hit = search(String(decoding: data, as: UTF8.self), for: query, file: file) {
                        continuation.yield(hit)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func search(_ text: String, for query: String, file: URL) -> SearchHit? {
        guard !query.isEmpty, let range = text.range(of: query, options: .caseInsensitive) else { return nil }

        var start = text.index(range.lowerBound, offsetBy: -context, limitedBy: text.startIndex) ?? text.startIndex
        var end = text.index(range.upperBound, offsetBy: context, limitedBy: text.endIndex) ?? text.endIndex

        // Whole words at the edges, unless the context is one long word. These
        // are the spaces furthest from the match, to keep as much as possible.
        if start > text.startIndex, let space = text[start..<range.lowerBound].firstIndex(of: " ") {
            start = text.index(after: space)
        }
        if end < text.endIndex, let space = text[range.upperBound..<end].lastIndex(of: " ") {
            end = space
        }

        func flat(_ part: Substring) -> String {
            String(part).replacing(/\r\n|\n/, with: " ")
        }
        return SearchHit(
            file: file,
            before: (start > text.startIndex ? "\u{2026}" : "") + flat(text[start..<range.lowerBound]),
            match: flat(text[range]),
            after: flat(text[range.upperBound..<end]) + (end < text.endIndex ? "\u{2026}" : "")
        )
    }
}
