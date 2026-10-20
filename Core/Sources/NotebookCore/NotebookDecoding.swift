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
    public static func decode(_ data: Data) throws -> DecodedNotebook {
        struct Header: Decodable { var schemaVersion: Int }
        let version = try JSONDecoder().decode(Header.self, from: data).schemaVersion
        guard (1...Notebook.currentSchemaVersion).contains(version) else { throw StorageError.unsupportedSchema(version) }
        let context = NotebookDecodingContext(storedSchemaVersion: version)
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
        return DecodedNotebook(notebook: notebook, storedSchemaVersion: version, inlineImageBytes: context.inline)
    }
}

/// Passed to `ImageObject.init(from:)` through `JSONDecoder.userInfo`; one
/// decode on one thread.
final class NotebookDecodingContext: @unchecked Sendable {
    static let key = CodingUserInfoKey(rawValue: "noty.notebookDecoding")!
    let storedSchemaVersion: Int
    private(set) var inline: [String: Data] = [:]
    /// Embedded bytes over all objects, duplicates counted (legacy rule).
    private(set) var embeddedBytes = 0

    init(storedSchemaVersion: Int) { self.storedSchemaVersion = storedSchemaVersion }

    func embed(_ data: Data) throws -> ImageAssetReference {
        guard (1...ImageLimits.maximumFileBytes).contains(data.count) else { throw StorageError.invalidDocument }
        embeddedBytes += data.count
        guard embeddedBytes <= ImageLimits.legacyMaximumNotebookBytes else { throw StorageError.invalidDocument }
        // Duplicated pages embedded the same bytes again: compare instead of hashing twice.
        if let known = inline.first(where: { $0.value.count == data.count && $0.value == data }) {
            return ImageAssetReference(sha256: known.key, byteCount: data.count)
        }
        let reference = ImageAssetReference(of: data)
        inline[reference.sha256] = data
        return reference
    }
}
