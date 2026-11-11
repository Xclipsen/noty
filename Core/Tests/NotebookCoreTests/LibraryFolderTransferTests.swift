import Foundation
import XCTest
@testable import NotebookCore

/// „Ordner exportieren“ / „Ordner importieren“ (docs/LIBRARY.md): a folder as
/// an ordinary library archive, and such an archive taken into today's
/// library with its folders instead of becoming a separate area.
final class LibraryFolderTransferTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("folders-\(UUID().uuidString)")
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

    private func folder(_ store: LibraryStore, _ title: String, in parent: UUID?) async throws -> UUID {
        let before = Set(try await store.load().snapshot.items.map(\.id))
        let created = try await store.createFolder(title: title, parentID: parent).items.first { !before.contains($0.id) }
        return try XCTUnwrap(created).id
    }

    /// Takes an archive into `store` like the app: folders in one commit, then
    /// every notebook through the staged, checked `.noty` import.
    private func merge(_ archive: URL, into store: LibraryStore, root: URL, base: UUID?) async throws
        -> (plan: LibraryMergePlan, imported: [NotebookImport.Result]) {
        let summary = try LibraryArchive.verify(archive)
        let (_, plan, folders) = try await store.mergeFolders(of: summary.snapshot, under: base)
        let work = try directory()
        let files = try LibraryBackupBrowser.extract(archive: archive,
                                                     titles: Dictionary(uniqueKeysWithValues: plan.notebooks.map { ($0.id, $0.title) }),
                                                     into: work.appendingPathComponent("x", isDirectory: true).creating())
        let repository = NotebookRepository(directory: root)
        var results: [NotebookImport.Result] = []
        for item in plan.notebooks {
            let prepared = try await repository.prepareRestore(from: XCTUnwrap(files[item.id]))
            let parent = item.backupParent.flatMap { folders[$0] } ?? base
            results.append(try await NotebookImport.commit(prepared, repository: repository, library: store, parentID: parent, replacing: nil))
        }
        return (plan, results)
    }

    private func path(_ id: UUID, in snapshot: LibrarySnapshot) -> [String] {
        let item = snapshot.items.first { $0.id == id }!
        return LibraryBackupBrowser.folderPath(of: item, in: snapshot)
    }

    // MARK: Export

    func testFolderExportHoldsOnlyTheActiveSubtreeWithTheFolderOnTop() async throws {
        let root = try directory(), outside = try directory()
        let store = LibraryStore(root: root); _ = try await store.load()
        let school = try await folder(store, "Berufsschule", in: nil)
        let year = try await folder(store, "1 Lehrjahr 2026/2027", in: school)
        let half = try await folder(store, "1. Halbjahr", in: year)
        let empty = try await folder(store, "Leer", in: year)
        let office = try await folder(store, "Kanzlei", in: nil)
        let ws = notebook("WS", pages: 3), fp = notebook("FP"), gone = notebook("Weg"), fibu = notebook("Fibu"), top = notebook("Oben")
        _ = try await store.createDocument(ws, parentID: half)
        _ = try await store.createDocument(fp, parentID: half)
        _ = try await store.createDocument(gone, parentID: half)
        _ = try await store.createDocument(fibu, parentID: office)
        _ = try await store.createDocument(top, parentID: nil)
        _ = try await store.trash(gone.id)
        let bin = try await folder(store, "Papierkorb-Ordner", in: year)
        let inBin = notebook("Im gelöschten Ordner")
        _ = try await store.createDocument(inBin, parentID: bin)
        _ = try await store.trash(bin)

        let whole = try await store.backupPlan(includeCalendar: false)
        let plan = try whole.restricted(toFolder: year)
        XCTAssertNil(plan.calendar)
        XCTAssertEqual(plan.documentCount, 2)
        let url = outside.appendingPathComponent("Ordner.notylibrary")
        _ = try LibraryArchive.write(plan, to: url)
        var read: [UUID: Notebook] = [:]
        let summary = try LibraryArchive.verify(url) { read[$0.id] = $0 }
        XCTAssertEqual(summary.snapshot.items.map(\.id), [year, half, empty, ws.id, fp.id], "Reihenfolge der Bibliothek, nichts aus dem Papierkorb")
        XCTAssertNil(summary.snapshot.items.first { $0.id == year }?.parentID, "der Ordner selbst steht oben")
        XCTAssertEqual(summary.snapshot.items.first { $0.id == half }?.parentID, year)
        XCTAssertEqual(Set(read.keys), [ws.id, fp.id])
        XCTAssertEqual(read[ws.id]?.pages.count, 3)
        // The library itself is untouched, and a folder that is gone or trashed is refused.
        let after = try await store.load().snapshot
        XCTAssertEqual(after, whole.snapshot)
        XCTAssertThrowsError(try whole.restricted(toFolder: bin))
        XCTAssertThrowsError(try whole.restricted(toFolder: ws.id))
        XCTAssertThrowsError(try whole.restricted(toFolder: UUID()))
    }

    // MARK: Plan

    private func snapshot(_ items: [LibraryItem]) -> LibrarySnapshot {
        var value = LibrarySnapshot(); value.items = items; return value
    }

    func testPlanUsesExistingFoldersByIDThenByNameAndCreatesTheRest() throws {
        // Archive: Berufsschule › 1 Lehrjahr › 1. Halbjahr › LF 1, plus a second top folder and a top-level notebook.
        let school = LibraryItem(title: "Berufsschule"), year = LibraryItem(title: "1 Lehrjahr 2026/2027", parentID: school.id)
        let half = LibraryItem(title: "1. Halbjahr", parentID: year.id), extra = LibraryItem(title: "Neu hier")
        let lf1 = LibraryItem(title: "LF 1", parentID: half.id, source: .library), loose = LibraryItem(title: "Lose", source: .library)
        var trashed = LibraryItem(title: "Weg", parentID: half.id, source: .library); trashed.deletedAt = Date(timeIntervalSince1970: 1)
        let backup = snapshot([school, year, half, extra, lf1, loose, trashed])

        // Today: same top folder by name (other ID, other case and spaces), the year by name, no „1. Halbjahr“ there.
        let mySchool = LibraryItem(title: "  berufsschule "), myYear = LibraryItem(title: "1 Lehrjahr 2026/2027", parentID: mySchool.id)
        let elsewhere = LibraryItem(title: "1. Halbjahr")                    // same name, but at the top level: not the same place
        var old = LibraryItem(title: "Neu hier"); old.deletedAt = Date(timeIntervalSince1970: 1)   // in the trash: never reused
        let current = snapshot([mySchool, myYear, elsewhere, old])

        let plan = try LibraryMerge.plan(backup: backup, current: current, base: nil)
        XCTAssertEqual(plan.folders.map(\.title), ["Berufsschule", "Neu hier", "1 Lehrjahr 2026/2027", "1. Halbjahr"], "Eltern vor Kindern")
        XCTAssertEqual(plan.folders.map(\.existing), [mySchool.id, nil, myYear.id, nil])
        XCTAssertEqual(plan.folders.map(\.backupParent), [nil, nil, school.id, year.id])
        XCTAssertEqual(plan.createdFolders, 2)
        XCTAssertEqual(plan.reusedFolders, 2)
        XCTAssertEqual(plan.notebooks.map(\.id), [lf1.id, loose.id])
        XCTAssertEqual(plan.notebooks.map(\.backupParent), [half.id, nil])
        XCTAssertEqual(plan.skippedTrashed, 1)

        // The same folder (same ID at the same place) wins over a namesake.
        let twin = LibraryItem(title: "Berufsschule")
        var same = school; same.title = "Umbenannt"
        let byID = try LibraryMerge.plan(backup: backup, current: snapshot([twin, same]), base: nil)
        XCTAssertEqual(byID.folders.first?.existing, school.id)

        // Two archive folders of one name never share today's single folder.
        let a = LibraryItem(title: "Doppelt"), b = LibraryItem(title: "doppelt"), mine = LibraryItem(title: "Doppelt")
        let twice = try LibraryMerge.plan(backup: snapshot([a, b]), current: snapshot([mine]), base: nil)
        XCTAssertEqual(twice.folders.map(\.existing), [mine.id, nil])

        // Under a base folder: the archive's top level is looked up there, not at the library's top.
        let target = LibraryItem(title: "Ziel"), inside = LibraryItem(title: "Berufsschule", parentID: target.id)
        let based = try LibraryMerge.plan(backup: backup, current: snapshot([mySchool, target, inside]), base: target.id)
        XCTAssertEqual(based.base, target.id)
        XCTAssertEqual(based.folders.first?.existing, inside.id)
        // The base must be an active folder.
        var gone = target; gone.deletedAt = Date(timeIntervalSince1970: 1)
        XCTAssertThrowsError(try LibraryMerge.plan(backup: backup, current: snapshot([gone]), base: target.id))
        XCTAssertThrowsError(try LibraryMerge.plan(backup: backup, current: current, base: UUID()))
        XCTAssertThrowsError(try LibraryMerge.plan(backup: backup, current: snapshot([lf1]), base: lf1.id))
    }

    // MARK: Whole way

    func testExportedFolderComesIntoAnotherLibraryWithItsFoldersAndLeavesItUntouched() async throws {
        let source = try directory(), outside = try directory(), target = try directory()
        let from = LibraryStore(root: source); _ = try await from.load()
        let school = try await folder(from, "Berufsschule", in: nil)
        let year = try await folder(from, "1 Lehrjahr 2026/2027", in: school)
        let half = try await folder(from, "1. Halbjahr", in: year)
        let lf1 = notebook("LF 1 – Rolle im Betrieb", pages: 2), english = notebook("Englisch")
        _ = try await from.createDocument(lf1, parentID: half)
        _ = try await from.createDocument(english, parentID: half)
        let archive = outside.appendingPathComponent("Berufsschule.notylibrary")
        _ = try LibraryArchive.write(try await from.backupPlan(includeCalendar: false).restricted(toFolder: school), to: archive)

        // The other library already has „Berufsschule › 1 Lehrjahr 2026/2027“ with notebooks of its own and an „Englisch“.
        let to = LibraryStore(root: target); _ = try await to.load()
        let mySchool = try await folder(to, "Berufsschule", in: nil)
        let myYear = try await folder(to, "1 Lehrjahr 2026/2027", in: mySchool)
        let own = notebook("WS"), ownEnglish = notebook("Englisch")
        _ = try await to.createDocument(own, parentID: myYear)
        _ = try await to.createDocument(ownEnglish, parentID: nil)
        let before = try await to.load().snapshot
        let ownBytes = try Data(contentsOf: try await to.documentURL(id: own.id).appendingPathComponent("manifest.json"))

        let (plan, imported) = try await merge(archive, into: to, root: target, base: nil)
        XCTAssertEqual(plan.createdFolders, 1, "nur „1. Halbjahr“ fehlte")
        XCTAssertEqual(plan.reusedFolders, 2)
        let after = try await to.load().snapshot
        // Everything that was there is still there, unchanged and in place.
        for item in before.items { XCTAssertEqual(after.items.first { $0.id == item.id }, item) }
        let ownAfter = try Data(contentsOf: try await to.documentURL(id: own.id).appendingPathComponent("manifest.json"))
        XCTAssertEqual(ownAfter, ownBytes)
        // Exactly one new folder, in the existing year folder.
        let newFolders = after.items.filter { $0.isFolder && !before.items.map(\.id).contains($0.id) }
        XCTAssertEqual(newFolders.map(\.title), ["1. Halbjahr"])
        XCTAssertEqual(newFolders.first?.parentID, myYear)
        // Both notebooks are new documents in that folder; the namesake got a number.
        XCTAssertEqual(imported.map(\.title), ["LF 1 – Rolle im Betrieb", "Englisch (1)"])
        for result in imported {
            XCTAssertFalse([lf1.id, english.id].contains(result.id), "neue Dokumentidentität")
            XCTAssertEqual(path(result.id, in: after), ["Berufsschule", "1 Lehrjahr 2026/2027", "1. Halbjahr"])
        }
        let reread = try await NotebookRepository(directory: try await to.documentURL(id: imported[0].id)).load().0
        XCTAssertEqual(reread.pages.count, 2)
        XCTAssertEqual(reread.pages[0].text, lf1.pages[0].text)
        XCTAssertEqual(reread.title, "LF 1 – Rolle im Betrieb")

        // A second time: no folder is created again, the notebooks come once more as copies.
        let (again, more) = try await merge(archive, into: to, root: target, base: nil)
        XCTAssertEqual(again.createdFolders, 0)
        XCTAssertEqual(more.map(\.title), ["LF 1 – Rolle im Betrieb (1)", "Englisch (2)"])
        let final = try await to.load().snapshot
        XCTAssertEqual(final.items.filter(\.isFolder).count, after.items.filter(\.isFolder).count)

        // Under a chosen folder the whole tree hangs below it.
        let box = try await folder(to, "Ablage", in: nil)
        let (below, placed) = try await merge(archive, into: to, root: target, base: box)
        XCTAssertEqual(below.createdFolders, 3)
        let placedIn = try await to.load().snapshot
        XCTAssertEqual(path(placed[0].id, in: placedIn), ["Ablage", "Berufsschule", "1 Lehrjahr 2026/2027", "1. Halbjahr"])
        // The source library never changed.
        let sourceItems = try await from.load().snapshot.items.count
        XCTAssertEqual(sourceItems, 5)
    }

    func testMergeFoldersCommitsNothingWhenNothingIsMissingAndRefusesABadBase() async throws {
        let root = try directory()
        let store = LibraryStore(root: root); _ = try await store.load()
        let school = try await folder(store, "Schule", in: nil)
        let index = root.appendingPathComponent("Library/index.json")
        let bytes = try Data(contentsOf: index)
        var backup = LibrarySnapshot(); backup.items = [LibraryItem(title: "schule")]
        let same = try await store.mergeFolders(of: backup, under: nil)
        XCTAssertEqual(same.folders, [backup.items[0].id: school])
        XCTAssertEqual(try Data(contentsOf: index), bytes, "kein Indexcommit ohne neuen Ordner")
        do { _ = try await store.mergeFolders(of: backup, under: UUID()); XCTFail("Ziel fehlt") } catch {}
        XCTAssertEqual(try Data(contentsOf: index), bytes)
        // A folder title the library would not accept stops everything before the commit.
        var bad = LibrarySnapshot(); bad.items = [LibraryItem(title: "Gut"), LibraryItem(title: String(repeating: "x", count: 500))]
        do { _ = try await store.mergeFolders(of: bad, under: nil); XCTFail("ungültiger Name") } catch {}
        XCTAssertEqual(try Data(contentsOf: index), bytes, "alle Ordner oder keiner")
    }
}

private extension URL {
    func creating() throws -> URL {
        try FileManager.default.createDirectory(at: self, withIntermediateDirectories: true)
        return self
    }
}
