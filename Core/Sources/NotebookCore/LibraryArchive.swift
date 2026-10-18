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

public enum LibraryArchiveError: Error, LocalizedError {
    case invalid, unsupported(Int), incomplete, destinationExists
    public var errorDescription: String? {
        switch self {
        case .invalid: "Die Datei ist kein vollständiges gültiges Bibliotheksbackup."
        case .unsupported(let version): "Bibliotheksbackup \(version) benötigt eine neuere noty-Version."
        case .incomplete: "Mindestens ein Heft ist nicht vollständig lesbar. Bibliotheksbackup abgebrochen; Dateien bleiben erhalten."
        case .destinationExists: "Der neue Wiederherstellungsbereich ist bereits vorhanden. Es wurde nichts überschrieben."
        }
    }
}

struct LibraryArchiveEntry: Codable {
    var kind: String
    var id: UUID?
    var byteCount: Int
    var crc32: UInt32
}
struct LibraryArchiveManifest: Codable {
    var libraryBackupVersion = 1
    var checksumAlgorithm = "crc32-iso-hdlc"
    var createdAt: Date
    var entries: [LibraryArchiveEntry]
}

/// NOTYLIB\n + uint32 BE manifest length + JSON manifest + bounded raw chunks.
/// There are no archive paths. Chunk IDs are checked against the index; restore
/// chooses every output path itself. Includes trash, excludes revision history.
public enum LibraryArchive {
    public static let maximumBytes = 200_000_000
    static let magic = Data("NOTYLIB\n".utf8)
    static let maximumHeader = 2_000_000

    public static func encode(_ bundle: LibraryBundle, createdAt: Date = Date()) throws -> Data {
        try bundle.validate()
        var chunks = [try JSONEncoder().encode(bundle.snapshot), try JSONEncoder().encode(bundle.toolbar)]
        var entries = [LibraryArchiveEntry(kind: "index", byteCount: chunks[0].count, crc32: SnapshotChecksum.crc32(chunks[0])),
                       LibraryArchiveEntry(kind: "toolbar", byteCount: chunks[1].count, crc32: SnapshotChecksum.crc32(chunks[1]))]
        var total = chunks[0].count + chunks[1].count
        for document in bundle.documents {
            let data = try JSONEncoder().encode(document)
            guard data.count <= maximumBytes - total else { throw BackupError.sizeLimit }
            total += data.count
            entries.append(LibraryArchiveEntry(kind: "notebook", id: document.id, byteCount: data.count, crc32: SnapshotChecksum.crc32(data)))
            chunks.append(data)
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let manifest = try encoder.encode(LibraryArchiveManifest(createdAt: createdAt, entries: entries))
        guard manifest.count <= maximumHeader, total + manifest.count + 12 <= maximumBytes else { throw BackupError.sizeLimit }
        let length = UInt32(manifest.count)
        var result = magic
        result.append(contentsOf: [UInt8(length >> 24), UInt8((length >> 16) & 255), UInt8((length >> 8) & 255), UInt8(length & 255)])
        result.append(manifest)
        for chunk in chunks { result.append(chunk) }
        guard try decode(result) == bundle else { throw LibraryArchiveError.invalid }
        return result
    }

    public static func decode(_ data: Data) throws -> LibraryBundle {
        do { return try decodeValidated(data) }
        catch let error as LibraryArchiveError { throw error }
        catch let error as BackupError { throw error }
        catch let error as StorageError { throw error }
        catch let error as LibraryError { throw error }
        catch let error as ToolbarError { throw error }
        catch { throw LibraryArchiveError.invalid }
    }

    private static func decodeValidated(_ data: Data) throws -> LibraryBundle {
        guard data.count <= maximumBytes else { throw BackupError.sizeLimit }
        guard data.count >= 12, data.starts(with: magic) else { throw LibraryArchiveError.invalid }
        let bytes = Array(data.prefix(12))
        let length = Int(bytes[8..<12].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        guard (1...maximumHeader).contains(length), data.count >= 12 + length else { throw LibraryArchiveError.invalid }
        let header = Data(data.dropFirst(12).prefix(length))
        struct Version: Decodable { var libraryBackupVersion: Int }
        let version = try JSONDecoder().decode(Version.self, from: header).libraryBackupVersion
        guard version == 1 else { throw LibraryArchiveError.unsupported(version) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(LibraryArchiveManifest.self, from: header)
        guard manifest.checksumAlgorithm == "crc32-iso-hdlc", (2...10_002).contains(manifest.entries.count),
              manifest.entries[0].kind == "index", manifest.entries[0].id == nil,
              manifest.entries[1].kind == "toolbar", manifest.entries[1].id == nil else { throw LibraryArchiveError.invalid }
        var offset = 12 + length
        var snapshot: LibrarySnapshot?
        var toolbar: ToolbarPreferences?
        var documents: [Notebook] = []
        var ids = Set<UUID>()
        for (index, entry) in manifest.entries.enumerated() {
            let limit = index == 0 ? 4_000_000 : (index == 1 ? 64_000 : maximumBytes)
            guard (1...limit).contains(entry.byteCount), entry.byteCount <= data.count - offset else { throw LibraryArchiveError.invalid }
            let payload = Data(data.dropFirst(offset).prefix(entry.byteCount))
            guard SnapshotChecksum.crc32(payload) == entry.crc32 else { throw BackupError.checksumMismatch }
            offset += entry.byteCount
            if index == 0 {
                let value = try JSONDecoder().decode(LibrarySnapshot.self, from: payload)
                try value.validate(); snapshot = value
            } else if index == 1 { toolbar = try ToolbarPreferences.decode(payload) }
            else {
                guard entry.kind == "notebook", let id = entry.id, ids.insert(id).inserted else { throw LibraryArchiveError.invalid }
                let document = try Notebook.decode(payload)
                guard document.id == id else { throw LibraryArchiveError.invalid }
                documents.append(document)
            }
        }
        guard offset == data.count, let snapshot, let toolbar else { throw LibraryArchiveError.invalid }
        let bundle = LibraryBundle(snapshot: snapshot, documents: documents, toolbar: toolbar)
        try bundle.validate(); return bundle
    }

    public static func read(_ url: URL) throws -> Data { try BackupArchive.readBounded(url, limit: maximumBytes) }
}
