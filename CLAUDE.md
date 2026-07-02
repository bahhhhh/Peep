# Peep

A native macOS app to preview the contents of archive files by drag-and-drop, without extracting them.

## Project structure

```
Peep/
├── Peep.xcodeproj/project.pbxproj   — hand-authored Xcode project (no xcworkspace)
├── Peep/
│   ├── PeepApp.swift                 — @main entry point, AppDelegate, AppTheme, Settings scene
│   ├── ContentView.swift             — all UI: drop zone, loading state, tree view, export, Quick Look
│   ├── ArchiveReader.swift           — multi-format reader + extractor (zip/tar/7z/TNEF/EML/MSG), ArchiveError
│   ├── FileEntry.swift               — FileEntry, ArchiveInfo, TreeNode value types + buildTree()
│   ├── Info.plist                    — manual plist with CFBundleDocumentTypes for all supported formats
│   ├── AppIcon.icns                  — app icon, delivered as a loose Resources file (see Known issues re: asset-catalog icons)
│   └── Assets.xcassets/             — AccentColor only
└── PeepTests/
    ├── ArchiveReaderTests.swift      — read + extract tests for every format; error-path and junkPaths tests
    ├── FileEntryTests.swift          — compressionRatio, buildTree (sort, nesting, implicit dirs, IDs)
    └── TestFixtureBuilder.swift      — generates test archives at runtime (ZIP via ZIPFoundation, TAR via system tar, TNEF/EML as constructed data)
```

## Requirements

- **Xcode** (not just CLI tools) — `xcodebuild` requires the full app; tests run via ⌘U or `xcodebuild test`
- **macOS 26+** deployment target (minimum and only supported OS)
- **ZIPFoundation** — added as a Swift Package dependency (fetched automatically by Xcode); handles ZIP
- **SWCompression** — added as a Swift Package dependency (fetched automatically by Xcode); handles TAR, TAR.GZ, TAR.BZ2, and 7-Zip
- **MimeParser** — added as a Swift Package dependency (fetched automatically by Xcode); handles EML/MIME parsing
- **`/usr/bin/tar`** — used by `TestFixtureBuilder` at test time to create TAR fixtures

## Architecture

### Data flow

1. User drops an archive onto the window (or opens one via Finder's "Open With" or right-click context menu)
2. Drag-and-drop: `ContentView.load()` calls `NSItemProvider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier)` to extract the file URL; then dispatches to the main actor and calls `loadURL(_:)`
3. Finder open: `AppDelegate.application(_:open:)` posts a `Notification.Name.openArchive` notification; `ContentView` receives it via `.onReceive` and calls `loadURL(_:)` directly
4. `loadURL(_:)` (`@MainActor`) cancels any in-flight load, cleans up the previous session temp dir, then stores a new `Task` in `loadTask` that calls `ArchiveReader.read(url:)`; `ArchiveReader.read` detects the format via `ArchiveFormat.detect(url:)` and dispatches to the appropriate reader in a `Task.detached`
5. Each entry is mapped to a `FileEntry`; the entries are wrapped in `ArchiveInfo`
6. `archiveInfo` state is set on `@MainActor`, which drives `buildTree()` and the tree view

### Key types

**`FileEntry`** — one entry from the archive
- `path: String` — full path inside the archive (directories end with `/`)
- `uncompressedSize / compressedSize: Int64`
- `compressionRatio: Double` — derived, 0 for directories
- `date: String` — "yyyy-MM-dd" formatted date
- `isDirectory: Bool`

**`ArchiveInfo`** — result of a successful read
- `entries: [FileEntry]`
- `fileName: String` — last path component of the source file
- `fileSize: Int64` — size of the archive file on disk

**`TreeNode`** — node in the folder hierarchy shown in the UI
- `name: String` — last path component (display name)
- `fullPath: String` — full archive path, e.g. `"usr/local/outset/"` (used as stable `id`)
- `entry: FileEntry?` — nil for implicit parent directories not listed in the archive
- `children: [TreeNode]?` — nil for files, non-nil (possibly empty) for directories
- `id: String { fullPath }` — deterministic so List selection survives re-renders

**`buildTree(from:) -> [TreeNode]`** — free function in `FileEntry.swift`
- Builds a trie from flat `[FileEntry]` paths by splitting on `/`
- Creates implicit folder nodes for any parent not explicitly listed as a directory entry
- Sorts each level: folders before files, then alphabetically

**`ArchiveError`**
- `.unsupportedFormat(String)` — thrown for unrecognised extensions; error message lists all supported formats
- `.readFailed(String)` — thrown when reading/parsing fails

**`ArchiveFormat`** (private enum in `ArchiveReader.swift`)
- `.zip`, `.tar`, `.tarGz`, `.tarBz2`, `.sevenZip`, `.tnef`, `.eml`, `.msg`
- `detect(url:)` — maps file extension / name to format; handles `.tar.gz`, `.tar.bz2`, `.tgz`, `.tbz`, `.tbz2`, `.7z`, `.tnef`, `.eml`, `.msg`, `winmail.dat`

**`AppTheme`** (in `PeepApp.swift`)
- `.system`, `.light`, `.dark` — persisted in `@AppStorage("appTheme")`
- Applies via `NSApp.appearance` in `.onChange(of: theme)`

### Reading archives

`ArchiveReader.read(url:)` detects the format then dispatches to a sync reader in `Task.detached`. All formats are read entirely in-process — no subprocesses except EML.

| Format | Reader | Notes |
|--------|--------|-------|
| `.zip` | `readZipSync` via `Archive` (ZIPFoundation) | Skips symlinks; streams entries via random-access file handle — no full archive load; dates from `entry.fileAttributes[.modificationDate]` |
| `.tar` | `readTarSync` via `TarContainer.info()` | Skips symlinks; strips leading `./`; adds trailing `/` to directory paths |
| `.tar.gz` / `.tgz` | `readTarGzSync` — `GzipArchive.unarchive` → `TarContainer.info()` | Full archive decompressed into memory before parsing |
| `.tar.bz2` / `.tbz` / `.tbz2` | `readTarBz2Sync` — `BZip2.decompress` → `TarContainer.info()` | Full archive decompressed into memory before parsing |
| `.7z` | `readSevenZipSync` via `SevenZipContainer.info()` | Skips symlinks; adds trailing `/` to directory paths |
| `.tnef` / `winmail.dat` | `readTnefSync` — pure Swift | Walks TNEF attribute stream; handles both classic (Outlook 95/96) and MAPI property bag (Outlook 97+) formats |
| `.eml` | `readEmlSync` via MimeParser | Swift MIME parsing; produces `message.html` preview + named parts |
| `.msg` | `readMsgSync` — pure Swift OLE2 parser | Walks CFB compound file; extracts body streams and `__attach_version1.N` storages; `siblings()` red-black tree traversal uses a visited set to guard against cycles in malformed files |

### Extracting archives

`ArchiveReader.extract(from:paths:junkPaths:to:)` dispatches per format:

- **zip**: `Archive(url:accessMode:.read)` (ZIPFoundation) opens archive via file handle; iterates filtered entries and calls `archive.extract(_:to:)` per entry — no full archive load into memory
- **tar**: `TarContainer.open()` loads all entries with data; filters by path set, writes to disk
- **tar.gz / tar.bz2**: decompresses to `Data` first, then same as tar
- **7z**: `SevenZipContainer.open()` loads all entries with data; `writeEntries` writes matching paths
- **TNEF**: `tnefWalk` re-runs on raw bytes, writes matching attachments
- **EML**: `emlParts` re-parses via MimeParser, writes matching parts
- **MSG**: `cfbMsgParts` re-parses the OLE2 compound file, writes matching streams

Shared helpers: `writeEntries` handles 7z extraction; `extractTarData` handles all tar variants. `loadData(from:)` wraps `Data(contentsOf:)` with a typed error.

Folder export: `ContentView.exportNode(_:)` filters `archiveInfo.entries` by `node.fullPath` prefix, then calls `ArchiveReader.extract` with the collected paths.

**Memory note**: ZIPFoundation uses random-access file I/O and does not load the full archive into memory. SWCompression (TAR, 7z) does load the entire archive into memory; for compressed tars and 7z, the decompressed content is also held in memory during extraction. This is a known trade-off of the in-process approach for those formats.

### Window appearance

- Window style: `.hiddenTitleBar`, default size 760×520
- `window.titlebarAppearsTransparent = true` set via an `NSViewRepresentable` shim on first appearance — removes the white titlebar strip so content extends to the top edge
- `.toolbar(removing: .title)` and `.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)` applied to `ContentView` body
- Default NSWindow background (white in light mode, standard dark in dark mode) — no custom material or transparency
- `WindowDragGesture()` applied to the drop zone and header bar so the window is draggable by those areas

### Drag and drop

- `.onDrop(of: [.fileURL], isTargeted: $isTargeted, perform: load)` on the root `ZStack`
- `.contentShape(Rectangle())` ensures the full ZStack surface is hittable
- `loadDataRepresentation(forTypeIdentifier:)` used instead of `loadItem` because on macOS `loadItem` may return `URL` or `Data` depending on OS version; `loadDataRepresentation` always returns `Data` parseable via `URL(dataRepresentation:relativeTo:)`
- Dropping a new file while one is already open cancels the previous load, cleans up its temp dir, and starts a fresh load
- A `dropHintOverlay` with "Drop to open" text and blue border appears over the archive view when a file is dragged over it
- **Drag-out**: each row has `.onDrag { draggingItemProvider(for: node) }`, which builds an `NSItemProvider` via `registerFileRepresentation(forTypeIdentifier:visibility:loadHandler:)`; the load handler calls `extractedURL(for:)` asynchronously and hands the resulting file/folder URL to the drag session's completion callback — dragging a row to Finder/Desktop extracts it on demand. Dragging from within a multi-selection carries all selected rows' providers.
- **Copy**: ⌘C (via the general `.onKeyPress(phases: .down)` handler) and the row context menu's "Copy" item both call `copyToPasteboard(_:)`, which extracts the given nodes via `extractedURL(for:)` and writes the resulting file URLs to `NSPasteboard.general` with `writeObjects(_:)`.
- `extractedURL(for node:) -> URL` (in `ContentView.swift`) is the shared on-demand extraction helper — extracts into a per-node subdirectory of the session temp dir, reusing a prior extraction if the destination already exists. Used by Quick Look, drag-out, and copy.

### Finder integration

**Info.plist** — `CFBundleDocumentTypes` with `LSHandlerRank = Alternate` for all supported UTIs (zip, tar, tgz, tbz, tar.gz, 7z, tnef, eml). Peep appears in "Open With" without stealing the system default. `AppDelegate.application(_:open:)` receives the URL and posts `Notification.Name.openArchive`.

`ContentView.loadURL(_:)` calls `NSDocumentController.shared.noteNewRecentDocumentURL(url)` after a successful read, so opened archives show up in the Dock icon's "Recent Items" (there is no `DocumentGroup`/File > Open Recent submenu — this is intentionally scoped to just the Dock/ menu recent-items list).

### Menu commands

`PeepApp.swift` defines `ArchiveActions` / `ArchiveWindowState` plus matching `FocusedValueKey`s, since `Commands` live outside the view hierarchy and each `WindowGroup` window has independent `ContentView` state. `ContentView.body` publishes both via `.focusedSceneValue(\.archiveActions, ...)` / `.focusedSceneValue(\.archiveWindowState, ...)`.

- `OpenArchiveCommand` (`CommandGroup(after: .newItem)`) — "Open…" (⌘O) → `pickArchiveToOpen()` (`NSOpenPanel` filtered to the supported extensions) → `loadURL(_:)`
- `ExtractAndCloseCommands` (`CommandGroup(after: .saveItem)`) — "Extract Selected/File/Folder/N Items…" (⌘E, label/enabled state driven by `ArchiveWindowState.selectionCount`/`.selectionIsDirectory`), "Extract All…" (⇧⌘E), "Close Archive" (no shortcut — see below)
- ⌘W intentionally keeps its default SwiftUI window-close behavior; there is no documented way to safely replace it for a plain `WindowGroup` scene, so "Close Archive" is menu-only.
- `CommandGroup(replacing: .appTermination)` replaces "Quit Peep" with a version that calls `exit(0)` directly instead of `NSApp.terminate(_:)`. **Why**: after any file has been dragged out of the tree via `.onDrag` (see Drag and drop), `-[NSApplication terminate:]`'s normal termination sequence posts a notification whose handling calls `CFPasteboardResolveAllPromisedData`, which hangs on the main thread for tens of seconds to a couple of minutes before eventually finishing on its own (verified via `sample` — confirmed to be a bounded OS-level timeout, not a true deadlock). This reproduced identically regardless of whether the drag's `NSItemProvider` was built lazily (`registerFileRepresentation`) or eagerly (`NSItemProvider(contentsOf:)`), and survived a freshly-restarted `pboard`, so it looks like an OS/AppKit-level rough edge on this macOS version rather than something fixable by changing how the item provider is constructed. `exit(0)` skips AppKit's termination notifications entirely, which is an acceptable trade-off since Peep has no unsaved state — but note this only covers the Quit menu item/⌘Q; Dock-icon "Quit" and Apple-Event-triggered quits still go through `-terminate:` and could still hit the slow path.

### UI states

- **Drop zone** — shown when `archiveInfo == nil && !isLoading`. Dashed border + archivebox icon; highlights blue when `isTargeted`. Lists all supported formats as hint text.
- **Loading** — `ProgressView` while `isLoading == true`
- **Archive view** — header bar + column header + tree list when `archiveInfo != nil`
- Errors surface inline in the drop zone via `errorMessage` state

### Tree view

Rendered via a native `Table`, not a `List` — gives click-to-sort columns and drag-to-resize columns for free. Getting here required flattening the tree ourselves rather than using `Table`'s hierarchical `children:` initializer; see the design rationale below since it isn't obvious from the code alone.

**Why it's flattened instead of hierarchical** — two constraints, confirmed via Apple docs/WWDC23/Apple Developer Forums before implementing:
1. `Table`'s hierarchical `children:` initializer exposes no programmatic expand/collapse API (same opaque-internal-state limitation `List`'s `children:` initializer has — the reason the tree was already off automatic disclosure before this migration, to let Return drive expansion).
2. The one API that does expose expansion as a real binding, `DisclosureTableRow(_:isExpanded:)`, cannot be recursed for arbitrary depth — `@ViewBuilder` closures require concrete view expressions, so a function that recursively returns `DisclosureTableRow`/`TableRow` can't be called from inside the `rows:` builder's `ForEach` (confirmed dead-end via Apple Developer Forums thread 747020). Archive folder nesting is unbounded, so this was a hard blocker.

Additionally, `Table` only supports per-row drag providers via the manual `rows:`/`TableRow(...).itemProvider` builder, not the simple `Table(data, selection:, sortOrder:) { columns }` convenience form — another reason the manual approach was necessary anyway once drag-out needed to keep working.

- `FlatRow` (private struct, top of `ContentView.swift`) — the Table's row type: wraps a `TreeNode` plus its display `depth`, and exposes `sortableSize`/`sortableDate`/`sortableKind` computed properties (directories sort as size `-1`/"Folder" kind) so `TableColumn(_:value:)` has something `Comparable` to sort by for every column, including the two that aren't stored properties on `TreeNode` itself
- `sortOrder: [KeyPathComparator<FlatRow>]` drives `Table`'s clickable/reversible column headers. `treeComparator()` reads `sortOrder.first` and switches on `.keyPath` (KeyPath is `Equatable`, so `case \FlatRow.sortableSize:` works) to build a plain `(TreeNode, TreeNode) -> Bool` closure — deliberately not using `KeyPathComparator`'s own `.compare()`/`.sorted(using:)` machinery, to keep the folders-first grouping (below) simple
- `sortedTree(_:)` / `sortedChildren(_:)` sort **within each sibling group, recursively at every level** — folders always before files (matches Finder), the clicked column only reorders inside each group. `sortedTreeNodes` and `visibleRows` (below) are **computed properties**, not cached `@State` — they read `sortOrder`/`expandedNodeIDs` directly, so there's no manual re-sort/re-flatten step to remember on state change
- `expandedNodeIDs: Set<String>` (all collapsed by default) is unchanged from before the Table migration — still what Return drives, now also toggled by a plain chevron `Button` inside the Name column's cell (`nameCell(for:)`), which replaced the `DisclosureGroup` triangle
- `flatten(_:depth:)` walks `sortedTreeNodes` respecting `expandedNodeIDs` into `[FlatRow]` (`visibleRows`) — this is what actually gets displayed; search mode builds its own flat `searchRows` directly from `filteredEntries` at `depth: 0` (no expansion applies, matching pre-Table behavior) and feeds the *same* `Table`/columns
- `selectedNodeIDs: Set<String>` supports Shift/Cmd-click multi-select; each ID is a `TreeNode.fullPath` (same as `FlatRow.id`, which forwards to `node.id`). `selectedNode` (singular, only non-nil when exactly one ID is selected) is kept for Quick Look; `selectedNodes` resolves the full set for extraction/copy/drag — both still resolve against the original (unsorted) `treeNodes` via `findNode`, since IDs are stable regardless of sort order
- Row icons: folder (yellow `folder.fill`) or file-type SF Symbol via `icon(for:)`; "Kind" column via `kind(for:)`. Both moved to `FileEntry.swift` as free functions (from private `ContentView` methods) since `FlatRow.sortableKind` needs to call `kind(for:)` and a private struct outside `ContentView` can't reach a `ContentView` instance method
- Drag-out is a `TableRow(row).itemProvider { selectedNodeIDs.contains(row.node.id) ? draggingItemProvider(for: row.node) : nil }` — same "only draggable once already selected" rule and the same `draggingItemProvider(for:)` as before the migration, just relocated from `.onDrag` on a `List` row
- Context menu uses `.contextMenu(forSelectionType: String.self)` on the `Table` (a plain `.contextMenu` directly on `Table` is confirmed broken in current SwiftUI), so right-clicking inside an existing multi-selection acts on the whole selection while right-clicking outside it re-targets to just that row — matches Finder. Content: "Extract Selected/File/Folder/N Items…" and "Copy"
- Space bar and Return both trigger Quick Look for files (single-selection only); Return on a selected directory instead toggles `expandedNodeIDs` (expand/collapse), checked before the Quick Look branch in the shared `.onKeyPress(phases: .down)` handler on the `Table`. ⌘C copies the selection via the same handler. Return deliberately mirrors Space for files rather than triggering extraction — popping a save-panel from an accidental Return keystroke would be surprising/destructive-feeling for a read-only browser
- Known minor side effect of the migration: the path tooltip (`.help()`) now only fires over the Name column's cell, not the full row width (each column is a separate cell view now, not one `HStack` spanning the row)

### Header bar

- Shows archive name, file count, uncompressed total, zip size on disk
- Filter `TextField` (width 180) for search; ⌘F focuses it via a hidden `Button` with `.keyboardShortcut("f", modifiers: .command)` bound to a `@FocusState` (`filterFieldFocused`) — SwiftUI key-equivalent buttons fire regardless of current first responder, so this works even when the tree `List` has focus
- **Extract Selected/File/Folder/N Items** — appears when the selection is non-empty; label from `extractLabel(for:)` based on selection count/kind; triggers `NSOpenPanel` + extraction via `exportSelection()`
- **Extract All** — always visible; extracts entire archive to a chosen folder
- Spinner replaces extract buttons during in-progress extraction
- **×** button (plain `xmark.circle.fill`) calls `closeArchive()` — cancels `loadTask` and `previewTask`, dismisses Quick Look, deletes session temp dir. Same method backs the File > Close Archive menu command. Has an explicit `.accessibilityLabel("Close")` since its only other hint is a `.help()` tooltip

### Export

- `NSOpenPanel` (folder picker) opened on the main thread via `@MainActor pickDestination(title:)`
- Extraction runs in `Task.detached` via `ArchiveReader.extract`
- Errors shown in an `.alert("Export Failed")`
- `exportNode(_:)` extracts a single file/folder; `exportNodes(_:)` extracts a multi-item selection as one `ArchiveReader.extract` call (one export, one progress bar) into a chosen destination folder, preserving each item's relative path; `exportSelection()` calls `exportNodes(selectedNodes)`. `collectPaths(for:)` resolves a node (file or directory) to its full list of archive paths and is shared by both export paths and `extractedURL(for:)`

### Quick Look

- Selecting a non-directory file silently extracts it to a per-node subdirectory inside the session temp dir (`FileManager.default.temporaryDirectory/Peep-<uuid>/<node.id-with-slashes-replaced>/filename`) in the background; the extraction task is stored in `previewTask` and cancelled if the selection changes before it finishes
- Already-extracted files are reused (cached by path existence check)
- Space bar calls `toggleQuickLook()`: sets `QLPreviewPanel.dataSource` and calls `makeKeyAndOrderFront` — or `orderOut` if already visible
- `QuickLookCoordinator: NSObject, ObservableObject, QLPreviewPanelDataSource` — held as `@StateObject`; exposes a single `url: URL?`
- Session temp dir is deleted when the archive is closed; `loadTask` and `previewTask` are both cancelled on close

### Settings

Settings scene (macOS `Settings { }`) with three tabs, window size 460×300:

- **General** (`GeneralSettingsView`) — toggle "Open in Finder after extraction"; persisted via `@AppStorage("openInFinderAfterExtract")`
- **Appearance** (`AppearanceSettingsView`) — `Picker` for System / Light / Dark; persisted via `@AppStorage("appTheme")`
- **About** (`AboutSettingsView`) — app version, open-source component credits (ZIPFoundation, SWCompression, MimeParser)

## Xcode project notes

- `project.pbxproj` was hand-authored with fixed UUIDs (24-char hex)
- `GENERATE_INFOPLIST_FILE = NO` — manual `Peep/Info.plist` used instead (test target uses `YES`)
- `ENABLE_HARDENED_RUNTIME = YES`, no entitlements file → app is **not sandboxed**
- Bundle ID: `com.peep.Peep` (app), `com.peep.PeepTests` (test bundle)
- No code signing identity set (Automatic) — works for local development
- SWCompression added as `XCRemoteSwiftPackageReference` in pbxproj (UUID prefix `AA00…AA0x`), `>= 4.8.0`
- ZIPFoundation added as `XCRemoteSwiftPackageReference` in pbxproj (UUID prefix `BB00…BB0x`), `>= 0.9.0`
- MimeParser added as `XCRemoteSwiftPackageReference` in pbxproj (UUID prefix `CC00…CC0x`), branch `master`
- `PeepTests` target (UUID prefix `FF…`) depends on `Peep` via `TEST_HOST`/`BUNDLE_LOADER`; all three packages are also linked to the test target (UUID prefix `FF30…`)
- **Known xcodebuild CLI issue**: transitive SPM dependency `BitByteData` (required by SWCompression) fails to resolve when building from the command line; use Xcode GUI (⌘U) to run tests

## Supported formats

| Format | Status | Backend |
|--------|--------|---------|
| `.zip` | Supported | ZIPFoundation (`Archive`) |
| `.tar`, `.tar.gz`, `.tgz`, `.tar.bz2`, `.tbz`, `.tbz2` | Supported | SWCompression (`TarContainer` + `GzipArchive` / `BZip2`) |
| `.7z` | Supported | SWCompression (`SevenZipContainer`) |
| `.eml` | Supported | MimeParser + Swift; produces `message.html` preview |
| `.msg` | Supported | Pure Swift OLE2/CFB parser (`cfbMsgParts`) |
| `.tnef` / `winmail.dat` | Supported | Pure Swift TNEF parser |

## Known issues

- After first install, Finder may need a relaunch or `lsregister -f Peep.app` before "Open With" appears
- **`actool` produces no compiled output in this sandboxed CLI environment** — verified even for a minimal catalog containing only `AccentColor`; `actool --compile ...` and the full `xcodebuild` pipeline both exit 0 but emit no `.car`/no compiled assets at all. Because of this, the app icon is delivered as a loose `Peep/AppIcon.icns` file via `CFBundleIconFile`/a plain Resources-copy build step (not `ASSETCATALOG_COMPILER_APPICON_NAME`) — that path doesn't depend on `actool` and is verified working. A modern Icon Composer `.icon` bundle (macOS 26 adaptive/Liquid Glass icon) was tried first via the asset catalog but hit this same `actool` limitation; it may well work fine from the real Xcode GUI (which runs a full IDE build session), so it's worth re-trying there if the adaptive icon rendering is wanted — this repo just can't verify it from the CLI
- SWCompression (TAR, 7z) loads the entire archive into memory; very large tar/7z archives may cause high memory usage
- `xcodebuild test` fails from the command line due to a transitive SPM dependency resolution issue (`BitByteData`); run tests from Xcode GUI instead
