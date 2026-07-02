import SwiftUI
import QuickLook
import QuickLookUI
import UniformTypeIdentifiers

final class QuickLookCoordinator: NSObject, ObservableObject, QLPreviewPanelDataSource {
    var url: URL?
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { url as NSURL? }
}

private struct FlatRow: Identifiable {
    let node: TreeNode
    let depth: Int
    var id: String { node.id }
    var name: String { node.name }
    var sortableSize: Int64 { node.isDirectory ? -1 : (node.entry?.uncompressedSize ?? -1) }
    var sortableDate: String { node.entry?.date ?? "" }
    var sortableKind: String { node.isDirectory ? "Folder" : kind(for: node.name) }
}

struct ContentView: View {
    @State private var archiveInfo: ArchiveInfo?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isTargeted = false
    @State private var searchText = ""
    @State private var archiveSourceURL: URL?
    @State private var selectedNodeIDs: Set<String> = []
    @State private var exportProgress: Double?
    @State private var exportTask: Task<Void, Never>?
    @State private var exportError: String?
    @State private var loadTask: Task<Void, Never>?
    @State private var previewTask: Task<Void, Never>?
    @AppStorage("openInFinderAfterExtract") private var openInFinderAfterExtract = false
    @State private var cachedPreviewURL: URL?
    @State private var sessionTempDir: URL?
    @StateObject private var qlCoordinator = QuickLookCoordinator()
    @FocusState private var filterFieldFocused: Bool
    @State private var expandedNodeIDs: Set<String> = []
    @State private var sortOrder: [KeyPathComparator<FlatRow>] = [KeyPathComparator(\FlatRow.name)]

    var treeNodes: [TreeNode] {
        buildTree(from: archiveInfo?.entries ?? [])
    }

    // MARK: - Sorting and flattening for the Table

    private func treeComparator() -> (TreeNode, TreeNode) -> Bool {
        guard let comparator = sortOrder.first else {
            return { $0.name.localizedCompare($1.name) == .orderedAscending }
        }
        let ascending = comparator.order == .forward
        switch comparator.keyPath {
        case \FlatRow.sortableSize:
            return { a, b in
                let sa = a.isDirectory ? Int64(-1) : (a.entry?.uncompressedSize ?? -1)
                let sb = b.isDirectory ? Int64(-1) : (b.entry?.uncompressedSize ?? -1)
                return ascending ? sa < sb : sa > sb
            }
        case \FlatRow.sortableDate:
            return { a, b in
                let da = a.entry?.date ?? ""
                let db = b.entry?.date ?? ""
                return ascending ? da < db : da > db
            }
        case \FlatRow.sortableKind:
            return { a, b in
                let ka = a.isDirectory ? "Folder" : kind(for: a.name)
                let kb = b.isDirectory ? "Folder" : kind(for: b.name)
                return ascending ? ka < kb : ka > kb
            }
        default:
            return { a, b in
                ascending
                    ? a.name.localizedCompare(b.name) == .orderedAscending
                    : a.name.localizedCompare(b.name) == .orderedDescending
            }
        }
    }

    private func sortedChildren(_ nodes: [TreeNode]) -> [TreeNode] {
        let cmp = treeComparator()
        return nodes.filter(\.isDirectory).sorted(by: cmp) + nodes.filter { !$0.isDirectory }.sorted(by: cmp)
    }

    private func sortedTree(_ nodes: [TreeNode]) -> [TreeNode] {
        sortedChildren(nodes).map { node in
            var copy = node
            copy.children = node.children.map(sortedTree)
            return copy
        }
    }

    private var sortedTreeNodes: [TreeNode] { sortedTree(treeNodes) }

    private func flatten(_ nodes: [TreeNode], depth: Int = 0) -> [FlatRow] {
        nodes.flatMap { node in
            [FlatRow(node: node, depth: depth)] +
            (node.isDirectory && expandedNodeIDs.contains(node.id) ? flatten(node.children ?? [], depth: depth + 1) : [])
        }
    }

    private var visibleRows: [FlatRow] { flatten(sortedTreeNodes) }

    private var searchRows: [FlatRow] {
        filteredEntries.map { e in
            // children: [] (not nil) for directory entries so TreeNode.isDirectory (children != nil)
            // reports true — otherwise drag-out/extraction treats every search result as a file.
            FlatRow(node: TreeNode(name: e.path, fullPath: e.path, entry: e, children: e.isDirectory ? [] : nil), depth: 0)
        }
    }

    var selectedNode: TreeNode? {
        guard selectedNodeIDs.count == 1, let id = selectedNodeIDs.first else { return nil }
        return findNode(id, in: treeNodes)
    }

    var selectedNodes: [TreeNode] {
        selectedNodeIDs.compactMap { findNode($0, in: treeNodes) }
    }

    private func findNode(_ id: String, in nodes: [TreeNode]) -> TreeNode? {
        for n in nodes {
            if n.id == id { return n }
            if let c = n.children, let found = findNode(id, in: c) { return found }
        }
        return nil
    }

    private func collectPaths(for node: TreeNode) -> [String] {
        guard let info = archiveInfo else { return [] }
        return node.isDirectory
            ? info.entries.map(\.path).filter { $0.hasPrefix(node.fullPath) }
            : [node.fullPath]
    }

    private var extractSelectionLabel: String { extractLabel(for: selectedNodes) }

    private func extractLabel(for nodes: [TreeNode]) -> String {
        if nodes.count == 1 {
            return nodes[0].isDirectory ? "Extract Folder" : "Extract File"
        }
        return "Extract \(nodes.count) Items"
    }

    @MainActor
    private func closeArchive() {
        loadTask?.cancel()
        previewTask?.cancel()
        QLPreviewPanel.shared()?.orderOut(nil)
        cachedPreviewURL = nil
        qlCoordinator.url = nil
        if let tmp = sessionTempDir { try? FileManager.default.removeItem(at: tmp) }
        sessionTempDir = nil
        archiveInfo = nil
        archiveSourceURL = nil
        selectedNodeIDs = []
        searchText = ""
        errorMessage = nil
    }

    var filteredEntries: [FileEntry] {
        (archiveInfo?.entries ?? [])
            .filter { $0.path.localizedCaseInsensitiveContains(searchText) }
            .sorted { $0.path.localizedCompare($1.path) == .orderedAscending }
    }

    var body: some View {
        ZStack {
            if isLoading {
                loadingView
            } else if let info = archiveInfo {
                archiveView(info: info)
                    .overlay(dropHintOverlay)
            } else {
                dropZoneView
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .blur(radius: exportProgress != nil ? 4 : 0)
        .overlay { if exportProgress != nil { exportProgressOverlay } }
        .animation(.easeInOut(duration: 0.2), value: exportProgress != nil)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: $isTargeted, perform: load)
        .onReceive(NotificationCenter.default.publisher(for: .openArchive)) { note in
            guard let url = note.object as? URL else { return }
            loadURL(url)
        }
        .focusedSceneValue(\.archiveActions, ArchiveActions(
            openPanel: { pickArchiveToOpen() },
            extractSelection: { exportSelection() },
            extractAll: { if let info = archiveInfo { exportAll(info: info) } },
            closeArchive: { closeArchive() }
        ))
        .focusedSceneValue(\.archiveWindowState, ArchiveWindowState(
            hasArchive: archiveInfo != nil,
            selectionCount: selectedNodeIDs.count,
            selectionIsDirectory: selectedNodeIDs.count == 1 ? selectedNode?.isDirectory : nil
        ))
        .alert("Export Failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    // MARK: - Drop zone

    private var dropZoneView: some View {
        VStack(spacing: 14) {
            Image(systemName: "archivebox")
                .font(.system(size: 72, weight: .ultraLight))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
                .animation(.easeInOut(duration: 0.15), value: isTargeted)

            Text("Drop a file here")
                .font(.title2)
                .fontWeight(.medium)

            Text(".zip  ·  .tar  ·  .tar.gz  ·  .tar.bz2  ·  .7z  ·  .msg  ·  .eml  ·  winmail.dat")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let err = errorMessage {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .gesture(WindowDragGesture())
        .background(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
                    style: StrokeStyle(lineWidth: 2, dash: [10, 6])
                )
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(isTargeted ? Color.accentColor.opacity(0.06) : Color.clear)
                )
                .animation(.easeInOut(duration: 0.15), value: isTargeted)
        )
        .padding(24)
    }

    // Subtle highlight when dragging a file over the archive view
    @ViewBuilder
    private var dropHintOverlay: some View {
        if isTargeted {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.06)))
                .overlay(
                    Text("Drop to open")
                        .font(.title3).fontWeight(.medium)
                        .foregroundStyle(Color.accentColor)
                )
                .padding(8)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.15), value: isTargeted)
        }
    }

    // MARK: - Export progress overlay

    @ViewBuilder
    private var exportProgressOverlay: some View {
        ZStack {
            Color.black.opacity(0.25)
            VStack(spacing: 16) {
                Text("Extracting…")
                    .font(.headline)
                ProgressView(value: exportProgress ?? 0, total: 1.0)
                    .progressViewStyle(.linear)
                    .frame(width: 240)
                Text("\(Int((exportProgress ?? 0) * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Cancel") { exportTask?.cancel() }
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(radius: 24, y: 6)
        }
        .ignoresSafeArea()
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView().scaleEffect(1.2)
            Text("Reading archive…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .gesture(WindowDragGesture())
    }

    // MARK: - Archive view

    @ViewBuilder
    private func archiveView(info: ArchiveInfo) -> some View {
        VStack(spacing: 0) {
            headerBar(info: info)
            Divider()
            fileTable
        }
        .onChange(of: selectedNodeIDs) { _, _ in preparePreview() }
    }

    private func headerBar(info: ArchiveInfo) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "archivebox.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(info.fileName)
                    .font(.headline)
                    .lineLimit(1)

                let fileCount = info.entries.filter { !$0.isDirectory }.count
                let totalUncompressed = info.entries.reduce(0) { $0 + $1.uncompressedSize }
                Text("\(fileCount) file\(fileCount == 1 ? "" : "s") · "
                     + "\(format(totalUncompressed)) uncompressed · "
                     + "\(format(info.fileSize)) on disk")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            TextField("Filter", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .focused($filterFieldFocused)

            Button("") { filterFieldFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()

            if !selectedNodeIDs.isEmpty {
                Button(extractSelectionLabel) {
                    exportSelection()
                }
                .buttonStyle(.bordered)
            }

                Button("Extract All") {
                    exportAll(info: info)
                }
                .buttonStyle(.bordered)

            Button {
                closeArchive()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close")
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .gesture(WindowDragGesture())
    }

    @ViewBuilder
    private var fileTable: some View {
        Table(selection: $selectedNodeIDs, sortOrder: $sortOrder) {
            TableColumn("Name", value: \FlatRow.name) { row in nameCell(for: row) }
                .width(min: 120, ideal: 300)
            TableColumn("Size", value: \FlatRow.sortableSize) { row in sizeCell(for: row) }
                .width(min: 50, ideal: 70)
            TableColumn("Date Modified", value: \FlatRow.sortableDate) { row in dateCell(for: row) }
                .width(min: 80, ideal: 110)
            TableColumn("Kind", value: \FlatRow.sortableKind) { row in kindCell(for: row) }
                .width(min: 60, ideal: 90)
        } rows: {
            ForEach(searchText.isEmpty ? visibleRows : searchRows) { row in
                TableRow(row)
                    .itemProvider {
                        selectedNodeIDs.contains(row.node.id) ? draggingItemProvider(for: row.node) : nil
                    }
            }
        }
        .font(.system(size: 13))
        .contextMenu(forSelectionType: String.self) { ids in
            contextMenuContent(for: ids)
        }
        .onKeyPress(phases: .down) { press in
            if press.key == .return, let node = selectedNode, node.isDirectory {
                toggleExpanded(node)
                return .handled
            }
            if press.key == .space || press.key == .return { toggleQuickLook(); return .handled }
            if press.characters == "c", press.modifiers.contains(.command) {
                copyToPasteboard(selectedNodes)
                return .handled
            }
            return .ignored
        }
    }

    // MARK: - Manually-tracked outline expansion (so Return can drive it, not just a disclosure triangle click)

    private func toggleExpanded(_ node: TreeNode) {
        if expandedNodeIDs.contains(node.id) {
            expandedNodeIDs.remove(node.id)
        } else {
            expandedNodeIDs.insert(node.id)
        }
    }

    // MARK: - Table cells

    private func nameCell(for row: FlatRow) -> some View {
        HStack(spacing: 6) {
            Spacer().frame(width: CGFloat(row.depth) * 16)
            if row.node.isDirectory {
                Button {
                    toggleExpanded(row.node)
                } label: {
                    Image(systemName: expandedNodeIDs.contains(row.node.id) ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 12)
            } else {
                Spacer().frame(width: 12)
            }
            Image(systemName: row.node.isDirectory ? "folder.fill" : icon(for: row.node.name))
                .foregroundStyle(row.node.isDirectory ? Color.yellow : Color.secondary)
                .frame(width: 16)
            Text(row.node.name)
                .lineLimit(1)
        }
        .help(row.node.fullPath)
    }

    private func sizeCell(for row: FlatRow) -> some View {
        Group {
            if let e = row.node.entry, !row.node.isDirectory {
                Text(format(e.uncompressedSize))
            } else {
                Text("--")
            }
        }
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .lineLimit(1)
    }

    private func dateCell(for row: FlatRow) -> some View {
        Text(row.node.entry?.date ?? "--")
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
    }

    private func kindCell(for row: FlatRow) -> some View {
        Text(row.node.isDirectory ? "Folder" : kind(for: row.node.name))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    @ViewBuilder
    private func contextMenuContent(for ids: Set<String>) -> some View {
        let nodes = ids.compactMap { findNode($0, in: treeNodes) }
        if !nodes.isEmpty {
            Button {
                exportNodes(nodes)
            } label: {
                Label(extractLabel(for: nodes) + "…",
                      systemImage: nodes.count == 1 && !nodes[0].isDirectory ? "doc" : "folder")
            }
            Button {
                copyToPasteboard(nodes)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
    }

    // MARK: - Drop handler

    @MainActor
    private func loadURL(_ url: URL) {
        loadTask?.cancel()
        loadTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            if let old = sessionTempDir {
                try? FileManager.default.removeItem(at: old)
                sessionTempDir = nil
            }
            isLoading = true
            errorMessage = nil
            archiveInfo = nil
            selectedNodeIDs = []
            do {
                let info = try await ArchiveReader.read(url: url)
                // ArchiveReader.read runs in a detached Task with no cancellation checks of its
                // own, so a slower, since-cancelled load can still resolve here after a newer
                // load has already started — re-check before touching any state, or this load
                // would clobber the newer one's archiveInfo/sessionTempDir with stale data.
                guard !Task.isCancelled else { return }
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Peep-\(UUID().uuidString)")
                try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                archiveInfo = info
                archiveSourceURL = url
                sessionTempDir = tmp
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
                let ext = url.pathExtension.lowercased()
                if ext == "eml" || ext == "msg" { selectedNodeIDs = ["message.html"] }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    @discardableResult
    private func load(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first,
              provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return false }

        provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
            guard let data else {
                Task { @MainActor in
                    self.errorMessage = error?.localizedDescription ?? "Could not read the dropped item."
                }
                return
            }
            guard let url = URL(dataRepresentation: data, relativeTo: nil) else {
                Task { @MainActor in self.errorMessage = "Could not parse the file URL." }
                return
            }
            Task { @MainActor in self.loadURL(url) }
        }
        return true
    }

    // MARK: - On-demand extraction (Quick Look, drag-out, copy)

    /// Extracts `node` into a per-node subdirectory of the session temp dir, reusing
    /// a prior extraction if one already exists at that path.
    private func nodeTempDir(for node: TreeNode) -> URL? {
        guard let tmp = sessionTempDir else { return nil }
        return tmp.appendingPathComponent(node.id.replacingOccurrences(of: "/", with: "_"))
    }

    private func expectedExtractionPath(for node: TreeNode) -> URL? {
        guard let nodeDir = nodeTempDir(for: node) else { return nil }
        if node.isDirectory {
            let prefix = node.fullPath
            let strippedPath = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
            return nodeDir.appendingPathComponent(strippedPath)
        } else {
            return nodeDir.appendingPathComponent(node.name)
        }
    }

    private func cachedExtractedURL(for node: TreeNode) -> URL? {
        guard let dest = expectedExtractionPath(for: node), FileManager.default.fileExists(atPath: dest.path) else {
            return nil
        }
        return dest
    }

    private func extractedURL(for node: TreeNode) async throws -> URL {
        guard let src = archiveSourceURL,
              let nodeDir = nodeTempDir(for: node),
              let dest = expectedExtractionPath(for: node) else {
            throw ArchiveError.readFailed("No archive open")
        }
        if FileManager.default.fileExists(atPath: dest.path) {
            return dest
        }
        // Extract into nodeDir itself (not a directory derived from `dest`, which for
        // multi-segment archive paths like "usr/local/outset" is several levels deeper
        // than the last-path-component strip previously assumed) so non-junked directory
        // extraction lands entries at nodeDir/<archive-relative-path>, matching `dest`.
        try FileManager.default.createDirectory(at: nodeDir, withIntermediateDirectories: true)
        try await ArchiveReader.extract(from: src, paths: collectPaths(for: node), junkPaths: !node.isDirectory, to: nodeDir)
        guard FileManager.default.fileExists(atPath: dest.path) else {
            throw ArchiveError.readFailed("Extraction produced no output")
        }
        return dest
    }

    private func draggingItemProvider(for node: TreeNode) -> NSItemProvider {
        // Prefer an already-extracted file: a plain, already-resolved NSItemProvider
        // avoids the OS's drag "promise" bookkeeping entirely (registerFileRepresentation's
        // lazy loadHandler was found to leave app quit blocked in CFPasteboardResolveAllPromisedData
        // even after the completion handler fired).
        if let cached = cachedExtractedURL(for: node), let provider = NSItemProvider(contentsOf: cached) {
            provider.suggestedName = node.name
            return provider
        }

        let provider = NSItemProvider()
        provider.suggestedName = node.name
        let contentType: UTType = node.isDirectory
            ? .folder
            : (UTType(filenameExtension: (node.name as NSString).pathExtension) ?? .data)
        provider.registerFileRepresentation(forTypeIdentifier: contentType.identifier, visibility: .all) { completion in
            let progress = Progress(totalUnitCount: 1)
            Task {
                do {
                    let url = try await extractedURL(for: node)
                    completion(url, false, nil)
                } catch {
                    completion(nil, false, error)
                }
                progress.completedUnitCount = 1
            }
            return progress
        }
        return provider
    }

    private func copyToPasteboard(_ nodes: [TreeNode]) {
        guard !nodes.isEmpty else { return }
        Task {
            var urls: [URL] = []
            for node in nodes {
                if let url = try? await extractedURL(for: node) {
                    urls.append(url)
                }
            }
            guard !urls.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(urls as [NSURL])
        }
    }

    // MARK: - Quick Look

    private func preparePreview() {
        previewTask?.cancel()
        cachedPreviewURL = nil
        guard let node = selectedNode, !node.isDirectory else { return }
        previewTask = Task {
            do {
                let url = try await extractedURL(for: node)
                cachedPreviewURL = url
            } catch is CancellationError {
                // selection changed before extraction finished — discard result
            } catch {
                // extraction failed silently; space bar will simply do nothing
            }
        }
    }

    private func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            guard let url = cachedPreviewURL else { return }
            qlCoordinator.url = url
            panel.dataSource = qlCoordinator
            panel.reloadData()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Export

    private func exportAll(info: ArchiveInfo) {
        guard let src = archiveSourceURL,
              let dest = pickDestination(title: "Extract Archive To") else { return }
        runExport(revealURL: dest, openFolder: true) { progress in
            try await ArchiveReader.extract(from: src, to: dest, progress: progress)
        }
    }

    private func exportSelection() {
        exportNodes(selectedNodes)
    }

    private func exportNodes(_ nodes: [TreeNode]) {
        guard nodes.count > 1 else {
            if let single = nodes.first { exportNode(single) }
            return
        }
        guard let src = archiveSourceURL,
              let dest = pickDestination(title: "Extract \(nodes.count) Items To") else { return }
        let paths = nodes.flatMap(collectPaths(for:))
        runExport(revealURL: dest, openFolder: true) { progress in
            try await ArchiveReader.extract(from: src, paths: paths, to: dest, progress: progress)
        }
    }

    private func exportNode(_ node: TreeNode) {
        guard let src = archiveSourceURL,
              let dest = pickDestination(title: node.isDirectory ? "Extract Folder To" : "Extract File To") else { return }

        if node.isDirectory {
            let prefix = node.fullPath
            let paths = collectPaths(for: node)
            let strippedPath = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
            let extractedFolder = dest.appendingPathComponent(strippedPath)
            runExport(revealURL: extractedFolder) { progress in
                try await ArchiveReader.extract(from: src, paths: paths, to: dest, progress: progress)
            }
        } else {
            let fileURL = dest.appendingPathComponent(node.name)
            runExport(revealURL: fileURL) { progress in
                try await ArchiveReader.extract(from: src, paths: [node.fullPath], junkPaths: true, to: dest, progress: progress)
            }
        }
    }

    private func runExport(revealURL: URL, openFolder: Bool = false, _ work: @escaping (@escaping (Double) -> Void) async throws -> Void) {
        exportProgress = 0
        exportTask = Task {
            defer { Task { @MainActor in exportProgress = nil; exportTask = nil } }
            let progressFn: (Double) -> Void = { value in
                Task { @MainActor in self.exportProgress = value }
            }
            do {
                try await work(progressFn)
                if openInFinderAfterExtract {
                    await MainActor.run {
                        if openFolder {
                            NSWorkspace.shared.open(revealURL)
                        } else {
                            NSWorkspace.shared.activateFileViewerSelecting([revealURL])
                        }
                    }
                }
            } catch is CancellationError {
                // user cancelled — no error shown
            } catch {
                await MainActor.run { exportError = error.localizedDescription }
            }
        }
    }

    @MainActor
    private func pickDestination(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Extract Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private static let openableExtensions = ["zip", "tar", "tgz", "tbz", "tbz2", "gz", "bz2", "7z", "tnef", "eml", "msg", "dat"]

    @MainActor
    private func pickArchiveToOpen() {
        let panel = NSOpenPanel()
        panel.title = "Open Archive"
        panel.prompt = "Open"
        panel.allowedContentTypes = Self.openableExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadURL(url)
    }

    // MARK: - Helpers

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

}
