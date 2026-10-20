import Foundation

public struct LibraryBundle: Equatable, Sendable {
    public var snapshot: LibrarySnapshot
    public var documents: [Notebook]
    public var toolbar: ToolbarPreferences
    public init(snapshot: LibrarySnapshot, documents: [Notebook], toolbar: ToolbarPreferences = ToolbarPreferences()) {
        self.snapshot = snapshot; self.documents = documents; self.toolbar = toolbar
    }
    public func validate() throws {
        try snapshot.validate(); try toolbar.validate()
        let ids = snapshot.items.filter { !$0.isFolder }.map(\.id)
        guard documents.count == ids.count, Set(documents.map(\.id)).count == documents.count,
              Set(documents.map(\.id)) == Set(ids) else { throw LibraryArchiveError.invalid }
        for document in documents {
            guard snapshot.items.first(where: { $0.id == document.id })?.title == document.title else { throw LibraryArchiveError.invalid }
            _ = try Notebook.decode(JSONEncoder().encode(document))
        }
    }
}

public enum LibraryArchiveError: Error, LocalizedError, Equatable {
    case invalid, unsupported(Int), incomplete, destinationExists, archiveTooLarge, notebookTooLarge(String), verificationFailed
    case damagedImage(String)
    public var errorDescription: String? {
        switch self {
        case .invalid: "Die Datei ist kein vollständiges gültiges Bibliotheksbackup."
        case .unsupported(let version): "Bibliotheksbackup \(version) benötigt eine neuere noty-Version."
        case .incomplete: "Mindestens ein Heft ist nicht vollständig lesbar. Bibliotheksbackup abgebrochen; Dateien bleiben erhalten."
        case .destinationExists: "Der neue Wiederherstellungsbereich ist bereits vorhanden. Es wurde nichts überschrieben."
        case .archiveTooLarge: "Das Bibliotheksbackup würde die Grenze von 4 GB überschreiten."
        case .notebookTooLarge(let title): "Das Notizbuch „\(title)“ ist größer als 200 MB und kann nicht gesichert werden."
        case .verificationFailed: "Die zurückgelesene Sicherung stimmt nicht mit dem geprüften Archiv überein. Ältere Sicherungen bleiben erhalten."
        case .damagedImage(let title): "Ein Bildoriginal im Notizbuch „\(title)“ fehlt oder ist beschädigt. Bibliotheksbackup abgebrochen; Dateien bleiben erhalten."
        }
    }
}

struct LibraryArchiveEntry: Codable, Equatable {
    var kind: String
    var id: UUID?
    var byteCount: Int
    var crc32: UInt32
}
private struct LibraryArchiveVersion: Decodable { var libraryBackupVersion: Int }
struct LibraryArchiveManifest: Codable {
    var libraryBackupVersion = 1
    var checksumAlgorithm = "crc32-iso-hdlc"
    var createdAt: Date
    var entries: [LibraryArchiveEntry]
}

/// Format 2 header.
struct LibraryArchiveHeader: Codable {
    var libraryBackupVersion = 2
    var checksumAlgorithm = "crc32-iso-hdlc"
    var assetHashAlgorithm = "sha256"
    var createdAt: Date
    static let keys: Set<String> = ["libraryBackupVersion", "checksumAlgorithm", "assetHashAlgorithm", "createdAt"]
}

/// Upper bounds of one archive; only tests lower them.
struct LibraryArchiveLimits: Sendable {
    var total = LibraryArchive.maximumBytes
    var notebook = LibraryArchive.maximumNotebookBytes
    /// Format 1 manifest (lists every chunk).
    var header = 2_000_000
    var index = 4_000_000
    var toolbar = 64_000
    var asset = ImageLimits.maximumFileBytes
    static let standard = LibraryArchiveLimits()
}

public struct LibraryArchiveChunk: Equatable, Sendable {
    public let id: UUID
    public let byteCount: Int
    public let crc32: UInt32
}

/// Everything a complete streaming pass learned about one archive. Notebook
/// contents are not retained; `file` binds the summary to the exact bytes.
public struct LibraryArchiveSummary: Equatable, Sendable {
    public let createdAt: Date
    public let snapshot: LibrarySnapshot
    public let toolbar: ToolbarPreferences
    /// Notebook chunks in archive order.
    public let notebooks: [LibraryArchiveChunk]
    public let file: LibraryArchiveFileInfo
    /// 1 or 2.
    public var formatVersion = 1
    /// Asset records (each hash once) and their payload bytes; format 2.
    public var assetCount = 0
    public var assetBytes = 0
    public var folderCount: Int { snapshot.items.count - notebooks.count }
    public var trashedCount: Int { snapshot.items.filter { $0.deletedAt != nil }.count }
}

/// Index, preferences and package locations captured on the library actor.
/// Notebooks are read later, one at a time, from their committed revisions.
public struct LibraryBackupPlan: Sendable {
    public let snapshot: LibrarySnapshot
    public let toolbar: ToolbarPreferences
    let packages: [UUID: URL]
    public var documentCount: Int { packages.count }
    var documents: [LibraryItem] { snapshot.items.filter { !$0.isFolder } }

    /// Latest committed revision under the index title. Revisions are immutable
    /// and the manifest is replaced last, but an editor committing meanwhile can
    /// remove the revision named by a manifest read a moment earlier: retry fresh.
    func committedNotebook(_ item: LibraryItem) throws -> Notebook {
        let result = try readableNotebook(item)
        guard !result.olderState else { throw LibraryArchiveError.incomplete }
        return result.document
    }

    /// The package's committed image originals, read-only.
    func assets(_ item: LibraryItem) throws -> NotebookAssets {
        guard let url = packages[item.id] else { throw LibraryArchiveError.incomplete }
        return NotebookAssets(package: url, readOnly: true)
    }

    /// Like `committedNotebook`, but when the newest revision stays damaged after
    /// fresh retries, returns the newest completely readable older state – the
    /// state the editor opens – with `olderState == true`. Read-only: the damaged
    /// newer files stay in the package (quarantined by the editor's next commit).
    func readableNotebook(_ item: LibraryItem) throws -> (document: Notebook, olderState: Bool) {
        guard let url = packages[item.id] else { throw LibraryArchiveError.incomplete }
        for attempt in 1...3 {
            let store = RevisionStore(directory: url)
            do {
                var document = try store.load()
                guard document.id == item.id else { throw LibraryArchiveError.incomplete }
                if store.recovered, attempt < 3 { continue }
                document.title = item.title
                return (document, store.recovered)
            } catch StorageError.unsupportedSchema(let version) { throw StorageError.unsupportedSchema(version) }
            catch RevisionError.unsupportedFormat(let version) { throw RevisionError.unsupportedFormat(version) }
            catch { if attempt == 3 { throw LibraryArchiveError.incomplete } }
        }
        throw LibraryArchiveError.incomplete
    }
}

private struct VisitFailure: Error { let error: Error }

/// The complete current library: index (with trash and folders), tool
/// preferences and every notebook; no revision history. There are no archive
/// paths: chunk IDs are checked against the index, asset files are named by
/// checked hashes, restore chooses every output path itself. Writers and
/// readers hold one notebook at a time.
///
/// Format 2 (written since C5): the record stream of `RecordDescriptor`:
/// `index`, `toolbar`, then per notebook its `notebook` record followed by
/// those of its unique external image assets (`Notebook.externalImageAssets`,
/// none before schema 12) that no earlier group carried, then `end`. An asset
/// follows a notebook or asset and is referenced by the notebook of its group;
/// each hash occurs once; every reference of every notebook appears in its own
/// or an earlier group (duplicated notebooks share their originals).
///
/// Format 1 (read): NOTYLIB\n + uint32 BE manifest length + JSON manifest
/// (may end in spaces: reserved before the chunks were known) + raw chunks.
public enum LibraryArchive {
    /// Whole archive. Same order of magnitude as iCloud/WebDAV upload limits and
    /// a day's backup on a home connection; keeps every offset far from Int overflow.
    public static let maximumBytes = 4_000_000_000
    /// One notebook chunk; equals the largest committed revision (RevisionStore).
    public static let maximumNotebookBytes = 200_000_000
    static let magic = Data("NOTYLIB\n".utf8)
    static let maximumHeader = 2_000_000
    /// Sorted keys make a chunk a pure function of its value, so a restored
    /// package can be compared with the archive by size and CRC alone.
    static func chunkEncoder() -> JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys; return encoder }
    /// Size and CRC of the canonical encoding of a decoded value; independent of
    /// the key order an archive (or an older build) actually used.
    static func fingerprint(_ document: Notebook) throws -> LibraryArchiveFileInfo {
        let bytes = try chunkEncoder().encode(document)
        return LibraryArchiveFileInfo(byteCount: bytes.count, crc32: StreamingCRC32.checksum(bytes))
    }

    // MARK: Writing (format 2)

    /// Small libraries/tests: the complete archive in memory, re-decoded before
    /// return. `assets` serves every notebook's external image assets.
    public static func encode(_ bundle: LibraryBundle, createdAt: Date = Date()) throws -> Data {
        try encode(bundle, assets: InlineImageAssets(), createdAt: createdAt)
    }

    static func encode(_ bundle: LibraryBundle, assets: ImageAssetProviding, createdAt: Date = Date()) throws -> Data {
        try bundle.validate()
        var sink = DataSink()
        let items = bundle.documents.map { document in bundle.snapshot.items.first { $0.id == document.id }! }
        _ = try write(snapshot: bundle.snapshot, toolbar: bundle.toolbar, documents: items, createdAt: createdAt, into: &sink,
                      limits: .standard, document: { item in (bundle.documents.first { $0.id == item.id }!, assets) },
                      validate: { _, _ in })
        guard try decode(sink.data) == bundle else { throw LibraryArchiveError.invalid }
        return sink.data
    }

    /// Streams the committed library into a new file at `url` (never replaced),
    /// then re-reads the written file completely (CRCs, every asset's SHA-256,
    /// structure, every notebook). `validate` sees each notebook with its
    /// package's image originals before it is encoded. On any error the
    /// unfinished file is removed. Safe off every actor; checks cancellation.
    /// A notebook whose newest revision is damaged is archived in its newest
    /// readable older state and reported through `olderState` (a warning, the
    /// archive itself is an ordinary complete one).
    public static func write(_ plan: LibraryBackupPlan, to url: URL, createdAt: Date = Date(),
                             validate: (Notebook, ImageAssetProviding) throws -> Void = { _, _ in },
                             olderState: (LibraryItem) -> Void = { _ in }) throws -> LibraryArchiveSummary {
        try write(plan, to: url, createdAt: createdAt, limits: .standard, validate: validate, olderState: olderState)
    }

    static func write(_ plan: LibraryBackupPlan, to url: URL, createdAt: Date = Date(), limits: LibraryArchiveLimits,
                      validate: (Notebook, ImageAssetProviding) throws -> Void = { _, _ in },
                      olderState: (LibraryItem) -> Void = { _ in }) throws -> LibraryArchiveSummary {
        try Data().write(to: url, options: .withoutOverwriting)
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: url) } }
        let handle = try FileHandle(forWritingTo: url)
        let written: Written
        do {
            var sink = FileSink(handle: handle)
            written = try write(snapshot: plan.snapshot, toolbar: plan.toolbar, documents: plan.documents, createdAt: createdAt,
                                into: &sink, limits: limits, document: { item in
                let result = try plan.readableNotebook(item)
                if result.olderState { olderState(item) }
                return (result.document, try plan.assets(item))
            }, validate: validate)
            try handle.synchronize()
            try handle.close()
        } catch { try? handle.close(); throw error }
        let summary = try verify(url, limits: limits)
        guard summary.formatVersion == 2, summary.snapshot == plan.snapshot, summary.toolbar == plan.toolbar,
              summary.notebooks == written.notebooks, summary.assetCount == written.assetCount,
              summary.assetBytes == written.assetBytes else { throw LibraryArchiveError.verificationFailed }
        complete = true
        return summary
    }

    struct Written { var notebooks: [LibraryArchiveChunk] = []; var assetCount = 0; var assetBytes = 0 }

    static func write<S: RecordArchiveSink>(snapshot: LibrarySnapshot, toolbar: ToolbarPreferences, documents: [LibraryItem],
                                             createdAt: Date, into sink: inout S, limits: LibraryArchiveLimits,
                                             document: (LibraryItem) throws -> (Notebook, ImageAssetProviding),
                                             validate: (Notebook, ImageAssetProviding) throws -> Void) throws -> Written {
        try snapshot.validate(); try toolbar.validate()
        let expected = snapshot.items.filter { !$0.isFolder }.map(\.id)
        guard documents.count == expected.count, Set(documents.map(\.id)) == Set(expected) else { throw LibraryArchiveError.invalid }
        // ISO-8601 keeps whole seconds; the summary of the written file must compare equal.
        let created = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
        let encoder = chunkEncoder()
        let index = try encoder.encode(snapshot), preferences = try encoder.encode(toolbar)
        guard index.count <= limits.index, preferences.count <= limits.toolbar else { throw LibraryArchiveError.invalid }
        var writer = RecordWriter(sink, limit: limits.total)
        defer { sink = writer.sink }
        var result = Written(), emitted = Set<String>()
        do {
            try writer.header(magic: magic, RecordArchive.recordEncoder().encode(LibraryArchiveHeader(createdAt: created)))
            try writer.data(.index, payload: index)
            try writer.data(.toolbar, payload: preferences)
            for item in documents {
                if Task.isCancelled { throw CancellationError() }
                try drained {
                    let (notebook, assets) = try document(item)
                    guard notebook.id == item.id, notebook.title == item.title else { throw LibraryArchiveError.invalid }
                    try validate(notebook, assets)
                    let data = try encoder.encode(notebook)
                    guard data.count <= limits.notebook else { throw LibraryArchiveError.notebookTooLarge(item.title) }
                    let references = try RecordArchive.uniqueAssets(notebook.externalImageAssets)
                    guard references.allSatisfy({ $0.byteCount <= limits.asset }) else { throw LibraryArchiveError.invalid }
                    let record = try writer.data(.notebook, id: item.id, payload: data)
                    result.notebooks.append(LibraryArchiveChunk(id: item.id, byteCount: data.count, crc32: record.crc32!))
                    for reference in references where !emitted.contains(reference.sha256) {
                        if Task.isCancelled { throw CancellationError() }
                        do {
                            // Hashed while streaming; a mismatch aborts (no second read).
                            try writer.asset(reference, from: try assets.payload(for: reference))
                        } catch is RecordArchiveAssetMismatch { throw LibraryArchiveError.damagedImage(item.title) }
                        catch is ImageAssetError { throw LibraryArchiveError.damagedImage(item.title) }
                        emitted.insert(reference.sha256)
                        result.assetCount += 1; result.assetBytes += reference.byteCount
                    }
                }
            }
            try writer.end()
        } catch is RecordArchiveLimitExceeded { throw LibraryArchiveError.archiveTooLarge }
        catch is RecordArchiveInvalid { throw LibraryArchiveError.invalid }
        return result
    }

    /// Format 1 exactly as written up to Build 53 (reserved manifest,
    /// Dictionary key order). Only tests and fixtures write it.
    static func encodeVersion1(_ bundle: LibraryBundle, createdAt: Date = Date()) throws -> Data {
        try bundle.validate()
        var sink = DataSink()
        let items = bundle.documents.map { document in bundle.snapshot.items.first { $0.id == document.id }! }
        _ = try writeVersion1(snapshot: bundle.snapshot, toolbar: bundle.toolbar, documents: items, createdAt: createdAt, into: &sink,
                              limits: .standard, document: { item in bundle.documents.first { $0.id == item.id }! })
        guard try decode(sink.data) == bundle else { throw LibraryArchiveError.invalid }
        return sink.data
    }

    static func writeVersion1<S: RecordArchiveSink>(snapshot: LibrarySnapshot, toolbar: ToolbarPreferences, documents: [LibraryItem],
                                                     createdAt: Date, into sink: inout S, limits: LibraryArchiveLimits,
                                                     document: (LibraryItem) throws -> Notebook) throws -> [LibraryArchiveEntry] {
        try snapshot.validate(); try toolbar.validate()
        let expected = snapshot.items.filter { !$0.isFolder }.map(\.id)
        guard documents.count == expected.count, Set(documents.map(\.id)) == Set(expected) else { throw LibraryArchiveError.invalid }
        let created = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
        let encoder = chunkEncoder()
        let index = try encoder.encode(snapshot), preferences = try encoder.encode(toolbar)
        guard index.count <= limits.index, preferences.count <= limits.toolbar else { throw LibraryArchiveError.invalid }
        var entries = [LibraryArchiveEntry(kind: "index", byteCount: index.count, crc32: StreamingCRC32.checksum(index)),
                       LibraryArchiveEntry(kind: "toolbar", byteCount: preferences.count, crc32: StreamingCRC32.checksum(preferences))]
        // Reserve the manifest with maximal digits; real counts/CRCs are never longer.
        let reserved = try manifestBytes(created, entries + documents.map {
            LibraryArchiveEntry(kind: "notebook", id: $0.id, byteCount: limits.notebook, crc32: .max)
        }).count
        guard reserved <= limits.header else { throw LibraryArchiveError.invalid }
        try sink.append(magic + RecordArchive.lengthBytes(reserved) + Data(repeating: 0x20, count: reserved))
        try sink.append(index); try sink.append(preferences)
        var total = RecordArchive.prefixByteCount + reserved + index.count + preferences.count
        for item in documents {
            let entry = try drained { () throws -> LibraryArchiveEntry in
                let notebook = try document(item)
                guard notebook.id == item.id, notebook.title == item.title else { throw LibraryArchiveError.invalid }
                let data = try encoder.encode(notebook)
                guard data.count <= limits.notebook else { throw LibraryArchiveError.notebookTooLarge(item.title) }
                guard data.count <= limits.total - total else { throw LibraryArchiveError.archiveTooLarge }
                try sink.append(data)
                return LibraryArchiveEntry(kind: "notebook", id: item.id, byteCount: data.count, crc32: StreamingCRC32.checksum(data))
            }
            total += entry.byteCount
            entries.append(entry)
        }
        let manifest = try manifestBytes(created, entries)
        guard manifest.count <= reserved else { throw LibraryArchiveError.invalid }
        try sink.replace(at: RecordArchive.prefixByteCount, with: manifest + Data(repeating: 0x20, count: reserved - manifest.count))
        return entries
    }

    private static func manifestBytes(_ createdAt: Date, _ entries: [LibraryArchiveEntry]) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(LibraryArchiveManifest(createdAt: createdAt, entries: entries))
    }

    // MARK: Reading

    /// Small archives/tests: decodes every notebook into memory (assets verified, not kept).
    public static func decode(_ data: Data) throws -> LibraryBundle {
        var source = DataSource(data: data)
        var documents: [Notebook] = []
        let summary = try read(&source, limits: .standard) { document, _ in documents.append(document) }
        return LibraryBundle(snapshot: summary.snapshot, documents: documents, toolbar: summary.toolbar)
    }

    /// One streaming pass over a regular file: header, then every record once
    /// (length, CRC, every asset's SHA-256, decode, identity/title against the
    /// index). Only the current notebook is held; `visit` receives it after
    /// validation, in archive order (format 2: once its asset group is complete).
    /// Errors thrown by `visit` are passed through unchanged.
    public static func verify(_ url: URL, visit: (Notebook) throws -> Void = { _ in }) throws -> LibraryArchiveSummary {
        try verify(url, limits: .standard, handling: .verify) { document, _ in try visit(document) }
    }

    /// Like `verify(_:visit:)`; every asset is verified into the existing
    /// `directory` as `<sha256>`, and `visit` gets these extracted originals.
    public static func verify(_ url: URL, extractingAssetsTo directory: URL,
                              visit: (Notebook, ImageAssetProviding) throws -> Void) throws -> LibraryArchiveSummary {
        try verify(url, limits: .standard, handling: .extract(directory), visit: visit)
    }

    static func verify(_ url: URL, limits: LibraryArchiveLimits, handling: RecordAssetHandling = .verify,
                       visit: (Notebook, ImageAssetProviding) throws -> Void = { _, _ in }) throws -> LibraryArchiveSummary {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize else { throw LibraryArchiveError.invalid }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var source = FileSource(handle: handle, size: size)
        return try read(&source, limits: limits, handling: handling, visit: visit)
    }

    static func read<S: RecordArchiveSource>(_ source: inout S, limits: LibraryArchiveLimits, handling: RecordAssetHandling = .verify,
                                              visit: (Notebook, ImageAssetProviding) throws -> Void) throws -> LibraryArchiveSummary {
        do {
            let size = source.size
            guard size <= limits.total else { throw LibraryArchiveError.archiveTooLarge }
            guard size >= RecordArchive.prefixByteCount else { throw LibraryArchiveError.invalid }
            var reader = RecordReader(source)
            defer { source = reader.input.source }
            let header = try reader.header(magic: magic, maximumHeader: max(limits.header, RecordArchive.maximumRecordHeaderBytes))
            let version = try JSONDecoder().decode(LibraryArchiveVersion.self, from: header).libraryBackupVersion
            switch version {
            case 1: return try readVersion1(&reader, header: header, limits: limits) { try visit($0, InlineImageAssets()) }
            case 2: return try readVersion2(&reader, header: header, limits: limits, handling: handling, visit: visit)
            default: throw LibraryArchiveError.unsupported(version)
            }
        }
        catch let failure as VisitFailure { throw failure.error }
        catch let error as LibraryArchiveError { throw error }
        catch let error as BackupError { throw error }
        catch let error as StorageError { throw error }
        catch let error as LibraryError { throw error }
        catch let error as ToolbarError { throw error }
        catch let error as CancellationError { throw error }
        catch { throw LibraryArchiveError.invalid }
    }

    private static func readVersion1<S: RecordArchiveSource>(_ reader: inout RecordReader<S>, header: Data, limits: LibraryArchiveLimits,
                                                               visit: (Notebook) throws -> Void) throws -> LibraryArchiveSummary {
        let size = reader.size, prefixCount = RecordArchive.prefixByteCount, length = header.count
        guard length <= limits.header else { throw LibraryArchiveError.invalid }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(LibraryArchiveManifest.self, from: header)
        let entries = manifest.entries
        guard manifest.checksumAlgorithm == "crc32-iso-hdlc", (2...10_002).contains(entries.count),
              entries[0].kind == "index", entries[0].id == nil,
              entries[1].kind == "toolbar", entries[1].id == nil else { throw LibraryArchiveError.invalid }
        // Structure first: limits, kinds, unique IDs and exact total length,
        // so truncated or extended files fail before any notebook is decoded.
        var ids = Set<UUID>(), payload = 0
        for (position, entry) in entries.enumerated() {
            let limit = position == 0 ? limits.index : (position == 1 ? limits.toolbar : limits.notebook)
            guard (1...limit).contains(entry.byteCount) else { throw LibraryArchiveError.invalid }
            if position >= 2 { guard entry.kind == "notebook", let id = entry.id, ids.insert(id).inserted else { throw LibraryArchiveError.invalid } }
            payload += entry.byteCount
        }
        guard payload == size - prefixCount - length else { throw LibraryArchiveError.invalid }
        func chunk(_ entry: LibraryArchiveEntry) throws -> Data {
            try reader.payload(RecordDescriptor(kind: .notebook, byteCount: entry.byteCount, crc32: entry.crc32), limit: entry.byteCount)
        }
        let snapshot = try JSONDecoder().decode(LibrarySnapshot.self, from: chunk(entries[0]))
        try snapshot.validate()
        let toolbar = try ToolbarPreferences.decode(chunk(entries[1]))
        let titles = Dictionary(uniqueKeysWithValues: snapshot.items.filter { !$0.isFolder }.map { ($0.id, $0.title) })
        guard titles.count == ids.count, Set(titles.keys) == ids else { throw LibraryArchiveError.invalid }
        var chunks: [LibraryArchiveChunk] = []
        for entry in entries.dropFirst(2) {
            if Task.isCancelled { throw CancellationError() }
            try drained {
                let document = try Notebook.decode(chunk(entry))
                guard document.id == entry.id, document.title == titles[document.id] else { throw LibraryArchiveError.invalid }
                do { try visit(document) } catch { throw VisitFailure(error: error) }
            }
            chunks.append(LibraryArchiveChunk(id: entry.id!, byteCount: entry.byteCount, crc32: entry.crc32))
        }
        guard reader.remaining == 0, try reader.input.atEnd() else { throw LibraryArchiveError.invalid }
        return LibraryArchiveSummary(createdAt: manifest.createdAt, snapshot: snapshot, toolbar: toolbar, notebooks: chunks,
                                     file: reader.file)
    }

    private static func readVersion2<S: RecordArchiveSource>(_ reader: inout RecordReader<S>, header data: Data, limits: LibraryArchiveLimits,
                                                               handling: RecordAssetHandling,
                                                               visit: (Notebook, ImageAssetProviding) throws -> Void) throws -> LibraryArchiveSummary {
        guard data.count <= RecordArchive.maximumRecordHeaderBytes else { throw LibraryArchiveError.invalid }
        try RecordArchive.requireKeys(data, LibraryArchiveHeader.keys)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let header = try decoder.decode(LibraryArchiveHeader.self, from: data)
        guard header.checksumAlgorithm == "crc32-iso-hdlc", header.assetHashAlgorithm == "sha256" else { throw LibraryArchiveError.invalid }
        let indexRecord = try reader.descriptor()
        guard indexRecord.kind == .index else { throw LibraryArchiveError.invalid }
        let snapshot = try JSONDecoder().decode(LibrarySnapshot.self, from: reader.payload(indexRecord, limit: limits.index))
        try snapshot.validate()
        let toolbarRecord = try reader.descriptor()
        guard toolbarRecord.kind == .toolbar else { throw LibraryArchiveError.invalid }
        let toolbar = try ToolbarPreferences.decode(reader.payload(toolbarRecord, limit: limits.toolbar))
        let titles = Dictionary(uniqueKeysWithValues: snapshot.items.filter { !$0.isFolder }.map { ($0.id, $0.title) })
        let extracted: ImageAssetProviding
        if case .extract(let directory) = handling { extracted = NotebookAssets(directory: directory, readOnly: true) }
        else { extracted = InlineImageAssets() }
        var chunks: [LibraryArchiveChunk] = [], ids = Set<UUID>(), emitted: [String: Int] = [:], assetBytes = 0
        var current: (document: Notebook, references: [String: ImageAssetReference])?
        /// A group is complete once every reference was carried by it or before.
        func finishGroup() throws {
            guard let group = current else { return }
            current = nil
            guard group.references.values.allSatisfy({ emitted[$0.sha256] == $0.byteCount }) else { throw LibraryArchiveError.invalid }
            do { try visit(group.document, extracted) } catch { throw VisitFailure(error: error) }
        }
        while true {
            if Task.isCancelled { throw CancellationError() }
            let descriptor = try reader.descriptor()
            switch descriptor.kind {
            case .notebook:
                try finishGroup()
                guard let id = descriptor.id, let title = titles[id], ids.insert(id).inserted else { throw LibraryArchiveError.invalid }
                let document = try drained { try Notebook.decode(reader.payload(descriptor, limit: limits.notebook)) }
                guard document.id == id, document.title == title else { throw LibraryArchiveError.invalid }
                let references = try RecordArchive.uniqueAssets(document.externalImageAssets)
                current = (document, Dictionary(uniqueKeysWithValues: references.map { ($0.sha256, $0) }))
                chunks.append(LibraryArchiveChunk(id: id, byteCount: descriptor.byteCount!, crc32: descriptor.crc32!))
            case .asset:
                guard let group = current, let reference = descriptor.assetReference, group.references[reference.sha256] == reference,
                      reference.byteCount <= limits.asset, emitted[reference.sha256] == nil else { throw LibraryArchiveError.invalid }
                try reader.asset(reference, handling)
                emitted[reference.sha256] = reference.byteCount; assetBytes += reference.byteCount
            case .end:
                try finishGroup()
                try reader.end(descriptor)
                guard ids == Set(titles.keys) else { throw LibraryArchiveError.invalid }
                var summary = LibraryArchiveSummary(createdAt: header.createdAt, snapshot: snapshot, toolbar: toolbar, notebooks: chunks,
                                                    file: reader.file)
                summary.formatVersion = 2; summary.assetCount = emitted.count; summary.assetBytes = assetBytes
                return summary
            case .index, .toolbar:
                throw LibraryArchiveError.invalid
            }
        }
    }
}
