import Foundation
import XCTest
@testable import NotebookCore

/// C8: streaming SHA-256 through an installed platform implementation
/// (CryptoKit in the app) and fewer digests of not yet migrated notebooks.
final class AcceleratedHashingTests: XCTestCase {
    private let fm = FileManager.default

    private func directory() throws -> URL {
        let root = fm.temporaryDirectory.appendingPathComponent("hashing-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// The portable implementation behind the streaming protocol, counting bytes.
    private final class Counting: SHA256StreamingHasher {
        private var inner = SHA256()
        private let counter: Counter
        init(_ counter: Counter) { self.counter = counter }
        func update(_ bytes: UnsafeRawBufferPointer) { inner.update(bytes); counter.add(bytes.count) }
        func finalize() -> [UInt8] { inner.finalize() }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var total = 0
        func add(_ count: Int) { lock.lock(); total += count; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return total }
    }

    /// Correct for whole messages only: drops all but the last piece.
    private final class LastPieceOnly: SHA256StreamingHasher {
        private var last = Data()
        func update(_ bytes: UnsafeRawBufferPointer) { last = Data(bytes) }
        func finalize() -> [UInt8] { var hasher = SHA256(); hasher.update(last); return hasher.finalize() }
    }

    func testStreamingAccelerationIsCheckedThenUsedForFilesAndArchives() throws {
        defer { SHA256.removeAccelerated() }
        XCTAssertFalse(SHA256.installAcceleratedStreaming { LastPieceOnly() }, "pieces across block borders must fit")
        XCTAssertNil(SHA256.acceleratedStreaming)
        let counter = Counter()
        XCTAssertTrue(SHA256.installAcceleratedStreaming { Counting(counter) })

        let data = Data((0..<300_001).map { UInt8(truncatingIfNeeded: $0 &* 29 &+ 3) })
        var stream = SHA256Stream()
        for start in stride(from: 0, to: data.count, by: 4_093) { stream.update(data[start..<min(data.count, start + 4_093)]) }
        XCTAssertEqual(stream.finalizeHex(), SHA256.portableHexDigest(data))

        // File verification (persist, verifiedPayload) and archive records go through it.
        let root = try directory()
        let assets = NotebookAssets(package: root)
        let reference = try assets.stage(data)
        let before = counter.value
        try assets.persist([reference])
        XCTAssertGreaterThanOrEqual(counter.value - before, data.count, "the re-read of the written file")
        assets.dropPending([reference])
        let reader = NotebookAssets(package: root, readOnly: true)
        let checked = counter.value
        XCTAssertEqual(try reader.verifiedPayload(for: reference), .file(root.appendingPathComponent("Assets/\(reference.sha256)")))
        XCTAssertEqual(counter.value - checked, data.count)
        var notebook = try Notebook.blank(title: "Archiv").preparedForTextEditing()
        try notebook.replaceImages([.test(bytes: data)], pageID: notebook.pages[0].id)
        let archived = counter.value
        let backup = root.appendingPathComponent("heft.notybackup")
        let written = try BackupArchive.write(notebook, assets: reader, to: backup)
        XCTAssertEqual(written.assets, [reference])
        XCTAssertGreaterThanOrEqual(counter.value - archived, 2 * data.count, "written and read back")

        // Without an installed implementation the same digests come from Swift.
        SHA256.removeAccelerated()
        let plain = counter.value
        XCTAssertEqual(try BackupArchive.verify(backup).assets, [reference])
        XCTAssertEqual(counter.value, plain)
    }

    // MARK: Not yet migrated notebooks

    private func legacyPackage(_ originals: [Data]) throws -> (URL, Notebook) {
        let root = try directory()
        var notebook = try Notebook.blank(title: "Alt").preparedForTextEditing()
        let objects = originals.enumerated().map { ImageObject.test(bytes: $1, x: 40 + Double($0) * 5) }
        // A repeated original stands for a duplicated image.
        try notebook.replaceImages(objects, pageID: notebook.pages[0].id)
        let stored = try LegacyNotebookJSON.encode(notebook, schemaVersion: 11,
                                                   originals: Dictionary(originals.map { (ImageAssetReference(of: $0).sha256, $0) }, uniquingKeysWith: { first, _ in first }))
        try LegacyNotebookJSON.writePackage(root, bytes: stored)
        return (root, try NotebookDecoding.decode(stored).notebook)
    }

    func testRepeatedLoadsOfAnOldNotebookReuseItsContentAddresses() throws {
        let first = Data((0..<3_000).map { UInt8(truncatingIfNeeded: $0 &* 5) }), second = Data((0..<1_000).map { UInt8(truncatingIfNeeded: $0 &* 9 &+ 1) })
        let (root, expected) = try legacyPackage([first, second, first])
        let cache = LegacyDigestCache.shared
        let reference = try RevisionStore(directory: root, readOnly: true)
        XCTAssertEqual(try reference.load(), expected)
        let hits = cache.hits
        // Previews, search, tasks: each opens a fresh read-only store.
        for _ in 0..<3 {
            let store = RevisionStore(directory: root, readOnly: true)
            XCTAssertEqual(try store.load(), expected)
            XCTAssertEqual(Set(store.assets.pendingReferences), Set([first, second].map { ImageAssetReference(of: $0) }))
            XCTAssertEqual(try store.assets.payload(for: ImageAssetReference(of: second)), .data(second))
        }
        XCTAssertEqual(cache.hits - hits, 3)
        XCTAssertEqual(try RevisionStore(directory: root, readOnly: true).localHistory().revisions.count, 1)

        // A cached list that does not fit (here: wrong sizes) is dropped; the file decodes as before.
        let manifest = try JSONDecoder().decode(RevisionManifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        let record = manifest.revisions[0]
        let key = "\(root.appendingPathComponent("Revisions").standardizedFileURL.path)/\(record.file)#\(record.byteCount)#\(record.crc32)"
        XCTAssertNotNil(cache.references(for: key), "keyed by the revision's path, size and CRC")
        cache.store([.declared(7), .declared(8), .declared(7)], for: key)
        XCTAssertEqual(try RevisionStore(directory: root, readOnly: true).load(), expected)
        XCTAssertEqual(cache.references(for: key), [first, second, first].map { ImageAssetReference(of: $0) })
        // Schema-12 revisions are never cached (nothing to hash).
        _ = try NotebookDecoding.decode(JSONEncoder().encode(expected), storedFile: "schema-12")
        XCTAssertNil(cache.references(for: "schema-12"))
    }

    /// The cache is only a shortcut: even a wrong cached address with the
    /// right size can never become a wrongly named asset file.
    func testAWrongCachedAddressCannotBecomeAnAsset() throws {
        let photo = Data((0..<2_000).map { UInt8(truncatingIfNeeded: $0 &* 11 &+ 7) })
        let (root, expected) = try legacyPackage([photo])
        _ = try RevisionStore(directory: root, readOnly: true).load()
        let manifest = try JSONDecoder().decode(RevisionManifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        let record = manifest.revisions[0]
        let key = "\(root.appendingPathComponent("Revisions").standardizedFileURL.path)/\(record.file)#\(record.byteCount)#\(record.crc32)"
        let wrong = ImageAssetReference.declared(photo.count, seed: 99)
        LegacyDigestCache.shared.store([wrong], for: key)
        defer { LegacyDigestCache.shared.remove(key) }
        let store = RevisionStore(directory: root)
        var loaded = try store.load()
        XCTAssertEqual(loaded.allImages.map(\.asset), [wrong])
        loaded.pages[0].drawing = Data("geändert".utf8)
        XCTAssertThrowsError(try store.save(loaded)) { XCTAssertEqual($0 as? ImageAssetError, .damaged(wrong.sha256)) }
        XCTAssertEqual((try? fm.contentsOfDirectory(atPath: root.appendingPathComponent("Assets").path)) ?? [], [])
        XCTAssertEqual(try JSONDecoder().decode(RevisionManifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json"))).revisions,
                       manifest.revisions, "no commit")
        LegacyDigestCache.shared.remove(key)
        XCTAssertEqual(try RevisionStore(directory: root).load(), expected)
    }
}
