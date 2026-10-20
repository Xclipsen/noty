import Foundation

/// CRC-32/ISO-HDLC detects accidental corruption, not deliberate tampering.
/// No compression, authentication or encryption is implied.
/// Revisions, manifests and archives share one implementation (slicing by
/// eight, `StreamingCRC32`): several times faster than a byte loop, which
/// matters for revisions with embedded PDFs or legacy images in debug builds.
enum SnapshotChecksum {
    static func crc32(_ data: Data) -> UInt32 { StreamingCRC32.checksum(data) }
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

/// `checkpoints.json`: older local-history states beyond the three manifest
/// entries. Separate so manifests keep the Build 46 format (1–3 entries); a
/// missing/damaged list or missing files only shorten the history.
struct CheckpointList: Codable, Equatable {
    var formatVersion = 1
    var checksumAlgorithm = "crc32-iso-hdlc"
    var checkpoints: [RevisionRecord]
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
        case .snapshotTooLarge: "Der Speicherstand überschreitet das Größenlimit von 200 MB (Bildoriginale zählen nicht mit, sie liegen getrennt). Bitte große PDFs entfernen, auch aus dem Seitenpapierkorb."
        case .revisionUnavailable: "Dieser lokale Stand ist nicht mehr verfügbar. Bitte die Liste neu öffnen."
        }
    }
}

/// Single-owner store. Immutable complete revisions are committed by replacing
/// the manifest last. Old prototype files remain untouched during migration.
///
/// Image originals (schema 12) are package assets (`assets`): a commit writes
/// every referenced and every pending asset first (verified, never
/// overwritten), then the revision, `checkpoints.json`, the previous manifest
/// and the manifest last. Loading accepts a schema-12 revision only if its
/// assets are present (stat); otherwise it falls back like on a CRC error and
/// deletes nothing. Embedded originals of schema 5–11 go to the pending area;
/// opening alone writes nothing.
public final class RevisionStore {
    public let directory: URL
    /// This package's image originals; the writable instance only here.
    public let assets: NotebookAssets
    /// Reading only (preview, search, duplicate source): `save` throws.
    public let readOnly: Bool
    /// The loaded state is an older fallback (newer manifest/revision damaged or
    /// unreadable). The next commit keeps the skipped newer data in `Quarantine/`.
    public private(set) var recovered = false
    private var loaded = false
    private var lastDocument: Notebook?
    private var lastBytes: Data?
    /// Schema of `lastBytes` as stored. `lastDocument` may already be raised to
    /// 12 in memory; the migration copy depends on the stored value.
    private var lastStoredSchema: Int?
    private var lastManifest: RevisionManifest?
    /// Revision files of the acknowledged chain (manifests, checkpoints) this
    /// store loaded, wrote or committed. Unknown unreferenced revisions are
    /// quarantined after a fallback load and otherwise deleted like dropped
    /// known ones (rests of an interrupted commit), see `collectGarbage`.
    private var known = Set<String>()
    /// manifest.json exists but was unusable; a copy is kept before replacing it.
    private var damagedPrimary = false
    /// Older local-history states from checkpoints.json whose files exist.
    private var checkpoints: [RevisionRecord] = []
    /// A checkpoints.json of a newer format is left untouched.
    private var checkpointsLocked = false
    /// checkpoints.json exists but could not be used: revision files present at
    /// load may belong to it and are left in place this session.
    private var checkpointsUncertain = false
    private var preexisting = Set<String>()
    /// This store's load fell back to an older state (sticky for its lifetime):
    /// unknown revision files are quarantined instead of deleted.
    private var fallbackLoaded = false
    /// Quarantine set of the current commit, created on first use.
    private var quarantineSet: URL?
    /// A commit happened since loading: the opening asset GC is over.
    private var committedSinceLoad = false
    /// The closing asset GC ran: no further opening run on this store.
    private var assetSessionClosed = false
    /// Commit timestamps (`savedAtUnix`); replaceable in tests.
    var clock: () -> Date = { Date() }
    /// Test hook after each commit step (crash images, injected failures).
    var commitFault: (CommitStage) throws -> Void = { _ in }
    enum CommitStage { case assetsWritten, revisionWritten, checkpointsWritten, previousWritten }
    private let fm = FileManager.default
    private static let maximumBytes = 200_000_000
    private var primary: URL { directory.appendingPathComponent("manifest.json") }
    private var previous: URL { directory.appendingPathComponent("manifest-previous.json") }
    private var revisions: URL { directory.appendingPathComponent("Revisions", isDirectory: true) }
    private var quarantine: URL { directory.appendingPathComponent("Quarantine", isDirectory: true) }
    private var checkpointFile: URL { directory.appendingPathComponent("checkpoints.json") }

    public init(directory: URL, readOnly: Bool = false) {
        self.directory = directory
        self.readOnly = readOnly
        assets = NotebookAssets(package: directory, readOnly: readOnly)
    }

    public func load() throws -> Notebook {
        let decoded = try loadDecoded()
        // Embedded originals of schema 5–11: in memory until the first commit
        // writes them as assets (outside the fallback loop: a full pending
        // area is an error, never a reason to open an older state).
        for (sha256, data) in decoded.inlineImageBytes {
            try assets.stage(data, knownAs: ImageAssetReference(sha256: sha256, byteCount: data.count))
        }
        return decoded.notebook
    }

    private func loadDecoded() throws -> DecodedNotebook {
        var skipped = Set<String>()
        for manifestURL in [primary, previous] where fm.fileExists(atPath: manifestURL.path) {
            do {
                let manifest = try readManifest(manifestURL)
                for (offset, record) in manifest.revisions.enumerated() {
                    do {
                        let bytes = try readRevisionBytes(record)
                        let decoded = try NotebookDecoding.decode(bytes, storedFile: storedFile(record))
                        let document = decoded.notebook
                        // Incomplete like a CRC error: older state, nothing deleted.
                        guard assets.presentOnDisk(decoded.storedExternalAssets) else { throw RevisionError.noCompleteRevision }
                        // Skipped newer entries leave the chain, but are never deleted.
                        let retained = Array(manifest.revisions.dropFirst(offset))
                        skipped.formUnion(manifest.revisions.prefix(offset).map(\.file))
                        var chain = Set(retained.map(\.file))
                        if manifestURL == primary, let older = try? readManifest(previous) {
                            chain.formUnion(older.revisions.map(\.file))
                        }
                        known = chain.subtracting(skipped)
                        checkpoints = readCheckpoints().filter { !skipped.contains($0.file) && !retained.contains($0) }
                        known.formUnion(checkpoints.map(\.file))
                        preexisting = checkpointsUncertain ? Set((try? fm.contentsOfDirectory(atPath: revisions.path)) ?? []) : []
                        damagedPrimary = manifestURL != primary
                        lastManifest = RevisionManifest(revisions: retained)
                        lastDocument = document
                        lastBytes = bytes
                        lastStoredSchema = decoded.storedSchemaVersion
                        recovered = manifestURL != primary || offset > 0
                        fallbackLoaded = recovered
                        loaded = true
                        return decoded
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
        let decoded = try legacy.loadDecoded()
        recovered = legacy.recovered
        loaded = true
        lastDocument = decoded.notebook
        lastBytes = nil // Exact legacy originals remain at notebook.json/recovery.json.
        lastStoredSchema = nil
        lastManifest = nil
        known = []
        checkpoints = []
        checkpointsUncertain = false
        preexisting = []
        fallbackLoaded = false // Prototype files stay untouched; revision rests are uncommitted.
        damagedPrimary = false
        return decoded
    }

    /// `importingAssetsFrom`: where assets that are neither on disk nor
    /// pending here come from (a restore stage, the package of a duplicated
    /// notebook); each is copied and verified before the revision is written.
    public func save(_ document: Notebook, importingAssetsFrom source: ImageAssetProviding? = nil) throws {
        guard !readOnly else { throw ImageAssetError.readOnly }
        if !loaded { _ = try load() }
        if lastManifest != nil, !recovered, lastDocument == document,
           fm.fileExists(atPath: primary.path) { return }
        quarantineSet = nil
        let bytes = try JSONEncoder().encode(document)
        guard bytes.count <= Self.maximumBytes else { throw RevisionError.snapshotTooLarge }
        _ = try NotebookDecoding.decode(bytes)
        // The stored schema decides: after loading schema 11 with images the
        // document in memory is already 12, the bytes on disk are not.
        if let old = lastDocument, old.id == document.id, let lastBytes {
            let stored = lastStoredSchema ?? old.schemaVersion
            if stored < document.schemaVersion { try archiveMigrationSource(lastBytes, schemaVersion: stored) }
        }
        // Assets first: every referenced one and every pending one (undo may
        // bring a removed image back). A failure aborts before any revision;
        // written assets without a revision are harmless orphans.
        let pending = assets.pendingReferences
        try assets.persist(document.externalImageAssets + pending, from: source)
        try commitFault(.assetsWritten)
        try fm.createDirectory(at: revisions, withIntermediateDirectories: true)
        try validateRevisionDirectory()
        var old = lastManifest
        var written: [String] = []
        let manifest: RevisionManifest
        var nextCheckpoints: [RevisionRecord] = []
        var checkpointsWritten = false
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
            try commitFault(.revisionWritten)
            // Exactly the Build 46 manifest rule; older states go to checkpoints.json.
            let older = old?.revisions ?? []
            manifest = RevisionManifest(revisions: [record] + Array(older.prefix(2)))
            nextCheckpoints = Self.checkpoints(from: Array(older.dropFirst(2)) + checkpoints, besides: manifest.revisions)
            // Before the commit point, so a checkpoint never depends on a GC'd file.
            checkpointsWritten = writeCheckpoints(nextCheckpoints)
            try commitFault(.checkpointsWritten)
            if let old { try JSONEncoder().encode(old).write(to: previous, options: .atomic) }
            try commitFault(.previousWritten)
            // After the valid previous pointer exists; a crash now loads it again.
            if damagedPrimary { preserveDamagedPrimary() }
            // Commit point: no UI may claim success before this atomic replacement.
            try JSONEncoder().encode(manifest).write(to: primary, options: .atomic)
        } catch {
            discardUncommitted(written)
            throw error
        }
        lastManifest = manifest
        lastDocument = document
        lastBytes = bytes
        lastStoredSchema = document.schemaVersion
        committedSinceLoad = true
        // Written by this commit: the renderer reads the files from now on.
        assets.dropPending(pending)
        recovered = false
        damagedPrimary = false
        // If checkpoints.json could not be replaced, its old entries stay protected, too.
        let kept = checkpointsWritten ? nextCheckpoints : nextCheckpoints + checkpoints
        checkpoints = nextCheckpoints
        let referenced = Set((manifest.revisions + (old?.revisions ?? []) + kept).map(\.file))
        known.formUnion(referenced)
        collectGarbage(keeping: referenced)
    }

    public enum AssetGarbageMoment: Sendable { case opening, closing }

    /// Asset GC of this package. Only the single writer runs it, and never
    /// during an editor session, so undo/redo, copied pages and drags never
    /// point to a deleted original:
    /// - `.opening`: after loading and before this store's first commit
    ///   (skipped once a commit happened, or after `.closing`);
    /// - `.closing`: after the last successful commit; `current` must equal
    ///   the committed state (otherwise skipped). Ends the session.
    /// Skipped (nil) as well while `isBlocked` (a library/external backup or a
    /// restore runs, `BackupActivity`), after a fallback load that is not yet
    /// committed, and for an uncommitted prototype package.
    ///
    /// Kept: every quoted 64-hex string in any regular file below
    /// `Revisions/`, `Quarantine/`, `Migrations/` and `Archives/` (raw search,
    /// also damaged or newer files), the pending area, the committed state,
    /// `current` and `keeping` (e.g. the in-app object clipboard). Deleted:
    /// unreferenced assets older than 15 min, partial files older than 1 h.
    /// Any read error aborts before anything is deleted.
    @discardableResult
    public func collectAssetGarbage(_ moment: AssetGarbageMoment, current: Notebook? = nil, keeping: Set<String> = [],
                                    isBlocked: () -> Bool = { BackupActivity.shared.isActive }) throws -> ImageAssetGarbageReport? {
        guard !readOnly else { throw ImageAssetError.readOnly }
        guard loaded, !recovered, lastManifest != nil, let committed = lastDocument else { return nil }
        switch moment {
        case .opening:
            guard !committedSinceLoad, !assetSessionClosed else { return nil }
        case .closing:
            guard current == nil || current == committed else { return nil }
            assetSessionClosed = true
        }
        guard !isBlocked() else { return nil }
        var kept = keeping.union(committed.allImages.map(\.asset.sha256))
        if let current { kept.formUnion(current.allImages.map(\.asset.sha256)) }
        let report = try assets.collectGarbage(roots: NotebookAssets.garbageRoots(inPackage: directory),
                                               keeping: kept, isBlocked: isBlocked)
        return report.skipped ? nil : report
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
    /// (the manifest) and the checkpoints chosen from the rest.
    static func retained(_ candidates: [RevisionRecord]) -> [RevisionRecord] {
        let newest = Array(candidates.prefix(newestKept))
        return newest + checkpoints(from: Array(candidates.dropFirst(newestKept)), besides: newest)
    }

    /// Checkpoints from older `candidates` (newest first, duplicates and entries
    /// of `newest` ignored): at least 10 minutes apart by `savedAtUnix`, each
    /// measured from the next older kept checkpoint, so continuous editing
    /// leaves one every 10 minutes. With `newest` at most eight entries and
    /// 300 MB of checkpoints; the oldest go first. Entries without a timestamp
    /// are never checkpoints. Returns newest first.
    static func checkpoints(from candidates: [RevisionRecord], besides newest: [RevisionRecord]) -> [RevisionRecord] {
        var seen = Set(newest.map(\.file))
        let unique = candidates.filter { seen.insert($0.file).inserted }
        var kept: [RevisionRecord] = [] // oldest first
        for candidate in unique.reversed() {
            guard let time = candidate.savedAtUnix else { continue }
            if let last = kept.last?.savedAtUnix, time - last < checkpointSpacing { continue }
            kept.append(candidate)
        }
        var bytes = kept.reduce(0) { $0 + $1.byteCount }
        while kept.count > maximumKept - newest.count || bytes > maximumCheckpointBytes {
            bytes -= kept.removeFirst().byteCount
        }
        return kept.reversed()
    }

    /// Never throws: a missing, damaged or foreign list only shortens the
    /// history. Entries whose revision file is gone (e.g. collected by Build 46,
    /// which does not know this file) are dropped silently.
    private func readCheckpoints() -> [RevisionRecord] {
        checkpointsLocked = false
        checkpointsUncertain = false
        guard itemExists(checkpointFile) else { return [] }
        checkpointsUncertain = true
        guard let bytes = try? readRegularFile(checkpointFile, limit: 128_000) else { return [] }
        struct Header: Decodable { var formatVersion: Int }
        guard let version = try? JSONDecoder().decode(Header.self, from: bytes).formatVersion else { return [] }
        guard version == 1 else { checkpointsLocked = version > 1; return [] }
        guard let list = try? JSONDecoder().decode(CheckpointList.self, from: bytes),
              list.checksumAlgorithm == "crc32-iso-hdlc", list.checkpoints.count <= Self.maximumKept,
              Set(list.checkpoints.map(\.file)).count == list.checkpoints.count,
              list.checkpoints.allSatisfy(validRecord) else { return [] }
        checkpointsUncertain = false
        return list.checkpoints.filter { record in
            let values = try? revisions.appendingPathComponent(record.file)
                .resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            return values?.isRegularFile == true && values?.isSymbolicLink != true && values?.fileSize == record.byteCount
        }
    }

    /// Atomic and best effort; skipped when unchanged. False keeps the list on
    /// disk authoritative for GC.
    private func writeCheckpoints(_ next: [RevisionRecord]) -> Bool {
        guard !checkpointsLocked else { return false }
        if next == checkpoints, next.isEmpty || itemExists(checkpointFile) { return true }
        guard let bytes = try? JSONEncoder().encode(CheckpointList(checkpoints: next)), bytes.count <= 128_000,
              (try? bytes.write(to: checkpointFile, options: .atomic)) != nil else { return false }
        return true
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
            // checkpoints.json unreadable or newer: files from before this session
            // may still be history; leave them (this session's own rests go).
            if checkpointsUncertain, preexisting.contains(file) { continue }
            // Possibly newer data the fallback skipped: keep it in quarantine.
            if !known.contains(file), fallbackLoaded { moveToQuarantine(url); continue }
            // Dropped acknowledged states, or unacknowledged rests of an interrupted commit.
            if (try? fm.removeItem(at: url)) != nil { known.remove(file) }
        }
    }

    /// A failed move leaves the file in place, never deletes it.
    private func moveToQuarantine(_ url: URL) {
        guard let folder = try? quarantineSetDirectory() else { return }
        let target = folder.appendingPathComponent(url.lastPathComponent)
        guard !itemExists(target) else { return }
        try? fm.moveItem(at: url, to: target)
    }

    /// The damaged manifest.json is the only pointer to skipped newer
    /// revisions; it is moved (a rename, no extra space) into this commit's
    /// quarantine set right before the new manifest replaces it. Best effort:
    /// if that fails, e.g. on full storage, the commit still replaces it, so
    /// saving is never blocked; the skipped revisions stay preserved anyway.
    private func preserveDamagedPrimary() {
        damagedPrimary = false
        guard let values = try? primary.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let folder = try? quarantineSetDirectory() else { return }
        let target = folder.appendingPathComponent("manifest.json")
        guard !itemExists(target) else { return }
        try? fm.moveItem(at: primary, to: target)
    }

    static let quarantineSetsKept = 3

    /// One set per recovered commit: `Quarantine/<unix seconds>-<UUID>/`. Only
    /// the three newest sets of this package are kept.
    private func quarantineSetDirectory() throws -> URL {
        if let quarantineSet { return quarantineSet }
        try fm.createDirectory(at: quarantine, withIntermediateDirectories: true)
        let values = try quarantine.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw RevisionError.invalidManifest }
        let stamp = String(format: "%010d", Int(max(0, min(9_999_999_999, clock().timeIntervalSince1970))))
        let set = quarantine.appendingPathComponent("\(stamp)-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: set, withIntermediateDirectories: false)
        quarantineSet = set
        let sets = ((try? fm.contentsOfDirectory(atPath: quarantine.path)) ?? []).filter { name in
            let parts = name.split(separator: "-", maxSplits: 1)
            guard parts.count == 2, parts[0].count == 10, parts[0].allSatisfy(\.isASCII), parts[0].allSatisfy(\.isNumber),
                  UUID(uuidString: String(parts[1]))?.uuidString == String(parts[1]) else { return false }
            let kind = try? quarantine.appendingPathComponent(name).resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return kind?.isDirectory == true && kind?.isSymbolicLink != true
        }.sorted()
        for name in sets.dropLast(Self.quarantineSetsKept) where name != set.lastPathComponent {
            try? fm.removeItem(at: quarantine.appendingPathComponent(name))
        }
        return set
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
        let manifestEntries = lastManifest?.revisions ?? []
        for (offset, record) in (manifestEntries + checkpoints).enumerated() {
            let checkpoint = offset >= manifestEntries.count
            // A checkpoint file that disappeared is only shorter history.
            if checkpoint, !itemExists(revisions.appendingPathComponent(record.file)) { continue }
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
            } catch StorageError.unsupportedSchema(let version) where !checkpoint {
                throw StorageError.unsupportedSchema(version)
            } catch { history.unreadableCount += 1 }
        }
        return history
    }

    /// Manifest entries and checkpoints, by stable revision UUID. Originals
    /// a schema 5–11 revision embedded are in `inlineImageBytes`; those of a
    /// schema-12 revision are in this package (`assets`, kept as GC roots).
    public func localRevision(id: UUID) throws -> DecodedNotebook {
        if !loaded { _ = try load() }
        let file = id.uuidString + ".json"
        guard let record = ((lastManifest?.revisions ?? []) + checkpoints).first(where: { $0.file == file }) else {
            throw RevisionError.revisionUnavailable
        }
        return try NotebookDecoding.decode(readRevisionBytes(record), storedFile: storedFile(record))
    }

    private func readDocument(_ record: RevisionRecord) throws -> Notebook {
        try NotebookDecoding.decode(readRevisionBytes(record), storedFile: storedFile(record)).notebook
    }

    /// Identity of an immutable revision file whose bytes were just checked
    /// against its record (size, CRC-32): path, size and CRC.
    private func storedFile(_ record: RevisionRecord) -> String {
        "\(revisions.standardizedFileURL.path)/\(record.file)#\(record.byteCount)#\(record.crc32)"
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
        // 1–3 entries: unchanged since Build 46, which falls back on anything else.
        guard manifest.checksumAlgorithm == "crc32-iso-hdlc",
              (1...Self.newestKept).contains(manifest.revisions.count),
              Set(manifest.revisions.map(\.file)).count == manifest.revisions.count,
              manifest.revisions.allSatisfy(validRecord) else {
            throw RevisionError.invalidManifest
        }
    }

    private func validRecord(_ record: RevisionRecord) -> Bool {
        validFilename(record.file) && (1...Self.maximumBytes).contains(record.byteCount)
            && (record.savedAtUnix.map { $0.isFinite && (-62_135_596_800...253_402_300_799).contains($0) } ?? true)
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
