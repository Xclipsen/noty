import Foundation
import XCTest
@testable import NotebookCore

/// A local write error while a restore extracts image originals (e.g. no
/// space left on the device) is not a defective archive, for `.noty` and
/// `.notylibrary` alike.
final class RestoreExtractionErrorTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("extraction-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private let bytes = Data((0..<4000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })

    private func notebook(_ title: String) -> Notebook {
        var document = Notebook(); document.title = title
        document.pages[0].images = [ImageObject(asset: ImageAssetReference(of: bytes), pixelWidth: 8, pixelHeight: 6, x: 40, y: 40)]
        document.schemaVersion = max(Notebook.imageAssetSchemaVersion, document.schemaVersion)
        return document
    }

    private var assets: InlineImageAssets { InlineImageAssets(bytes: [ImageAssetReference(of: bytes).sha256: bytes]) }

    /// A regular file where the extraction directory should be: every write fails.
    private func unwritable(_ root: URL) throws -> URL {
        let url = root.appendingPathComponent("kein-ordner")
        try Data("x".utf8).write(to: url)
        return url
    }

    private func backup(_ root: URL) throws -> URL {
        let url = root.appendingPathComponent("heft.notybackup")
        try BackupArchive.write(notebook("Mit Bild"), assets: assets, to: url)
        XCTAssertNoThrow(try BackupArchive.verify(url), "precondition: the archive is valid")
        return url
    }

    private func library(_ root: URL) throws -> URL {
        let document = notebook("Mit Bild")
        var snapshot = LibrarySnapshot()
        snapshot.items = [LibraryItem(id: document.id, title: document.title, source: .library)]
        let url = root.appendingPathComponent("bibliothek.notylibrary")
        try LibraryArchive.encode(LibraryBundle(snapshot: snapshot, documents: [document]), assets: assets).write(to: url)
        XCTAssertNoThrow(try LibraryArchive.verify(url), "precondition: the archive is valid")
        return url
    }

    func testWriteErrorWhileExtractingANotebookBackupIsNotAnInvalidArchive() throws {
        let root = try directory()
        let url = try backup(root)
        XCTAssertThrowsError(try BackupArchive.verify(url, extractingAssetsTo: try unwritable(root))) { error in
            guard case BackupError.extractionFailed(let outOfSpace) = error else { return XCTFail("reported as \(error)") }
            XCTAssertFalse(outOfSpace)
            XCTAssertNotEqual(error.localizedDescription, BackupError.invalidArchive.localizedDescription)
        }
    }

    func testWriteErrorWhileExtractingALibraryBackupIsNotAnInvalidArchive() throws {
        let root = try directory()
        let url = try library(root)
        XCTAssertThrowsError(try LibraryArchive.verify(url, extractingAssetsTo: try unwritable(root)) { _, _ in }) { error in
            XCTAssertEqual(error as? LibraryArchiveError, .extractionFailed(outOfSpace: false))
            XCTAssertNotEqual(error.localizedDescription, LibraryArchiveError.invalid.localizedDescription)
        }
    }

    func testADefectiveArchiveStaysInvalidWhileExtracting() throws {
        let root = try directory()
        let target = root.appendingPathComponent("Assets", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        // Cut inside the asset record: the archive itself is incomplete.
        let cutBackup = root.appendingPathComponent("kurz.notybackup")
        try Data(contentsOf: try backup(root)).dropLast(2_500).write(to: cutBackup)
        XCTAssertThrowsError(try BackupArchive.verify(cutBackup, extractingAssetsTo: target)) { error in
            guard case BackupError.invalidArchive = error else { return XCTFail("reported as \(error)") }
        }
        let cutLibrary = root.appendingPathComponent("kurz.notylibrary")
        try Data(contentsOf: try library(root)).dropLast(2_500).write(to: cutLibrary)
        XCTAssertThrowsError(try LibraryArchive.verify(cutLibrary, extractingAssetsTo: target) { _, _ in }) { error in
            XCTAssertEqual(error as? LibraryArchiveError, .invalid)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [], "no partial original is left behind")
    }

    func testOutOfSpaceIsRecognisedFromCocoaAndPOSIXErrors() {
        XCTAssertTrue(RecordArchiveExtractionFailed(underlying: CocoaError(.fileWriteOutOfSpace)).outOfSpace)
        XCTAssertTrue(RecordArchiveExtractionFailed(underlying: POSIXError(.ENOSPC)).outOfSpace)
        XCTAssertTrue(RecordArchiveExtractionFailed(underlying: CocoaError(.fileWriteUnknown, userInfo: [NSUnderlyingErrorKey: POSIXError(.ENOSPC)])).outOfSpace)
        XCTAssertFalse(RecordArchiveExtractionFailed(underlying: CocoaError(.fileWriteNoPermission)).outOfSpace)
        XCTAssertFalse(RecordArchiveExtractionFailed(underlying: BackupError.invalidArchive).outOfSpace)
        // Both messages name the cause instead of a defective file.
        for outOfSpace in [true, false] {
            XCTAssertEqual(BackupError.extractionFailed(outOfSpace: outOfSpace).localizedDescription,
                           LibraryArchiveError.extractionFailed(outOfSpace: outOfSpace).localizedDescription)
        }
        XCTAssertTrue(BackupError.extractionFailed(outOfSpace: true).localizedDescription.contains("Zu wenig freier Speicher"))
    }
}
