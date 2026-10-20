import Foundation

public enum BackupError: Error, LocalizedError {
    case invalidArchive
    case unsupportedVersion(Int)
    case sizeLimit
    case checksumMismatch
    case invalidStaging

    public var errorDescription: String? {
        switch self {
        case .invalidArchive: "Die Datei ist kein vollständiges unterstütztes noty-Backup."
        case .unsupportedVersion(let version): "Backupformat \(version) benötigt eine neuere noty-Version."
        case .sizeLimit: "Das Backup überschreitet das aktuelle Größenlimit von 200 MB."
        case .checksumMismatch: "Die Backup-Prüfsumme stimmt nicht. Es wurde nichts wiederhergestellt."
        case .invalidStaging: "Die vorbereitete Wiederherstellung ist nicht mehr gültig. Bitte das Backup erneut auswählen."
        }
    }
}

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

public struct DecodedBackup: Sendable {
    public let document: Notebook
    public let isLegacyJSON: Bool
}

/// Open, uncompressed single-document archive: magic + header length + JSON
/// manifest + Notebook JSON. No archive paths are extracted onto the filesystem.
public enum BackupArchive {
    public static let maximumBytes = 200_000_000
    static let magic = Data("NOTYBKP\n".utf8)
    static let maximumHeaderBytes = 64_000

    public static func encode(_ document: Notebook, createdAt: Date = Date()) throws -> Data {
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
        let length = UInt32(header.count)
        var archive = magic
        archive.append(contentsOf: [UInt8((length >> 24) & 255), UInt8((length >> 16) & 255),
                                    UInt8((length >> 8) & 255), UInt8(length & 255)])
        archive.append(header)
        archive.append(payload)
        // Validate the exact finished bytes before handing them to the exporter.
        guard try decode(archive).document == document else { throw BackupError.invalidArchive }
        return archive
    }

    public static func decode(_ data: Data) throws -> DecodedBackup {
        do { return try decodeValidated(data) }
        catch let error as BackupError { throw error }
        catch let error as StorageError { throw error }
        catch { throw BackupError.invalidArchive }
    }

    private static func decodeValidated(_ data: Data) throws -> DecodedBackup {
        guard data.count <= maximumBytes else { throw BackupError.sizeLimit }
        guard data.starts(with: magic) else {
            // Preserve access to the prototype's explicitly exported JSON files.
            return DecodedBackup(document: try Notebook.decode(data), isLegacyJSON: true)
        }
        guard data.count >= 12 else { throw BackupError.invalidArchive }
        let prefix = Array(data.prefix(12))
        let headerLength = Int(prefix[8..<12].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
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
        return DecodedBackup(document: document, isLegacyJSON: false)
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

/// Incremental CRC-32/ISO-HDLC (same values as zlib.crc32), slicing-by-8 so
/// multi-hundred-megabyte archives can be checked block by block.
struct StreamingCRC32 {
    private static let table: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 8 * 256)
        for byte in 0..<256 {
            var value = UInt32(byte)
            for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 1 ? 0xedb88320 : 0) }
            table[byte] = value
        }
        for slice in 1..<8 {
            for byte in 0..<256 {
                let previous = table[(slice - 1) * 256 + byte]
                table[slice * 256 + byte] = (previous >> 8) ^ table[Int(previous & 255)]
            }
        }
        return table
    }()
    private var state: UInt32 = 0xffffffff
    var value: UInt32 { state ^ 0xffffffff }

    mutating func update(_ data: Data) { data.withUnsafeBytes { update($0) } }
    mutating func update(_ bytes: UnsafeRawBufferPointer) {
        guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
        var crc = state, index = 0
        let count = bytes.count
        Self.table.withUnsafeBufferPointer { t in
            while index + 8 <= count {
                let one = crc ^ (UInt32(base[index]) | UInt32(base[index + 1]) << 8 | UInt32(base[index + 2]) << 16 | UInt32(base[index + 3]) << 24)
                let two = UInt32(base[index + 4]) | UInt32(base[index + 5]) << 8 | UInt32(base[index + 6]) << 16 | UInt32(base[index + 7]) << 24
                crc = t[1792 + Int(one & 255)] ^ t[1536 + Int((one >> 8) & 255)] ^ t[1280 + Int((one >> 16) & 255)] ^ t[1024 + Int(one >> 24)]
                    ^ t[768 + Int(two & 255)] ^ t[512 + Int((two >> 8) & 255)] ^ t[256 + Int((two >> 16) & 255)] ^ t[Int(two >> 24)]
                index += 8
            }
            while index < count { crc = t[Int((crc ^ UInt32(base[index])) & 255)] ^ (crc >> 8); index += 1 }
        }
        state = crc
    }
    static func checksum(_ data: Data) -> UInt32 { var crc = StreamingCRC32(); crc.update(data); return crc.value }
}

/// Exact byte count and CRC-32 of a complete archive file.
public struct LibraryArchiveFileInfo: Codable, Equatable, Sendable {
    public let byteCount: Int
    public let crc32: UInt32
    public init(byteCount: Int, crc32: UInt32) { self.byteCount = byteCount; self.crc32 = crc32 }
}

/// Bounded, block-wise file access shared by backup readers and transports:
/// no unbounded `Data(contentsOf:)` before a size check, no whole archive in memory.
public enum BoundedFile {
    static let block = 4 * 1024 * 1024

    /// Small files only (manifests, listings): the limit is checked while reading.
    public static func read(_ url: URL, limit: Int) throws -> Data {
        guard limit >= 1 else { throw BackupError.sizeLimit }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(64_000, limit + 1)), !chunk.isEmpty {
            guard chunk.count <= limit - data.count else { throw BackupError.sizeLimit }
            data.append(chunk)
        }
        return data
    }

    /// Size and CRC-32 of a regular file (no symbolic link), streamed in blocks.
    public static func checksum(_ url: URL, limit: Int = LibraryArchive.maximumBytes) throws -> LibraryArchiveFileInfo {
        try requireRegularFile(url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var crc = StreamingCRC32(), count = 0
        while let chunk = try handle.read(upToCount: block), !chunk.isEmpty {
            guard chunk.count <= limit - count else { throw LibraryArchiveError.archiveTooLarge }
            crc.update(chunk); count += chunk.count
        }
        return LibraryArchiveFileInfo(byteCount: count, crc32: crc.value)
    }

    /// Streams `source` into a newly created `destination` (never replaces an
    /// existing file) and syncs it. A partially written destination is removed.
    @discardableResult
    public static func copy(from source: URL, to destination: URL, limit: Int = LibraryArchive.maximumBytes) throws -> LibraryArchiveFileInfo {
        try requireRegularFile(source)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        try Data().write(to: destination, options: .withoutOverwriting)
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: destination) } }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var crc = StreamingCRC32(), count = 0
        while let chunk = try input.read(upToCount: block), !chunk.isEmpty {
            guard chunk.count <= limit - count else { throw LibraryArchiveError.archiveTooLarge }
            try output.write(contentsOf: chunk)
            crc.update(chunk); count += chunk.count
        }
        try output.synchronize()
        complete = true
        return LibraryArchiveFileInfo(byteCount: count, crc32: crc.value)
    }

    static func requireRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw LibraryArchiveError.invalid }
    }
}

public struct PreparedRestore: Sendable {
    public let id: UUID
    public let document: Notebook
    public let isLegacyJSON: Bool
    // Only the repository can issue a token tied to these exact staged bytes.
    let archiveCRC32: UInt32
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
