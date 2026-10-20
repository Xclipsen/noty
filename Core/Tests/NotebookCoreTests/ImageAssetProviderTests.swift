import Foundation
import XCTest
@testable import NotebookCore

/// C4/C6: every image byte access goes through `ImageAssetProviding`; since
/// schema 12 an image object stores only its content address.
final class ImageAssetProviderTests: XCTestCase {
    private func image(_ bytes: Data) -> ImageObject { .test(bytes: bytes) }

    func testObjectEncodesOnlyItsReferenceAndRejectsEmbeddedBytes() throws {
        let bytes = Data((0..<1_000).map { UInt8($0 % 251) })
        let object = image(bytes)
        XCTAssertEqual(object.asset, ImageAssetReference(of: bytes))
        let encoded = try JSONEncoder().encode(object)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["id", "asset", "pixelWidth", "pixelHeight", "x", "y", "width", "height", "rotation", "crop", "locked"])
        XCTAssertEqual(Set(try XCTUnwrap(json["asset"] as? [String: Any]).keys), ["sha256", "byteCount"])
        XCTAssertEqual(try JSONDecoder().decode(ImageObject.self, from: encoded), object)
        // Without a decoding context the current form applies: `data` is no field of it.
        var mixed = json; mixed["data"] = bytes.base64EncodedString()
        XCTAssertThrowsError(try JSONDecoder().decode(ImageObject.self, from: JSONSerialization.data(withJSONObject: mixed)))
        var legacy = json; legacy.removeValue(forKey: "asset"); legacy["data"] = bytes.base64EncodedString()
        XCTAssertThrowsError(try JSONDecoder().decode(ImageObject.self, from: JSONSerialization.data(withJSONObject: legacy)))
        var moved = object; moved.x += 1
        XCTAssertNotEqual(moved, object)
    }

    func testInlineProviderServesNotebookBytesByContent() throws {
        let a = Data(repeating: 1, count: 40), b = Data(repeating: 2, count: 50)
        var notebook = Notebook()
        notebook.pages[0].images = [image(a), image(a)]
        var trashed = Page(); trashed.images = [image(b)]
        notebook.deletedPages = [DeletedPage(page: trashed, originalIndex: 1, deletedAt: Date(timeIntervalSince1970: 1), nextPageID: nil, previousPageID: nil)]
        XCTAssertEqual(notebook.allImages.count, 3)
        XCTAssertEqual(notebook.externalImageAssets, [ImageAssetReference(of: a), ImageAssetReference(of: b)],
                       "unique, active pages before the page trash")
        let assets = InlineImageAssets(bytes: [ImageAssetReference(of: a).sha256: a, ImageAssetReference(of: b).sha256: b])
        XCTAssertEqual(Set(assets.references), [ImageAssetReference(of: a), ImageAssetReference(of: b)])
        XCTAssertEqual(try assets.payload(for: ImageAssetReference(of: b)), .data(b))
        XCTAssertEqual(try assets.verifiedPayload(for: ImageAssetReference(of: a)), .data(a))
        XCTAssertThrowsError(try assets.payload(for: ImageAssetReference(of: Data([9])))) { error in
            guard case ImageAssetError.missing = error else { return XCTFail("\(error)") }
        }
        let wrongSize = ImageAssetReference(sha256: ImageAssetReference(of: a).sha256, byteCount: 41)
        XCTAssertThrowsError(try assets.payload(for: wrongSize))
        XCTAssertThrowsError(try assets.payload(for: ImageAssetReference(sha256: "X", byteCount: 1))) { error in
            XCTAssertEqual(error as? ImageAssetError, .invalidReference)
        }
    }

    func testChainedProviderUsesTheFirstSourceAndReportsDamageFirst() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data(repeating: 3, count: 32), other = Data(repeating: 4, count: 32)
        let reference = ImageAssetReference(of: bytes)
        let package = NotebookAssets(package: root)
        _ = try package.stage(bytes)
        try package.persist([reference])
        package.dropPending([reference])
        let inline = InlineImageAssets(bytes: [ImageAssetReference(of: other).sha256: other])
        let chain = ChainedImageAssets([inline, package])
        XCTAssertEqual(try chain.payload(for: ImageAssetReference(of: other)), .data(other))
        guard case .file = try chain.verifiedPayload(for: reference) else { return XCTFail("package file expected") }
        XCTAssertThrowsError(try ChainedImageAssets([]).payload(for: reference)) { error in
            XCTAssertEqual(error as? ImageAssetError, .missing(reference.sha256))
        }
        // Same size, other content: a fresh reader proves the damage, which
        // wins over the inline provider's plain absence.
        try Data(repeating: 5, count: 32).write(to: package.directory.appendingPathComponent(reference.sha256))
        let fresh = NotebookAssets(package: root, readOnly: true)
        XCTAssertThrowsError(try ChainedImageAssets([inline, fresh]).verifiedPayload(for: reference)) { error in
            XCTAssertEqual(error as? ImageAssetError, .damaged(reference.sha256))
        }
    }

    func testAcceleratedDigestIsOnlyInstalledWhenItMatchesTheVectors() {
        defer { SHA256.removeAccelerated() }
        let data = Data("abc".utf8)
        XCTAssertFalse(SHA256.installAccelerated { _ in [UInt8](repeating: 0, count: 32) })
        XCTAssertEqual(SHA256.hexDigest(data), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let seen = Seen()
        XCTAssertTrue(SHA256.installAccelerated { bytes in
            seen.insert(bytes)
            var hasher = SHA256(); hasher.update(bytes); return hasher.finalize()
        })
        // Unique inputs: other digests running meanwhile cannot disturb the check.
        let marker = Data("noty-\(UUID().uuidString)".utf8), other = Data("noty-\(UUID().uuidString)".utf8)
        XCTAssertEqual(SHA256.hexDigest(marker), SHA256.portableHexDigest(marker))
        XCTAssertEqual(ImageAssetReference(of: other).sha256, SHA256.portableHexDigest(other))
        XCTAssertTrue(seen.contains(marker) && seen.contains(other), "one-shot digests use the installed implementation")
        XCTAssertEqual(SHA256.hexDigest(data), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testSearchFingerprintFollowsTheContentAddress() {
        var notebook = Notebook.blank(title: "Bild")
        notebook.pages[0].images = [image(Data(repeating: 1, count: 64))]
        let before = ContentSearchPlanner.prepare(notebook)[0].fingerprints.imageOCR
        XCTAssertNotNil(before)
        var same = notebook
        same.pages[0].images = [.test(bytes: Data(repeating: 1, count: 64), id: notebook.pages[0].images![0].id)]
        XCTAssertEqual(ContentSearchPlanner.prepare(same)[0].fingerprints.imageOCR, before)
        var changed = notebook
        changed.pages[0].images = [.test(bytes: Data(repeating: 2, count: 64), id: notebook.pages[0].images![0].id)]
        XCTAssertNotEqual(ContentSearchPlanner.prepare(changed)[0].fingerprints.imageOCR, before)
    }
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var inputs = Set<Data>()
    func insert(_ data: Data) { lock.lock(); inputs.insert(data); lock.unlock() }
    func contains(_ data: Data) -> Bool { lock.lock(); defer { lock.unlock() }; return inputs.contains(data) }
}
