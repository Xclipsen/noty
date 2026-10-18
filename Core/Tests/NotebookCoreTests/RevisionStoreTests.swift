import Foundation
import XCTest
@testable import NotebookCore

final class RevisionStoreTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private func manifest(_ root: URL) throws -> RevisionManifest {
        try JSONDecoder().decode(RevisionManifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
    }

    func testChecksumKnownVectors() {
        XCTAssertEqual(SnapshotChecksum.crc32(Data()), 0)
        XCTAssertEqual(SnapshotChecksum.crc32(Data("123456789".utf8)), 0xcbf43926)
        XCTAssertEqual(SnapshotChecksum.crc32(Data("The quick brown fox jumps over the lazy dog".utf8)), 0x414fa339)
    }

    func testImmutableRevisionsKeepThreeStatesAndBoundPhysicalHistory() throws {
        let root = try directory()
        let store = RevisionStore(directory: root)
        var document = Notebook()
        try store.save(document)
        let first = try manifest(root).revisions[0]
        let firstURL = root.appendingPathComponent("Revisions/" + first.file)
        let firstBytes = try Data(contentsOf: firstURL)
        document.pages[0].text = "zweiter Stand"
        try store.save(document)
        XCTAssertEqual(try Data(contentsOf: firstURL), firstBytes)
        for revision in 3...12 {
            document.pages[0].text = "Stand \(revision)"
            try store.save(document)
        }
        XCTAssertEqual(try manifest(root).revisions.count, 3)
        XCTAssertLessThanOrEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Revisions").path).count, 4)
        XCTAssertEqual(try RevisionStore(directory: root).load(), document)
    }

    func testValidJSONWithChangedBytesFailsChecksumAndRecoversOlderState() throws {
        let root = try directory()
        let store = RevisionStore(directory: root)
        var first = Notebook()
        first.pages[0].text = "AAA"
        try store.save(first)
        var second = first
        second.pages[0].text = "BBB"
        try store.save(second)
        let latest = root.appendingPathComponent("Revisions/" + (try manifest(root).revisions[0].file))
        let bytes = try String(contentsOf: latest, encoding: .utf8).replacingOccurrences(of: "BBB", with: "CCC")
        try Data(bytes.utf8).write(to: latest)
        let recovered = RevisionStore(directory: root)
        XCTAssertEqual(try recovered.load(), first)
        XCTAssertTrue(recovered.recovered)
        try recovered.save(first)
        XCTAssertEqual(try RevisionStore(directory: root).load(), first)
        XCTAssertFalse(recovered.recovered)
    }

    func testTruncatedManifestUsesPreviousCompleteManifest() throws {
        let root = try directory()
        let store = RevisionStore(directory: root)
        let first = Notebook()
        try store.save(first)
        var second = first
        second.pages[0].text = "neuer"
        try store.save(second)
        try Data("{".utf8).write(to: root.appendingPathComponent("manifest.json"))
        let recovered = RevisionStore(directory: root)
        XCTAssertEqual(try recovered.load(), first)
        XCTAssertTrue(recovered.recovered)
    }

    func testUncommittedRevisionDoesNotBecomeCurrentAndIsCollectedAfterCommit() throws {
        let root = try directory()
        let store = RevisionStore(directory: root)
        let first = Notebook()
        try store.save(first)
        var uncommitted = first
        uncommitted.pages[0].text = "nie bestätigter Stand"
        let orphan = root.appendingPathComponent("Revisions/" + UUID().uuidString + ".json")
        try JSONEncoder().encode(uncommitted).write(to: orphan)
        let reopened = RevisionStore(directory: root)
        XCTAssertEqual(try reopened.load(), first)
        var next = first
        next.pages[0].text = "nächster bestätigter Stand"
        try reopened.save(next)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testFailedManifestCommitKeepsAcknowledgedStateAndRetryWorks() throws {
        let root = try directory()
        let store = RevisionStore(directory: root)
        let acknowledged = Notebook()
        try store.save(acknowledged)
        let primary = root.appendingPathComponent("manifest.json")
        try FileManager.default.moveItem(at: primary, to: root.appendingPathComponent("preserved-manifest.json"))
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: false)
        var edited = acknowledged
        edited.pages[0].text = "ungesichert"
        XCTAssertThrowsError(try store.save(edited))
        let reopened = RevisionStore(directory: root)
        XCTAssertEqual(try reopened.load(), acknowledged)
        XCTAssertTrue(reopened.recovered)
        try FileManager.default.removeItem(at: primary)
        try store.save(edited)
        XCTAssertEqual(try RevisionStore(directory: root).load(), edited)
    }

    func testLegacyMigrationLeavesExactOriginalFilesAndKeepsIDsAndGeometry() throws {
        let root = try directory()
        var legacy = Notebook()
        legacy.schemaVersion = 1
        legacy.pages[0].drawing = Data([1, 2, 3])
        legacy.pages[0].text = "Ältere Notiz"
        let oldStore = NotebookStore(directory: root)
        try oldStore.save(legacy)
        let original = try Data(contentsOf: root.appendingPathComponent("notebook.json"))
        let store = RevisionStore(directory: root)
        var upgraded = try store.load()
        upgraded.schemaVersion = Notebook.currentSchemaVersion
        try store.save(upgraded)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("notebook.json")), original)
        XCTAssertEqual(try RevisionStore(directory: root).load(), upgraded)
        XCTAssertEqual(upgraded.pages, legacy.pages)
        XCTAssertEqual(upgraded.id, legacy.id)
        XCTAssertEqual(try manifest(root).revisions.count, 2)
    }

    func testFutureManifestVersionDoesNotFallBackOrGetOverwritten() throws {
        let root = try directory()
        let store = RevisionStore(directory: root)
        var document = Notebook()
        try store.save(document)
        document.pages[0].text = "neu"
        try store.save(document)
        let future = Data("{\"formatVersion\":99}".utf8)
        let primary = root.appendingPathComponent("manifest.json")
        try future.write(to: primary)
        let olderApp = RevisionStore(directory: root)
        XCTAssertThrowsError(try olderApp.load()) { error in
            guard case RevisionError.unsupportedFormat(99) = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try olderApp.save(document))
        XCTAssertEqual(try Data(contentsOf: primary), future)
    }

    func testFutureDocumentSchemaDoesNotSilentlyUseOlderRevision() throws {
        let root = try directory()
        let store = RevisionStore(directory: root)
        let first = Notebook()
        try store.save(first)
        var second = first
        second.pages[0].text = "neu"
        try store.save(second)
        var index = try manifest(root)
        let future = Data("{\"schemaVersion\":99}".utf8)
        index.revisions[0].byteCount = future.count
        index.revisions[0].crc32 = SnapshotChecksum.crc32(future)
        try future.write(to: root.appendingPathComponent("Revisions/" + index.revisions[0].file))
        try JSONEncoder().encode(index).write(to: root.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try RevisionStore(directory: root).load()) { error in
            guard case StorageError.unsupportedSchema(99) = error else { return XCTFail("\(error)") }
        }
    }

    func testUnsafePathSymlinkAndOversizedRecordAreRejectedWithoutTouchingFiles() throws {
        let root = try directory()
        let store = RevisionStore(directory: root)
        try store.save(Notebook())
        let index = try manifest(root)
        let primary = root.appendingPathComponent("manifest.json")
        for invalid in ["../notebook.json", "/tmp/notebook.json", "subdir/" + index.revisions[0].file] {
            var unsafe = index
            unsafe.revisions[0].file = invalid
            try JSONEncoder().encode(unsafe).write(to: primary)
            XCTAssertThrowsError(try RevisionStore(directory: root).load())
        }
        var oversized = index
        oversized.revisions[0].byteCount = 200_000_001
        try JSONEncoder().encode(oversized).write(to: primary)
        XCTAssertThrowsError(try RevisionStore(directory: root).load())
        try JSONEncoder().encode(index).write(to: primary)
        let revision = root.appendingPathComponent("Revisions/" + index.revisions[0].file)
        let preserved = root.appendingPathComponent("original.json")
        try FileManager.default.moveItem(at: revision, to: preserved)
        let original = try Data(contentsOf: preserved)
        try FileManager.default.createSymbolicLink(at: revision, withDestinationURL: preserved)
        XCTAssertThrowsError(try RevisionStore(directory: root).load())
        XCTAssertEqual(try Data(contentsOf: preserved), original)
    }

    func testUnchangedFlushDoesNotRotateHistory() throws {
        let root = try directory()
        let store = RevisionStore(directory: root)
        let first = Notebook()
        try store.save(first)
        var second = first
        second.pages[0].text = "neu"
        try store.save(second)
        let bytes = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        try store.save(second)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("manifest.json")), bytes)
    }

    func testFailedPreviousManifestWriteDoesNotChangeCurrentCommit() throws {
        let root = try directory()
        let store = RevisionStore(directory: root)
        let acknowledged = Notebook()
        try store.save(acknowledged)
        let primary = root.appendingPathComponent("manifest.json")
        let bytes = try Data(contentsOf: primary)
        let blocker = root.appendingPathComponent("manifest-previous.json")
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: false)
        var edited = acknowledged
        edited.pages[0].text = "nicht bestätigt"
        XCTAssertThrowsError(try store.save(edited))
        XCTAssertEqual(try Data(contentsOf: primary), bytes)
        XCTAssertEqual(try RevisionStore(directory: root).load(), acknowledged)
        try FileManager.default.removeItem(at: blocker)
        try store.save(edited)
        XCTAssertEqual(try RevisionStore(directory: root).load(), edited)
    }

    func testFailedFirstMigrationCommitRetainsReadableLegacyAndPreviousPointer() throws {
        let root = try directory()
        let legacy = Notebook()
        try NotebookStore(directory: root).save(legacy)
        let bytes = try Data(contentsOf: root.appendingPathComponent("notebook.json"))
        let store = RevisionStore(directory: root)
        _ = try store.load()
        let primary = root.appendingPathComponent("manifest.json")
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: false)
        var edited = legacy
        edited.pages[0].text = "neue Eingabe"
        XCTAssertThrowsError(try store.save(edited))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("notebook.json")), bytes)
        XCTAssertEqual(try RevisionStore(directory: root).load(), legacy)
    }
}
