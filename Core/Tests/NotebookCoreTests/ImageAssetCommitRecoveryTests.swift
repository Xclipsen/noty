import Foundation
import XCTest
@testable import NotebookCore

/// C6: a commit writes assets first, then revision, checkpoints, previous
/// manifest and the manifest last. A crash at any step leaves the last
/// acknowledged state; a missing asset makes a revision incomplete (fallback,
/// nothing deleted); failed attempts never multiply files.
final class ImageAssetCommitRecoveryTests: XCTestCase {
    private struct Crash: Error {}
    private let first = Data((0..<2_000).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 5) })
    private let second = Data((0..<900).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("commit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func notebook(_ originals: [Data], text: String = "") throws -> Notebook {
        var notebook = try Notebook.blank(title: "Bilder").preparedForTextEditing()
        notebook.id = UUID(uuidString: "5E1F0000-0000-4000-8000-000000000001")!
        notebook.pages[0].id = UUID(uuidString: "5E1F0000-0000-4000-8000-000000000002")!
        if !text.isEmpty { notebook.pages[0].drawing = Data(text.utf8) }
        let images = originals.enumerated().map { index, data in
            ImageObject.test(bytes: data, id: UUID(uuidString: String(format: "5E1F0000-0000-4000-8000-%012d", 10 + index))!,
                             x: 40 + Double(index) * 10)
        }
        if !images.isEmpty { try notebook.replaceImages(images, pageID: notebook.pages[0].id) }
        return notebook
    }

    private func files(_ root: URL, _ folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(folder).path)) ?? []).sorted()
    }

    func testCrashImageAtEveryCommitStageLoadsTheLastAcknowledgedState() throws {
        let base = try directory()
        let committed = try notebook([first])
        let setup = RevisionStore(directory: base.appendingPathComponent("Paket"))
        _ = try setup.assets.stage(first)
        try setup.save(committed)
        let next = try notebook([first, second], text: "neu")
        let stages: [RevisionStore.CommitStage] = [.assetsWritten, .revisionWritten, .checkpointsWritten, .previousWritten]
        for stage in stages {
            let package = base.appendingPathComponent("Paket-\(stage)")
            try FileManager.default.copyItem(at: base.appendingPathComponent("Paket"), to: package)
            let image = base.appendingPathComponent("Abbild-\(stage)")
            let store = RevisionStore(directory: package)
            XCTAssertEqual(try store.load(), committed)
            _ = try store.assets.stage(second)
            store.commitFault = { reached in
                guard reached == stage else { return }
                // The disk as a crash at this point would leave it.
                try FileManager.default.copyItem(at: package, to: image)
                throw Crash()
            }
            XCTAssertThrowsError(try store.save(next), "\(stage)")
            XCTAssertEqual(try RevisionStore(directory: image).load(), committed, "crash after \(stage)")
            XCTAssertEqual(try RevisionStore(directory: package).load(), committed, "failed commit after \(stage)")
            XCTAssertTrue(NotebookAssets(package: image, readOnly: true).presentOnDisk([ImageAssetReference(of: second)]),
                          "assets come first (\(stage))")
            // The pending original survives the failure; a retry commits.
            XCTAssertEqual(store.assets.pendingReferences, [ImageAssetReference(of: second)])
            store.commitFault = { _ in }
            try store.save(next)
            XCTAssertEqual(try RevisionStore(directory: package).load(), next)
            // A store opened on the crash image commits the same change.
            let resumed = RevisionStore(directory: image)
            XCTAssertEqual(try resumed.load(), committed)
            _ = try resumed.assets.stage(second)
            try resumed.save(next)
            XCTAssertEqual(try RevisionStore(directory: image).load(), next)
        }
    }

    func testAssetsDirectoryAsAFileFailsTheSaveBeforeAnyRevision() throws {
        let root = try directory()
        let store = RevisionStore(directory: root)
        let committed = try notebook([])
        try store.save(committed)
        let revisions = files(root, "Revisions")
        try Data("Datei".utf8).write(to: root.appendingPathComponent("Assets"))
        _ = try store.assets.stage(first)
        let next = try notebook([first])
        XCTAssertThrowsError(try store.save(next)) { XCTAssertEqual($0 as? ImageAssetError, .invalidDirectory) }
        XCTAssertEqual(files(root, "Revisions"), revisions, "no revision written")
        XCTAssertEqual(try RevisionStore(directory: root).load(), committed)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Assets"))
        try store.save(next)
        XCTAssertEqual(try RevisionStore(directory: root).load(), next)
        XCTAssertEqual(files(root, "Assets"), [ImageAssetReference(of: first).sha256])
    }

    func testMissingAssetFallsBackToTheOlderRevisionAndDeletesNothing() throws {
        let root = try directory()
        let store = RevisionStore(directory: root)
        let older = try notebook([first])
        _ = try store.assets.stage(first)
        try store.save(older)
        let newer = try notebook([first, second], text: "neuer")
        _ = try store.assets.stage(second)
        try store.save(newer)
        let revisions = files(root, "Revisions")
        try FileManager.default.removeItem(at: root.appendingPathComponent("Assets/\(ImageAssetReference(of: second).sha256)"))
        let fallback = RevisionStore(directory: root)
        XCTAssertEqual(try fallback.load(), older, "incomplete like a CRC error")
        XCTAssertTrue(fallback.recovered)
        XCTAssertEqual(files(root, "Revisions"), revisions, "nothing deleted on load")
        XCTAssertEqual(files(root, "Assets"), [ImageAssetReference(of: first).sha256])
        // The next real change quarantines the skipped newer revision instead of deleting it.
        var edited = older; edited.pages[0].drawing = Data([4])
        try fallback.save(edited)
        let quarantined = (FileManager.default.enumerator(atPath: root.appendingPathComponent("Quarantine").path)?.allObjects as? [String] ?? [])
            .filter { $0.hasSuffix(".json") }
        XCTAssertTrue(quarantined.contains { name in revisions.contains { name.hasSuffix($0) } }, "skipped revision kept: \(quarantined)")
        // Without any complete revision: a clear read error, still nothing deleted.
        let single = try directory()
        let only = RevisionStore(directory: single)
        _ = try only.assets.stage(second)
        try only.save(try notebook([second]))
        try FileManager.default.removeItem(at: single.appendingPathComponent("Assets/\(ImageAssetReference(of: second).sha256)"))
        let before = files(single, "Revisions")
        XCTAssertThrowsError(try RevisionStore(directory: single).load()) { error in
            guard case RevisionError.noCompleteRevision = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(files(single, "Revisions"), before)
        // A damaged asset of the right size still loads (stat only); reading proves the damage.
        let damaged = try directory()
        let writer = RevisionStore(directory: damaged)
        _ = try writer.assets.stage(first)
        let document = try notebook([first])
        try writer.save(document)
        let reference = ImageAssetReference(of: first)
        try Data(repeating: 0, count: first.count).write(to: damaged.appendingPathComponent("Assets/\(reference.sha256)"))
        let reader = RevisionStore(directory: damaged)
        XCTAssertEqual(try reader.load(), document)
        XCTAssertThrowsError(try reader.assets.verifiedPayload(for: reference)) { XCTAssertEqual($0 as? ImageAssetError, .damaged(reference.sha256)) }
    }

    func testRepeatedFailuresDoNotMultiplyFiles() throws {
        let root = try directory()
        let store = RevisionStore(directory: root)
        let committed = try notebook([first])
        _ = try store.assets.stage(first)
        try store.save(committed)
        let revisions = files(root, "Revisions")
        var next = try notebook([first, second], text: "Versuch")
        _ = try store.assets.stage(second)
        store.commitFault = { if $0 == .previousWritten { throw Crash() } }
        for attempt in 0..<5 {
            next.pages[0].drawing = Data("Versuch \(attempt)".utf8)
            XCTAssertThrowsError(try store.save(next))
            XCTAssertEqual(files(root, "Revisions"), revisions, "attempt \(attempt): uncommitted revisions removed")
            XCTAssertEqual(files(root, "Assets").count, 2, "attempt \(attempt): each asset written once")
        }
        XCTAssertEqual(try RevisionStore(directory: root).load(), committed)
        store.commitFault = { _ in }
        try store.save(next)
        XCTAssertEqual(try RevisionStore(directory: root).load(), next)
    }

    func testCopiesImportAssetsFromTheirSourceBeforeTheRevision() throws {
        let root = try directory()
        let source = NotebookAssets(directory: root.appendingPathComponent("Quelle", isDirectory: true))
        _ = try source.stage(first)
        try source.persist([ImageAssetReference(of: first)])
        let copy = RevisionStore(directory: root.appendingPathComponent("Kopie"))
        let document = try notebook([first])
        // Without a source the commit refuses: nothing would hold the original.
        XCTAssertThrowsError(try RevisionStore(directory: root.appendingPathComponent("Ohne")).save(document)) { error in
            XCTAssertEqual(error as? ImageAssetError, .missing(ImageAssetReference(of: first).sha256))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Ohne/manifest.json").path))
        // A source with wrong bytes fails the verification of the copied file.
        let lying = InlineImageAssets(bytes: [ImageAssetReference(of: first).sha256: Data(repeating: 1, count: first.count)])
        XCTAssertThrowsError(try RevisionStore(directory: root.appendingPathComponent("Falsch")).save(document, importingAssetsFrom: lying))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Falsch/manifest.json").path))
        try copy.save(document, importingAssetsFrom: source)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Kopie/Assets/\(ImageAssetReference(of: first).sha256)")), first)
        XCTAssertEqual(try RevisionStore(directory: root.appendingPathComponent("Kopie")).load(), document)
    }
}
