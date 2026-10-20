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
        case .snapshotTooLarge: "Der Speicherstand überschreitet das aktuelle Größenlimit von 200 MB. Bitte große PDFs oder Bilder entfernen, auch aus dem Seitenpapierkorb."
        case .revisionUnavailable: "Dieser lokale Stand ist nicht mehr verfügbar. Bitte die Liste neu öffnen."
        }
    }
}

/// Single-owner store. Immutable complete revisions are committed by replacing
/// the manifest last. Old prototype files remain untouched during migration.
public final class RevisionStore {
    public let directory: URL
    /// The loaded state is an older fallback (newer manifest/revision damaged or
    /// unreadable). The next commit keeps the skipped newer data in `Quarantine/`.
    public private(set) var recovered = false
    private var loaded = false
    private var lastDocument: Notebook?
    private var lastBytes: Data?
    private var lastManifest: RevisionManifest?
    /// Revision files of the acknowledged chain this store loaded, wrote or
    /// committed. Only these are ever deleted; any other unreferenced revision
    /// (e.g. a newer one skipped by a fallback) is quarantined instead.
    private var known = Set<String>()
    /// manifest.json exists but was unusable; a copy is kept before replacing it.
    private var damagedPrimary = false
    /// Commit timestamps (`savedAtUnix`); replaceable in tests.
    var clock: () -> Date = { Date() }
    private let fm = FileManager.default
    private static let maximumBytes = 200_000_000
    private var primary: URL { directory.appendingPathComponent("manifest.json") }
    private var previous: URL { directory.appendingPathComponent("manifest-previous.json") }
    private var revisions: URL { directory.appendingPathComponent("Revisions", isDirectory: true) }
    private var quarantine: URL { directory.appendingPathComponent("Quarantine", isDirectory: true) }

    public init(directory: URL) { self.directory = directory }

    public func load() throws -> Notebook {
        var skipped = Set<String>()
        for manifestURL in [primary, previous] where fm.fileExists(atPath: manifestURL.path) {
            do {
                let manifest = try readManifest(manifestURL)
                for (offset, record) in manifest.revisions.enumerated() {
                    do {
                        let bytes = try readRevisionBytes(record)
                        let document = try Notebook.decode(bytes)
                        // Skipped newer entries leave the chain, but are never deleted.
                        let retained = Array(manifest.revisions.dropFirst(offset))
                        skipped.formUnion(manifest.revisions.prefix(offset).map(\.file))
                        var chain = Set(retained.map(\.file))
                        if manifestURL == primary, let older = try? readManifest(previous) {
                            chain.formUnion(older.revisions.map(\.file))
                        }
                        known = chain.subtracting(skipped)
                        damagedPrimary = manifestURL != primary
                        lastManifest = RevisionManifest(revisions: retained)
                        lastDocument = document
                        lastBytes = bytes
                        recovered = manifestURL != primary || offset > 0
                        loaded = true
                        return document
                    } catch StorageError.unsupportedSchema(let version) {
                        throw StorageError.unsupportedSchema(version)
                    } catch { continue }
                }
                skipped.formUnion(manifest.revisions.map(\.file))
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
        known = []
        damagedPrimary = false
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
            try archiveMigrationSource(lastBytes, schemaVersion: old.schemaVersion)
        }
        try fm.createDirectory(at: revisions, withIntermediateDirectories: true)
        try validateRevisionDirectory()
        var old = lastManifest
        var written: [String] = []
        let manifest: RevisionManifest
        do {
            if old == nil, hasLegacyFiles, let legacy = lastDocument {
                // The first package commit also has a valid previous pointer to the
                // acknowledged prototype, even if its final manifest write fails.
                let legacyBytes = try JSONEncoder().encode(legacy)
                guard legacyBytes.count <= Self.maximumBytes else { throw RevisionError.snapshotTooLarge }
                let legacyRecord = try writeRevision(legacyBytes)
                written.append(legacyRecord.file)
                old = RevisionManifest(revisions: [legacyRecord])
            }
            let record = try writeRevision(bytes)
            written.append(record.file)
            manifest = RevisionManifest(revisions: Self.retained([record] + (old?.revisions ?? [])))
            if damagedPrimary { preserveDamagedPrimary() }
            if let old { try JSONEncoder().encode(old).write(to: previous, options: .atomic) }
            // Commit point: no UI may claim success before this atomic replacement.
            try JSONEncoder().encode(manifest).write(to: primary, options: .atomic)
        } catch {
            discardUncommitted(written)
            throw error
        }
        lastManifest = manifest
        lastDocument = document
        lastBytes = bytes
        recovered = false
        damagedPrimary = false
        let referenced = Set((manifest.revisions + (old?.revisions ?? [])).map(\.file))
        known.formUnion(referenced)
        collectGarbage(keeping: referenced)
    }

    /// Archives exact acknowledged bytes before any migration commit or GC.
    /// A retried commit (e.g. automatic save retry) reuses an existing archive
    /// with identical bytes (size, CRC, then bytes) instead of adding a copy.
    private func archiveMigrationSource(_ bytes: Data, schemaVersion: Int) throws {
        let parent = directory.appendingPathComponent("Migrations", isDirectory: true)
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let values = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw RevisionError.invalidManifest }
        let name = "notebook-v\(schemaVersion).json"
        let checksum = SnapshotChecksum.crc32(bytes)
        for folder in (try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? [] {
            guard UUID(uuidString: folder.lastPathComponent) != nil,
                  let kind = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  kind.isDirectory == true, kind.isSymbolicLink != true else { continue }
            let file = folder.appendingPathComponent(name)
            guard let info = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  info.isRegularFile == true, info.isSymbolicLink != true, info.fileSize == bytes.count,
                  let existing = try? Data(contentsOf: file), SnapshotChecksum.crc32(existing) == checksum,
                  existing == bytes else { continue }
            return
        }
        let archive = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: archive, withIntermediateDirectories: false)
        let original = archive.appendingPathComponent(name)
        try bytes.write(to: original, options: .atomic)
        guard try Data(contentsOf: original) == bytes else { throw RevisionError.noCompleteRevision }
    }

    static let newestKept = 3
    static let maximumKept = 8
    static let checkpointSpacing: Double = 600
    static let maximumCheckpointBytes = 300_000_000

    /// Local history tiers for `candidates` (newest first): the newest three
    /// always; older entries only as checkpoints at least 10 minutes apart by
    /// `savedAtUnix`, each measured from the next older kept checkpoint, so
    /// continuous editing leaves one every 10 minutes. At most eight entries and
    /// 300 MB of checkpoints; the oldest checkpoints go first. Entries without a
    /// timestamp are never checkpoints.
    static func retained(_ candidates: [RevisionRecord]) -> [RevisionRecord] {
        let newest = Array(candidates.prefix(newestKept))
        var checkpoints: [RevisionRecord] = [] // oldest first
        for candidate in candidates.dropFirst(newestKept).reversed() {
            guard let time = candidate.savedAtUnix else { continue }
            if let last = checkpoints.last?.savedAtUnix, time - last < checkpointSpacing { continue }
            checkpoints.append(candidate)
        }
        var bytes = checkpoints.reduce(0) { $0 + $1.byteCount }
        while checkpoints.count > maximumKept - newest.count || bytes > maximumCheckpointBytes {
            bytes -= checkpoints.removeFirst().byteCount
        }
        return newest + checkpoints.reversed()
    }

    /// Best effort after a commit; keeps every revision referenced by either
    /// manifest. Revisions this store dropped itself are deleted. Unreferenced
    /// revisions it never acknowledged (newer ones skipped by a fallback, foreign
    /// leftovers) are moved to `Quarantine/`, never deleted or overwritten.
    /// Legacy files, other names, directories and symlinks stay untouched.
    private func collectGarbage(keeping referenced: Set<String>) {
        guard let files = try? fm.contentsOfDirectory(atPath: revisions.path) else { return }
        for file in files where validFilename(file) && !referenced.contains(file) {
            let url = revisions.appendingPathComponent(file)
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            if known.contains(file) {
                if (try? fm.removeItem(at: url)) != nil { known.remove(file) }
            } else {
                moveToQuarantine(url)
            }
        }
    }

    private func moveToQuarantine(_ url: URL) {
        guard let folder = try? quarantineDirectory() else { return }
        var target = folder.appendingPathComponent(url.lastPathComponent)
        if itemExists(target) { target = folder.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)") }
        guard !itemExists(target) else { return }
        try? fm.moveItem(at: url, to: target)
    }

    /// A damaged manifest.json is the only pointer to skipped newer revisions;
    /// keep a copy beside them before the recovered commit replaces it.
    /// Copied once; a failed copy is retried with the next commit attempt.
    private func preserveDamagedPrimary() {
        guard let values = try? primary.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { damagedPrimary = false; return }
        guard let folder = try? quarantineDirectory() else { return }
        let target = folder.appendingPathComponent("manifest-\(UUID().uuidString).json")
        guard !itemExists(target), (try? fm.copyItem(at: primary, to: target)) != nil else { return }
        damagedPrimary = false
    }

    private func quarantineDirectory() throws -> URL {
        try fm.createDirectory(at: quarantine, withIntermediateDirectories: true)
        let values = try quarantine.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw RevisionError.invalidManifest }
        return quarantine
    }

    /// After a failed commit, remove this attempt's new revision files that no
    /// readable manifest on disk references, so repeated automatic retries cannot
    /// fill the disk. An unreadable manifest was not written by this attempt and
    /// cannot name its fresh UUIDs.
    private func discardUncommitted(_ files: [String]) {
        let referenced = Set([primary, previous].compactMap { try? readManifest($0) }.flatMap { $0.revisions.map(\.file) })
        for file in files where !referenced.contains(file) {
            if (try? fm.removeItem(at: revisions.appendingPathComponent(file))) != nil { known.remove(file) }
        }
    }

    /// Does not follow a final symlink.
    private func itemExists(_ url: URL) -> Bool { (try? fm.attributesOfItem(atPath: url.path)) != nil }

    private func readManifest(_ url: URL) throws -> RevisionManifest {
        let bytes = try readRegularFile(url, limit: 128_000)
        struct Header: Decodable { var formatVersion: Int }
        let version = try JSONDecoder().decode(Header.self, from: bytes).formatVersion
        guard version == 1 else { throw RevisionError.unsupportedFormat(version) }
        let manifest = try JSONDecoder().decode(RevisionManifest.self, from: bytes)
        try validate(manifest)
        return manifest
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

    private var hasLegacyFiles: Bool {
        fm.fileExists(atPath: directory.appendingPathComponent("notebook.json").path)
            || fm.fileExists(atPath: directory.appendingPathComponent("recovery.json").path)
    }

    private func writeRevision(_ bytes: Data) throws -> RevisionRecord {
        let record = RevisionRecord(file: UUID().uuidString + ".json", byteCount: bytes.count,
                                    crc32: SnapshotChecksum.crc32(bytes), savedAtUnix: clock().timeIntervalSince1970)
        let url = revisions.appendingPathComponent(record.file)
        guard !fm.fileExists(atPath: url.path) else { throw RevisionError.invalidManifest }
        try bytes.write(to: url, options: .atomic)
        known.insert(record.file)
        // Re-read staged bytes before making this revision discoverable.
        let staged = try readRegularFile(url, limit: record.byteCount)
        guard staged.count == record.byteCount, SnapshotChecksum.crc32(staged) == record.crc32 else {
            if (try? fm.removeItem(at: url)) != nil { known.remove(record.file) }
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
              (1...Self.maximumKept).contains(manifest.revisions.count),
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
