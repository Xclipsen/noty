import Foundation
import XCTest
@testable import NotebookCore

/// iCloud-Ablage (docs/ICLOUD.md): per-notebook versions in the app's iCloud
/// container, the device head, retention, restore through the checked import.
final class NotebookVaultTests: XCTestCase {
    private let device = UUID()
    private let start = Date(timeIntervalSince1970: 1_762_600_000) // 08.11.2025
    private var utc: Calendar { var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!; return calendar }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func notebook(_ title: String) -> Notebook {
        var document = Notebook()
        document.title = title
        document.pages[0].text = "\(title) · ÄÖÜ"
        document.pages[0].drawing = Data([1, 2, 3])
        return document
    }

    private struct Setup { let store: LibraryStore; let library: URL; let vault: URL; let scratch: URL }
    private func setup() async throws -> Setup {
        let base = try directory()
        let library = base.appendingPathComponent("Bibliothek"), vault = base.appendingPathComponent("iCloud"),
            scratch = base.appendingPathComponent("tmp")
        for folder in [library, vault, scratch] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let store = LibraryStore(root: library); _ = try await store.load()
        return Setup(store: store, library: library, vault: VaultLayout.root(container: vault), scratch: scratch)
    }

    @discardableResult
    private func run(_ setup: Setup, head: VaultHead?, at date: Date, interval: TimeInterval = 600) async throws -> (VaultHead, VaultRunReport) {
        try NotebookVault.run(plan: try await setup.store.backupPlan(), root: setup.vault, head: head, device: device, deviceName: "iPad",
                              scratch: setup.scratch, minimumInterval: interval, now: date, calendar: utc)
    }

    private func files(_ setup: Setup, _ id: UUID) throws -> [String] {
        let folder = VaultLayout.versions(setup.vault, id)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    func testFirstRunArchivesEveryActiveNotebookAndAnUnchangedLibraryNothing() async throws {
        let s = try await setup()
        let a = notebook("Bio"), b = notebook("Mathe"), gone = notebook("Alt")
        for document in [a, b, gone] { _ = try await s.store.createDocument(document, parentID: nil) }
        _ = try await s.store.trash(gone.id)
        var manifests: [Data] = []
        for document in [a, b] { manifests.append(try Data(contentsOf: try await s.store.documentURL(id: document.id).appendingPathComponent("manifest.json"))) }

        let (head, report) = try await run(s, head: nil, at: start)
        XCTAssertEqual(report.uploaded.sorted(), ["Bio", "Mathe"])
        XCTAssertEqual(Set(head.notebooks.map(\.id)), [a.id, b.id])
        XCTAssertEqual(try files(s, a.id).count, 1)
        XCTAssertEqual(try files(s, gone.id), [])
        // The head in iCloud is the same one, readable again.
        XCTAssertEqual(try NotebookVault.readHead(root: s.vault, device: device), head)
        // Nothing changed: no new version, no new file.
        let (again, second) = try await run(s, head: head, at: start.addingTimeInterval(3600))
        XCTAssertEqual(second.uploaded, [])
        XCTAssertEqual(second.unchanged, 2)
        XCTAssertEqual(again.notebooks, head.notebooks)
        XCTAssertEqual(try files(s, a.id).count, 1)
        // The library was only read.
        for (document, manifest) in zip([a, b], manifests) {
            let package = try await s.store.documentURL(id: document.id)
            XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent("manifest.json")), manifest)
        }
    }

    func testChangedNotebookGetsANewVersionOnceTheIntervalPassed() async throws {
        let s = try await setup()
        let a = notebook("Physik")
        _ = try await s.store.createDocument(a, parentID: nil)
        var (head, _) = try await run(s, head: nil, at: start)
        var edited = a; edited.pages[0].text = "neu"
        try RevisionStore(directory: try await s.store.documentURL(id: a.id)).save(edited)

        let (waiting, report) = try await run(s, head: head, at: start.addingTimeInterval(60))
        XCTAssertEqual(report.waiting, 1)
        XCTAssertEqual(waiting.notebooks[0].versions.count, 1)
        (head, _) = try await run(s, head: waiting, at: start.addingTimeInterval(700))
        XCTAssertEqual(head.notebooks[0].versions.count, 2)
        XCTAssertEqual(try files(s, a.id).count, 2)
        XCTAssertGreaterThan(head.notebooks[0].versions[0].savedAt, head.notebooks[0].versions[1].savedAt)
        // A manual run (interval 0) takes a change at once.
        edited.pages[0].text = "noch neuer"
        try RevisionStore(directory: try await s.store.documentURL(id: a.id)).save(edited)
        (head, _) = try await run(s, head: head, at: start.addingTimeInterval(710), interval: 0)
        XCTAssertEqual(head.notebooks[0].versions.count, 3)
    }

    func testAVersionComesBackThroughTheCheckedImportWithImagesAndADatedTitle() async throws {
        let s = try await setup()
        var document = notebook("Bilder")
        _ = try await s.store.createDocument(document, parentID: nil)
        let image = Data((0..<2_000).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        let reference = ImageAssetReference(of: image)
        let revisions = RevisionStore(directory: try await s.store.documentURL(id: document.id))
        document = try revisions.load()
        document.pages[0].images = [ImageObject(asset: reference, pixelWidth: 8, pixelHeight: 6, x: 40, y: 40)]
        document.schemaVersion = max(Notebook.imageAssetSchemaVersion, document.schemaVersion)
        _ = try revisions.assets.stage(image)
        try revisions.save(document)
        let (head, _) = try await run(s, head: nil, at: start)
        var later = document; later.pages[0].text = "später"
        try revisions.save(later)

        let version = head.notebooks[0].versions[0]
        let local = s.scratch.appendingPathComponent("zurück.notybackup")
        try NotebookVault.copyVersion(root: s.vault, notebook: document.id, version: version, to: local)
        let repository = NotebookRepository(directory: s.library)
        let prepared = try await repository.prepareRestore(from: local)
        let title = LibraryBackupBrowser.copyTitle("Bilder", savedAt: version.savedAt, withTime: true, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(title, "Bilder (Stand 08.11.2025, 11:06)")
        let result = try await NotebookImport.commit(prepared, repository: repository, library: s.store, parentID: nil,
                                                     replacing: nil, title: title)
        XCTAssertEqual(result.title, title)
        let restoredURL = try await s.store.documentURL(id: result.id), originalURL = try await s.store.documentURL(id: document.id)
        let restored = RevisionStore(directory: restoredURL, readOnly: true)
        XCTAssertEqual(try restored.load().pages, document.pages)
        XCTAssertTrue(restored.assets.presentOnDisk([reference]))
        XCTAssertEqual(try RevisionStore(directory: originalURL, readOnly: true).load(), later)
    }

    func testCopyRejectsAFileThatDiffersFromTheHead() async throws {
        let s = try await setup()
        let a = notebook("Kunst")
        _ = try await s.store.createDocument(a, parentID: nil)
        let (head, _) = try await run(s, head: nil, at: start)
        let version = head.notebooks[0].versions[0]
        let url = VaultLayout.versions(s.vault, a.id).appendingPathComponent(version.file)
        var bytes = try Data(contentsOf: url); bytes[bytes.count - 1] ^= 0xFF
        try bytes.write(to: url)
        let local = s.scratch.appendingPathComponent("x.notybackup")
        XCTAssertThrowsError(try NotebookVault.copyVersion(root: s.vault, notebook: a.id, version: version, to: local)) { error in
            XCTAssertEqual(error as? VaultError, .verificationFailed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.path))
        var renamed = version; renamed.file = "../\(version.file)"
        XCTAssertThrowsError(try NotebookVault.copyVersion(root: s.vault, notebook: a.id, version: renamed, to: local))
    }

    func testRetentionKeepsThreeNewestAndNewestPerDayWeekAndMonth() {
        let hour: TimeInterval = 3600, day = 24 * hour
        let now = start
        // Newest first: five today, then one per day for 40 days, then very old ones.
        var dates = (0..<5).map { now.addingTimeInterval(-Double($0) * hour) }
        dates += (1...40).map { now.addingTimeInterval(-Double($0) * day) }
        dates += [now.addingTimeInterval(-300 * day), now.addingTimeInterval(-400 * day)]
        let obsolete = Set(VaultRetention.obsolete(dates, now: now, calendar: utc))
        XCTAssertFalse(obsolete.contains(0))
        XCTAssertTrue((0..<3).allSatisfy { !obsolete.contains($0) })
        XCTAssertTrue(obsolete.contains(3) && obsolete.contains(4)) // same day as newer ones
        XCTAssertTrue((5..<11).allSatisfy { !obsolete.contains($0) }) // one per day, last 7 days
        XCTAssertTrue(obsolete.contains(dates.count - 1) && obsolete.contains(dates.count - 2)) // older than 6 months
        XCTAssertLessThanOrEqual(dates.count - obsolete.count, 3 + 7 + 5 + 7)
        XCTAssertEqual(VaultRetention.obsolete([now], now: now), [])
    }

    func testPruneRemovesOnlyOwnVersionFilesAndNeverTheNewest() async throws {
        let s = try await setup()
        let a = notebook("Latein")
        _ = try await s.store.createDocument(a, parentID: nil)
        var (head, _) = try await run(s, head: nil, at: start)
        let folder = VaultLayout.versions(s.vault, a.id)
        try Data("fremd".utf8).write(to: folder.appendingPathComponent("fremd.txt"))
        // Six changes on one day, an hour apart.
        for step in 1...6 {
            var edited = a; edited.pages[0].text = "Stand \(step)"
            try RevisionStore(directory: try await s.store.documentURL(id: a.id)).save(edited)
            (head, _) = try await run(s, head: head, at: start.addingTimeInterval(Double(step) * 3600))
        }
        XCTAssertEqual(head.notebooks[0].versions.count, 3)
        XCTAssertEqual(try files(s, a.id).filter { $0 != "fremd.txt" }.sorted(), head.notebooks[0].versions.map(\.file).sorted())
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("fremd.txt").path))
        XCTAssertFalse(NotebookVault.removeVersion(folder.appendingPathComponent("fremd.txt"), coordination: DirectBackupFiles()))
    }

    func testRetentionAlsoAppliesToNotebooksThatAreNoLongerChanged() async throws {
        let s = try await setup()
        let a = notebook("Erdkunde"), gone = notebook("Abgegeben")
        for document in [a, gone] { _ = try await s.store.createDocument(document, parentID: nil) }
        var (head, _) = try await run(s, head: nil, at: start)
        // Both change and are filed on seven consecutive days.
        for day in 1...6 {
            for document in [a, gone] {
                var edited = document; edited.pages[0].text = "Tag \(day)"
                try RevisionStore(directory: try await s.store.documentURL(id: document.id)).save(edited)
            }
            (head, _) = try await run(s, head: head, at: start.addingTimeInterval(Double(day) * 86_400))
        }
        XCTAssertEqual(head.notebooks.map(\.versions.count), [7, 7], "one per day of the last week")
        let newest = try XCTUnwrap(head.notebooks.first { $0.id == a.id }?.versions.first)
        _ = try await s.store.trash(gone.id)

        // 400 days after the last change, nothing to upload.
        let (later, report) = try await run(s, head: head, at: start.addingTimeInterval(406 * 86_400))
        XCTAssertEqual(report.uploaded, [])
        XCTAssertEqual(report.unchanged, 1)
        XCTAssertEqual(report.removedVersions, 4, "only the three newest are left of the unchanged notebook")
        let versions = try XCTUnwrap(later.notebooks.first { $0.id == a.id }).versions
        XCTAssertEqual(versions.count, 3)
        XCTAssertEqual(versions.first, newest, "the newest version is never removed")
        XCTAssertEqual(try files(s, a.id), versions.map(\.file).sorted())
        // Documented: a notebook deleted from the library keeps its versions.
        XCTAssertEqual(try XCTUnwrap(later.notebooks.first { $0.id == gone.id }).versions.count, 7)
        XCTAssertEqual(try files(s, gone.id).count, 7)
        // The head in iCloud records the removal.
        XCTAssertEqual(try NotebookVault.readHead(root: s.vault, device: device), later)
        let (_, again) = try await run(s, head: later, at: start.addingTimeInterval(407 * 86_400))
        XCTAssertEqual(again.removedVersions, 0)
    }

    func testRetentionAlsoAppliesWhileAChangeWaitsForTheMinimumInterval() async throws {
        let s = try await setup()
        let a = notebook("Physik")
        _ = try await s.store.createDocument(a, parentID: nil)
        var (head, _) = try await run(s, head: nil, at: start)
        for day in 1...6 {
            var edited = a; edited.pages[0].text = "Tag \(day)"
            try RevisionStore(directory: try await s.store.documentURL(id: a.id)).save(edited)
            (head, _) = try await run(s, head: head, at: start.addingTimeInterval(Double(day) * 86_400))
        }
        var edited = a; edited.pages[0].text = "noch nicht abgelegt"
        try RevisionStore(directory: try await s.store.documentURL(id: a.id)).save(edited)
        // Changed, but the interval (two years) has not passed.
        let (later, report) = try await run(s, head: head, at: start.addingTimeInterval(406 * 86_400), interval: 730 * 86_400)
        XCTAssertEqual(report.waiting, 1)
        XCTAssertEqual(report.removedVersions, 4)
        XCTAssertEqual(try XCTUnwrap(later.notebooks.first).versions.count, 3)
        XCTAssertEqual(try NotebookVault.readHead(root: s.vault, device: device), later)
    }

    func testHeadsOfOtherDevicesAndNewerFormatsAreReadNotOverwritten() async throws {
        let s = try await setup()
        let a = notebook("Chemie")
        _ = try await s.store.createDocument(a, parentID: nil)
        let (head, _) = try await run(s, head: nil, at: start)
        let other = UUID()
        var foreign = head; foreign.device = other; foreign.deviceName = "altes iPad"; foreign.updatedAt = start.addingTimeInterval(-86_400)
        try NotebookVault.writeHead(foreign, root: s.vault, coordination: DirectBackupFiles())
        let newer = VaultLayout.head(s.vault, UUID())
        try Data(#"{"formatVersion": 2}"#.utf8).write(to: newer)
        try Data("kein json".utf8).write(to: VaultLayout.devices(s.vault).appendingPathComponent("notiz.txt"))

        let (heads, unreadable) = try NotebookVault.heads(root: s.vault)
        XCTAssertEqual(Set(heads.map(\.device)), [device, other])
        XCTAssertEqual(unreadable, 1)
        let mine = VaultLayout.head(s.vault, device)
        try Data(#"{"formatVersion": 2}"#.utf8).write(to: mine)
        XCTAssertThrowsError(try NotebookVault.readHead(root: s.vault, device: device)) { error in
            XCTAssertEqual(error as? VaultError, .unsupported(2))
        }
    }

    func testCatalogMergesDevicesAndKnowsTodaysStateAndFolder() async throws {
        let s = try await setup()
        let folder = try await s.store.createFolder(title: "Schule", parentID: nil).items[0].id
        let a = notebook("Bio"), b = notebook("Musik")
        _ = try await s.store.createDocument(a, parentID: folder)
        _ = try await s.store.createDocument(b, parentID: nil)
        let (head, _) = try await run(s, head: nil, at: start)
        var older = head; older.device = UUID(); older.deviceName = "altes iPad"; older.updatedAt = start.addingTimeInterval(-3600)
        older.notebooks = older.notebooks.map { notebook in
            var copy = notebook
            copy.versions = copy.versions.map { var v = $0; v.file = VaultLayout.versionName(at: start.addingTimeInterval(-7200)); v.savedAt = start.addingTimeInterval(-7200); return v }
            return copy
        }
        _ = try await s.store.trash(b.id); _ = try await s.store.purge(ids: [b.id])
        let current = try await s.store.load().snapshot

        let catalog = VaultCatalogEntry.catalog(heads: [older, head], current: current)
        XCTAssertEqual(catalog.map(\.title), ["Bio", "Musik"])
        let bio = catalog[0]
        XCTAssertEqual(bio.versions.count, 2)
        XCTAssertEqual(bio.versions.map(\.deviceName), ["iPad", "altes iPad"])
        XCTAssertEqual(bio.folderPath, ["Schule"])
        XCTAssertEqual(bio.today, .active)
        XCTAssertEqual(bio.destination(in: current), folder)
        XCTAssertEqual(catalog[1].today, .deleted)
        XCTAssertNil(catalog[1].destination(in: current))
    }

    func testVersionNamesAreStrict() {
        let name = VaultLayout.versionName(at: start)
        XCTAssertTrue(VaultLayout.isVersionName(name))
        for bad in ["../\(name)", name.uppercased(), "1762600000-x.noty", "0-\(UUID().uuidString.lowercased()).noty",
                    name + ".partial", "1762600000-\(UUID().uuidString.lowercased()).json"] {
            XCTAssertFalse(VaultLayout.isVersionName(bad), bad)
        }
    }
}
