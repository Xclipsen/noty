import Foundation
import XCTest
@testable import NotebookCore

/// BACKUP-RESTORE-PLAN Phase 1: table of contents of a library backup
/// compared with today, single notebooks back as a copy or replacing today's
/// state, through the same staged import as a `.noty` file.
final class LibraryBackupBrowserTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func notebook(_ title: String, pages: Int = 1) -> Notebook {
        var document = Notebook()
        document.title = title
        document.pages[0].text = "\(title) · ÄÖÜ"
        document.pages[0].drawing = Data([1, 2, 3])
        while document.pages.count < pages { document.pages.append(Page()) }
        return document
    }

    private func backup(_ store: LibraryStore, in folder: URL) async throws -> URL {
        let url = folder.appendingPathComponent("\(UUID().uuidString).notylibrary")
        _ = try LibraryArchive.write(try await store.backupPlan(), to: url)
        return url
    }

    private func catalog(_ archive: URL, _ store: LibraryStore) async throws -> BackupCatalog {
        let plan = try await store.backupPlan()
        let current = try await store.load().snapshot
        return try LibraryBackupBrowser.catalog(archive: archive, current: current, fingerprints: plan.currentFingerprints())
    }

    /// Restores like the app: extract, stage, check, commit, adopt.
    private func restore(_ archive: URL, _ entries: [(BackupNotebookEntry, String)], replacing: Bool,
                         store: LibraryStore, root: URL, scratch: URL) async throws -> [NotebookImport.Result] {
        let work = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: work) }
        let files = try LibraryBackupBrowser.extract(archive: archive,
                                                     titles: Dictionary(uniqueKeysWithValues: entries.map { ($0.0.id, $0.1) }), into: work)
        let repository = NotebookRepository(directory: root)
        var results: [NotebookImport.Result] = []
        for (entry, _) in entries {
            let prepared = try await repository.prepareRestore(from: XCTUnwrap(files[entry.id]))
            let current = try await store.load().snapshot
            let target = replacing ? current.activeNotebook(entry.id)?.id : nil
            results.append(try await NotebookImport.commit(prepared, repository: repository, library: store,
                                                           parentID: LibraryBackupBrowser.destination(for: entry, in: current),
                                                           replacing: target))
        }
        return results
    }

    func testFreshBackupListsActiveNotebooksWithFoldersAsUnchanged() async throws {
        let root = try directory(), outside = try directory()
        let store = LibraryStore(root: root); _ = try await store.load()
        let school = try await store.createFolder(title: "Schule", parentID: nil).items[0].id
        let bio = try await store.createFolder(title: "Bio", parentID: school).items.first { $0.title == "Bio" }!.id
        let a = notebook("Zellen", pages: 3), b = notebook("Mathe"), gone = notebook("Alt")
        _ = try await store.createDocument(a, parentID: bio)
        _ = try await store.createDocument(b, parentID: nil)
        _ = try await store.createDocument(gone, parentID: nil)
        _ = try await store.trash(gone.id)

        let result = try await catalog(try await backup(store, in: outside), store)
        XCTAssertEqual(result.entries.map(\.title).sorted(), ["Mathe", "Zellen"])
        XCTAssertTrue(result.entries.allSatisfy { $0.change == .unchanged })
        XCTAssertTrue(result.differences.isEmpty)
        let zellen = try XCTUnwrap(result.entries.first { $0.id == a.id })
        XCTAssertEqual(zellen.folderPath, ["Schule", "Bio"])
        XCTAssertEqual(zellen.parentID, bio)
        XCTAssertEqual(zellen.pageCount, 3)
        XCTAssertEqual(result.trashedInBackup, 1)
        XCTAssertEqual(result.newSince, [])
    }

    func testCatalogReportsChangedTrashedDeletedAndNewSinceTheBackup() async throws {
        let root = try directory(), outside = try directory()
        let store = LibraryStore(root: root); _ = try await store.load()
        let edited = notebook("Physik"), renamed = notebook("Chemie"), trashed = notebook("Kunst"),
            purged = notebook("Musik"), same = notebook("Latein")
        for document in [edited, renamed, trashed, purged, same] { _ = try await store.createDocument(document, parentID: nil) }
        let archive = try await backup(store, in: outside)

        var changed = edited; changed.pages[0].text = "später bearbeitet"
        try RevisionStore(directory: try await store.documentURL(id: edited.id)).save(changed)
        _ = try await store.rename(renamed.id, title: "Chemie Q1")
        _ = try await store.trash(trashed.id)
        _ = try await store.trash(purged.id)
        _ = try await store.purge(ids: [purged.id])
        _ = try await store.createDocument(notebook("Neu"), parentID: nil)

        let result = try await catalog(archive, store)
        let change = Dictionary(uniqueKeysWithValues: result.entries.map { ($0.id, $0.change) })
        XCTAssertEqual(change[edited.id], .changed)
        XCTAssertEqual(change[renamed.id], .changed)
        XCTAssertEqual(change[trashed.id], .trashed)
        XCTAssertEqual(change[purged.id], .deleted)
        XCTAssertEqual(change[same.id], .unchanged)
        XCTAssertEqual(result.entries.first { $0.id == renamed.id }?.currentTitle, "Chemie Q1")
        XCTAssertNil(result.entries.first { $0.id == purged.id }?.currentTitle)
        XCTAssertEqual(result.newSince, ["Neu"])
        XCTAssertEqual(result.differences.count, 4)
    }

    func testCopyComesBackNextToTodaysNotebookInItsFolderAndTodayStaysUntouched() async throws {
        let root = try directory(), outside = try directory()
        let store = LibraryStore(root: root); _ = try await store.load()
        let folder = try await store.createFolder(title: "Q1", parentID: nil).items[0].id
        let original = notebook("Physik")
        _ = try await store.createDocument(original, parentID: folder)
        let archive = try await backup(store, in: outside)
        let package = try await store.documentURL(id: original.id)
        var today = original; today.pages[0].text = "heute"
        try RevisionStore(directory: package).save(today)
        let manifest = try Data(contentsOf: package.appendingPathComponent("manifest.json"))

        let listed = try await catalog(archive, store).entries
        let entry = try XCTUnwrap(listed.first)
        XCTAssertEqual(entry.change, .changed)
        let date = Date(timeIntervalSince1970: 1_762_560_000) // 08.11.2025, 00:00 UTC
        let title = LibraryBackupBrowser.copyTitle(entry.title, savedAt: date, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(title, "Physik (Stand 08.11.2025)")
        let result = try await restore(archive, [(entry, title)], replacing: false, store: store, root: root, scratch: outside)
        let copy = try XCTUnwrap(result.first)
        XCTAssertEqual(copy.title, title)
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.snapshot.children(of: folder).map(\.id), [original.id, copy.id])
        XCTAssertNotNil(copy.snapshot.activeNotebook(original.id))
        let restored = try RevisionStore(directory: try await store.documentURL(id: copy.id), readOnly: true).load()
        XCTAssertEqual(restored.pages, original.pages)
        // Today's notebook: not one byte changed.
        XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent("manifest.json")), manifest)
        XCTAssertEqual(try RevisionStore(directory: package, readOnly: true).load(), today)
        // The extraction left nothing behind but the caller's scratch folder.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path).filter { !$0.hasSuffix(".notylibrary") }, [])
    }

    func testReplaceMovesTodayToTheTrashAndDeletedNotebooksReturnUnderTheirTitle() async throws {
        let root = try directory(), outside = try directory()
        let store = LibraryStore(root: root); _ = try await store.load()
        let folder = try await store.createFolder(title: "Fächer", parentID: nil).items[0].id
        let before = notebook("Anfang"), kept = notebook("Bio"), lost = notebook("Erdkunde")
        for document in [before, kept, lost] { _ = try await store.createDocument(document, parentID: folder) }
        _ = try await store.setFavorite(kept.id, value: true)
        let archive = try await backup(store, in: outside)
        var today = kept; today.pages[0].text = "kaputt bearbeitet"
        try RevisionStore(directory: try await store.documentURL(id: kept.id)).save(today)
        _ = try await store.trash(lost.id); _ = try await store.purge(ids: [lost.id])

        let entries = try await catalog(archive, store).differences
        XCTAssertEqual(Set(entries.map(\.id)), [kept.id, lost.id])
        let results = try await restore(archive, entries.map { ($0, $0.title) }, replacing: true, store: store, root: root, scratch: outside)
        let snapshot = try await store.load().snapshot
        let replaced = try XCTUnwrap(results.first { $0.title == "Bio" })
        let back = try XCTUnwrap(results.first { $0.title == "Erdkunde" })
        // Same place and pin as today's notebook, which waits in the trash.
        XCTAssertEqual(snapshot.children(of: folder).map(\.id), [before.id, replaced.id, back.id])
        XCTAssertTrue(try XCTUnwrap(snapshot.activeNotebook(replaced.id)).favorite)
        XCTAssertTrue(snapshot.isTrashed(kept.id))
        let replacedURL = try await store.documentURL(id: replaced.id)
        XCTAssertEqual(try RevisionStore(directory: replacedURL, readOnly: true).load().pages, kept.pages)
        _ = try await store.restore(kept.id)
        let keptURL = try await store.documentURL(id: kept.id)
        XCTAssertEqual(try RevisionStore(directory: keptURL, readOnly: true).load(), today)
    }

    func testFolderThatIsGoneOrTrashedTodayFallsBackToTheTopLevel() async throws {
        let root = try directory(), outside = try directory()
        let store = LibraryStore(root: root); _ = try await store.load()
        let trashed = try await store.createFolder(title: "Alt", parentID: nil).items[0].id
        let kept = try await store.createFolder(title: "Bleibt", parentID: nil).items.first { $0.title == "Bleibt" }!.id
        let a = notebook("A"), b = notebook("B")
        _ = try await store.createDocument(a, parentID: trashed)
        _ = try await store.createDocument(b, parentID: kept)
        let archive = try await backup(store, in: outside)
        _ = try await store.trash(trashed)
        let result = try await catalog(archive, store)
        let current = try await store.load().snapshot
        let entryA = try XCTUnwrap(result.entries.first { $0.id == a.id })
        let entryB = try XCTUnwrap(result.entries.first { $0.id == b.id })
        XCTAssertEqual(entryA.change, .trashed)
        XCTAssertNil(LibraryBackupBrowser.destination(for: entryA, in: current))
        XCTAssertEqual(LibraryBackupBrowser.destination(for: entryB, in: current), kept)
    }

    func testImageOriginalsComeBackWithTheNotebook() async throws {
        let root = try directory(), outside = try directory()
        let store = LibraryStore(root: root); _ = try await store.load()
        var document = notebook("Bilder")
        _ = try await store.createDocument(document, parentID: nil)
        let image = Data((0..<3_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let reference = ImageAssetReference(of: image)
        let revisions = RevisionStore(directory: try await store.documentURL(id: document.id))
        document = try revisions.load()
        document.pages[0].images = [ImageObject(asset: reference, pixelWidth: 8, pixelHeight: 6, x: 40, y: 40)]
        document.schemaVersion = max(Notebook.imageAssetSchemaVersion, document.schemaVersion)
        _ = try revisions.assets.stage(image)
        try revisions.save(document)
        let archive = try await backup(store, in: outside)
        _ = try await store.trash(document.id); _ = try await store.purge(ids: [document.id])

        let listed = try await catalog(archive, store).entries
        let entry = try XCTUnwrap(listed.first)
        XCTAssertEqual(entry.change, .deleted)
        let result = try await restore(archive, [(entry, entry.title)], replacing: false, store: store, root: root, scratch: outside)
        let package = try await store.documentURL(id: XCTUnwrap(result.first).id)
        let reopened = RevisionStore(directory: package, readOnly: true)
        XCTAssertEqual(try reopened.load().pages[0].images?.map(\.asset), [reference])
        XCTAssertTrue(reopened.assets.presentOnDisk([reference]))
    }

    func testExtractRejectsAnIDThatIsNotInTheBackup() async throws {
        let root = try directory(), outside = try directory()
        let store = LibraryStore(root: root); _ = try await store.load()
        _ = try await store.createDocument(notebook("Eins"), parentID: nil)
        let archive = try await backup(store, in: outside)
        let work = outside.appendingPathComponent("arbeit", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        XCTAssertThrowsError(try LibraryBackupBrowser.extract(archive: archive, titles: [UUID(): "Fremd"], into: work))
    }

    func testCopyTitleStaysAValidTitleAndKeepsTheDate() throws {
        let date = Date(timeIntervalSince1970: 1_762_560_000)
        let utc = TimeZone(identifier: "UTC")!
        let long = LibraryBackupBrowser.copyTitle(String(repeating: "Ä", count: 200), savedAt: date, timeZone: utc)
        XCTAssertEqual(long.count, NotebookTitles.maximumLength)
        XCTAssertTrue(long.hasSuffix(" (Stand 08.11.2025)"))
        XCTAssertEqual(try LibraryStore.validTitle(long), long)
        XCTAssertEqual(LibraryBackupBrowser.copyTitle("  ", savedAt: date, timeZone: utc), "Unbenanntes Heft (Stand 08.11.2025)")
    }
}
