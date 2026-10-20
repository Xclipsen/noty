import Foundation
import XCTest
@testable import NotebookCore

/// `NotebookAssets` in isolation (C2): write protocol, presence, pending area,
/// read-only mode. Not yet wired into RevisionStore.
final class ImageAssetStoreTests: XCTestCase {
    private var package: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        package = fm.temporaryDirectory.appendingPathComponent("assets-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? fm.removeItem(at: package) }

    private var assetsDirectory: URL { package.appendingPathComponent("Assets", isDirectory: true) }
    private func bytes(_ count: Int, _ seed: UInt8 = 1) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) }) }
    private func names() -> [String] { ((try? fm.contentsOfDirectory(atPath: assetsDirectory.path)) ?? []).sorted() }
    private func file(_ reference: ImageAssetReference) -> URL { assetsDirectory.appendingPathComponent(reference.sha256) }
    private func store(readOnly: Bool = false) -> NotebookAssets {
        let assets = NotebookAssets(package: package, readOnly: readOnly)
        assets.blockSize = 7 // odd block size: every streaming path crosses block borders
        return assets
    }

    func testStagePersistAndDropMoveBytesFromMemoryToAnImmutableFile() throws {
        let assets = store(), data = bytes(1_000)
        let reference = try assets.stage(data)
        XCTAssertEqual(reference, ImageAssetReference(of: data))
        XCTAssertEqual(try assets.payload(for: reference), .data(data))
        XCTAssertFalse(assets.presentOnDisk([reference]))
        XCTAssertFalse(fm.fileExists(atPath: assetsDirectory.path), "staging alone writes nothing")

        XCTAssertEqual(try assets.persist(assets.pendingReferences), [reference])
        XCTAssertEqual(names(), [reference.sha256], "no partial file left")
        XCTAssertEqual(try Data(contentsOf: file(reference)), data)
        XCTAssertTrue(assets.presentOnDisk([reference]))
        XCTAssertEqual(try assets.payload(for: reference), .file(file(reference)), "file first, then pending")

        assets.dropPending([reference])
        XCTAssertEqual(assets.pendingByteCount, 0)
        XCTAssertEqual(try assets.payload(for: reference), .file(file(reference)))
        XCTAssertEqual(try assets.verifiedPayload(for: reference), .file(file(reference)))

        // Repeated commits never rewrite an existing asset.
        let before = try fm.attributesOfItem(atPath: file(reference).path)[.modificationDate] as? Date
        XCTAssertEqual(try assets.persist([reference, reference]), [])
        XCTAssertEqual(try fm.attributesOfItem(atPath: file(reference).path)[.modificationDate] as? Date, before)
        XCTAssertEqual(names(), [reference.sha256])
        XCTAssertEqual(try assets.persist([]), [])
    }

    func testPendingAreaDeduplicatesAndEnforcesItsLimit() throws {
        let assets = store()
        assets.pendingLimit = 10
        let first = bytes(6, 1), second = bytes(6, 2)
        let a = try assets.stage(first)
        XCTAssertEqual(try assets.stage(first), a, "same bytes again are not counted twice")
        XCTAssertEqual(assets.pendingByteCount, 6)
        XCTAssertThrowsError(try assets.stage(second)) { XCTAssertEqual($0 as? ImageAssetError, .pendingFull) }
        XCTAssertEqual(assets.pendingReferences, [a])
        assets.dropPending([a])
        let b = try assets.stage(second)
        XCTAssertEqual(assets.pendingReferences, [b])
        XCTAssertEqual(NotebookAssets.maximumPendingBytes, 100_000_000)

        XCTAssertThrowsError(try assets.stage(Data())) { XCTAssertEqual($0 as? ImageAssetError, .invalidReference) }
        // Size is checked before hashing; nothing becomes pending.
        assets.pendingLimit = .max
        XCTAssertThrowsError(try assets.stage(Data(count: ImageLimits.maximumFileBytes + 1))) {
            XCTAssertEqual($0 as? ImageAssetError, .invalidReference)
        }
        XCTAssertEqual(assets.pendingReferences, [b])
    }

    func testPersistRejectsInvalidOrContradictoryReferencesBeforeWriting() throws {
        let assets = store(), reference = try assets.stage(bytes(40))
        for bad in [ImageAssetReference(sha256: reference.sha256.uppercased(), byteCount: 40),
                    ImageAssetReference(sha256: "../" + reference.sha256.dropFirst(3), byteCount: 40),
                    ImageAssetReference(sha256: reference.sha256, byteCount: 0)] {
            XCTAssertThrowsError(try assets.persist([reference, bad])) { XCTAssertEqual($0 as? ImageAssetError, .invalidReference) }
            XCTAssertThrowsError(try assets.payload(for: bad)) { XCTAssertEqual($0 as? ImageAssetError, .invalidReference) }
        }
        XCTAssertThrowsError(try assets.persist([reference, ImageAssetReference(sha256: reference.sha256, byteCount: 41)])) {
            XCTAssertEqual($0 as? ImageAssetError, .invalidReference)
        }
        XCTAssertFalse(fm.fileExists(atPath: assetsDirectory.path))
    }

    func testMissingBytesOrWrongSourceBytesFailWithoutLeavingFiles() throws {
        let assets = store(), data = bytes(100)
        let reference = ImageAssetReference(of: data)
        XCTAssertThrowsError(try assets.persist([reference])) { XCTAssertEqual($0 as? ImageAssetError, .missing(reference.sha256)) }
        XCTAssertThrowsError(try assets.payload(for: reference)) { XCTAssertEqual($0 as? ImageAssetError, .missing(reference.sha256)) }

        // A source whose bytes do not hash to the address: rejected after the re-read.
        struct Wrong: ImageAssetProviding {
            let data: Data
            func payload(for reference: ImageAssetReference) throws -> ImageAssetPayload { .data(data) }
        }
        var flipped = data; flipped[3] ^= 1
        for _ in 0..<3 { // repeated failures do not accumulate files
            XCTAssertThrowsError(try assets.persist([reference], from: Wrong(data: flipped))) {
                XCTAssertEqual($0 as? ImageAssetError, .damaged(reference.sha256))
            }
            XCTAssertThrowsError(try assets.persist([reference], from: Wrong(data: data + Data([0])))) {
                XCTAssertEqual($0 as? ImageAssetError, .damaged(reference.sha256))
            }
        }
        XCTAssertEqual(names(), [])
        XCTAssertEqual(try assets.persist([reference], from: Wrong(data: data)), [reference])
        XCTAssertEqual(try Data(contentsOf: file(reference)), data)
    }

    func testImportFromAnotherPackageStreamsAndVerifiesTheFile() throws {
        let otherPackage = package.appendingPathComponent("Other", isDirectory: true)
        let other = NotebookAssets(package: otherPackage)
        let data = bytes(5_000, 9)
        let reference = try other.stage(data)
        try other.persist([reference]); other.dropPending([reference])
        XCTAssertEqual(try other.payload(for: reference), .file(otherPackage.appendingPathComponent("Assets/\(reference.sha256)")))

        let assets = store()
        XCTAssertEqual(try assets.persist([reference], from: other), [reference])
        XCTAssertEqual(try Data(contentsOf: file(reference)), data)
        XCTAssertEqual(names(), [reference.sha256])

        // Damaged source file of the same size: refused, nothing installed.
        let third = NotebookAssets(package: package.appendingPathComponent("Third", isDirectory: true))
        let otherFile = otherPackage.appendingPathComponent("Assets/\(reference.sha256)")
        var damaged = data; damaged[0] ^= 0xff
        try damaged.write(to: otherFile)
        XCTAssertThrowsError(try third.persist([reference], from: other)) { XCTAssertEqual($0 as? ImageAssetError, .damaged(reference.sha256)) }
        XCTAssertEqual((try? fm.contentsOfDirectory(atPath: third.directory.path)) ?? [], [])
    }

    func testExistingTargetIsNeverOverwrittenUnlessProvenWrong() throws {
        let data = bytes(300, 4), reference = ImageAssetReference(of: data)
        try fm.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)

        // Same bytes already there (another commit, a clone): own partial removed, file kept.
        try data.write(to: file(reference))
        let before = try fm.attributesOfItem(atPath: file(reference).path)[.systemFileNumber] as? NSNumber
        var assets = store()
        _ = try assets.stage(data)
        XCTAssertEqual(try assets.persist([reference]), [])
        XCTAssertEqual(try fm.attributesOfItem(atPath: file(reference).path)[.systemFileNumber] as? NSNumber, before)
        XCTAssertEqual(names(), [reference.sha256])

        // Same size, flipped byte, own bytes pending: SHA proves it wrong → repaired.
        var flipped = data; flipped[10] ^= 1
        try flipped.write(to: file(reference))
        assets = store(); _ = try assets.stage(data)
        XCTAssertEqual(try assets.persist([reference]), [reference])
        XCTAssertEqual(try Data(contentsOf: file(reference)), data)
        XCTAssertEqual(names(), [reference.sha256])

        // Wrong size is proof, too.
        try data.prefix(299).write(to: file(reference))
        assets = store(); _ = try assets.stage(data)
        XCTAssertEqual(try assets.persist([reference]), [reference])
        XCTAssertEqual(try Data(contentsOf: file(reference)), data)

        // Wrong size and no bytes: refused, the file stays as it is.
        try data.prefix(299).write(to: file(reference))
        assets = store()
        XCTAssertThrowsError(try assets.persist([reference])) { XCTAssertEqual($0 as? ImageAssetError, .damaged(reference.sha256)) }
        XCTAssertEqual(try Data(contentsOf: file(reference)), data.prefix(299))
        XCTAssertFalse(assets.presentOnDisk([reference]))

        // Right size, wrong content, no bytes: nothing proves it wrong at commit
        // time (stat only); the first verified read does and marks it damaged.
        try flipped.write(to: file(reference))
        assets = store()
        XCTAssertEqual(try assets.persist([reference]), [])
        XCTAssertTrue(assets.presentOnDisk([reference]))
        XCTAssertEqual(try assets.payload(for: reference), .file(file(reference)))
        XCTAssertThrowsError(try assets.verifiedPayload(for: reference)) { XCTAssertEqual($0 as? ImageAssetError, .damaged(reference.sha256)) }
        XCTAssertFalse(assets.presentOnDisk([reference]))
        XCTAssertThrowsError(try assets.payload(for: reference)) { XCTAssertEqual($0 as? ImageAssetError, .damaged(reference.sha256)) }
        XCTAssertEqual(try Data(contentsOf: file(reference)), flipped, "reading never deletes or rewrites")
        // Fresh bytes (re-import): served from memory, the next commit repairs.
        _ = try assets.stage(data)
        XCTAssertEqual(try assets.verifiedPayload(for: reference), .data(data))
        XCTAssertEqual(try assets.persist([reference]), [reference])
        XCTAssertEqual(try assets.verifiedPayload(for: reference), .file(file(reference)))
        XCTAssertEqual(try Data(contentsOf: file(reference)), data)
    }

    func testTargetAppearingDuringTheWriteIsNotOverwritten() throws {
        let data = bytes(200, 5), reference = ImageAssetReference(of: data)
        let assets = store()
        _ = try assets.stage(data)
        assets.fault = { stage in if stage == .partialVerified { try data.write(to: self.file(reference)) } }
        XCTAssertEqual(try assets.persist([reference]), [])
        XCTAssertEqual(names(), [reference.sha256])

        // A foreign file of another size appearing: error, foreign file untouched.
        try fm.removeItem(at: file(reference))
        assets.fault = { stage in if stage == .partialVerified { try Data([1, 2, 3]).write(to: self.file(reference)) } }
        XCTAssertThrowsError(try assets.persist([reference]))
        XCTAssertEqual(try Data(contentsOf: file(reference)), Data([1, 2, 3]))
        XCTAssertEqual(names(), [reference.sha256])
    }

    /// A crash image taken between the steps only ever contains a partial
    /// file (ignored, collected later), never a wrong `<sha>`.
    func testInterruptedWritesLeaveOnlyPartialFilesAndFailuresCleanUp() throws {
        let data = bytes(500, 6), reference = ImageAssetReference(of: data)
        let assets = store()
        _ = try assets.stage(data)
        struct Crash: Error {}
        for stage in [NotebookAssets.PersistStage.partialWritten, .partialVerified] {
            var image: [String] = []
            assets.fault = { current in
                guard current == stage else { return }
                image = self.names()
                throw Crash()
            }
            XCTAssertThrowsError(try assets.persist([reference])) { XCTAssertTrue($0 is Crash) }
            XCTAssertEqual(image.count, 1)
            XCTAssertTrue(NotebookAssets.isPartialName(image[0]), image[0])
            XCTAssertTrue(image[0].hasPrefix(reference.sha256 + ".partial-"))
            XCTAssertEqual(names(), [], "the failed attempt removes its own partial file")
            XCTAssertFalse(assets.presentOnDisk([reference]))
        }
        assets.fault = { _ in }
        XCTAssertEqual(try assets.persist([reference]), [reference])
    }

    func testSymlinkedDirectoryOrAssetIsRejectedAndNeverWrittenThrough() throws {
        let elsewhere = package.appendingPathComponent("Elsewhere", isDirectory: true)
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let data = bytes(64, 7), reference = ImageAssetReference(of: data)
        try data.write(to: elsewhere.appendingPathComponent(reference.sha256))

        // Assets/ itself a symlink.
        try fm.createSymbolicLink(at: assetsDirectory, withDestinationURL: elsewhere)
        var assets = store()
        XCTAssertFalse(assets.presentOnDisk([reference]))
        XCTAssertThrowsError(try assets.payload(for: reference))
        _ = try assets.stage(data)
        XCTAssertEqual(try assets.payload(for: reference), .data(data), "pending, not the linked file")
        XCTAssertThrowsError(try assets.persist([reference])) { XCTAssertEqual($0 as? ImageAssetError, .invalidDirectory) }
        XCTAssertThrowsError(try assets.collectGarbage(roots: [])) { XCTAssertEqual($0 as? ImageAssetError, .invalidDirectory) }
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: elsewhere.path), [reference.sha256])
        try fm.removeItem(at: assetsDirectory)

        // Assets/ a regular file.
        try Data([1]).write(to: assetsDirectory)
        assets = store(); _ = try assets.stage(data)
        XCTAssertThrowsError(try assets.persist([reference])) { XCTAssertEqual($0 as? ImageAssetError, .invalidDirectory) }
        try fm.removeItem(at: assetsDirectory)

        // A single asset a symlink (also a dangling one) or a directory.
        try fm.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
        for make in [{ try self.fm.createSymbolicLink(at: self.file(reference), withDestinationURL: elsewhere.appendingPathComponent(reference.sha256)) },
                     { try self.fm.createSymbolicLink(atPath: self.file(reference).path, withDestinationPath: "missing") },
                     { try self.fm.createDirectory(at: self.file(reference), withIntermediateDirectories: false) }] {
            try make()
            assets = store()
            XCTAssertFalse(assets.presentOnDisk([reference]))
            XCTAssertThrowsError(try assets.payload(for: reference))
            _ = try assets.stage(data)
            XCTAssertEqual(try assets.payload(for: reference), .data(data))
            XCTAssertThrowsError(try assets.persist([reference])) { XCTAssertEqual($0 as? ImageAssetError, .invalidDirectory) }
            XCTAssertNotNil(try? fm.attributesOfItem(atPath: file(reference).path), "left untouched")
            try fm.removeItem(at: file(reference))
        }
        XCTAssertEqual(try Data(contentsOf: elsewhere.appendingPathComponent(reference.sha256)), data)
    }

    func testPresenceIsStatOnly() throws {
        let assets = store()
        let a = try assets.stage(bytes(10, 1)), b = try assets.stage(bytes(20, 2))
        XCTAssertTrue(assets.presentOnDisk([]), "nothing referenced, no directory needed")
        XCTAssertEqual(assets.missingOnDisk([a, b]), [a, b])
        try assets.persist([a])
        XCTAssertEqual(assets.missingOnDisk([a, b]), [b])
        XCTAssertFalse(assets.presentOnDisk([ImageAssetReference(sha256: a.sha256, byteCount: 11)]), "size must match")
        XCTAssertFalse(assets.presentOnDisk([ImageAssetReference(sha256: a.sha256.uppercased(), byteCount: 10)]))
        try assets.persist([b])
        XCTAssertTrue(assets.presentOnDisk([a, b, a]))
    }

    func testReadOnlyInstanceNeverWrites() throws {
        let writer = store(), data = bytes(50, 3)
        let stored = try writer.stage(data)
        try writer.persist([stored])

        try? fm.removeItem(at: assetsDirectory)
        let reader = store(readOnly: true)
        let pendingOnly = try reader.stage(bytes(70, 8)) // e.g. legacy inline image of a preview
        XCTAssertEqual(try reader.payload(for: pendingOnly), .data(bytes(70, 8)))
        XCTAssertThrowsError(try reader.persist([pendingOnly])) { XCTAssertEqual($0 as? ImageAssetError, .readOnly) }
        XCTAssertThrowsError(try reader.collectGarbage(roots: [])) { XCTAssertEqual($0 as? ImageAssetError, .readOnly) }
        XCTAssertFalse(fm.fileExists(atPath: assetsDirectory.path), "not even the directory is created")

        try writer.persist([stored])
        XCTAssertEqual(try reader.verifiedPayload(for: stored), .file(file(stored)))
        XCTAssertThrowsError(try reader.persist([stored])) { XCTAssertEqual($0 as? ImageAssetError, .readOnly) }
        XCTAssertThrowsError(try reader.collectGarbage(roots: [], keeping: [])) { XCTAssertEqual($0 as? ImageAssetError, .readOnly) }
        XCTAssertEqual(names(), [stored.sha256])
    }

    func testFileDigestStreamsAndStopsAfterTheLimit() throws {
        let url = package.appendingPathComponent("blob")
        let data = bytes(1_000, 2)
        try data.write(to: url)
        let full = try NotebookAssets.digest(ofFile: url, limit: 1_000, blockSize: 3)
        XCTAssertEqual(full.sha256, SHA256.hexDigest(data)); XCTAssertEqual(full.byteCount, 1_000)
        XCTAssertEqual(try NotebookAssets.digest(ofFile: url, limit: 10, blockSize: 4).byteCount, 11)
        XCTAssertEqual(try NotebookAssets.digest(ofFile: url, limit: 999, blockSize: 4096).byteCount, 1_000)
    }
}

/// GC primitives (C2): raw root search, deletion rules, abort on read errors.
/// When the GC runs (open/close, backup lock) is C7.
final class ImageAssetGarbagePrimitiveTests: XCTestCase {
    private var package: URL!
    private let fm = FileManager.default
    private let later = Date().addingTimeInterval(30 * 60)    // assets old, partials young
    private let muchLater = Date().addingTimeInterval(2 * 3_600) // both old

    override func setUpWithError() throws {
        package = fm.temporaryDirectory.appendingPathComponent("assets-gc-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? fm.removeItem(at: package) }

    private var assetsDirectory: URL { package.appendingPathComponent("Assets", isDirectory: true) }
    private var roots: [URL] { NotebookAssets.garbageRoots(inPackage: package) }
    private func names() -> [String] { ((try? fm.contentsOfDirectory(atPath: assetsDirectory.path)) ?? []).sorted() }
    private func hash(_ seed: Int) -> String { SHA256.hexDigest(Data("asset \(seed)".utf8)) }
    private func store(at date: Date) -> NotebookAssets {
        let assets = NotebookAssets(package: package)
        assets.clock = { date }; assets.blockSize = 5
        return assets
    }
    @discardableResult
    private func asset(_ seed: Int) throws -> ImageAssetReference {
        let writer = NotebookAssets(package: package), data = Data("asset \(seed)".utf8)
        let reference = try writer.stage(data)
        try writer.persist([reference])
        return reference
    }
    private func write(_ text: String, _ path: String) throws {
        let url = package.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func testRootSearchFindsQuotedHashesInAnyBytesAcrossBlockBorders() throws {
        let h = (0..<8).map(hash)
        try write("{\"images\":[{\"asset\":{\"sha256\":\"\(h[0])\",\"byteCount\":7}}]}", "Revisions/A.json")
        try write("{ \"sha256\" : \"\(h[1])\" ,", "Quarantine/0000000001-X/B.json")       // Python spacing, truncated
        try write("\u{0}\u{ff}garbage\"\(h[2])\"\u{1}", "Migrations/X/notebook-v12.json")  // binary rest
        try write("\"\(h[3])\"\"\(h[4])\"", "Archives/Y/deep/er/c")                      // adjacent strings, nested
        try write("\(h[5]) \"\(h[6])0\" \"0\(h[6])\" \"\(h[6].uppercased())\" \"\(h[6].dropLast())\"", "Revisions/B.json")
        try write("\"\(h[7])\"", "Other/ignored.json")                                   // no root
        for size in [1, 2, 5, 63, 64, 65, 4096] {
            XCTAssertEqual(try NotebookAssets.referencedHashes(in: roots, blockSize: size), Set(h[0...4]), "block \(size)")
        }
        XCTAssertEqual(try NotebookAssets.referencedHashes(in: [package.appendingPathComponent("Missing")]), [])
        XCTAssertEqual(try NotebookAssets.referencedHashes(in: []), [])
    }

    /// The search sees exactly what JSONEncoder writes for a reference.
    func testRootSearchMatchesEncoderOutput() throws {
        struct Wrapper: Codable { var asset: ImageAssetReference; var data: Data }
        let reference = ImageAssetReference(of: Data("x".utf8))
        let encoded = try JSONEncoder().encode([Wrapper(asset: reference, data: Data(repeating: 0xab, count: 500))])
        try encoded.write(to: package.appendingPathComponent("Revisions/R.json", isDirectory: false).creatingParent())
        XCTAssertEqual(try NotebookAssets.referencedHashes(in: roots, blockSize: 3), [reference.sha256])
    }

    func testDeletionRulesKeepReferencedYoungForeignAndLinkedItems() throws {
        let referenced = try asset(1), pendingKept = try asset(2), kept = try asset(3)
        let unreferenced = try asset(4), other = try asset(5)
        try write("{\"sha256\":\"\(referenced.sha256)\"}", "Quarantine/1-A/R.json")
        let partial = "\(hash(9)).partial-\(UUID().uuidString)"
        try Data([1]).write(to: assetsDirectory.appendingPathComponent(partial))
        // Foreign names, lower-case partial UUID, a directory and a symlink with hash names.
        let lowerPartial = "\(hash(8)).partial-\(UUID().uuidString.lowercased())"
        for name in ["notes.txt", hash(6) + ".jpg", hash(6).uppercased(), lowerPartial] {
            try Data([2]).write(to: assetsDirectory.appendingPathComponent(name))
        }
        try fm.createDirectory(at: assetsDirectory.appendingPathComponent(hash(7)), withIntermediateDirectories: false)
        try fm.createSymbolicLink(atPath: assetsDirectory.appendingPathComponent(hash(10)).path, withDestinationPath: other.sha256)
        let foreign = names().filter { ![referenced, pendingKept, kept, unreferenced, other].map(\.sha256).contains($0) && $0 != partial }

        // Young: nothing goes.
        var assets = store(at: Date())
        _ = try assets.stage(Data("asset 2".utf8))
        XCTAssertEqual(try assets.collectGarbage(roots: roots, keeping: [kept.sha256]), ImageAssetGarbageReport())

        // Assets older than 15 min go, the partial (younger than 1 h) stays.
        assets = store(at: later)
        _ = try assets.stage(Data("asset 2".utf8))
        let report = try assets.collectGarbage(roots: roots, keeping: [kept.sha256])
        XCTAssertEqual(report.removedAssets, [unreferenced.sha256, other.sha256].sorted())
        XCTAssertEqual(report.removedPartials, [])
        XCTAssertEqual(names(), ([referenced.sha256, pendingKept.sha256, kept.sha256, partial] + foreign).sorted())

        // After an hour the partial goes as well; everything foreign stays.
        assets = store(at: muchLater)
        XCTAssertEqual(try assets.collectGarbage(roots: roots, keeping: [kept.sha256, pendingKept.sha256]),
                       ImageAssetGarbageReport(removedAssets: [], removedPartials: [partial]))
        XCTAssertEqual(names(), ([referenced.sha256, pendingKept.sha256, kept.sha256] + foreign).sorted())
        XCTAssertNotNil(try fm.destinationOfSymbolicLink(atPath: assetsDirectory.appendingPathComponent(hash(10)).path))

        // Missing Assets/ is an empty run.
        try fm.removeItem(at: assetsDirectory)
        XCTAssertEqual(try store(at: muchLater).collectGarbage(roots: roots), ImageAssetGarbageReport())
    }

    func testEveryKindOfRootKeepsItsAssets() throws {
        let references = try (20..<25).map(asset)
        try write("{\"sha256\":\"\(references[0].sha256)\"}", "Revisions/manifest-like.json")
        try write("{\"sha256\":\"\(references[1].sha256)\"", "Revisions/unreadable.json")     // damaged JSON
        try write("{\"sha256\":\"\(references[2].sha256)\"}", "Quarantine/0000000001-S/manifest.json")
        try write("{\"sha256\":\"\(references[3].sha256)\"}", "Migrations/M/notebook-v12.json")
        try write("{\"sha256\":\"\(references[4].sha256)\"}", "Archives/A/notebook.json")
        let unreferenced = try asset(30)
        let report = try store(at: later).collectGarbage(roots: roots)
        XCTAssertEqual(report.removedAssets, [unreferenced.sha256])
        XCTAssertEqual(names(), references.map(\.sha256).sorted())
    }

    func testReadErrorsInTheRootsAbortWithoutDeleting() throws {
        let unreferenced = try asset(40)
        // A root that is a file, or a symlink, is no readable root directory.
        try write("x", "Archives")
        XCTAssertThrowsError(try store(at: muchLater).collectGarbage(roots: roots)) {
            XCTAssertEqual($0 as? ImageAssetError, .garbageCollectionAborted)
        }
        try fm.removeItem(at: package.appendingPathComponent("Archives"))
        try fm.createSymbolicLink(atPath: package.appendingPathComponent("Archives").path, withDestinationPath: "nowhere")
        XCTAssertThrowsError(try store(at: muchLater).collectGarbage(roots: roots))
        try fm.removeItem(at: package.appendingPathComponent("Archives"))
        XCTAssertEqual(names(), [unreferenced.sha256])

        // An unreadable file (permissions) aborts the whole run.
        try write("{}", "Revisions/locked.json")
        let locked = package.appendingPathComponent("Revisions/locked.json")
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        try XCTSkipIf(FileManager.default.isReadableFile(atPath: locked.path), "running with privileges that ignore permissions")
        XCTAssertThrowsError(try store(at: muchLater).collectGarbage(roots: roots)) {
            XCTAssertEqual($0 as? ImageAssetError, .garbageCollectionAborted)
        }
        XCTAssertEqual(names(), [unreferenced.sha256])
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path)
        XCTAssertEqual(try store(at: muchLater).collectGarbage(roots: roots).removedAssets, [unreferenced.sha256])
    }

    func testPartialNamesAreExact() {
        let id = UUID().uuidString, h = hash(1)
        XCTAssertTrue(NotebookAssets.isPartialName("\(h).partial-\(id)"))
        XCTAssertFalse(NotebookAssets.isPartialName("\(h).partial-\(id.lowercased())"))
        XCTAssertFalse(NotebookAssets.isPartialName("\(h.uppercased()).partial-\(id)"))
        XCTAssertFalse(NotebookAssets.isPartialName("\(h).partial-\(id)x"))
        XCTAssertFalse(NotebookAssets.isPartialName("\(h).partial\(id)"))
        XCTAssertFalse(NotebookAssets.isPartialName(h))
        XCTAssertEqual(NotebookAssets.garbageRoots(inPackage: package).map(\.lastPathComponent), ["Revisions", "Quarantine", "Migrations", "Archives"])
    }
}

private extension URL {
    func creatingParent() throws -> URL {
        try FileManager.default.createDirectory(at: deletingLastPathComponent(), withIntermediateDirectories: true)
        return self
    }
}
