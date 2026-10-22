import Foundation
import XCTest
@testable import NotebookCore

/// C6: schema 5–11 with embedded images is raised to 12 in memory on load;
/// opening writes nothing, the first real change keeps the exact old bytes
/// under `Migrations/`, then writes the assets and a schema-12 revision.
final class ImageAssetMigrationTests: XCTestCase {
    private let original = Data((0..<3_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    private let other = Data("zweites Original".utf8)

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// In memory (schema 12): two objects of one original on the first page,
    /// a second original on a trashed page.
    private func modern() throws -> Notebook {
        var notebook = try Notebook.blank(title: "Altheft").preparedForTextEditing()
        let first = ImageObject.test(bytes: original, x: 40), duplicate = ImageObject.test(bytes: original, x: 300)
        try notebook.replaceImages([first, duplicate], pageID: notebook.pages[0].id)
        let second = try notebook.insertPaper(.grid, at: 1)
        try notebook.replaceImages([.test(bytes: other)], pageID: second)
        try notebook.trashPage(second)
        XCTAssertEqual(notebook.schemaVersion, 12)
        return notebook
    }

    private var originals: [String: Data] {
        [ImageAssetReference(of: original).sha256: original, ImageAssetReference(of: other).sha256: other]
    }

    private func legacyPackage(_ root: URL, bytes: Data) throws { try LegacyNotebookJSON.writePackage(root, bytes: bytes) }
    private func inventory(_ root: URL) throws -> [String: Data] { try LegacyNotebookJSON.inventory(root) }

    private func migrationFiles(_ root: URL) throws -> [URL] {
        let parent = root.appendingPathComponent("Migrations", isDirectory: true)
        guard FileManager.default.fileExists(atPath: parent.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
            .flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
    }

    // MARK: Decoding

    func testDecodingRaisesEmbeddedImagesToSchema12InMemory() throws {
        let modern = try modern()
        let bytes = try LegacyNotebookJSON.encode(modern, schemaVersion: 11, originals: originals)
        let decoded = try NotebookDecoding.decode(bytes)
        XCTAssertEqual(decoded.storedSchemaVersion, 11)
        XCTAssertEqual(decoded.notebook, modern, "same objects, content addresses of the embedded bytes")
        XCTAssertEqual(decoded.inlineImageBytes, originals, "duplicated objects: one entry")
        XCTAssertEqual(decoded.storedExternalAssets, [], "nothing outside the stored JSON")
        XCTAssertEqual(decoded.notebook.externalImageAssets.count, 2)
        // A notebook without images keeps its schema.
        let plain = try JSONEncoder().encode(try Notebook.blank(title: "Ohne").preparedForTextEditing())
        XCTAssertEqual(try NotebookDecoding.decode(plain).notebook.schemaVersion, 4)
        // Schema 12 is stored as is.
        let stored = try NotebookDecoding.decode(JSONEncoder().encode(modern))
        XCTAssertEqual(stored.storedSchemaVersion, 12)
        XCTAssertEqual(stored.inlineImageBytes, [:])
        XCTAssertEqual(stored.storedExternalAssets, modern.externalImageAssets)
    }

    func testStoredFormsAreExclusiveAndUnknownSchemasStayLocked() throws {
        let modern = try modern()
        let legacy = try LegacyNotebookJSON.encode(modern, schemaVersion: 11, originals: originals)
        let current = try JSONEncoder().encode(modern)
        func mutated(_ data: Data, _ change: (inout [String: Any]) -> Void) throws -> Data {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            change(&object)
            return try JSONSerialization.data(withJSONObject: object)
        }
        func firstImage(_ object: inout [String: Any], _ change: (inout [String: Any]) -> Void) {
            var pages = object["pages"] as! [[String: Any]]
            var images = pages[0]["images"] as! [[String: Any]]
            change(&images[0]); pages[0]["images"] = images; object["pages"] = pages
        }
        let asset = ["sha256": ImageAssetReference(of: original).sha256, "byteCount": original.count] as [String: Any]
        let cases: [(String, Data)] = [
            ("schema 12 with data", try mutated(current) { firstImage(&$0) { $0["data"] = self.original.base64EncodedString() } }),
            ("schema 12 without asset", try mutated(current) { firstImage(&$0) { $0.removeValue(forKey: "asset"); $0["data"] = self.original.base64EncodedString() } }),
            ("schema 11 with asset", try mutated(legacy) { firstImage(&$0) { $0["asset"] = asset } }),
            ("schema 11 asset instead of data", try mutated(legacy) { firstImage(&$0) { $0.removeValue(forKey: "data"); $0["asset"] = asset } }),
            ("upper-case hash", try mutated(current) { firstImage(&$0) { $0["asset"] = ["sha256": (asset["sha256"] as! String).uppercased(), "byteCount": self.original.count] } }),
            ("63 hex digits", try mutated(current) { firstImage(&$0) { $0["asset"] = ["sha256": String((asset["sha256"] as! String).dropLast()), "byteCount": self.original.count] } }),
            ("path in hash", try mutated(current) { firstImage(&$0) { $0["asset"] = ["sha256": "../" + String((asset["sha256"] as! String).dropFirst(3)), "byteCount": self.original.count] } }),
            ("asset over 20 MB", try mutated(current) { firstImage(&$0) { $0["asset"] = ["sha256": String(repeating: "b", count: 64), "byteCount": 20_000_001] } }),
            ("same hash, other size", try mutated(current) { firstImage(&$0) { $0["asset"] = ["sha256": asset["sha256"]!, "byteCount": self.original.count + 1] } }),
            ("same hash, other pixel size", try mutated(current) { firstImage(&$0) { $0["pixelWidth"] = 9 } }),
            ("images in schema 12 below it", try mutated(current) { $0["schemaVersion"] = 11 }),
        ]
        for (name, data) in cases {
            XCTAssertThrowsError(try NotebookDecoding.decode(data), name)
        }
        // 500 MB of unique originals (declared): duplicates count once, one byte more is refused.
        var full = try Notebook.blank(title: "Voll").preparedForTextEditing()
        var images = (0..<25).map { ImageObject(asset: .declared(20_000_000, seed: $0), pixelWidth: 8, pixelHeight: 6, x: 40 + Double($0)) }
        var copy = images[0]; copy.id = UUID(); images.append(copy)
        try full.replaceImages(images, pageID: full.pages[0].id)
        XCTAssertEqual(try NotebookDecoding.decode(JSONEncoder().encode(full)).notebook, full)
        full.pages[0].images!.append(ImageObject(asset: .declared(1, seed: 99), pixelWidth: 8, pixelHeight: 6))
        XCTAssertThrowsError(try NotebookDecoding.decode(JSONEncoder().encode(full)))
        // Schema 15 is locked before anything else, also inside a package.
        let future = try mutated(current) { $0["schemaVersion"] = 15 }
        XCTAssertThrowsError(try NotebookDecoding.decode(future)) { error in
            guard case StorageError.unsupportedSchema(15) = error else { return XCTFail("\(error)") }
        }
        let root = try directory()
        try legacyPackage(root, bytes: future)
        XCTAssertThrowsError(try RevisionStore(directory: root).load()) { error in
            guard case StorageError.unsupportedSchema(15) = error else { return XCTFail("\(error)") }
        }
    }

    func testLegacyLimitsApplyOnlyToTheStoredForm() throws {
        // 81 objects of one 500 kB original on two pages: one original in
        // memory, but 40.5 MB embedded – over the old 40 MB per-object sum.
        let bytes = Data(repeating: 7, count: 500_000)
        let reference = ImageAssetReference.declared(bytes.count)
        var notebook = try Notebook.blank(title: "Grenze").preparedForTextEditing()
        let second = try notebook.insertPaper(.blank, at: 1)
        func objects(_ count: Int) -> [ImageObject] {
            (0..<count).map { ImageObject(asset: reference, pixelWidth: 8, pixelHeight: 6, x: 40 + Double($0)) }
        }
        try notebook.replaceImages(objects(50), pageID: notebook.pages[0].id)
        try notebook.replaceImages(objects(30), pageID: second)
        XCTAssertEqual(notebook.uniqueImageAssetBytes, 500_000)
        let within = try LegacyNotebookJSON.encode(notebook, schemaVersion: 11, originals: [reference.sha256: bytes])
        let decoded = try NotebookDecoding.decode(within)
        XCTAssertEqual(decoded.inlineImageBytes.count, 1, "duplicates hashed once")
        XCTAssertEqual(decoded.notebook.uniqueImageAssetBytes, 500_000)
        try notebook.replaceImages(objects(31), pageID: second)
        let over = try LegacyNotebookJSON.encode(notebook, schemaVersion: 11, originals: [reference.sha256: bytes])
        XCTAssertThrowsError(try NotebookDecoding.decode(over))
        XCTAssertNoThrow(try NotebookDecoding.decode(JSONEncoder().encode(notebook)), "schema 12 counts each original once")
        // An embedded original above 20 MB is refused before it is hashed.
        var single = try Notebook.blank(title: "Groß").preparedForTextEditing()
        try single.replaceImages([ImageObject(asset: .declared(20_000_000), pixelWidth: 8, pixelHeight: 6)], pageID: single.pages[0].id)
        let oversized = try LegacyNotebookJSON.encode(single, schemaVersion: 11,
                                                      originals: [ImageAssetReference.declared(20_000_000).sha256: Data(count: 20_000_001)])
        XCTAssertThrowsError(try NotebookDecoding.decode(oversized))
    }

    // MARK: Opening and the first change

    func testOpeningAnOldNotebookWithImagesWritesNothing() async throws {
        let root = try directory()
        let modern = try modern()
        try legacyPackage(root, bytes: LegacyNotebookJSON.encode(modern, schemaVersion: 11, originals: originals))
        let before = try inventory(root)
        let repository = NotebookRepository(directory: root)
        let (loaded, recovered) = try await repository.load()
        XCTAssertFalse(recovered)
        XCTAssertEqual(loaded, modern)
        XCTAssertEqual(Set(repository.assets.pendingReferences), Set(modern.externalImageAssets), "embedded originals wait in memory")
        // The editor saves right after opening: unchanged, so no commit.
        try await repository.save(loaded, revision: 1)
        try await repository.save(loaded, revision: 2)
        XCTAssertEqual(try inventory(root), before, "no revision, no Assets/, no Migrations/")
        // Rendering already reads the embedded originals through the store.
        XCTAssertEqual(try repository.assets.payload(for: ImageAssetReference(of: original)), .data(original))
        // A read-only store (preview, search) never writes either.
        let preview = RevisionStore(directory: root, readOnly: true)
        XCTAssertEqual(try preview.load(), modern)
        XCTAssertThrowsError(try preview.save(modern)) { XCTAssertEqual($0 as? ImageAssetError, .readOnly) }
        XCTAssertEqual(try inventory(root), before)
    }

    func testFirstChangeKeepsExactOldBytesThenWritesAssetsAndSchema12() throws {
        let root = try directory()
        let modern = try modern()
        let old = try LegacyNotebookJSON.encode(modern, schemaVersion: 11, originals: originals)
        try legacyPackage(root, bytes: old)
        let store = RevisionStore(directory: root)
        var document = try store.load()
        try store.save(document)
        XCTAssertEqual(try migrationFiles(root), [])
        document.pages[0].text = ""
        try document.replaceTextBoxes([TextBox(x: 40, y: 600, width: 200, height: 40, text: "geändert")], pageID: document.pages[0].id)
        try store.save(document)
        let archived = try migrationFiles(root)
        XCTAssertEqual(archived.map(\.lastPathComponent), ["notebook-v11.json"])
        XCTAssertEqual(try Data(contentsOf: archived[0]), old, "exact acknowledged bytes")
        // Two objects of one original and one trashed: exactly two asset files with the embedded bytes.
        let assetNames = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Assets").path).sorted()
        XCTAssertEqual(assetNames, originals.keys.sorted())
        for (hash, bytes) in originals {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Assets/\(hash)")), bytes)
        }
        XCTAssertEqual(store.assets.pendingReferences, [], "written by the commit, renderer reads files")
        // The new revision is schema 12 with references only.
        let manifest = try JSONDecoder().decode(RevisionManifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        let newest = try Data(contentsOf: root.appendingPathComponent("Revisions/\(manifest.revisions[0].file)"))
        let decoded = try NotebookDecoding.decode(newest)
        XCTAssertEqual(decoded.storedSchemaVersion, 12)
        XCTAssertEqual(decoded.inlineImageBytes, [:])
        XCTAssertNil(newest.range(of: Data(original.base64EncodedString().utf8)))
        XCTAssertEqual(try RevisionStore(directory: root).load(), document)
        // Later commits keep the single migration copy.
        document.pages[0].drawing = Data([1, 2])
        try store.save(document)
        XCTAssertEqual(try migrationFiles(root).count, 1)
        // The old revision is still in the history and decodes with its embedded bytes.
        let history = try store.localHistory()
        let oldest = try store.localRevision(id: try XCTUnwrap(history.revisions.last?.id))
        XCTAssertEqual(oldest.storedSchemaVersion, 11)
        XCTAssertEqual(oldest.inlineImageBytes, originals)
    }

    func testFailedMigrationCopyPreventsTheCommitAndARetryReusesIt() throws {
        let root = try directory()
        let old = try LegacyNotebookJSON.encode(modern(), schemaVersion: 11, originals: originals)
        try legacyPackage(root, bytes: old)
        let before = try inventory(root)
        let store = RevisionStore(directory: root)
        var document = try store.load()
        document.pages[0].drawing = Data([9])
        // `Migrations` is a file: the copy fails, nothing else is written.
        let blocker = root.appendingPathComponent("Migrations")
        try Data("kein Ordner".utf8).write(to: blocker)
        XCTAssertThrowsError(try store.save(document))
        var expected = before; expected["/Migrations"] = Data("kein Ordner".utf8)
        XCTAssertEqual(try inventory(root), expected, "no asset, no revision, no manifest change")
        XCTAssertEqual(try NotebookDecoding.decode(Data(contentsOf: root.appendingPathComponent("Revisions").appendingPathComponent(
            try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Revisions").path)[0]))).storedSchemaVersion, 11)
        let fresh = RevisionStore(directory: root)
        XCTAssertEqual(try fresh.load().pages[0].drawing, Data(), "the acknowledged state stays readable")
        try FileManager.default.removeItem(at: blocker)
        // A commit failing after the copy: the retry reuses the identical archive.
        store.commitFault = { if $0 == .revisionWritten { throw CocoaError(.fileWriteOutOfSpace) } }
        XCTAssertThrowsError(try store.save(document))
        XCTAssertEqual(try migrationFiles(root).count, 1)
        store.commitFault = { _ in }
        try store.save(document)
        let archived = try migrationFiles(root)
        XCTAssertEqual(archived.count, 1, "same bytes, same archive")
        XCTAssertEqual(try Data(contentsOf: archived[0]), old)
        XCTAssertEqual(try RevisionStore(directory: root).load(), document)
    }

    func testUndoAfterMigrationNeverLowersTheSchema() throws {
        let root = try directory()
        try legacyPackage(root, bytes: LegacyNotebookJSON.encode(modern(), schemaVersion: 11, originals: originals))
        var document = try RevisionStore(directory: root).load()
        XCTAssertEqual(document.schemaVersion, 12)
        var history = NotebookUndoHistory()
        // A page operation recorded with page snapshots (`PageStructureChange`).
        let before = document
        _ = try document.insertPaper(.lined, at: 1)
        XCTAssertTrue(history.recordPages(before: before, after: document, undoPageID: before.pages[0].id, redoPageID: document.pages[1].id))
        // A content change removing every image of the page.
        let contentBefore = PageContent(page: document.pages[0])
        var content = contentBefore; content.images = []
        try document.replaceContent(content, pageID: document.pages[0].id)
        history.record(.objects, changes: [PageContentReplacement(pageID: document.pages[0].id, expected: contentBefore, replacement: content)])
        for _ in 0..<2 {
            let outcome = try XCTUnwrap(history.undo(document))
            try outcome.notebook.validate()
            document = outcome.notebook
            XCTAssertEqual(document.schemaVersion, 12)
        }
        XCTAssertEqual(document.pages.count, before.pages.count)
        XCTAssertEqual(document.allImages, before.allImages)
        // A restored copy keeps the schema, too.
        var copy = document; copy.schemaVersion = 2
        copy.raiseSchemaForImageAssets()
        XCTAssertEqual(copy.schemaVersion, 12)
    }
}
