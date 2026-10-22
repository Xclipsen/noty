import Foundation
import XCTest
@testable import NotebookCore

/// `.noty` file (TEXT-REBUILD-62 §5): import as a normal notebook with the
/// exact title, „Titel (n)“ on name collisions, replace or keep both on a
/// document ID that already exists, safe share file names.
final class NotyFileTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func notebook(_ title: String, text: String = "Inhalt") -> Notebook {
        var document = Notebook()
        document.title = title
        document.pages[0].text = text
        document.pages[0].drawing = Data([1, 2, 3])
        return document
    }

    /// Writes `document` as `<title>.noty` (format 2, unchanged content).
    private func file(_ document: Notebook, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(NotyFile.fileName(for: document.title))
        _ = try BackupArchive.write(document, to: url)
        return url
    }

    // MARK: Names

    func testUniqueTitleKeepsFreeTitleAndCountsUpOnCollision() {
        XCTAssertEqual(NotebookTitles.unique("Biologie", taken: ["Mathe"]), "Biologie")
        XCTAssertEqual(NotebookTitles.unique("Biologie", taken: ["Biologie"]), "Biologie (1)")
        XCTAssertEqual(NotebookTitles.unique("Biologie", taken: ["Biologie", "Biologie (1)"]), "Biologie (2)")
        // Gaps are filled first; case and Unicode normalisation do not matter.
        XCTAssertEqual(NotebookTitles.unique("Biologie", taken: ["biologie", "Biologie (2)"]), "Biologie (1)")
        XCTAssertEqual(NotebookTitles.unique("Übung", taken: ["U\u{0308}bung"]), "Übung (1)")
    }

    func testUniqueTitleContinuesASeriesButKeepsNumbersThatBelongToTheName() {
        XCTAssertEqual(NotebookTitles.unique("Bio (1)", taken: ["Bio", "Bio (1)"]), "Bio (2)")
        XCTAssertEqual(NotebookTitles.unique("Klasse (10)", taken: ["Klasse (10)"]), "Klasse (10) (1)")
        XCTAssertEqual(NotebookTitles.unique("Klasse (10)", taken: ["Mathe"]), "Klasse (10)")
    }

    func testUniqueTitleIsAlwaysAValidLibraryTitle() throws {
        let long = String(repeating: "x", count: 120)
        let numbered = NotebookTitles.unique(long, taken: [long])
        XCTAssertEqual(numbered.count, 120)
        XCTAssertTrue(numbered.hasSuffix(" (1)"))
        XCTAssertEqual(NotebookTitles.unique("  Zeile 1\nZeile 2 ", taken: []), "Zeile 1 Zeile 2")
        XCTAssertEqual(NotebookTitles.unique(" \n ", taken: []), "Unbenanntes Heft")
        XCTAssertEqual(NotebookTitles.unique(String(repeating: "y", count: 300), taken: []).count, 120)
        for title in [numbered, NotebookTitles.unique("\t", taken: ["Unbenanntes Heft"])] {
            XCTAssertEqual(try LibraryStore.validTitle(title), title)
        }
    }

    func testShareFileNameIsSafe() {
        XCTAssertEqual(NotyFile.fileName(for: "Bio/Chemie: Teil 1"), "Bio-Chemie- Teil 1.noty")
        XCTAssertEqual(NotyFile.fileName(for: "..versteckt"), "versteckt.noty")
        XCTAssertEqual(NotyFile.fileName(for: " \n"), "Heft.noty")
        XCTAssertEqual(NotyFile.fileName(for: "a?b*c\"d<e>f|g\\h"), "a-b-c-d-e-f-g-h.noty")
        let long = NotyFile.fileStem(for: String(repeating: "ä", count: 300))
        XCTAssertLessThanOrEqual(long.utf8.count, 200)
        XCTAssertEqual(long, String(repeating: "ä", count: 100))
    }

    func testCollisionScopeIsActiveNotebooksOfTheAreaWithoutTrashAndFolders() async throws {
        let root = try directory()
        let store = LibraryStore(root: root); _ = try await store.load()
        let folder = try await store.createFolder(title: "Bio", parentID: nil).items[0].id
        let inside = notebook("Zellen"), trashed = notebook("Genetik"), loose = notebook("Mathe")
        _ = try await store.createDocument(inside, parentID: folder)
        _ = try await store.createDocument(trashed, parentID: nil)
        _ = try await store.createDocument(loose, parentID: nil)
        let snapshot = try await store.trash(trashed.id)
        XCTAssertEqual(Set(snapshot.activeNotebookTitles()), ["Zellen", "Mathe"])
        XCTAssertEqual(snapshot.activeNotebookTitles(excluding: loose.id), ["Zellen"])
        XCTAssertNotNil(snapshot.activeNotebook(inside.id))
        XCTAssertNil(snapshot.activeNotebook(trashed.id))
        XCTAssertNil(snapshot.activeNotebook(folder))
        let hidden = try await store.trash(folder)
        XCTAssertEqual(hidden.activeNotebookTitles(), ["Mathe"])
        XCTAssertEqual(LibraryStore.committedIndex(root: root), hidden)
    }

    // MARK: Import

    func testImportedNotebookIsANormalLibraryNotebookWithExactTitleAndNewIdentity() async throws {
        let root = try directory(), outside = try directory()
        let library = LibraryStore(root: root); _ = try await library.load()
        let folder = try await library.createFolder(title: "Fächer", parentID: nil).items[0].id
        let original = notebook("Rechnungswesen 2026", text: "ÄÖÜ geteilt")
        let url = try file(original, in: outside)
        XCTAssertEqual(url.lastPathComponent, "Rechnungswesen 2026.noty")
        XCTAssertEqual(try BackupArchive.verify(url).document, original)
        let repository = NotebookRepository(directory: root)
        let prepared = try await repository.prepareRestore(from: url)
        XCTAssertEqual(prepared.sourceDocumentID, original.id)
        XCTAssertNotEqual(prepared.document.id, original.id)
        XCTAssertEqual(prepared.document.title, original.title)
        let result = try await NotebookImport.commit(prepared, repository: repository, library: library, parentID: folder, replacing: nil)
        XCTAssertEqual(result.title, "Rechnungswesen 2026")
        let item = try XCTUnwrap(result.snapshot.items.first { $0.id == result.id })
        XCTAssertEqual(item.source, .library)
        XCTAssertEqual(item.parentID, folder)
        XCTAssertEqual(item.title, original.title)
        // A normal package, not a restored copy: nothing in Restores.
        let package = try await library.documentURL(id: result.id)
        XCTAssertEqual(package.standardizedFileURL.path,
                       root.appendingPathComponent("Library/Documents/\(result.id.uuidString)").standardizedFileURL.path)
        var expected = original; expected.id = result.id
        XCTAssertEqual(try RevisionStore(directory: package, readOnly: true).load(), expected)
        let copies = try await repository.restoredCopies()
        XCTAssertTrue(copies.notebooks.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("BackupStaging/\(prepared.id.uuidString)").path))
        // Stable across a fresh library load (no rediscovery as another entry).
        let fresh = try await LibraryStore(root: root).load()
        XCTAssertEqual(fresh.snapshot, result.snapshot)
    }

    func testImportOfAnExistingTitleGetsNumberedAndLegacyExtensionStillImports() async throws {
        let root = try directory(), outside = try directory()
        let library = LibraryStore(root: root); _ = try await library.load()
        _ = try await library.createDocument(notebook("Bio"), parentID: nil)
        let repository = NotebookRepository(directory: root)
        let shared = try file(notebook("Bio", text: "von Lisa"), in: outside)
        let legacy = outside.appendingPathComponent("alt.notybackup")
        _ = try BackupArchive.write(notebook("Bio", text: "alt"), to: legacy)
        var titles: [String] = []
        for url in [shared, legacy] {
            let prepared = try await repository.prepareRestore(from: url)
            titles.append(try await NotebookImport.commit(prepared, repository: repository, library: library,
                                                          parentID: nil, replacing: nil).title)
        }
        XCTAssertEqual(titles, ["Bio (1)", "Bio (2)"])
        let snapshot = try await library.load().snapshot
        XCTAssertEqual(snapshot.items.map(\.title), ["Bio", "Bio (1)", "Bio (2)"])
        XCTAssertTrue(snapshot.items.allSatisfy { $0.source == .library })
    }

    func testReplaceMovesCurrentStateToTrashAndTakesPositionWithNewIdentity() async throws {
        let root = try directory(), outside = try directory()
        let library = LibraryStore(root: root); _ = try await library.load()
        let folder = try await library.createFolder(title: "Q1", parentID: nil).items[0].id
        let before = notebook("Vorher"), existing = notebook("Physik", text: "Stand beim Teilen"), after = notebook("Nachher")
        for document in [before, existing, after] { _ = try await library.createDocument(document, parentID: folder) }
        _ = try await library.setFavorite(existing.id, value: true)
        let url = try file(existing, in: outside)
        // Edited after sharing: this current state must stay restorable.
        let package = try await library.documentURL(id: existing.id)
        var edited = existing; edited.pages[0].text = "später bearbeitet"
        try RevisionStore(directory: package).save(edited)
        let manifest = try Data(contentsOf: package.appendingPathComponent("manifest.json"))
        let repository = NotebookRepository(directory: root)
        let prepared = try await repository.prepareRestore(from: url)
        let loaded = try await library.load().snapshot
        XCTAssertNotNil(loaded.activeNotebook(prepared.sourceDocumentID))
        let result = try await NotebookImport.commit(prepared, repository: repository, library: library,
                                                     parentID: nil, replacing: existing.id)
        XCTAssertNotEqual(result.id, existing.id)
        XCTAssertEqual(result.title, "Physik")
        let snapshot = result.snapshot
        XCTAssertEqual(snapshot.children(of: folder).map(\.id), [before.id, result.id, after.id])
        let imported = try XCTUnwrap(snapshot.activeNotebook(result.id))
        XCTAssertTrue(imported.favorite)
        XCTAssertEqual(imported.source, .library)
        XCTAssertTrue(snapshot.isTrashed(existing.id))
        XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent("manifest.json")), manifest)
        XCTAssertEqual(try RevisionStore(directory: package, readOnly: true).load(), edited)
        let importedURL = try await library.documentURL(id: result.id)
        let importedDocument = try RevisionStore(directory: importedURL, readOnly: true).load()
        XCTAssertEqual(importedDocument.pages, existing.pages)
        // The replaced notebook comes back from the trash unchanged.
        let restored = try await library.restore(existing.id)
        XCTAssertFalse(restored.isTrashed(existing.id))
        let restoredURL = try await library.documentURL(id: existing.id)
        XCTAssertEqual(try RevisionStore(directory: restoredURL, readOnly: true).load(), edited)
    }

    func testKeepBothLeavesTheExistingNotebookAndNumbersTheImport() async throws {
        let root = try directory(), outside = try directory()
        let library = LibraryStore(root: root); _ = try await library.load()
        let existing = notebook("Chemie")
        _ = try await library.createDocument(existing, parentID: nil)
        let url = try file(existing, in: outside)
        let repository = NotebookRepository(directory: root)
        let prepared = try await repository.prepareRestore(from: url)
        let result = try await NotebookImport.commit(prepared, repository: repository, library: library, parentID: nil, replacing: nil)
        XCTAssertEqual(result.title, "Chemie (1)")
        XCTAssertNotNil(result.snapshot.activeNotebook(existing.id))
        XCTAssertNotEqual(result.id, existing.id)
    }

    func testDeclinedImportRemovesItsStageAndChangesNothing() async throws {
        let root = try directory(), outside = try directory()
        let library = LibraryStore(root: root); _ = try await library.load()
        let before = try await library.createDocument(notebook("Bio"), parentID: nil)
        let repository = NotebookRepository(directory: root)
        let prepared = try await repository.prepareRestore(from: try file(notebook("Bio"), in: outside))
        await repository.discardRestore(prepared)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("BackupStaging").path))
        do { _ = try await repository.commitRestore(prepared); XCTFail("discarded stage committed") } catch { }
        let after = try await library.load().snapshot
        XCTAssertEqual(after, before)
    }

    // MARK: Local history copies

    func testLocalHistoryCopiesGetNumberedTitlesInsteadOfRestoredSuffix() async throws {
        let root = try directory()
        let library = LibraryStore(root: root); _ = try await library.load()
        let document = notebook("Deutsch")
        _ = try await library.createDocument(document, parentID: nil)
        let package = try await library.documentURL(id: document.id)
        let repository = NotebookRepository(directory: package, restoreDirectory: root.appendingPathComponent("Restores", isDirectory: true))
        var edited = document; edited.pages[0].text = "neuer"
        try await repository.save(edited, revision: 1)
        let history = try await repository.localHistory()
        let revision = try XCTUnwrap(history.revisions.last).id
        // Two copies in one editor session: the first is not in the index yet.
        let first = try await repository.commitRestoreCopy(try await repository.prepareLocalRecovery(id: revision), libraryRoot: root)
        let second = try await repository.commitRestoreCopy(try await repository.prepareLocalRecovery(id: revision), libraryRoot: root)
        XCTAssertEqual([first.title, second.title], ["Deutsch (1)", "Deutsch (2)"])
        let snapshot = try await library.load().snapshot
        XCTAssertEqual(Set(snapshot.items.filter { $0.source == .restored }.map(\.title)), ["Deutsch (1)", "Deutsch (2)"])
        XCTAssertFalse(snapshot.items.contains { $0.title.contains("Wiederhergestellt") })
    }
}
