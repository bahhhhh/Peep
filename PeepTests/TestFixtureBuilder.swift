import Foundation
import ZIPFoundation

/// Builds minimal test fixture archives in a temp directory for each format Peep supports.
enum TestFixtureBuilder {

    // MARK: – Source content

    static let helloContent   = Data("Hello from Peep\n".utf8)
    static let worldContent   = Data("World content\n".utf8)

    // MARK: – ZIP (ZIPFoundation write API)

    static func zipURL() throws -> URL {
        let dir = makeTempSourceDir()
        let hello = dir.appendingPathComponent("hello.txt")
        let subdir = dir.appendingPathComponent("subdir")
        let world = subdir.appendingPathComponent("world.txt")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        try helloContent.write(to: hello)
        try worldContent.write(to: world)

        let zipURL = makeTempDir().appendingPathComponent("test.zip")
        let archive = try Archive(url: zipURL, accessMode: .create)
        try archive.addEntry(with: "hello.txt", relativeTo: dir)
        try archive.addEntry(with: "subdir/world.txt", relativeTo: dir)
        return zipURL
    }

    // MARK: – TAR / TAR.GZ / TAR.BZ2 (system tar)

    static func tarURL() throws -> URL {
        try makeTarArchive(ext: "tar", flags: "-cf")
    }

    static func tarGzURL() throws -> URL {
        try makeTarArchive(ext: "tar.gz", flags: "-czf")
    }

    static func tarBz2URL() throws -> URL {
        try makeTarArchive(ext: "tar.bz2", flags: "-cjf")
    }

    // MARK: – 7-Zip (minimal valid empty archive — exercises the reader without needing 7z CLI)

    static func sevenZipURL() throws -> URL {
        // Signature header for a 7z archive containing zero files.
        // Layout: [sig:6][version:2][startHeaderCRC:4][nextOffset:8][nextSize:8][nextCRC:4][kEnd:1]
        let bytes: [UInt8] = [
            0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C,  // "7z\xBC\xAF\x27\x1C"
            0x00, 0x04,                            // version 0.4
            0xE3, 0xFF, 0x16, 0x73,               // CRC of the 20-byte StartHeader below
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // NextHeaderOffset = 0
            0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // NextHeaderSize = 1
            0x8D, 0xEF, 0x02, 0xD2,               // CRC32 of kEnd byte (0x00)
            0x00,                                  // kEnd — empty archive header
        ]
        return try writeTempFile(name: "test.7z", data: Data(bytes))
    }

    // MARK: – TNEF / winmail.dat (hand-crafted binary)

    static func tnefURL() throws -> URL {
        // Minimal TNEF with one attachment: "test.txt" containing "Hello from TNEF"
        // Format per-attribute: [level:1][attrId_LE32:4][attrLen_LE32:4][data:attrLen][checksum_LE16:2]
        var data = Data([0x78, 0x9F, 0x3E, 0x22, 0x00, 0x00])  // signature + key
        data += tnefAttr(level: 0x02, id: 0x9002, payload: Data(repeating: 0, count: 8))  // attAttachRenddata
        data += tnefAttr(level: 0x02, id: 0x8010, payload: Data("test.txt\0".utf8))        // attAttachTitle
        data += tnefAttr(level: 0x02, id: 0x800F, payload: Data("Hello from TNEF".utf8))   // attAttachData
        return try writeTempFile(name: "winmail.dat", data: data)
    }

    // MARK: – EML (raw MIME text)

    static func emlURL() throws -> URL {
        let raw = """
            MIME-Version: 1.0\r
            From: Test User <test@example.com>\r
            To: recipient@example.com\r
            Subject: Test Email\r
            Content-Type: multipart/mixed; boundary="PEEPTESTBOUNDARY"\r
            \r
            --PEEPTESTBOUNDARY\r
            Content-Type: text/plain; charset=utf-8\r
            \r
            Hello from Peep test email.\r
            --PEEPTESTBOUNDARY\r
            Content-Type: text/plain; name="attachment.txt"\r
            Content-Disposition: attachment; filename="attachment.txt"\r
            \r
            Attachment content here.\r
            --PEEPTESTBOUNDARY--\r

            """
        return try writeTempFile(name: "test.eml", data: Data(raw.utf8))
    }

    // MARK: – Unsupported format (for error-path tests)

    static func unsupportedURL() throws -> URL {
        try writeTempFile(name: "test.xyz", data: Data("not an archive".utf8))
    }

    // MARK: – Corrupt archives (for error-path tests)

    static func corruptZipURL() throws -> URL {
        try writeTempFile(name: "corrupt.zip", data: Data("this is not a zip file".utf8))
    }

    static func corruptMsgURL() throws -> URL {
        try writeTempFile(name: "corrupt.msg", data: Data("this is not an OLE2 file".utf8))
    }

    // MARK: – MSG — malformed OLE2 with cyclic directory red-black tree

    static func cyclicMsgURL() throws -> URL {
        // Minimal valid OLE2 compound file where directory entry 1 has right=1 (self-cycle).
        // Root entry (0) has child=1; siblings() must not infinite-loop on entry 1's right pointer.
        let ENDOFCHAIN: UInt32 = 0xFFFFFFFE
        let FREESECT:   UInt32 = 0xFFFFFFFF
        let NOSTREAM:   UInt32 = 0xFFFFFFFF

        var d = [UInt8](repeating: 0, count: 512 * 3)  // header + FAT sector + dir sector

        func w16(_ off: Int, _ v: UInt16) {
            d[off]   = UInt8(v & 0xFF)
            d[off+1] = UInt8(v >> 8)
        }
        func w32(_ off: Int, _ v: UInt32) {
            d[off]   = UInt8(v & 0xFF)
            d[off+1] = UInt8((v >> 8)  & 0xFF)
            d[off+2] = UInt8((v >> 16) & 0xFF)
            d[off+3] = UInt8((v >> 24) & 0xFF)
        }

        // Header (offset 0–511)
        let magic: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
        d.replaceSubrange(0..<8, with: magic)
        w16(30, 9)              // sector size shift: 2^9 = 512 bytes
        w16(32, 6)              // mini-sector size shift: 2^6 = 64 bytes
        w32(44, 1)              // num FAT sectors = 1
        w32(48, 1)              // first dir sector = sector 1
        w32(56, 4096)           // mini-stream cutoff
        w32(60, ENDOFCHAIN)     // no mini FAT
        w32(68, ENDOFCHAIN)     // no DIFAT extension
        w32(76, 0)              // DIFAT[0]: sector 0 holds the FAT
        for i in 1..<109 { w32(76 + i * 4, FREESECT) }

        // FAT sector (sector 0, file offset 512)
        let fatBase = 512
        for i in 0..<128 { w32(fatBase + i * 4, FREESECT) }
        w32(fatBase + 0 * 4, ENDOFCHAIN)   // sector 0 (FAT) chain ends
        w32(fatBase + 1 * 4, ENDOFCHAIN)   // sector 1 (dir) chain ends

        // Directory sector (sector 1, file offset 1024) — 4 entries × 128 bytes
        let dirBase = 1024

        // Entry 0: Root Entry, child = 1
        let rootName: [UInt16] = Array("Root Entry".utf16)
        for (i, c) in rootName.enumerated() { w16(dirBase + i * 2, c) }
        w16(dirBase + 64, UInt16((rootName.count + 1) * 2))
        d[dirBase + 66] = 5              // type: root storage
        d[dirBase + 67] = 1              // color: black
        w32(dirBase + 68, NOSTREAM)      // left
        w32(dirBase + 72, NOSTREAM)      // right
        w32(dirBase + 76, 1)             // child → entry 1
        w32(dirBase + 116, ENDOFCHAIN)   // start sector

        // Entry 1: "Cyclic", right = 1 (self-referential cycle)
        let e1 = dirBase + 128
        let cyclicName: [UInt16] = Array("Cyclic".utf16)
        for (i, c) in cyclicName.enumerated() { w16(e1 + i * 2, c) }
        w16(e1 + 64, UInt16((cyclicName.count + 1) * 2))
        d[e1 + 66] = 1               // type: storage
        d[e1 + 67] = 1               // color: black
        w32(e1 + 68, NOSTREAM)       // left
        w32(e1 + 72, 1)              // right = self (CYCLE)
        w32(e1 + 76, NOSTREAM)       // child
        w32(e1 + 116, ENDOFCHAIN)    // start sector

        // Entries 2–3: type 0 (unused, already zeroed)

        return try writeTempFile(name: "cyclic.msg", data: Data(d))
    }

    static func corruptTnefURL() throws -> URL {
        try writeTempFile(name: "corrupt.tnef", data: Data("not tnef".utf8))
    }

    // MARK: – Private helpers

    private static func makeTarArchive(ext: String, flags: String) throws -> URL {
        let srcDir = makeTempSourceDir()
        let subdir = srcDir.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        try helloContent.write(to: srcDir.appendingPathComponent("hello.txt"))
        try worldContent.write(to: subdir.appendingPathComponent("world.txt"))

        let outDir = makeTempDir()
        let archivePath = outDir.appendingPathComponent("test.\(ext)").path
        let result = shell("/usr/bin/tar", [flags, archivePath, "-C", srcDir.path, "."])
        if result != 0 { throw TestError.shellFailed("/usr/bin/tar exited \(result)") }
        return URL(fileURLWithPath: archivePath)
    }

    private static func makeTempSourceDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeepTestsSrc-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeepTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func writeTempFile(name: String, data: Data) throws -> URL {
        let url = makeTempDir().appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    static func makeTempDestDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeepTestsDest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func tnefAttr(level: UInt8, id: UInt32, payload: Data) -> Data {
        var d = Data([level])
        d += withUnsafeBytes(of: id.littleEndian) { Data($0) }
        d += withUnsafeBytes(of: UInt32(payload.count).littleEndian) { Data($0) }
        d += payload
        d += Data([0x00, 0x00])  // checksum (zero is accepted by the reader)
        return d
    }

    @discardableResult
    private static func shell(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError  = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    enum TestError: Error {
        case shellFailed(String)
    }
}
