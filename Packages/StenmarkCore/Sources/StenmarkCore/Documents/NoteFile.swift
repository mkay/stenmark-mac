// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

import CryptoKit
import Foundation

/// A note as it was read from disk: its text, and what's needed to write it
/// back the same way and to notice if the file changes meanwhile.
public struct LoadedNote: Sendable, Equatable {
    /// With "\n" line endings whatever the file uses, which is what CodeMirror
    /// hands back. `NoteFile` restores the file's own endings on saving.
    public var text: String
    public var format: NoteFormat
    public var fingerprint: NoteFingerprint
}

/// How a note's text is stored. All of it survives a save, so that opening a
/// note on one machine doesn't rewrite every line for the other.
public struct NoteFormat: Sendable, Equatable {
    public enum LineEnding: Sendable { case lf, crlf }
    public enum Encoding: Sendable { case utf8, utf8WithBOM, latin1 }

    public var lineEnding: LineEnding = .lf
    public var encoding: Encoding = .utf8

    public init(lineEnding: LineEnding = .lf, encoding: Encoding = .utf8) {
        self.lineEnding = lineEnding
        self.encoding = encoding
    }
}

/// Identifies a file's contents. A hash rather than the modification date,
/// because sync clients touch dates without changing a byte, and a change must
/// never go unnoticed because it landed within the date's resolution.
public struct NoteFingerprint: Sendable, Equatable {
    let digest: SHA256Digest

    init(_ data: Data) {
        digest = SHA256.hash(data: data)
    }
}

public enum NoteError: Error, LocalizedError {
    case unreadable(URL, underlying: Error)
    case unwritable(URL, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let url, let error):
            String(localized: "“\(url.lastPathComponent)” can't be read: \(error.localizedDescription)", bundle: .module)
        case .unwritable(let url, let error):
            String(localized: "“\(url.lastPathComponent)” can't be saved: \(error.localizedDescription)", bundle: .module)
        }
    }
}

/// What came of a save.
public enum SaveOutcome: Sendable, Equatable {
    /// Written. Keep the fingerprint for the next save.
    case saved(NoteFingerprint)
    /// The file already held this text, so it wasn't touched. Writing it would
    /// change the modified date and make Nextcloud upload the note again.
    case unchanged(NoteFingerprint)
    /// The file changed since it was read, probably through sync. Nothing was
    /// written. The caller decides, and `NoteFile.overwrite` or
    /// `NoteFile.saveCopy` carry out the decision.
    case conflict(LoadedNote)
    /// The file is gone, moved or deleted elsewhere. Nothing was written.
    case removed
}

/// Reads and writes notes. Every write to a note goes through here, because
/// this is where the rules for sharing a synced folder are kept.
///
/// All of this blocks, and reading a note Nextcloud hasn't downloaded yet can
/// block for a while, so call it away from the main thread.
public enum NoteFile {
    public static func load(_ url: URL) throws -> LoadedNote {
        let data: Data
        do {
            data = try coordinatedRead(url)
        } catch {
            throw NoteError.unreadable(url, underlying: error)
        }
        return decode(data)
    }

    /// Saves `text`, unless the file changed since `fingerprint` was taken.
    public static func save(
        _ text: String, to url: URL, format: NoteFormat, expecting fingerprint: NoteFingerprint
    ) throws -> SaveOutcome {
        let onDisk: Data
        do {
            onDisk = try coordinatedRead(url)
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            return .removed
        } catch {
            throw NoteError.unreadable(url, underlying: error)
        }

        let current = decode(onDisk)
        if current.text == normalised(text) { return .unchanged(current.fingerprint) }
        guard current.fingerprint == fingerprint else { return .conflict(current) }

        return .saved(try write(encode(text, format), to: url))
    }

    /// Replaces the file whatever it holds now, once the user has said to.
    @discardableResult
    public static func overwrite(_ url: URL, with text: String, format: NoteFormat) throws -> NoteFingerprint {
        try write(encode(text, format), to: url)
    }

    /// Writes `text` to a new file beside `url`, for keeping both versions
    /// after a conflict. Nextcloud syncs it as an ordinary note.
    public static func saveCopy(of url: URL, text: String, format: NoteFormat) throws -> URL {
        let folder = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let suffix = String(localized: "Mac copy", bundle: .module)
        var copy = folder.appending(path: "\(stem) (\(suffix)).md")
        var number = 2
        while FileManager.default.fileExists(atPath: copy.path) {
            copy = folder.appending(path: "\(stem) (\(suffix) \(number)).md")
            number += 1
        }
        try create(copy, with: encode(text, format))
        return copy
    }

    /// Whether the file still holds what `fingerprint` describes. This is how
    /// to tell a real change from the echo of the app's own save when the
    /// folder watcher fires. Unreadable counts as changed.
    public static func matches(_ url: URL, _ fingerprint: NoteFingerprint) -> Bool {
        (try? coordinatedRead(url)).map { NoteFingerprint($0) == fingerprint } ?? false
    }

    /// Replaces a note's tags, with the same conflict rules as any other save:
    /// the note is read and written in one go, so there's nothing stale to
    /// protect, and `unchanged` means it already had these tags.
    public static func updateTags(of url: URL, to tags: [String]) throws -> SaveOutcome {
        let note = try load(url)
        let updated = Frontmatter.updatingTags(in: note.text, to: tags)
        return try save(updated, to: url, format: note.format, expecting: note.fingerprint)
    }

    // MARK: Decoding and encoding

    static func decode(_ data: Data) -> LoadedNote {
        let fingerprint = NoteFingerprint(data)
        var format = NoteFormat()
        let text: String
        if data.starts(with: [0xEF, 0xBB, 0xBF]), let decoded = String(bytes: data.dropFirst(3), encoding: .utf8) {
            format.encoding = .utf8WithBOM
            text = decoded
        } else if let decoded = String(bytes: data, encoding: .utf8) {
            text = decoded
        } else {
            // Every byte is valid Latin-1, so this always succeeds and writes
            // back byte for byte. Linux refuses these files instead.
            format.encoding = .latin1
            text = String(bytes: data, encoding: .isoLatin1) ?? ""
        }

        // A file with both kinds of ending counts as whichever it has more of.
        // It's only rewritten if the note is really edited.
        let crlf = text.components(separatedBy: "\r\n").count - 1
        let lf = text.utf8.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) } - crlf
        format.lineEnding = crlf > lf ? .crlf : .lf
        return LoadedNote(text: normalised(text), format: format, fingerprint: fingerprint)
    }

    static func encode(_ text: String, _ format: NoteFormat) -> Data {
        var out = normalised(text)
        if format.lineEnding == .crlf {
            out = out.replacingOccurrences(of: "\n", with: "\r\n", options: .literal)
        }
        switch format.encoding {
        case .utf8:
            return Data(out.utf8)
        case .utf8WithBOM:
            return Data([0xEF, 0xBB, 0xBF]) + Data(out.utf8)
        case .latin1:
            // Text typed into a Latin-1 note can fall outside it. UTF-8 keeps
            // that text, where a lossy conversion would silently change it.
            return out.data(using: .isoLatin1) ?? Data(out.utf8)
        }
    }

    private static func normalised(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n", options: .literal)
    }

    // MARK: Disk

    private static func coordinatedRead(_ url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { file in
            result = Result { try Data(contentsOf: file) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    /// Writes through a temporary file, so a crash can't leave a truncated note
    /// for sync to pick up.
    ///
    /// `replaceItemAt` because `Data.write(options: .atomic)` puts its temporary
    /// file beside the note, and in a synced folder that's visible to the sync
    /// client. A coordinator because that's how the File Provider extension
    /// behind Nextcloud finds out about the change.
    @discardableResult
    private static func write(_ data: Data, to url: URL) throws -> NoteFingerprint {
        // A note can be a symlink. Replacing the link would leave the real note
        // unchanged and turn the link into a separate file.
        let target = url.resolvingSymlinksInPath()
        var coordinationError: NSError?
        var failure: Error?
        NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing, error: &coordinationError) { file in
            do {
                try replace(file, with: data)
            } catch {
                failure = error
            }
        }
        if let error = coordinationError ?? failure {
            throw NoteError.unwritable(url, underlying: error)
        }
        return NoteFingerprint(data)
    }

    private static func replace(_ file: URL, with data: Data) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: file.path) else {
            try create(file, with: data)
            return
        }
        let scratch = try manager.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: file, create: true)
        defer { try? manager.removeItem(at: scratch) }
        let temporary = scratch.appending(path: file.lastPathComponent)
        try data.write(to: temporary)
        _ = try manager.replaceItemAt(file, withItemAt: temporary)
    }

    /// Makes a new file, with its name in composed Unicode form.
    ///
    /// Not through Foundation, which decomposes every name it creates, and URL
    /// decomposes paths as soon as it holds them. Linux compares names byte for
    /// byte, so a decomposed "ü" isn't the "ü" someone types there. Replacing an
    /// existing file is different: that keeps the name's bytes whatever the
    /// form of the path, so existing notes stay as they are.
    static func create(_ file: URL, with data: Data) throws {
        let folder = file.deletingLastPathComponent().path
        let name = file.lastPathComponent.precomposedStringWithCanonicalMapping
        let descriptor = open(folder + "/" + name, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.close()
    }
}
