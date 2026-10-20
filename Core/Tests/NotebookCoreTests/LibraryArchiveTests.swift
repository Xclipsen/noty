import Foundation
import XCTest
@testable import NotebookCore

final class LibraryArchiveTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func fixture() -> LibraryBundle {
        var value = LibrarySnapshot()
        let folder = LibraryItem(title: "Steuerrecht")
        let sub = LibraryItem(title: "Übungen", parentID: folder.id)
        var first = Notebook(); first.title = "ÄÖÜ ß"; first.pages[0].text = "Original"; first.pdf = Data([1, 2, 3])
        first.pages[0].drawing = Data([4, 5, 6])
        var second = Notebook(); second.title = "Papierkorb"; second.pages[0].text = "Auch erhalten"
        var a = LibraryItem(id: first.id, title: first.title, parentID: sub.id, source: .legacyMain)
        a.favorite = true; a.lastOpened = Date(timeIntervalSince1970: 123_456)
        var b = LibraryItem(id: second.id, title: second.title, parentID: folder.id, source: .restored)
        b.deletedAt = Date(timeIntervalSince1970: 234_567)
        value.items = [folder, sub, a, b]
        var toolbar = ToolbarPreferences(); toolbar.dock = .right
        toolbar.presets = [InkPreset(tool: .pen, color: InkColor(0.1, 0.2, 0.7), width: 3)]
        return LibraryBundle(snapshot: value, documents: [first, second], toolbar: toolbar)
    }

    private func transformHeader(_ data: Data, _ change: (inout [String: Any]) -> Void) throws -> Data {
        let length = Int(data.dropFirst(8).prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        var header = try JSONSerialization.jsonObject(with: Data(data.dropFirst(12).prefix(length))) as! [String: Any]
        change(&header)
        let encoded = try JSONSerialization.data(withJSONObject: header)
        let count = UInt32(encoded.count)
        var result = LibraryArchive.magic
        result.append(contentsOf: [UInt8(count >> 24), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)])
        result.append(encoded); result.append(data.dropFirst(12 + length)); return result
    }

    func testCompleteArchivePreservesOrderFoldersTrashEveryLayerAndPreferences() throws {
        let bundle = fixture()
        let encoded = try LibraryArchive.encode(bundle)
        XCTAssertEqual(try LibraryArchive.decode(encoded), bundle)
        // Non-zero Data slice indices must not change header offsets.
        var prefix = Data([0, 0, 0]); prefix.append(encoded)
        XCTAssertEqual(try LibraryArchive.decode(prefix.dropFirst(3)), bundle)
    }

    func testIncompleteDuplicateExtraOrMismatchedDocumentsCannotBeExported() throws {
        var bundle = fixture(); bundle.documents.removeLast()
        XCTAssertThrowsError(try LibraryArchive.encode(bundle))
        bundle = fixture(); bundle.documents.append(bundle.documents[0])
        XCTAssertThrowsError(try LibraryArchive.encode(bundle))
        bundle = fixture(); bundle.documents.append(Notebook())
        XCTAssertThrowsError(try LibraryArchive.encode(bundle))
        bundle = fixture(); bundle.documents[0].title = "Falscher Name"
        XCTAssertThrowsError(try LibraryArchive.encode(bundle))
    }

    func testDamagedNotebookIsRejectedBeforeRestore() throws {
        var encoded = try LibraryArchive.encode(fixture())
        encoded[encoded.count - 1] ^= 1
        XCTAssertThrowsError(try LibraryArchive.decode(encoded)) { error in
            guard case BackupError.checksumMismatch = error else { return XCTFail("Expected checksum failure") }
        }
    }

    func testTruncatedTrailingDataOrHugeEntryLengthsAreRejected() throws {
        let encoded = try LibraryArchive.encode(fixture())
        XCTAssertThrowsError(try LibraryArchive.decode(encoded.dropLast()))
        XCTAssertThrowsError(try LibraryArchive.decode(encoded + Data([0])))
        let huge = try transformHeader(encoded) { header in
            var entries = header["entries"] as! [[String: Any]]
            entries[0]["byteCount"] = Int.max; header["entries"] = entries
        }
        XCTAssertThrowsError(try LibraryArchive.decode(huge))
        XCTAssertThrowsError(try LibraryArchive.decode(LibraryArchive.magic + Data([255, 255, 255, 255])))
    }

    func testFutureArchiveVersionUnknownAlgorithmAndPathLikeKindsAreRejected() throws {
        let data = try LibraryArchive.encode(fixture())
        let future = try transformHeader(data) { $0["libraryBackupVersion"] = 99 }
        XCTAssertThrowsError(try LibraryArchive.decode(future)) { error in
            guard case LibraryArchiveError.unsupported(99) = error else { return XCTFail("future archive not protected") }
        }
        let algorithm = try transformHeader(data) { $0["checksumAlgorithm"] = "none" }
        XCTAssertThrowsError(try LibraryArchive.decode(algorithm))
        let path = try transformHeader(data) { header in
            var entries = header["entries"] as! [[String: Any]]
            entries[2]["kind"] = "../../outside.json"; header["entries"] = entries
        }
        XCTAssertThrowsError(try LibraryArchive.decode(path))
    }

    func testDuplicateOrIncorrectManifestDocumentIdentityIsRejected() throws {
        let data = try LibraryArchive.encode(fixture())
        let duplicate = try transformHeader(data) { header in
            var entries = header["entries"] as! [[String: Any]]
            entries[3]["id"] = entries[2]["id"]; header["entries"] = entries
        }
        XCTAssertThrowsError(try LibraryArchive.decode(duplicate))
        let wrongID = try transformHeader(data) { header in
            var entries = header["entries"] as! [[String: Any]]
            entries[2]["id"] = UUID().uuidString; header["entries"] = entries
        }
        XCTAssertThrowsError(try LibraryArchive.decode(wrongID))
    }

    func testRestorePublishesSeparateLibraryAndEditsCannotChangeSource() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent("Original")
        var original = Notebook(); original.title = "Hauptheft"; original.pages[0].text = "erhalten"
        try RevisionStore(directory: sourceRoot).save(original)
        let source = LibraryStore(root: sourceRoot); _ = try await source.load()
        let folderID = try await source.createFolder(title: "Fach", parentID: nil).items.last!.id
        _ = try await source.move(original.id, to: folderID)
        let bundle = try await source.backupBundle()
        let file = root.appendingPathComponent("input.notylibrary")
        try LibraryArchive.encode(bundle).write(to: file)
        let before = try Data(contentsOf: sourceRoot.appendingPathComponent("manifest.json"))
        let manager = WorkspaceStore(root: root.appendingPathComponent("Workspaces"))
        let prepared = try await manager.prepareRestore(file: file)
        let empty = try await manager.list(); XCTAssertTrue(empty.workspaces.isEmpty)
        let workspace = try await manager.commitRestore(prepared, title: "Test-Restore")
        let destination = try await manager.directory(for: workspace.id)
        let restored = LibraryStore(root: destination)
        let loaded = try await restored.load()
        XCTAssertEqual(loaded.snapshot.items.map(\.id), bundle.snapshot.items.map(\.id))
        XCTAssertEqual(loaded.snapshot.items.last?.parentID, folderID)
        let copiedURL = try await restored.documentURL(id: original.id)
        var edited = original; edited.pages[0].text += " Kopie"
        try RevisionStore(directory: copiedURL).save(edited)
        XCTAssertEqual(try RevisionStore(directory: sourceRoot).load(), original)
        XCTAssertEqual(try Data(contentsOf: sourceRoot.appendingPathComponent("manifest.json")), before)
        XCTAssertEqual(try RevisionStore(directory: copiedURL).load(), edited)
        let fresh = try await WorkspaceStore(root: root.appendingPathComponent("Workspaces")).list()
        XCTAssertEqual(fresh.workspaces.map(\.id), [workspace.id])
    }

    func testEmptyLibraryAndTrashRestoreAsCompleteSeparateWorkspace() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manager = WorkspaceStore(root: root.appendingPathComponent("Workspaces"))
        for bundle in [LibraryBundle(snapshot: LibrarySnapshot(), documents: []), fixture()] {
            let file = root.appendingPathComponent("input.notylibrary")
            try LibraryArchive.encode(bundle).write(to: file)
            let prepared = try await manager.prepareRestore(file: file)
            let published = try await manager.commitRestore(prepared, title: "Kopie")
            let directory = try await manager.directory(for: published.id)
            let restored = try await LibraryStore(root: directory).backupBundle()
            XCTAssertEqual(restored.documents, bundle.documents)
            XCTAssertEqual(restored.snapshot.items.map(\.deletedAt), bundle.snapshot.items.map(\.deletedAt))
            XCTAssertEqual(restored.toolbar, bundle.toolbar)
        }
    }

    func testChangedStageAndReplayCannotPublishAnotherWorkspace() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("input.notylibrary")
        let data = try LibraryArchive.encode(fixture()); try data.write(to: file)
        let workspaces = root.appendingPathComponent("Workspaces")
        let manager = WorkspaceStore(root: workspaces)
        let prepared = try await manager.prepareRestore(file: file)
        let staged = workspaces.appendingPathComponent("Staging/\(prepared.id.uuidString)/input.notylibrary")
        try (data + Data([0])).write(to: staged)
        do { _ = try await manager.commitRestore(prepared, title: "Kaputt"); XCTFail("modified stage accepted") } catch { }
        let empty = try await manager.list(); XCTAssertTrue(empty.workspaces.isEmpty)
        try data.write(to: staged)
        _ = try await manager.commitRestore(prepared, title: "Okay")
        do { _ = try await manager.commitRestore(prepared, title: "Replay"); XCTFail("replayed token") } catch { }
        let one = try await manager.list(); XCTAssertEqual(one.workspaces.count, 1)
    }

    func testPublishFailureKeepsStagedDocumentsAndExistingDestinationUntouched() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("input.notylibrary")
        try LibraryArchive.encode(fixture()).write(to: file)
        let workspaces = root.appendingPathComponent("Workspaces")
        let manager = WorkspaceStore(root: workspaces)
        let prepared = try await manager.prepareRestore(file: file)
        let destination = workspaces.appendingPathComponent("Areas/\(prepared.id.uuidString)")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let sentinel = destination.appendingPathComponent("protected")
        try Data([9, 8, 7]).write(to: sentinel)
        do { _ = try await manager.commitRestore(prepared, title: "Blocked"); XCTFail("overwritten") }
        catch LibraryArchiveError.destinationExists { }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data([9, 8, 7]))
        let stage = workspaces.appendingPathComponent("Staging/\(prepared.id.uuidString)/Data")
        let readback = try await LibraryStore(root: stage).backupBundle()
        XCTAssertEqual(readback.documents, try LibraryArchive.decode(Data(contentsOf: file)).documents)
    }

    func testUnreadableOrMissingDocumentAbortsFullExportRatherThanOmittingIt() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root); _ = try await store.load()
        let notebook = Notebook(); _ = try await store.createDocument(notebook, parentID: nil)
        let directory = try await store.documentURL(id: notebook.id)
        try Data("broken".utf8).write(to: directory.appendingPathComponent("manifest.json"))
        do { _ = try await store.backupBundle(); XCTFail("partial backup accepted") } catch { }
        try FileManager.default.removeItem(at: directory)
        do { _ = try await store.backupBundle(); XCTFail("missing document omitted") } catch { }
    }

    func testPopulateRefusesAnyExistingRootAndPreservesOriginalBytes() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let original = Notebook(); try RevisionStore(directory: root).save(original)
        let bytes = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        do { try await LibraryStore(root: root).populateEmpty(fixture()); XCTFail("existing root overwritten") }
        catch LibraryArchiveError.destinationExists { }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("manifest.json")), bytes)
    }

    func testRecoveredOlderDocumentCannotBeSilentlyExportedAsCurrentLibrary() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(root: root); _ = try await library.load()
        var notebook = Notebook(); notebook.pages[0].text = "älter"
        _ = try await library.createDocument(notebook, parentID: nil)
        let directory = try await library.documentURL(id: notebook.id)
        notebook.pages[0].text = "neuer"
        try RevisionStore(directory: directory).save(notebook)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("manifest.json"))) as! [String: Any]
        let entries = manifest["revisions"] as! [[String: Any]]
        let latest = directory.appendingPathComponent("Revisions/\(entries[0]["file"] as! String)")
        try Data("damaged".utf8).write(to: latest)
        do { _ = try await library.backupBundle(); XCTFail("silently backed up older content") }
        catch LibraryArchiveError.incomplete { }
    }

    func testSymlinkInRestoreStageIsRejectedEvenWhenBytesWouldMatch() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("input.notylibrary")
        try LibraryArchive.encode(fixture()).write(to: file)
        let workspaces = root.appendingPathComponent("Workspaces")
        let manager = WorkspaceStore(root: workspaces)
        let prepared = try await manager.prepareRestore(file: file)
        let staged = workspaces.appendingPathComponent("Staging/\(prepared.id.uuidString)/input.notylibrary")
        try FileManager.default.removeItem(at: staged)
        try FileManager.default.createSymbolicLink(at: staged, withDestinationURL: file)
        do { _ = try await manager.commitRestore(prepared, title: "Symlink"); XCTFail("symlink accepted") }
        catch BackupError.invalidStaging { }
        let result = try await manager.list(); XCTAssertTrue(result.workspaces.isEmpty)
    }

    func testIndependentTestAreasHaveDifferentDocumentIDsAndSettings() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let manager = WorkspaceStore(root: root)
        let a = try await manager.createTest(title: "A")
        let b = try await manager.createTest(title: "B")
        let firstRoot = try await manager.directory(for: a.id)
        let secondRoot = try await manager.directory(for: b.id)
        let first = try await LibraryStore(root: firstRoot).backupBundle()
        let second = try await LibraryStore(root: secondRoot).backupBundle()
        XCTAssertTrue(Set(first.snapshot.items.map(\.id)).isDisjoint(with: second.snapshot.items.map(\.id)))
        var preferences = first.toolbar; preferences.dock = .floating; preferences.fingerDrawing = true
        try await ToolbarPreferenceStore(root: firstRoot).save(preferences, revision: 1)
        let untouched = try await ToolbarPreferenceStore(root: secondRoot).load()
        XCTAssertEqual(untouched.0, ToolbarPreferences())
    }
}
