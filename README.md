# Sukurini (スクリーニー)

[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

A macOS menu bar app that watches your screenshot folder, tells you when a new one lands, and lets you drag it anywhere without opening Finder.

Named after [Screenie](https://apps.apple.com/app/screenie/id1195678496) — abandoned years ago, x86-only. This is a from-scratch rebuild for Apple Silicon.

## Features

- **Menu bar indicator** — pulses when a new screenshot lands, clears when you use it or after 30 seconds.
- **Drag from the menu bar** — press the icon and drag; the newest screenshot comes with your cursor as a copy.
- **Gallery** — click the icon for a Spotlight-style panel, newest first, grouped by day.
- **OCR search** — Vision OCR indexes the text inside screenshots (Korean, English, Japanese), since screenshot filenames are useless for search.
- **Folders** — watch any folder, switch between several, and set where macOS saves screenshots.
- **Stays out of the way** — indexing throttles on battery, pauses in Low Power Mode, and backs off when the machine gets hot.

## Requirements

macOS 14 or later, Apple Silicon only (arm64, no Rosetta fallback).

## Build

SwiftPM plus a Makefile, no Xcode project. Command Line Tools are enough.

```bash
make run
```

- `make build` — compile only
- `make bundle` — assemble `dist/Sukurini.app`
- `make sign` — bundle and ad-hoc sign
- `make run` — sign, then launch
- `make install` — install to `/Applications`
- `make logs` — stream the app's unified logs
- `make clean` — remove build output

Launch at login requires the app to live in `/Applications` or `~/Applications`, so run `make install` first.

Ad-hoc signing is the default. Its identity changes on every rebuild, so macOS treats each build as a different app — resetting folder permissions and orphaning the login item. To avoid that, create a self-signed certificate in Keychain Access and build with it:

```bash
make install IDENTITY="Your Certificate Name"
```

## Design notes

- **Almost no dependencies.** AppKit, Vision, system SQLite; SwiftUI only for the settings window. `libwebp` is the one exception — ImageIO can decode WebP but has never been able to encode it.
- **WebP conversion is opt-in and verified.** Lossless, ~60–70% smaller. The display's ICC profile is carried across with the mux API (macOS embeds the monitor profile in every capture, never sRGB), and each file is decoded back and compared pixel by pixel before the original is touched.
- **Conversion happens before publish.** The store withholds the PNG at both admission points, so the menu bar ripples once and a drag payload can never point at a file about to be deleted.
- **Copy as PNG** covers apps that still reject WebP (Google Docs, Figma) — same pixels, ICC profile, and filename, ~20 ms and cached. The pasteboard carries both the file and the bitmap.
- **Folder watching** uses a debounced kqueue `DispatchSource` with a directory diff, not Spotlight queries, so it catches anything that appears in the folder.
- **Search** uses FTS5 with the `trigram` tokenizer and `LIKE`. `MATCH` can't handle queries shorter than three characters, and two-character Korean searches are the common case.
- **The OCR index survives restarts.** Text is committed per file, so interrupting the initial pass costs nothing.

## License

Apache License 2.0 — see [LICENSE](LICENSE). Forks are welcome, but must keep the copyright notice, state what they changed, and reproduce [NOTICE](NOTICE) wherever they show third-party notices. The name "Sukurini" is not covered by the license.

## Author

Suhun Han ([@ssut](https://github.com/ssut))
