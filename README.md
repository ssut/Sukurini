# Sukurini (スクリーニー)

**Sukurini** takes its name from [Screenie](https://apps.apple.com/app/screenie/id1195678496) — a lovely little screenshot shelf for macOS that stopped being updated years ago. Its last build is x86-only, runs under Rosetta, and the developer's site is gone. Sukurini is a from-scratch rebuild of what made it good, for Apple Silicon.

A menu bar app that watches your screenshot folder, tells you when a new one lands, and lets you drag it anywhere without opening Finder.

## What it does

- **Menu bar indicator.** A quiet ring sits in your menu bar. When a new screenshot lands, a dot springs out from the center and pulses. It clears the moment you use the screenshot — or after 30 seconds.
- **Drag straight from the menu bar.** Press the icon and drag. The newest screenshot comes with your cursor, as a copy, into Finder, Slack, a browser upload field, anywhere. No new screenshot needed — it always grabs the latest one in the folder.
- **Gallery.** Click the icon for a Spotlight-style panel: every screenshot, newest first, grouped by day. Double-click to open, drag out to copy.
- **Search inside images.** Screenshot filenames are all `Screenshot 2026-07-26 at ...`, which makes filename search useless. Sukurini runs Apple's Vision OCR over your screenshots and indexes the text, so you can find the one with `결제완료` or `invoice` in it. Korean, English and Japanese.
- **Folders.** Watch any folder, switch between several, and set which one macOS itself saves screenshots to.
- **Stays out of the way.** Indexing throttles on battery, pauses in Low Power Mode, and backs off when the machine gets hot.

## Requirements

macOS 14 or later, Apple Silicon. Intel Macs are not supported — the build is arm64 only, and there is no Rosetta fallback.

## Build

No Xcode project — SwiftPM plus a Makefile assembles the `.app` bundle. Command Line Tools are enough.

```bash
make run
```

Other targets:

| Target | What it does |
| --- | --- |
| `make build` | Compile only |
| `make bundle` | Assemble `dist/Sukurini.app` |
| `make sign` | Bundle and ad-hoc sign |
| `make run` | Sign, then launch |
| `make install` | Install to `/Applications` |
| `make logs` | Stream the app's unified logs |
| `make clean` | Remove build output |

Launch at login requires the app to live in `/Applications` or `~/Applications`, so run `make install` before enabling it.

### Signing

Ad-hoc signing is the default and is fine for personal use. Because an ad-hoc identity changes on every rebuild, macOS treats each build as a different app — which resets folder permissions and can orphan the login item. If that bothers you, create a self-signed code-signing certificate in Keychain Access and build with it:

```bash
make install IDENTITY="Your Certificate Name"
```

## Design notes

- **Almost no third-party dependencies.** AppKit, Vision, and the system SQLite. SwiftUI only for the settings window. The one exception is `libwebp`, because ImageIO can decode WebP but has never been able to encode it on any macOS version.
- **WebP conversion is opt-in and verified.** New screenshots convert to lossless WebP (about 60–70% smaller). The display's ICC profile is carried across with the mux API — without it a "lossless" encode still shifts colour, since macOS embeds the monitor profile in every capture and never sRGB. Each file is decoded back and compared pixel by pixel before its original is touched, so a failed conversion costs disk space, never data.
- **Conversion happens before the screenshot is ever published.** The store withholds the PNG at both admission points, so the menu bar ripples once, for the `.webp`, and the drag payload can never point at a file that is about to be deleted.
- **Copy as PNG covers the apps that still reject WebP.** Google Docs and Figma refuse a `.webp`, so the optional Copy-as-PNG mode hands copies and drags a temporary PNG rendered from the WebP instead — same pixels, same ICC profile, same filename. It costs about 20 ms per screenshot, is cached, and the pasteboard carries both the file and the bitmap so file-based and image-based receivers each get what they want.
- **Folder watching** uses a kqueue `DispatchSource` with a debounce and a directory diff, rather than Spotlight metadata queries — so it reacts to anything that appears in the folder, not just files macOS tagged as screen captures.
- **Full-text search** uses FTS5 with the `trigram` tokenizer and `LIKE`. `MATCH` can't handle queries shorter than three characters, which rules it out when two-character Korean searches are the common case.
- **The OCR index survives restarts.** Text is committed per file, so interrupting the initial pass over thousands of screenshots costs nothing.

## Author

Suhun Han ([@ssut](https://github.com/ssut))
