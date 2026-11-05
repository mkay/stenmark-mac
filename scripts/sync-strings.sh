#!/usr/bin/env bash
# Pulls new UI strings into the String Catalogs and lists what lacks German or
# Russian. Run after changing user-visible text, then translate in Xcode or in
# the .xcstrings JSON directly.
set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED=build/DerivedData
xcodebuild -project Stenmark.xcodeproj -scheme Stenmark -configuration Debug \
    -derivedDataPath "$DERIVED" SWIFT_EMIT_LOC_STRINGS=YES build >/dev/null

sync() {
    local target=$1 catalog=$2
    local data
    data=$(find "$DERIVED" -path "*/$target.build/*" -name "*.stringsdata")
    # shellcheck disable=SC2086
    [ -n "$data" ] && xcrun xcstringstool sync "$catalog" --stringsdata $data
}
sync Stenmark App/Localizable.xcstrings
sync StenmarkCore Packages/StenmarkCore/Sources/StenmarkCore/Resources/Localizable.xcstrings
sync StenmarkWeb Packages/StenmarkWeb/Sources/StenmarkWeb/Resources/Localizable.xcstrings

python3 -I - <<'PY'
import json
for path in ["App/Localizable.xcstrings",
             "Packages/StenmarkCore/Sources/StenmarkCore/Resources/Localizable.xcstrings",
             "Packages/StenmarkWeb/Sources/StenmarkWeb/Resources/Localizable.xcstrings"]:
    strings = json.load(open(path))["strings"]
    for language in ("de", "ru"):
        todo = [k for k, e in strings.items()
                if e.get("shouldTranslate", True) and language not in e.get("localizations", {})]
        print(f"{path}: {len(strings)} strings, {len(todo)} without {language}")
        for k in todo:
            print("  ", json.dumps(k, ensure_ascii=False))
PY
