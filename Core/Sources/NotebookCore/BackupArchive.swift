import Foundation

public enum BackupError: Error, LocalizedError {
    case invalidArchive
    case unsupportedVersion(Int)
    case sizeLimit
    case fileTooLarge
    case checksumMismatch
    case invalidStaging
    case verificationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidArchive: "Die Datei ist kein vollständiges unterstütztes noty-Backup."
        case .unsupportedVersion(let version): "Backupformat \(version) benötigt eine neuere noty-Version."
        case .sizeLimit: "Das Backup überschreitet das aktuelle Größenlimit von 200 MB."
        case .fileTooLarge: "Die Backup-Datei überschreitet die Grenze von 800 MB."
        case .checksumMismatch: "Die Backup-Prüfsumme stimmt nicht. Es wurde nichts wiederhergestellt."
        case .invalidStaging: "Die vorbereitete Wiederherstellung ist nicht mehr gültig. Bitte das Backup erneut auswählen."
        case .verificationFailed: "Das zurückgelesene Backup stimmt nicht mit dem Heft überein. Es wurde keine Backup-Datei übergeben."
        }
    }
}

/// Format 1 header (read; written only by `encodeVersion1`).
struct BackupManifest: Codable {
    var backupFormatVersion = 1
    var checksumAlgorithm = "crc32-iso-hdlc"
    var payloadName = "notebook.json"
    var payloadByteCount: Int
    var payloadCRC32: UInt32
    var documentID: UUID
    var notebookSchemaVersion: Int
    var createdAt: Date
}

/// Format 2 header.
struct BackupHeader: Codable {
    var backupFormatVersion = 2
    var checksumAlgorithm = "crc32-iso-hdlc"
    var assetHashAlgorithm = "sha256"
    var documentID: UUID
    var notebookSchemaVersion: Int
    var createdAt: Date
    static let keys: Set<String> = ["backupFormatVersion", "checksumAlgorithm", "assetHashAlgorithm", "documentID",
                                    "notebookSchemaVersion", "createdAt"]
}

public struct DecodedBackup: Sendable {
    public let document: Notebook
    public let isLegacyJSON: Bool
    /// 0: plain notebook JSON of the prototype; 1 or 2: `.notybackup` format.
    public let formatVersion: Int
    /// Image originals carried as asset records (format 2), in archive order.
    public let assets: [ImageAssetReference]
    /// Size and CRC-32 of the exact bytes read.
    public let file: LibraryArchiveFileInfo
}

/// Upper bounds of one `.notybackup`; only tests lower them.
struct BackupArchiveLimits: Sendable {
    var file = BackupArchive.maximumFileBytes
    var notebook = BackupArchive.maximumBytes
    var asset = ImageLimits.maximumFileBytes
    static let standard = BackupArchiveLimits()
}

/// Open, uncompressed single-document archive. No archive paths are
/// extracted onto the filesystem; asset files are named by checked hashes.
///
/// Format 2 (written since C5): the record stream of `RecordDescriptor` with
/// exactly one `notebook` record, then exactly the notebook's unique external
/// image assets (`Notebook.externalImageAssets`, none before schema 12), then
/// `end`. Format 1 (magic + header + one notebook JSON, ≤ 200 MB, read in
/// memory) and the prototype's plain JSON stay readable.
public enum BackupArchive {
    /// Format 1, prototype JSON and the notebook JSON of format 2.
    public static let maximumBytes = 200_000_000
    /// A format-2 file: notebook JSON ≤ 200 MB plus assets ≤ 500 MB plus overhead.
    public static let maximumFileBytes = 800_000_000
    static let magic = Data("NOTYBKP\n".utf8)
    static let maximumHeaderBytes = 64_000

    // MARK: Writing (format 2)

    /// Small notebooks/tests: the complete archive in memory, re-decoded and
    /// compared before return. `assets` serves `externalImageAssets`.
    public static func encode(_ document: Notebook, assets: ImageAssetProviding? = nil, createdAt: Date = Date()) throws -> Data {
        var sink = DataSink()
        try write(document, assets: assets, createdAt: createdAt, into: &sink, limits: .standard)
        guard try decode(sink.data).document == document else { throw BackupError.verificationFailed }
        return sink.data
    }

    /// Streams the archive into a new file at `url` (never replaced), synced,
    /// then reads the written file back completely (CRCs, every asset's
    /// SHA-256, structure) and compares the notebook. On any error the
    /// unfinished file is removed. Safe off every actor.
    @discardableResult
    public static func write(_ document: Notebook, assets: ImageAssetProviding? = nil, to url: URL,
                             createdAt: Date = Date()) throws -> DecodedBackup {
        try write(document, assets: assets, to: url, createdAt: createdAt, limits: .standard)
    }

    static func write(_ document: Notebook, assets: ImageAssetProviding?, to url: URL, createdAt: Date,
                      limits: BackupArchiveLimits) throws -> DecodedBackup {
        try Data().write(to: url, options: .withoutOverwriting)
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: url) } }
        let handle = try FileHandle(forWritingTo: url)
        do {
            var sink = FileSink(handle: handle)
            try write(document, assets: assets, createdAt: createdAt, into: &sink, limits: limits)
            try handle.synchronize()
            try handle.close()
        } catch { try? handle.close(); throw error }
        let written = try verify(url, handling: .verify, limits: limits)
        guard written.formatVersion == 2, written.document == document,
              written.assets == document.externalImageAssets else { throw BackupError.verificationFailed }
        complete = true
        return written
    }

    static func write<S: RecordArchiveSink>(_ document: Notebook, assets: ImageAssetProviding?, createdAt: Date,
                                             into sink: inout S, limits: BackupArchiveLimits) throws {
        do {
            let payload = try LibraryArchive.chunkEncoder().encode(document)
            guard payload.count <= limits.notebook else { throw BackupError.sizeLimit }
            _ = try Notebook.decode(payload)
            let references = try RecordArchive.uniqueAssets(document.externalImageAssets)
            guard references.allSatisfy({ $0.byteCount <= limits.asset }) else { throw BackupError.invalidArchive }
            // ISO-8601 keeps whole seconds; the re-read header must compare equal.
            let created = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
            let header = try RecordArchive.recordEncoder().encode(BackupHeader(documentID: document.id,
                notebookSchemaVersion: document.schemaVersion, createdAt: created))
            guard header.count <= maximumHeaderBytes else { throw BackupError.invalidArchive }
            var writer = RecordWriter(sink, limit: limits.file)
            defer { sink = writer.sink }
            try writer.header(magic: magic, header)
            try writer.data(.notebook, id: document.id, payload: payload)
            for reference in references {
                if Task.isCancelled { throw CancellationError() }
                guard let assets else { throw ImageAssetError.missing(reference.sha256) }
                // Hashed while streaming; a mismatch aborts (no second read).
                try writer.asset(reference, from: try assets.payload(for: reference))
            }
            try writer.end()
        } catch is RecordArchiveLimitExceeded { throw BackupError.fileTooLarge }
        catch let mismatch as RecordArchiveAssetMismatch { throw ImageAssetError.damaged(mismatch.reference.sha256) }
        catch is RecordArchiveInvalid { throw BackupError.invalidArchive }
    }

    /// Format 1 exactly as written up to Build 53 (Dictionary key order).
    /// Only tests and fixtures write it; the app writes format 2.
    static func encodeVersion1(_ document: Notebook, createdAt: Date = Date()) throws -> Data {
        let payload = try JSONEncoder().encode(document)
        guard payload.count <= maximumBytes else { throw BackupError.sizeLimit }
        _ = try Notebook.decode(payload)
        let manifest = BackupManifest(payloadByteCount: payload.count, payloadCRC32: SnapshotChecksum.crc32(payload),
                                      documentID: document.id, notebookSchemaVersion: document.schemaVersion,
                                      createdAt: createdAt)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let header = try encoder.encode(manifest)
        guard header.count <= maximumHeaderBytes, 12 + header.count + payload.count <= maximumBytes else {
            throw BackupError.sizeLimit
        }
        var archive = magic + RecordArchive.lengthBytes(header.count)
        archive.append(header)
        archive.append(payload)
        guard try decode(archive).document == document else { throw BackupError.invalidArchive }
        return archive
    }

    // MARK: Reading

    /// Any accepted backup in memory (prototype JSON, format 1 ≤ 200 MB,
    /// format 2 with every asset verified and discarded).
    public static func decode(_ data: Data) throws -> DecodedBackup {
        try mapped {
            guard data.starts(with: magic), data.count >= RecordArchive.prefixByteCount else { return try decodeInMemory(data) }
            let version = try formatVersion(header: data.prefix(RecordArchive.prefixByteCount), data.dropFirst(RecordArchive.prefixByteCount))
            guard version == 2 else { return try decodeInMemory(data) }
            var source = DataSource(data: data)
            return try readVersion2(&source, handling: .verify, limits: .standard)
        }
    }

    /// One streaming pass over a regular file. Format 2: CRCs, structure and
    /// every asset (`extractingAssetsTo`: verified into that existing
    /// directory as `<sha256>`, otherwise discarded); memory is bounded by the
    /// notebook JSON. Format 1 and prototype JSON: read in memory (≤ 200 MB).
    public static func verify(_ url: URL, extractingAssetsTo directory: URL? = nil) throws -> DecodedBackup {
        try verify(url, handling: directory.map { .extract($0) } ?? .verify, limits: .standard)
    }

    static func verify(_ url: URL, handling: RecordAssetHandling, limits: BackupArchiveLimits) throws -> DecodedBackup {
        try mapped {
            try BoundedFile.requireRegularFile(url)
            guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw BackupError.invalidArchive }
            guard size <= limits.file else { throw BackupError.fileTooLarge }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let head = try handle.read(upToCount: RecordArchive.prefixByteCount) ?? Data()
            var version = 0
            if head.count == RecordArchive.prefixByteCount, head.starts(with: magic) {
                let length = RecordArchive.length(prefix: head)
                guard (1...maximumHeaderBytes).contains(length) else { throw BackupError.invalidArchive }
                version = try formatVersion(header: head, try handle.read(upToCount: length) ?? Data())
            }
            guard version == 2 else { return try decodeInMemory(readBounded(url, limit: limits.notebook)) }
            try handle.seek(toOffset: 0)
            var source = FileSource(handle: handle, size: size)
            return try readVersion2(&source, handling: handling, limits: limits)
        }
    }

    private static func mapped(_ body: () throws -> DecodedBackup) throws -> DecodedBackup {
        do { return try body() }
        catch let error as BackupError { throw error }
        catch let error as StorageError { throw error }
        catch let error as CancellationError { throw error }
        catch { throw BackupError.invalidArchive }
    }

    /// The header's format version (1 or 2), anything else unsupported.
    private static func formatVersion(header prefix: Data, _ rest: Data) throws -> Int {
        let length = RecordArchive.length(prefix: prefix)
        guard (1...maximumHeaderBytes).contains(length), rest.count >= length else { throw BackupError.invalidArchive }
        struct Version: Decodable { var backupFormatVersion: Int }
        let version = try JSONDecoder().decode(Version.self, from: Data(rest.prefix(length))).backupFormatVersion
        guard version == 1 || version == 2 else { throw BackupError.unsupportedVersion(version) }
        return version
    }

    private static func decodeInMemory(_ data: Data) throws -> DecodedBackup {
        let file = LibraryArchiveFileInfo(byteCount: data.count, crc32: StreamingCRC32.checksum(data))
        guard data.count <= maximumBytes else { throw BackupError.sizeLimit }
        guard data.starts(with: magic) else {
            // Preserve access to the prototype's explicitly exported JSON files.
            return DecodedBackup(document: try Notebook.decode(data), isLegacyJSON: true, formatVersion: 0, assets: [], file: file)
        }
        guard data.count >= 12 else { throw BackupError.invalidArchive }
        let headerLength = RecordArchive.length(prefix: data.prefix(RecordArchive.prefixByteCount))
        guard (1...maximumHeaderBytes).contains(headerLength), data.count >= 12 + headerLength else {
            throw BackupError.invalidArchive
        }
        let header = Data(data.dropFirst(12).prefix(headerLength))
        struct Version: Decodable { var backupFormatVersion: Int }
        let version = try JSONDecoder().decode(Version.self, from: header).backupFormatVersion
        guard version == 1 else { throw BackupError.unsupportedVersion(version) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(BackupManifest.self, from: header)
        guard manifest.payloadName == "notebook.json", manifest.checksumAlgorithm == "crc32-iso-hdlc",
              (1...maximumBytes).contains(manifest.payloadByteCount),
              data.count - 12 - headerLength == manifest.payloadByteCount else {
            throw BackupError.invalidArchive
        }
        let payload = Data(data.suffix(manifest.payloadByteCount))
        guard SnapshotChecksum.crc32(payload) == manifest.payloadCRC32 else { throw BackupError.checksumMismatch }
        let document = try Notebook.decode(payload)
        guard document.id == manifest.documentID, document.schemaVersion == manifest.notebookSchemaVersion else {
            throw BackupError.invalidArchive
        }
        return DecodedBackup(document: document, isLegacyJSON: false, formatVersion: 1, assets: [], file: file)
    }

    /// Exactly one notebook, then exactly its unique external assets (each
    /// once, any order), then `end` and the end of the file.
    static func readVersion2<S: RecordArchiveSource>(_ source: inout S, handling: RecordAssetHandling,
                                                     limits: BackupArchiveLimits) throws -> DecodedBackup {
        var reader = RecordReader(source)
        defer { source = reader.input.source }
        do {
            guard reader.size <= limits.file else { throw BackupError.fileTooLarge }
            let headerData = try reader.header(magic: magic, maximumHeader: maximumHeaderBytes)
            try RecordArchive.requireKeys(headerData, BackupHeader.keys)
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let header = try decoder.decode(BackupHeader.self, from: headerData)
            guard header.backupFormatVersion == 2, header.checksumAlgorithm == "crc32-iso-hdlc",
                  header.assetHashAlgorithm == "sha256" else { throw BackupError.invalidArchive }
            let first = try reader.descriptor()
            guard first.kind == .notebook, first.id == header.documentID else { throw BackupError.invalidArchive }
            let document = try drained { try Notebook.decode(reader.payload(first, limit: limits.notebook)) }
            guard document.id == header.documentID, document.schemaVersion == header.notebookSchemaVersion else {
                throw BackupError.invalidArchive
            }
            let references = try RecordArchive.uniqueAssets(document.externalImageAssets)
            let expected = Dictionary(uniqueKeysWithValues: references.map { ($0.sha256, $0) })
            var seen = Set<String>()
            while true {
                if Task.isCancelled { throw CancellationError() }
                let descriptor = try reader.descriptor()
                if descriptor.kind == .end { try reader.end(descriptor); break }
                guard descriptor.kind == .asset, let reference = descriptor.assetReference,
                      expected[reference.sha256] == reference, reference.byteCount <= limits.asset,
                      seen.insert(reference.sha256).inserted else { throw BackupError.invalidArchive }
                try reader.asset(reference, handling)
            }
            guard seen.count == expected.count else { throw BackupError.invalidArchive }
            return DecodedBackup(document: document, isLegacyJSON: false, formatVersion: 2, assets: references, file: reader.file)
        } catch is RecordArchiveInvalid { throw BackupError.invalidArchive }
        catch is RecordArchiveTruncated { throw BackupError.invalidArchive }
    }

    /// Read in bounded chunks so even a growing/provider file cannot cause an
    /// unbounded Data(contentsOf:) allocation before the size check.
    public static func read(_ url: URL) throws -> Data {
        try readBounded(url, limit: maximumBytes)
    }

    static func readBounded(_ url: URL, limit: Int) throws -> Data {
        guard (1...maximumBytes).contains(limit) else { throw BackupError.sizeLimit }
        return try BoundedFile.read(url, limit: limit)
    }
}

public struct PreparedRestore: Sendable {
    public let id: UUID
    public let document: Notebook
    public let isLegacyJSON: Bool
    /// The staged, verified image originals (read-only), for the UI's checks.
    public let assets: NotebookAssets
    // Only the repository can issue a token tied to these exact staged bytes.
    let archive: LibraryArchiveFileInfo
    let assetReferences: [ImageAssetReference]
}

public struct RestoredPagePreview: Identifiable, Sendable {
    public let id: UUID
    public let pageNumber: Int
    public let text: String
}

public struct RestoredNotebook: Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public let directory: URL
    public let collectionDirectory: URL
    public let modifiedAt: Date?
    public let textPages: [RestoredPagePreview]
    public var preferredPageID: UUID? = nil
}

public struct RestoreCatalog: Sendable {
    public var notebooks: [RestoredNotebook] = []
    public var unreadableCount = 0
}
