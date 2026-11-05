// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import StenmarkCore
import StenmarkWeb

/// A save that found the file changed, or gone, waiting for a decision.
struct SaveConflict: Identifiable {
    let id = UUID()
    let mine: String
    /// Nil if the file is gone.
    let theirs: LoadedNote?
    let then: (() -> Void)?
}

/// Leaving a note with unsaved edits, waiting for a decision.
struct UnsavedPrompt: Identifiable {
    let id = UUID()
    let then: () -> Void
}

enum ConflictChoice {
    case keepMine, keepTheirs, keepBoth, cancel
}

/// Edit mode. The rule throughout: a save that doesn't fully succeed leaves the
/// window in edit mode with the text intact, so nothing can drop someone's work.
extension WindowModel {
    var hasUnsavedChanges: Bool {
        isEditing && editor.text != pristineText
    }

    func configureEditing() {
        isPreviewVisible = app.settings.value(Settings.previewEnabled)
        isTypewriterOn = app.settings.value(Settings.editorTypewriter)
        editor.onSave = { [weak self] in self?.saveNow() }
        editor.onEscape = { [weak self] in self?.leaveEdit() }
        editor.onTextChanged = { [weak self] _ in self?.textChanged() }
        editor.onScrollLine = { [weak self] line in
            guard let self, isPreviewVisible else { return }
            preview.scroll(toLine: line, smooth: false)
        }
        preview.onLink = { [weak self] in self?.follow($0) }
        preview.onEditRequest = { [weak self] line, word in
            guard let self, line > 0 else { return }
            Task { await self.editor.goTo(line: line, word: word) }
        }
    }

    private var editorStyle: EditorStyle {
        let settings = app.settings
        return EditorStyle(
            theme: settings.value(Settings.editorTheme),
            matchSystem: settings.value(Settings.editorThemeMatchSystem),
            isDark: isDark,
            fontFamily: settings.value(Settings.editorFontFamily),
            fontSize: settings.value(Settings.editorFontSize),
            lineNumbers: settings.value(Settings.editorLineNumbers),
            lineWrap: settings.value(Settings.editorLineWrap),
            typewriter: isTypewriterOn
        )
    }

    func applyEditorStyle() {
        guard editorLoaded else { return }
        let style = editorStyle
        Task { await editor.apply(style) }
    }

    // MARK: Entering and leaving

    func toggleEdit() {
        if isEditing { leaveEdit() } else { enterEdit() }
    }

    /// Opens the note in the editor, at `line` and `word` if given and
    /// otherwise wherever the reader had got to.
    func enterEdit(line: Int? = nil, word: String = "") {
        guard let url = openNote, !isEditing else { return }
        Task {
            let target: Int
            if let line, line > 0 { target = line } else { target = await reader.topSourceLine() }
            do {
                // From disk, not the page: the note may have changed since.
                let note = try await Task.detached { try NoteFile.load(url) }.value
                if !editorLoaded {
                    await editor.load()
                    editorLoaded = true
                }
                await editor.apply(editorStyle)
                try await load(note, into: url)
                isEditing = true
                hidesLists = app.settings.value(Settings.hideSidebarOnEdit)
                await showPreviewPage()
                // After SwiftUI has swapped the views: a web view that isn't in
                // the window yet can't take focus.
                try? await Task.sleep(for: .milliseconds(100))
                await editor.goTo(line: target, word: word)
                await editor.focus()
            } catch {
                show(error, title: String(localized: "Couldn’t Open the Note"))
            }
        }
    }

    private func load(_ note: LoadedNote, into url: URL) async throws {
        try await editor.setContent(note.text)
        editBase = note
        // What CodeMirror holds after loading: it reads a lone \r as a line
        // break, and that mustn't look like an edit.
        pristineText = note.text.replacingOccurrences(of: "\r", with: "\n")
        diskChangedWhileEditing = false
        wordCount = note.text.split(whereSeparator: \.isWhitespace).count
    }

    /// Done editing: saves if there's anything to save, then shows the note.
    func leaveEdit() {
        guard isEditing else { return }
        Task {
            if await save(then: { [weak self] in self?.showReader() }) { await showReaderNow() }
        }
    }

    private func showReader() {
        Task { await showReaderNow() }
    }

    /// Back to the reader, at the line the editor had reached.
    private func showReaderNow() async {
        let line = await editor.topLine()
        guard let url = openNote else { return }
        stopEditing()
        do {
            let note = try await Task.detached { try NoteFile.load(url) }.value
            await display(note, of: url, keepPosition: false)
            reader.scroll(toLine: line, smooth: false)
        } catch {
            show(error, title: String(localized: "Couldn’t Open the Note"))
        }
    }

    private func stopEditing() {
        isEditing = false
        editBase = nil
        pristineText = ""
        diskChangedWhileEditing = false
        previewTask?.cancel()
        hidesLists = false
    }

    /// Runs `then` once there's no edit in the way, asking first if there are
    /// unsaved changes. Nothing is written unless the user says to save.
    func finishEditing(then: @escaping () -> Void) {
        guard isEditing else {
            then()
            return
        }
        if hasUnsavedChanges {
            unsavedPrompt = UnsavedPrompt(then: then)
        } else {
            stopEditing()
            then()
        }
    }

    func answerUnsavedPrompt(_ prompt: UnsavedPrompt, save shouldSave: Bool) {
        unsavedPrompt = nil
        guard shouldSave else {
            // Straight out, without saving. On Linux this path saves by accident.
            stopEditing()
            prompt.then()
            return
        }
        let finish: () -> Void = { [weak self] in
            self?.stopEditing()
            prompt.then()
        }
        Task {
            if await save(then: finish) { finish() }
        }
    }

    // MARK: Saving

    func saveNow() {
        Task { await save(then: nil) }
    }

    /// Saves any edits. True if everything is on disk and the caller can go on.
    /// False means it can't yet, and the window stays in edit mode: either there
    /// was an error, or a conflict is waiting, whose answer will run `then`.
    @discardableResult
    func save(then: (() -> Void)?) async -> Bool {
        guard isEditing, let url = openNote, let base = editBase else { return false }
        guard hasUnsavedChanges else { return true }
        let text = editor.text
        do {
            let outcome = try await Task.detached {
                try NoteFile.save(text, to: url, format: base.format, expecting: base.fingerprint)
            }.value
            switch outcome {
            case .saved(let fingerprint), .unchanged(let fingerprint):
                markSaved(text, fingerprint, format: base.format)
                return true
            case .conflict(let theirs):
                conflict = SaveConflict(mine: text, theirs: theirs, then: then)
            case .removed:
                conflict = SaveConflict(mine: text, theirs: nil, then: then)
            }
        } catch {
            show(error, title: String(localized: "Couldn’t Save the Note"))
        }
        return false
    }

    private func markSaved(_ text: String, _ fingerprint: NoteFingerprint, format: NoteFormat) {
        let saved = LoadedNote(text: text, format: format, fingerprint: fingerprint)
        editBase = saved
        shown = saved
        pristineText = text
        diskChangedWhileEditing = false
    }

    func resolve(_ conflict: SaveConflict, with choice: ConflictChoice) {
        self.conflict = nil
        guard choice != .cancel, let url = openNote, let base = editBase else { return }
        Task {
            do {
                switch choice {
                case .keepMine:
                    let mine = conflict.mine
                    let fingerprint = try await Task.detached {
                        try NoteFile.overwrite(url, with: mine, format: base.format)
                    }.value
                    markSaved(mine, fingerprint, format: base.format)
                case .keepBoth:
                    let mine = conflict.mine
                    _ = try await Task.detached {
                        try NoteFile.saveCopy(of: url, text: mine, format: base.format)
                    }.value
                    try await take(conflict.theirs, url)
                case .keepTheirs:
                    try await take(conflict.theirs, url)
                case .cancel:
                    return
                }
                conflict.then?()
            } catch {
                show(error, title: String(localized: "Couldn’t Save the Note"))
            }
        }
    }

    private func take(_ theirs: LoadedNote?, _ url: URL) async throws {
        if let theirs {
            try await load(theirs, into: url)
            shown = theirs
        } else {
            // There's nothing to go back to: the note is gone.
            stopEditing()
            openNote = nil
            shown = nil
        }
    }

    /// The watcher saw the file change while it's open in the editor. With no
    /// edits to lose, the editor follows it; with edits, it says so, and the
    /// save will ask.
    func noteChangedWhileEditing() {
        guard let url = openNote, let fingerprint = editBase?.fingerprint else { return }
        Task {
            let same = await Task.detached { NoteFile.matches(url, fingerprint) }.value
            guard !same, isEditing, openNote == url else { return }
            guard !hasUnsavedChanges else {
                diskChangedWhileEditing = true
                return
            }
            guard let note = try? await Task.detached(operation: { try NoteFile.load(url) }).value else {
                diskChangedWhileEditing = true
                return
            }
            let line = await editor.topLine()
            try? await load(note, into: url)
            await editor.goTo(line: line, center: false)
        }
    }

    // MARK: Preview and tools

    private func textChanged() {
        guard isEditing else { return }
        wordCount = editor.text.split(whereSeparator: \.isWhitespace).count
        previewTask?.cancel()
        previewTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await updatePreview()
        }
    }

    private func renderedPreview() -> String {
        let frontmatter = Frontmatter(in: editor.text)
        return app.renderer.html(frontmatter?.body ?? editor.text, lineOffset: frontmatter?.lineCount ?? 0)
    }

    /// The preview's page always exists in edit mode, even hidden, because the
    /// table of contents reads its headings.
    private func showPreviewPage() async {
        guard let url = openNote else { return }
        var previewStyle = style
        previewStyle.isPreview = true
        await preview.show(ReaderPage.html(body: renderedPreview(), style: previewStyle), folder: url.deletingLastPathComponent())
        headings = await preview.headings()
    }

    private func updatePreview() async {
        await preview.setBody(renderedPreview())
        headings = await preview.headings()
    }

    func restylePreview() {
        Task { await showPreviewPage() }
    }

    func togglePreview() {
        isPreviewVisible.toggle()
        try? app.settings.set(Settings.previewEnabled, to: isPreviewVisible)
    }

    func toggleTypewriter() {
        guard isEditing else { return }
        isTypewriterOn.toggle()
        try? app.settings.set(Settings.editorTypewriter, to: isTypewriterOn)
        applyEditorStyle()
    }

    func format(_ function: String, _ argument: Int? = nil) {
        Task {
            if let argument {
                _ = try? await editor.call(function, argument)
            } else {
                _ = try? await editor.call(function)
            }
            await editor.focus()
        }
    }
}
