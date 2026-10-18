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
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: 64_000), !chunk.isEmpty {
            guard chunk.count <= limit - data.count else { throw BackupError.sizeLimit }
            data.append(chunk)
        }
        return data
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
