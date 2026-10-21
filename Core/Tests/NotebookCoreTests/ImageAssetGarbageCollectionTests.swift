import Foundation
import XCTest
@testable import NotebookCore

/// C7: the asset GC of a package runs only in its single writer, after opening
/// (before the first commit) and after the last commit when closing, never
/// while a backup or restore runs. Every file below Revisions/, Quarantine/,
/// Migrations/ and Archives/ is a root (raw search); so are the pending area,
/// the committed and the current state and the caller's extra hashes.
final class ImageAssetGarbageCollectionTests: XCTestCase {
    private let fm = FileManager.default
    private let never: () -> Bool = { false }
    /// Later than the 15-minute age of unreferenced assets, earlier than the hour of partial files.
    private let later = Date().addingTimeInterval(20 * 60)
    private let muchLater = Date().addingTimeInterval(2 * 3600)
    private let pageOne = UUID(uuidString: "6C700000-0000-4000-8000-000000000001")!
    private let pageTwo = UUID(uuidString: "6C700000-0000-4000-8000-000000000002")!

    private func directory() throws -> URL {
        let root = fm.temporaryDirectory.appendingPathComponent("asset-gc-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func bytes(_ seed: Int, count: Int = 700) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* (seed * 2 + 1) &+ seed) })
    }

    /// Two pages; `images` on the first, `text` as ink bytes on the second.
    private func notebook(_ images: [Data], text: String = "", trashed: [Data] = []) throws -> Notebook {
        var notebook = try Notebook.blank(title: "Aufräumen").preparedForTextEditing()
        notebook.id = UUID(uuidString: "6C700000-0000-4000-8000-0000000000AA")!
        notebook.pages[0].id = pageOne
        _ = try notebook.insertPaper(.blank, at: 1)
        notebook.pages[1].id = pageTwo
        if !text.isEmpty { notebook.pages[1].drawing = Data(text.utf8) }
        func objects(_ originals: [Data], _ offset: Int) -> [ImageObject] {
            originals.enumerated().map { index, data in
                .test(bytes: data, id: UUID(uuidString: String(format: "6C700000-0000-4000-8000-%012d", offset + index))!,
                      x: 40 + Double(index) * 10)
            }
        }
        if !images.isEmpty { try notebook.replaceImages(objects(images, 100), pageID: pageOne) }
        if !trashed.isEmpty {
            _ = try notebook.insertPaper(.blank, at: 2)
            let id = UUID(uuidString: "6C700000-0000-4000-8000-000000000003")!
            notebook.pages[2].id = id
            try notebook.replaceImages(objects(trashed, 200), pageID: id)
            try notebook.trashPage(id, at: Date(timeIntervalSince1970: 1_800_000_000))
        }
        return notebook
    }

    private func hash(_ data: Data) -> String { ImageAssetReference(of: data).sha256 }

    private func assetNames(_ package: URL) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: package.appendingPathComponent("Assets").path)) ?? []).sorted()
    }

    /// Writes files into `Assets/` through a second writer used only for setup.
    private func plant(_ originals: [Data], in package: URL) throws {
        let setup = NotebookAssets(package: package)
        for data in originals { _ = try setup.stage(data) }
        try setup.persist(originals.map { ImageAssetReference(of: $0) })
    }

    private func committedPackage(_ document: Notebook, originals: [Data], at package: URL) throws {
        let store = RevisionStore(directory: package)
        for data in originals { _ = try store.assets.stage(data) }
        try store.save(document)
    }

    private func opened(_ package: URL, at date: Date) throws -> RevisionStore {
        let store = RevisionStore(directory: package)
        _ = try store.load()
        store.assets.clock = { date }
        return store
    }

    // MARK: Deletion rules through the store

    func testOpeningRemovesOldOrphansAndKeepsReferencedPendingYoungAndForeignItems() throws {
        let package = try directory()
        let kept = bytes(1), orphan = bytes(2), pending = bytes(3)
        try committedPackage(try notebook([kept]), originals: [kept], at: package)
        try plant([orphan], in: package)
        let partial = "\(hash(bytes(4))).partial-\(UUID().uuidString)"
        try Data([1]).write(to: package.appendingPathComponent("Assets/\(partial)"))
        try Data([2]).write(to: package.appendingPathComponent("Assets/notizen.txt"))
        try fm.createDirectory(at: package.appendingPathComponent("Assets/\(hash(bytes(5)))"), withIntermediateDirectories: false)

        // Young: nothing goes.
        var store = try opened(package, at: Date())
        XCTAssertEqual(try store.collectAssetGarbage(.opening, isBlocked: never), ImageAssetGarbageReport())

        // 20 minutes later the orphan goes; pending bytes (on disk, too), the
        // committed reference, the young partial and foreign items stay.
        try plant([pending], in: package)
        store = try opened(package, at: later)
        _ = try store.assets.stage(pending)
        XCTAssertEqual(try store.collectAssetGarbage(.opening, isBlocked: never),
                       ImageAssetGarbageReport(removedAssets: [hash(orphan)]))
        XCTAssertEqual(assetNames(package), [hash(kept), hash(pending), hash(bytes(5)), partial, "notizen.txt"].sorted())

        // After two hours the partial goes as well (pending no longer held).
        store = try opened(package, at: muchLater)
        XCTAssertEqual(try store.collectAssetGarbage(.opening, isBlocked: never),
                       ImageAssetGarbageReport(removedAssets: [hash(pending)], removedPartials: [partial]))
        XCTAssertEqual(assetNames(package), [hash(kept), hash(bytes(5)), "notizen.txt"].sorted())
        XCTAssertEqual(try RevisionStore(directory: package).load(), try notebook([kept]))
    }

    /// Hand-built chain: each asset is named by exactly one kind of root.
    func testAssetNamedOnlyByOneRootKindStays() throws {
        let package = try directory()
        let previous = bytes(10), checkpoint = bytes(11), unreadable = bytes(12), quarantined = bytes(13)
        let migration = bytes(14), trashed = bytes(15), archived = bytes(16), orphan = bytes(17)
        try plant([previous, checkpoint, unreadable, quarantined, migration, trashed, archived, orphan], in: package)
        let revisions = package.appendingPathComponent("Revisions", isDirectory: true)
        try fm.createDirectory(at: revisions, withIntermediateDirectories: true)
        func revision(_ document: Notebook, savedAt: Double) throws -> RevisionRecord {
            let data = try JSONEncoder().encode(document)
            let record = RevisionRecord(file: UUID().uuidString + ".json", byteCount: data.count,
                                        crc32: SnapshotChecksum.crc32(data), savedAtUnix: savedAt)
            try data.write(to: revisions.appendingPathComponent(record.file))
            return record
        }
        let current = try notebook([], text: "jetzt", trashed: [trashed])  // only the page trash names it
        let newest = try revision(current, savedAt: 1_800_003_000)
        let older = try revision(try notebook([previous]), savedAt: 1_800_002_000)
        let oldest = try revision(try notebook([checkpoint]), savedAt: 1_800_000_000)
        try JSONEncoder().encode(RevisionManifest(revisions: [newest])).write(to: package.appendingPathComponent("manifest.json"))
        try JSONEncoder().encode(RevisionManifest(revisions: [older])).write(to: package.appendingPathComponent("manifest-previous.json"))
        try JSONEncoder().encode(CheckpointList(checkpoints: [oldest])).write(to: package.appendingPathComponent("checkpoints.json"))
        // A damaged revision rest: no valid JSON, still a root by raw search.
        let damaged = try JSONEncoder().encode(try notebook([unreadable]))
        try damaged.prefix(damaged.count - 9).write(to: revisions.appendingPathComponent(UUID().uuidString + ".json"))
        func write(_ document: Notebook, _ path: String) throws {
            let url = package.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(document).write(to: url)
        }
        try write(try notebook([quarantined]), "Quarantine/1800000000-\(UUID().uuidString)/\(UUID().uuidString).json")
        try write(try notebook([migration]), "Migrations/\(UUID().uuidString)/notebook-v12.json")
        try write(try notebook([archived]), "Archives/\(UUID().uuidString)/notebook.json")

        let store = try opened(package, at: later)
        XCTAssertEqual(try store.load(), current)
        XCTAssertEqual(try store.collectAssetGarbage(.opening, isBlocked: never),
                       ImageAssetGarbageReport(removedAssets: [hash(orphan)]))
        XCTAssertEqual(assetNames(package),
                       [previous, checkpoint, unreadable, quarantined, migration, trashed, archived].map(hash).sorted())
        XCTAssertEqual(try store.localHistory().revisions.count, 2, "manifest entry and checkpoint stay readable")
    }

    /// The same roots, reached through real commits: a checkpoint, and a
    /// damaged newer revision the fallback commit moved to Quarantine/.
    func testCheckpointAndQuarantineFromRealCommitsKeepTheirAssets() throws {
        let base = try directory()
        // Checkpoint: the image leaves the three manifest entries after four
        // more commits ten minutes apart, but stays an older local state.
        let photo = bytes(20), orphan = bytes(21)
        let package = base.appendingPathComponent("Checkpoint")
        var time = 1_800_000_000.0
        let writer = RevisionStore(directory: package)
        writer.clock = { Date(timeIntervalSince1970: time) }
        _ = try writer.assets.stage(photo)
        try writer.save(try notebook([photo]))
        for step in 1...4 { time += 700; try writer.save(try notebook([], text: "Schritt \(step)")) }
        let manifests = ["manifest.json", "manifest-previous.json"].compactMap { name -> [String]? in
            guard let data = try? Data(contentsOf: package.appendingPathComponent(name)),
                  let manifest = try? JSONDecoder().decode(RevisionManifest.self, from: data) else { return nil }
            return manifest.revisions.map(\.file)
        }.flatMap { $0 }
        let named = try NotebookAssets.referencedHashes(in: [package.appendingPathComponent("Revisions")])
        XCTAssertTrue(named.contains(hash(photo)), "a checkpoint names it")
        for file in Set(manifests) {
            let text = String(decoding: try Data(contentsOf: package.appendingPathComponent("Revisions/\(file)")), as: UTF8.self)
            XCTAssertFalse(text.contains(hash(photo)), "no manifest entry names it")
        }
        try plant([orphan], in: package)
        let store = try opened(package, at: later)
        XCTAssertEqual(try store.collectAssetGarbage(.opening, isBlocked: never)?.removedAssets, [hash(orphan)])
        XCTAssertEqual(assetNames(package), [hash(photo)])

        // Quarantine: newest revision (with the image) damaged → fallback; its
        // commit moves the damaged file to Quarantine/, which keeps the asset.
        let quarantined = base.appendingPathComponent("Quarantaene")
        let first = RevisionStore(directory: quarantined)
        try first.save(try notebook([], text: "alt"))
        _ = try first.assets.stage(photo)
        try first.save(try notebook([photo]))
        let manifest = try JSONDecoder().decode(RevisionManifest.self, from: Data(contentsOf: quarantined.appendingPathComponent("manifest.json")))
        let newest = quarantined.appendingPathComponent("Revisions/\(manifest.revisions[0].file)")
        var damaged = try Data(contentsOf: newest)
        damaged[damaged.count - 1] = UInt8(ascii: " ")
        try damaged.write(to: newest)
        let fallback = try opened(quarantined, at: later)
        XCTAssertTrue(fallback.recovered)
        XCTAssertNil(try fallback.collectAssetGarbage(.opening, isBlocked: never), "never after an uncommitted fallback")
        let changed = try notebook([], text: "neu")
        try fallback.save(changed)
        XCTAssertFalse(fm.fileExists(atPath: newest.path))
        XCTAssertTrue(try NotebookAssets.referencedHashes(in: [quarantined.appendingPathComponent("Quarantine")]).contains(hash(photo)))
        try plant([orphan], in: quarantined)
        XCTAssertEqual(try fallback.collectAssetGarbage(.closing, current: changed, isBlocked: never)?.removedAssets, [hash(orphan)])
        XCTAssertEqual(assetNames(quarantined), [hash(photo)])
    }

    // MARK: When the GC may run

    func testOnlyTheWriterCollectsAndOnlyAtOpeningOrClosing() throws {
        let package = try directory()
        let photo = bytes(30), orphan = bytes(31)
        let committed = try notebook([photo])
        try committedPackage(committed, originals: [photo], at: package)
        try plant([orphan], in: package)

        let reader = RevisionStore(directory: package, readOnly: true)
        _ = try reader.load()
        XCTAssertThrowsError(try reader.collectAssetGarbage(.opening, isBlocked: never)) {
            XCTAssertEqual($0 as? ImageAssetError, .readOnly)
        }
        XCTAssertNil(try RevisionStore(directory: package).collectAssetGarbage(.opening, isBlocked: never), "not loaded")

        // After a commit the opening run is over for this store.
        let store = try opened(package, at: later)
        let edited = try notebook([photo], text: "geändert")
        try store.save(edited)
        XCTAssertNil(try store.collectAssetGarbage(.opening, isBlocked: never))
        // Closing requires the current state to be the committed one.
        XCTAssertNil(try store.collectAssetGarbage(.closing, current: try notebook([photo], text: "ungespeichert"), isBlocked: never))
        XCTAssertEqual(assetNames(package), [hash(photo), hash(orphan)].sorted())
        XCTAssertEqual(try store.collectAssetGarbage(.closing, current: edited, isBlocked: never)?.removedAssets, [hash(orphan)])
        XCTAssertNil(try store.collectAssetGarbage(.opening, isBlocked: never), "the session is closed")

        // An unchanged open also counts no commit (the editor's first flush).
        let reopened = try opened(package, at: later)
        try reopened.save(edited)
        XCTAssertNotNil(try reopened.collectAssetGarbage(.opening, isBlocked: never))
    }

    func testOpeningAnOldNotebookCollectsNothingAndWritesNothing() throws {
        let package = try directory()
        let photo = bytes(40)
        let stored = try LegacyNotebookJSON.encode(try notebook([photo]), schemaVersion: 11, originals: [hash(photo): photo])
        try LegacyNotebookJSON.writePackage(package, bytes: stored)
        let before = try LegacyNotebookJSON.inventory(package)
        let store = try opened(package, at: muchLater)
        XCTAssertEqual(store.assets.pendingReferences, [ImageAssetReference(of: photo)])
        XCTAssertEqual(try store.collectAssetGarbage(.opening, isBlocked: never), ImageAssetGarbageReport())
        XCTAssertEqual(try LegacyNotebookJSON.inventory(package), before, "no Assets/ appears by opening")
        // A prototype package without manifest is never collected.
        let prototype = try directory()
        try JSONEncoder().encode(try notebook([])).write(to: prototype.appendingPathComponent("notebook.json"))
        let legacy = try opened(prototype, at: muchLater)
        XCTAssertNil(try legacy.collectAssetGarbage(.opening, isBlocked: never))
    }

    func testReadErrorsAbortAndBackupsOrRestoresBlockTheRun() throws {
        let package = try directory()
        let photo = bytes(50), orphan = bytes(51)
        try committedPackage(try notebook([photo]), originals: [photo], at: package)
        try plant([orphan], in: package)

        // Migrations/ as a file is an unreadable root: abort, nothing deleted.
        try Data("x".utf8).write(to: package.appendingPathComponent("Migrations"))
        XCTAssertThrowsError(try opened(package, at: later).collectAssetGarbage(.opening, isBlocked: never)) {
            XCTAssertEqual($0 as? ImageAssetError, .garbageCollectionAborted)
        }
        XCTAssertEqual(assetNames(package), [hash(photo), hash(orphan)].sorted())
        try fm.removeItem(at: package.appendingPathComponent("Migrations"))

        // A running backup or restore (process-wide) skips the run.
        let activity = BackupActivity.shared.begin()
        XCTAssertTrue(BackupActivity.shared.isActive)
        XCTAssertNil(try opened(package, at: later).collectAssetGarbage(.opening))
        // Started during the search: nothing deleted either.
        var asked = 0
        XCTAssertNil(try opened(package, at: later).collectAssetGarbage(.opening, isBlocked: { asked += 1; return asked > 2 }))
        XCTAssertEqual(asked, 3, "before the run, before the search, before the first deletion")
        XCTAssertEqual(assetNames(package), [hash(photo), hash(orphan)].sorted())
        activity.end(); activity.end()
        XCTAssertFalse(BackupActivity.shared.isActive, "ending twice counts once")
        XCTAssertEqual(try opened(package, at: later).collectAssetGarbage(.opening)?.removedAssets, [hash(orphan)])
    }

    func testBackupAndRestoreHoldTheProcessWideActivity() async throws {
        let root = try directory()
        let library = LibraryStore(root: root.appendingPathComponent("Bibliothek"))
        _ = try await library.load()
        _ = try await library.createDocument(try notebook([], text: "Heft"), parentID: nil)
        let plan = try await library.backupPlan()
        let file = root.appendingPathComponent("bibliothek.notylibrary")
        var seen: [Bool] = []
        XCTAssertFalse(BackupActivity.shared.isActive)
        _ = try LibraryArchive.write(plan, to: file) { _, _ in seen.append(BackupActivity.shared.isActive) }
        XCTAssertEqual(seen, [true])
        XCTAssertFalse(BackupActivity.shared.isActive)
        let manager = WorkspaceStore(root: root.appendingPathComponent("Bereiche"))
        let flag = SeenFlag()
        let prepared = try await manager.prepareRestore(file: file) { _, _ in flag.set(BackupActivity.shared.isActive) }
        XCTAssertTrue(flag.value)
        XCTAssertFalse(BackupActivity.shared.isActive)
        _ = try await manager.commitRestore(prepared, title: "Restore")
        XCTAssertFalse(BackupActivity.shared.isActive)
    }

    /// The quote-skipping scanner finds exactly what a byte-by-byte reading
    /// of the rule finds, for any split into pieces.
    func testRawSearchMatchesTheRuleForRandomBytesAndSplits() {
        func reference(_ bytes: [UInt8]) -> Set<String> {
            var found = Set<String>()
            for (index, byte) in bytes.enumerated() where byte == 0x22 && index + 65 < bytes.count && bytes[index + 65] == 0x22 {
                let digits = bytes[(index + 1)...(index + 64)]
                if digits.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) {
                    found.insert(String(decoding: digits, as: UTF8.self))
                }
            }
            return found
        }
        var state: UInt64 = 0x9E3779B97F4A7C15
        func next() -> UInt64 { state ^= state << 13; state ^= state >> 7; state ^= state << 17; return state }
        let alphabet = Array("0123456789abcdefABx\" \"".utf8)
        for round in 0..<300 {
            var bytes: [UInt8] = []
            for _ in 0..<(Int(next() % 6)) {
                bytes += (0..<Int(next() % 40)).map { _ in alphabet[Int(next() % UInt64(alphabet.count))] }
                let hash = SHA256.hexDigest(Data("\(round)-\(next())".utf8))
                bytes += Array("\"\(next() % 7 == 0 ? String(hash.dropLast()) : hash)\"".utf8)
            }
            var scanner = QuotedHashScanner(), found = Set<String>(), offset = 0
            while offset < bytes.count {
                let piece = min(bytes.count - offset, 1 + Int(next() % 70))
                scanner.feed(Data(bytes[offset..<(offset + piece)]), into: &found)
                offset += piece
            }
            XCTAssertEqual(found, reference(bytes), "round \(round)")
        }
    }

    // MARK: Undo within one session

    func testUndoAfterDeletionAndManyCommitsInTheSameSessionFindsItsAsset() throws {
        let package = try directory()
        let photo = bytes(60)
        try committedPackage(try notebook([photo]), originals: [photo], at: package)
        var time = 1_800_000_000.0
        let store = try opened(package, at: muchLater)
        store.clock = { Date(timeIntervalSince1970: time) }
        var current = try store.load()
        XCTAssertEqual(try store.collectAssetGarbage(.opening, isBlocked: never), ImageAssetGarbageReport())

        // Delete the image as one undo step, then many commits on another page.
        var history = NotebookUndoHistory()
        let before = PageContent(page: current.pages[0])
        try current.replaceImages([], pageID: pageOne)
        history.record(.images, changes: [PageContentReplacement(pageID: pageOne, expected: before, replacement: PageContent(page: current.pages[0]))])
        try store.save(current)
        for step in 1...12 {
            time += 700
            current.pages[1].drawing = Data("Schritt \(step)".utf8)
            try store.save(current)
        }
        // No revision, checkpoint or other root names the image any more …
        let roots = NotebookAssets.garbageRoots(inPackage: package)
        XCTAssertFalse(try NotebookAssets.referencedHashes(in: roots).contains(hash(photo)))
        // … but within the session nothing collects it.
        XCTAssertNil(try store.collectAssetGarbage(.opening, isBlocked: never))
        XCTAssertEqual(assetNames(package), [hash(photo)])

        let outcome = try XCTUnwrap(history.undo(current))
        XCTAssertEqual(outcome.notebook.pages[0].images?.map(\.asset), [ImageAssetReference(of: photo)])
        current = outcome.notebook
        try store.save(current)
        let reloaded = RevisionStore(directory: package)
        XCTAssertEqual(try reloaded.load(), current)
        XCTAssertTrue(reloaded.assets.presentOnDisk([ImageAssetReference(of: photo)]))
        XCTAssertEqual(try store.collectAssetGarbage(.closing, current: current, isBlocked: never), ImageAssetGarbageReport())
        XCTAssertEqual(assetNames(package), [hash(photo)])
    }

    /// Without undo history (next session) the same deletion frees the file
    /// once no kept state names it, and the in-app clipboard can keep it.
    func testPermanentDeletionFreesTheFileOnlyAtALaterOpeningOrClosing() throws {
        let package = try directory()
        let photo = bytes(70)
        try committedPackage(try notebook([], trashed: [photo]), originals: [photo], at: package)
        var time = 1_800_000_000.0
        let store = try opened(package, at: muchLater)
        store.clock = { Date(timeIntervalSince1970: time) }
        var current = try store.load()
        try current.emptyPageTrash()
        for step in 1...12 {
            time += 700
            current.pages[1].drawing = Data("Schritt \(step)".utf8)
            try store.save(current)
        }
        XCTAssertEqual(assetNames(package), [hash(photo)], "a commit never collects")
        XCTAssertEqual(try store.collectAssetGarbage(.closing, current: current, keeping: [hash(photo)], isBlocked: never),
                       ImageAssetGarbageReport(), "the object clipboard keeps it")
        XCTAssertEqual(try opened(package, at: muchLater).collectAssetGarbage(.opening, isBlocked: never)?.removedAssets, [hash(photo)])
        XCTAssertEqual(try RevisionStore(directory: package).load(), current)
    }

    // MARK: Crash images

    /// A crash at every commit step, then the GC on the crash image: the last
    /// acknowledged state always stays complete; the crashed commit's asset
    /// goes only once no rest names it and it is old enough.
    func testCrashImagesAtEveryCommitStageLoseNothingAcknowledged() throws {
        struct Crash: Error {}
        let base = try directory()
        let kept = bytes(80), added = bytes(81)
        let committed = try notebook([kept])
        let next = try notebook([kept, added], text: "neu")
        try committedPackage(committed, originals: [kept], at: base.appendingPathComponent("Paket"))
        let stages: [RevisionStore.CommitStage] = [.assetsWritten, .revisionWritten, .checkpointsWritten, .previousWritten]
        for stage in stages {
            let package = base.appendingPathComponent("Paket-\(stage)")
            let image = base.appendingPathComponent("Abbild-\(stage)")
            try fm.copyItem(at: base.appendingPathComponent("Paket"), to: package)
            let store = RevisionStore(directory: package)
            _ = try store.load()
            _ = try store.assets.stage(added)
            store.commitFault = { reached in
                guard reached == stage else { return }
                try FileManager.default.copyItem(at: package, to: image)
                throw Crash()
            }
            XCTAssertThrowsError(try store.save(next))

            let restarted = try opened(image, at: later)
            XCTAssertEqual(try restarted.load(), committed, "\(stage)")
            let report = try XCTUnwrap(try restarted.collectAssetGarbage(.opening, isBlocked: never), "\(stage)")
            // Only after the asset step no rest names the new asset.
            XCTAssertEqual(report.removedAssets, stage == .assetsWritten ? [hash(added)] : [], "\(stage)")
            XCTAssertEqual(try RevisionStore(directory: image).load(), committed, "\(stage)")
            XCTAssertTrue(NotebookAssets(package: image, readOnly: true).presentOnDisk([ImageAssetReference(of: kept)]))

            // The next commit drops the unacknowledged revision rest; closing then frees the asset.
            let resumed = try opened(image, at: later)
            let other = try notebook([kept], text: "anders")
            try resumed.save(other)
            XCTAssertNotNil(try resumed.collectAssetGarbage(.closing, current: other, isBlocked: never))
            XCTAssertEqual(assetNames(image), [hash(kept)], "\(stage)")
            XCTAssertEqual(try RevisionStore(directory: image).load(), other)
        }
    }

    func testCrashDuringTheAssetWriteLeavesAPartialFileForOneHour() throws {
        struct Crash: Error {}
        let base = try directory()
        let kept = bytes(90), added = bytes(91)
        let committed = try notebook([kept])
        let package = base.appendingPathComponent("Paket")
        try committedPackage(committed, originals: [kept], at: package)
        let image = base.appendingPathComponent("Abbild")
        let store = RevisionStore(directory: package)
        _ = try store.load()
        _ = try store.assets.stage(added)
        store.assets.fault = { stage in
            guard stage == .partialWritten else { return }
            try FileManager.default.copyItem(at: package, to: image)
            throw Crash()
        }
        XCTAssertThrowsError(try store.save(try notebook([kept, added])))
        let partials = assetNames(image).filter { $0.contains(".partial-") }
        XCTAssertEqual(partials.count, 1)
        XCTAssertNil(try opened(image, at: later).collectAssetGarbage(.opening, isBlocked: never)?.removedPartials.first)
        XCTAssertEqual(try opened(image, at: muchLater).collectAssetGarbage(.opening, isBlocked: never)?.removedPartials, partials)
        XCTAssertEqual(assetNames(image), [hash(kept)])
        XCTAssertEqual(try RevisionStore(directory: image).load(), committed)
    }
}

private final class SeenFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = false
    func set(_ value: Bool) { lock.lock(); seen = seen || value; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return seen }
}
