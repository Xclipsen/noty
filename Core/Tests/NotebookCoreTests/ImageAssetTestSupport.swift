import Foundation
@testable import NotebookCore

extension ImageAssetReference {
    /// A valid reference without bytes: Core never decodes images, so limit and
    /// consistency rules can be tested with declared sizes (`seed` picks the hash).
    static func declared(_ byteCount: Int, seed: Int = 0) -> ImageAssetReference {
        ImageAssetReference(sha256: SHA256.hexDigest(Data("declared-\(seed)".utf8)), byteCount: byteCount)
    }
}

extension ImageObject {
    /// An image object referencing exactly these bytes (schema 12).
    static func test(bytes: Data, id: UUID = UUID(), pixelWidth: Int = 8, pixelHeight: Int = 6,
                     x: Double = 40, y: Double = 40, width: Double = 240, height: Double = 180,
                     rotation: Double = 0, locked: Bool = false) -> ImageObject {
        ImageObject(id: id, asset: ImageAssetReference(of: bytes), pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                    x: x, y: y, width: width, height: height, rotation: rotation, locked: locked)
    }
}

/// The stored form of schema 5–11 as Build 53 wrote it: `data` (Base64)
/// instead of `asset`. Only tests write it; the app has no path back.
enum LegacyNotebookJSON {
    /// `notebook` re-encoded with `schemaVersion` and every image's original
    /// embedded from `originals` (by SHA-256).
    static func encode(_ notebook: Notebook, schemaVersion: Int, originals: [String: Data]) throws -> Data {
        var object = try XCTUnwrapJSON(JSONSerialization.jsonObject(with: JSONEncoder().encode(notebook)))
        object["schemaVersion"] = schemaVersion
        func embed(_ page: inout [String: Any]) throws {
            guard var images = page["images"] as? [[String: Any]] else { return }
            for index in images.indices {
                let asset = try XCTUnwrapJSON(images[index].removeValue(forKey: "asset"))
                guard let hash = asset["sha256"] as? String, originals[hash] != nil else { throw StorageError.invalidDocument }
                // Spliced in after serializing: JSONSerialization writes megabytes slowly.
                images[index]["data"] = "@@legacy-\(hash)@@"
            }
            page["images"] = images
        }
        if var pages = object["pages"] as? [[String: Any]] {
            for index in pages.indices { try embed(&pages[index]) }
            object["pages"] = pages
        }
        if var deleted = object["deletedPages"] as? [[String: Any]] {
            for index in deleted.indices {
                var page = try XCTUnwrapJSON(deleted[index]["page"])
                try embed(&page)
                deleted[index]["page"] = page
            }
            object["deletedPages"] = deleted
        }
        var json = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        for (hash, bytes) in originals { json = json.replacingOccurrences(of: "@@legacy-\(hash)@@", with: bytes.base64EncodedString()) }
        return Data(json.utf8)
    }

    /// A package exactly as Build 53 committed it: one revision with these
    /// bytes and a Build-46 manifest (replaces an existing one).
    static func writePackage(_ root: URL, bytes: Data) throws {
        let revisions = root.appendingPathComponent("Revisions", isDirectory: true)
        try? FileManager.default.removeItem(at: revisions)
        try? FileManager.default.removeItem(at: root.appendingPathComponent("manifest-previous.json"))
        try FileManager.default.createDirectory(at: revisions, withIntermediateDirectories: true)
        let record = RevisionRecord(file: UUID().uuidString + ".json", byteCount: bytes.count,
                                    crc32: SnapshotChecksum.crc32(bytes), savedAtUnix: 1_800_000_000)
        try bytes.write(to: revisions.appendingPathComponent(record.file))
        try JSONEncoder().encode(RevisionManifest(revisions: [record])).write(to: root.appendingPathComponent("manifest.json"))
    }

    /// Every file below `root` with its bytes (directories empty).
    static func inventory(_ root: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for case let url as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)! {
            let regular = try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            result[String(url.path.dropFirst(root.path.count))] = regular ? try Data(contentsOf: url) : Data()
        }
        return result
    }

    private static func XCTUnwrapJSON(_ value: Any?) throws -> [String: Any] {
        guard let value = value as? [String: Any] else { throw StorageError.invalidDocument }
        return value
    }
}
