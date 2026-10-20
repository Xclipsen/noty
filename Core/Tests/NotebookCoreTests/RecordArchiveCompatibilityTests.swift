import Foundation
import XCTest
@testable import NotebookCore

/// C3 moved the streaming machinery (sink, source, StreamingCRC32,
/// BoundedFile) into RecordArchive.swift without any format change. The golden
/// archives below were written by the code before that refactor (commit
/// efd8ace); they must stay readable. Since C5 the app writes format 2; the
/// format-1 writers (`encodeVersion1`, `writeVersion1`) remain for fixtures and
/// must still give exactly these bytes.
///
/// Encoders without `.sortedKeys` (library manifest, single backup) emit keys in
/// Dictionary order, which Swift seeds per process. The golden bytes were
/// therefore produced with `SWIFT_DETERMINISTIC_HASHING=1`; only such a run can
/// compare them exactly (`testExactBytesUnderDeterministicHashing`). Every run
/// compares them structurally: identical lengths, offsets and sorted chunks,
/// JSON-equal headers and payloads.
final class RecordArchiveCompatibilityTests: XCTestCase {
    static let createdAt = Date(timeIntervalSince1970: 1_700_000_000)

    static func uuid(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))! }

    static func notebooks() -> [Notebook] {
        var first = Notebook()
        first.schemaVersion = 5; first.id = uuid(1); first.title = "Golden Ä"
        first.pages[0].id = uuid(2); first.pages[0].drawing = Data([1, 2, 3, 4, 250])
        first.pages[0].images = [ImageObject(id: uuid(3), data: Data([0x89, 0x50, 0x4e, 0x47, 0, 255]), pixelWidth: 4, pixelHeight: 3,
                                             x: 50.5, y: 60.25, width: 120, height: 90, rotation: 12.5)]
        var second = Notebook()
        second.id = uuid(4); second.title = "Papierkorb"
        second.pages[0].id = uuid(5); second.pages[0].text = "Auch erhalten"
        second.pdf = Data([37, 80, 68, 70])
        return [first, second]
    }

    static func bundle() -> LibraryBundle {
        let documents = notebooks()
        var snapshot = LibrarySnapshot()
        let folder = LibraryItem(id: uuid(10), title: "Steuerrecht")
        var a = LibraryItem(id: documents[0].id, title: documents[0].title, parentID: folder.id, source: .legacyMain)
        a.favorite = true; a.lastOpened = Date(timeIntervalSince1970: 123_456)
        var b = LibraryItem(id: documents[1].id, title: documents[1].title, parentID: folder.id, source: .restored)
        b.deletedAt = Date(timeIntervalSince1970: 234_567)
        snapshot.items = [folder, a, b]
        var toolbar = ToolbarPreferences(); toolbar.dock = .right
        return LibraryBundle(snapshot: snapshot, documents: documents, toolbar: toolbar)
    }

    static let goldenLibrary = Data(base64Encoded: [
        "Tk9UWUxJQgoAAAGqeyJjaGVja3N1bUFsZ29yaXRobSI6ImNyYzMyLWlzby1oZGxjIiwiZW50cmllcyI6W3sia2luZCI6ImluZGV4IiwiYnl0ZU",
        "NvdW50Ijo0NjksImNyYzMyIjoxNjk1OTU3MzM3fSx7ImtpbmQiOiJ0b29sYmFyIiwiYnl0ZUNvdW50IjozNzksImNyYzMyIjoyNDEwMDEyMjIw",
        "fSx7ImtpbmQiOiJub3RlYm9vayIsImJ5dGVDb3VudCI6MzkzLCJjcmMzMiI6MzI3MzQwOTEyLCJpZCI6IjAwMDAwMDAwLTAwMDAtNDAwMC04MD",
        "AwLTAwMDAwMDAwMDAwMSJ9LHsia2luZCI6Im5vdGVib29rIiwiYnl0ZUNvdW50IjoxOTMsImNyYzMyIjo4OTI0MTQ2MTMsImlkIjoiMDAwMDAw",
        "MDAtMDAwMC00MDAwLTgwMDAtMDAwMDAwMDAwMDA0In1dLCJsaWJyYXJ5QmFja3VwVmVyc2lvbiI6MSwiY3JlYXRlZEF0IjoiMjAyMy0xMS0xNF",
        "QyMjoxMzoyMFoifSAgICAgICAgICAgICAgeyJmb3JtYXRWZXJzaW9uIjoxLCJpdGVtcyI6W3siZmF2b3JpdGUiOmZhbHNlLCJpZCI6IjAwMDAw",
        "MDAwLTAwMDAtNDAwMC04MDAwLTAwMDAwMDAwMDAxMCIsInRpdGxlIjoiU3RldWVycmVjaHQifSx7ImZhdm9yaXRlIjp0cnVlLCJpZCI6IjAwMD",
        "AwMDAwLTAwMDAtNDAwMC04MDAwLTAwMDAwMDAwMDAwMSIsImxhc3RPcGVuZWQiOi05NzgxODM3NDQsInBhcmVudElEIjoiMDAwMDAwMDAtMDAw",
        "MC00MDAwLTgwMDAtMDAwMDAwMDAwMDEwIiwic291cmNlIjoibGVnYWN5TWFpbiIsInRpdGxlIjoiR29sZGVuIMOEIn0seyJkZWxldGVkQXQiOi",
        "05NzgwNzI2MzMsImZhdm9yaXRlIjpmYWxzZSwiaWQiOiIwMDAwMDAwMC0wMDAwLTQwMDAtODAwMC0wMDAwMDAwMDAwMDQiLCJwYXJlbnRJRCI6",
        "IjAwMDAwMDAwLTAwMDAtNDAwMC04MDAwLTAwMDAwMDAwMDAxMCIsInNvdXJjZSI6InJlc3RvcmVkIiwidGl0bGUiOiJQYXBpZXJrb3JiIn1dfX",
        "siZG9jayI6InJpZ2h0IiwiZXJhc2VyV2lkdGgiOjE2LCJmaW5nZXJEcmF3aW5nIjpmYWxzZSwiZmxvYXRpbmdYIjowLCJmbG9hdGluZ1kiOjAs",
        "ImZvcm1hdFZlcnNpb24iOjgsIm1hcmtlckNvbG9yIjp7ImFscGhhIjoxLCJibHVlIjowLCJncmVlbiI6MSwicmVkIjoxfSwibWFya2VyV2lkdG",
        "giOjE0LCJvcmRlciI6WyJwZW4iLCJwZW5jaWwiLCJtYXJrZXIiLCJzdHJva2VFcmFzZXIiLCJ0ZXh0Iiwic2VsZWN0aW9uIiwic2hhcGUiLCJp",
        "bWFnZSIsInJlYWQiLCJsYXNlciIsInByZWNpc2lvbkVyYXNlciIsImlua1NlbGVjdGlvbiJdLCJwZW5Db2xvciI6eyJhbHBoYSI6MSwiYmx1ZS",
        "I6MCwiZ3JlZW4iOjAsInJlZCI6MH0sInBlbldpZHRoIjoyLCJwcmVzZXRzIjpbXX17ImlkIjoiMDAwMDAwMDAtMDAwMC00MDAwLTgwMDAtMDAw",
        "MDAwMDAwMDAxIiwicGFnZXMiOlt7ImRyYXdpbmciOiJBUUlEQlBvPSIsImlkIjoiMDAwMDAwMDAtMDAwMC00MDAwLTgwMDAtMDAwMDAwMDAwMD",
        "AyIiwiaW1hZ2VzIjpbeyJjcm9wIjp7ImhlaWdodCI6MSwid2lkdGgiOjEsIngiOjAsInkiOjB9LCJkYXRhIjoiaVZCT1J3RFwvIiwiaGVpZ2h0",
        "Ijo5MCwiaWQiOiIwMDAwMDAwMC0wMDAwLTQwMDAtODAwMC0wMDAwMDAwMDAwMDMiLCJsb2NrZWQiOmZhbHNlLCJwaXhlbEhlaWdodCI6MywicG",
        "l4ZWxXaWR0aCI6NCwicm90YXRpb24iOjEyLjUsIndpZHRoIjoxMjAsIngiOjUwLjUsInkiOjYwLjI1fV0sInRleHQiOiIifV0sInNjaGVtYVZl",
        "cnNpb24iOjUsInRpdGxlIjoiR29sZGVuIMOEIn17ImlkIjoiMDAwMDAwMDAtMDAwMC00MDAwLTgwMDAtMDAwMDAwMDAwMDA0IiwicGFnZXMiOl",
        "t7ImRyYXdpbmciOiIiLCJpZCI6IjAwMDAwMDAwLTAwMDAtNDAwMC04MDAwLTAwMDAwMDAwMDAwNSIsInRleHQiOiJBdWNoIGVyaGFsdGVuIn1d",
        "LCJwZGYiOiJKVkJFUmc9PSIsInNjaGVtYVZlcnNpb24iOjIsInRpdGxlIjoiUGFwaWVya29yYiJ9",
    ].joined())!

    static let goldenBackup = Data(base64Encoded: [
        "Tk9UWUJLUAoAAAD9eyJkb2N1bWVudElEIjoiMDAwMDAwMDAtMDAwMC00MDAwLTgwMDAtMDAwMDAwMDAwMDAxIiwicGF5bG9hZEJ5dGVDb3VudC",
        "I6MzkzLCJjcmVhdGVkQXQiOiIyMDIzLTExLTE0VDIyOjEzOjIwWiIsIm5vdGVib29rU2NoZW1hVmVyc2lvbiI6NSwicGF5bG9hZENSQzMyIjoy",
        "MDg2NTU4MDQsImNoZWNrc3VtQWxnb3JpdGhtIjoiY3JjMzItaXNvLWhkbGMiLCJwYXlsb2FkTmFtZSI6Im5vdGVib29rLmpzb24iLCJiYWNrdX",
        "BGb3JtYXRWZXJzaW9uIjoxfXsicGFnZXMiOlt7InRleHQiOiIiLCJpbWFnZXMiOlt7ImlkIjoiMDAwMDAwMDAtMDAwMC00MDAwLTgwMDAtMDAw",
        "MDAwMDAwMDAzIiwiY3JvcCI6eyJ4IjowLCJoZWlnaHQiOjEsIndpZHRoIjoxLCJ5IjowfSwibG9ja2VkIjpmYWxzZSwicGl4ZWxIZWlnaHQiOj",
        "MsImhlaWdodCI6OTAsInBpeGVsV2lkdGgiOjQsInJvdGF0aW9uIjoxMi41LCJkYXRhIjoiaVZCT1J3RFwvIiwieCI6NTAuNSwieSI6NjAuMjUs",
        "IndpZHRoIjoxMjB9XSwiZHJhd2luZyI6IkFRSURCUG89IiwiaWQiOiIwMDAwMDAwMC0wMDAwLTQwMDAtODAwMC0wMDAwMDAwMDAwMDIifV0sIn",
        "RpdGxlIjoiR29sZGVuIMOEIiwic2NoZW1hVmVyc2lvbiI6NSwiaWQiOiIwMDAwMDAwMC0wMDAwLTQwMDAtODAwMC0wMDAwMDAwMDAwMDEifQ==",
    ].joined())!

    private var deterministicHashing: Bool { ProcessInfo.processInfo.environment["SWIFT_DETERMINISTIC_HASHING"] != nil }

    private func header(_ data: Data) -> (length: Int, json: Data, rest: Data) {
        let length = Int(data.dropFirst(8).prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        return (length, Data(data.dropFirst(12).prefix(length)), Data(data.dropFirst(12 + length)))
    }
    private func object(_ data: Data) throws -> NSDictionary {
        try JSONSerialization.jsonObject(with: data) as! NSDictionary
    }
    private func trimmed(_ data: Data) -> Data {
        var data = data
        while data.last == 0x20 { data.removeLast() }
        return data
    }

    /// Same magic, reserved manifest length, padding and byte-identical chunks;
    /// the manifest is JSON-equal.
    private func assertEquivalentLibrary(_ written: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        let golden = Self.goldenLibrary
        XCTAssertEqual(written.count, golden.count, file: file, line: line)
        XCTAssertEqual(written.prefix(12), golden.prefix(12), "magic and reserved length", file: file, line: line)
        let a = header(written), b = header(golden)
        XCTAssertEqual(a.rest, b.rest, "index, toolbar and notebook chunks", file: file, line: line)
        XCTAssertEqual(a.json.count - trimmed(a.json).count, b.json.count - trimmed(b.json).count, "padding", file: file, line: line)
        XCTAssertEqual(try object(trimmed(a.json)), try object(trimmed(b.json)), file: file, line: line)
    }

    private func assertEquivalentBackup(_ written: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        let golden = Self.goldenBackup
        XCTAssertEqual(written.prefix(8), golden.prefix(8), file: file, line: line)
        let a = header(written), b = header(golden)
        XCTAssertEqual(a.rest.count, b.rest.count, file: file, line: line)
        XCTAssertEqual(try object(a.rest), try object(b.rest), "payload", file: file, line: line)
        let headerA = try object(a.json).mutableCopy() as! NSMutableDictionary, headerB = try object(b.json).mutableCopy() as! NSMutableDictionary
        // The payload CRC follows the payload's key order.
        XCTAssertEqual((headerA["payloadCRC32"] as? NSNumber)?.uint32Value, StreamingCRC32.checksum(a.rest), file: file, line: line)
        headerA.removeObject(forKey: "payloadCRC32"); headerB.removeObject(forKey: "payloadCRC32")
        XCTAssertEqual(headerA, headerB, file: file, line: line)
    }

    func testGoldenArchivesStayReadable() throws {
        XCTAssertEqual(try LibraryArchive.decode(Self.goldenLibrary), Self.bundle())
        let backup = try BackupArchive.decode(Self.goldenBackup)
        XCTAssertFalse(backup.isLegacyJSON)
        XCTAssertEqual(backup.document, Self.notebooks()[0])

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("golden-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("golden.notylibrary")
        try Self.goldenLibrary.write(to: url)
        var visited: [UUID] = []
        let summary = try LibraryArchive.verify(url) { visited.append($0.id) }
        XCTAssertEqual(visited, Self.notebooks().map(\.id))
        XCTAssertEqual(summary.file, LibraryArchiveFileInfo(byteCount: 1_872, crc32: 579_206_857)) // zlib.crc32
        XCTAssertEqual(summary.createdAt, Self.createdAt)
        XCTAssertEqual(summary.snapshot, Self.bundle().snapshot)
        XCTAssertEqual(summary.notebooks.map(\.byteCount), [393, 193])
        XCTAssertEqual(try BoundedFile.checksum(url), summary.file)
        XCTAssertEqual(StreamingCRC32.checksum(Self.goldenBackup), 2_648_843_916) // zlib.crc32
        XCTAssertEqual(Self.goldenBackup.count, 658)
    }

    func testWritingTheSameValuesGivesEquivalentBytes() throws {
        try assertEquivalentLibrary(LibraryArchive.encodeVersion1(Self.bundle(), createdAt: Self.createdAt))
        try assertEquivalentBackup(BackupArchive.encodeVersion1(Self.notebooks()[0], createdAt: Self.createdAt))
    }

    /// The format-1 streaming file path (FileSink, reserved manifest patched in place).
    func testStreamingFileWriteGivesEquivalentBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("golden-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var packages: [UUID: URL] = [:]
        for document in Self.notebooks() {
            let package = root.appendingPathComponent(document.id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            try RevisionStore(directory: package).save(document)
            packages[document.id] = package
        }
        let bundle = Self.bundle()
        let plan = LibraryBackupPlan(snapshot: bundle.snapshot, toolbar: bundle.toolbar, packages: packages)
        let url = root.appendingPathComponent("written.notylibrary")
        try Data().write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        var sink = FileSink(handle: handle)
        _ = try LibraryArchive.writeVersion1(snapshot: plan.snapshot, toolbar: plan.toolbar, documents: plan.documents,
                                             createdAt: Self.createdAt, into: &sink, limits: .standard,
                                             document: plan.committedNotebook)
        try handle.close()
        let written = try Data(contentsOf: url)
        try assertEquivalentLibrary(written)
        XCTAssertEqual(try LibraryArchive.verify(url).file, try BoundedFile.checksum(url))
        if deterministicHashing { XCTAssertEqual(written, Self.goldenLibrary) }
    }

    func testExactBytesUnderDeterministicHashing() throws {
        try XCTSkipUnless(deterministicHashing, "exact comparison needs SWIFT_DETERMINISTIC_HASHING=1")
        XCTAssertEqual(try LibraryArchive.encodeVersion1(Self.bundle(), createdAt: Self.createdAt), Self.goldenLibrary)
        XCTAssertEqual(try BackupArchive.encodeVersion1(Self.notebooks()[0], createdAt: Self.createdAt), Self.goldenBackup)
    }
}
