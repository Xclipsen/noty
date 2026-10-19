import Foundation
import XCTest
@testable import NotebookCore

final class LibraryPurgeTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func book(_ title: String) -> Notebook { var value = Notebook(); value.title = title; value.pages[0].text = title; return value }
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func testPurgeRefusesActiveAndUnknownItemsWithoutChangingAnything() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root); _ = try await store.load()
        let active = book("Aktiv"), trashed = book("Weg")
        _ = try await store.createDocument(active, parentID: nil)
        _ = try await store.createDocument(trashed, parentID: nil)
        let before = try await store.trash(trashed.id)
        let index = try Data(contentsOf: root.appendingPathComponent("Library/index.json"))
        for ids in [[active.id], [trashed.id, active.id], [UUID()]] {
            do { _ = try await store.purge(ids: ids); XCTFail("non-trashed item purged") }
            catch LibraryError.unavailable { }
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Library/index.json")), index)
        XCTAssertTrue(exists(root.appendingPathComponent("Library/Documents/\(trashed.id.uuidString)/manifest.json")))
        let fresh = try await LibraryStore(root: root).load()
        XCTAssertEqual(fresh.snapshot, before)
    }

    func testPurgeRemovesIndexEntryAndPackageAndSurvivesReloadWithoutRediscovery() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root); _ = try await store.load()
        let keep = book("Bleibt"), gone = book("Gelöscht")
        _ = try await store.createDocument(keep, parentID: nil)
        _ = try await store.createDocument(gone, parentID: nil)
        let keepBytes = try Data(contentsOf: root.appendingPathComponent("Library/Documents/\(keep.id.uuidString)/manifest.json"))
        _ = try await store.trash(gone.id)
        let result = try await store.purge(ids: [gone.id])
        XCTAssertEqual(result.purgedIDs, [gone.id]); XCTAssertEqual(result.leftoverDirectories, 0)
        XCTAssertEqual(result.snapshot.items.map(\.id), [keep.id])
        XCTAssertFalse(exists(root.appendingPathComponent("Library/Documents/\(gone.id.uuidString)")))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Library/Purging").path), [])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Library/Documents/\(keep.id.uuidString)/manifest.json")), keepBytes)
        let fresh = try await LibraryStore(root: root).load()
        XCTAssertEqual(fresh.snapshot, result.snapshot); XCTAssertEqual(fresh.unreadableDocuments, 0)
        // The fallback index must not reference the removed package either.
        try FileManager.default.removeItem(at: root.appendingPathComponent("Library/index.json"))
        let fallback = try await LibraryStore(root: root).load()
        XCTAssertTrue(fallback.recovered); XCTAssertEqual(fallback.snapshot.items.map(\.id), [keep.id])
    }

    func testPurgingTrashedFolderPurgesAllDescendantsButNotSiblings() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root); _ = try await store.load()
        let folder = try await store.createFolder(title: "Fach", parentID: nil).items[0].id
        let nested = try await store.createFolder(title: "Alt", parentID: folder).items[1].id
        let inner = book("Innen"), deep = book("Tief"), outside = book("Daneben")
        _ = try await store.createDocument(inner, parentID: folder)
        _ = try await store.createDocument(deep, parentID: nested)
        _ = try await store.createDocument(outside, parentID: nil)
        _ = try await store.trash(deep.id)      // independently trashed descendant
        _ = try await store.trash(folder)
        let result = try await store.purge(ids: [folder])
        XCTAssertEqual(Set(result.purgedIDs), [folder, nested, inner.id, deep.id])
        XCTAssertEqual(result.snapshot.items.map(\.id), [outside.id])
        for id in [inner.id, deep.id] { XCTAssertFalse(exists(root.appendingPathComponent("Library/Documents/\(id.uuidString)"))) }
        XCTAssertTrue(exists(root.appendingPathComponent("Library/Documents/\(outside.id.uuidString)/manifest.json")))
    }

    func testDescendantOfTrashedFolderCanBePurgedAloneAndRestoreOfOthersStillWorks() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root); _ = try await store.load()
        let folder = try await store.createFolder(title: "Fach", parentID: nil).items[0].id
        let a = book("A"), b = book("B")
        _ = try await store.createDocument(a, parentID: folder)
        _ = try await store.createDocument(b, parentID: folder)
        _ = try await store.trash(folder)
        _ = try await store.purge(ids: [a.id])
        let restored = try await store.restore(folder)
        XCTAssertEqual(restored.children(of: folder).map(\.id), [b.id])
        let url = try await store.documentURL(id: b.id)
        XCTAssertEqual(try RevisionStore(directory: url).load(), b)
    }

    func testPurgeNeverFollowsSymlinksOrDeletesOutsideTheLibraryRoot() async throws {
        let root = root(), outside = self.root()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let store = LibraryStore(root: root); _ = try await store.load()
        let target = book("Mit Link")
        _ = try await store.createDocument(target, parentID: nil)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let precious = outside.appendingPathComponent("fremd.txt")
        try Data("fremd".utf8).write(to: precious)
        let package = root.appendingPathComponent("Library/Documents/\(target.id.uuidString)")
        try FileManager.default.createSymbolicLink(at: package.appendingPathComponent("link"), withDestinationURL: outside)
        _ = try await store.trash(target.id)
        _ = try await store.purge(ids: [target.id])
        XCTAssertFalse(exists(package))
        XCTAssertEqual(try Data(contentsOf: precious), Data("fremd".utf8))

        // A package directory that itself is a symbolic link is refused before the index changes.
        let linked = book("Verlinkt")
        _ = try await store.createDocument(linked, parentID: nil)
        let linkedPackage = root.appendingPathComponent("Library/Documents/\(linked.id.uuidString)")
        let moved = outside.appendingPathComponent("paket")
        try FileManager.default.moveItem(at: linkedPackage, to: moved)
        try FileManager.default.createSymbolicLink(at: linkedPackage, withDestinationURL: moved)
        let before = try await store.trash(linked.id)
        do { _ = try await store.purge(ids: [linked.id]); XCTFail("symlinked package purged") }
        catch LibraryError.invalidIndex { }
        XCTAssertTrue(exists(moved.appendingPathComponent("manifest.json")))
        let fresh = try await LibraryStore(root: root).load()
        XCTAssertEqual(fresh.snapshot.items, before.items)
    }

    func testIndexIsWrittenBeforePackagesAndWriteFailureKeepsEverything() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root); _ = try await store.load()
        let target = book("Unterbrochen")
        _ = try await store.createDocument(target, parentID: nil)
        let trashed = try await store.trash(target.id)
        let index = root.appendingPathComponent("Library/index.json")
        let bytes = try Data(contentsOf: index)
        // Force the atomic index write to fail: the package must remain untouched.
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        do { _ = try await store.purge(ids: [target.id]); XCTFail("commit should fail") } catch { }
        XCTAssertEqual(try RevisionStore(directory: root.appendingPathComponent("Library/Documents/\(target.id.uuidString)")).load(), target)
        try FileManager.default.removeItem(at: index)
        try bytes.write(to: index)
        let fresh = try await LibraryStore(root: root).load()
        XCTAssertEqual(fresh.snapshot, trashed)
    }

    func testPackageRemovalFailureAfterIndexWriteLeavesValidIndexAndReportsOrphan() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root); _ = try await store.load()
        let target = book("Verwaist")
        _ = try await store.createDocument(target, parentID: nil)
        _ = try await store.trash(target.id)
        // A regular file where the staging directory belongs makes the move fail.
        try Data("x".utf8).write(to: root.appendingPathComponent("Library/Purging"))
        let result = try await store.purge(ids: [target.id])
        XCTAssertEqual(result.purgedIDs, [target.id]); XCTAssertEqual(result.leftoverDirectories, 1)
        XCTAssertTrue(result.snapshot.items.isEmpty)
        // Files are kept; the next load adopts the orphan instead of losing it.
        let fresh = try await LibraryStore(root: root).load()
        XCTAssertEqual(fresh.snapshot.items.map(\.id), [target.id])
        XCTAssertNil(fresh.snapshot.items[0].deletedAt)
    }

    func testEmptyTrashKeepsLegacyMainAndPurgesRestoredCopies() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let main = book("Ursprung")
        try RevisionStore(directory: root).save(main)
        var copy = book("Kopie"); copy.id = UUID()
        let restoredURL = root.appendingPathComponent("Restores/\(copy.id.uuidString)")
        try RevisionStore(directory: restoredURL).save(copy)
        let store = LibraryStore(root: root); _ = try await store.load()
        let fresh = book("Neu")
        _ = try await store.createDocument(fresh, parentID: nil)
        for id in [main.id, copy.id, fresh.id] { _ = try await store.trash(id) }
        do { _ = try await store.purge(ids: [main.id]); XCTFail("legacy main purged") }
        catch LibraryError.notPurgeable { }
        let result = try await store.emptyTrash()
        XCTAssertEqual(Set(result.purgedIDs), [copy.id, fresh.id]); XCTAssertEqual(result.retainedIDs, [main.id])
        XCTAssertEqual(result.snapshot.items.map(\.id), [main.id])
        XCTAssertFalse(exists(restoredURL))
        XCTAssertEqual(try RevisionStore(directory: root).load(), main)
        let reloaded = try await LibraryStore(root: root).load()
        XCTAssertEqual(reloaded.snapshot, result.snapshot)
    }

    func testDefaultAppearanceIsOptionalValidatedAndRoundTrips() throws {
        var value = ToolbarPreferences()
        XCTAssertNil(try ToolbarPreferences.decode(JSONEncoder().encode(value)).defaultAppearance)
        var appearance = NotebookAppearance(); appearance.paper = .grid; appearance.color = .dark; appearance.coverEnabled = false
        value.defaultAppearance = appearance
        XCTAssertEqual(try ToolbarPreferences.decode(JSONEncoder().encode(value)).defaultAppearance, appearance)
        appearance.paper = .legacyTest; value.defaultAppearance = appearance
        XCTAssertThrowsError(try value.validate())
    }
}
