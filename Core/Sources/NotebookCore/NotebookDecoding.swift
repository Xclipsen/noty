import Foundation

/// A stored notebook as decoded, with what the in-memory model no longer holds.
public struct DecodedNotebook: Sendable {
    /// Validated in-memory form; images of schema 5–11 are raised to 12.
    public let notebook: Notebook
    /// The schema of the bytes (≤ 11 although `notebook` may be 12).
    public let storedSchemaVersion: Int
    /// Originals the stored form embedded (schema 5–11), by SHA-256. Empty
    /// for schema 12, whose originals are package assets.
    public let inlineImageBytes: [String: Data]

    public var inlineAssets: InlineImageAssets { InlineImageAssets(bytes: inlineImageBytes) }

    /// External originals the stored form did not embed: what a package or a
    /// format-2 archive has to carry for these bytes. Empty for schema ≤ 11.
    public var storedExternalAssets: [ImageAssetReference] {
        notebook.externalImageAssets.filter { inlineImageBytes[$0.sha256] == nil }
    }
}

/// The only decoder of stored notebook bytes (revisions, prototype files,
/// archives). Checks the schema header before anything else: unknown newer
/// schemas (≥ 13) stay `unsupportedSchema`, never a fallback.
///
/// Schema 5–11 embedded image originals as `data`: each is hashed and kept
/// in `inlineImageBytes`, the object gets its content address. The legacy
/// limits apply to the stored form (≤ 20 MB per original, ≤ 40 MB summed
/// over all objects, duplicates counted). The notebook is validated under its
/// stored schema, then – if it has images – raised to 12 in memory and
/// validated again. Notebooks without images keep their schema. Nothing is
/// written here: the first real change commits schema 12 (RevisionStore keeps
/// the exact old bytes under `Migrations/`).
public enum NotebookDecoding {
    public static func decode(_ data: Data) throws -> DecodedNotebook { try decode(data, storedFile: nil) }

    /// `storedFile`: identity of an immutable stored file (revision path,
    /// size and CRC-32; see `RevisionStore`). The content addresses of its
    /// embedded legacy originals are remembered per identity
    /// (`LegacyDigestCache`), so previews, search and tasks of a not yet
    /// migrated notebook do not hash up to 40 MB on every load. A cached list
    /// that does not fit (count, sizes) is dropped and the file decoded again.
    /// A wrong cached address could never become an asset: `persist`
    /// verifies the SHA-256 of every file it writes.
    static func decode(_ data: Data, storedFile: String?) throws -> DecodedNotebook {
        struct Header: Decodable { var schemaVersion: Int }
        let version = try JSONDecoder().decode(Header.self, from: data).schemaVersion
        guard (1...Notebook.currentSchemaVersion).contains(version) else { throw StorageError.unsupportedSchema(version) }
        let key = version < Notebook.imageAssetSchemaVersion ? storedFile : nil
        if let key, let known = LegacyDigestCache.shared.references(for: key) {
            do { return try decode(data, version: version, known: known) }
            catch { LegacyDigestCache.shared.remove(key) }
        }
        let (decoded, order) = try decodeRecording(data, version: version)
        if let key, !order.isEmpty { LegacyDigestCache.shared.store(order, for: key) }
        return decoded
    }

    private static func decode(_ data: Data, version: Int, known: [ImageAssetReference]) throws -> DecodedNotebook {
        let (decoded, order) = try decodeRecording(data, version: version, known: known)
        guard order.count == known.count else { throw StorageError.invalidDocument }
        return decoded
    }

    private static func decodeRecording(_ data: Data, version: Int, known: [ImageAssetReference]? = nil) throws -> (DecodedNotebook, [ImageAssetReference]) {
        let context = NotebookDecodingContext(storedSchemaVersion: version, known: known)
        let decoder = JSONDecoder()
        decoder.userInfo[NotebookDecodingContext.key] = context
        var notebook = try decoder.decode(Notebook.self, from: data)
        guard notebook.schemaVersion == version else { throw StorageError.invalidDocument }
        if version < Notebook.imageAssetSchemaVersion {
            guard context.embeddedBytes <= ImageLimits.legacyMaximumNotebookBytes else { throw StorageError.invalidDocument }
            try notebook.validate(legacyImages: true)
            if !notebook.allImages.isEmpty {
                notebook.schemaVersion = Notebook.imageAssetSchemaVersion
                try notebook.validate()
            }
        } else {
            try notebook.validate()
        }
        return (DecodedNotebook(notebook: notebook, storedSchemaVersion: version, inlineImageBytes: context.inline), context.order)
    }
}

/// Content addresses of embedded legacy originals per stored file identity,
/// in decoding order (one entry per image object). Process-wide, bounded.
final class LegacyDigestCache: @unchecked Sendable {
    static let shared = LegacyDigestCache()
    static let maximumEntries = 64
    private let lock = NSLock()
    private var entries: [String: [ImageAssetReference]] = [:]
    /// Decodes served from the cache (tests).
    private(set) var hits = 0

    func references(for key: String) -> [ImageAssetReference]? {
        lock.lock(); defer { lock.unlock() }
        let found = entries[key]
        if found != nil { hits += 1 }
        return found
    }

    func store(_ references: [ImageAssetReference], for key: String) {
        lock.lock(); defer { lock.unlock() }
        if entries[key] == nil, entries.count >= Self.maximumEntries { entries.removeAll() }
        entries[key] = references
    }

    func remove(_ key: String) { lock.lock(); entries[key] = nil; lock.unlock() }
    func removeAll() { lock.lock(); entries.removeAll(); hits = 0; lock.unlock() }
}

/// Passed to `ImageObject.init(from:)` through `JSONDecoder.userInfo`; one
/// decode on one thread.
final class NotebookDecodingContext: @unchecked Sendable {
    static let key = CodingUserInfoKey(rawValue: "noty.notebookDecoding")!
    let storedSchemaVersion: Int
    private(set) var inline: [String: Data] = [:]
    /// Embedded bytes over all objects, duplicates counted (legacy rule).
    private(set) var embeddedBytes = 0
    /// The address of every embedded object, in decoding order.
    private(set) var order: [ImageAssetReference] = []
    /// Addresses remembered for the same stored file (`LegacyDigestCache`).
    private let known: [ImageAssetReference]?

    init(storedSchemaVersion: Int, known: [ImageAssetReference]? = nil) {
        self.storedSchemaVersion = storedSchemaVersion; self.known = known
    }

    func embed(_ data: Data) throws -> ImageAssetReference {
        guard (1...ImageLimits.maximumFileBytes).contains(data.count) else { throw StorageError.invalidDocument }
        embeddedBytes += data.count
        guard embeddedBytes <= ImageLimits.legacyMaximumNotebookBytes else { throw StorageError.invalidDocument }
        let reference: ImageAssetReference
        if let known {
            // Same stored file: the address is known; sizes must still fit.
            guard order.count < known.count, known[order.count].byteCount == data.count,
                  inline[known[order.count].sha256].map({ $0.count == data.count }) ?? true else { throw StorageError.invalidDocument }
            reference = known[order.count]
        } else if let same = inline.first(where: { $0.value.count == data.count && $0.value == data }) {
            // Duplicated pages embedded the same bytes again: compare instead of hashing twice.
            reference = ImageAssetReference(sha256: same.key, byteCount: data.count)
        } else {
            reference = ImageAssetReference(of: data)
        }
        if inline[reference.sha256] == nil { inline[reference.sha256] = data }
        order.append(reference)
        return reference
    }
}
