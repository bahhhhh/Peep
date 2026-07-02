import Foundation

struct FileEntry: Identifiable {
    let id = UUID()
    let path: String
    let uncompressedSize: Int64
    let compressedSize: Int64
    let date: String
    let isDirectory: Bool

    var compressionRatio: Double {
        guard uncompressedSize > 0, !isDirectory else { return 0 }
        return 1.0 - Double(compressedSize) / Double(uncompressedSize)
    }
}

struct ArchiveInfo {
    let entries: [FileEntry]
    let fileName: String
    let fileSize: Int64
}

struct TreeNode: Identifiable {
    let name: String
    let fullPath: String    // full path inside the archive, e.g. "usr/local/outset/"
    let entry: FileEntry?
    var children: [TreeNode]?

    var id: String { fullPath }
    var isDirectory: Bool { children != nil }
}

func buildTree(from entries: [FileEntry]) -> [TreeNode] {
    class N {
        let name: String
        var entry: FileEntry?
        var isExplicitDir = false
        var kids: [String: N] = [:]
        init(_ n: String) { name = n }
        var effectiveIsDir: Bool { isExplicitDir || !kids.isEmpty }
    }

    let root = N("")
    for e in entries {
        let parts = e.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { continue }
        var cur = root
        for (i, part) in parts.enumerated() {
            if cur.kids[part] == nil { cur.kids[part] = N(part) }
            let child = cur.kids[part]!
            if i == parts.count - 1 { child.entry = e; if e.isDirectory { child.isExplicitDir = true } }
            cur = child
        }
    }

    func order(_ kids: Dictionary<String, N>.Values) -> [N] {
        kids.sorted {
            if $0.effectiveIsDir != $1.effectiveIsDir { return $0.effectiveIsDir }
            return $0.name.localizedCompare($1.name) == .orderedAscending
        }
    }

    func convert(_ n: N, parentPath: String) -> TreeNode {
        let myPath = parentPath.isEmpty ? n.name : "\(parentPath)/\(n.name)"
        let fullPath = n.effectiveIsDir ? "\(myPath)/" : myPath
        return TreeNode(
            name: n.name,
            fullPath: fullPath,
            entry: n.entry,
            children: n.effectiveIsDir
                ? order(n.kids.values).map { convert($0, parentPath: myPath) }
                : nil
        )
    }

    return order(root.kids.values).map { convert($0, parentPath: "") }
}

func kind(for path: String) -> String {
    switch (path as NSString).pathExtension.lowercased() {
    case "sh", "bash", "zsh", "command": return "Shell script"
    case "app": return "Application"
    case "png", "jpg", "jpeg", "gif", "webp", "heic": return "Image"
    case "svg": return "SVG image"
    case "pdf": return "PDF document"
    case "zip", "tar", "gz", "7z", "bz2", "eml", "msg": return "Archive"
    case "mp4", "mov", "avi", "mkv": return "Video"
    case "mp3", "m4a", "wav", "aiff", "flac": return "Audio"
    case "swift": return "Swift source"
    case "py": return "Python script"
    case "js", "ts": return "Script"
    case "json": return "JSON"
    case "xml", "plist": return "XML"
    case "txt", "md": return "Plain text"
    case "": return "File"
    default:
        let ext = (path as NSString).pathExtension
        return ext.isEmpty ? "File" : "\(ext.uppercased()) file"
    }
}

func icon(for path: String) -> String {
    switch (path as NSString).pathExtension.lowercased() {
    case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg": return "photo"
    case "pdf": return "doc.richtext"
    case "zip", "tar", "gz", "7z", "bz2", "eml", "msg": return "archivebox"
    case "mp4", "mov", "avi", "mkv": return "video"
    case "mp3", "m4a", "wav", "aiff", "flac": return "music.note"
    case "swift", "py", "js", "ts", "rb", "go", "rs", "c", "cpp", "h": return "doc.text"
    case "json", "yaml", "yml", "toml", "xml", "plist": return "doc.badge.ellipsis"
    default: return "doc"
    }
}
