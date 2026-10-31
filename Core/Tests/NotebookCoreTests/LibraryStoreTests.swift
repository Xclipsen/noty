import Foundation
import XCTest
@testable import NotebookCore

final class LibraryStoreTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    func testMoveIntoTheCurrentFolderKeepsTheOrder() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root)
        _ = try await store.load()
        _ = try await store.createFolder(title: "A", parentID: nil)
        let snapshot = try await store.createFolder(title: "B", parentID: nil)
        let order = snapshot.items.map(\.id)
        let first = try XCTUnwrap(snapshot.items.first(where: { $0.title == "A" }))
        let moved = try await store.move(first.id, to: nil)
        XCTAssertEqual(moved.items.map(\.id), order)
    }

    func testAdoptsMainAndRestoreWithoutChangingAnyDocumentBytesOrIDs() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        var main = Notebook(); main.pages[0].text = "Altbestand ÄÖÜ"
        var copy = main; copy.id = UUID(); copy.pages[0].text = "RESTORE-17"
        try RevisionStore(directory: root).save(main)
        let restored = root.appendingPathComponent("Restores/\(copy.id.uuidString)")
        try RevisionStore(directory: restored).save(copy)
        let original = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        let originalCopy = try Data(contentsOf: restored.appendingPathComponent("manifest.json"))
        let store = LibraryStore(root: root)
        let result = try await store.load()
        XCTAssertEqual(Set(result.snapshot.items.map(\.id)), [main.id, copy.id])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("manifest.json")), original)
        XCTAssertEqual(try Data(contentsOf: restored.appendingPathComponent("manifest.json")), originalCopy)
        let mainURL = try await store.documentURL(id: main.id)
        let copyURL = try await store.documentURL(id: copy.id)
        XCTAssertEqual(mainURL.standardizedFileURL.path, root.standardizedFileURL.path)
        XCTAssertEqual(copyURL.standardizedFileURL.path, restored.standardizedFileURL.path)
        XCTAssertEqual(try RevisionStore(directory: copyURL).load(), copy)
        let fresh = try await LibraryStore(root: root).load()
        XCTAssertEqual(fresh.snapshot, result.snapshot)
    }

    func testNestedMoveRejectsCycleAndPreservesIndexAcrossRestart() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root); _ = try await store.load()
        let a = try await store.createFolder(title: "Steuerrecht", parentID: nil).items[0].id
        let b = try await store.createFolder(title: "Arbeitsblätter", parentID: a).items[1].id
        do { _ = try await store.move(a, to: b); XCTFail("cycle accepted") }
        catch LibraryError.invalidDestination { }
        let renamed = try await store.rename(b, title: "  Übungen  ")
        XCTAssertEqual(renamed.items[1].title, "Übungen")
        let fresh = try await LibraryStore(root: root).load()
        XCTAssertEqual(fresh.snapshot, renamed)
    }

    func testFolderTrashHidesDescendantsAndRestorePreservesContentAndOrder() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root); _ = try await store.load()
        let folder = try await store.createFolder(title: "Rechnungswesen", parentID: nil).items[0].id
        var book = Notebook(); book.title = "Test"; book.pages[0].drawing = Data([1, 2, 3]); book.pages[0].text = "erhalten"
        _ = try await store.createDocument(book, parentID: folder)
        let url = try await store.documentURL(id: book.id)
        let before = try Data(contentsOf: url.appendingPathComponent("manifest.json"))
        let trashed = try await store.trash(folder)
        XCTAssertTrue(trashed.isTrashed(book.id))
        do { _ = try await store.documentURL(id: book.id); XCTFail("trashed child open") }
        catch LibraryError.unavailable { }
        let restored = try await store.restore(folder)
        XCTAssertFalse(restored.isTrashed(book.id))
        XCTAssertEqual(restored.items.map(\.id), [folder, book.id])
        XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent("manifest.json")), before)
        XCTAssertEqual(try RevisionStore(directory: url).load(), book)
    }

    func testRestoreIntoTrashedParentUsesRootWithoutRestoringOtherDeletedChildren() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root); _ = try await store.load()
        let folder = try await store.createFolder(title: "Fach", parentID: nil).items[0].id
        let child = try await store.createFolder(title: "Alt", parentID: folder).items[1].id
        _ = try await store.trash(child); _ = try await store.trash(folder)
        let restored = try await store.restore(child)
        XCTAssertNil(restored.items.first { $0.id == child }?.parentID)
        XCTAssertFalse(restored.isTrashed(child)); XCTAssertTrue(restored.isTrashed(folder))
    }

    func testManualReorderChecksExactSiblingsAndSurvivesReload() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root); _ = try await store.load()
        let a = try await store.createFolder(title: "A", parentID: nil).items[0].id
        let b = try await store.createFolder(title: "B", parentID: nil).items[1].id
        let nested = try await store.createFolder(title: "Kind", parentID: a).items[2].id
        do { _ = try await store.reorder([b, nested], parentID: nil); XCTFail("foreign sibling accepted") }
        catch LibraryError.unavailable { }
        _ = try await store.reorder([b, a], parentID: nil)
        let fresh = try await LibraryStore(root: root).load()
        XCTAssertEqual(fresh.snapshot.children(of: nil).map(\.id), [b, a])
    }

    func testIndexWriteFailurePreservesLastGoodValueAndNewDocumentIsRediscovered() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root); _ = try await store.load()
        let original = try await store.createFolder(title: "Original", parentID: nil)
        let index = root.appendingPathComponent("Library/index.json")
        let bytes = try Data(contentsOf: index)
        // Replace only our temporary test file with a directory to force atomic write failure.
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        var book = Notebook(); book.title = "Unterbrochen"
        do { _ = try await store.createDocument(book, parentID: nil); XCTFail("commit should fail") } catch { }
        XCTAssertEqual(try RevisionStore(directory: root.appendingPathComponent("Library/Documents/\(book.id.uuidString)")).load(), book)
        try FileManager.default.removeItem(at: index)
        try bytes.write(to: index)
        let fresh = try await LibraryStore(root: root).load()
        XCTAssertEqual(fresh.snapshot.items.first, original.items.first)
        XCTAssertEqual(fresh.snapshot.items.last?.id, book.id)
    }

    func testCorruptPrimaryFallsBackButTwoCorruptIndicesNeverResetLibrary() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root); _ = try await store.load()
        let first = try await store.createFolder(title: "A", parentID: nil)
        _ = try await store.createFolder(title: "B", parentID: nil)
        let index = root.appendingPathComponent("Library/index.json")
        let bad = Data("broken".utf8)
        try bad.write(to: index)
        let fallback = try await LibraryStore(root: root).load()
        XCTAssertTrue(fallback.recovered); XCTAssertEqual(fallback.snapshot, first)
        try bad.write(to: root.appendingPathComponent("Library/index-previous.json"))
        do { _ = try await LibraryStore(root: root).load(); XCTFail("empty fallback") }
        catch LibraryError.invalidIndex { }
        XCTAssertEqual(try Data(contentsOf: index), bad)
    }

    func testFutureVersionNeverFallsBackOrRewritesIndex() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root); _ = try await store.load()
        _ = try await store.createFolder(title: "A", parentID: nil)
        _ = try await store.createFolder(title: "B", parentID: nil)
        let index = root.appendingPathComponent("Library/index.json")
        let future = Data("{\"formatVersion\":99}".utf8); try future.write(to: index)
        do { _ = try await LibraryStore(root: root).load(); XCTFail("future overwritten") }
        catch LibraryError.unsupportedVersion(99) { }
        XCTAssertEqual(try Data(contentsOf: index), future)
    }

    func testChecksumDetectsValidJSONEditAndCatalogRejectsParentCycles() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root); _ = try await store.load()
        _ = try await store.createFolder(title: "A", parentID: nil)
        let index = root.appendingPathComponent("Library/index.json")
        var envelope = try JSONSerialization.jsonObject(with: Data(contentsOf: index)) as! [String: Any]
        var payload = Data(base64Encoded: envelope["payload"] as! String)!
        payload = Data(String(decoding: payload, as: UTF8.self).replacingOccurrences(of: "\"A\"", with: "\"B\"").utf8)
        envelope["payload"] = payload.base64EncodedString()
        try JSONSerialization.data(withJSONObject: envelope).write(to: index)
        do { _ = try await LibraryStore(root: root).load(); XCTFail("CRC not checked") }
        catch LibraryError.invalidIndex { }
        var value = LibrarySnapshot()
        var folder = LibraryItem(title: "Zyklus"); folder.parentID = folder.id; value.items = [folder]
        XCTAssertThrowsError(try value.validate())
    }

    func testConcurrentMutationsUseSingleOwnerAndKeepEveryEntry() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root); _ = try await store.load()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for n in 1...25 { group.addTask { _ = try await store.createFolder(title: "Fach \(n)", parentID: nil) } }
            try await group.waitForAll()
        }
        let fresh = try await LibraryStore(root: root).load()
        XCTAssertEqual(fresh.snapshot.items.count, 25)
        XCTAssertEqual(Set(fresh.snapshot.items.map(\.title)).count, 25)
    }

    func testRestoresCreatedLaterAreFoundAndTrashedOnesStayTrashed() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root); _ = try await store.load()
        let copy = Notebook()
        try RevisionStore(directory: root.appendingPathComponent("Restores/\(copy.id.uuidString)")).save(copy)
        let discovered = try await store.load(); XCTAssertEqual(discovered.snapshot.items.count, 1)
        _ = try await store.trash(copy.id)
        let refreshed = try await store.load()
        XCTAssertTrue(refreshed.snapshot.isTrashed(copy.id)); XCTAssertTrue(refreshed.snapshot.children(of: nil).isEmpty)
    }

    func testSymlinkDocumentNeverOpensAndInvalidNamesCannotBeCommitted() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = self.root(); defer { try? FileManager.default.removeItem(at: outside) }
        let store = LibraryStore(root: root); _ = try await store.load()
        let book = Notebook(); _ = try await store.createDocument(book, parentID: nil)
        let url = try await store.documentURL(id: book.id)
        try FileManager.default.moveItem(at: url, to: outside)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: outside)
        do { _ = try await store.documentURL(id: book.id); XCTFail("symlink accepted") } catch { }
        do { _ = try await store.createFolder(title: "\n \n", parentID: nil); XCTFail("empty name") }
        catch LibraryError.invalidTitle { }
        do { _ = try await store.createFolder(title: "Fach\nNeu", parentID: nil); XCTFail("multiline") }
        catch LibraryError.invalidTitle { }
    }

    func testDuplicateCopiesImageAssetsAndLeavesTheOriginalPackageUntouched() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root); _ = try await store.load()
        let photo = Data((0..<4_000).map { UInt8(truncatingIfNeeded: $0 &* 17) })
        var book = try Notebook.blank(title: "Bildheft").preparedForTextEditing()
        _ = try await store.createDocument(book, parentID: nil)
        let sourceURL = try await store.documentURL(id: book.id)
        let writer = RevisionStore(directory: sourceURL)
        book = try writer.load()
        _ = try writer.assets.stage(photo)
        try book.replaceImages([.test(bytes: photo), .test(bytes: photo, x: 300)], pageID: book.pages[0].id)
        try writer.save(book)
        let before = try LegacyNotebookJSON.inventory(sourceURL)
        let result = try await store.duplicateDocument(book.id, title: "Bildheft Kopie")
        let copyURL = try await store.documentURL(id: result.id)
        let hash = ImageAssetReference(of: photo).sha256
        XCTAssertEqual(try Data(contentsOf: copyURL.appendingPathComponent("Assets/\(hash)")), photo, "copied and verified")
        XCTAssertEqual(try LegacyNotebookJSON.inventory(sourceURL), before, "the original is only read")
        // Removing the image in the copy never touches the original's asset.
        let copyStore = RevisionStore(directory: copyURL)
        var copy = try copyStore.load()
        XCTAssertEqual(copy.allImages.map(\.asset), book.allImages.map(\.asset))
        try copy.replaceImages([], pageID: copy.pages[0].id)
        try copyStore.save(copy)
        XCTAssertEqual(try LegacyNotebookJSON.inventory(sourceURL), before)
        XCTAssertEqual(try RevisionStore(directory: sourceURL).load(), book)

        // A not yet migrated schema-11 package: the copy is schema 12 with an
        // asset of the embedded original; the original keeps its exact bytes.
        var legacy = try Notebook.blank(title: "Altheft").preparedForTextEditing()
        _ = try await store.createDocument(legacy, parentID: nil)
        let legacyURL = try await store.documentURL(id: legacy.id)
        try legacy.replaceImages([.test(bytes: photo)], pageID: legacy.pages[0].id)
        try LegacyNotebookJSON.writePackage(legacyURL, bytes: LegacyNotebookJSON.encode(legacy, schemaVersion: 11, originals: [hash: photo]))
        let legacyBefore = try LegacyNotebookJSON.inventory(legacyURL)
        let migrated = try await store.duplicateDocument(legacy.id, title: "Altheft Kopie")
        let migratedURL = try await store.documentURL(id: migrated.id)
        let reopened = RevisionStore(directory: migratedURL, readOnly: true)
        XCTAssertEqual(try reopened.load().schemaVersion, 12)
        XCTAssertEqual(try Data(contentsOf: migratedURL.appendingPathComponent("Assets/\(hash)")), photo)
        XCTAssertEqual(try LegacyNotebookJSON.inventory(legacyURL), legacyBefore, "no Assets/, no Migrations/ in the original")
    }

    func testDuplicateCreatesIndependentPackageBehindOriginalAndLeavesSourceBytes() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root); _ = try await store.load()
        let folder = try await store.createFolder(title: "Fach", parentID: nil).items[0].id
        var book = Notebook(); book.title = "Heft"; book.pages[0].drawing = Data([4, 5, 6]); book.pages[0].text = "Inhalt"
        _ = try await store.createDocument(book, parentID: folder)
        let after = try await store.createFolder(title: "Danach", parentID: folder).items[2].id
        _ = try await store.rename(book.id, title: "Umbenannt")
        let sourceURL = try await store.documentURL(id: book.id)
        let before = try Data(contentsOf: sourceURL.appendingPathComponent("manifest.json"))
        let result = try await store.duplicateDocument(book.id, title: "Umbenannt Kopie")
        XCTAssertNotEqual(result.id, book.id)
        XCTAssertEqual(result.snapshot.children(of: folder).map(\.id), [book.id, result.id, after])
        let item = try XCTUnwrap(result.snapshot.items.first { $0.id == result.id })
        XCTAssertEqual(item.source, .library); XCTAssertFalse(item.favorite); XCTAssertNil(item.lastOpened)
        let copyURL = try await store.documentURL(id: result.id)
        XCTAssertNotEqual(copyURL.standardizedFileURL.path, sourceURL.standardizedFileURL.path)
        let copy = try RevisionStore(directory: copyURL).load()
        var expected = book; expected.id = result.id; expected.title = "Umbenannt Kopie"
        XCTAssertEqual(copy, expected)
        XCTAssertEqual(try Data(contentsOf: sourceURL.appendingPathComponent("manifest.json")), before)
        XCTAssertEqual(try RevisionStore(directory: sourceURL).load(), book)
        do { _ = try await store.duplicateDocument(folder, title: "Ordner Kopie"); XCTFail("folder duplicated") }
        catch LibraryError.unavailable { }
        _ = try await store.trash(book.id)
        do { _ = try await store.duplicateDocument(book.id, title: "X"); XCTFail("trashed duplicated") }
        catch LibraryError.unavailable { }
        let current = try await store.load()
        let fresh = try await LibraryStore(root: root).load()
        XCTAssertEqual(fresh.snapshot, current.snapshot)
    }

    func testPlaceMovesAndPositionsInOneCommitAndRejectsCyclesAndForeignAnchors() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root); _ = try await store.load()
        let a = try await store.createFolder(title: "A", parentID: nil).items[0].id
        let b = try await store.createFolder(title: "B", parentID: nil).items[1].id
        let c = try await store.createFolder(title: "C", parentID: nil).items[2].id
        let inner = try await store.createFolder(title: "Innen", parentID: a).items[3].id
        var moved = try await store.place(c, in: nil, before: a)
        XCTAssertEqual(moved.children(of: nil).map(\.id), [c, a, b])
        moved = try await store.place(b, in: a, before: inner)
        XCTAssertEqual(moved.children(of: a).map(\.id), [b, inner])
        XCTAssertEqual(moved.children(of: nil).map(\.id), [c, a])
        moved = try await store.place(c, in: a, before: nil)
        XCTAssertEqual(moved.children(of: a).map(\.id), [b, inner, c])
        do { _ = try await store.place(a, in: inner, before: nil); XCTFail("cycle accepted") }
        catch LibraryError.invalidDestination { }
        do { _ = try await store.place(b, in: nil, before: inner); XCTFail("foreign anchor accepted") }
        catch LibraryError.unavailable { }
        let fresh = try await LibraryStore(root: root).load()
        XCTAssertEqual(fresh.snapshot, moved)
    }
}
