import Foundation
import XCTest
@testable import NotebookCore

final class BackupArchiveTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    private func sample() -> Notebook {
        var document = Notebook()
        document.title = "Rechnungswesen"
        document.pdf = Data([1, 2, 3, 4, 5])
        document.pages[0].drawing = Data([6, 7, 8])
        document.pages[0].text = "ÄÖÜ ß – Test 🖊️"
        var second = Page()
        second.text = "zweite Seite"
        document.pages.append(second)
        return document
    }

    private func rewriteHeader(_ archive: Data, change: (inout [String: Any]) -> Void) throws -> Data {
        let length = Int(archive.dropFirst(8).prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        var header = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(archive.dropFirst(12).prefix(length))) as? [String: Any])
        change(&header)
        let newHeader = try JSONSerialization.data(withJSONObject: header)
        let count = UInt32(newHeader.count)
        var result = BackupArchive.magic
        result.append(contentsOf: [UInt8((count >> 24) & 255), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)])
        result.append(newHeader)
        result.append(archive.dropFirst(12 + length))
        return result
    }

    func testRoundTripPreservesEveryEditableLayerAndStablePageIdentity() throws {
        let document = sample()
        let archive = try BackupArchive.encode(document)
        let restored = try BackupArchive.decode(archive)
        XCTAssertEqual(restored.document, document)
        XCTAssertFalse(restored.isLegacyJSON)
        // A Data slice may have a nonzero startIndex; the parser must not assume 0.
        var prefixed = Data([0, 0, 0])
        prefixed.append(archive)
        XCTAssertEqual(try BackupArchive.decode(prefixed.dropFirst(3)).document, document)
    }

    func testTruncationExtraBytesAndImpossibleHeaderLengthsAreRejected() throws {
        let archive = try BackupArchive.encode(sample())
        for count in [0, 7, 8, 11, 12, archive.count - 1] {
            XCTAssertThrowsError(try BackupArchive.decode(Data(archive.prefix(count))))
        }
        var extra = archive
        extra.append(0)
        XCTAssertThrowsError(try BackupArchive.decode(extra))
        var excessive = BackupArchive.magic
        excessive.append(contentsOf: [255, 255, 255, 255])
        XCTAssertThrowsError(try BackupArchive.decode(excessive))
    }

    func testChangedPayloadWithStillValidJSONFailsChecksum() throws {
        var document = sample()
        document.title = "AAA"
        let archive = try BackupArchive.encode(document)
        let location = try XCTUnwrap(archive.range(of: Data("AAA".utf8)))
        var corrupt = archive
        corrupt.replaceSubrange(location, with: Data("BBB".utf8))
        XCTAssertThrowsError(try BackupArchive.decode(corrupt)) { error in
            guard case BackupError.checksumMismatch = error else { return XCTFail("\(error)") }
        }
    }

    func testFutureBackupVersionIsExplicitlyRejected() throws {
        let archive = try rewriteHeader(BackupArchive.encodeVersion1(sample())) { $0["backupFormatVersion"] = 99 }
        XCTAssertThrowsError(try BackupArchive.decode(archive)) { error in
            guard case BackupError.unsupportedVersion(99) = error else { return XCTFail("\(error)") }
        }
    }

    func testManifestIdentitySchemaAlgorithmAndPayloadLengthMustMatch() throws {
        let archive = try BackupArchive.encodeVersion1(sample())
        let modifications: [(inout [String: Any]) -> Void] = [
            { $0["documentID"] = UUID().uuidString },
            { $0["notebookSchemaVersion"] = 99 },
            { $0["checksumAlgorithm"] = "none" },
            { $0["payloadByteCount"] = -1 },
            { $0["payloadByteCount"] = BackupArchive.maximumBytes + 1 }
        ]
        for change in modifications {
            XCTAssertThrowsError(try BackupArchive.decode(rewriteHeader(archive, change: change)))
        }
    }

    func testNoArchiveSuppliedPathsAreAccepted() throws {
        let archive = try BackupArchive.encodeVersion1(sample())
        for path in ["../notebook.json", "/tmp/notebook.json", "subdir/notebook.json", "..\\notebook.json"] {
            let unsafe = try rewriteHeader(archive) { $0["payloadName"] = path }
            XCTAssertThrowsError(try BackupArchive.decode(unsafe))
        }
    }

    func testLegacyJSONIsMarkedAndUnknownLegacySchemaRemainsProtected() throws {
        var document = sample()
        document.schemaVersion = 1
        let decoded = try BackupArchive.decode(JSONEncoder().encode(document))
        XCTAssertEqual(decoded.document, document)
        XCTAssertTrue(decoded.isLegacyJSON)
        XCTAssertThrowsError(try BackupArchive.decode(Data("{\"schemaVersion\":99}".utf8))) { error in
            guard case StorageError.unsupportedSchema(99) = error else { return XCTFail("\(error)") }
        }
    }

    func testBoundedFileReaderRejectsOversizedInputWithoutAppendingIt() throws {
        let root = try directory()
        let file = root.appendingPathComponent("backup")
        let bytes = Data(repeating: 42, count: 100)
        try bytes.write(to: file)
        XCTAssertEqual(try BackupArchive.readBounded(file, limit: 100), bytes)
        XCTAssertThrowsError(try BackupArchive.readBounded(file, limit: 99)) { error in
            guard case BackupError.sizeLimit = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try BackupArchive.readBounded(file, limit: 0))
    }

    func testRestoreIntoEmptyIndependentStoreCanBeEditedAndReopenedWithoutChangingCurrentNotebook() async throws {
        let root = try directory()
        let repository = NotebookRepository(directory: root)
        let current = sample()
        try await repository.save(current, revision: 1)
        let manifest = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        let file = root.appendingPathComponent("external.notybackup")
        try await repository.backup(current, to: file)
        let prepared = try await repository.prepareRestore(from: file)
        XCTAssertNotEqual(prepared.document.id, current.id)
        XCTAssertEqual(prepared.document.pages, current.pages)
        let restored = try await repository.commitRestore(prepared)
        var edited = try RevisionStore(directory: restored.directory).load()
        XCTAssertEqual(edited, prepared.document)
        edited.pages[0].text += " – nach Restore bearbeitet"
        edited.pages[0].drawing.append(9)
        try RevisionStore(directory: restored.directory).save(edited)
        XCTAssertEqual(try RevisionStore(directory: restored.directory).load(), edited)
        let (unchanged, _) = try await repository.load()
        XCTAssertEqual(unchanged, current)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("manifest.json")), manifest)
        let catalog = try await repository.restoredCopies()
        XCTAssertEqual(catalog.notebooks.map(\.id), [restored.id])
        XCTAssertEqual(catalog.unreadableCount, 0)
    }

    func testCorruptArchiveCreatesNoStagingAndNeverChangesExistingStore() async throws {
        let root = try directory()
        let repository = NotebookRepository(directory: root)
        let document = sample()
        try await repository.save(document, revision: 1)
        let file = root.appendingPathComponent("broken.notybackup")
        try Data("invalid backup".utf8).write(to: file)
        do {
            _ = try await repository.prepareRestore(from: file)
            XCTFail("Corruption must fail")
        } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("BackupStaging").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Restores").path))
        let (unchanged, _) = try await repository.load()
        XCTAssertEqual(unchanged, document)
    }

    func testModifiedStagingAndReplayedTokenAreRejected() async throws {
        let root = try directory()
        let repository = NotebookRepository(directory: root)
        let file = root.appendingPathComponent("external.notybackup")
        try BackupArchive.encode(sample()).write(to: file)
        let prepared = try await repository.prepareRestore(from: file)
        let staged = root.appendingPathComponent("BackupStaging/\(prepared.id.uuidString)/input.notybackup")
        let original = try Data(contentsOf: staged)
        try Data("corruption".utf8).write(to: staged)
        do {
            _ = try await repository.commitRestore(prepared)
            XCTFail("Changed staging must fail")
        } catch { }
        try original.write(to: staged)
        _ = try await repository.commitRestore(prepared)
        // Recreate the staged bytes: the already committed destination still
        // prevents a token replay from replacing an existing restored notebook.
        try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try original.write(to: staged)
        do {
            _ = try await repository.commitRestore(prepared)
            XCTFail("Token replay must fail")
        } catch { }
    }

    func testFailedRestoreWritePreservesCurrentAndKeepsStagingForDiagnosis() async throws {
        let root = try directory()
        let repository = NotebookRepository(directory: root)
        let current = sample()
        try await repository.save(current, revision: 1)
        let file = root.appendingPathComponent("external.notybackup")
        try BackupArchive.encode(current).write(to: file)
        let prepared = try await repository.prepareRestore(from: file)
        try Data("blocks destination directory".utf8).write(to: root.appendingPathComponent("Restores"))
        do {
            _ = try await repository.commitRestore(prepared)
            XCTFail("Blocked write must fail")
        } catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("BackupStaging/\(prepared.id.uuidString)/input.notybackup").path))
        let (unchanged, _) = try await repository.load()
        XCTAssertEqual(unchanged, current)
    }

    func testRepeatedRestoreCreatesDistinctCopiesWhileNewerAutosaveRemainsCurrent() async throws {
        let root = try directory()
        let repository = NotebookRepository(directory: root)
        let current = sample()
        try await repository.save(current, revision: 1)
        let file = root.appendingPathComponent("external.notybackup")
        try BackupArchive.encode(current).write(to: file)
        let first = try await repository.prepareRestore(from: file)
        var newer = current
        newer.pages[0].text += " neuer Hauptstand"
        try await repository.save(newer, revision: 2)
        let a = try await repository.commitRestore(first)
        let second = try await repository.prepareRestore(from: file)
        let b = try await repository.commitRestore(second)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertNotEqual(a.directory, b.directory)
        try await repository.save(current, revision: 1)
        let (loaded, _) = try await repository.load()
        XCTAssertEqual(loaded, newer)
        let catalog = try await repository.restoredCopies()
        XCTAssertEqual(Set(catalog.notebooks.map(\.id)), Set([a.id, b.id]))
    }

    func testUnreadableRestoredCopyIsReportedAndItsFilesArePreserved() async throws {
        let root = try directory()
        let repository = NotebookRepository(directory: root)
        let broken = root.appendingPathComponent("Restores/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        let original = Data("broken manifest".utf8)
        let manifest = broken.appendingPathComponent("manifest.json")
        try original.write(to: manifest)
        let catalog = try await repository.restoredCopies()
        XCTAssertEqual(catalog.unreadableCount, 1)
        XCTAssertTrue(catalog.notebooks.isEmpty)
        XCTAssertEqual(try Data(contentsOf: manifest), original)
    }

    func testIdenticallyNamedCopiesExposeDistinctPagePreviewsForFindingSavedChanges() async throws {
        let root = try directory()
        let repository = NotebookRepository(directory: root)
        let original = sample()
        let archive = root.appendingPathComponent("external.notybackup")
        try BackupArchive.encode(original).write(to: archive)
        let a = try await repository.commitRestore(repository.prepareRestore(from: archive))
        let b = try await repository.commitRestore(repository.prepareRestore(from: archive))
        var changed = try RevisionStore(directory: a.directory).load()
        changed.pages[1].text = "RESTORE-17\nEindeutige Änderung"
        try RevisionStore(directory: a.directory).save(changed)
        let catalog = try await repository.restoredCopies()
        XCTAssertEqual(catalog.notebooks.count, 2)
        XCTAssertEqual(Set(catalog.notebooks.map(\.title)).count, 1)
        let found = try XCTUnwrap(catalog.notebooks.first { $0.textPages.contains { $0.text.contains("RESTORE-17") } })
        XCTAssertEqual(found.id, a.id)
        let page = try XCTUnwrap(found.textPages.first { $0.text.contains("RESTORE-17") })
        XCTAssertEqual(page.id, original.pages[1].id)
        XCTAssertEqual(page.pageNumber, 2)
        XCTAssertNotNil(found.modifiedAt)
        XCTAssertEqual(try RevisionStore(directory: b.directory).load().pages, original.pages)
    }

    func testCopyPreviewDoesNotChangeSavedUnicodeOrOverflowingText() async throws {
        let root = try directory()
        let repository = NotebookRepository(directory: root)
        var original = sample()
        original.pages[1].text = String(repeating: "ÄÖÜ 🖊️\n", count: 100)
        let archive = root.appendingPathComponent("external.notybackup")
        try BackupArchive.encode(original).write(to: archive)
        let prepared = try await repository.prepareRestore(from: archive)
        let restored = try await repository.commitRestore(prepared)
        let catalog = try await repository.restoredCopies()
        let preview = try XCTUnwrap(catalog.notebooks.first?.textPages.first { $0.pageNumber == 2 })
        XCTAssertLessThanOrEqual(preview.text.count, 160)
        XCTAssertFalse(preview.text.contains("\n"))
        XCTAssertEqual(try RevisionStore(directory: restored.directory).load().pages[1].text, original.pages[1].text)
    }
}
