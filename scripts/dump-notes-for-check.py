#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
# SPDX-License-Identifier: GPL-3.0-only
"""Records what the Linux app sees in a notes folder, for RealNotesCheck.

    scripts/dump-notes-for-check.py ../../stenmark/repo ~/Notes /path/out.json
    STENMARK_REAL_NOTES=~/Notes STENMARK_REAL_NOTES_JSON=/path/out.json \\
        swift test --package-path Packages/StenmarkCore --filter RealNotesCheck

Reads only. The JSON holds the notes' paths, tags and titles, so keep it out of
the repository. Needs PyYAML. The scanning below is copied from the Linux app's
document_panel.py, which can't be imported here because it pulls in GTK.
"""
import importlib.util
import json
import os
import sys
from pathlib import Path

repo, root, out = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("frontmatter", Path(repo) / "stenmark" / "frontmatter.py")
frontmatter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(frontmatter)


def collect(folder):
    entries = [e for e in sorted(os.scandir(folder), key=lambda e: e.name.lower()) if not e.name.startswith(".")]
    files = [e.path for e in entries if e.is_file() and e.name.lower().endswith(".md")]
    for entry in entries:
        if entry.is_dir(follow_symlinks=False):
            files += collect(entry.path)
    return files


def title(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        text = f.read(4096)
    _meta, body = frontmatter.parse_frontmatter(text)
    for line in body.splitlines():
        line = line.strip()
        if line.startswith("# "):
            return line[2:].strip() or None
        if line:
            return None
    return None


notes = [
    {"path": os.path.relpath(p, root), "tags": frontmatter.read_tags(p), "title": title(p)}
    for p in collect(root)
]
Path(out).write_text(json.dumps(notes, ensure_ascii=False), encoding="utf-8")
print(len(notes), "notes")
