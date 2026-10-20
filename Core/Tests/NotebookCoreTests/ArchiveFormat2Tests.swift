import Foundation
import XCTest
@testable import NotebookCore

/// C5: `.notybackup` and `.notylibrary` format 2 (record stream). Until schema
/// 12 notebooks embed their images, so real archives carry no asset records;
/// these tests attach synthetic asset references (`ExternalAssetSeam`) to run
/// the asset paths: writing, checks, staging and restore.
final class ArchiveFormat2Tests: XCTestCase {
    private var attached: [UUID: [ImageAssetReference]] = [:]

    override func tearDown() {
        ExternalAssetSeam.set(nil)
        super.tearDown()
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("format2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// Attaches references to notebooks by document ID (for every reader and writer).
    private func attach(_ references: [UUID: [ImageAssetReference]]) {
        attached.merge(references) { _, new in new }
        let snapshot = attached
        ExternalAssetSeam.set { snapshot[$0.id] ?? [] }
    }

    private func bytes(_ count: Int, seed: UInt8) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ Int(seed)) }) }

    private func sample(_ title: String = "Format 2 · Ä") -> Notebook {
        var notebook = Notebook()
        notebook.title = title
        notebook.pdf = Data([1, 2, 3, 4])
        notebook.pages[0].text = "Inhalt ÄÖÜ"
        notebook.pages[0].drawing = Data([5, 6, 7])
        return notebook
    }

    // MARK: Record helpers (independent of the writer)

    private struct Parsed {
        var magic: Data
        var header: [String: Any]
        var records: [(descriptor: [String: Any], payload: Data)]
    }

    private func parse(_ data: Data) throws -> Parsed {
        func length(_ at: Int) -> Int { Int(data[data.startIndex + at..<data.startIndex + at + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }) }
        let headerLength = length(8)
        var offset = 12 + headerLength
        let header = try XCTUnwrap(JSONSerialization.jsonObject(with: data[data.startIndex + 12..<data.startIndex + offset]) as? [String: Any])
        var records: [(descriptor: [String: Any], payload: Data)] = []
        while offset < data.count {
            let count = length(offset)
            let descriptor = try XCTUnwrap(JSONSerialization.jsonObject(with: data[data.startIndex + offset + 4..<data.startIndex + offset + 4 + count]) as? [String: Any])
            offset += 4 + count
            let size = descriptor["byteCount"] as? Int ?? 0
            records.append((descriptor, Data(data[data.startIndex + offset..<data.startIndex + offset + size])))
            offset += size
        }
        return Parsed(magic: Data(data.prefix(8)), header: header, records: records)
    }

    private func build(_ parsed: Parsed) throws -> Data {
        func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
        func length(_ value: Int) -> Data { Data([UInt8(value >> 24), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]) }
        let header = try json(parsed.header)
        var data = parsed.magic + length(header.count) + header
        for record in parsed.records {
            let descriptor = try json(record.descriptor)
            data += length(descriptor.count) + descriptor + record.payload
        }
        return data
    }

    /// A fresh `end` record matching the records before it.
    private func withEnd(_ parsed: Parsed) -> Parsed {
        var result = parsed
        result.records.removeAll { $0.descriptor["kind"] as? String == "end" }
        let payload = result.records.reduce(0) { $0 + $1.payload.count }
        result.records.append((["kind": "end", "records": result.records.count, "payloadBytes": payload], Data()))
        return result
    }

    private func assetRecord(_ data: Data) -> (descriptor: [String: Any], payload: Data) {
        let reference = ImageAssetReference(of: data)
        return (["kind": "asset", "sha256": reference.sha256, "byteCount": reference.byteCount], data)
    }

    // MARK: Single notebook backup

    func testNotebookBackupIsAReproducibleRecordStreamAndFileEqualsMemory() throws {
        let document = sample()
        let created = Date(timeIntervalSince1970: 1_800_000_000.75)
        let archive = try BackupArchive.encode(document, createdAt: created)
        XCTAssertEqual(try BackupArchive.encode(document, createdAt: created), archive, "sorted keys everywhere: same values, same bytes")
        let parsed = try parse(archive)
        XCTAssertEqual(parsed.magic, BackupArchive.magic)
        XCTAssertEqual(Set(parsed.header.keys), BackupHeader.keys)
        XCTAssertEqual(parsed.header["backupFormatVersion"] as? Int, 2)
        XCTAssertEqual(parsed.header["assetHashAlgorithm"] as? String, "sha256")
        XCTAssertEqual(parsed.header["createdAt"] as? String, "2027-01-15T08:00:00Z")
        XCTAssertEqual(parsed.records.map { $0.descriptor["kind"] as? String }, ["notebook", "end"])
        XCTAssertEqual(parsed.records[1].descriptor["records"] as? Int, 1)
        XCTAssertEqual(parsed.records[1].descriptor["payloadBytes"] as? Int, parsed.records[0].payload.count)
        let decoded = try BackupArchive.decode(archive)
        XCTAssertEqual(decoded.document, document)
        XCTAssertEqual(decoded.formatVersion, 2)
        XCTAssertFalse(decoded.isLegacyJSON)
        XCTAssertEqual(decoded.assets, [])
        XCTAssertEqual(decoded.file, LibraryArchiveFileInfo(byteCount: archive.count, crc32: StreamingCRC32.checksum(archive)))

        let root = try directory()
        let url = root.appendingPathComponent("heft.notybackup")
        let written = try BackupArchive.write(document, to: url, createdAt: created)
        XCTAssertEqual(try Data(contentsOf: url), archive)
        XCTAssertEqual(written.file, try BoundedFile.checksum(url))
        // Never replaces an existing file.
        XCTAssertThrowsError(try BackupArchive.write(document, to: url, createdAt: created))
        XCTAssertEqual(try Data(contentsOf: url), archive)
        // Format 1 and prototype JSON stay readable through the streaming entry point.
        let old = root.appendingPathComponent("alt.notybackup")
        try BackupArchive.encodeVersion1(document).write(to: old)
        let v1 = try BackupArchive.verify(old)
        XCTAssertEqual(v1.document, document); XCTAssertEqual(v1.formatVersion, 1)
        XCTAssertEqual(v1.file, try BoundedFile.checksum(old))
        let json = root.appendingPathComponent("prototyp.json")
        try JSONEncoder().encode(document).write(to: json)
        XCTAssertTrue(try BackupArchive.verify(json).isLegacyJSON)
    }

    func testAssetsAreStreamedOnceVerifiedAndExtractedByHash() throws {
        let root = try directory()
        let document = sample()
        let a = bytes(3_000, seed: 1), b = bytes(10, seed: 2)
        attach([document.id: [ImageAssetReference(of: a), ImageAssetReference(of: b), ImageAssetReference(of: a)]])
        let assets = InlineImageAssets(bytes: [ImageAssetReference(of: a).sha256: a, ImageAssetReference(of: b).sha256: b])
        let url = root.appendingPathComponent("heft.notybackup")
        let written = try BackupArchive.write(document, assets: assets, to: url)
        XCTAssertEqual(written.assets, [ImageAssetReference(of: a), ImageAssetReference(of: b)], "unique, first occurrence")
        let parsed = try parse(Data(contentsOf: url))
        XCTAssertEqual(parsed.records.map { $0.descriptor["kind"] as? String }, ["notebook", "asset", "asset", "end"])
        XCTAssertEqual(Set(parsed.records[1].descriptor.keys), ["kind", "sha256", "byteCount"])
        XCTAssertEqual(parsed.records[1].payload, a)
        let extracted = root.appendingPathComponent("Assets", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: false)
        let decoded = try BackupArchive.verify(url, extractingAssetsTo: extracted)
        XCTAssertEqual(decoded.assets, written.assets)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: extracted.path).sorted(),
                       [ImageAssetReference(of: a).sha256, ImageAssetReference(of: b).sha256].sorted())
        XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent(ImageAssetReference(of: a).sha256)), a)
        // Asset files of a package (file payload) stream the same way.
        let package = NotebookAssets(package: root.appendingPathComponent("Paket"))
        _ = try package.stage(a); _ = try package.stage(b)
        try package.persist(written.assets); package.dropPending(written.assets)
        let fromFiles = root.appendingPathComponent("aus-dateien.notybackup")
        try BackupArchive.write(document, assets: package, to: fromFiles)
        XCTAssertEqual(try Data(contentsOf: fromFiles).count, try Data(contentsOf: url).count)
    }

    func testMissingOrDamagedSourceAssetLeavesNoArchive() throws {
        let root = try directory()
        let document = sample()
        let a = bytes(500, seed: 3)
        attach([document.id: [ImageAssetReference(of: a)]])
        let url = root.appendingPathComponent("heft.notybackup")
        XCTAssertThrowsError(try BackupArchive.write(document, assets: InlineImageAssets(), to: url)) { error in
            XCTAssertEqual(error as? ImageAssetError, .missing(ImageAssetReference(of: a).sha256))
        }
        XCTAssertThrowsError(try BackupArchive.write(document, to: url))
        // Bytes that do not hash to their name: aborted while streaming.
        let lying = InlineImageAssets(bytes: [ImageAssetReference(of: a).sha256: bytes(500, seed: 4)])
        XCTAssertThrowsError(try BackupArchive.write(document, assets: lying, to: url)) { error in
            XCTAssertEqual(error as? ImageAssetError, .damaged(ImageAssetReference(of: a).sha256))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testEveryStructuralViolationOfANotebookArchiveIsRejected() throws {
        let document = sample()
        let a = bytes(64, seed: 5), b = bytes(65, seed: 6)
        attach([document.id: [ImageAssetReference(of: a), ImageAssetReference(of: b)]])
        let assets = InlineImageAssets(bytes: [ImageAssetReference(of: a).sha256: a, ImageAssetReference(of: b).sha256: b])
        let valid = try parse(BackupArchive.encode(document, assets: assets))
        XCTAssertNoThrow(try BackupArchive.decode(build(valid)))
        // Asset order is free; the set is what counts.
        var swapped = valid; swapped.records.swapAt(1, 2)
        XCTAssertNoThrow(try BackupArchive.decode(build(swapped)))

        func rejects(_ parsed: Parsed, _ name: String, file: StaticString = #filePath, line: UInt = #line,
                     _ check: (Error) -> Void = { _ in }) throws {
            XCTAssertThrowsError(try BackupArchive.decode(build(parsed)), name, file: file, line: line, check)
        }
        var missing = valid; missing.records.remove(at: 2)
        try rejects(withEnd(missing), "missing asset")
        var extra = valid; extra.records.insert(assetRecord(bytes(66, seed: 7)), at: 3)
        try rejects(withEnd(extra), "extra asset")
        var duplicate = valid; duplicate.records.insert(valid.records[1], at: 3)
        try rejects(withEnd(duplicate), "duplicate asset")
        var flipped = valid; flipped.records[1].payload[10] ^= 1
        try rejects(flipped, "SHA-256 mismatch") { error in
            guard case BackupError.checksumMismatch = error else { return XCTFail("\(error)") }
        }
        var first = valid; first.records.swapAt(0, 1)
        try rejects(first, "asset before the notebook")
        var noEnd = valid; noEnd.records.removeLast()
        try rejects(noEnd, "no end record")
        var counts = valid; counts.records[3].descriptor["records"] = 2
        try rejects(counts, "wrong end totals")
        var trailing = try build(valid); trailing.append(0)
        XCTAssertThrowsError(try BackupArchive.decode(trailing), "trailing byte")
        var future = valid; future.header["backupFormatVersion"] = 3
        try rejects(future, "format 3") { error in
            guard case BackupError.unsupportedVersion(3) = error else { return XCTFail("\(error)") }
        }
        var headerKey = valid; headerKey.header["payloadName"] = "notebook.json"
        try rejects(headerKey, "extra header key")
        var descriptorKey = valid; descriptorKey.records[1].descriptor["crc32"] = 1
        try rejects(descriptorKey, "asset with a CRC")
        var path = valid; path.records[1].descriptor["sha256"] = "../" + String(repeating: "a", count: 61)
        try rejects(path, "path-like hash")
        var upper = valid; upper.records[1].descriptor["sha256"] = (valid.records[1].descriptor["sha256"] as! String).uppercased()
        try rejects(upper, "upper-case hash")
        var identity = valid; identity.records[0].descriptor["id"] = UUID().uuidString
        try rejects(identity, "notebook ID differs from the header")
        var kind = valid; kind.records[1].descriptor["kind"] = "../asset"
        try rejects(kind, "unknown record kind")
        var lowered = BackupArchiveLimits(); lowered.asset = 64
        var source = DataSource(data: try build(valid))
        XCTAssertThrowsError(try BackupArchive.readVersion2(&source, handling: .verify, limits: lowered), "asset above the limit")
    }

    func testRestoreCopiesStagedAssetsIntoTheNewPackageAndRechecksTheStage() async throws {
        let root = try directory()
        let repository = NotebookRepository(directory: root)
        let current = sample()
        try await repository.save(current, revision: 1)
        let a = bytes(2_000, seed: 8), b = bytes(30, seed: 9)
        let references = [ImageAssetReference(of: a), ImageAssetReference(of: b)]
        attach([current.id: references])
        // The package holds the committed originals (as from C6 on).
        let package = NotebookAssets(package: root)
        _ = try package.stage(a); _ = try package.stage(b)
        try package.persist(references); package.dropPending(references)
        let file = root.appendingPathComponent("extern.notybackup")
        try await repository.backup(current, to: file)

        let prepared = try await repository.prepareRestore(from: file)
        XCTAssertEqual(prepared.assetReferences, references)
        guard case .file(let staged) = try prepared.assets.verifiedPayload(for: references[0]) else { return XCTFail("staged file expected") }
        XCTAssertEqual(try Data(contentsOf: staged), a)
        attach([prepared.id: references])
        // Same size, other bytes in the stage: refused before anything is written.
        let original = try Data(contentsOf: staged)
        try bytes(2_000, seed: 10).write(to: staged)
        do { _ = try await repository.commitRestore(prepared); XCTFail("changed staged asset accepted") } catch { }
        let destination = root.appendingPathComponent("Restores/\(prepared.id.uuidString)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try original.write(to: staged)
        // A fresh repository reads the stage again (no session cache of the damage).
        let restored = try await NotebookRepository(directory: root).commitRestore(prepared)
        XCTAssertEqual(restored.directory.standardizedFileURL.path, destination.standardizedFileURL.path)
        for (reference, data) in zip(references, [a, b]) {
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Assets/\(reference.sha256)")), data)
        }
        XCTAssertEqual(try RevisionStore(directory: destination).load(), prepared.document)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("BackupStaging/\(prepared.id.uuidString)").path))
        // The original package is unchanged.
        XCTAssertEqual(try RevisionStore(directory: root).load(), current)
        XCTAssertTrue(NotebookAssets(package: root, readOnly: true).presentOnDisk(references))
    }

    func testLocalRecoveryCopiesAssetsFromTheOwnPackage() async throws {
        let root = try directory()
        let repository = NotebookRepository(directory: root)
        var document = sample()
        try await repository.save(document, revision: 1)
        let a = bytes(700, seed: 11)
        attach([document.id: [ImageAssetReference(of: a)]])
        let package = NotebookAssets(package: root)
        _ = try package.stage(a); try package.persist([ImageAssetReference(of: a)])
        document.pages[0].text = "neuer"
        try await repository.save(document, revision: 2)
        let history = try await repository.localHistory()
        let older = try XCTUnwrap(history.revisions.last)
        let prepared = try await repository.prepareLocalRecovery(id: older.id)
        XCTAssertEqual(prepared.assetReferences, [ImageAssetReference(of: a)])
        let restored = try await repository.commitRestore(prepared)
        XCTAssertEqual(try Data(contentsOf: restored.directory.appendingPathComponent("Assets/\(ImageAssetReference(of: a).sha256)")), a)
    }

    func testRejectedFileLeavesNoStagingAndKeepsTheStore() async throws {
        let root = try directory()
        let repository = NotebookRepository(directory: root)
        let document = sample()
        try await repository.save(document, revision: 1)
        let a = bytes(100, seed: 12)
        attach([document.id: [ImageAssetReference(of: a)]])
        let valid = try parse(BackupArchive.encode(document, assets: InlineImageAssets(bytes: [ImageAssetReference(of: a).sha256: a])))
        var damaged = valid; damaged.records[1].payload[0] ^= 1
        let file = root.appendingPathComponent("kaputt.notybackup")
        try build(damaged).write(to: file)
        do { _ = try await repository.prepareRestore(from: file); XCTFail("damaged asset accepted") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("BackupStaging").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Restores").path))
        XCTAssertEqual(try RevisionStore(directory: root).load(), document)
    }

    func testLoweredLimitsRefuseWithoutLeavingAFile() throws {
        let root = try directory()
        let document = sample()
        let a = bytes(5_000, seed: 21)
        attach([document.id: [ImageAssetReference(of: a)]])
        let assets = InlineImageAssets(bytes: [ImageAssetReference(of: a).sha256: a])
        let url = root.appendingPathComponent("heft.notybackup")
        var limits = BackupArchiveLimits(); limits.file = 4_000
        XCTAssertThrowsError(try BackupArchive.write(document, assets: assets, to: url, createdAt: Date(), limits: limits)) { error in
            guard case BackupError.fileTooLarge = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        limits = BackupArchiveLimits(); limits.notebook = 100
        XCTAssertThrowsError(try BackupArchive.write(document, assets: assets, to: url, createdAt: Date(), limits: limits)) { error in
            guard case BackupError.sizeLimit = error else { return XCTFail("\(error)") }
        }
        try BackupArchive.write(document, assets: assets, to: url)
        limits = BackupArchiveLimits(); limits.file = try Data(contentsOf: url).count - 1
        XCTAssertThrowsError(try BackupArchive.verify(url, handling: .verify, limits: limits)) { error in
            guard case BackupError.fileTooLarge = error else { return XCTFail("\(error)") }
        }
    }

    func testAssetStreamsAreIndependentOfBlockSizes() throws {
        let root = try directory()
        let payload = bytes(1_003, seed: 22)
        let reference = ImageAssetReference(of: payload)
        let file = root.appendingPathComponent("quelle")
        try payload.write(to: file)
        for (write, read) in [(7, 5), (1_003, 1_003), (4_096, 1), (64, 1_002)] {
            for source in [ImageAssetPayload.data(payload), .file(file)] {
                var writer = RecordWriter(DataSink(), limit: 10_000)
                writer.blockSize = write
                try writer.asset(reference, from: source)
                try writer.end()
                var reader = RecordReader(DataSource(data: writer.sink.data))
                reader.blockSize = read
                let directory = root.appendingPathComponent("aus-\(write)-\(read)-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let descriptor = try reader.descriptor()
                XCTAssertEqual(descriptor.assetReference, reference)
                try reader.asset(reference, .extract(directory))
                try reader.end(reader.descriptor())
                XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(reference.sha256)), payload)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [reference.sha256], "no partial file left")
            }
        }
        // Bytes that are longer, shorter or different never pass.
        for wrong in [payload + Data([0]), payload.dropLast(), bytes(1_003, seed: 23)] {
            var writer = RecordWriter(DataSink(), limit: 10_000)
            XCTAssertThrowsError(try writer.asset(reference, from: .data(Data(wrong)))) { XCTAssertTrue($0 is RecordArchiveAssetMismatch) }
        }
    }

    // MARK: Library

    private func library(at root: URL, titles: [String]) async throws -> (LibraryStore, [Notebook]) {
        let store = LibraryStore(root: root)
        _ = try await store.load()
        var notebooks: [Notebook] = []
        for title in titles {
            var notebook = Notebook(); notebook.title = title; notebook.pages[0].text = title
            _ = try await store.createDocument(notebook, parentID: nil)
            notebooks.append(notebook)
        }
        return (store, notebooks)
    }

    private func put(_ data: [Data], into package: URL) throws {
        let assets = NotebookAssets(package: package)
        for value in data { _ = try assets.stage(value) }
        try assets.persist(assets.pendingReferences); assets.dropPending(assets.pendingReferences)
    }

    func testSharedAssetsAreArchivedOnceAndRestoredIntoEveryPackage() async throws {
        let root = try directory()
        let (store, notebooks) = try await library(at: root.appendingPathComponent("Quelle"), titles: ["Eins", "Zwei", "Drei"])
        let shared = bytes(4_000, seed: 13), own = bytes(50, seed: 14)
        attach([notebooks[0].id: [ImageAssetReference(of: shared)],
                notebooks[1].id: [ImageAssetReference(of: own), ImageAssetReference(of: shared)]])
        for (notebook, data) in zip(notebooks.prefix(2), [[shared], [own, shared]]) {
            try put(data, into: await store.documentURL(id: notebook.id))
        }
        let plan = try await store.backupPlan()
        let file = root.appendingPathComponent("bibliothek.notylibrary")
        var validated: [(UUID, Bool)] = []
        let summary = try LibraryArchive.write(plan, to: file) { document, assets in
            validated.append((document.id, (try? assets.payload(for: ImageAssetReference(of: shared))) != nil))
        }
        XCTAssertEqual(validated.map(\.0), notebooks.map(\.id))
        XCTAssertEqual(validated.map(\.1), [true, true, false], "validation sees each package's own originals")
        XCTAssertEqual(summary.formatVersion, 2)
        XCTAssertEqual(summary.assetCount, 2)
        XCTAssertEqual(summary.assetBytes, shared.count + own.count)
        let parsed = try parse(Data(contentsOf: file))
        XCTAssertEqual(parsed.records.map { $0.descriptor["kind"] as? String },
                       ["index", "toolbar", "notebook", "asset", "notebook", "asset", "notebook", "end"])
        XCTAssertEqual(parsed.records[3].payload, shared)
        XCTAssertEqual(parsed.records[5].payload, own)

        let manager = WorkspaceStore(root: root.appendingPathComponent("Workspaces"))
        let seen = Recorded()
        let prepared = try await manager.prepareRestore(file: file) { document, assets in
            seen.set(document.id, document.externalImageAssets.filter { (try? assets.verifiedPayload(for: $0)) != nil }.count)
        }
        XCTAssertEqual(seen.value, [notebooks[0].id: 1, notebooks[1].id: 2, notebooks[2].id: 0], "validation sees the extracted originals")
        XCTAssertEqual(prepared.summary, summary)
        let area = try await manager.commitRestore(prepared, title: "Mit Bildern")
        let restoredRoot = try await manager.directory(for: area.id)
        for (notebook, data) in zip(notebooks.prefix(2), [[shared], [own, shared]]) {
            for value in data {
                let file = restoredRoot.appendingPathComponent("Library/Documents/\(notebook.id.uuidString)/Assets/\(ImageAssetReference(of: value).sha256)")
                XCTAssertEqual(try Data(contentsOf: file), value)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: restoredRoot.deletingLastPathComponent().appendingPathComponent("AssetScratch").path),
                       "the scratch is not part of the published area")
        let restoredDocuments = try await LibraryStore(root: restoredRoot).backupBundle().documents
        let sourceDocuments = try await store.backupBundle().documents
        XCTAssertEqual(restoredDocuments, sourceDocuments)
    }

    func testDamagedPackageAssetAbortsTheLibraryBackupWithTheNotebookTitle() async throws {
        let root = try directory()
        let (store, notebooks) = try await library(at: root.appendingPathComponent("Quelle"), titles: ["Bildheft"])
        let a = bytes(300, seed: 15)
        attach([notebooks[0].id: [ImageAssetReference(of: a)]])
        let package = try await store.documentURL(id: notebooks[0].id)
        try put([a], into: package)
        try bytes(300, seed: 16).write(to: package.appendingPathComponent("Assets/\(ImageAssetReference(of: a).sha256)"))
        let plan = try await store.backupPlan()
        let file = root.appendingPathComponent("bibliothek.notylibrary")
        XCTAssertThrowsError(try LibraryArchive.write(plan, to: file)) { error in
            XCTAssertEqual(error as? LibraryArchiveError, .damagedImage("Bildheft"))
        }
        try FileManager.default.removeItem(at: package.appendingPathComponent("Assets/\(ImageAssetReference(of: a).sha256)"))
        XCTAssertThrowsError(try LibraryArchive.write(plan, to: file)) { error in
            XCTAssertEqual(error as? LibraryArchiveError, .damagedImage("Bildheft"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testChangedScratchAssetIsRefusedAndNoAreaIsPublished() async throws {
        let root = try directory()
        let (store, notebooks) = try await library(at: root.appendingPathComponent("Quelle"), titles: ["Bildheft"])
        let a = bytes(900, seed: 17)
        attach([notebooks[0].id: [ImageAssetReference(of: a)]])
        try put([a], into: try await store.documentURL(id: notebooks[0].id))
        let file = root.appendingPathComponent("bibliothek.notylibrary")
        _ = try LibraryArchive.write(try await store.backupPlan(), to: file)
        let workspaces = root.appendingPathComponent("Workspaces")
        let manager = WorkspaceStore(root: workspaces)
        let prepared = try await manager.prepareRestore(file: file)
        let scratch = workspaces.appendingPathComponent("Staging/\(prepared.id.uuidString)/AssetScratch/\(ImageAssetReference(of: a).sha256)")
        try bytes(900, seed: 18).write(to: scratch)
        do { _ = try await manager.commitRestore(prepared, title: "Weg"); XCTFail("changed scratch accepted") } catch { }
        let list = try await manager.list()
        XCTAssertTrue(list.workspaces.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: workspaces.appendingPathComponent("Staging").path).isEmpty)
    }

    func testEveryGroupRuleOfALibraryArchiveIsEnforced() throws {
        var snapshot = LibrarySnapshot()
        var one = Notebook(); one.title = "Eins"
        var two = Notebook(); two.title = "Zwei"
        snapshot.items = [LibraryItem(id: one.id, title: one.title, source: .library), LibraryItem(id: two.id, title: two.title, source: .library)]
        let a = bytes(80, seed: 19), b = bytes(81, seed: 20)
        attach([one.id: [ImageAssetReference(of: a)], two.id: [ImageAssetReference(of: a), ImageAssetReference(of: b)]])
        let assets = InlineImageAssets(bytes: [ImageAssetReference(of: a).sha256: a, ImageAssetReference(of: b).sha256: b])
        let bundle = LibraryBundle(snapshot: snapshot, documents: [one, two])
        let encoded = try LibraryArchive.encode(bundle, assets: assets, createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(try LibraryArchive.encode(bundle, assets: assets, createdAt: Date(timeIntervalSince1970: 1_800_000_000)), encoded)
        let valid = try parse(encoded)
        XCTAssertEqual(valid.records.map { $0.descriptor["kind"] as? String }, ["index", "toolbar", "notebook", "asset", "notebook", "asset", "end"])
        XCTAssertEqual(Set(valid.header.keys), LibraryArchiveHeader.keys)
        XCTAssertEqual(try LibraryArchive.decode(build(valid)), bundle)

        func rejects(_ parsed: Parsed, _ name: String, file: StaticString = #filePath, line: UInt = #line,
                     _ check: (Error) -> Void = { _ in }) throws {
            XCTAssertThrowsError(try LibraryArchive.decode(build(parsed)), name, file: file, line: line, check)
        }
        var beforeNotebook = valid; beforeNotebook.records.insert(beforeNotebook.records.remove(at: 3), at: 2)
        try rejects(beforeNotebook, "asset before any notebook")
        // `b` is referenced only by the second notebook: not in the first group.
        var foreign = valid; foreign.records.insert(foreign.records.remove(at: 5), at: 4)
        try rejects(foreign, "asset not referenced by the preceding notebook")
        var twice = valid; twice.records.insert(valid.records[3], at: 6)
        try rejects(withEnd(twice), "the same hash twice")
        var missing = valid; missing.records.remove(at: 5)
        try rejects(withEnd(missing), "reference never carried")
        var late = valid; late.records.insert(late.records.remove(at: 3), at: 4)
        try rejects(late, "reference carried only after its notebook's group")
        var flipped = valid; flipped.records[5].payload[3] ^= 1
        try rejects(flipped, "SHA-256 mismatch") { error in
            guard case BackupError.checksumMismatch = error else { return XCTFail("\(error)") }
        }
        var noEnd = valid; noEnd.records.removeLast()
        try rejects(noEnd, "no end record")
        var trailing = try build(valid); trailing.append(contentsOf: [0, 0, 0, 0])
        XCTAssertThrowsError(try LibraryArchive.decode(trailing), "data after the end record")
        var future = valid; future.header["libraryBackupVersion"] = 3
        try rejects(future, "format 3") { error in XCTAssertEqual(error as? LibraryArchiveError, .unsupported(3)) }
        var entries = valid; entries.header["entries"] = []
        try rejects(entries, "format-1 manifest key in a format-2 header")
        var lostNotebook = valid; lostNotebook.records.removeSubrange(4...5)
        try rejects(withEnd(lostNotebook), "notebook of the index missing")
        var notebookCRC = valid; notebookCRC.records[2].payload[4] ^= 1
        try rejects(notebookCRC, "notebook CRC") { error in
            guard case BackupError.checksumMismatch = error else { return XCTFail("\(error)") }
        }
        var lowered = LibraryArchiveLimits(); lowered.asset = 80
        var source = DataSource(data: try build(valid))
        XCTAssertThrowsError(try LibraryArchive.read(&source, limits: lowered) { _, _ in }, "asset above the limit")
    }
}

private final class Recorded: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: Int] = [:]
    var value: [UUID: Int] { lock.lock(); defer { lock.unlock() }; return values }
    func set(_ id: UUID, _ count: Int) { lock.lock(); values[id] = count; lock.unlock() }
}
