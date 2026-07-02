import XCTest
@testable import Peep

final class ArchiveReaderTests: XCTestCase {

    // MARK: – Unsupported format

    func testUnsupportedFormatThrows() async throws {
        let url = try TestFixtureBuilder.unsupportedURL()
        do {
            _ = try await ArchiveReader.read(url: url)
            XCTFail("Expected unsupportedFormat error")
        } catch let error as ArchiveError {
            guard case .unsupportedFormat(let ext) = error else {
                return XCTFail("Wrong ArchiveError case: \(error)")
            }
            XCTAssertEqual(ext, "xyz")
        }
    }

    // MARK: – ZIP

    func testZipRead() async throws {
        let url = try TestFixtureBuilder.zipURL()
        let info = try await ArchiveReader.read(url: url)

        XCTAssertEqual(info.fileName, "test.zip")
        XCTAssertGreaterThan(info.fileSize, 0)

        let paths = Set(info.entries.map(\.path))
        XCTAssertTrue(paths.contains("hello.txt"), "Expected hello.txt, got: \(paths)")
        XCTAssertTrue(paths.contains("subdir/world.txt"), "Expected subdir/world.txt, got: \(paths)")

        let hello = try XCTUnwrap(info.entries.first { $0.path == "hello.txt" })
        XCTAssertFalse(hello.isDirectory)
        XCTAssertEqual(hello.uncompressedSize, Int64(TestFixtureBuilder.helloContent.count))
    }

    func testZipReadHasDates() async throws {
        let url = try TestFixtureBuilder.zipURL()
        let info = try await ArchiveReader.read(url: url)
        let hello = try XCTUnwrap(info.entries.first { $0.path == "hello.txt" })
        XCTAssertFalse(hello.date.isEmpty, "ZIP entries should have non-empty dates")
        // Verify yyyy-MM-dd format: 10 chars, two hyphens
        XCTAssertEqual(hello.date.count, 10, "Date should be yyyy-MM-dd, got: \(hello.date)")
        XCTAssertEqual(hello.date.filter { $0 == "-" }.count, 2, "Date should have two hyphens, got: \(hello.date)")
    }

    func testZipExtract() async throws {
        let archiveURL = try TestFixtureBuilder.zipURL()
        let dest = try TestFixtureBuilder.makeTempDestDir()
        try await ArchiveReader.extract(from: archiveURL, to: dest)

        let helloURL = dest.appendingPathComponent("hello.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: helloURL.path))
        let data = try Data(contentsOf: helloURL)
        XCTAssertEqual(data, TestFixtureBuilder.helloContent)

        let worldURL = dest.appendingPathComponent("subdir/world.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: worldURL.path))
    }

    func testZipExtractSingleFile() async throws {
        let archiveURL = try TestFixtureBuilder.zipURL()
        let dest = try TestFixtureBuilder.makeTempDestDir()
        try await ArchiveReader.extract(from: archiveURL, paths: ["hello.txt"], to: dest)

        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("hello.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("subdir/world.txt").path))
    }

    func testZipCorruptThrows() async throws {
        let url = try TestFixtureBuilder.corruptZipURL()
        do {
            _ = try await ArchiveReader.read(url: url)
            XCTFail("Expected readFailed error")
        } catch let error as ArchiveError {
            guard case .readFailed = error else {
                return XCTFail("Wrong ArchiveError case: \(error)")
            }
        }
    }

    // MARK: – TAR

    func testTarRead() async throws {
        let url = try TestFixtureBuilder.tarURL()
        let info = try await ArchiveReader.read(url: url)

        XCTAssertEqual(info.fileName, "test.tar")
        let paths = Set(info.entries.map(\.path))
        XCTAssertTrue(paths.contains("hello.txt") || paths.contains("./hello.txt"),
                      "Expected hello.txt, got: \(paths)")
        let hasWorld = paths.contains("subdir/world.txt") || paths.contains("./subdir/world.txt")
        XCTAssertTrue(hasWorld, "Expected subdir/world.txt, got: \(paths)")
    }

    func testTarExtract() async throws {
        let archiveURL = try TestFixtureBuilder.tarURL()
        let dest = try TestFixtureBuilder.makeTempDestDir()
        try await ArchiveReader.extract(from: archiveURL, to: dest)

        let helloURL = dest.appendingPathComponent("hello.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: helloURL.path))
        let data = try Data(contentsOf: helloURL)
        XCTAssertEqual(data, TestFixtureBuilder.helloContent)
    }

    // MARK: – TAR.GZ

    func testTarGzRead() async throws {
        let url = try TestFixtureBuilder.tarGzURL()
        let info = try await ArchiveReader.read(url: url)

        XCTAssertEqual(info.fileName, "test.tar.gz")
        let paths = Set(info.entries.map(\.path))
        XCTAssertTrue(paths.contains("hello.txt") || paths.contains("./hello.txt"),
                      "Expected hello.txt in tar.gz, got: \(paths)")
    }

    func testTarGzExtract() async throws {
        let archiveURL = try TestFixtureBuilder.tarGzURL()
        let dest = try TestFixtureBuilder.makeTempDestDir()
        try await ArchiveReader.extract(from: archiveURL, to: dest)

        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("hello.txt").path))
    }

    // MARK: – TAR.BZ2

    func testTarBz2Read() async throws {
        let url = try TestFixtureBuilder.tarBz2URL()
        let info = try await ArchiveReader.read(url: url)

        XCTAssertEqual(info.fileName, "test.tar.bz2")
        let paths = Set(info.entries.map(\.path))
        XCTAssertTrue(paths.contains("hello.txt") || paths.contains("./hello.txt"),
                      "Expected hello.txt in tar.bz2, got: \(paths)")
    }

    func testTarBz2Extract() async throws {
        let archiveURL = try TestFixtureBuilder.tarBz2URL()
        let dest = try TestFixtureBuilder.makeTempDestDir()
        try await ArchiveReader.extract(from: archiveURL, to: dest)

        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("hello.txt").path))
    }

    // MARK: – 7-Zip

    func testSevenZipReadSucceeds() async throws {
        // Minimal valid empty 7z archive — verifies the parser doesn't crash or throw on valid input
        let url = try TestFixtureBuilder.sevenZipURL()
        let info = try await ArchiveReader.read(url: url)
        XCTAssertEqual(info.fileName, "test.7z")
        // Empty archive has 0 entries by definition
        XCTAssertEqual(info.entries.count, 0)
    }

    // MARK: – TNEF / winmail.dat

    func testTnefRead() async throws {
        let url = try TestFixtureBuilder.tnefURL()
        let info = try await ArchiveReader.read(url: url)

        XCTAssertEqual(info.fileName, "winmail.dat")
        XCTAssertEqual(info.entries.count, 1)
        let entry = info.entries[0]
        XCTAssertEqual(entry.path, "test.txt")
        XCTAssertFalse(entry.isDirectory)
        XCTAssertEqual(entry.uncompressedSize, Int64("Hello from TNEF".utf8.count))
    }

    func testTnefExtract() async throws {
        let archiveURL = try TestFixtureBuilder.tnefURL()
        let dest = try TestFixtureBuilder.makeTempDestDir()
        try await ArchiveReader.extract(from: archiveURL, to: dest)

        let outURL = dest.appendingPathComponent("test.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path))
        let data = try Data(contentsOf: outURL)
        XCTAssertEqual(String(data: data, encoding: .utf8), "Hello from TNEF")
    }

    func testTnefCorruptThrows() async throws {
        let url = try TestFixtureBuilder.corruptTnefURL()
        do {
            _ = try await ArchiveReader.read(url: url)
            XCTFail("Expected readFailed for corrupt TNEF")
        } catch let error as ArchiveError {
            guard case .readFailed = error else {
                return XCTFail("Wrong ArchiveError case: \(error)")
            }
        }
    }

    // MARK: – EML

    func testEmlRead() async throws {
        let url = try TestFixtureBuilder.emlURL()
        let info = try await ArchiveReader.read(url: url)

        XCTAssertEqual(info.fileName, "test.eml")
        XCTAssertGreaterThan(info.entries.count, 0)

        // message.html preview is always the first entry
        XCTAssertEqual(info.entries.first?.path, "message.html")

        // Named attachment should appear
        let paths = info.entries.map(\.path)
        XCTAssertTrue(paths.contains("attachment.txt"), "Expected attachment.txt, got: \(paths)")
    }

    func testEmlExtract() async throws {
        let archiveURL = try TestFixtureBuilder.emlURL()
        let dest = try TestFixtureBuilder.makeTempDestDir()
        try await ArchiveReader.extract(from: archiveURL, to: dest)

        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("message.html").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("attachment.txt").path))
    }

    // MARK: – MSG (OLE2) – error path and cycle safety

    func testMsgCorruptThrows() async throws {
        let url = try TestFixtureBuilder.corruptMsgURL()
        do {
            _ = try await ArchiveReader.read(url: url)
            XCTFail("Expected readFailed for corrupt MSG")
        } catch let error as ArchiveError {
            guard case .readFailed = error else {
                return XCTFail("Wrong ArchiveError case: \(error)")
            }
        }
    }

    func testMsgCyclicDirectoryDoesNotCrash() async throws {
        // Verifies that a well-formed OLE2 file where a directory entry's right-sibling
        // pointer forms a cycle does not cause infinite recursion in siblings().
        // Simply completing this test (without hanging or crashing) is success.
        let url = try TestFixtureBuilder.cyclicMsgURL()
        let info = try await ArchiveReader.read(url: url)
        XCTAssertEqual(info.fileName, "cyclic.msg")
    }

    // MARK: – ArchiveError descriptions

    func testUnsupportedFormatErrorDescription() {
        let error = ArchiveError.unsupportedFormat("xyz")
        let desc = error.errorDescription ?? ""
        XCTAssertTrue(desc.contains("xyz"), "Error description should mention the extension")
    }

    func testReadFailedErrorDescription() {
        let error = ArchiveError.readFailed("something broke")
        let desc = error.errorDescription ?? ""
        XCTAssertTrue(desc.contains("something broke"))
    }

    // MARK: – junkPaths extraction

    func testZipExtractJunkPaths() async throws {
        let archiveURL = try TestFixtureBuilder.zipURL()
        let dest = try TestFixtureBuilder.makeTempDestDir()
        // junkPaths = true: all files extracted flat into dest, no subdirectories preserved
        try await ArchiveReader.extract(from: archiveURL, junkPaths: true, to: dest)

        let hello = dest.appendingPathComponent("hello.txt")
        let world = dest.appendingPathComponent("world.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: hello.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: world.path))
        // The subdir/ should NOT exist as a directory inside dest
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("subdir").path))
    }

    func testTarExtractJunkPaths() async throws {
        let archiveURL = try TestFixtureBuilder.tarURL()
        let dest = try TestFixtureBuilder.makeTempDestDir()
        try await ArchiveReader.extract(from: archiveURL, junkPaths: true, to: dest)

        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("hello.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("world.txt").path))
    }
}
