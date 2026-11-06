#!/usr/bin/env python3
"""Writes App/Resources/ThirdPartyNotices.txt, which Help shows in the app.

MIT and BSD code has to carry its copyright and licence text, and minifying
strips both from the web bundles. Run this after changing what the bundles use,
or the version of Yams or Sparkle. With --check it changes nothing and fails if
the file is out of date, which is how release.sh uses it.

It asks esbuild what really ends up in each bundle, so a package that's only in
the lockfile, like argparse, stays out. It needs web/*/node_modules, and the
Swift packages checked out by a build.
"""
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "App/Resources/ThirdPartyNotices.txt"
STORED = ROOT / "scripts/licences"

BUNDLES = [("web/editor", ["src/editor.js"]), ("web/reader", ["src/reader.js", "src/page.js"])]

# These don't carry their licence text, so it's kept here, from upstream:
# github.com/uiwjs/react-codemirror/blob/master/LICENSE (npm packages with only
# "license": "MIT"), and github.com/yaml/libyaml/blob/master/License (compiled
# into Yams as CYaml).
UIW = "uiw-react-codemirror.txt"
LIBYAML = "libyaml.txt"

HEADER = """\
Stenmark for macOS includes the third-party software below. Each is under its
own licence, not Stenmark's. Packages with the same licence text share an entry.

Written by scripts/make-notices.py. Don't edit it by hand.
"""


def die(message):
    print(message, file=sys.stderr)
    sys.exit(1)


def shipped_packages(folder, entry):
    """The packages with code in the bundle made from `entry`."""
    with tempfile.TemporaryDirectory() as temp:
        meta = Path(temp) / "meta.json"
        subprocess.run(
            ["node_modules/.bin/esbuild", entry, "--bundle", "--minify", "--log-level=error",
             f"--metafile={meta}", f"--outfile={Path(temp) / 'out.js'}"],
            cwd=ROOT / folder, check=True)
        outputs = json.loads(meta.read_text())["outputs"]
    names = set()
    for output in outputs.values():
        for path, info in output["inputs"].items():
            match = re.search(r"node_modules/((?:@[^/]+/)?[^/]+)/", path)
            if match and info["bytesInOutput"] > 0:
                names.add(match.group(1))
    return names


def npm_licence(package):
    files = sorted(f for f in package.iterdir() if re.match(r"(?i)(licen[sc]e|copying)", f.name))
    if files:
        return files[0].read_text(encoding="utf-8")
    if package.parent.name == "@uiw":
        return (STORED / UIW).read_text(encoding="utf-8")
    die(f"No licence text for {package.name}: add it to scripts/licences.")


def web_entries():
    entries = []
    for folder, sources in BUNDLES:
        modules = ROOT / folder / "node_modules"
        if not modules.is_dir():
            die(f"Run npm ci --ignore-scripts in {folder} first.")
        for name in set().union(*(shipped_packages(folder, source) for source in sources)):
            package = modules / name
            version = json.loads((package / "package.json").read_text())["version"]
            entries.append((f"{name} {version}", npm_licence(package)))
    return entries


def swift_entries():
    checkouts = next((c for c in (ROOT / "build/DerivedData/SourcePackages/checkouts",
                                  ROOT / "build/Release/SourcePackages/checkouts") if c.is_dir()), None)
    if checkouts is None:
        die("Build the app first, so that Yams and Sparkle are checked out.")
    resolved = json.loads((ROOT / "Packages/StenmarkCore/Package.resolved").read_text())
    yams = next(p["state"]["version"] for p in resolved["pins"] if p["identity"] == "yams")
    sparkle = re.search(r"Sparkle:\n.*\n\s+exactVersion: (\S+)", (ROOT / "project.yml").read_text()).group(1)
    return [
        (f"Yams {yams}", (checkouts / "Yams/LICENSE").read_text(encoding="utf-8")),
        ("libYAML, as part of Yams", (STORED / LIBYAML).read_text(encoding="utf-8")),
        (f"Sparkle {sparkle}", (checkouts / "Sparkle/LICENSE").read_text(encoding="utf-8")),
    ]


def render(entries):
    groups = {}
    for name, text in entries:
        groups.setdefault(text.strip().replace("\r\n", "\n"), set()).add(name)
    parts = [HEADER]
    for text, names in sorted(groups.items(), key=lambda group: sorted(group[1])[0].lower()):
        parts.append("=" * 72 + "\n\n" + "\n".join(sorted(names)) + "\n\n" + text + "\n")
    return "\n".join(parts)


def main():
    notices = render(web_entries() + swift_entries())
    if "--check" in sys.argv:
        if not OUTPUT.exists() or OUTPUT.read_text(encoding="utf-8") != notices:
            die("ThirdPartyNotices.txt is out of date: run scripts/make-notices.py and commit it.")
        return
    OUTPUT.write_text(notices, encoding="utf-8")


main()
