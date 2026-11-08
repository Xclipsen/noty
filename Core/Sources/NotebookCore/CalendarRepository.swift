import Foundation

// Kalender Stufe B1: storage of one area's calendar in `<Bereich>/Calendar/`.
//
//   Calendar/manifest.json            commit point (RevisionManifest, format 1, 1–3 entries)
//   Calendar/manifest-previous.json   previous manifest (fallback)
//   Calendar/Revisions/<UUID>.json    immutable complete CalendarState revisions
//   Calendar/Quarantine/              damaged manifest moved aside before replacing it
//   Calendar/Migration/               exact bytes of an older-format revision, archived
//                                     before the first commit in the new format (B2)
//   Calendar/Cache/<UUID>.json        replaceable source snapshot per connection
//
// The confirmed state (own events, settings, connection record) follows the
// notebook revision rules (`RevisionStore`): full immutable revisions, read
// back before they are referenced, previous manifest written, manifest
// replaced last; an older state is never committed over a newer one; a
// manifest changed by another writer refuses the commit; an unknown newer
// format or a package without any readable revision locks writing instead of
// starting empty. The cache is separate and may be dropped at any time.

public struct CalendarLoad: Sendable, Equatable {
    public let state: CalendarState
    /// Loaded from an older revision/previous manifest (newer one unreadable).
    public let recovered: Bool
}

/// Single-owner store of `Calendar/` (wrapped by `CalendarRepository`).
final class CalendarStore {
    let directory: URL
    var clock: () -> Date = { Date() }
    enum CommitStage { case migrationArchive, revisionWritten, previousWritten }
    /// Test hook after each commit step (injected failures, crash images).
    var commitFault: (CommitStage) throws -> Void = { _ in }
    private(set) var recovered = false
    private(set) var current: CalendarState?
    private var loaded = false
    private var lastManifest: RevisionManifest?
    private var observedPrimary: Data?
    private var damagedPrimary = false
    /// Exact bytes and stored format of the revision `current` came from.
    /// An older format is archived (`Migration/`) before the first commit
    /// that would rewrite it in the current format; a failed archive refuses
    /// the commit.
    private var loadedBytes: Data?
    private var loadedFile: String?
    private(set) var loadedFormat: Int?
    /// Revision files of the acknowledged chain this store loaded or wrote.
    /// Only these are ever deleted; skipped (possibly newer) files stay.
    private var known = Set<String>()
    private let fm = FileManager.default
    static let maximumBytes = 64_000_000
    private var primary: URL { directory.appendingPathComponent("manifest.json") }
    private var previous: URL { directory.appendingPathComponent("manifest-previous.json") }
    private var revisions: URL { directory.appendingPathComponent("Revisions", isDirectory: true) }
    private var quarantine: URL { directory.appendingPathComponent("Quarantine", isDirectory: true) }
    private var migration: URL { directory.appendingPathComponent("Migration", isDirectory: true) }

    init(directory: URL) { self.directory = directory }

    /// Newest readable revision. Throws (and stays unloaded, so every save is
    /// refused) on an unknown newer format, or when the package exists but no
    /// revision can be verified. A missing package is an empty calendar.
    func load() throws -> CalendarState {
        let fingerprint = primaryFingerprint()
        for manifestURL in [primary, previous] where itemExists(manifestURL) {
            let manifest: RevisionManifest
            do { manifest = try readManifest(manifestURL) }
            catch RevisionError.unsupportedFormat(let version) { throw CalendarStoreError.unsupportedFormat(version) }
            catch { continue }
            for (offset, record) in manifest.revisions.enumerated() {
                do {
                    let (state, bytes, format) = try decodeRevision(record)
                    loadedBytes = bytes; loadedFile = record.file; loadedFormat = format
                    var chain = Set(manifest.revisions.dropFirst(offset).map(\.file))
                    if manifestURL == primary, let older = try? readManifest(previous) { chain.formUnion(older.revisions.map(\.file)) }
                    known = chain
                    lastManifest = RevisionManifest(revisions: Array(manifest.revisions.dropFirst(offset)))
                    current = state
                    recovered = manifestURL != primary || offset > 0
                    damagedPrimary = manifestURL != primary
                    observedPrimary = fingerprint
                    loaded = true
                    return state
                } catch CalendarStoreError.unsupportedFormat(let version) {
                    throw CalendarStoreError.unsupportedFormat(version)
                } catch { continue }
            }
        }
        // Once anything exists, never silently start with an empty calendar.
        let hasRevisions = !(((try? fm.contentsOfDirectory(atPath: revisions.path)) ?? []).isEmpty)
        guard !itemExists(primary), !itemExists(previous), !hasRevisions else { throw CalendarStoreError.noCompleteRevision }
        known = []
        lastManifest = nil
        loadedBytes = nil; loadedFile = nil; loadedFormat = nil
        current = CalendarState()
        recovered = false
        damagedPrimary = false
        observedPrimary = fingerprint
        loaded = true
        return current!
    }

    /// Commits `state` as a new revision; on any failure the committed state
    /// on disk and in `current` stays exactly as before.
    func save(_ state: CalendarState) throws {
        try state.validate()
        if !loaded { _ = try load() }
        if lastManifest != nil, !recovered, current == state, itemExists(primary) { return }
        try requireUnchangedPrimary()
        let bytes = try Self.encoder.encode(state)
        guard bytes.count <= Self.maximumBytes else { throw CalendarStoreError.invalidState }
        guard try Self.decode(bytes) == state else { throw CalendarStoreError.invalidState }
        // Before anything of the new format is written: the old bytes stay.
        try archiveOlderFormat()
        try fm.createDirectory(at: revisions, withIntermediateDirectories: true)
        try requireRealDirectory(revisions)
        let old = lastManifest
        var written: [String] = []
        let manifest: RevisionManifest
        var manifestBytes = Data()
        do {
            let record = try writeRevision(bytes)
            written.append(record.file)
            try commitFault(.revisionWritten)
            try requireUnchangedPrimary()
            manifest = RevisionManifest(revisions: [record] + Array((old?.revisions ?? []).prefix(2)))
            if let old { try Self.encoder.encode(old).write(to: previous, options: .atomic) }
            try commitFault(.previousWritten)
            try requireUnchangedPrimary()
            if damagedPrimary { preserveDamagedPrimary() }
            // Commit point: nothing may report „gespeichert“ before this.
            manifestBytes = try Self.encoder.encode(manifest)
            try manifestBytes.write(to: primary, options: .atomic)
        } catch {
            for file in written { if (try? fm.removeItem(at: revisions.appendingPathComponent(file))) != nil { known.remove(file) } }
            throw error
        }
        lastManifest = manifest
        observedPrimary = manifestBytes
        loadedBytes = bytes; loadedFile = manifest.revisions.first?.file; loadedFormat = state.formatVersion
        current = state
        recovered = false
        damagedPrimary = false
        let referenced = Set((manifest.revisions + (old?.revisions ?? [])).map(\.file))
        known.formUnion(referenced)
        // Dropped acknowledged states only; unknown files are never touched.
        for file in known.subtracting(referenced) {
            if (try? fm.removeItem(at: revisions.appendingPathComponent(file))) != nil { known.remove(file) }
        }
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// Header first: a newer format is reported as such, never parsed further.
    static func decode(_ bytes: Data) throws -> CalendarState { try decodeStored(bytes).state }

    /// The state in the current format and the format it was stored in. An
    /// older (migratable) format is read with the defaults of the new fields
    /// (format 1 → 2: no series, links, mappings, colours or notes folder;
    /// 2 → 3: no reminders, lesson reminder setting or deleted events;
    /// 3 → 4: no system calendars, system event notes or homework marks).
    static func decodeStored(_ bytes: Data) throws -> (state: CalendarState, format: Int) {
        struct Header: Decodable { var formatVersion: Int }
        let version = try JSONDecoder().decode(Header.self, from: bytes).formatVersion
        if version > CalendarState.currentFormat { throw CalendarStoreError.unsupportedFormat(version) }
        guard version == CalendarState.currentFormat || CalendarState.migratableFormats.contains(version) else {
            throw CalendarStoreError.invalidState
        }
        var state = try JSONDecoder().decode(CalendarState.self, from: bytes)
        if version < 4 {
            // Format 1–3 know no system calendars, notes of system events or homework marks.
            guard state.homeworkDone.isEmpty, state.settings.systemCalendars == nil,
                  !state.noteLinks.contains(where: { $0.target.isSystem }) else { throw CalendarStoreError.invalidState }
        }
        if version < 3 {
            // Format 1/2 know none of the B3 fields; anything else is not that format.
            guard state.deletedEvents.isEmpty, state.settings.lessonReminderMinutes == nil,
                  state.events.allSatisfy({ $0.reminderMinutes == nil }) else { throw CalendarStoreError.invalidState }
        }
        if version < 2 {
            // Format 1 knows none of the B2 fields either.
            guard state.noteLinks.isEmpty, state.lessonMappings.isEmpty, state.settings.subjectColors.isEmpty,
                  state.settings.notesFolderID == nil, state.connection?.sourceIdentity == nil,
                  state.events.allSatisfy({ $0.recurrence == nil }) else { throw CalendarStoreError.invalidState }
        }
        state.formatVersion = CalendarState.currentFormat
        try state.validate()
        return (state, version)
    }

    private func decodeRevision(_ record: RevisionRecord) throws -> (CalendarState, Data, Int) {
        let bytes = try readRegularFile(revisions.appendingPathComponent(record.file), limit: record.byteCount)
        guard bytes.count == record.byteCount, SnapshotChecksum.crc32(bytes) == record.crc32 else {
            throw CalendarStoreError.noCompleteRevision
        }
        let decoded = try Self.decodeStored(bytes)
        return (decoded.state, bytes, decoded.format)
    }

    /// Copies the exact bytes of an older-format revision into `Migration/`
    /// and reads them back. Idempotent; a failure refuses the commit.
    private func archiveOlderFormat() throws {
        guard let format = loadedFormat, format < CalendarState.currentFormat, let bytes = loadedBytes, let file = loadedFile else { return }
        try fm.createDirectory(at: migration, withIntermediateDirectories: true)
        try requireRealDirectory(migration)
        var url = migration.appendingPathComponent("format-\(format)-\(file)")
        if itemExists(url) {
            if (try? readRegularFile(url, limit: bytes.count)) == bytes { return }
            url = migration.appendingPathComponent("format-\(format)-\(UUID().uuidString)-\(file)")
        }
        try commitFault(.migrationArchive)
        try bytes.write(to: url, options: .atomic)
        guard try readRegularFile(url, limit: bytes.count) == bytes else { throw CalendarStoreError.invalidState }
    }

    private func writeRevision(_ bytes: Data) throws -> RevisionRecord {
        let record = RevisionRecord(file: UUID().uuidString + ".json", byteCount: bytes.count,
                                    crc32: SnapshotChecksum.crc32(bytes), savedAtUnix: clock().timeIntervalSince1970)
        let url = revisions.appendingPathComponent(record.file)
        guard !itemExists(url) else { throw CalendarStoreError.invalidState }
        try bytes.write(to: url, options: .atomic)
        known.insert(record.file)
        let staged = try readRegularFile(url, limit: record.byteCount)
        guard staged == bytes else {
            if (try? fm.removeItem(at: url)) != nil { known.remove(record.file) }
            throw CalendarStoreError.noCompleteRevision
        }
        return record
    }

    private func readManifest(_ url: URL) throws -> RevisionManifest {
        let bytes = try readRegularFile(url, limit: 128_000)
        struct Header: Decodable { var formatVersion: Int }
        let version = try JSONDecoder().decode(Header.self, from: bytes).formatVersion
        guard version == 1 else { throw RevisionError.unsupportedFormat(version) }
        let manifest = try JSONDecoder().decode(RevisionManifest.self, from: bytes)
        guard manifest.checksumAlgorithm == "crc32-iso-hdlc", (1...3).contains(manifest.revisions.count),
              Set(manifest.revisions.map(\.file)).count == manifest.revisions.count,
              manifest.revisions.allSatisfy({ validFilename($0.file) && (1...Self.maximumBytes).contains($0.byteCount) }) else {
            throw RevisionError.invalidManifest
        }
        return manifest
    }

    private func validFilename(_ file: String) -> Bool {
        guard file.hasSuffix(".json"), let id = UUID(uuidString: String(file.dropLast(5))) else { return false }
        return id.uuidString + ".json" == file
    }

    private func itemExists(_ url: URL) -> Bool { (try? fm.attributesOfItem(atPath: url.path)) != nil }

    private func requireRealDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw CalendarStoreError.invalidState }
    }

    private func readRegularFile(_ url: URL, limit: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, (1...limit).contains(size) else {
            throw CalendarStoreError.invalidState
        }
        return try Data(contentsOf: url)
    }

    private func primaryFingerprint() -> Data? {
        guard let attributes = try? fm.attributesOfItem(atPath: primary.path) else { return nil }
        if attributes[.type] as? FileAttributeType == .typeRegular,
           let size = (attributes[.size] as? NSNumber)?.intValue, size <= 1_000_000,
           let data = try? Data(contentsOf: primary) { return data }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? -1
        let date = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return Data("other:\(size):\(date)".utf8)
    }

    /// A usable manifest that differs from the one this store last saw is
    /// another writer's commit: refuse instead of overwriting it.
    private func requireUnchangedPrimary() throws {
        guard primaryFingerprint() != observedPrimary else { return }
        do { _ = try readManifest(primary) }
        catch RevisionError.unsupportedFormat { throw CalendarStoreError.concurrentChange }
        catch { return }
        throw CalendarStoreError.concurrentChange
    }

    /// The damaged manifest may be the only pointer to newer revisions:
    /// moved aside (best effort) before the new manifest replaces it.
    private func preserveDamagedPrimary() {
        damagedPrimary = false
        guard itemExists(primary), (try? fm.createDirectory(at: quarantine, withIntermediateDirectories: true)) != nil,
              (try? requireRealDirectory(quarantine)) != nil else { return }
        let stamp = Int(max(0, clock().timeIntervalSince1970))
        try? fm.moveItem(at: primary, to: quarantine.appendingPathComponent("manifest-\(stamp)-\(UUID().uuidString).json"))
    }
}

/// Serial owner of one area's `Calendar/` package. Holds the process-wide
/// write claim (`PackageWriteLock`) from the first load until `close()`.
public actor CalendarRepository {
    public nonisolated let directory: URL
    private let store: CalendarStore
    private var claim: PackageWriteLock.Claim?
    private var savedRevision = Int.min
    private var snapshot: CalendarSourceSnapshot?
    private var cacheLockedVersion: Int?
    private let fm = FileManager.default
    private let claimWait: Double

    /// `areaRoot`: the active area's data root (the library root).
    /// `claimWait`: how long a second owner waits for the write claim.
    public init(areaRoot: URL, claimWait: Double = 3) {
        directory = areaRoot.appendingPathComponent("Calendar", isDirectory: true)
        store = CalendarStore(directory: directory)
        self.claimWait = claimWait
    }

    /// Test hooks.
    func setFault(_ fault: @escaping (CalendarStore.CommitStage) throws -> Void) { store.commitFault = fault }

    /// One acquisition at a time: concurrent callers wait for the same one
    /// (never a second claim attempt that the first one blocks).
    private var claiming: Task<PackageWriteLock.Claim?, Never>?
    /// Bumped by `close()`: a claim that arrives after closing is let go.
    private var closings = 0

    private func requireClaim() async throws {
        if let claim, !claim.isReleased { return }
        let attempt: Task<PackageWriteLock.Claim?, Never>
        if let claiming {
            attempt = claiming
        } else {
            let directory = directory, wait = claimWait
            attempt = Task { await PackageWriteLock.shared.claim(directory, waitingUpTo: wait) }
            claiming = attempt
        }
        let closed = closings
        let result = await attempt.value
        if claiming == attempt { claiming = nil }
        // Another waiter of the same attempt may have stored it already.
        if let claim, !claim.isReleased { return }
        guard let result, !result.isReleased, closed == closings else {
            if closed != closings { result?.release() }
            throw CalendarStoreError.busy
        }
        claim = result
    }

    public func load() async throws -> CalendarLoad {
        try await requireClaim()
        let state = try store.load()
        return CalendarLoad(state: state, recovered: store.recovered)
    }

    /// Commits `state` unless a newer `revision` was already committed (an
    /// older queued autosave never replaces a newer one). True: committed or
    /// already current; false: skipped as older.
    @discardableResult
    public func save(_ state: CalendarState, revision: Int) async throws -> Bool {
        guard revision >= savedRevision else { return false }
        try await requireClaim()
        // Waiting for the claim is a suspension point: a newer save may have
        // committed meanwhile and must not be replaced by this older one.
        guard revision >= savedRevision else { return false }
        try store.save(state)
        savedRevision = revision
        return true
    }

    /// Releases the write claim (area switch, model gone).
    public func close() {
        closings += 1
        claiming = nil
        claim?.release()
        claim = nil
    }

    // MARK: Source cache (replaceable)

    private var cacheDirectory: URL { directory.appendingPathComponent("Cache", isDirectory: true) }
    private func cacheURL(_ connection: UUID) -> URL { cacheDirectory.appendingPathComponent("\(connection.uuidString).json") }

    /// Cached snapshot of the committed state's connection. A missing or
    /// damaged cache is an empty one (nothing loaded yet); a newer cache
    /// format is left alone and writing it stays locked (`unsupportedFormat`).
    public func sourceSnapshot() throws -> CalendarSourceSnapshot? {
        guard let connection = store.current?.connection?.id else { return nil }
        if let snapshot, snapshot.connection == connection { return snapshot }
        cacheLockedVersion = nil
        let url = cacheURL(connection)
        var loaded = CalendarSourceSnapshot(connection: connection)
        if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
           values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= 256_000_000,
           let bytes = try? Data(contentsOf: url) {
            do {
                let decoded = try JSONDecoder().decode(CalendarSourceSnapshot.self, from: bytes)
                try decoded.validate()
                if decoded.connection == connection { loaded = decoded }
            } catch CalendarStoreError.unsupportedFormat(let version) {
                cacheLockedVersion = version
                snapshot = loaded
                throw CalendarStoreError.unsupportedFormat(version)
            } catch {}
        }
        snapshot = loaded
        return loaded
    }

    /// Merges one complete fetch (per-day newer-wins) and writes the cache.
    /// A fetch for another connection than the committed one is discarded.
    /// A failed write keeps the previous cache on disk and in memory.
    public func merge(_ fetch: CalendarTimetableFetch) throws -> CalendarSourceSnapshot {
        guard store.current?.connection?.id == fetch.connection else { throw CalendarStoreError.staleConnection }
        var next = (try? sourceSnapshot()) ?? CalendarSourceSnapshot(connection: fetch.connection)
        try next.merge(fetch)
        try writeCache(next)
        return next
    }

    public func replaceHolidays(_ holidays: [CalendarHoliday], fetchedAt: Date, connection: UUID) throws -> CalendarSourceSnapshot {
        guard store.current?.connection?.id == connection else { throw CalendarStoreError.staleConnection }
        var next = (try? sourceSnapshot()) ?? CalendarSourceSnapshot(connection: connection)
        next.replaceHolidays(holidays, fetchedAt: fetchedAt)
        try writeCache(next)
        return next
    }

    private func writeCache(_ next: CalendarSourceSnapshot) throws {
        if let version = cacheLockedVersion { throw CalendarStoreError.unsupportedFormat(version) }
        try next.validate()
        try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let bytes = try CalendarStore.encoder.encode(next)
        let url = cacheURL(next.connection)
        try bytes.write(to: url, options: .atomic)
        snapshot = next
    }

    /// Drops the cache of `connection` (disconnect). Notes and own events
    /// are not touched. Only the UUID-named file inside `Cache/` is removed.
    public func removeSourceCache(connection: UUID) throws {
        if snapshot?.connection == connection { snapshot = nil }
        cacheLockedVersion = nil
        let url = cacheURL(connection)
        if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { try fm.removeItem(at: url) }
    }
}
