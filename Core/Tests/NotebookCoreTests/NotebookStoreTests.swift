import Foundation
import XCTest
@testable import NotebookCore

final class NotebookStoreTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    func testRoundTripIncludesPDFDrawingAndUnicodeText() throws {
        let directory = try temporaryDirectory()
        let store = NotebookStore(directory: directory)
        _ = try store.load()
        var notebook = Notebook()
        notebook.pdf = Data([1, 2, 3])
        notebook.pages[0].drawing = Data([5, 6, 7])
        notebook.pages[0].text = "Äquivalenz: 🖊️\nzweite Zeile"
        try store.save(notebook)
        XCTAssertEqual(try NotebookStore(directory: directory).load(), notebook)
    }

    func testTruncatedPrimaryRecoversPreviousCompleteSnapshot() throws {
        let directory = try temporaryDirectory()
        let store = NotebookStore(directory: directory)
        var first = try store.load()
        first.pages[0].text = "erster Stand"
        try store.save(first)
        var second = first
        second.pages[0].text = "zweiter Stand"
        try store.save(second)
        try Data("{".utf8).write(to: directory.appendingPathComponent("notebook.json"))
        let reopened = NotebookStore(directory: directory)
        XCTAssertEqual(try reopened.load(), first)
        XCTAssertTrue(reopened.recovered)
        try reopened.save(first)
        XCTAssertEqual(try NotebookStore(directory: directory).load(), first)
        let recovery = try Data(contentsOf: directory.appendingPathComponent("recovery.json"))
        XCTAssertEqual(try Notebook.decode(recovery), first)
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

    func testFirstSaveAlsoCreatesRecoveryCopy() throws {
        let directory = try temporaryDirectory()
        let store = NotebookStore(directory: directory)
        let notebook = try store.load()
        try store.save(notebook)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("notebook.json"))
        XCTAssertEqual(try NotebookStore(directory: directory).load(), notebook)
    }

    func testUnsupportedVersionsAndEmptyPagesAreRejected() throws {
        var notebook = Notebook()
        notebook.schemaVersion = Notebook.currentSchemaVersion + 1
        XCTAssertThrowsError(try Notebook.decode(JSONEncoder().encode(notebook)))
        notebook.schemaVersion = 1
        notebook.pages = []
        XCTAssertThrowsError(try Notebook.decode(JSONEncoder().encode(notebook)))
    }

    func testWriteFailureIsReported() throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("file")
        try Data().write(to: file)
        let store = NotebookStore(directory: file)
        XCTAssertThrowsError(try store.save(Notebook()))
    }

    func testRecoveryWriteFailurePreservesPrimaryAndAllowsRetry() throws {
        let directory = try temporaryDirectory()
        let store = NotebookStore(directory: directory)
        let acknowledged = Notebook()
        try store.save(acknowledged)
        let primary = directory.appendingPathComponent("notebook.json")
        let recovery = directory.appendingPathComponent("recovery.json")
        let originalBytes = try Data(contentsOf: primary)
        // An actual filesystem error at the recovery destination, without root
        // permissions or a fake writer that assumes how atomic writes work.
        try FileManager.default.removeItem(at: recovery)
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: false)
        var edited = acknowledged
        edited.pages[0].text = "noch ungesicherte Änderung"
        XCTAssertThrowsError(try store.save(edited))
        XCTAssertEqual(try Data(contentsOf: primary), originalBytes)
        XCTAssertEqual(try NotebookStore(directory: directory).load(), acknowledged)

        try FileManager.default.removeItem(at: recovery)
        try store.save(edited)
        XCTAssertEqual(try NotebookStore(directory: directory).load(), edited)
        XCTAssertEqual(try Notebook.decode(Data(contentsOf: recovery)), acknowledged)
    }

    func testPrimaryCommitFailureRecoversLastAcknowledgedSnapshotAndAllowsRetry() throws {
        let directory = try temporaryDirectory()
        let store = NotebookStore(directory: directory)
        let first = Notebook()
        try store.save(first)
        var acknowledged = first
        acknowledged.pages[0].text = "zuletzt bestätigter Stand"
        try store.save(acknowledged)
        let primary = directory.appendingPathComponent("notebook.json")
        let recovery = directory.appendingPathComponent("recovery.json")
        // Block only the final commit. Recovery can be written successfully.
        try FileManager.default.moveItem(at: primary, to: directory.appendingPathComponent("preserved-primary.json"))
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: false)
        var edited = acknowledged
        edited.pages[0].text = "nach dem Fehler weiter im Speicher"
        XCTAssertThrowsError(try store.save(edited))
        XCTAssertEqual(try Notebook.decode(Data(contentsOf: recovery)), acknowledged)
        let reopened = NotebookStore(directory: directory)
        XCTAssertEqual(try reopened.load(), acknowledged)
        XCTAssertTrue(reopened.recovered)

        try FileManager.default.removeItem(at: primary)
        try store.save(edited)
        XCTAssertEqual(try NotebookStore(directory: directory).load(), edited)
        XCTAssertEqual(try Notebook.decode(Data(contentsOf: recovery)), acknowledged)
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
        let store = NotebookStore(directory: directory)
        try store.save(Notebook())
        let newer = Data("{\"schemaVersion\":99}".utf8)
        try newer.write(to: directory.appendingPathComponent("notebook.json"))
        XCTAssertThrowsError(try NotebookStore(directory: directory).load()) { error in
            guard case StorageError.unsupportedSchema(99) = error else {
                return XCTFail("Expected unsupported schema, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("notebook.json")), newer)
    }

    func testUnchangedFlushKeepsOlderRecoveryPoint() throws {
        let directory = try temporaryDirectory()
        let store = NotebookStore(directory: directory)
        let first = Notebook()
        try store.save(first)
        var second = first
        second.pages[0].text = "neuer Stand"
        try store.save(second)
        try store.save(second)
        let recovery = try Data(contentsOf: directory.appendingPathComponent("recovery.json"))
        XCTAssertEqual(try Notebook.decode(recovery), first)
    }

    func testLegacyUpgradeArchivesExactOldBytesAndKeepsIDsAndCoordinates() throws {
        let directory = try temporaryDirectory()
        var legacy = Notebook()
        legacy.schemaVersion = 1
        legacy.pages[0].drawing = Data([1, 2, 3])
        legacy.pages[0].text = "Altstand"
        let oldBytes = try JSONEncoder().encode(legacy)
        try oldBytes.write(to: directory.appendingPathComponent("notebook.json"))
        let store = NotebookStore(directory: directory)
        var upgraded = try store.load()
        XCTAssertNil(upgraded.pages[0].geometry)
        upgraded.schemaVersion = Notebook.currentSchemaVersion
        try store.save(upgraded)
        XCTAssertEqual(upgraded.pages, legacy.pages)
        XCTAssertEqual(upgraded.id, legacy.id)
        let folders = try FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("Migrations"), includingPropertiesForKeys: nil)
        XCTAssertEqual(folders.count, 1)
        XCTAssertEqual(try Data(contentsOf: folders[0].appendingPathComponent("notebook-v1.json")), oldBytes)
        XCTAssertEqual(try NotebookStore(directory: directory).load(), upgraded)
    }

    func testFailedMigrationArchiveDoesNotModifyLegacySnapshot() throws {
        let directory = try temporaryDirectory()
        var legacy = Notebook()
        legacy.schemaVersion = 1
        let original = try JSONEncoder().encode(legacy)
        try original.write(to: directory.appendingPathComponent("notebook.json"))
        try Data("blocks archive directory".utf8).write(to: directory.appendingPathComponent("Migrations"))
        let store = NotebookStore(directory: directory)
        var upgraded = try store.load()
        upgraded.schemaVersion = Notebook.currentSchemaVersion
        XCTAssertThrowsError(try store.save(upgraded))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("notebook.json")), original)
        XCTAssertEqual(try NotebookStore(directory: directory).load(), legacy)
    }
}
