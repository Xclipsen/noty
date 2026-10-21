import Foundation
import XCTest
@testable import NotebookCore

private func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
/// Deterministic incompressible-looking bytes (xorshift), fast enough for debug builds.
private func payload(_ count: Int, seed: UInt64) -> Data {
    var state = seed | 1, data = Data(count: count)
    data.withUnsafeMutableBytes { bytes in
        for index in 0..<count { state ^= state << 13; state ^= state >> 7; state ^= state << 17; bytes[index] = UInt8(truncatingIfNeeded: state) }
    }
    return data
}
private func library(_ count: Int, bytes: Int, at root: URL) async throws -> (LibraryStore, [Notebook]) {
    let store = LibraryStore(root: root); _ = try await store.load()
    let folder = try await store.createFolder(title: "Fach", parentID: nil).items.last!.id
    var notebooks: [Notebook] = []
    for index in 0..<count {
        var notebook = Notebook(); notebook.title = "Heft \(index + 1) · ÄÖÜ"
        notebook.pages[0].drawing = payload(bytes, seed: UInt64(index + 1)); notebook.pages[0].text = "Seite \(index)"
        _ = try await store.createDocument(notebook, parentID: index.isMultiple(of: 2) ? folder : nil)
        notebooks.append(notebook)
    }
    if let last = notebooks.last { _ = try await store.trash(last.id) }
    return (store, notebooks)
}

final class LibraryArchiveStreamingTests: XCTestCase {
    func testStreamingCRCMatchesReferenceVectorAndBlockSplits() {
        /// Bitwise CRC-32/ISO-HDLC, independent of both table implementations.
        func bitwise(_ data: Data) -> UInt32 {
            var crc: UInt32 = 0xffffffff
            for byte in data {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) }
            }
            return crc ^ 0xffffffff
        }
        XCTAssertEqual(StreamingCRC32.checksum(Data("123456789".utf8)), 0xCBF43926)
        XCTAssertEqual(SnapshotChecksum.crc32(Data("123456789".utf8)), 0xCBF43926)
        let data = payload(100_003, seed: 7)
        XCTAssertEqual(StreamingCRC32.checksum(data), bitwise(data))
        XCTAssertEqual(SnapshotChecksum.crc32(data), bitwise(data))
        for count in 0..<20 { XCTAssertEqual(SnapshotChecksum.crc32(data.prefix(count)), bitwise(data.prefix(count))) }
        XCTAssertEqual(SnapshotChecksum.crc32(data.dropFirst(3)), bitwise(data.dropFirst(3)), "slices with an offset")
        var split = StreamingCRC32()
        for range in [0..<1, 1..<9, 9..<4096, 4096..<99_999, 99_999..<100_003] { split.update(data.subdata(in: range)) }
        XCTAssertEqual(split.value, bitwise(data))
        XCTAssertEqual(StreamingCRC32.checksum(Data()), 0)
    }

    /// Lowered limits stand in for 200 MB/notebook and 4 GB/archive: the whole
    /// library is larger than one notebook chunk (the former total cap).
    func testLibraryLargerThanOneNotebookChunkStreamsToFileAndRestores() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let (store, notebooks) = try await library(8, bytes: 60_000, at: root.appendingPathComponent("Quelle"))
        var limits = LibraryArchiveLimits(); limits.notebook = 120_000; limits.total = 2_000_000
        let plan = try await store.backupPlan()
        let file = root.appendingPathComponent("bibliothek.notylibrary")
        var validated: [UUID] = []
        let summary = try LibraryArchive.write(plan, to: file, limits: limits) { document, _ in validated.append(document.id) }
        XCTAssertEqual(validated, notebooks.map(\.id))
        XCTAssertEqual(summary.notebooks.map(\.id), notebooks.map(\.id))
        XCTAssertGreaterThan(summary.file.byteCount, limits.notebook * 4)
        XCTAssertEqual(summary.file, try BoundedFile.checksum(file))
        XCTAssertEqual(summary.trashedCount, 1); XCTAssertEqual(summary.folderCount, 1)
        // The same file is an ordinary format-2 archive for the in-memory reader.
        let bundle = try await store.backupBundle()
        XCTAssertEqual(try LibraryArchive.decode(Data(contentsOf: file)), bundle)
        let manager = WorkspaceStore(root: root.appendingPathComponent("Workspaces"))
        let prepared = try await manager.prepareRestore(file: file)
        XCTAssertEqual(prepared.summary, summary)
        let area = try await manager.commitRestore(prepared, title: "Großer Restore")
        let restored = try await LibraryStore(root: manager.directory(for: area.id)).backupBundle()
        XCTAssertEqual(restored.documents, bundle.documents)
        XCTAssertEqual(restored.snapshot.items.map(\.deletedAt), bundle.snapshot.items.map(\.deletedAt))
    }

    func testSizeLimitsRejectWithoutLeavingAFile() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let (store, notebooks) = try await library(4, bytes: 30_000, at: root.appendingPathComponent("Quelle"))
        let plan = try await store.backupPlan()
        let file = root.appendingPathComponent("zu-gross.notylibrary")
        var limits = LibraryArchiveLimits(); limits.notebook = 20_000
        XCTAssertThrowsError(try LibraryArchive.write(plan, to: file, limits: limits)) { error in
            XCTAssertEqual(error as? LibraryArchiveError, .notebookTooLarge(notebooks[0].title))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        limits = LibraryArchiveLimits(); limits.total = 100_000
        XCTAssertThrowsError(try LibraryArchive.write(plan, to: file, limits: limits)) { error in
            XCTAssertEqual(error as? LibraryArchiveError, .archiveTooLarge)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        // An existing file is never replaced.
        try Data([7]).write(to: file)
        XCTAssertThrowsError(try LibraryArchive.write(plan, to: file))
        XCTAssertEqual(try Data(contentsOf: file), Data([7]))
        let ok = root.appendingPathComponent("ok.notylibrary"); _ = try LibraryArchive.write(plan, to: ok)
        let big = try Data(contentsOf: ok)
        var readLimits = LibraryArchiveLimits(); readLimits.total = big.count - 1
        var source = BytesSource(big)
        XCTAssertThrowsError(try LibraryArchive.read(&source, limits: readLimits) { _, _ in }) { error in
            XCTAssertEqual(error as? LibraryArchiveError, .archiveTooLarge)
        }
    }

    func testWriterAppendsEachNotebookBeforeLoadingTheNext() throws {
        var snapshot = LibrarySnapshot()
        let documents = (0..<4).map { index -> Notebook in
            var notebook = Notebook(); notebook.title = "N\(index)"; notebook.pages[0].drawing = payload(5_000, seed: UInt64(index + 9)); return notebook
        }
        snapshot.items = documents.map { LibraryItem(id: $0.id, title: $0.title, source: .library) }
        let sink = RecordingSink()
        var writer = sink
        _ = try LibraryArchive.write(snapshot: snapshot, toolbar: ToolbarPreferences(), documents: snapshot.items, createdAt: Date(),
                                     into: &writer, limits: .standard, document: { item in
            sink.events.append("load")
            return (documents.first { $0.id == item.id }!, InlineImageAssets())
        }, validate: { _, _ in sink.events.append("validate") })
        // Header, index and toolbar records (descriptor + payload); then strictly
        // load → validate → descriptor → payload per notebook; end record last.
        // Nothing is ever patched afterwards (no reserved manifest in format 2).
        XCTAssertEqual(sink.events, Array(repeating: "append", count: 5)
                       + Array(repeating: ["load", "validate", "append", "append"], count: 4).flatMap { $0 } + ["append"])
        XCTAssertEqual(try LibraryArchive.decode(sink.data).documents, documents)
    }

    func testReaderVisitsNotebooksOneByOneAndStopsAtFirstDamagedChunk() throws {
        var snapshot = LibrarySnapshot()
        let documents = (0..<4).map { index -> Notebook in var notebook = Notebook(); notebook.title = "N\(index)"; return notebook }
        snapshot.items = documents.map { LibraryItem(id: $0.id, title: $0.title, source: .library) }
        var data = try LibraryArchive.encode(LibraryBundle(snapshot: snapshot, documents: documents))
        let url = temporaryRoot(); defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        var visited: [UUID] = []
        _ = try LibraryArchive.verify(url) { visited.append($0.id) }
        XCTAssertEqual(visited, documents.map(\.id))
        // Damage inside the third notebook chunk: the first two were already
        // visited (sequential streaming), the third is never handed out.
        let third = String(decoding: try LibraryArchive.chunkEncoder().encode(documents[2]), as: UTF8.self)
        let marker = data.range(of: Data(third.utf8))!
        data[marker.lowerBound + 5] ^= 1
        try data.write(to: url)
        visited = []
        XCTAssertThrowsError(try LibraryArchive.verify(url) { visited.append($0.id) }) { error in
            guard case BackupError.checksumMismatch = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(visited, Array(documents.prefix(2).map(\.id)))
        // Errors of the visitor itself are passed through unchanged.
        struct Rejected: Error {}
        try LibraryArchive.encode(LibraryBundle(snapshot: snapshot, documents: documents)).write(to: url)
        XCTAssertThrowsError(try LibraryArchive.verify(url) { _ in throw Rejected() }) { XCTAssertTrue($0 is Rejected) }
    }

    func testPaddedManifestIsPlainJSONAndUnpaddedArchivesStillRead() throws {
        var snapshot = LibrarySnapshot(); var notebook = Notebook(); notebook.title = "Alt"
        snapshot.items = [LibraryItem(id: notebook.id, title: notebook.title, source: .legacyMain)]
        let bundle = LibraryBundle(snapshot: snapshot, documents: [notebook])
        let data = try LibraryArchive.encodeVersion1(bundle)
        let length = Int(data.dropFirst(8).prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        let header = Data(data.dropFirst(12).prefix(length))
        XCTAssertEqual(header.last, 0x20)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: header))
        // Rewrite as an unpadded manifest, exactly like Build ≤ 46 wrote it.
        let compact = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: header))
        var old = LibraryArchive.magic
        old.append(contentsOf: [0, UInt8(compact.count >> 16), UInt8((compact.count >> 8) & 255), UInt8(compact.count & 255)])
        old.append(compact); old.append(data.dropFirst(12 + length))
        XCTAssertEqual(try LibraryArchive.decode(old), bundle)
    }

    /// Exactly the Build ≤ 46 writer: default JSONEncoder chunks, compact manifest.
    private func legacyArchive(_ bundle: LibraryBundle) throws -> Data {
        let chunks = [try JSONEncoder().encode(bundle.snapshot), try JSONEncoder().encode(bundle.toolbar)] + (try bundle.documents.map { try JSONEncoder().encode($0) })
        var entries = [LibraryArchiveEntry(kind: "index", byteCount: chunks[0].count, crc32: SnapshotChecksum.crc32(chunks[0])),
                       LibraryArchiveEntry(kind: "toolbar", byteCount: chunks[1].count, crc32: SnapshotChecksum.crc32(chunks[1]))]
        for (document, chunk) in zip(bundle.documents, chunks.dropFirst(2)) {
            entries.append(LibraryArchiveEntry(kind: "notebook", id: document.id, byteCount: chunk.count, crc32: SnapshotChecksum.crc32(chunk)))
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let manifest = try encoder.encode(LibraryArchiveManifest(createdAt: Date(timeIntervalSince1970: 1_790_000_000), entries: entries))
        var data = LibraryArchive.magic
        data.append(contentsOf: [0, UInt8(manifest.count >> 16), UInt8((manifest.count >> 8) & 255), UInt8(manifest.count & 255)])
        data.append(manifest); chunks.forEach { data.append($0) }
        return data
    }

    func testArchiveOfAnOlderBuildStillVerifiesAndRestores() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let (store, _) = try await library(3, bytes: 2_000, at: root.appendingPathComponent("Quelle"))
        let bundle = try await store.backupBundle()
        let file = root.appendingPathComponent("build46.notylibrary")
        try legacyArchive(bundle).write(to: file)
        XCTAssertEqual(try LibraryArchive.decode(Data(contentsOf: file)), bundle)
        let manager = WorkspaceStore(root: root.appendingPathComponent("Workspaces"))
        let prepared = try await manager.prepareRestore(file: file)
        XCTAssertEqual(prepared.summary.file, try BoundedFile.checksum(file))
        let area = try await manager.commitRestore(prepared, title: "Alt")
        let restored = try await LibraryStore(root: manager.directory(for: area.id)).backupBundle()
        XCTAssertEqual(restored.documents, bundle.documents)
    }

    private func files(_ directory: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let base = directory.standardizedFileURL.path
        for case let url as URL in FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])! {
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            result[String(url.standardizedFileURL.path.dropFirst(base.count))] = try Data(contentsOf: url)
        }
        return result
    }

    /// A damaged newest revision must not block every library backup: the
    /// notebook goes in with the state its editor opens, reported as warning.
    func testDamagedNewestRevisionArchivesTheReadableOlderStateWithWarning() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let (store, notebooks) = try await library(2, bytes: 500, at: root.appendingPathComponent("Quelle"))
        let directory = try await store.documentURL(id: notebooks[0].id)
        var newer = notebooks[0]; newer.pages[0].text = "neuer, danach beschädigt"
        try RevisionStore(directory: directory).save(newer)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("manifest.json"))) as! [String: Any]
        let latest = directory.appendingPathComponent("Revisions/\((manifest["revisions"] as! [[String: Any]])[0]["file"] as! String)")
        try Data("damaged".utf8).write(to: latest)
        let opened = RevisionStore(directory: directory)
        let editorState = try opened.load()
        XCTAssertTrue(opened.recovered); XCTAssertEqual(editorState.pages[0].text, notebooks[0].pages[0].text)
        let before = try files(directory)
        let plan = try await store.backupPlan()
        let file = root.appendingPathComponent("mit-hinweis.notylibrary")
        var older: [UUID] = []
        let summary = try LibraryArchive.write(plan, to: file, olderState: { older.append($0.id) })
        XCTAssertEqual(older, [notebooks[0].id])
        XCTAssertEqual(summary.notebooks.count, 2)
        let decoded = try LibraryArchive.decode(Data(contentsOf: file))
        XCTAssertEqual(decoded.documents.first { $0.id == notebooks[0].id }, editorState)
        XCTAssertEqual(decoded.documents.first { $0.id == notebooks[1].id }, notebooks[1])
        // Read-only: damaged revision, manifest and everything else stay as they were (no quarantine move).
        XCTAssertEqual(try files(directory), before)
        // The in-memory helper has no warning channel and still refuses.
        do { _ = try await store.backupBundle(); XCTFail("silent older state") } catch LibraryArchiveError.incomplete { }
        // The archive is an ordinary one: verification and restore expect nothing special.
        let manager = WorkspaceStore(root: root.appendingPathComponent("Workspaces"))
        let area = try await manager.commitRestore(try await manager.prepareRestore(file: file), title: "Mit Hinweis")
        let restored = try await LibraryStore(root: manager.directory(for: area.id)).backupBundle()
        XCTAssertEqual(restored.documents, decoded.documents)
        XCTAssertEqual(ExternalBackupPolicy.olderStateWarning([notebooks[0].title]),
                       "„Heft 1 · ÄÖÜ“: älterer lesbarer Stand gesichert, neuere Revision beschädigt")
        XCTAssertNil(ExternalBackupPolicy.olderStateWarning([]))
    }

    func testStartupRemovesOnlyStaleUnownedStagesAndNeverAreas() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let (store, _) = try await library(1, bytes: 100, at: root.appendingPathComponent("Quelle"))
        let file = root.appendingPathComponent("in.notylibrary")
        let plan = try await store.backupPlan(); _ = try LibraryArchive.write(plan, to: file)
        let workspaces = root.appendingPathComponent("Workspaces"), staging = workspaces.appendingPathComponent("Staging")
        let earlierRun = WorkspaceStore(root: workspaces)
        let leftover = try await earlierRun.prepareRestore(file: file)
        let launch = WorkspaceStore(root: workspaces)
        let owned = try await launch.prepareRestore(file: file)
        let area = try await launch.commitRestore(try await launch.prepareRestore(file: file), title: "Bereich")
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("Notizen"), withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data([5]).write(to: outside.appendingPathComponent("keep"))
        let link = UUID().uuidString
        try FileManager.default.createSymbolicLink(at: staging.appendingPathComponent(link), withDestinationURL: outside)
        let fresh = await launch.removeStaleStages(now: Date())
        XCTAssertEqual(fresh, 0)
        let removed = await launch.removeStaleStages(now: Date().addingTimeInterval(2 * 86400))
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: staging.path)), [owned.id.uuidString, "Notizen", link])
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.appendingPathComponent(leftover.id.uuidString).path))
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("keep")), Data([5]))
        let listed = try await launch.list(); XCTAssertEqual(listed.workspaces.map(\.id), [area.id])
        // The stage this run still owns stays usable.
        _ = try await launch.commitRestore(owned, title: "Später")
        let both = try await launch.list(); XCTAssertEqual(both.workspaces.count, 2)
    }

    func testWriteReadsTheLatestCommitAfterConcurrentSaves() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let (store, notebooks) = try await library(2, bytes: 1_000, at: root.appendingPathComponent("Quelle"))
        let plan = try await store.backupPlan()
        // Five commits after the plan: revisions named by the old manifest are gone.
        let package = try await store.documentURL(id: notebooks[0].id)
        var edited = notebooks[0]
        for step in 1...5 { edited.pages[0].text = "Stand \(step)"; try RevisionStore(directory: package).save(edited) }
        let file = root.appendingPathComponent("a.notylibrary")
        _ = try LibraryArchive.write(plan, to: file)
        let decoded = try LibraryArchive.decode(Data(contentsOf: file))
        XCTAssertEqual(decoded.documents.first { $0.id == edited.id }?.pages[0].text, "Stand 5")
    }

    func testPreparedRestoreValidatesEachNotebookAndRemovesAFailedStage() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let (store, notebooks) = try await library(3, bytes: 500, at: root.appendingPathComponent("Quelle"))
        let file = root.appendingPathComponent("in.notylibrary")
        let plan = try await store.backupPlan(); _ = try LibraryArchive.write(plan, to: file)
        let workspaces = root.appendingPathComponent("Workspaces")
        let manager = WorkspaceStore(root: workspaces)
        struct FrameworkRejected: Error {}
        let rejected = notebooks[1].id
        do { _ = try await manager.prepareRestore(file: file) { document, _ in if document.id == rejected { throw FrameworkRejected() } }; XCTFail("accepted") }
        catch is FrameworkRejected { }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: workspaces.appendingPathComponent("Staging").path).isEmpty)
        let prepared = try await manager.prepareRestore(file: file)
        XCTAssertEqual(prepared.summary.notebooks.map(\.id), notebooks.map(\.id))
        try await manager.discardRestore(prepared)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: workspaces.appendingPathComponent("Staging").path).isEmpty)
        do { _ = try await manager.commitRestore(prepared, title: "Weg"); XCTFail("discarded stage committed") } catch { }
        let list = try await manager.list(); XCTAssertTrue(list.workspaces.isEmpty)
        // A damaged source never leaves a stage behind.
        var data = try Data(contentsOf: file); data[data.count - 2] ^= 1; try data.write(to: file)
        do { _ = try await manager.prepareRestore(file: file); XCTFail("damaged accepted") } catch { }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: workspaces.appendingPathComponent("Staging").path).isEmpty)
    }
}

private final class RecordingSink: LibraryArchiveSink {
    var events: [String] = []
    var data = Data()
    func append(_ data: Data) { events.append("append"); self.data.append(data) }
    func replace(at offset: Int, with data: Data) { events.append("replace"); self.data.replaceSubrange(offset..<offset + data.count, with: data) }
}
private struct BytesSource: LibraryArchiveSource {
    let data: Data; var offset = 0
    init(_ data: Data) { self.data = data }
    var size: Int { data.count }
    mutating func read(_ count: Int) throws -> Data {
        guard count <= data.count - offset else { throw LibraryArchiveError.invalid }
        defer { offset += count }; return data.subdata(in: offset..<offset + count)
    }
    func atEnd() -> Bool { offset == data.count }
}

/// Folder double: optionally damages a file right before a coordinated read or refuses a move.
private struct FaultyFiles: BackupFileCoordinating {
    var damageOnRead: String?
    var failMove = false
    func reading(_ url: URL, metadataOnly: Bool, _ body: (URL) throws -> Void) throws {
        if let damageOnRead, url.lastPathComponent == damageOnRead { try Data([0]).write(to: url) }
        try body(url)
    }
    func writing(_ url: URL, _ body: (URL) throws -> Void) throws { try body(url) }
    func moving(_ source: URL, to destination: URL, _ body: (URL, URL) throws -> Void) throws {
        if failMove { throw CocoaError(.fileWriteNoPermission) }
        try body(source, destination)
    }
    func deleting(_ url: URL, _ body: (URL) throws -> Void) throws { try body(url) }
}

final class ExternalBackupPipelineTests: XCTestCase {
    private func folder() throws -> (URL, URL, URL, LibraryArchiveFileInfo) {
        let root = temporaryRoot(), target = root.appendingPathComponent("iCloud")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("local.notylibrary")
        try LibraryArchive.encode(LibraryBundle(snapshot: LibrarySnapshot(), documents: [])).write(to: source)
        return (root, target, source, try LibraryArchive.verify(source).file)
    }

    func testBackoffGrowsResetsOnSuccessAndOldStoredPolicyStillDecodes() throws {
        var policy = ExternalBackupPolicy(); policy.startTarget(.webDAV, at: Date(timeIntervalSince1970: 1_000))
        policy.endpoint = "https://example.org/dav/"
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(policy.due(at: start))
        var time = start
        for (failures, wait) in [(1, 900.0), (2, 3600), (3, 4 * 3600), (4, 12 * 3600), (9, 12 * 3600)] {
            while (policy.consecutiveFailures ?? 0) < failures { policy.recordFailure(.unreachable, reason: "Server nicht erreichbar", at: time) }
            XCTAssertFalse(policy.due(at: time.addingTimeInterval(wait - 1)), "\(failures)")
            XCTAssertTrue(policy.due(at: time.addingTimeInterval(wait)), "\(failures)")
            time = time.addingTimeInterval(wait)
        }
        XCTAssertEqual(policy.lastOutcome, .unreachable); XCTAssertEqual(policy.lastFailureReason, "Server nicht erreichbar")
        policy.recordSuccess(at: time)
        XCTAssertNil(policy.consecutiveFailures); XCTAssertNil(policy.lastFailureReason); XCTAssertEqual(policy.lastOutcome, .succeeded)
        XCTAssertFalse(policy.due(at: time.addingTimeInterval(24 * 3600 - 1)))
        XCTAssertTrue(policy.due(at: time.addingTimeInterval(24 * 3600)))
        // A clock set back never blocks the next attempt indefinitely.
        policy.recordFailure(.failed, reason: "x", at: time.addingTimeInterval(30 * 24 * 3600))
        XCTAssertTrue(policy.due(at: time.addingTimeInterval(25 * 3600)))
        try policy.validate()
        XCTAssertEqual(try JSONDecoder().decode(ExternalBackupPolicy.self, from: JSONEncoder().encode(policy)), policy)
        // Build ≤ 46 stored none of the new keys.
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(policy)) as! [String: Any]
        for key in ["configuredAt", "lastOutcome", "lastFailureReason", "consecutiveFailures"] { legacy.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(ExternalBackupPolicy.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.consecutiveFailures); XCTAssertNil(decoded.lastOutcome); try decoded.validate()
        var negative = policy; negative.consecutiveFailures = -1; XCTAssertThrowsError(try negative.validate())
    }

    func testHealthDistinguishesFailureUnreachableStaleAndNeverPostponed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var policy = ExternalBackupPolicy()
        XCTAssertEqual(ExternalBackupHealth(policy, folderUnreachable: false, running: false, now: now), .notConfigured)
        policy.target = .folder; policy.folderBookmark = Data([1])
        // Build ≤ 46 stored the attempt time before building, also for postponed runs.
        policy.lastSuccess = now.addingTimeInterval(-7200); policy.lastAttempt = now.addingTimeInterval(-60)
        XCTAssertEqual(ExternalBackupHealth(policy, folderUnreachable: false, running: false, now: now), .ok(policy.lastSuccess!))
        policy.recordFailure(.failed, reason: "Bibliothek größer als 4 GB", at: now.addingTimeInterval(-30))
        XCTAssertEqual(ExternalBackupHealth(policy, folderUnreachable: false, running: false, now: now), .failed("Bibliothek größer als 4 GB"))
        XCTAssertEqual(ExternalBackupHealth(policy, folderUnreachable: false, running: true, now: now), .ok(policy.lastSuccess!))
        XCTAssertEqual(ExternalBackupHealth(policy, folderUnreachable: true, running: false, now: now), .folderUnreachable)
        policy.recordFailure(.unreachable, reason: "Server nicht erreichbar (offline?)", at: now)
        XCTAssertEqual(ExternalBackupHealth(policy, folderUnreachable: false, running: false, now: now), .unreachable("Server nicht erreichbar (offline?)"))
        XCTAssertEqual(ExternalBackupHealth(policy, folderUnreachable: false, running: false, now: now.addingTimeInterval(3 * 86400)),
                       .stale(policy.lastSuccess))
        // A success with warning is a success: backoff reset, shown, not a failure.
        policy.recordSuccess(at: now, warning: "„X“: älterer lesbarer Stand gesichert, neuere Revision beschädigt")
        let warned = ExternalBackupHealth(policy, folderUnreachable: false, running: false, now: now)
        XCTAssertEqual(warned, .warning(now, "„X“: älterer lesbarer Stand gesichert, neuere Revision beschädigt"))
        XCTAssertTrue(warned.isSetUp); XCTAssertNil(policy.consecutiveFailures); XCTAssertFalse(policy.due(at: now.addingTimeInterval(3600)))
        policy.recordSuccess(at: now)
        XCTAssertNil(policy.lastWarning)
        XCTAssertEqual(ExternalBackupHealth(policy, folderUnreachable: false, running: false, now: now), .ok(now))
        var fresh = ExternalBackupPolicy(); fresh.folderBookmark = Data([1]); fresh.startTarget(.folder, at: now)
        XCTAssertEqual(ExternalBackupHealth(fresh, folderUnreachable: false, running: false, now: now.addingTimeInterval(3600)), .firstPending)
        XCTAssertEqual(ExternalBackupHealth(fresh, folderUnreachable: false, running: false, now: now.addingTimeInterval(4 * 86400)), .stale(nil))
    }

    func testTemporaryNamesAreOwnAndStaleOnlyAfterADay() {
        let policy = ExternalBackupPolicy(), now = Date(timeIntervalSince1970: 1_700_100_000)
        let old = policy.filename(at: now.addingTimeInterval(-25 * 3600)), fresh = policy.filename(at: now.addingTimeInterval(-3600))
        let foreign = ExternalBackupPolicy().filename(at: now.addingTimeInterval(-90 * 3600))
        XCTAssertNil(policy.timestamp(old + ".partial"))
        XCTAssertNotNil(policy.temporaryTimestamp(old + ".failed"))
        XCTAssertNil(policy.temporaryTimestamp(foreign + ".partial"))
        XCTAssertEqual(policy.staleTemporaries([old + ".partial", fresh + ".partial", foreign + ".partial", old, "x.partial"], now: now), [old + ".partial"])
    }

    func testICloudPlaceholdersCountForRetentionAndAreRemovedWithoutDownload() throws {
        let (root, target, source, info) = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        var policy = ExternalBackupPolicy(); policy.keep = 3
        let names = (0..<5).map { policy.filename(at: Date(timeIntervalSince1970: Double(1_700_000_000 + $0))) }
        // Two oldest only in the cloud, one evicted and one downloaded copy coexisting.
        for name in names.prefix(3) { try Data("placeholder".utf8).write(to: target.appendingPathComponent("." + name + ".icloud")) }
        try ExternalBackupFolder.write(archive: source, file: info, name: names[3], policy: policy, directory: target)
        let foreignPlaceholder = "." + ExternalBackupPolicy().filename() + ".icloud"
        try Data([1]).write(to: target.appendingPathComponent(foreignPlaceholder))
        let listing = try ExternalBackupFolder.list(policy: policy, directory: target)
        XCTAssertEqual(listing.archives, Array(names.prefix(4).reversed()))
        XCTAssertEqual(listing.placeholders, Set(names.prefix(3)))
        try ExternalBackupFolder.write(archive: source, file: info, name: names[4], policy: policy, directory: target)
        let removed = try ExternalBackupFolder.prune(policy: policy, directory: target, verified: names[4], file: info)
        XCTAssertEqual(Set(removed), Set(names.prefix(2)))
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: target.path))
        XCTAssertEqual(left, [names[3], names[4], "." + names[2] + ".icloud", foreignPlaceholder])
    }

    func testFailedReadBackRemovesFinalFileAndFailedMoveRemovesPartial() throws {
        let (root, target, source, info) = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let policy = ExternalBackupPolicy(), first = policy.filename(), second = policy.filename()
        let keep = policy.filename(); try ExternalBackupFolder.write(archive: source, file: info, name: keep, policy: policy, directory: target)
        XCTAssertThrowsError(try ExternalBackupFolder.write(archive: source, file: info, name: first, policy: policy, directory: target,
                                                            coordination: FaultyFiles(damageOnRead: first))) { error in
            XCTAssertEqual(error as? LibraryArchiveError, .verificationFailed)
        }
        XCTAssertThrowsError(try ExternalBackupFolder.write(archive: source, file: info, name: second, policy: policy, directory: target,
                                                            coordination: FaultyFiles(failMove: true)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [keep])
        XCTAssertEqual(try BoundedFile.checksum(target.appendingPathComponent(keep)), info)
    }

    func testStaleOwnPartialsArePrunedAndOthersKept() throws {
        let (root, target, source, info) = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let policy = ExternalBackupPolicy(), now = Date()
        let stale = policy.filename(at: now.addingTimeInterval(-2 * 24 * 3600)) + ".partial"
        let recent = policy.filename(at: now.addingTimeInterval(-600)) + ".partial"
        let foreign = ExternalBackupPolicy().filename(at: now.addingTimeInterval(-9 * 24 * 3600)) + ".partial"
        for name in [stale, recent, foreign] { try Data([3]).write(to: target.appendingPathComponent(name)) }
        let name = policy.filename(at: now)
        try ExternalBackupFolder.write(archive: source, file: info, name: name, policy: policy, directory: target)
        XCTAssertEqual(try ExternalBackupFolder.prune(policy: policy, directory: target, verified: name, file: info, now: now), [])
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: target.path)), [name, recent, foreign])
        let copy = root.appendingPathComponent("zurück.notylibrary")
        XCTAssertEqual(try ExternalBackupFolder.copy(name: name, policy: policy, directory: target, to: copy), info)
        XCTAssertThrowsError(try ExternalBackupFolder.copy(name: "../x.notylibrary", policy: policy, directory: target, to: copy))
    }
}

final class SigningProfileTests: XCTestCase {
    func testExpirationFromCMSWrappedPlist() throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>AppIDName</key><string>noty</string>
        <key>CreationDate</key><date>2026-10-12T08:00:00Z</date>
        <key>ExpirationDate</key><date>2026-10-19T08:00:00Z</date>
        </dict></plist>
        """
        var blob = Data([0x30, 0x82, 0x1f, 0x00, 0x06, 0x09]) + payload(300, seed: 3)
        blob.append(Data(plist.utf8)); blob.append(payload(700, seed: 4))
        XCTAssertEqual(SigningProfile.expirationDate(blob), Date(timeIntervalSince1970: 1_792_396_800))
    }
    func testMissingOrBrokenProfileYieldsNil() {
        XCTAssertNil(SigningProfile.expirationDate(Data()))
        XCTAssertNil(SigningProfile.expirationDate(Data("<?xml version=\"1.0\"?><plist><dict><key>ExpirationDate</key>".utf8)))
        XCTAssertNil(SigningProfile.expirationDate(Data("</plist> <?xml version=\"1.0\"?><plist version=\"1.0\"><dict/></plist>".utf8)))
    }
    func testReminderOneDayBeforeOrSoon() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(SigningProfile.reminderDate(expiration: now.addingTimeInterval(7 * 86400), now: now), now.addingTimeInterval(6 * 86400))
        XCTAssertEqual(SigningProfile.reminderDate(expiration: now.addingTimeInterval(3600), now: now), now.addingTimeInterval(60))
        XCTAssertNil(SigningProfile.reminderDate(expiration: now.addingTimeInterval(-1), now: now))
    }
}
