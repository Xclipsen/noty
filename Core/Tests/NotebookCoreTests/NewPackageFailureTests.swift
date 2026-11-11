import XCTest
@testable import NotebookCore

/// A failed first commit of a new notebook package must not leave a
/// manifest-less directory behind, and such a directory (from an older build
/// or an app kill) must neither count as an unreadable notebook nor block a
/// later attempt with the same document ID. Anything that could hold user
/// data stays reported and untouched.
final class NewPackageFailureTests: XCTestCase {
    private let fm = FileManager.default
    private let stages: [RevisionStore.CommitStage] = [.assetsWritten, .revisionWritten, .checkpointsWritten, .previousWritten]

    private func directory() throws -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private func bytes(_ count: Int, seed: UInt8) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
    }

    private func withImage(_ notebook: Notebook, _ reference: ImageAssetReference) -> Notebook {
        var copy = notebook
        copy.pages[0].images = [ImageObject(asset: reference, pixelWidth: 8, pixelHeight: 6, x: 40, y: 40)]
        copy.schemaVersion = max(Notebook.imageAssetSchemaVersion, copy.schemaVersion)
        return copy
    }

    /// Every entry below `url` (relative path → bytes; directories and
    /// symbolic links by a marker), to prove that nothing was touched.
    private func tree(_ url: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for path in try fm.subpathsOfDirectory(atPath: url.path) {
            let item = url.appendingPathComponent(path)
            switch try fm.attributesOfItem(atPath: item.path)[.type] as? FileAttributeType {
            case .typeRegular?: result[path] = try Data(contentsOf: item)
            case .typeDirectory?: result[path] = Data("<directory>".utf8)
            default: result[path] = Data("<other>".utf8)
            }
        }
        return result
    }

    private struct Injected: Error {}

    // MARK: RevisionStore

    func testFailedFirstCommitAtAnyStageLeavesNoPackageDirectoryAndCanBeRetried() throws {
        for stage in stages {
            let parent = try directory()
            let package = parent.appendingPathComponent(UUID().uuidString)
            let image = bytes(3_000, seed: 5)
            let store = RevisionStore(directory: package)
            let document = withImage(Notebook.blank(title: "Neu"), try store.assets.stage(image))
            store.commitFault = { if $0 == stage { throw Injected() } }
            XCTAssertThrowsError(try store.save(document), "\(stage)")
            let left = (try? fm.subpathsOfDirectory(atPath: package.path)) ?? []
            XCTAssertFalse(fm.fileExists(atPath: package.path), "\(stage) left behind: \(left)")
            XCTAssertEqual(try fm.contentsOfDirectory(atPath: parent.path), [], "\(stage)")
            // The original is still pending: the same store commits it on the next attempt.
            XCTAssertEqual(store.assets.pendingReferences, document.externalImageAssets, "\(stage)")
            store.commitFault = { _ in }
            XCTAssertNoThrow(try store.save(document), "\(stage) retry")
            let reopened = RevisionStore(directory: package, readOnly: true)
            XCTAssertEqual(try reopened.load(), document, "\(stage)")
            XCTAssertFalse(reopened.recovered, "\(stage)")
            XCTAssertTrue(reopened.assets.presentOnDisk(document.externalImageAssets), "\(stage)")
            XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent("Assets/\(document.externalImageAssets[0].sha256)")), image)
        }
    }

    func testFailedFirstCommitInAnEmptyExistingDirectoryLeavesItEmpty() throws {
        for stage in stages {
            let package = try directory()
            let store = RevisionStore(directory: package)
            let document = withImage(Notebook.blank(title: "Neu"), try store.assets.stage(bytes(500, seed: 1)))
            store.commitFault = { if $0 == stage { throw Injected() } }
            XCTAssertThrowsError(try store.save(document), "\(stage)")
            // The directory was there before the call: only what the call created goes.
            XCTAssertTrue(fm.fileExists(atPath: package.path), "\(stage)")
            XCTAssertEqual(try fm.subpathsOfDirectory(atPath: package.path), [], "\(stage)")
        }
    }

    func testFailedCommitOfAnExistingPackageKeepsTheOldStateReadable() throws {
        for stage in stages {
            let package = try directory().appendingPathComponent(UUID().uuidString)
            let first = RevisionStore(directory: package)
            let a = bytes(2_000, seed: 2)
            let old = withImage(Notebook.blank(title: "Alt"), try first.assets.stage(a))
            try first.save(old)
            let manifest = try Data(contentsOf: package.appendingPathComponent("manifest.json"))

            let store = RevisionStore(directory: package)
            XCTAssertEqual(try store.load(), old)
            var next = withImage(old, try store.assets.stage(bytes(2_500, seed: 3)))
            next.title = "Neu"
            store.commitFault = { if $0 == stage { throw Injected() } }
            XCTAssertThrowsError(try store.save(next), "\(stage)")

            XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent("manifest.json")), manifest, "\(stage)")
            let reopened = RevisionStore(directory: package, readOnly: true)
            XCTAssertEqual(try reopened.load(), old, "\(stage)")
            XCTAssertFalse(reopened.recovered, "\(stage)")
            XCTAssertTrue(reopened.assets.presentOnDisk(old.externalImageAssets), "\(stage)")
            XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent("Assets/\(old.externalImageAssets[0].sha256)")), a, "\(stage)")

            store.commitFault = { _ in }
            XCTAssertNoThrow(try store.save(next), "\(stage) retry")
            let after = RevisionStore(directory: package, readOnly: true)
            XCTAssertEqual(try after.load(), next, "\(stage)")
            XCTAssertTrue(after.assets.presentOnDisk(next.externalImageAssets + old.externalImageAssets), "\(stage)")
        }
    }

    func testFailedFirstCommitNeverRemovesWhatWasThereBefore() throws {
        let image = bytes(1_200, seed: 7)
        let reference = ImageAssetReference(of: image)
        // Each closure prepares a directory with content from before the call.
        let preparations: [(String, (URL) throws -> Void)] = [
            ("foreign file", { try Data("Notiz".utf8).write(to: $0.appendingPathComponent("notiz.txt")) }),
            ("earlier asset", {
                try FileManager.default.createDirectory(at: $0.appendingPathComponent("Assets"), withIntermediateDirectories: true)
                try image.write(to: $0.appendingPathComponent("Assets/\(reference.sha256)"))
            }),
            ("migration archive", {
                try FileManager.default.createDirectory(at: $0.appendingPathComponent("Migrations"), withIntermediateDirectories: true)
            }),
            ("quarantine", {
                try FileManager.default.createDirectory(at: $0.appendingPathComponent("Quarantine/x"), withIntermediateDirectories: true)
                try Data("alt".utf8).write(to: $0.appendingPathComponent("Quarantine/x/manifest.json"))
            }),
        ]
        for (name, prepare) in preparations {
            for stage in stages {
                let package = try directory()
                try prepare(package)
                let before = try tree(package)
                let store = RevisionStore(directory: package)
                let document = withImage(Notebook.blank(title: "Neu"), try store.assets.stage(image))
                store.commitFault = { if $0 == stage { throw Injected() } }
                XCTAssertThrowsError(try store.save(document), "\(name) \(stage)")
                let after = try tree(package)
                for (path, data) in before { XCTAssertEqual(after[path], data, "\(name) \(stage): \(path)") }
            }
        }
    }

    func testFailedFirstPackageCommitOfALegacyNotebookKeepsItsFiles() throws {
        for stage in stages {
            let package = try directory()
            let legacy = Notebook.blank(title: "Prototyp")
            let legacyBytes = try JSONEncoder().encode(legacy)
            try legacyBytes.write(to: package.appendingPathComponent("notebook.json"))
            let store = RevisionStore(directory: package)
            var next = try store.load(); next.title = "Geändert"
            store.commitFault = { if $0 == stage { throw Injected() } }
            XCTAssertThrowsError(try store.save(next), "\(stage)")
            XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent("notebook.json")), legacyBytes, "\(stage)")
            XCTAssertEqual(try RevisionStore(directory: package, readOnly: true).load(), legacy, "\(stage)")
        }
    }

    /// Calendar note notebooks are retried with the same document ID: rests
    /// without content of an aborted first commit must not block that.
    func testNewPackageCanBeCommittedIntoAnEmptyLeftover() throws {
        let package = try directory().appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: package.appendingPathComponent("Revisions"), withIntermediateDirectories: true)
        try fm.createDirectory(at: package.appendingPathComponent("Assets"), withIntermediateDirectories: true)
        try Data().write(to: package.appendingPathComponent("Revisions/\(UUID().uuidString).json"))
        try Data().write(to: package.appendingPathComponent("Revisions/.dat.nosync0001"))
        let document = Notebook.blank(title: "Terminnotiz")
        XCTAssertNoThrow(try RevisionStore(directory: package).save(document))
        let reopened = RevisionStore(directory: package, readOnly: true)
        XCTAssertEqual(try reopened.load(), document)
        XCTAssertFalse(reopened.recovered)
    }

    func testUncommittedRevisionWithBytesStillBlocksANewPackageAndStays() throws {
        let package = try directory().appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: package.appendingPathComponent("Revisions"), withIntermediateDirectories: true)
        let orphan = package.appendingPathComponent("Revisions/\(UUID().uuidString).json")
        let content = try JSONEncoder().encode(Notebook.blank(title: "Nie bestätigt"))
        try content.write(to: orphan)
        XCTAssertThrowsError(try RevisionStore(directory: package).save(Notebook.blank(title: "Neu")))
        XCTAssertEqual(try Data(contentsOf: orphan), content)
        XCTAssertEqual(try fm.subpathsOfDirectory(atPath: package.path).sorted(), ["Revisions", "Revisions/\(orphan.lastPathComponent)"])
    }

    // MARK: Library

    func testFailedCreateLeavesNoDirectoryAndTheLibraryBackupKeepsWorking() async throws {
        let root = try directory()
        let store = LibraryStore(root: root)
        _ = try await store.load()
        _ = try await store.createDocument(Notebook.blank(title: "Echtes Heft"), parentID: nil)
        // The original of this image is nowhere: the commit fails after `Assets/` was created.
        let broken = withImage(Notebook.blank(title: "Ohne Original"), ImageAssetReference(of: bytes(900, seed: 9)))
        do { _ = try await store.createDocument(broken, parentID: nil); XCTFail("create should fail") } catch { }
        let package = root.appendingPathComponent("Library/Documents/\(broken.id.uuidString)")
        XCTAssertFalse(fm.fileExists(atPath: package.path), "left behind: \((try? fm.subpathsOfDirectory(atPath: package.path)) ?? [])")
        let fresh = LibraryStore(root: root)
        let loaded = try await fresh.load()
        XCTAssertEqual(loaded.unreadableDocuments, 0)
        XCTAssertEqual(loaded.snapshot.items.map(\.title), ["Echtes Heft"])
        do { _ = try await fresh.backupPlan() } catch { XCTFail("backupPlan threw \(error)") }
    }

    func testEmptyLeftoverDirectoriesAreNoUnreadableNotebooks() async throws {
        let root = try directory()
        let store = LibraryStore(root: root)
        _ = try await store.load()
        _ = try await store.createDocument(Notebook.blank(title: "Echtes Heft"), parentID: nil)
        let hash = ImageAssetReference(of: bytes(10, seed: 1)).sha256
        var leftovers: [URL] = []
        for collection in ["Library/Documents", "Restores"] {
            let parent = root.appendingPathComponent(collection)
            // What a failed first commit of an older build left behind.
            let revisionsOnly = parent.appendingPathComponent(UUID().uuidString)
            try fm.createDirectory(at: revisionsOnly.appendingPathComponent("Revisions"), withIntermediateDirectories: true)
            let empty = parent.appendingPathComponent(UUID().uuidString)
            try fm.createDirectory(at: empty, withIntermediateDirectories: true)
            // What an app kill can leave: zero-length rests of this store's own writes.
            let killed = parent.appendingPathComponent(UUID().uuidString)
            try fm.createDirectory(at: killed.appendingPathComponent("Revisions"), withIntermediateDirectories: true)
            try fm.createDirectory(at: killed.appendingPathComponent("Assets"), withIntermediateDirectories: true)
            try Data().write(to: killed.appendingPathComponent("Assets/\(hash).partial-\(UUID().uuidString)"))
            try Data().write(to: killed.appendingPathComponent("Revisions/\(UUID().uuidString).json"))
            leftovers += [revisionsOnly, empty, killed]
        }
        let before = try tree(root.appendingPathComponent("Restores"))
        for attempt in 1...2 {
            let fresh = LibraryStore(root: root)
            let loaded = try await fresh.load()
            XCTAssertEqual(loaded.unreadableDocuments, 0, "load \(attempt)")
            XCTAssertEqual(loaded.snapshot.items.map(\.title), ["Echtes Heft"], "load \(attempt)")
            do { _ = try await fresh.backupPlan() } catch { XCTFail("backupPlan threw \(error) (load \(attempt))") }
        }
        // The inventory only reads: the rests are ignored, not removed.
        for leftover in leftovers { XCTAssertTrue(fm.fileExists(atPath: leftover.path)) }
        XCTAssertEqual(try tree(root.appendingPathComponent("Restores")), before)
        let catalog = try await NotebookRepository(directory: root).restoredCopies()
        XCTAssertEqual(catalog.unreadableCount, 0)
        XCTAssertEqual(catalog.notebooks.count, 0)
    }

    func testLeftoverWithAnyRealFileStaysUnreadableAndUntouched() async throws {
        let hash = ImageAssetReference(of: bytes(10, seed: 1)).sha256
        let cases: [(String, (URL) throws -> Void)] = [
            ("revision with bytes", {
                try FileManager.default.createDirectory(at: $0.appendingPathComponent("Revisions"), withIntermediateDirectories: true)
                try JSONEncoder().encode(Notebook.blank(title: "Nie bestätigt"))
                    .write(to: $0.appendingPathComponent("Revisions/\(UUID().uuidString).json"))
            }),
            ("temporary file with bytes", {
                try FileManager.default.createDirectory(at: $0.appendingPathComponent("Revisions"), withIntermediateDirectories: true)
                try Data("{".utf8).write(to: $0.appendingPathComponent("Revisions/.dat.nosync0001"))
            }),
            ("asset", {
                try FileManager.default.createDirectory(at: $0.appendingPathComponent("Assets"), withIntermediateDirectories: true)
                try Data([1, 2, 3]).write(to: $0.appendingPathComponent("Assets/\(hash)"))
            }),
            ("partial asset with bytes", {
                try FileManager.default.createDirectory(at: $0.appendingPathComponent("Assets"), withIntermediateDirectories: true)
                try Data([1]).write(to: $0.appendingPathComponent("Assets/\(hash).partial-\(UUID().uuidString)"))
            }),
            ("legacy document", { try Data("kaputt".utf8).write(to: $0.appendingPathComponent("notebook.json")) }),
            ("empty manifest", { try Data().write(to: $0.appendingPathComponent("manifest.json")) }),
            ("empty previous manifest", { try Data().write(to: $0.appendingPathComponent("manifest-previous.json")) }),
            ("empty checkpoint list", { try Data().write(to: $0.appendingPathComponent("checkpoints.json")) }),
            ("migration archive", {
                try FileManager.default.createDirectory(at: $0.appendingPathComponent("Migrations"), withIntermediateDirectories: true)
            }),
            ("quarantine", {
                try FileManager.default.createDirectory(at: $0.appendingPathComponent("Quarantine"), withIntermediateDirectories: true)
            }),
            ("foreign file", { try Data("x".utf8).write(to: $0.appendingPathComponent("notiz.txt")) }),
            ("nested directory", {
                try FileManager.default.createDirectory(at: $0.appendingPathComponent("Revisions/Tief"), withIntermediateDirectories: true)
            }),
            ("symbolic link", {
                try FileManager.default.createDirectory(at: $0.appendingPathComponent("Revisions"), withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: $0.appendingPathComponent("Revisions/link"),
                                                           withDestinationURL: URL(fileURLWithPath: "/etc/hostname"))
            }),
        ]
        for collection in ["Library/Documents", "Restores"] {
            for (name, prepare) in cases {
                let root = try directory()
                let store = LibraryStore(root: root)
                _ = try await store.load()
                _ = try await store.createDocument(Notebook.blank(title: "Echtes Heft"), parentID: nil)
                let leftover = root.appendingPathComponent(collection).appendingPathComponent(UUID().uuidString)
                try fm.createDirectory(at: leftover, withIntermediateDirectories: true)
                try prepare(leftover)
                let before = try tree(leftover)
                let fresh = LibraryStore(root: root)
                let loaded = try await fresh.load()
                XCTAssertEqual(loaded.unreadableDocuments, 1, "\(collection): \(name)")
                do { _ = try await fresh.backupPlan(); XCTFail("\(collection): \(name): backup of an incomplete library") }
                catch LibraryArchiveError.incomplete { }
                XCTAssertEqual(try tree(leftover), before, "\(collection): \(name)")
            }
        }
    }

    func testNotebookCanBeCreatedIntoAnEmptyLeftoverWithItsID() async throws {
        let root = try directory()
        let store = LibraryStore(root: root)
        _ = try await store.load()
        let book = Notebook.blank(title: "Zweiter Versuch")
        let leftover = root.appendingPathComponent("Library/Documents/\(book.id.uuidString)")
        try fm.createDirectory(at: leftover.appendingPathComponent("Revisions"), withIntermediateDirectories: true)
        try Data().write(to: leftover.appendingPathComponent("Revisions/\(UUID().uuidString).json"))
        let snapshot = try await store.createDocument(book, parentID: nil)
        XCTAssertEqual(snapshot.items.map(\.id), [book.id])
        XCTAssertEqual(try RevisionStore(directory: leftover, readOnly: true).load(), book)
        let loaded = try await LibraryStore(root: root).load()
        XCTAssertEqual(loaded.unreadableDocuments, 0)
        // A directory with content is still never written into.
        let other = Notebook.blank(title: "Belegt")
        let taken = root.appendingPathComponent("Library/Documents/\(other.id.uuidString)")
        try fm.createDirectory(at: taken, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: taken.appendingPathComponent("notiz.txt"))
        do { _ = try await store.createDocument(other, parentID: nil); XCTFail("occupied directory accepted") } catch { }
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: taken.path), ["notiz.txt"])
    }

    // MARK: Restore copies

    private func preparedRestore(in root: URL) async throws -> (NotebookRepository, PreparedRestore, Notebook) {
        let repository = NotebookRepository(directory: root)
        let image = bytes(4_000, seed: 11)
        let document = withImage(Notebook.blank(title: "Quelle"), try repository.assets.stage(image))
        try await repository.save(document, revision: 1)
        let file = root.appendingPathComponent("extern.notybackup")
        try await repository.backup(document, to: file)
        return (repository, try await repository.prepareRestore(from: file), document)
    }

    /// „A failure keeps the stage“: the same `PreparedRestore` commits afterwards.
    func testRestoreCommitCanBeRetriedWithTheSameStageAfterAFailure() async throws {
        for stage in stages {
            for intoLibrary in [false, true] {
                let name = "\(stage), library: \(intoLibrary)"
                let root = try directory()
                let (repository, prepared, document) = try await preparedRestore(in: root)
                let collection = intoLibrary ? root.appendingPathComponent("Library/Documents") : nil
                let destination = (collection ?? root.appendingPathComponent("Restores")).appendingPathComponent(prepared.id.uuidString)
                let input = root.appendingPathComponent("BackupStaging/\(prepared.id.uuidString)/input.notybackup")
                await repository.setRestoreCommitFault { if $0 == stage { throw Injected() } }
                do { _ = try await repository.commitRestore(prepared, into: collection); XCTFail("\(name): commit should fail") } catch { }
                XCTAssertFalse(fm.fileExists(atPath: destination.path),
                               "\(name) left behind: \((try? fm.subpathsOfDirectory(atPath: destination.path)) ?? [])")
                XCTAssertTrue(fm.fileExists(atPath: input.path), name)
                XCTAssertEqual(try RevisionStore(directory: root, readOnly: true).load(), document, name)
                if intoLibrary {
                    let loaded = try await LibraryStore(root: root).load()
                    XCTAssertEqual(loaded.unreadableDocuments, 0, name)
                }

                await repository.setRestoreCommitFault { _ in }
                let restored = try await repository.commitRestore(prepared, into: collection)
                XCTAssertEqual(restored.id, prepared.id, name)
                let reopened = RevisionStore(directory: destination, readOnly: true)
                XCTAssertEqual(try reopened.load(), prepared.document, name)
                XCTAssertFalse(reopened.recovered, name)
                XCTAssertTrue(reopened.assets.presentOnDisk(document.externalImageAssets), name)
                XCTAssertFalse(fm.fileExists(atPath: input.path), "\(name): the stage goes after the commit")
            }
        }
    }

    // MARK: Shell

    func testOnlyDirectoriesWithoutAnyByteAreShellsAndRemovalIsNeverRecursive() throws {
        let base = try directory()
        XCTAssertFalse(PackageShell.isShell(base.appendingPathComponent("fehlt")))
        let shell = base.appendingPathComponent("a")
        try fm.createDirectory(at: shell.appendingPathComponent("Revisions"), withIntermediateDirectories: true)
        try fm.createDirectory(at: shell.appendingPathComponent("Assets"), withIntermediateDirectories: true)
        try Data().write(to: shell.appendingPathComponent("Revisions/\(UUID().uuidString).json"))
        try Data().write(to: shell.appendingPathComponent(".dat.nosync0001"))
        XCTAssertTrue(PackageShell.isShell(shell))
        // A symbolic link to a shell is none.
        let link = base.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: shell)
        XCTAssertFalse(PackageShell.isShell(link))
        XCTAssertFalse(PackageShell.remove(link))
        XCTAssertTrue(PackageShell.isShell(shell))

        XCTAssertTrue(PackageShell.remove(shell, keepingRoot: true))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: shell.path), [])
        XCTAssertTrue(PackageShell.remove(shell))
        XCTAssertFalse(fm.fileExists(atPath: shell.path))

        let package = base.appendingPathComponent("b")
        try fm.createDirectory(at: package.appendingPathComponent("Revisions"), withIntermediateDirectories: true)
        try Data().write(to: package.appendingPathComponent("Revisions/leer.json"))
        try Data("{}".utf8).write(to: package.appendingPathComponent("Revisions/\(UUID().uuidString).json"))
        let before = try tree(package)
        XCTAssertFalse(PackageShell.isShell(package))
        XCTAssertFalse(PackageShell.remove(package))
        XCTAssertEqual(try tree(package), before)
    }

    func testRestoreCommitWorksIntoAnEmptyLeftoverOfAnEarlierAttempt() async throws {
        let root = try directory()
        let (repository, prepared, document) = try await preparedRestore(in: root)
        let destination = root.appendingPathComponent("Restores/\(prepared.id.uuidString)")
        try fm.createDirectory(at: destination.appendingPathComponent("Revisions"), withIntermediateDirectories: true)
        let restored = try await repository.commitRestore(prepared)
        XCTAssertEqual(restored.id, prepared.id)
        let reopened = RevisionStore(directory: destination, readOnly: true)
        XCTAssertEqual(try reopened.load().pages, document.pages)
        XCTAssertTrue(reopened.assets.presentOnDisk(document.externalImageAssets))
    }
}
