import Foundation

/// CRC-32/ISO-HDLC detects accidental corruption, not deliberate tampering.
/// No compression, authentication or encryption is implied.
enum SnapshotChecksum {
    private static let table: [UInt32] = (0..<256).map { byte in
        var value = UInt32(byte)
        for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 1 ? 0xedb88320 : 0) }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 255)] ^ (crc >> 8) }
        return crc ^ 0xffffffff
    }
}

struct RevisionRecord: Codable, Equatable {
    var file: String
    var byteCount: Int
    var crc32: UInt32
    var savedAtUnix: Double? = nil
}

public struct LocalRevision: Identifiable, Sendable {
    public let id: UUID
    public let savedAt: Date?
    public let title: String
    public let pageCount: Int
    public let isLatest: Bool
}

public struct LocalHistory: Sendable {
    public var revisions: [LocalRevision] = []
    public var unreadableCount = 0
}

struct RevisionManifest: Codable {
    var formatVersion = 1
    var checksumAlgorithm = "crc32-iso-hdlc"
    var revisions: [RevisionRecord]
}

public enum RevisionError: Error, LocalizedError {
    case unsupportedFormat(Int)
    case invalidManifest
    case noCompleteRevision
    case snapshotTooLarge
    case revisionUnavailable

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let version): "Speicherformat \(version) benötigt eine neuere noty-Version."
        case .invalidManifest: "Das Speicherverzeichnis enthält ein ungültiges Manifest."
        case .noCompleteRevision: "Kein vollständiger, geprüfter Speicherstand gefunden. Vorhandene Dateien bleiben erhalten."
        case .snapshotTooLarge: "Der Speicherstand überschreitet das aktuelle Größenlimit von 200 MB."
        case .revisionUnavailable: "Dieser lokale Stand ist nicht mehr verfügbar. Bitte die Liste neu öffnen."
        }
    }
}

/// Single-owner store. Immutable complete revisions are committed by replacing
/// the manifest last. Old prototype files remain untouched during migration.
public final class RevisionStore {
    public let directory: URL
    public private(set) var recovered = false
    private var loaded = false
    private var lastDocument: Notebook?
    private var lastBytes: Data?
    private var lastManifest: RevisionManifest?
    private let fm = FileManager.default
    private static let maximumBytes = 200_000_000
    private var primary: URL { directory.appendingPathComponent("manifest.json") }
    private var previous: URL { directory.appendingPathComponent("manifest-previous.json") }
    private var revisions: URL { directory.appendingPathComponent("Revisions", isDirectory: true) }

    public init(directory: URL) { self.directory = directory }

    public func load() throws -> Notebook {
        for manifestURL in [primary, previous] where fm.fileExists(atPath: manifestURL.path) {
            do {
                let bytes = try readRegularFile(manifestURL, limit: 128_000)
                struct Header: Decodable { var formatVersion: Int }
                let version = try JSONDecoder().decode(Header.self, from: bytes).formatVersion
                guard version == 1 else { throw RevisionError.unsupportedFormat(version) }
                let manifest = try JSONDecoder().decode(RevisionManifest.self, from: bytes)
                try validate(manifest)
                for (offset, record) in manifest.revisions.enumerated() {
                    do {
                        let bytes = try readRevisionBytes(record)
                        let document = try Notebook.decode(bytes)
                        // Do not retain corrupt newer entries when repairing a recovery.
                        lastManifest = RevisionManifest(revisions: Array(manifest.revisions.dropFirst(offset)))
                        lastDocument = document
                        lastBytes = bytes
                        recovered = manifestURL != primary || offset > 0
                        loaded = true
                        return document
                    } catch StorageError.unsupportedSchema(let version) {
                        throw StorageError.unsupportedSchema(version)
                    } catch { continue }
                }
            } catch RevisionError.unsupportedFormat(let version) {
                throw RevisionError.unsupportedFormat(version)
            } catch StorageError.unsupportedSchema(let version) {
                throw StorageError.unsupportedSchema(version)
            } catch { continue }
        }
        // Once a package exists, never silently roll back to a stale prototype.
        guard !fm.fileExists(atPath: primary.path), !fm.fileExists(atPath: previous.path) else {
            throw RevisionError.noCompleteRevision
        }
        if !hasLegacyFiles, fm.fileExists(atPath: revisions.path),
           !(try fm.contentsOfDirectory(atPath: revisions.path)).isEmpty {
            throw RevisionError.noCompleteRevision
        }
        let legacy = NotebookStore(directory: directory)
        let document = try legacy.load()
        recovered = legacy.recovered
        loaded = true
        lastDocument = document
        lastBytes = nil // Exact legacy originals remain at notebook.json/recovery.json.
        lastManifest = nil
        return document
    }

    public func save(_ document: Notebook) throws {
        if !loaded { _ = try load() }
        if lastManifest != nil, !recovered, lastDocument == document,
           fm.fileExists(atPath: primary.path) { return }
        let bytes = try JSONEncoder().encode(document)
        guard bytes.count <= Self.maximumBytes else { throw RevisionError.snapshotTooLarge }
        _ = try Notebook.decode(bytes)
        if let old = lastDocument, old.id == document.id, old.schemaVersion < document.schemaVersion,
           let lastBytes {
            let parent = directory.appendingPathComponent("Migrations", isDirectory: true)
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            let values = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw RevisionError.invalidManifest }
            let archive = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: archive, withIntermediateDirectories: false)
            let original = archive.appendingPathComponent("notebook-v\(old.schemaVersion).json")
            // Archive exact acknowledged bytes before any migration commit or GC.
            try lastBytes.write(to: original, options: .atomic)
            guard try Data(contentsOf: original) == lastBytes else { throw RevisionError.noCompleteRevision }
        }
        try fm.createDirectory(at: revisions, withIntermediateDirectories: true)
        try validateRevisionDirectory()
        var old = lastManifest
        if old == nil, hasLegacyFiles, let legacy = lastDocument {
            // The first package commit also has a valid previous pointer to the
            // acknowledged prototype, even if its final manifest write fails.
            let legacyBytes = try JSONEncoder().encode(legacy)
            guard legacyBytes.count <= Self.maximumBytes else { throw RevisionError.snapshotTooLarge }
            old = RevisionManifest(revisions: [try writeRevision(legacyBytes)])
        }
        let record = try writeRevision(bytes)
        let manifest = RevisionManifest(revisions: [record] + Array((old?.revisions ?? []).prefix(2)))
        if let old { try JSONEncoder().encode(old).write(to: previous, options: .atomic) }
        // Commit point: no UI may claim success before this atomic replacement.
        try JSONEncoder().encode(manifest).write(to: primary, options: .atomic)
        lastManifest = manifest
        lastDocument = document
        lastBytes = bytes
        recovered = false
        let referenced = Set((manifest.revisions + (old?.revisions ?? [])).map(\.file))
        // Cleanup is best effort after commit; keep every revision referenced by
        // either manifest. Never remove legacy files or unrelated filenames.
        if let files = try? fm.contentsOfDirectory(atPath: revisions.path) {
            for file in files where validFilename(file) && !referenced.contains(file) {
                let url = revisions.appendingPathComponent(file)
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values?.isRegularFile == true, values?.isSymbolicLink != true { try? fm.removeItem(at: url) }
            }
        }
    }

    public func localHistory() throws -> LocalHistory {
        if !loaded { _ = try load() }
        var history = LocalHistory()
        for (offset, record) in (lastManifest?.revisions ?? []).enumerated() {
            do {
                let document = try readDocument(record)
                guard let id = UUID(uuidString: String(record.file.dropLast(5))) else {
                    throw RevisionError.invalidManifest
                }
                let fileDate = (try? revisions.appendingPathComponent(record.file)
                    .resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                history.revisions.append(LocalRevision(id: id,
                    savedAt: record.savedAtUnix.map { Date(timeIntervalSince1970: $0) } ?? fileDate,
                    title: document.title, pageCount: document.pages.count, isLatest: offset == 0))
            } catch StorageError.unsupportedSchema(let version) {
                throw StorageError.unsupportedSchema(version)
            } catch { history.unreadableCount += 1 }
        }
        return history
    }

    public func localRevision(id: UUID) throws -> Notebook {
        if !loaded { _ = try load() }
        guard let record = lastManifest?.revisions.first(where: { $0.file == id.uuidString + ".json" }) else {
            throw RevisionError.revisionUnavailable
        }
        return try readDocument(record)
    }

    private func readDocument(_ record: RevisionRecord) throws -> Notebook {
        try Notebook.decode(readRevisionBytes(record))
    }

    private func readRevisionBytes(_ record: RevisionRecord) throws -> Data {
        let bytes = try readRegularFile(revisions.appendingPathComponent(record.file), limit: record.byteCount)
        guard bytes.count == record.byteCount, SnapshotChecksum.crc32(bytes) == record.crc32 else {
            throw RevisionError.noCompleteRevision
        }
        return bytes
    }

    /// Only called after NotebookRepository has archived the complete original
    /// directory. A deliberate restore can replace corruption, never a future format.
    func replaceArchivedOriginal(with document: Notebook) throws {
        if !loaded {
            do { _ = try load() }
            catch RevisionError.unsupportedFormat(let version) { throw RevisionError.unsupportedFormat(version) }
            catch StorageError.unsupportedSchema(let version) { throw StorageError.unsupportedSchema(version) }
            catch {
                lastDocument = nil
                lastBytes = nil
                lastManifest = nil
                recovered = false
                loaded = true
            }
        }
        try save(document)
    }

    private var hasLegacyFiles: Bool {
        fm.fileExists(atPath: directory.appendingPathComponent("notebook.json").path)
            || fm.fileExists(atPath: directory.appendingPathComponent("recovery.json").path)
    }

    private func writeRevision(_ bytes: Data) throws -> RevisionRecord {
        let record = RevisionRecord(file: UUID().uuidString + ".json", byteCount: bytes.count,
                                    crc32: SnapshotChecksum.crc32(bytes), savedAtUnix: Date().timeIntervalSince1970)
        let url = revisions.appendingPathComponent(record.file)
        guard !fm.fileExists(atPath: url.path) else { throw RevisionError.invalidManifest }
        try bytes.write(to: url, options: .atomic)
        // Re-read staged bytes before making this revision discoverable.
        let staged = try readRegularFile(url, limit: record.byteCount)
        guard staged.count == record.byteCount, SnapshotChecksum.crc32(staged) == record.crc32 else {
            throw RevisionError.noCompleteRevision
        }
        return record
    }

    private func validateRevisionDirectory() throws {
        let values = try revisions.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw RevisionError.invalidManifest }
    }

    private func validate(_ manifest: RevisionManifest) throws {
        guard manifest.checksumAlgorithm == "crc32-iso-hdlc",
              (1...3).contains(manifest.revisions.count),
              Set(manifest.revisions.map(\.file)).count == manifest.revisions.count,
              manifest.revisions.allSatisfy({ validFilename($0.file) && (1...Self.maximumBytes).contains($0.byteCount)
                  && ($0.savedAtUnix.map { $0.isFinite && (-62_135_596_800...253_402_300_799).contains($0) } ?? true) }) else {
            throw RevisionError.invalidManifest
        }
    }

    private func validFilename(_ file: String) -> Bool {
        guard file.hasSuffix(".json"), let id = UUID(uuidString: String(file.dropLast(5))) else { return false }
        return id.uuidString + ".json" == file
    }

    private func readRegularFile(_ url: URL, limit: Int) throws -> Data {
        if url.deletingLastPathComponent() == revisions { try validateRevisionDirectory() }
        // Do not follow a supplied leaf symlink, or allocate an unchecked file.
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, (1...limit).contains(size) else {
            throw RevisionError.invalidManifest
        }
        return try Data(contentsOf: url)
    }
}
