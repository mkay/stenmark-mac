# Stenmark for macOS

A native macOS Markdown reader, organiser and editor, rebuilt in Swift and SwiftUI from
[Stenmark for Linux](https://github.com/mkay/stenmark). The editor is CodeMirror 6, hosted
in a `WKWebView`.

<img src="docs/icon.png" alt="Stenmark icon" width="128">

This is an early version, not a finished app yet.

Both apps are meant to work on the same synced folder of notes, so the Mac app writes
files exactly as the Linux app does.

## Layout

| Path | What |
|---|---|
| `App/` | The SwiftUI app target |
| `Packages/StenmarkCore/` | Notes, frontmatter and saving. No UI imports. |
| `Packages/StenmarkWeb/` | `WKWebView` hosts, the `stenmark://` scheme handler, built web bundles |
| `web/editor/` | CodeMirror source, from the Linux app |
| `web/reader/` | The Markdown renderer: markdown-it and highlight.js |
| `project.yml` | XcodeGen spec. `Stenmark.xcodeproj` is generated, not checked in. |

## Building

Requires Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
xcodebuild -project Stenmark.xcodeproj -scheme Stenmark -configuration Debug -derivedDataPath build/DerivedData build
(cd Packages/StenmarkCore && swift test)
(cd Packages/StenmarkWeb && swift test)
```

The web bundles are committed. After changing `web/`, rebuild them with Node:

```sh
(cd web/editor && npm ci --ignore-scripts && npm run build)
(cd web/reader && npm ci --ignore-scripts && npm run build)
```

`scripts/make-frontmatter-fixtures.py` regenerates the frontmatter test fixtures from the
Linux app's own code. It needs PyYAML.

## License

GPL-3.0-**only**. See [LICENSE](LICENSE) and [COPYRIGHT](COPYRIGHT).
