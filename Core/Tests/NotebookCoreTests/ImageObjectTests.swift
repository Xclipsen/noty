import Foundation
import XCTest
@testable import NotebookCore

final class ImageObjectTests: XCTestCase {
    private let bytes = Data([137, 80, 78, 71])
    private func image() -> ImageObject {
        .test(bytes: bytes, pixelWidth: 1200, pixelHeight: 800, x: 100, y: 100, width: 240, height: 160)
    }

    func testFirstImagePreservesLegacyTextAndPDFAndTextEditingCannotDowngrade() throws {
        var document = Notebook(); document.pdf = Data([1, 2, 3]); document.pages[0].text = "Alttext"
        let before = document
        XCTAssertEqual(try Notebook.decode(JSONEncoder().encode(document)), before)
        try document.replaceImages([image()], pageID: document.pages[0].id)
        XCTAssertEqual(document.schemaVersion, 12, "image objects reference assets: schema 12")
        XCTAssertEqual(document.pdfSources?.first?.data, before.pdf)
        XCTAssertEqual(document.pages[0].text, before.pages[0].text)
        try document.replaceTextBoxes(document.pages[0].effectiveTextBoxes, pageID: document.pages[0].id)
        XCTAssertEqual(document.schemaVersion, 12)
        XCTAssertEqual(document.pages[0].images, [imageWithID(document.pages[0].images![0].id)])
    }

    private func imageWithID(_ id: UUID) -> ImageObject { var copy = image(); copy.id = id; return copy }

    func testCropAndArbitraryRotationKeepOriginalBytesAndFitAllCorners() throws {
        let original = image()
        var quarterTurn = original; quarterTurn.rotation = 90
        XCTAssertEqual(quarterTurn.rotatedBounds.x, 140, accuracy: 0.0001)
        XCTAssertEqual(quarterTurn.rotatedBounds.y, 60, accuracy: 0.0001)
        XCTAssertEqual(quarterTurn.rotatedBounds.width, 160, accuracy: 0.0001)
        XCTAssertEqual(quarterTurn.rotatedBounds.height, 240, accuracy: 0.0001)
        let bounds = PageRect(x: -100, y: -80, width: 400, height: 500)
        var rotated = original; rotated.rotation = 37; rotated.x = -150; rotated.y = -90
        let fitted = rotated.fitted(in: bounds)
        XCTAssertTrue(fitted.fits(in: bounds))
        XCTAssertEqual(fitted.width / fitted.height, 1.5, accuracy: 0.0001)
        let crop = PageRect(x: 0.25, y: 0.1, width: 0.5, height: 0.75)
        let cropped = try fitted.cropped(to: crop, in: bounds)
        XCTAssertEqual(cropped.crop, crop); XCTAssertEqual(cropped.asset, original.asset)
        XCTAssertEqual(cropped.width / cropped.height, 1, accuracy: 0.0001)
        XCTAssertTrue(cropped.fits(in: bounds))
        let reset = try cropped.cropped(to: .init(x: 0, y: 0, width: 1, height: 1), in: bounds)
        XCTAssertEqual(reset.width / reset.height, 1.5, accuracy: 0.0001)
        XCTAssertTrue(reset.fits(in: bounds)); XCTAssertEqual(reset.asset, original.asset)
    }

    func testLimitsAndInvalidMetadataDoNotChangeTheDocument() throws {
        var document = Notebook.blank(title: "Grenzen"); let id = document.pages[0].id
        let original = document
        let tooMany = (0..<51).map { _ in image() }
        XCTAssertThrowsError(try document.replaceImages(tooMany, pageID: id))
        let oversized = ImageObject(asset: .declared(20_000_001), pixelWidth: 1, pixelHeight: 1)
        XCTAssertThrowsError(try document.replaceImages([oversized], pageID: id))
        let pixels = ImageObject(asset: ImageAssetReference(of: Data([1])), pixelWidth: 100_000, pixelHeight: 100_000)
        XCTAssertThrowsError(try document.replaceImages([pixels], pageID: id))
        // 500 MB of unique originals: 35 × 14 MB fit, a 36th does not.
        func large(_ seed: Int) -> ImageObject { ImageObject(asset: .declared(14_000_000, seed: seed), pixelWidth: 100, pixelHeight: 100) }
        let fitting = (0..<35).map(large)
        XCTAssertThrowsError(try document.replaceImages(fitting + [large(35)], pageID: id))
        XCTAssertEqual(document, original)
        // A duplicated object shares its original and costs nothing.
        var again = fitting[0]; again.id = UUID()
        try document.replaceImages(fitting + [again], pageID: id)
        XCTAssertEqual(document.uniqueImageAssetBytes, 490_000_000)
        // Objects of one original must agree on its pixel size.
        var otherSize = ImageObject(asset: fitting[0].asset, pixelWidth: 101, pixelHeight: 100); otherSize.x = 300
        XCTAssertThrowsError(try document.replaceImages(fitting + [otherSize], pageID: id))
        let other = try document.insertPaper(.blank, at: 1)
        try document.trashPage(id)
        // The page trash still counts.
        XCTAssertThrowsError(try document.replaceImages([large(35)], pageID: other))
        var third = again; third.id = UUID()
        XCTAssertNoThrow(try document.replaceImages([third], pageID: other), "an original of the trash costs nothing again")
    }

    func testInvalidObjectsAreRejectedAtomicallyIncludingTrashIdentities() throws {
        var document = Notebook.blank(title: "Bilder"); let id = document.pages[0].id
        let original = document
        var bad = image(); bad.rotation = .infinity
        XCTAssertThrowsError(try document.replaceImages([bad], pageID: id)); XCTAssertEqual(document, original)
        bad = image(); bad.crop.width = 0
        XCTAssertThrowsError(try document.replaceImages([bad], pageID: id))
        bad = image(); bad.crop.x = 0.9
        XCTAssertThrowsError(try document.replaceImages([bad], pageID: id))
        bad = image(); bad.x = 590
        XCTAssertThrowsError(try document.replaceImages([bad], pageID: id))
        bad = image(); bad.rotation = 45; bad.x = 0; bad.y = 0
        XCTAssertThrowsError(try document.replaceImages([bad], pageID: id))
        let same = image()
        XCTAssertThrowsError(try document.replaceImages([same, same], pageID: id))
        XCTAssertThrowsError(try document.replaceImages([image()], pageID: UUID()))
        XCTAssertEqual(document, original)
        try document.replaceImages([same], pageID: id)
        let other = try document.insertPaper(.blank, at: 1)
        try document.trashPage(id)
        XCTAssertThrowsError(try document.replaceImages([same], pageID: other))
        var oldSchema = original; oldSchema.pages[0].images = [image()]
        XCTAssertThrowsError(try oldSchema.validate())
    }

    func testIndependentDuplicateTrashAndMarginRestoreKeepImagesAndLock() throws {
        var document = Notebook(); document.pdf = Data([1])
        let id = document.pages[0].id
        var object = image(); object.locked = true
        try document.replaceImages([object], pageID: id)
        try document.setMargins(PageMargins(right: 300), pageIDs: [id])
        let copyID = try document.duplicatePage(id)
        let copied = try XCTUnwrap(document.pages[1].images?.first)
        XCTAssertNotEqual(copied.id, object.id); XCTAssertEqual(copied.asset, object.asset); XCTAssertTrue(copied.locked)
        try document.trashPage(copyID); try document.restorePage(copyID)
        try document.applyMargins(PageMargins(), pageIDs: [id], trimmedDrawings: [id: Data([4])])
        try document.replaceImages([], pageID: id)
        let snapshot = document.deletedPages!.first!.id
        try document.restorePage(snapshot)
        XCTAssertEqual(document.pages[0].images?.first?.asset, object.asset)
        XCTAssertTrue(document.pages[0].images!.first!.locked)
        try document.validate()
    }

    func testImagesOutsideReducedMarginsBlockBothCoreMarginPaths() throws {
        var document = Notebook(); document.pdf = Data([1]); let id = document.pages[0].id
        try document.setMargins(PageMargins(left: 300), pageIDs: [id])
        var object = image(); object.x = -250
        try document.replaceImages([object], pageID: id)
        let original = document
        XCTAssertThrowsError(try document.setMargins(PageMargins(), pageIDs: [id]))
        XCTAssertThrowsError(try document.applyMargins(PageMargins(), pageIDs: [id]))
        XCTAssertEqual(document, original)
    }

    func testRevisionMigrationAndBothArchivesRestoreEditableImages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RevisionStore(directory: root)
        var document = try Notebook.blank(title: "Bildarchiv").preparedForTextEditing()
        try store.save(document)
        let oldBytes = try JSONEncoder().encode(document)
        // Exact acknowledged bytes are obtained from the committed revision.
        let revisionFiles = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Revisions"), includingPropertiesForKeys: nil)
        let acknowledged = try Data(contentsOf: XCTUnwrap(revisionFiles.first))
        var object = image(); object.rotation = -33; object.locked = true
        _ = try store.assets.stage(bytes)
        try document.replaceImages([object], pageID: document.pages[0].id)
        try store.save(document)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Assets/\(object.asset.sha256)")), bytes)
        XCTAssertEqual(try RevisionStore(directory: root).load(), document)
        let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent("Migrations"), includingPropertiesForKeys: nil)!
        let migration = try XCTUnwrap(enumerator.allObjects.compactMap { $0 as? URL }.first { $0.lastPathComponent == "notebook-v4.json" })
        XCTAssertEqual(try Data(contentsOf: migration), acknowledged)
        XCTAssertEqual(try Notebook.decode(oldBytes).schemaVersion, 4)
        let archive = try BackupArchive.encode(document, assets: store.assets)
        XCTAssertEqual(try BackupArchive.decode(archive).document, document)
        let repository = NotebookRepository(directory: root)
        let file = root.appendingPathComponent("images.notybackup"); try archive.write(to: file)
        let staged = try await repository.prepareRestore(from: file)
        let restored = try await repository.commitRestore(staged)
        let restoredStore = RevisionStore(directory: restored.directory)
        var edited = try restoredStore.load()
        XCTAssertEqual(edited.pages, document.pages)
        var changed = object; changed.locked = false; changed.rotation = 15
        try edited.replaceImages([changed], pageID: edited.pages[0].id)
        try restoredStore.save(edited)
        XCTAssertEqual(try RevisionStore(directory: restored.directory).load(), edited)
        XCTAssertEqual(try RevisionStore(directory: root).load(), document)
        let library = LibraryStore(root: root); _ = try await library.load()
        let bundle = try await library.backupBundle()
        let libraryBytes = try LibraryArchive.encode(bundle, assets: store.assets)
        XCTAssertEqual(try LibraryArchive.decode(libraryBytes).documents, bundle.documents)
    }
}
