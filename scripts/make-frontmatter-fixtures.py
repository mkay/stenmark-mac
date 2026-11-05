#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
# SPDX-License-Identifier: GPL-3.0-only
"""Writes the golden files for the frontmatter tests from the Linux app's code.

The Mac app must write tags exactly as Linux does, or a tag edit on one machine
reformats the note for the other and it churns through sync. Running the real
update_tags() here means the expected output can't drift from what Linux does.

    scripts/make-frontmatter-fixtures.py ../../stenmark/repo

Needs PyYAML. Every input is already in PyYAML's form, as notes written by
Stenmark are: on anything else the Mac app deliberately touches only the tags.
"""
import importlib.util
import json
import sys
import tempfile
from pathlib import Path

import yaml

linux = Path(sys.argv[1]) / "stenmark" / "frontmatter.py"
spec = importlib.util.spec_from_file_location("frontmatter", linux)
frontmatter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(frontmatter)

AWKWARD = [
    "plain", "two words", "c++", "c#", "a#b", "a #b", "a: b", "a:b", "key:", ":colon",
    "?q", "q?", "a,b", ",a", "[x]", "x[1]", "{x}", "x{1}", "*star", "&amp", "!bang",
    "|pipe", ">gt", "'q", "q'", '"q', 'q"', "it's", "%p", "@a", "`b", "-x", "- x", "-",
    "--", "---", "---x", "...", "...x", ".net", ".5", "5.", "1.5", "1e3", "1.0e+3", "123",
    "0", "017", "0o17", "0x1f", "0b11", "1_000", "+1", "-1", "1:30", ".inf", ".nan",
    "true", "True", "TRUE", "false", "yes", "no", "on", "off", "y", "n", "null", "Null",
    "~", "<<", "=", "2026-11-05", "2026-11-05 10:00:00", "2026-1-5", "ümläut", "straße",
    "日本語", "🎉", "tab\there", " leading", "trailing ", "a\\b", " nbsp", "é",
]

BODY = "# Title\n\nSome text\n\n- [ ] a task\n"


def canonical(meta):
    return f"---\n{yaml.dump(meta, default_flow_style=False, allow_unicode=True, sort_keys=True)}---\n"


def run(text, tags):
    with tempfile.NamedTemporaryFile("w", suffix=".md", encoding="utf-8", delete=False) as f:
        f.write(text)
    path = Path(f.name)
    frontmatter.update_tags(str(path), tags)
    # newline="" because the expected output has to be the file's exact bytes.
    result = path.open(encoding="utf-8", newline="").read()
    path.unlink()
    return result


cases = [{"name": f"tag {t!r}", "input": BODY, "tags": [t]} for t in AWKWARD]
cases += [
    {"name": "several tags are sorted", "input": BODY, "tags": ["zebra", "Ähnlich", "apple", "Zoo"]},
    {"name": "no frontmatter, no tags", "input": BODY, "tags": []},
    {"name": "replace", "input": canonical({"tags": ["a"]}) + BODY, "tags": ["b", "c"]},
    {"name": "remove the only key", "input": canonical({"tags": ["a"]}) + BODY, "tags": []},
    {"name": "key sorted before", "input": canonical({"alpha": 1}) + BODY, "tags": ["t"]},
    {"name": "key sorted after", "input": canonical({"zeta": 1}) + BODY, "tags": ["t"]},
    {"name": "keys on both sides", "input": canonical({"alpha": "x", "zeta": 1}) + BODY, "tags": ["t"]},
    {"name": "replace between keys", "input": canonical({"alpha": 1, "tags": ["a", "b"], "zeta": 2}) + BODY, "tags": ["c"]},
    {"name": "remove between keys", "input": canonical({"alpha": 1, "tags": ["a"], "zeta": 2}) + BODY, "tags": []},
    {"name": "nested values stay", "input": canonical({"meta": {"a": [1, 2], "b": "x"}, "tags": ["a"]}) + BODY, "tags": ["b"]},
    {"name": "dates stay", "input": canonical({"date": __import__("datetime").date(2026, 11, 5)}) + BODY, "tags": ["t"]},
    {"name": "empty body", "input": canonical({"tags": ["a"]}), "tags": ["b"]},
    {"name": "empty file", "input": "", "tags": ["a"]},
    {"name": "invalid yaml is body", "input": "---\na: [b\n---\ntext\n", "tags": ["t"]},
    {"name": "a rule is not frontmatter", "input": "---\n\ntext\n", "tags": ["t"]},
    {"name": "a list is not frontmatter", "input": "---\n- a\n---\ntext\n", "tags": ["t"]},
]
for case in cases:
    case["output"] = run(case["input"], case["tags"])

out = Path(__file__).parent.parent / "Packages/StenmarkCore/Tests/StenmarkCoreTests/Fixtures/frontmatter.json"
out.write_text(json.dumps(cases, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
print(f"{len(cases)} cases")
