import Foundation
import XCTest
@testable import NotebookCore

/// Writes prototype files the way the former legacy writer did: notebook.json
/// and recovery.json as complete snapshots (the first save used the same bytes).
enum LegacyFixture {
    static func write(_ primary: Notebook, recovery: Notebook? = nil, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bytes = try JSONEncoder().encode(primary)
        try (recovery.map { try JSONEncoder().encode($0) } ?? bytes).write(to: directory.appendingPathComponent("recovery.json"))
        try bytes.write(to: directory.appendingPathComponent("notebook.json"))
    }
}

/// The app only reads the prototype files (for the one-time package migration).
final class NotebookStoreTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    func testRoundTripIncludesPDFDrawingAndUnicodeText() throws {
        let directory = try temporaryDirectory()
        var notebook = Notebook()
        notebook.pdf = Data([1, 2, 3])
        notebook.pages[0].drawing = Data([5, 6, 7])
        notebook.pages[0].text = "Äquivalenz: 🖊️\nzweite Zeile"
        try LegacyFixture.write(notebook, to: directory)
        let store = NotebookStore(directory: directory)
        XCTAssertEqual(try store.load(), notebook)
        XCTAssertFalse(store.recovered)
    }

    func testTruncatedPrimaryRecoversPreviousCompleteSnapshot() throws {
        let directory = try temporaryDirectory()
        var first = Notebook()
        first.pages[0].text = "erster Stand"
        var second = first
        second.pages[0].text = "zweiter Stand"
        try LegacyFixture.write(second, recovery: first, to: directory)
        try Data("{".utf8).write(to: directory.appendingPathComponent("notebook.json"))
        let reopened = NotebookStore(directory: directory)
        XCTAssertEqual(try reopened.load(), first)
        XCTAssertTrue(reopened.recovered)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("notebook.json")), Data("{".utf8))
    }

    func testTwoCorruptCopiesArePreserved() throws {
        let directory = try temporaryDirectory()
        let corrupt = Data("broken".utf8)
        for name in ["notebook.json", "recovery.json"] {
            try corrupt.write(to: directory.appendingPathComponent(name))
        }
        XCTAssertThrowsError(try NotebookStore(directory: directory).load())
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("notebook.json")), corrupt)
    }

    func testRecoveryCopyAloneIsLoadedAsRecovered() throws {
        let directory = try temporaryDirectory()
        let notebook = Notebook()
        try LegacyFixture.write(notebook, to: directory)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("notebook.json"))
        let store = NotebookStore(directory: directory)
        XCTAssertEqual(try store.load(), notebook)
        XCTAssertTrue(store.recovered)
    }

    func testUnsupportedVersionsAndEmptyPagesAreRejected() throws {
        var notebook = Notebook()
        notebook.schemaVersion = Notebook.currentSchemaVersion + 1
        XCTAssertThrowsError(try Notebook.decode(JSONEncoder().encode(notebook)))
        notebook.schemaVersion = 1
        notebook.pages = []
        XCTAssertThrowsError(try Notebook.decode(JSONEncoder().encode(notebook)))
    }

    func testDuplicatePageIDsAreRejectedAndReorderingKeepsContent() throws {
        var notebook = Notebook()
        notebook.pages[0].text = "erste Seite"
        let originalID = notebook.pages[0].id
        notebook.pages.append(notebook.pages[0])
        XCTAssertThrowsError(try Notebook.decode(JSONEncoder().encode(notebook)))
        notebook.pages[1].id = UUID()
        notebook.pages[1].text = "zweite Seite"
        notebook.pages.reverse()
        let decoded = try Notebook.decode(JSONEncoder().encode(notebook))
        XCTAssertEqual(decoded.pages.first { $0.id == originalID }?.text, "erste Seite")
    }

    func testNewerPrimarySchemaDoesNotSilentlyFallBackToOlderRecovery() throws {
        let directory = try temporaryDirectory()
        try LegacyFixture.write(Notebook(), to: directory)
        let newer = Data("{\"schemaVersion\":99}".utf8)
        try newer.write(to: directory.appendingPathComponent("notebook.json"))
        XCTAssertThrowsError(try NotebookStore(directory: directory).load()) { error in
            guard case StorageError.unsupportedSchema(99) = error else {
                return XCTFail("Expected unsupported schema, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("notebook.json")), newer)
    }

    func testEmptyDirectoryStartsBlankWithoutWritingFiles() throws {
        let directory = try temporaryDirectory()
        XCTAssertEqual(try NotebookStore(directory: directory).load().pages.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }
}
