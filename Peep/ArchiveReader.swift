import Foundation
import MimeParser
import SWCompression
import ZIPFoundation

enum ArchiveError: LocalizedError {
    case unsupportedFormat(String)
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            return ".\(ext) is not supported. Drop a .zip, .tar, .tar.gz, .tar.bz2, .7z, .msg, .eml, or winmail.dat file."
        case .readFailed(let msg):
            return "Could not read archive: \(msg)"
        }
    }
}

private enum ArchiveFormat {
    case zip, tar, tarGz, tarBz2, sevenZip, tnef, eml, msg

    static func detect(url: URL) -> ArchiveFormat? {
        let name = url.lastPathComponent.lowercased()
        let ext  = url.pathExtension.lowercased()
        switch ext {
        case "zip":          return .zip
        case "tar":          return .tar
        case "tgz":          return .tarGz
        case "tbz", "tbz2": return .tarBz2
        case "7z":           return .sevenZip
        case "tnef":         return .tnef
        case "eml":          return .eml
        case "msg":          return .msg
        case "gz":           return name.hasSuffix(".tar.gz")  ? .tarGz  : nil
        case "bz2":          return name.hasSuffix(".tar.bz2") ? .tarBz2 : nil
        default:             return name == "winmail.dat" ? .tnef : nil
        }
    }
}

enum ArchiveReader {

    static func read(url: URL) async throws -> ArchiveInfo {
        guard let format = ArchiveFormat.detect(url: url) else {
            throw ArchiveError.unsupportedFormat(url.pathExtension)
        }
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .flatMap { Int64($0) } ?? 0
        return try await Task.detached(priority: .userInitiated) {
            switch format {
            case .zip:      return try Self.readZipSync(url: url, fileSize: fileSize)
            case .tar:      return try Self.readTarSync(url: url, fileSize: fileSize)
            case .tarGz:    return try Self.readTarGzSync(url: url, fileSize: fileSize)
            case .tarBz2:   return try Self.readTarBz2Sync(url: url, fileSize: fileSize)
            case .sevenZip: return try Self.readSevenZipSync(url: url, fileSize: fileSize)
            case .tnef:     return try Self.readTnefSync(url: url, fileSize: fileSize)
            case .eml:      return try Self.readEmlSync(url: url, fileSize: fileSize)
            case .msg:      return try Self.readMsgSync(url: url, fileSize: fileSize)
            }
        }.value
    }

    static func extract(from archiveURL: URL, paths: [String] = [], junkPaths: Bool = false, to destination: URL, progress: ((Double) -> Void)? = nil) async throws {
        let format = ArchiveFormat.detect(url: archiveURL) ?? .zip
        try await Task.detached(priority: .userInitiated) {
            switch format {
            case .zip:      try await Self.extractZipSync(from: archiveURL, paths: paths, junkPaths: junkPaths, to: destination, progress: progress)
            case .tar:      try await Self.extractTarSync(from: archiveURL, paths: paths, junkPaths: junkPaths, to: destination, progress: progress)
            case .tarGz:    try await Self.extractTarGzSync(from: archiveURL, paths: paths, junkPaths: junkPaths, to: destination, progress: progress)
            case .tarBz2:   try await Self.extractTarBz2Sync(from: archiveURL, paths: paths, junkPaths: junkPaths, to: destination, progress: progress)
            case .sevenZip: try await Self.extractSevenZipSync(from: archiveURL, paths: paths, junkPaths: junkPaths, to: destination, progress: progress)
            case .tnef:     try Self.extractTnefSync(from: archiveURL, paths: paths, to: destination, progress: progress)
            case .eml:      try Self.extractEmlSync(from: archiveURL, paths: paths, to: destination, progress: progress)
            case .msg:      try Self.extractMsgSync(from: archiveURL, paths: paths, to: destination, progress: progress)
            }
        }.value
    }

    // MARK: – ZIP (SWCompression)

    private static func readZipSync(url: URL, fileSize: Int64) throws -> ArchiveInfo {
        let archive: ZIPFoundation.Archive
        do { archive = try ZIPFoundation.Archive(url: url, accessMode: .read) }
        catch { throw ArchiveError.readFailed(error.localizedDescription) }

        let fmt = isoFormatter()
        let entries: [FileEntry] = archive.compactMap { entry -> FileEntry? in
            guard entry.type != .symlink else { return nil }
            let isDir = entry.type == .directory
            let modDate = entry.fileAttributes[.modificationDate] as? Date
            return FileEntry(
                path: entry.path,
                uncompressedSize: Int64(entry.uncompressedSize),
                compressedSize: Int64(entry.compressedSize),
                date: modDate.map { fmt.string(from: $0) } ?? "",
                isDirectory: isDir
            )
        }
        return ArchiveInfo(entries: entries, fileName: url.lastPathComponent, fileSize: fileSize)
    }

    private static func extractZipSync(from archiveURL: URL, paths: [String], junkPaths: Bool, to destination: URL, progress: ((Double) -> Void)?) async throws {
        let archive: ZIPFoundation.Archive
        do { archive = try ZIPFoundation.Archive(url: archiveURL, accessMode: .read) }
        catch { throw ArchiveError.readFailed(error.localizedDescription) }

        let pathSet = Set(paths)
        let toWrite = archive.filter { $0.type != .symlink && (pathSet.isEmpty || pathSet.contains($0.path)) }
        let total = max(toWrite.count, 1)
        let fm = FileManager.default

        for (i, entry) in toWrite.enumerated() {
            try Task.checkCancellation()
            let destName = junkPaths ? (entry.path as NSString).lastPathComponent : entry.path
            guard let destURL = safeDestURL(base: destination, relativePath: destName) else { continue }
            if entry.type == .directory {
                try fm.createDirectory(at: destURL, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                _ = try archive.extract(entry, to: destURL)
            }
            progress?(Double(i + 1) / Double(total))
        }
    }

    // MARK: – Plain TAR (SWCompression)

    private static func readTarSync(url: URL, fileSize: Int64) throws -> ArchiveInfo {
        try tarInfoToArchiveInfo(data: loadData(from: url), fileName: url.lastPathComponent, fileSize: fileSize)
    }

    private static func extractTarSync(from archiveURL: URL, paths: [String], junkPaths: Bool, to destination: URL, progress: ((Double) -> Void)?) async throws {
        try await extractTarData(loadData(from: archiveURL), paths: paths, junkPaths: junkPaths, to: destination, progress: progress)
    }

    // MARK: – TAR.GZ (SWCompression)

    private static func readTarGzSync(url: URL, fileSize: Int64) throws -> ArchiveInfo {
        let tar = try decompress(loadData(from: url), using: GzipArchive.unarchive)
        return try tarInfoToArchiveInfo(data: tar, fileName: url.lastPathComponent, fileSize: fileSize)
    }

    private static func extractTarGzSync(from archiveURL: URL, paths: [String], junkPaths: Bool, to destination: URL, progress: ((Double) -> Void)?) async throws {
        let tar = try decompress(loadData(from: archiveURL), using: GzipArchive.unarchive)
        try await extractTarData(tar, paths: paths, junkPaths: junkPaths, to: destination, progress: progress)
    }

    // MARK: – TAR.BZ2 (SWCompression)

    private static func readTarBz2Sync(url: URL, fileSize: Int64) throws -> ArchiveInfo {
        let tar = try decompress(loadData(from: url), using: BZip2.decompress)
        return try tarInfoToArchiveInfo(data: tar, fileName: url.lastPathComponent, fileSize: fileSize)
    }

    private static func extractTarBz2Sync(from archiveURL: URL, paths: [String], junkPaths: Bool, to destination: URL, progress: ((Double) -> Void)?) async throws {
        let tar = try decompress(loadData(from: archiveURL), using: BZip2.decompress)
        try await extractTarData(tar, paths: paths, junkPaths: junkPaths, to: destination, progress: progress)
    }

    // MARK: – 7-Zip (SWCompression)

    private static func readSevenZipSync(url: URL, fileSize: Int64) throws -> ArchiveInfo {
        let data = try loadData(from: url)
        let infos: [SevenZipEntryInfo]
        do { infos = try SevenZipContainer.info(container: data) }
        catch { throw ArchiveError.readFailed(error.localizedDescription) }

        let fmt = isoFormatter()
        let entries = infos.compactMap { info -> FileEntry? in
            guard info.type != .symbolicLink else { return nil }
            let isDir = info.type == .directory
            let path = isDir && !info.name.hasSuffix("/") ? info.name + "/" : info.name
            return FileEntry(
                path: path,
                uncompressedSize: Int64(info.size ?? 0),
                compressedSize: Int64(info.size ?? 0),
                date: info.modificationTime.map { fmt.string(from: $0) } ?? "",
                isDirectory: isDir
            )
        }
        return ArchiveInfo(entries: entries, fileName: url.lastPathComponent, fileSize: fileSize)
    }

    private static func extractSevenZipSync(from archiveURL: URL, paths: [String], junkPaths: Bool, to destination: URL, progress: ((Double) -> Void)?) async throws {
        let data = try loadData(from: archiveURL)
        let entries: [SevenZipEntry]
        do { entries = try SevenZipContainer.open(container: data) }
        catch { throw ArchiveError.readFailed(error.localizedDescription) }
        try await writeEntries(entries.map { ($0.info.name, $0.info.type, $0.data) },
                               paths: Set(paths), junkPaths: junkPaths, to: destination, progress: progress)
    }

    // MARK: – Shared TAR helpers

    private static func tarInfoToArchiveInfo(data: Data, fileName: String, fileSize: Int64) throws -> ArchiveInfo {
        let infos: [TarEntryInfo]
        do { infos = try TarContainer.info(container: data) }
        catch { throw ArchiveError.readFailed(error.localizedDescription) }

        let fmt = isoFormatter()
        let entries = infos.compactMap { info -> FileEntry? in
            guard info.type != .symbolicLink else { return nil }
            var path = info.name
            if path.hasPrefix("./") { path = String(path.dropFirst(2)) }
            guard !path.isEmpty, path != "." else { return nil }
            let isDir = info.type == .directory
            return FileEntry(
                path: isDir && !path.hasSuffix("/") ? path + "/" : path,
                uncompressedSize: Int64(info.size ?? 0),
                compressedSize: Int64(info.size ?? 0),
                date: info.modificationTime.map { fmt.string(from: $0) } ?? "",
                isDirectory: isDir
            )
        }
        return ArchiveInfo(entries: entries, fileName: fileName, fileSize: fileSize)
    }

    private static func extractTarData(_ data: Data, paths: [String], junkPaths: Bool, to destination: URL, progress: ((Double) -> Void)?) async throws {
        let entries: [TarEntry]
        do { entries = try TarContainer.open(container: data) }
        catch { throw ArchiveError.readFailed(error.localizedDescription) }

        let pathSet = Set(paths)
        let toWrite = entries.filter { entry in
            guard entry.info.type != .symbolicLink else { return false }
            var path = entry.info.name
            if path.hasPrefix("./") { path = String(path.dropFirst(2)) }
            guard !path.isEmpty, path != "." else { return false }
            if !pathSet.isEmpty {
                let dirPath = path.hasSuffix("/") ? path : path + "/"
                return pathSet.contains(path) || pathSet.contains(dirPath)
            }
            return true
        }
        let total = max(toWrite.count, 1)
        let fm = FileManager.default
        let dirs  = toWrite.filter { $0.info.type == .directory }
        let files = toWrite.filter { $0.info.type != .directory }

        // Phase 1: create directories in order (parent before child)
        for (i, entry) in dirs.enumerated() {
            try Task.checkCancellation()
            var path = entry.info.name
            if path.hasPrefix("./") { path = String(path.dropFirst(2)) }
            let destName = junkPaths ? (path as NSString).lastPathComponent : path
            guard let dirURL = safeDestURL(base: destination, relativePath: destName) else { continue }
            try fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
            progress?(Double(i + 1) / Double(total))
        }

        // Phase 2: write files concurrently
        var done = dirs.count
        try await withThrowingTaskGroup(of: Void.self) { group in
            for entry in files {
                var path = entry.info.name
                if path.hasPrefix("./") { path = String(path.dropFirst(2)) }
                let destName = junkPaths ? (path as NSString).lastPathComponent : path
                guard let destURL = safeDestURL(base: destination, relativePath: destName) else { continue }
                let fileData = entry.data
                group.addTask {
                    try Task.checkCancellation()
                    try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if let fileData { try fileData.write(to: destURL) }
                }
            }
            for try await _ in group {
                done += 1
                progress?(Double(done) / Double(total))
            }
        }
    }

    private static func writeEntries(_ entries: [(name: String, type: ContainerEntryType, data: Data?)],
                                     paths: Set<String>, junkPaths: Bool, to destination: URL,
                                     progress: ((Double) -> Void)?) async throws {
        let toWrite = entries.filter { $0.type != .symbolicLink && (paths.isEmpty || paths.contains($0.name)) }
        let total = max(toWrite.count, 1)
        let fm = FileManager.default
        let dirs  = toWrite.filter { $0.type == .directory }
        let files = toWrite.filter { $0.type != .directory }

        // Phase 1: create directories in order (parent before child)
        for (i, (name, _, _)) in dirs.enumerated() {
            try Task.checkCancellation()
            let destName = junkPaths ? (name as NSString).lastPathComponent : name
            guard let dirURL = safeDestURL(base: destination, relativePath: destName) else { continue }
            try fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
            progress?(Double(i + 1) / Double(total))
        }

        // Phase 2: write files concurrently
        var done = dirs.count
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (name, _, data) in files {
                let destName = junkPaths ? (name as NSString).lastPathComponent : name
                guard let destURL = safeDestURL(base: destination, relativePath: destName) else { continue }
                group.addTask {
                    try Task.checkCancellation()
                    try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if let fileData = data { try fileData.write(to: destURL) }
                }
            }
            for try await _ in group {
                done += 1
                progress?(Double(done) / Double(total))
            }
        }
    }

    // MARK: – TNEF / winmail.dat (pure Swift — no external dependency)

    private static func readTnefSync(url: URL, fileSize: Int64) throws -> ArchiveInfo {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw ArchiveError.readFailed(error.localizedDescription) }

        var entries: [FileEntry] = []
        try tnefWalk(data) { name, payload, date in
            entries.append(FileEntry(path: name,
                                     uncompressedSize: Int64(payload.count),
                                     compressedSize: Int64(payload.count),
                                     date: date, isDirectory: false))
        }
        return ArchiveInfo(entries: entries, fileName: url.lastPathComponent, fileSize: fileSize)
    }

    private static func extractTnefSync(from archiveURL: URL, paths: [String], to destination: URL, progress: ((Double) -> Void)?) throws {
        let data: Data
        do { data = try Data(contentsOf: archiveURL) }
        catch { throw ArchiveError.readFailed(error.localizedDescription) }

        let wanted = Set(paths)
        try tnefWalk(data) { name, payload, _ in
            guard wanted.isEmpty || wanted.contains(name) else { return }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try payload.write(to: destination.appendingPathComponent(name))
        }
        progress?(1.0)
    }

    /// Parses a TNEF stream, calling `handler(filename, data, date)` for every attachment.
    /// Handles both the classic TNEF attribute format (Outlook 95/96) and the
    /// per-attachment MAPI property bag (`attAttachment`, Outlook 97+).
    private static func tnefWalk(_ raw: Data,
                                  handler: (String, Data, String) throws -> Void) throws {
        guard raw.count > 6, tnefLE32(raw, 0) == 0x223E9F78 else {
            throw ArchiveError.readFailed("Not a valid TNEF file")
        }

        var pos = 6     // past 4-byte signature and 2-byte key
        var classicName = "", classicDate = "", mapiName = ""
        var classicPayload: Data? = nil, mapiPayload: Data? = nil
        var inAttach = false

        func flush() throws {
            let name = mapiName.isEmpty ? classicName : mapiName
            let data = mapiPayload ?? classicPayload
            if inAttach, !name.isEmpty, let d = data { try handler(name, d, classicDate) }
            classicName = ""; classicDate = ""; mapiName = ""
            classicPayload = nil; mapiPayload = nil; inAttach = false
        }

        while pos + 9 <= raw.count {
            let lvl    = raw[pos]; pos += 1
            let attrId = tnefLE32(raw, pos); pos += 4
            let attrLen = Int(tnefLE32(raw, pos)); pos += 4
            guard pos + attrLen + 2 <= raw.count else { break }
            let chunk = raw.subdata(in: pos ..< pos + attrLen)
            pos += attrLen + 2      // data + 2-byte checksum

            guard lvl == 0x02 else { continue }     // only attachment-level attributes

            switch attrId & 0x0000_FFFF {
            case 0x9002:            // attAttachRenddata — marks start of a new attachment
                try flush(); inAttach = true

            case 0x8010, 0x9001:   // attAttachTitle / attAttachTransportFilename
                classicName = tnefString(chunk)

            case 0x800F:            // attAttachData (classic binary payload)
                classicPayload = chunk

            case 0x8013:            // attAttachModifyDate (DTR struct: seven consecutive WORDs)
                if chunk.count >= 10 {
                    classicDate = String(format: "%04d-%02d-%02d",
                                         Int(tnefLE16(chunk, 0)), Int(tnefLE16(chunk, 2)),
                                         Int(tnefLE16(chunk, 4)))
                }

            case 0x9005:            // attAttachment — per-attachment MAPI property bag (Outlook 97+)
                tnefScanMAPI(chunk, name: &mapiName, data: &mapiPayload)

            default: break
            }
        }
        try flush()
    }

    /// Scans a MAPI property bag for PR_ATTACH_LONG_FILENAME (0x3707),
    /// PR_ATTACH_FILENAME (0x3704), and PR_ATTACH_DATA_BIN (0x3701).
    private static func tnefScanMAPI(_ bag: Data, name: inout String, data: inout Data?) {
        guard bag.count >= 4 else { return }
        let propCount = Int(tnefLE32(bag, 0))
        var pos = 4

        for _ in 0 ..< propCount {
            guard pos + 8 <= bag.count else { return }
            let ptype = tnefLE16(bag, pos)
            let pid   = tnefLE16(bag, pos + 2)
            pos += 8    // prop tag (4 bytes) + reserved padding (4 bytes)

            // Multi-value: each value has its own length prefix
            if ptype & 0x1000 != 0 {
                guard pos + 4 <= bag.count else { return }
                let mvCount = Int(tnefLE32(bag, pos)); pos += 4
                for _ in 0 ..< mvCount {
                    guard pos + 4 <= bag.count else { return }
                    let vlen = Int(tnefLE32(bag, pos)); pos += 4
                    pos += (vlen + 3) & ~3
                }
                continue
            }

            switch ptype {
            // Fixed-size 4-byte types: NULL, error, short, boolean, long, float
            case 0x0001, 0x000A, 0x0002, 0x000B, 0x0003, 0x0004: pos += 4
            // Fixed-size 8-byte types: double, currency, apptime, int64, systime
            case 0x0005, 0x0006, 0x0007, 0x0014, 0x0040:          pos += 8
            // Fixed-size 16-byte: CLSID
            case 0x0048:                                           pos += 16

            // Variable-size: PT_STRING8 / PT_UNICODE / PT_BINARY
            case 0x001E, 0x001F, 0x0102:
                guard pos + 4 <= bag.count else { return }
                let vlen = Int(tnefLE32(bag, pos)); pos += 4
                guard pos + vlen <= bag.count else { return }

                if pid == 0x3707 || pid == 0x3704 {     // PR_ATTACH_LONG_FILENAME / PR_ATTACH_FILENAME
                    let enc: String.Encoding = (ptype == 0x001F) ? .utf16LittleEndian : .windowsCP1252
                    let s = String(data: bag.subdata(in: pos ..< pos + vlen), encoding: enc) ?? ""
                    let clean = s.trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespaces))
                    if !clean.isEmpty { name = clean }
                }
                if pid == 0x3701 {                       // PR_ATTACH_DATA_BIN
                    data = bag.subdata(in: pos ..< pos + vlen)
                }
                pos += (vlen + 3) & ~3

            default:
                return  // unknown prop type — can't determine size, stop scanning
            }
        }
    }

    private static func tnefString(_ d: Data) -> String {
        (String(data: d, encoding: .windowsCP1252) ?? String(data: d, encoding: .utf8) ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespaces))
    }

    private static func tnefLE16(_ d: Data, _ pos: Int) -> UInt16 {
        guard pos + 1 < d.count else { return 0 }
        return UInt16(d[pos]) | UInt16(d[pos + 1]) << 8
    }

    private static func tnefLE32(_ d: Data, _ pos: Int) -> UInt32 {
        guard pos + 3 < d.count else { return 0 }
        return UInt32(d[pos]) | UInt32(d[pos+1]) << 8 | UInt32(d[pos+2]) << 16 | UInt32(d[pos+3]) << 24
    }

    // MARK: – EML / MIME email (MimeParser)

    private static func emlParts(from url: URL) throws -> [(name: String, data: Data)] {
        let raw = try loadData(from: url)
        guard let emlString = String(data: raw, encoding: .utf8)
                           ?? String(data: raw, encoding: .isoLatin1) else {
            throw ArchiveError.readFailed("Could not decode EML as text")
        }
        let mime: Mime
        do { mime = try MimeParser().parse(emlString) }
        catch { throw ArchiveError.readFailed("MIME parse error: \(error)") }

        var results: [(name: String, data: Data)] = []
        var seen = Set<String>()
        var previewHTML: Data?
        var previewText: String?

        func uniqueName(_ base: String) -> String {
            if seen.insert(base).inserted { return base }
            let dot = base.lastIndex(of: ".")
            let nm = dot.map { String(base[..<$0]) } ?? base
            let ext = dot.map { String(base[$0...]) } ?? ""
            var c = 1
            while true {
                let candidate = "\(nm)_\(c)\(ext)"
                if seen.insert(candidate).inserted { return candidate }
                c += 1
            }
        }

        func walk(_ m: Mime) {
            switch m.content {
            case .body:
                guard let data = try? m.decodedContentData(), !data.isEmpty else { return }
                let type_ = m.header.contentType?.type ?? "application"
                let subtype = m.header.contentType?.subtype ?? "octet-stream"
                guard type_ != "message" else { return }
                var baseName = m.header.contentDisposition?.filename
                            ?? m.header.contentType?.name
                if baseName == nil {
                    switch "\(type_)/\(subtype)" {
                    case "text/plain":
                        baseName = "body.txt"
                        if previewText == nil { previewText = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) }
                    case "text/html":
                        baseName = "body.html"
                        if previewHTML == nil { previewHTML = data }
                    case "text/calendar": baseName = "invite.ics"
                    default: return
                    }
                }
                guard let name = baseName else { return }
                results.append((name: uniqueName(name), data: data))
            case .mixed(let parts):
                parts.forEach { walk($0) }
            case .alternative(let parts):
                parts.forEach { walk($0) }
            }
        }

        walk(mime)

        let h = parseRFC822Headers(emlString)
        let preview = emailPreviewHTML(
            subject: h["subject"] ?? "", from: h["from"] ?? "",
            to: h["to"] ?? "", cc: h["cc"] ?? "", date: h["date"] ?? "",
            htmlBody: previewHTML, textBody: previewText
        )
        return [("message.html", preview)] + results
    }

    private static func readEmlSync(url: URL, fileSize: Int64) throws -> ArchiveInfo {
        let parts = try emlParts(from: url)
        let entries = parts.map { part in
            FileEntry(path: part.name, uncompressedSize: Int64(part.data.count),
                      compressedSize: Int64(part.data.count), date: "", isDirectory: false)
        }
        return ArchiveInfo(entries: entries, fileName: url.lastPathComponent, fileSize: fileSize)
    }

    private static func extractEmlSync(from archiveURL: URL, paths: [String], to destination: URL, progress: ((Double) -> Void)?) throws {
        let want = Set(paths)
        let parts = try emlParts(from: archiveURL)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for part in parts where want.isEmpty || want.contains(part.name) {
            try part.data.write(to: destination.appendingPathComponent(part.name))
        }
        progress?(1.0)
    }

    // MARK: – MSG (Outlook Message / OLE2 Compound File Binary Format)

    private static func readMsgSync(url: URL, fileSize: Int64) throws -> ArchiveInfo {
        let raw = try loadData(from: url)
        let parts = try cfbMsgParts(raw)
        let entries = parts.map { p in
            FileEntry(path: p.name, uncompressedSize: Int64(p.data.count),
                      compressedSize: Int64(p.data.count), date: "", isDirectory: false)
        }
        return ArchiveInfo(entries: entries, fileName: url.lastPathComponent, fileSize: fileSize)
    }

    private static func extractMsgSync(from archiveURL: URL, paths: [String], to destination: URL, progress: ((Double) -> Void)?) throws {
        let raw = try loadData(from: archiveURL)
        let want = Set(paths)
        let parts = try cfbMsgParts(raw)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for p in parts where want.isEmpty || want.contains(p.name) {
            try p.data.write(to: destination.appendingPathComponent(p.name))
        }
        progress?(1.0)
    }

    private static func cfbMsgParts(_ fileData: Data) throws -> [(name: String, data: Data)] {
        let d = Array(fileData)

        func u8 (_ i: Int) -> UInt8  { i < d.count ? d[i] : 0 }
        func u16(_ i: Int) -> UInt16 { UInt16(u8(i)) | UInt16(u8(i+1)) << 8 }
        func u32(_ i: Int) -> UInt32 { UInt32(u8(i)) | UInt32(u8(i+1)) << 8 | UInt32(u8(i+2)) << 16 | UInt32(u8(i+3)) << 24 }

        let magic: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
        guard d.count >= 512, Array(d[0..<8]) == magic else {
            throw ArchiveError.readFailed("Not a valid OLE2 compound file")
        }

        let sectorSize     = 1 << Int(u16(30))   // 512 (v3) or 4096 (v4)
        let miniSectorSize = 1 << Int(u16(32))   // 64
        let numFATSectors  = Int(u32(44))
        let firstDirSect   = u32(48)
        let miniCutoff     = Int(u32(56))         // 4096
        let firstMiniSect  = u32(60)
        let firstDIFSect   = u32(68)

        let ENDOFCHAIN: UInt32 = 0xFFFFFFFE
        let FREESECT:   UInt32 = 0xFFFFFFFF
        let NOSTREAM:   UInt32 = 0xFFFFFFFF

        func sectorStart(_ sid: UInt32) -> Int { 512 + Int(sid) * sectorSize }

        // Collect FAT sector IDs from header DIFAT array (109 slots at offset 76)
        var fatSIDs: [UInt32] = []
        for i in 0..<109 {
            let sid = u32(76 + i * 4)
            if sid == FREESECT || sid == ENDOFCHAIN { break }
            fatSIDs.append(sid)
        }
        // Follow DIFAT chain for files with >109 FAT sectors
        var difSect = firstDIFSect
        while difSect != ENDOFCHAIN && difSect != FREESECT {
            let base = sectorStart(difSect)
            let n = sectorSize / 4 - 1
            for i in 0..<n {
                let sid = u32(base + i * 4)
                if sid == FREESECT || sid == ENDOFCHAIN { break }
                fatSIDs.append(sid)
            }
            difSect = u32(base + sectorSize - 4)
        }

        // Build FAT
        var fat = [UInt32](repeating: FREESECT, count: numFATSectors * (sectorSize / 4))
        var fatIdx = 0
        for sid in fatSIDs {
            let base = sectorStart(sid)
            for i in 0..<(sectorSize / 4) {
                let entry = u32(base + i * 4)
                if fatIdx < fat.count { fat[fatIdx] = entry } else { fat.append(entry) }
                fatIdx += 1
            }
        }

        func readChain(start: UInt32, maxBytes: Int = .max) -> [UInt8] {
            var out = [UInt8](); var sid = start
            while sid != ENDOFCHAIN && sid != FREESECT && Int(sid) < fat.count {
                let base = sectorStart(sid)
                let avail = min(sectorSize, d.count - base)
                guard avail > 0 else { break }
                let take = min(avail, maxBytes - out.count)
                out.append(contentsOf: d[base..<base+take])
                if out.count >= maxBytes { break }
                sid = fat[Int(sid)]
            }
            return out
        }

        // Build mini FAT
        let miniFATBytes = readChain(start: firstMiniSect)
        var miniFAT = [UInt32]()
        for i in 0..<(miniFATBytes.count / 4) {
            let o = i * 4
            miniFAT.append(UInt32(miniFATBytes[o]) | UInt32(miniFATBytes[o+1]) << 8
                         | UInt32(miniFATBytes[o+2]) << 16 | UInt32(miniFATBytes[o+3]) << 24)
        }

        // Parse directory entries (128 bytes each)
        let dirBytes = readChain(start: firstDirSect)
        func dU8 (_ i: Int) -> UInt8  { i < dirBytes.count ? dirBytes[i] : 0 }
        func dU16(_ i: Int) -> UInt16 { UInt16(dU8(i)) | UInt16(dU8(i+1)) << 8 }
        func dU32(_ i: Int) -> UInt32 { UInt32(dU8(i)) | UInt32(dU8(i+1)) << 8 | UInt32(dU8(i+2)) << 16 | UInt32(dU8(i+3)) << 24 }

        struct DirEntry {
            let name: String; let type: UInt8
            let left: UInt32; let right: UInt32; let child: UInt32
            let start: UInt32; let size: UInt64
        }
        var dirs = [DirEntry]()
        for i in 0..<(dirBytes.count / 128) {
            let b = i * 128
            let rawLen = Int(dU16(b + 64))
            let nameLen = rawLen >= 2 ? rawLen - 2 : 0
            let nameBytes = nameLen > 0 ? Array(dirBytes[b..<min(b + nameLen, dirBytes.count)]) : []
            let name = String(bytes: nameBytes, encoding: .utf16LittleEndian) ?? ""
            let sizeLo = UInt64(dU32(b + 120)); let sizeHi = UInt64(dU32(b + 124))
            dirs.append(DirEntry(name: name, type: dU8(b + 66),
                                 left: dU32(b + 68), right: dU32(b + 72), child: dU32(b + 76),
                                 start: dU32(b + 116), size: sizeHi << 32 | sizeLo))
        }

        // Mini stream lives in the root entry's regular stream
        // `Int(clamping:)` avoids a trap if a malformed file's 64-bit size field exceeds
        // Int.max; the chain readers below already stop at actual available data regardless.
        let miniStream = dirs.isEmpty ? [UInt8]() : readChain(start: dirs[0].start, maxBytes: Int(clamping: dirs[0].size))

        func readMiniChain(start: UInt32, size: Int) -> [UInt8] {
            var out = [UInt8](); var msid = start
            while msid != ENDOFCHAIN && msid != FREESECT && Int(msid) < miniFAT.count {
                let off = Int(msid) * miniSectorSize
                guard off < miniStream.count else { break }
                let take = min(miniSectorSize, min(size - out.count, miniStream.count - off))
                out.append(contentsOf: miniStream[off..<off+take])
                if out.count >= size { break }
                msid = miniFAT[Int(msid)]
            }
            return out
        }

        func streamBytes(for e: DirEntry) -> [UInt8] {
            guard e.type == 2 else { return [] }
            let sz = Int(clamping: e.size)
            return (sz < miniCutoff && !miniStream.isEmpty)
                ? readMiniChain(start: e.start, size: sz)
                : readChain(start: e.start, maxBytes: sz)
        }

        // Red-black tree traversal to enumerate sibling directory entries.
        // `visited` guards against cycles in malformed files.
        func siblings(_ did: UInt32) -> [Int] {
            var visited = Set<UInt32>()
            func walk(_ did: UInt32) -> [Int] {
                guard did != NOSTREAM, Int(did) < dirs.count, dirs[Int(did)].type != 0 else { return [] }
                guard visited.insert(did).inserted else { return [] }
                return walk(dirs[Int(did)].left) + [Int(did)] + walk(dirs[Int(did)].right)
            }
            return walk(did)
        }
        func children(of did: Int) -> [Int] {
            guard did < dirs.count else { return [] }
            return siblings(dirs[did].child)
        }
        func find(in did: Int, named n: String) -> Int? {
            children(of: did).first { dirs[$0].name.uppercased() == n.uppercased() }
        }
        func readUTF16(_ did: Int) -> String? {
            let bytes = streamBytes(for: dirs[did])
            guard bytes.count >= 2 else { return nil }
            return String(bytes: bytes, encoding: .utf16LittleEndian)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        }

        var results: [(name: String, data: Data)] = []
        var seen = Set<String>()
        func uniqueName(_ base: String) -> String {
            if seen.insert(base).inserted { return base }
            let dot = base.lastIndex(of: "."); let nm = dot.map { String(base[..<$0]) } ?? base
            let ext = dot.map { String(base[$0...]) } ?? ""; var c = 1
            while true { let cand = "\(nm)_\(c)\(ext)"; if seen.insert(cand).inserted { return cand }; c += 1 }
        }

        // PR_BODY (0x1000, PT_UNICODE 001F) → body.txt as UTF-8
        if let did = find(in: 0, named: "__substg1.0_1000001F") {
            let bytes = streamBytes(for: dirs[did])
            if let text = String(bytes: bytes, encoding: .utf16LittleEndian), !text.isEmpty {
                results.append((uniqueName("body.txt"), Data(text.utf8)))
            }
        }

        // PR_HTML_BODY (0x1013, PT_BINARY 0102) → body.html
        if let did = find(in: 0, named: "__substg1.0_10130102") {
            let bytes = streamBytes(for: dirs[did])
            if !bytes.isEmpty { results.append((uniqueName("body.html"), Data(bytes))) }
        }

        // Attachments: sub-storages named __attach_version1.N
        let attachDIDs = children(of: 0).filter {
            dirs[$0].name.lowercased().hasPrefix("__attach_version1.") && dirs[$0].type == 1
        }
        for attDID in attachDIDs {
            // PR_ATTACH_LONG_FILENAME (0x3707) preferred; fall back to PR_ATTACH_FILENAME (0x3704)
            let nameDID = find(in: attDID, named: "__substg1.0_3707001F")
                       ?? find(in: attDID, named: "__substg1.0_3704001F")
            guard let nDID = nameDID, let name = readUTF16(nDID), !name.isEmpty else { continue }
            // PR_ATTACH_DATA_BIN (0x3701, PT_BINARY 0102)
            guard let dDID = find(in: attDID, named: "__substg1.0_37010102") else { continue }
            let bytes = streamBytes(for: dirs[dDID])
            guard !bytes.isEmpty else { continue }
            results.append((uniqueName(name), Data(bytes)))
        }

        // Message metadata for the formatted preview
        let subject    = find(in: 0, named: "__substg1.0_0037001F").flatMap { readUTF16($0) } ?? ""
        let senderName = find(in: 0, named: "__substg1.0_0C1A001F").flatMap { readUTF16($0) } ?? ""
        let senderAddr = find(in: 0, named: "__substg1.0_0C1F001F").flatMap { readUTF16($0) } ?? ""
        let from = senderName.isEmpty ? senderAddr
                 : senderAddr.isEmpty ? senderName
                 : "\(senderName) <\(senderAddr)>"
        let to = find(in: 0, named: "__substg1.0_0E04001F").flatMap { readUTF16($0) } ?? ""
        let cc = find(in: 0, named: "__substg1.0_0E03001F").flatMap { readUTF16($0) } ?? ""

        // Date from fixed-size properties stream (PR_CLIENT_SUBMIT_TIME 0x0039 / PR_MESSAGE_DELIVERY_TIME 0x0E06)
        var date = ""
        if let pDID = find(in: 0, named: "__properties_version1.0") {
            let props = streamBytes(for: dirs[pDID])
            let targets: Set<UInt16> = [0x0039, 0x0E06]
            var pos = 24  // skip 24-byte message-object header
            while pos + 16 <= props.count {
                let ptype = UInt16(props[pos]) | UInt16(props[pos+1]) << 8
                let pid   = UInt16(props[pos+2]) | UInt16(props[pos+3]) << 8
                if ptype == 0x0040 && targets.contains(pid) {
                    var ft: UInt64 = 0
                    for i in 0..<8 { ft |= UInt64(props[pos+8+i]) << (i*8) }
                    let epoch: UInt64 = 116444736000000000
                    if ft > epoch {
                        let d = Date(timeIntervalSince1970: Double(ft - epoch) / 10_000_000)
                        let f = DateFormatter(); f.dateStyle = .long; f.timeStyle = .short
                        date = f.string(from: d)
                        break
                    }
                }
                pos += 16
            }
        }

        let htmlBodyData = results.first(where: { $0.name == "body.html" })?.data
        let textBody = results.first(where: { $0.name == "body.txt" }).flatMap { String(data: $0.data, encoding: .utf8) }
        let preview = emailPreviewHTML(subject: subject, from: from, to: to, cc: cc, date: date,
                                       htmlBody: htmlBodyData, textBody: textBody)
        return [("message.html", preview)] + results
    }

    // MARK: – Shared helpers

    private static func emailPreviewHTML(
        subject: String, from: String, to: String, cc: String, date: String,
        htmlBody: Data?, textBody: String?
    ) -> Data {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
             .replacingOccurrences(of: "<", with: "&lt;")
             .replacingOccurrences(of: ">", with: "&gt;")
             .replacingOccurrences(of: "\"", with: "&quot;")
        }

        // Parse "Display Name <addr>" or bare address
        let senderName: String
        let senderEmail: String
        if let lt = from.firstIndex(of: "<"), let gt = from.lastIndex(of: ">"), lt < gt {
            let n = String(from[..<lt])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let e = String(from[from.index(after: lt)..<gt])
            senderName = n.isEmpty ? e : n
            senderEmail = e
        } else {
            senderName = from.trimmingCharacters(in: .whitespaces)
            senderEmail = senderName
        }

        // Up to two initials from sender display name
        let nameWords = senderName.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        let initials: String = {
            if nameWords.count >= 2, let a = nameWords[0].first, let b = nameWords[1].first {
                return "\(a)\(b)".uppercased()
            } else if let a = senderName.first {
                return String(a).uppercased()
            }
            return "?"
        }()

        // Deterministic avatar color (stable DJB2 over UTF-8 bytes)
        var h: UInt32 = 5381
        for byte in from.utf8 { h = h &* 31 &+ UInt32(byte) }
        let palette = ["#007AFF","#34C759","#FF9500","#FF3B30","#AF52DE","#5856D6","#FF2D55","#00C7BE"]
        let avatarColor = palette[Int(h % UInt32(palette.count))]

        // From display: bold name + dimmed <email>
        let fromHTML: String
        if !senderName.isEmpty && senderName.lowercased() != senderEmail.lowercased() {
            fromHTML = "<span class=fn>\(esc(senderName))</span> <span class=fe>&lt;\(esc(senderEmail))&gt;</span>"
        } else {
            fromHTML = "<span class=fn>\(esc(senderEmail))</span>"
        }

        // Recipient rows
        var rcptHTML = ""
        if !to.isEmpty { rcptHTML += "<div><span class=rl>To</span> \(esc(to))</div>" }
        if !cc.isEmpty { rcptHTML += "<div><span class=rl>Cc</span> \(esc(cc))</div>" }

        // Body content
        let bodyHTML: String
        if let data = htmlBody,
           let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) {
            if let bodyTag = html.range(of: "<body", options: .caseInsensitive),
               let tagClose = html[bodyTag.upperBound...].range(of: ">"),
               let bodyEnd = html[tagClose.upperBound...].range(of: "</body>", options: .caseInsensitive) {
                bodyHTML = String(html[tagClose.upperBound..<bodyEnd.lowerBound])
            } else {
                bodyHTML = html
            }
        } else if let text = textBody, !text.isEmpty {
            bodyHTML = "<pre>\(esc(text))</pre>"
        } else {
            bodyHTML = "<p class=nobody>(No message body)</p>"
        }

        let subjHTML = esc(subject.isEmpty ? "(No Subject)" : subject)
        let dateHTML = esc(date)
        let dateSpan = dateHTML.isEmpty ? "" : "<span class=dt>\(dateHTML)</span>"
        let rcptBlock = rcptHTML.isEmpty ? "" : "<div class=rc>\(rcptHTML)</div>"

        let html = """
        <!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1"><style>
        *,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
        :root{--bg:#ffffff;--hdr:#f6f6f6;--bd:#e5e5ea;--tx:#1c1c1e;--dm:#6c6c70;--ac:#007aff}
        @media(prefers-color-scheme:dark){:root{--bg:#1c1c1e;--hdr:#2c2c2e;--bd:#38383a;--tx:#f2f2f7;--dm:#8e8e93}}
        body{font-family:-apple-system,'Helvetica Neue',Helvetica,Arial,sans-serif;font-size:14px;color:var(--tx);background:var(--bg);-webkit-font-smoothing:antialiased;line-height:1.5}
        .hdr{background:var(--hdr);border-bottom:1px solid var(--bd);padding:20px 24px 16px}
        .subj{font-size:20px;font-weight:600;line-height:1.3;margin-bottom:14px}
        .sr{display:flex;align-items:flex-start;gap:12px}
        .av{width:40px;height:40px;border-radius:50%;background:\(avatarColor);color:#fff;font-size:15px;font-weight:600;display:flex;align-items:center;justify-content:center;flex-shrink:0;letter-spacing:-.5px;font-family:-apple-system,'Helvetica Neue',Helvetica,Arial,sans-serif}
        .sm{flex:1;min-width:0}
        .fl{display:flex;align-items:baseline;justify-content:space-between;gap:12px;flex-wrap:wrap}
        .fn{font-weight:600;font-size:14px}
        .fe{font-size:12px;color:var(--dm)}
        .dt{font-size:12px;color:var(--dm);white-space:nowrap}
        .rc{margin-top:5px;font-size:12px;color:var(--dm);line-height:1.6}
        .rl{font-weight:500;margin-right:4px}
        .body{padding:24px;line-height:1.7}
        .body p{margin-bottom:.9em}
        .body a{color:var(--ac)}
        .body img{max-width:100%;height:auto;border-radius:4px}
        .body table{border-collapse:collapse;max-width:100%}
        .body blockquote{border-left:3px solid var(--bd);margin:8px 0;padding-left:14px;color:var(--dm)}
        .body pre{white-space:pre-wrap;word-break:break-word;font-family:'SF Mono',SFMono-Regular,ui-monospace,Menlo,monospace;font-size:12px;background:var(--hdr);padding:12px;border-radius:6px;border:1px solid var(--bd);line-height:1.5;margin:.9em 0}
        .nobody{color:var(--dm);font-style:italic}
        </style></head><body>
        <div class=hdr>
        <div class=subj>\(subjHTML)</div>
        <div class=sr>
        <div class=av>\(initials)</div>
        <div class=sm>
        <div class=fl><div>\(fromHTML)</div>\(dateSpan)</div>
        \(rcptBlock)
        </div>
        </div>
        </div>
        <div class=body>\(bodyHTML)</div>
        </body></html>
        """
        return Data(html.utf8)
    }

    private static func parseRFC822Headers(_ raw: String) -> [String: String] {
        var headers: [String: String] = [:]
        var key = ""; var val = ""
        for line in raw.components(separatedBy: "\n") {
            let l = line.hasSuffix("\r") ? String(line.dropLast()) : line
            if l.isEmpty { break }
            if (l.first == " " || l.first == "\t") && !key.isEmpty {
                val += " " + l.trimmingCharacters(in: .whitespaces)
            } else if let ci = l.firstIndex(of: ":") {
                if !key.isEmpty { headers[key.lowercased()] = val.trimmingCharacters(in: .whitespaces) }
                key = String(l[..<ci])
                val = String(l[l.index(after: ci)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        if !key.isEmpty { headers[key.lowercased()] = val.trimmingCharacters(in: .whitespaces) }
        return headers
    }

    /// Returns the resolved destination URL only when it is strictly inside `base`.
    /// Rejects path-traversal entries (zip slip) by resolving `..` components before checking.
    private static func safeDestURL(base: URL, relativePath: String) -> URL? {
        let dest = base.appendingPathComponent(relativePath).standardized
        return dest.path.hasPrefix(base.standardized.path + "/") ? dest : nil
    }

    private static func loadData(from url: URL) throws -> Data {
        do { return try Data(contentsOf: url) }
        catch { throw ArchiveError.readFailed(error.localizedDescription) }
    }

    private static func decompress(_ data: Data, using fn: (Data) throws -> Data) throws -> Data {
        do { return try fn(data) }
        catch { throw ArchiveError.readFailed(error.localizedDescription) }
    }

    private static func isoFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

}
