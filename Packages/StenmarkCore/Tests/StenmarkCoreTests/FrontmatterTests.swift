// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Testing
@testable import StenmarkCore

struct GoldenCase: Decodable, Sendable, CustomTestStringConvertible {
    let name: String
    let input: String
    let tags: [String]
    let output: String
    var testDescription: String { name }
}

/// Written by scripts/make-frontmatter-fixtures.py, from the Linux app's code.
let goldenCases: [GoldenCase] = {
    let url = Bundle.module.url(forResource: "Fixtures/frontmatter", withExtension: "json")!
    return try! JSONDecoder().decode([GoldenCase].self, from: Data(contentsOf: url))
}()

@Test("Writes tags byte for byte as Linux does", arguments: goldenCases)
func matchesLinux(golden: GoldenCase) {
    #expect(Frontmatter.updatingTags(in: golden.input, to: golden.tags) == golden.output)
}

@Test("Reads back every tag it writes", arguments: goldenCases.filter { $0.name.hasPrefix("tag ") })
func readsBack(golden: GoldenCase) {
    let expected = golden.tags[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    #expect(Frontmatter.tags(in: golden.output) == [expected])
}

@Test func keepsEverythingElseInAHandWrittenBlock() {
    let note = "---\n# why this note exists\ntitle: \"My note\"\nzeta: 1\ntags: [b, a]\n# keep me\nother: x\n---\nBody\n"
    #expect(Frontmatter.updatingTags(in: note, to: ["c"]) ==
        "---\n# why this note exists\ntitle: \"My note\"\nzeta: 1\ntags:\n- c\n# keep me\nother: x\n---\nBody\n")
}

@Test func keepsWindowsLineEndings() {
    let note = "---\r\ntags:\r\n- a\r\nzeta: 1\r\n---\r\nBody\r\n"
    #expect(Frontmatter.updatingTags(in: note, to: ["b", "c"]) ==
        "---\r\ntags:\r\n- b\r\n- c\r\nzeta: 1\r\n---\r\nBody\r\n")
    #expect(Frontmatter.updatingTags(in: "Body\r\n", to: ["a"]) == "---\r\ntags:\r\n- a\r\n---\r\nBody\r\n")
}

@Test func readsTheForms() {
    #expect(Frontmatter.tags(in: "---\ntags: [B, a ]\n---\n") == ["b", "a"])
    #expect(Frontmatter.tags(in: "---\ntags: Solo\n---\n") == ["solo"])
    #expect(Frontmatter.tags(in: "---\ntags:\n  - x\n  - 'y z'\n---\n") == ["x", "y z"])
    #expect(Frontmatter.tags(in: "---\ntags:\n---\n") == [])
    #expect(Frontmatter.tags(in: "no frontmatter") == [])
}

@Test func countsItsLines() {
    let note = "---\ntags:\n- a\ntitle: x\n---\n\n# Heading\n"
    #expect(Frontmatter(in: note)?.lineCount == 5)
    #expect(Frontmatter(in: note)?.body == "\n# Heading\n")
}
