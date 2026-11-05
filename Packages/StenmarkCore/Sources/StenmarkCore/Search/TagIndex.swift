// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Which notes have which tags. An actor because building it reads every note
/// under the root, and each read can wait on Nextcloud downloading the file.
public actor TagIndex {
    /// Enough to cover frontmatter, as on Linux.
    private static let readLength = 8192

    private var root: URL
    // Keyed by path, not URL. Swift compares strings by canonical equivalence,
    // so a path from the watcher finds the same note whichever Unicode form it
    // arrives in. URLs of the two forms aren't equal.
    private var filesByTag: [String: Set<String>] = [:]
    private var tagsByFile: [String: [String]] = [:]

    public init(root: URL) {
        self.root = root
    }

    /// Walks the root again. A note that can't be read just has no tags until
    /// the next rebuild, so one failed download doesn't cost the whole index.
    public func rebuild() async {
        filesByTag.removeAll()
        tagsByFile.removeAll()
        for file in NoteLibrary.allNotes(under: root) {
            if Task.isCancelled { return }
            index(file)
            await Task.yield()
        }
    }

    public func setRoot(_ root: URL) async {
        self.root = root
        await rebuild()
    }

    public var allTags: [String] {
        filesByTag.keys.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
    }

    public func count(of tag: String) -> Int {
        filesByTag[tag]?.count ?? 0
    }

    public func tags(of file: URL) -> [String] {
        tagsByFile[file.path] ?? []
    }

    /// The notes having every one of `tags`, sorted by path.
    public func files(matchingAll tags: [String]) -> [URL] {
        guard let first = tags.first else { return [] }
        let matching = tags.dropFirst().reduce(filesByTag[first] ?? []) { $0.intersection(filesByTag[$1] ?? []) }
        return matching.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Indexes a note again after a change, or forgets it if it's gone.
    public func update(_ file: URL) {
        remove(file)
        index(file)
    }

    public func remove(_ file: URL) {
        for tag in tagsByFile.removeValue(forKey: file.path) ?? [] {
            filesByTag[tag]?.remove(file.path)
            if filesByTag[tag]?.isEmpty == true { filesByTag[tag] = nil }
        }
    }

    private func index(_ file: URL) {
        guard let text = NoteLibrary.readStart(of: file, bytes: Self.readLength) else { return }
        let tags = Frontmatter.tags(in: text)
        guard !tags.isEmpty else { return }
        tagsByFile[file.path] = tags
        for tag in tags { filesByTag[tag, default: []].insert(file.path) }
    }
}
