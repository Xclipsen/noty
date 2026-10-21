import Foundation

/// Content address of one immutable image original in a notebook package
/// (`Assets/<sha256>`), stored in `ImageObject.asset` since schema 12.
public struct ImageAssetReference: Codable, Hashable, Sendable {
    public let sha256: String
    public let byteCount: Int

    public init(sha256: String, byteCount: Int) { self.sha256 = sha256; self.byteCount = byteCount }

    /// Reference of exactly these bytes (not checked against the limits).
    public init(of data: Data) { self.init(sha256: SHA256.hexDigest(data), byteCount: data.count) }

    /// Hash of 64 lowercase hexadecimal characters and 1 … 20 MB, the limit per
    /// stored original (`ImageLimits.maximumFileBytes`).
    public var isValid: Bool {
        Self.isValidHash(sha256) && (1...ImageLimits.maximumFileBytes).contains(byteCount)
    }

    /// `^[0-9a-f]{64}$`; also the only accepted asset file name.
    public static func isValidHash(_ value: String) -> Bool {
        let utf8 = value.utf8
        return utf8.count == 64 && utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}

/// Where the bytes of one asset can be read: an immutable file in a package
/// (ImageIO reads it directly) or memory (staged, not yet committed).
public enum ImageAssetPayload: Equatable, Sendable {
    case file(URL)
    case data(Data)
}

public protocol ImageAssetProviding: Sendable {
    func payload(for reference: ImageAssetReference) throws -> ImageAssetPayload
    /// Like `payload`, but the bytes are proven to match the reference (backup,
    /// restore, PDF export). Default: `payload`, for providers whose bytes
    /// already define their reference (inline originals).
    func verifiedPayload(for reference: ImageAssetReference) throws -> ImageAssetPayload
}

extension ImageAssetProviding {
    public func verifiedPayload(for reference: ImageAssetReference) throws -> ImageAssetPayload { try payload(for: reference) }
}

/// Originals held in memory, served by content address: the bytes a schema
/// 5–11 notebook embedded (`DecodedNotebook.inlineImageBytes`), or any other
/// set of bytes keyed by their own SHA-256.
public struct InlineImageAssets: ImageAssetProviding {
    private let bytes: [String: Data]

    public init() { bytes = [:] }

    /// Keyed by their own SHA-256 (not checked; build the keys with
    /// `ImageAssetReference(of:)` or take `inlineImageBytes`).
    public init(bytes: [String: Data]) { self.bytes = bytes }

    public var isEmpty: Bool { bytes.isEmpty }

    public var references: [ImageAssetReference] {
        bytes.map { ImageAssetReference(sha256: $0.key, byteCount: $0.value.count) }.sorted { $0.sha256 < $1.sha256 }
    }

    public func payload(for reference: ImageAssetReference) throws -> ImageAssetPayload {
        guard reference.isValid else { throw ImageAssetError.invalidReference }
        guard let data = bytes[reference.sha256], data.count == reference.byteCount else { throw ImageAssetError.missing(reference.sha256) }
        return .data(data)
    }
}

/// The first provider that has the asset, in order. A proven damage is
/// reported before a plain absence.
public struct ChainedImageAssets: ImageAssetProviding {
    public let providers: [ImageAssetProviding]
    public init(_ providers: [ImageAssetProviding]) { self.providers = providers }

    public func payload(for reference: ImageAssetReference) throws -> ImageAssetPayload {
        try first(reference) { try $0.payload(for: reference) }
    }

    public func verifiedPayload(for reference: ImageAssetReference) throws -> ImageAssetPayload {
        try first(reference) { try $0.verifiedPayload(for: reference) }
    }

    private func first(_ reference: ImageAssetReference,
                       _ body: (ImageAssetProviding) throws -> ImageAssetPayload) throws -> ImageAssetPayload {
        var failure: Error = ImageAssetError.missing(reference.sha256)
        for provider in providers {
            do { return try body(provider) } catch {
                if case ImageAssetError.missing = failure { failure = error }
            }
        }
        throw failure
    }
}

extension Notebook {
    /// Images of the active pages, then of the page trash, in page order.
    public var allImages: [ImageObject] {
        (pages + (deletedPages ?? []).map(\.page)).flatMap { $0.images ?? [] }
    }

    /// Image originals referenced by this notebook, unique by hash in order
    /// of first occurrence (active pages, then page trash): exactly the asset
    /// records an archive carries and the files a package must hold for it.
    /// (A notebook decoded from schema 5–11 lists its embedded originals here,
    /// too; `DecodedNotebook.storedExternalAssets` excludes them.)
    public var externalImageAssets: [ImageAssetReference] {
        var seen = Set<String>()
        return allImages.map(\.asset).filter { seen.insert($0.sha256).inserted }
    }
}

public enum ImageAssetError: Error, LocalizedError, Equatable {
    case invalidReference
    case missing(String)
    case damaged(String)
    case pendingFull
    case readOnly
    case invalidDirectory
    case garbageCollectionAborted

    public var errorDescription: String? {
        switch self {
        case .invalidReference: "Ein Bildverweis ist ungültig."
        case .missing: "Ein Bildoriginal fehlt im Heftpaket. Vorhandene Dateien bleiben erhalten."
        case .damaged: "Ein Bildoriginal ist beschädigt (Prüfsumme stimmt nicht). Vorhandene Dateien bleiben erhalten."
        case .pendingFull: "Zu viele neue Bilder warten auf das Speichern. Bitte erst erfolgreich speichern."
        case .readOnly: "Dieses Heft ist nur zum Lesen geöffnet. Es wurde nichts geschrieben."
        case .invalidDirectory: "Der Bildordner des Hefts ist ungültig. Es wurde nichts überschrieben."
        case .garbageCollectionAborted: "Aufräumen der Bildoriginale abgebrochen. Es wurde nichts gelöscht."
        }
    }
}

/// Result of one `collectGarbage` run (file names, sorted). `skipped`: a
/// backup or restore started meanwhile; nothing was deleted.
public struct ImageAssetGarbageReport: Equatable, Sendable {
    public var removedAssets: [String] = []
    public var removedPartials: [String] = []
    public var skipped = false
}

/// Process-wide marker for running library backups, external backups and
/// restores. While any of them runs, no package collects asset garbage: the
/// run is skipped and happens at the next opening or closing. Activities may
/// overlap (counted).
public final class BackupActivity: @unchecked Sendable {
    public static let shared = BackupActivity()

    private let lock = NSLock()
    private var count = 0

    public init() {}

    public var isActive: Bool { lock.lock(); defer { lock.unlock() }; return count > 0 }

    /// Ends with `end()` or when released.
    public func begin() -> Hold {
        lock.lock(); count += 1; lock.unlock()
        return Hold(self)
    }

    public func during<T>(_ body: () throws -> T) rethrows -> T {
        let hold = begin(); defer { hold.end() }
        return try body()
    }

    public func during<T>(_ body: () async throws -> T) async rethrows -> T {
        let hold = begin(); defer { hold.end() }
        return try await body()
    }

    fileprivate func finish() { lock.lock(); count -= 1; lock.unlock() }

    public final class Hold: @unchecked Sendable {
        private let lock = NSLock()
        private var activity: BackupActivity?
        fileprivate init(_ activity: BackupActivity) { self.activity = activity }
        /// Idempotent.
        public func end() {
            lock.lock(); let ending = activity; activity = nil; lock.unlock()
            ending?.finish()
        }
        deinit { end() }
    }
}

/// Content-addressed image originals of exactly one notebook package:
/// `<Paket>/Assets/<sha256>`, immutable, plus an in-memory pending area for
/// imported bytes that no commit has written yet. Only the package's single
/// writer persists or collects; read-only instances (preview, export of a
/// closed notebook) never touch the disk except for reading.
///
/// Write protocol per missing asset: `<sha>.partial-<UUID>` → synchronize →
/// streaming re-read (SHA-256 and size) → rename to `<sha>`. An existing
/// target is never overwritten; only content proven wrong (size differs or
/// SHA-256 mismatch) is replaced, by verified bytes with the same address.
/// Foundation offers no directory fsync; like `.atomic` this is no guarantee
/// against power loss.
///
/// RevisionStore owns the writable instance of its package (assets first,
/// then revision, manifest last); restores, previews and archive writers use
/// further instances.
public final class NotebookAssets: ImageAssetProviding, @unchecked Sendable {
    public static let directoryName = "Assets"
    /// Imported bytes held until the next successful commit (`stage`).
    public static let maximumPendingBytes = 100_000_000
    /// GC deletes unreferenced assets only after this age …
    public static let unreferencedAssetAge: TimeInterval = 15 * 60
    /// … and rests of interrupted writes (`*.partial-<UUID>`) after this one.
    public static let partialFileAge: TimeInterval = 60 * 60
    /// Every regular file below these package directories is a GC root.
    public static let rootDirectoryNames = ["Revisions", "Quarantine", "Migrations", "Archives"]

    /// The `Assets` directory itself.
    public let directory: URL
    public let readOnly: Bool
    /// Lowered by tests only.
    var pendingLimit = NotebookAssets.maximumPendingBytes
    var blockSize = BoundedFile.block
    /// GC reference time; replaceable in tests.
    var clock: () -> Date = { Date() }
    /// Test hook between the write steps (see `PersistStage`).
    var fault: (PersistStage) throws -> Void = { _ in }
    enum PersistStage { case partialWritten, partialVerified }

    private let lock = NSLock()
    private var pending: [String: Data] = [:]
    private var pendingBytes = 0
    /// On-disk assets whose SHA-256 was checked in this session.
    private var verified = Set<String>()
    /// On-disk assets proven wrong in this session (until repaired).
    private var damaged = Set<String>()
    private let fm = FileManager.default

    public init(directory: URL, readOnly: Bool = false) {
        self.directory = directory; self.readOnly = readOnly
    }

    /// `<package>/Assets`.
    public convenience init(package: URL, readOnly: Bool = false) {
        self.init(directory: package.appendingPathComponent(Self.directoryName, isDirectory: true), readOnly: readOnly)
    }

    /// The GC root directories of a package (they need not exist).
    public static func garbageRoots(inPackage package: URL) -> [URL] {
        rootDirectoryNames.map { package.appendingPathComponent($0, isDirectory: true) }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    private func fileURL(_ sha256: String) -> URL { directory.appendingPathComponent(sha256, isDirectory: false) }

    // MARK: Pending

    /// Hashes `data` and keeps it in memory until `dropPending`. Allowed on
    /// read-only instances (legacy inline images of a preview). Bytes already
    /// pending are not counted twice.
    public func stage(_ data: Data) throws -> ImageAssetReference {
        guard (1...ImageLimits.maximumFileBytes).contains(data.count) else { throw ImageAssetError.invalidReference }
        let reference = ImageAssetReference(of: data)
        try addPending(data, reference)
        return reference
    }

    /// Like `stage`, without hashing again: `reference` was derived from
    /// exactly these bytes by `NotebookDecoding` (embedded legacy originals).
    /// Never trusted further: `persist` verifies every written file.
    func stage(_ data: Data, knownAs reference: ImageAssetReference) throws {
        guard reference.isValid, reference.byteCount == data.count else { throw ImageAssetError.invalidReference }
        try addPending(data, reference)
    }

    private func addPending(_ data: Data, _ reference: ImageAssetReference) throws {
        try locked {
            guard pending[reference.sha256] == nil else { return }
            guard data.count <= pendingLimit - pendingBytes else { throw ImageAssetError.pendingFull }
            pending[reference.sha256] = data
            pendingBytes += data.count
        }
    }

    /// Sorted by hash.
    public var pendingReferences: [ImageAssetReference] {
        locked { pending.map { ImageAssetReference(sha256: $0.key, byteCount: $0.value.count) } }
            .sorted { $0.sha256 < $1.sha256 }
    }

    public var pendingByteCount: Int { locked { pendingBytes } }

    /// After a successful commit wrote these assets; the renderer reads files from now on.
    public func dropPending<S: Sequence>(_ references: S) where S.Element == ImageAssetReference {
        locked {
            for reference in references {
                if let data = pending.removeValue(forKey: reference.sha256) { pendingBytes -= data.count }
            }
        }
    }

    /// On disk (stat) or pending in this instance: a commit can write it
    /// without another source.
    public func isAvailable(_ reference: ImageAssetReference) -> Bool {
        pendingData(reference) != nil || presentOnDisk([reference])
    }

    private func pendingData(_ reference: ImageAssetReference) -> Data? {
        locked { pending[reference.sha256].flatMap { $0.count == reference.byteCount ? $0 : nil } }
    }

    // MARK: Reading

    /// File first (stat only: regular, no symlink, size), then pending.
    public func payload(for reference: ImageAssetReference) throws -> ImageAssetPayload {
        guard reference.isValid else { throw ImageAssetError.invalidReference }
        let isDamaged = locked { damaged.contains(reference.sha256) }
        if !isDamaged, onDisk(reference) { return .file(fileURL(reference.sha256)) }
        if let data = pendingData(reference) { return .data(data) }
        throw isDamaged ? ImageAssetError.damaged(reference.sha256) : ImageAssetError.missing(reference.sha256)
    }

    /// Like `payload`, but a file is streamed and its SHA-256 compared once per
    /// session. A mismatch marks the asset damaged (pending bytes, if any, are
    /// returned instead). Read errors are thrown and prove nothing.
    public func verifiedPayload(for reference: ImageAssetReference) throws -> ImageAssetPayload {
        guard reference.isValid else { throw ImageAssetError.invalidReference }
        let (isVerified, isDamaged) = locked { (verified.contains(reference.sha256), damaged.contains(reference.sha256)) }
        if !isDamaged, onDisk(reference) {
            let url = fileURL(reference.sha256)
            if isVerified { return .file(url) }
            if try matches(url, reference) {
                locked { _ = verified.insert(reference.sha256) }
                return .file(url)
            }
            locked { _ = damaged.insert(reference.sha256) }
        }
        if let data = pendingData(reference) { return .data(data) }
        throw (isDamaged || locked { damaged.contains(reference.sha256) })
            ? ImageAssetError.damaged(reference.sha256) : ImageAssetError.missing(reference.sha256)
    }

    /// Every reference is a regular file (no symlink) of the right size in a
    /// real `Assets` directory and not proven damaged. `stat` only, no hashing.
    public func presentOnDisk<S: Sequence>(_ references: S) -> Bool where S.Element == ImageAssetReference {
        missingOnDisk(references).isEmpty
    }

    public func missingOnDisk<S: Sequence>(_ references: S) -> [ImageAssetReference] where S.Element == ImageAssetReference {
        let known = locked { damaged }
        let directoryValid = directoryState() == .directory
        return references.filter { reference in
            !(reference.isValid && directoryValid && !known.contains(reference.sha256) && onDisk(reference))
        }
    }

    private func onDisk(_ reference: ImageAssetReference) -> Bool {
        guard directoryState() == .directory, case .regular(let size) = item(fileURL(reference.sha256)) else { return false }
        return size == reference.byteCount
    }

    // MARK: Writing

    /// Writes every reference not yet on disk (see type documentation). Bytes
    /// come from this instance's pending area, then from `source` (e.g. a
    /// restore staging area or another package). Existing files of the right
    /// size are only checked by `stat`, unless their bytes are pending here:
    /// then their SHA-256 is compared once per session and proven-wrong content
    /// is repaired. Returns the references written or repaired. Throws before
    /// any further write on the first failure; orphans are harmless (GC).
    @discardableResult
    public func persist<S: Sequence>(_ references: S, from source: ImageAssetProviding? = nil) throws -> [ImageAssetReference]
        where S.Element == ImageAssetReference {
        guard !readOnly else { throw ImageAssetError.readOnly }
        var unique: [ImageAssetReference] = [], sizes: [String: Int] = [:]
        for reference in references {
            guard reference.isValid else { throw ImageAssetError.invalidReference }
            if let size = sizes[reference.sha256] {
                guard size == reference.byteCount else { throw ImageAssetError.invalidReference }
                continue
            }
            sizes[reference.sha256] = reference.byteCount
            unique.append(reference)
        }
        guard !unique.isEmpty else { return [] }
        try prepareDirectory()
        var written: [ImageAssetReference] = []
        for reference in unique {
            if try persistOne(reference, from: source) { written.append(reference) }
        }
        return written
    }

    /// True if a file was written.
    private func persistOne(_ reference: ImageAssetReference, from source: ImageAssetProviding?) throws -> Bool {
        let target = fileURL(reference.sha256)
        switch item(target) {
        case .none:
            let partial = try writePartial(reference, from: source)
            do { try fm.moveItem(at: partial, to: target) } catch {
                // Never overwritten: a target that appeared meanwhile must fit.
                try? fm.removeItem(at: partial)
                guard case .regular(let size) = item(target), size == reference.byteCount else { throw error }
                return false
            }
            locked { _ = verified.insert(reference.sha256) }
            return true
        case .other:
            throw ImageAssetError.invalidDirectory
        case .regular(let size):
            let (isVerified, isDamaged) = locked { (verified.contains(reference.sha256), damaged.contains(reference.sha256)) }
            if size == reference.byteCount, !isDamaged {
                // Only stat without own bytes: nothing would prove the content wrong.
                guard !isVerified, pendingData(reference) != nil else { return false }
                if try matches(target, reference) { locked { _ = verified.insert(reference.sha256) }; return false }
                locked { _ = damaged.insert(reference.sha256) }
            }
            // Proven wrong (size or SHA-256): replace with verified bytes of this address.
            guard source != nil || pendingData(reference) != nil else { throw ImageAssetError.damaged(reference.sha256) }
            let partial = try writePartial(reference, from: source)
            do { _ = try fm.replaceItemAt(target, withItemAt: partial) } catch {
                try? fm.removeItem(at: partial)
                throw error
            }
            locked { damaged.remove(reference.sha256); _ = verified.insert(reference.sha256) }
            return true
        }
    }

    /// A synchronized, re-read and verified `<sha>.partial-<UUID>`; removed on failure.
    private func writePartial(_ reference: ImageAssetReference, from source: ImageAssetProviding?) throws -> URL {
        let payload: ImageAssetPayload
        if let data = pendingData(reference) { payload = .data(data) }
        else if let source { payload = try source.payload(for: reference) }
        else { throw ImageAssetError.missing(reference.sha256) }
        let partial = directory.appendingPathComponent("\(reference.sha256).partial-\(UUID().uuidString)", isDirectory: false)
        if case .file(let url) = payload {
            // Another package or a restore stage: `copyItem` clones on APFS
            // (no extra space); the copy is verified below like written bytes.
            try BoundedFile.requireRegularFile(url)
            do { try fm.copyItem(at: url, to: partial) } catch { try? fm.removeItem(at: partial); throw error }
        } else {
            try Data().write(to: partial, options: .withoutOverwriting)
        }
        do {
            let output = try FileHandle(forWritingTo: partial)
            do {
                if case .data(let data) = payload {
                    guard data.count == reference.byteCount else { throw ImageAssetError.damaged(reference.sha256) }
                    var offset = data.startIndex
                    while offset < data.endIndex {
                        let end = data.index(offset, offsetBy: min(blockSize, data.endIndex - offset))
                        try output.write(contentsOf: data[offset..<end]); offset = end
                    }
                }
                try output.synchronize()
                try output.close()
            } catch { try? output.close(); throw error }
            try fault(.partialWritten)
            guard try matches(partial, reference) else { throw ImageAssetError.damaged(reference.sha256) }
            try fault(.partialVerified)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        return partial
    }

    private func prepareDirectory() throws {
        if directoryState() == .missing { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
        guard directoryState() == .directory else { throw ImageAssetError.invalidDirectory }
    }

    // MARK: Garbage collection primitives

    /// Deletes, never during an editor session (`RevisionStore.collectAssetGarbage`
    /// decides when):
    /// - `^[0-9a-f]{64}$`, regular file, no symlink, not referenced and older
    ///   than `unreferencedAssetAge`;
    /// - `<sha>.partial-<UUID>` older than `partialFileAge`.
    /// References are `keeping`, the pending area and every quoted 64-hex
    /// string in any regular file below `roots` (`referencedHashes`). Foreign
    /// names, directories and symlinks stay. Any read error in the roots or the
    /// listing aborts the run before anything is deleted; single deletions are
    /// best effort. Age is measured from the newest file time available.
    /// `isBlocked` is asked before and again right before the first deletion
    /// (a backup may have started during the search): then nothing is deleted
    /// and the report says `skipped`.
    @discardableResult
    public func collectGarbage(roots: [URL], keeping: Set<String> = [],
                               isBlocked: () -> Bool = { false }) throws -> ImageAssetGarbageReport {
        guard !readOnly else { throw ImageAssetError.readOnly }
        guard !isBlocked() else { return ImageAssetGarbageReport(skipped: true) }
        switch directoryState() {
        case .missing: return ImageAssetGarbageReport()
        case .invalid: throw ImageAssetError.invalidDirectory
        case .directory: break
        }
        var referenced: Set<String>
        let names: [String]
        do {
            referenced = try Self.referencedHashes(in: roots, blockSize: blockSize)
            names = try fm.contentsOfDirectory(atPath: directory.path)
        } catch { throw ImageAssetError.garbageCollectionAborted }
        referenced.formUnion(keeping)
        referenced.formUnion(locked { pending.keys })
        guard !isBlocked() else { return ImageAssetGarbageReport(skipped: true) }
        let now = clock()
        var report = ImageAssetGarbageReport()
        for name in names.sorted() {
            let isAsset = ImageAssetReference.isValidHash(name)
            guard isAsset ? !referenced.contains(name) : Self.isPartialName(name) else { continue }
            let url = directory.appendingPathComponent(name, isDirectory: false)
            guard case .regular = item(url), let changed = newestFileTime(url),
                  now.timeIntervalSince(changed) >= (isAsset ? Self.unreferencedAssetAge : Self.partialFileAge),
                  (try? fm.removeItem(at: url)) != nil else { continue }
            if isAsset {
                report.removedAssets.append(name)
                locked { verified.remove(name); damaged.remove(name) }
            } else { report.removedPartials.append(name) }
        }
        return report
    }

    /// `<64 hex>.partial-<UUID in upper case>`, exactly as written here.
    static func isPartialName(_ name: String) -> Bool {
        let marker = ".partial-"
        guard name.utf8.count == 64 + marker.utf8.count + 36 else { return false }
        let hash = String(name.prefix(64)), rest = name.dropFirst(64)
        guard ImageAssetReference.isValidHash(hash), rest.hasPrefix(marker) else { return false }
        let id = String(rest.dropFirst(marker.count))
        return UUID(uuidString: id)?.uuidString == id
    }

    /// Raw byte search for `"<64 lowercase hex>"` in every regular file below
    /// `roots` (recursively; symlinks and special files are not followed).
    /// Over-cautious by design: works on damaged JSON, unknown newer schemas and
    /// any whitespace; base64 contains no quote, so false hits only keep
    /// garbage. Encoders must not escape hex strings (JSONEncoder and Python
    /// do not). A missing root is empty; a root that is no real directory, any
    /// listing or read error throws.
    public static func referencedHashes(in roots: [URL]) throws -> Set<String> {
        try referencedHashes(in: roots, blockSize: BoundedFile.block)
    }

    static func referencedHashes(in roots: [URL], blockSize: Int) throws -> Set<String> {
        let fm = FileManager.default
        var found = Set<String>()
        func scanDirectory(_ url: URL, depth: Int) throws {
            guard depth < 64 else { throw ImageAssetError.garbageCollectionAborted }
            for name in try fm.contentsOfDirectory(atPath: url.path) {
                let child = url.appendingPathComponent(name)
                let attributes = try fm.attributesOfItem(atPath: child.path)
                switch attributes[.type] as? FileAttributeType {
                case .typeRegular?: try scanFile(child, blockSize: blockSize, into: &found)
                case .typeDirectory?: try scanDirectory(child, depth: depth + 1)
                default: continue
                }
            }
        }
        for root in roots {
            // attributesOfItem does not follow a final symlink (also a dangling one).
            guard let attributes = try? fm.attributesOfItem(atPath: root.path) else {
                // Missing is empty; anything else unreadable aborts.
                guard !fm.fileExists(atPath: root.path) else { throw ImageAssetError.garbageCollectionAborted }
                continue
            }
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw ImageAssetError.garbageCollectionAborted }
            try scanDirectory(root, depth: 0)
        }
        return found
    }

    private static func scanFile(_ url: URL, blockSize: Int, into found: inout Set<String>) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var scanner = QuotedHashScanner()
        while let chunk = try handle.read(upToCount: blockSize), !chunk.isEmpty { scanner.feed(chunk, into: &found) }
    }

    // MARK: Files

    private enum DirectoryState { case missing, directory, invalid }

    /// The `Assets` directory must be a real directory, never a symlink.
    private func directoryState() -> DirectoryState {
        guard let attributes = try? fm.attributesOfItem(atPath: directory.path) else {
            return fm.fileExists(atPath: directory.path) ? .invalid : .missing
        }
        return attributes[.type] as? FileAttributeType == .typeDirectory ? .directory : .invalid
    }

    private enum Item { case none, regular(Int), other }

    /// Does not follow a final symlink.
    private func item(_ url: URL) -> Item {
        guard let attributes = try? fm.attributesOfItem(atPath: url.path) else {
            return fm.fileExists(atPath: url.path) ? .other : .none
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue else { return .other }
        return .regular(size)
    }

    private func newestFileTime(_ url: URL) -> Date? {
        let fresh = URL(fileURLWithPath: url.path)
        let values = try? fresh.resourceValues(forKeys: [.contentModificationDateKey, .attributeModificationDateKey, .creationDateKey])
        return [values?.contentModificationDate, values?.attributeModificationDate, values?.creationDate].compactMap { $0 }.max()
    }

    /// Streaming SHA-256 and size; reads at most `byteCount + 1` bytes.
    private func matches(_ url: URL, _ reference: ImageAssetReference) throws -> Bool {
        let result = try Self.digest(ofFile: url, limit: reference.byteCount, blockSize: blockSize)
        return result.byteCount == reference.byteCount && result.sha256 == reference.sha256
    }

    /// SHA-256 and byte count of a file, streamed in blocks; stops once more
    /// than `limit` bytes were read (the count then exceeds `limit`).
    static func digest(ofFile url: URL, limit: Int, blockSize: Int = BoundedFile.block) throws -> (sha256: String, byteCount: Int) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256Stream(), count = 0
        while count <= limit, let chunk = try handle.read(upToCount: min(blockSize, limit + 1 - count)), !chunk.isEmpty {
            hasher.update(chunk); count += chunk.count
        }
        return (hasher.finalizeHex(), count)
    }
}

/// Finds `"` + 64 lowercase hex + `"` in a byte stream fed in arbitrary pieces.
/// Outside a candidate it jumps to the next quote with `memchr`, so long
/// base64 strings (embedded PDFs) cost little even in debug builds.
struct QuotedHashScanner {
    private var candidate = false
    private var run = 0
    private var digits = [UInt8](repeating: 0, count: 64)

    mutating func feed(_ data: Data, into found: inout Set<String>) {
        data.withUnsafeBytes { raw in
            guard let start = raw.baseAddress, raw.count > 0 else { return }
            let bytes = start.assumingMemoryBound(to: UInt8.self)
            let count = raw.count
            var index = 0
            while index < count {
                if !candidate {
                    guard let quote = memchr(start + index, 0x22, count - index) else { return }
                    index = UnsafeRawPointer(quote) - start
                }
                let byte = bytes[index]
                index += 1
                if byte == 0x22 {
                    if candidate, run == 64 { found.insert(String(decoding: digits, as: UTF8.self)) }
                    candidate = true; run = 0
                } else if (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte) {
                    if run < 64 { digits[run] = byte; run += 1 } else { candidate = false }
                } else {
                    candidate = false
                }
            }
        }
    }
}
