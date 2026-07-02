# Peep

A native macOS app to preview the contents of archive files by drag-and-drop, without extracting them.

Drop a `.zip`, `.tar`, `.7z`, Outlook `.msg`/TNEF, or `.eml` file onto Peep and browse its contents in a sortable, searchable file list — no extraction required until you actually want a file.

## Features

- **Drag-and-drop or Finder "Open With"** to open an archive — no need to extract first
- **Native, sortable, resizable columns** (Name / Size / Date Modified / Kind), Finder-style folder-first sorting
- **Full-text filter** across every path in the archive (⌘F)
- **Quick Look** on any file without extracting it (Space or Return)
- **Multi-selection** with Shift/Cmd-click, batch extraction, and Finder-matching right-click behavior
- **Drag files or folders out** to Finder/Desktop, or copy (⌘C) and paste them elsewhere — both extract on demand
- **Extract** a single file, a folder, a multi-selection, or the whole archive, with a progress bar and cancel support
- **File menu commands** for everything above (Open…, Extract Selected/All…, Close Archive) with proper keyboard shortcuts
- Light/Dark/System appearance, and an option to reveal extracted files in Finder automatically

## Supported formats

| Format | Backend |
|---|---|
| `.zip` | [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) |
| `.tar`, `.tar.gz`, `.tgz`, `.tar.bz2`, `.tbz`, `.tbz2` | [SWCompression](https://github.com/tsolomko/SWCompression) |
| `.7z` | [SWCompression](https://github.com/tsolomko/SWCompression) |
| `.eml` | [MimeParser](https://github.com/miximka/MimeParser) — renders a message preview plus attachments |
| `.msg` (Outlook) | Pure Swift OLE2/CFB parser (no dependency) |
| `.tnef` / `winmail.dat` | Pure Swift TNEF parser (no dependency) |

## Requirements

- macOS 26 or later, Apple Silicon
- Not sandboxed — no special permissions needed to run

## Installation

### Option 1: Download the installer (recommended for most people)

1. Grab `Peep-<version>.pkg` from the [Releases](../../releases) page.
2. Double-click it and follow the installer.
3. **This build isn't signed with an Apple Developer ID**, so macOS will refuse to open it the first time ("Apple could not verify... is free of malware"). To proceed:
   - Right-click (or Control-click) the `.pkg` → **Open**, then confirm in the dialog that appears, **or**
   - Go to **System Settings → Privacy & Security**, scroll to the bottom, and click **Open Anyway** next to the blocked-item notice, then re-open the installer.
4. Peep installs to `/Applications`. First launch may also need the same right-click → Open step for the app itself.

If you'd rather avoid the Gatekeeper prompt entirely, build from source instead (below) — Xcode-built apps run locally without any of this.

### Option 2: Build from source

Requires the full **Xcode app** (not just the command-line tools) — `xcodebuild` needs it, and running tests requires the Xcode GUI (see [Development](#development) below).

```sh
git clone <this-repo-url>
cd Peep
open Peep.xcodeproj
```

Xcode will fetch the three Swift Package dependencies (ZIPFoundation, SWCompression, MimeParser) automatically. Select the **Peep** scheme and press ⌘R.

## Usage tips

| Action | Shortcut |
|---|---|
| Open an archive | ⌘O |
| Filter/search | ⌘F |
| Quick Look selected item | Space or Return |
| Expand/collapse a folder | Return (when a folder is selected), or click the disclosure arrow |
| Extract selection | ⌘E |
| Extract entire archive | ⇧⌘E |
| Copy selection to Finder | ⌘C, then ⌘V in Finder |
| Close the open archive | File → Close Archive |

Drag-and-drop of a row to Finder only works once that row is already selected — click once to select, then drag. (This is a deliberate tradeoff: SwiftUI's drag gesture on an unselected row would otherwise swallow the click meant to select it.)

## Known limitations

- **Not code-signed or notarized** — see the Gatekeeper workaround above. Contributions or sponsorship toward a Developer ID would let future releases skip this entirely.
- **Large `.tar`/`.7z` archives use significant memory.** The underlying library (SWCompression) decompresses the entire archive into memory rather than streaming — `.zip` doesn't have this limitation, since ZIPFoundation reads via random-access file I/O instead.
- After first install, Finder may need a relaunch (or `lsregister -f /Applications/Peep.app`) before Peep shows up in the "Open With" menu for archive files.

## Development

See [`CLAUDE.md`](CLAUDE.md) for a full architecture walkthrough (data flow, key types, per-format reader notes, and the reasoning behind several non-obvious implementation choices).

- `xcodebuild` works fine from the command line for building the app.
- **Running the test suite from the command line does not work** — a transitive Swift Package dependency (`BitByteData`, pulled in by SWCompression) fails to resolve outside the Xcode GUI. Run tests with ⌘U in Xcode instead.
- `PeepTests` generates its own fixture archives at runtime (`TestFixtureBuilder.swift`) rather than checking in binary test archives.

## Credits

Peep is built on:

- [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) by Thomas Zoechling (MIT)
- [SWCompression](https://github.com/tsolomko/SWCompression) by Timofey Solomko (MIT)
- [MimeParser](https://github.com/miximka/MimeParser) by miximka (MIT)

## License

[MIT](LICENSE)
