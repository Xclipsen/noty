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
    public var errorDescription: String? {
        switch self {
        case .invalid: "Die Datei ist kein vollständiges gültiges Bibliotheksbackup."
        case .unsupported(let version): "Bibliotheksbackup \(version) benötigt eine neuere noty-Version."
        case .incomplete: "Mindestens ein Heft ist nicht vollständig lesbar. Bibliotheksbackup abgebrochen; Dateien bleiben erhalten."
        case .destinationExists: "Der neue Wiederherstellungsbereich ist bereits vorhanden. Es wurde nichts überschrieben."
        case .archiveTooLarge: "Das Bibliotheksbackup würde die Grenze von 4 GB überschreiten."
        case .notebookTooLarge(let title): "Das Notizbuch „\(title)“ ist größer als 200 MB und kann nicht gesichert werden."
        case .verificationFailed: "Die zurückgelesene Sicherung stimmt nicht mit dem geprüften Archiv überein. Ältere Sicherungen bleiben erhalten."
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

/// Upper bounds of one archive; only tests lower them.
struct LibraryArchiveLimits: Sendable {
    var total = LibraryArchive.maximumBytes
    var notebook = LibraryArchive.maximumNotebookBytes
    var header = 2_000_000
    var index = 4_000_000
    var toolbar = 64_000
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

protocol LibraryArchiveSink {
    mutating func append(_ data: Data) throws
    mutating func replace(at offset: Int, with data: Data) throws
}
private struct DataSink: LibraryArchiveSink {
    var data = Data()
    mutating func append(_ data: Data) { self.data.append(data) }
    mutating func replace(at offset: Int, with data: Data) { self.data.replaceSubrange(offset..<offset + data.count, with: data) }
}
private struct FileSink: LibraryArchiveSink {
    let handle: FileHandle
    func append(_ data: Data) throws { try handle.write(contentsOf: data) }
    func replace(at offset: Int, with data: Data) throws {
        try handle.seek(toOffset: UInt64(offset)); try handle.write(contentsOf: data); _ = try handle.seekToEnd()
    }
}

protocol LibraryArchiveSource {
    var size: Int { get }
    /// Exactly `count` bytes or an error; never more than requested.
    mutating func read(_ count: Int) throws -> Data
    mutating func atEnd() throws -> Bool
}
private struct DataSource: LibraryArchiveSource {
    let data: Data
    var offset = 0
    var size: Int { data.count }
    mutating func read(_ count: Int) throws -> Data {
        guard count <= data.count - offset else { throw LibraryArchiveError.invalid }
        let start = data.startIndex + offset
        offset += count
        return Data(data[start..<start + count])
    }
    func atEnd() -> Bool { offset == data.count }
}
private struct FileSource: LibraryArchiveSource {
    let handle: FileHandle
    let size: Int
    func read(_ count: Int) throws -> Data {
        var result = Data(capacity: count)
        while result.count < count {
            guard let piece = try handle.read(upToCount: min(BoundedFile.block, count - result.count)), !piece.isEmpty else {
                throw LibraryArchiveError.invalid
            }
            result.append(piece)
        }
        return result
    }
    func atEnd() throws -> Bool { (try handle.read(upToCount: 1))?.isEmpty ?? true }
}

private struct VisitFailure: Error { let error: Error }

#if canImport(ObjectiveC)
private func drained<T>(_ body: () throws -> T) rethrows -> T { try autoreleasepool(invoking: body) }
#else
private func drained<T>(_ body: () throws -> T) rethrows -> T { try body() }
#endif

/// NOTYLIB\n + uint32 BE manifest length + JSON manifest + bounded raw chunks.
/// There are no archive paths. Chunk IDs are checked against the index; restore
/// chooses every output path itself. Includes trash, excludes revision history.
/// The manifest JSON may end in spaces (reserved before the chunks are known);
/// its length field includes them. Writers and readers handle one notebook
/// chunk at a time, so memory is bounded by the largest notebook, not the library.
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

    // MARK: Writing

    /// Small libraries/tests: the complete archive in memory, re-decoded before return.
    public static func encode(_ bundle: LibraryBundle, createdAt: Date = Date()) throws -> Data {
        try bundle.validate()
        var sink = DataSink()
        let items = bundle.documents.map { document in bundle.snapshot.items.first { $0.id == document.id }! }
        _ = try write(snapshot: bundle.snapshot, toolbar: bundle.toolbar, documents: items, createdAt: createdAt, into: &sink,
                      limits: .standard, document: { item in bundle.documents.first { $0.id == item.id }! }, validate: { _ in })
        guard try decode(sink.data) == bundle else { throw LibraryArchiveError.invalid }
        return sink.data
    }

    /// Streams the committed library into a new file at `url` (never replaced),
    /// then re-reads the written file completely (CRC, structure, every notebook).
    /// `validate` sees each notebook before it is encoded. On any error the
    /// unfinished file is removed. Safe off every actor; checks cancellation.
    /// A notebook whose newest revision is damaged is archived in its newest
    /// readable older state and reported through `olderState` (a warning, the
    /// archive itself is an ordinary complete one).
    public static func write(_ plan: LibraryBackupPlan, to url: URL, createdAt: Date = Date(),
                             validate: (Notebook) throws -> Void = { _ in },
                             olderState: (LibraryItem) -> Void = { _ in }) throws -> LibraryArchiveSummary {
        try write(plan, to: url, createdAt: createdAt, limits: .standard, validate: validate, olderState: olderState)
    }

    static func write(_ plan: LibraryBackupPlan, to url: URL, createdAt: Date = Date(), limits: LibraryArchiveLimits,
                      validate: (Notebook) throws -> Void = { _ in },
                      olderState: (LibraryItem) -> Void = { _ in }) throws -> LibraryArchiveSummary {
        try Data().write(to: url, options: .withoutOverwriting)
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: url) } }
        let handle = try FileHandle(forWritingTo: url)
        let entries: [LibraryArchiveEntry]
        do {
            var sink = FileSink(handle: handle)
            entries = try write(snapshot: plan.snapshot, toolbar: plan.toolbar, documents: plan.documents, createdAt: createdAt,
                                into: &sink, limits: limits, document: { item in
                let result = try plan.readableNotebook(item)
                if result.olderState { olderState(item) }
                return result.document
            }, validate: validate)
            try handle.synchronize()
            try handle.close()
        } catch { try? handle.close(); throw error }
        let summary = try verify(url, limits: limits)
        guard summary.snapshot == plan.snapshot, summary.toolbar == plan.toolbar,
              summary.notebooks == entries.dropFirst(2).map({ LibraryArchiveChunk(id: $0.id!, byteCount: $0.byteCount, crc32: $0.crc32) })
        else { throw LibraryArchiveError.verificationFailed }
        complete = true
        return summary
    }

    static func write<S: LibraryArchiveSink>(snapshot: LibrarySnapshot, toolbar: ToolbarPreferences, documents: [LibraryItem],
                                             createdAt: Date, into sink: inout S, limits: LibraryArchiveLimits,
                                             document: (LibraryItem) throws -> Notebook,
                                             validate: (Notebook) throws -> Void) throws -> [LibraryArchiveEntry] {
        try snapshot.validate(); try toolbar.validate()
        let expected = snapshot.items.filter { !$0.isFolder }.map(\.id)
        guard documents.count == expected.count, Set(documents.map(\.id)) == Set(expected) else { throw LibraryArchiveError.invalid }
        // ISO-8601 keeps whole seconds; the summary of the written file must compare equal.
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
        try sink.append(magic + lengthBytes(reserved) + Data(repeating: 0x20, count: reserved))
        try sink.append(index); try sink.append(preferences)
        var total = 12 + reserved + index.count + preferences.count
        for item in documents {
            if Task.isCancelled { throw CancellationError() }
            let entry = try drained { () throws -> LibraryArchiveEntry in
                let notebook = try document(item)
                guard notebook.id == item.id, notebook.title == item.title else { throw LibraryArchiveError.invalid }
                try validate(notebook)
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
        try sink.replace(at: 12, with: manifest + Data(repeating: 0x20, count: reserved - manifest.count))
        return entries
    }

    private static func manifestBytes(_ createdAt: Date, _ entries: [LibraryArchiveEntry]) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(LibraryArchiveManifest(createdAt: createdAt, entries: entries))
    }
    private static func lengthBytes(_ value: Int) -> Data {
        let length = UInt32(value)
        return Data([UInt8(length >> 24), UInt8((length >> 16) & 255), UInt8((length >> 8) & 255), UInt8(length & 255)])
    }

    // MARK: Reading

    /// Small archives/tests: decodes every notebook into memory.
    public static func decode(_ data: Data) throws -> LibraryBundle {
        var source = DataSource(data: data)
        var documents: [Notebook] = []
        let summary = try read(&source, limits: .standard) { documents.append($0) }
        return LibraryBundle(snapshot: summary.snapshot, documents: documents, toolbar: summary.toolbar)
    }

    /// One streaming pass over a regular file: header, then every chunk once
    /// (length, CRC, decode, identity/title against the index). Only the current
    /// notebook is held; `visit` receives it after validation, in archive order.
    /// Errors thrown by `visit` are passed through unchanged.
    public static func verify(_ url: URL, visit: (Notebook) throws -> Void = { _ in }) throws -> LibraryArchiveSummary {
        try verify(url, limits: .standard, visit: visit)
    }

    static func verify(_ url: URL, limits: LibraryArchiveLimits, visit: (Notebook) throws -> Void = { _ in }) throws -> LibraryArchiveSummary {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize else { throw LibraryArchiveError.invalid }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var source = FileSource(handle: handle, size: size)
        return try read(&source, limits: limits, visit: visit)
    }

    static func read<S: LibraryArchiveSource>(_ source: inout S, limits: LibraryArchiveLimits,
                                              visit: (Notebook) throws -> Void) throws -> LibraryArchiveSummary {
        do { return try readValidated(&source, limits: limits, visit: visit) }
        catch let failure as VisitFailure { throw failure.error }
        catch let error as LibraryArchiveError { throw error }
        catch let error as BackupError { throw error }
        catch let error as StorageError { throw error }
        catch let error as LibraryError { throw error }
        catch let error as ToolbarError { throw error }
        catch let error as CancellationError { throw error }
        catch { throw LibraryArchiveError.invalid }
    }

    private static func readValidated<S: LibraryArchiveSource>(_ source: inout S, limits: LibraryArchiveLimits,
                                                               visit: (Notebook) throws -> Void) throws -> LibraryArchiveSummary {
        let size = source.size
        guard size <= limits.total else { throw LibraryArchiveError.archiveTooLarge }
        guard size >= 12 else { throw LibraryArchiveError.invalid }
        var crc = StreamingCRC32()
        func next(_ count: Int) throws -> Data { let data = try source.read(count); crc.update(data); return data }
        let prefix = try next(12)
        guard prefix.starts(with: magic) else { throw LibraryArchiveError.invalid }
        let length = Int(prefix.dropFirst(8).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        guard (1...limits.header).contains(length), size - 12 >= length else { throw LibraryArchiveError.invalid }
        let header = try next(length)
        let version = try JSONDecoder().decode(LibraryArchiveVersion.self, from: header).libraryBackupVersion
        guard version == 1 else { throw LibraryArchiveError.unsupported(version) }
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
        guard payload == size - 12 - length else { throw LibraryArchiveError.invalid }
        func chunk(_ entry: LibraryArchiveEntry) throws -> Data {
            let data = try next(entry.byteCount)
            guard StreamingCRC32.checksum(data) == entry.crc32 else { throw BackupError.checksumMismatch }
            return data
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
        guard try source.atEnd() else { throw LibraryArchiveError.invalid }
        return LibraryArchiveSummary(createdAt: manifest.createdAt, snapshot: snapshot, toolbar: toolbar, notebooks: chunks,
                                     file: LibraryArchiveFileInfo(byteCount: size, crc32: crc.value))
    }
}
