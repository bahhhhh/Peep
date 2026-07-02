import XCTest
@testable import Peep

final class FileEntryTests: XCTestCase {

    // MARK: – FileEntry.compressionRatio

    func testCompressionRatioNormal() {
        let e = FileEntry(path: "file.txt", uncompressedSize: 1000, compressedSize: 400, date: "", isDirectory: false)
        XCTAssertEqual(e.compressionRatio, 0.6, accuracy: 1e-10)
    }

    func testCompressionRatioZeroForDirectory() {
        let e = FileEntry(path: "dir/", uncompressedSize: 0, compressedSize: 0, date: "", isDirectory: true)
        XCTAssertEqual(e.compressionRatio, 0.0)
    }

    func testCompressionRatioZeroWhenUncompressedIsZero() {
        let e = FileEntry(path: "empty.txt", uncompressedSize: 0, compressedSize: 0, date: "", isDirectory: false)
        XCTAssertEqual(e.compressionRatio, 0.0)
    }

    func testCompressionRatioNegativeWhenCompressedIsLarger() {
        // Some compression methods expand tiny files; ratio can be negative
        let e = FileEntry(path: "tiny.txt", uncompressedSize: 4, compressedSize: 8, date: "", isDirectory: false)
        XCTAssertEqual(e.compressionRatio, -1.0, accuracy: 1e-10)
    }

    func testCompressionRatioFullCompression() {
        let e = FileEntry(path: "zeros.bin", uncompressedSize: 1000, compressedSize: 0, date: "", isDirectory: false)
        XCTAssertEqual(e.compressionRatio, 1.0, accuracy: 1e-10)
    }

    // MARK: – buildTree – empty input

    func testBuildTreeEmpty() {
        let nodes = buildTree(from: [])
        XCTAssertTrue(nodes.isEmpty)
    }

    // MARK: – buildTree – flat files at root

    func testBuildTreeFlatFiles() {
        let entries = [
            FileEntry(path: "b.txt", uncompressedSize: 10, compressedSize: 10, date: "", isDirectory: false),
            FileEntry(path: "a.txt", uncompressedSize: 20, compressedSize: 20, date: "", isDirectory: false),
        ]
        let nodes = buildTree(from: entries)
        XCTAssertEqual(nodes.count, 2)
        // Alphabetical order
        XCTAssertEqual(nodes[0].name, "a.txt")
        XCTAssertEqual(nodes[1].name, "b.txt")
        // Leaf nodes have no children
        XCTAssertNil(nodes[0].children)
        XCTAssertNil(nodes[1].children)
    }

    // MARK: – buildTree – explicit directory entry

    func testBuildTreeExplicitDirectory() {
        let entries = [
            FileEntry(path: "docs/", uncompressedSize: 0, compressedSize: 0, date: "", isDirectory: true),
            FileEntry(path: "docs/readme.txt", uncompressedSize: 5, compressedSize: 5, date: "", isDirectory: false),
        ]
        let nodes = buildTree(from: entries)
        XCTAssertEqual(nodes.count, 1)
        let docs = nodes[0]
        XCTAssertEqual(docs.name, "docs")
        XCTAssertEqual(docs.fullPath, "docs/")
        XCTAssertTrue(docs.isDirectory)
        XCTAssertEqual(docs.children?.count, 1)
        XCTAssertEqual(docs.children?.first?.name, "readme.txt")
    }

    // MARK: – buildTree – implicit parent directories

    func testBuildTreeImplicitParentDirs() throws {
        // No explicit directory entries — parent dirs must be synthesised from file paths
        let entries = [
            FileEntry(path: "a/b/c.txt", uncompressedSize: 1, compressedSize: 1, date: "", isDirectory: false),
        ]
        let nodes = buildTree(from: entries)
        XCTAssertEqual(nodes.count, 1)
        let a = nodes[0]
        XCTAssertEqual(a.name, "a")
        XCTAssertEqual(a.fullPath, "a/")
        XCTAssertTrue(a.isDirectory)
        let b = try XCTUnwrap(a.children?.first)
        XCTAssertEqual(b.name, "b")
        XCTAssertEqual(b.fullPath, "a/b/")
        let c = try XCTUnwrap(b.children?.first)
        XCTAssertEqual(c.name, "c.txt")
        XCTAssertEqual(c.fullPath, "a/b/c.txt")
        XCTAssertFalse(c.isDirectory)
    }

    // MARK: – buildTree – sort order (dirs before files, then alphabetical)

    func testBuildTreeSortOrder() {
        let entries = [
            FileEntry(path: "z.txt", uncompressedSize: 1, compressedSize: 1, date: "", isDirectory: false),
            FileEntry(path: "a.txt", uncompressedSize: 1, compressedSize: 1, date: "", isDirectory: false),
            FileEntry(path: "m/", uncompressedSize: 0, compressedSize: 0, date: "", isDirectory: true),
            FileEntry(path: "b/", uncompressedSize: 0, compressedSize: 0, date: "", isDirectory: true),
        ]
        let nodes = buildTree(from: entries)
        // Two directories first (alphabetical), then two files (alphabetical)
        XCTAssertEqual(nodes.map(\.name), ["b", "m", "a.txt", "z.txt"])
    }

    // MARK: – buildTree – stable IDs (fullPath used as id)

    func testBuildTreeNodeIDs() {
        let entries = [
            FileEntry(path: "dir/", uncompressedSize: 0, compressedSize: 0, date: "", isDirectory: true),
            FileEntry(path: "dir/file.txt", uncompressedSize: 1, compressedSize: 1, date: "", isDirectory: false),
        ]
        let nodes = buildTree(from: entries)
        let dir = nodes[0]
        let file = dir.children![0]
        XCTAssertEqual(dir.id, "dir/")
        XCTAssertEqual(file.id, "dir/file.txt")
    }

    // MARK: – buildTree – deep nesting

    func testBuildTreeDeepNesting() {
        let entries = [
            FileEntry(path: "a/b/c/d/e.txt", uncompressedSize: 1, compressedSize: 1, date: "", isDirectory: false),
        ]
        let nodes = buildTree(from: entries)
        var node = nodes[0]
        let names = ["a", "b", "c", "d"]
        for name in names {
            XCTAssertEqual(node.name, name)
            XCTAssertTrue(node.isDirectory)
            node = node.children![0]
        }
        XCTAssertEqual(node.name, "e.txt")
        XCTAssertFalse(node.isDirectory)
    }

    // MARK: – buildTree – entry with no path components is skipped

    func testBuildTreeSkipsEmptyPath() {
        let entries = [
            FileEntry(path: "", uncompressedSize: 0, compressedSize: 0, date: "", isDirectory: false),
            FileEntry(path: "real.txt", uncompressedSize: 1, compressedSize: 1, date: "", isDirectory: false),
        ]
        let nodes = buildTree(from: entries)
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes[0].name, "real.txt")
    }

    // MARK: – ArchiveInfo

    func testArchiveInfoProperties() {
        let entries = [
            FileEntry(path: "a.txt", uncompressedSize: 100, compressedSize: 60, date: "2024-01-01", isDirectory: false),
        ]
        let info = ArchiveInfo(entries: entries, fileName: "my.zip", fileSize: 500)
        XCTAssertEqual(info.fileName, "my.zip")
        XCTAssertEqual(info.fileSize, 500)
        XCTAssertEqual(info.entries.count, 1)
        XCTAssertEqual(info.entries[0].path, "a.txt")
    }
}
