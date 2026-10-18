import Foundation
import XCTest
@testable import NotebookCore

final class MarginRestoreTests: XCTestCase {
    private func trimmed() throws -> (Notebook, Page, UUID) {
        var value = Notebook.blank(title: "Rand-Restore")
        let geometry = try PDFPageGeometry(mediaBox: .init(x: -20, y: 0, width: 600, height: 800),
            cropBox: .init(x: 10, y: 30, width: 500, height: 700), rotation: 90)
        let id = try value.insertPDF(Data([1, 2, 3]), geometries: [geometry], at: 0)[0]
        value.pages[0].drawing = Data([10, 20])
        value.pages[0].text = "Vor Verkleinerung ÄÖÜ"
        try value.setMargins(PageMargins(left: 200, top: 100, style: .grid, color: .dark), pageIDs: [id])
        let original = value.pages[0]
        try value.applyMargins(PageMargins(left: 50), pageIDs: [id], trimmedDrawings: [id: Data([10])])
        return (value, original, try XCTUnwrap(value.deletedPages?.first?.id))
    }

    func testRestoreKeepsStableIDCurrentPositionAndEveryNewerLayerInTrash() throws {
        var (value, original, savedID) = try trimmed()
        try value.movePage(original.id, to: 1)
        value.pages[1].drawing.append(99)
        value.pages[1].text = "Später bearbeitet"
        value.pages[1].bookmarked = true
        let current = value.pages[1]
        let order = value.pages.map(\.id)
        let untouched = value.pages[0]
        XCTAssertEqual(try value.restorePage(savedID), original.id)
        XCTAssertEqual(value.pages.map(\.id), order)
        XCTAssertEqual(value.pages[1], original)
        XCTAssertEqual(value.pages[0], untouched)
        let backup = try XCTUnwrap(value.deletedPages?.first)
        var expected = current; expected.id = backup.id
        XCTAssertEqual(backup.page, expected)
        XCTAssertNotEqual(backup.id, original.id)
        XCTAssertNotEqual(backup.id, savedID)
        XCTAssertEqual(value.marginRestoreTarget(for: backup), original.id)
    }

    func testCurrentStateCanBeRecoveredAfterCommitRestartAndExternalBackup() throws {
        var (value, original, savedID) = try trimmed()
        value.pages[0].text = "Neuere Eingabe bleibt rettbar"
        value.pages[0].drawing.append(88)
        let current = value.pages[0]
        try value.restorePage(savedID)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RevisionStore(directory: root)
        try store.save(value)
        var reopened = try store.load()
        XCTAssertEqual(reopened, value)
        reopened = try BackupArchive.decode(BackupArchive.encode(reopened)).document
        let backupID = try XCTUnwrap(reopened.deletedPages?.first?.id)
        XCTAssertEqual(try reopened.restorePage(backupID), original.id)
        XCTAssertEqual(reopened.pages[0], current)
        var previous = original
        previous.id = try XCTUnwrap(reopened.deletedPages?.first?.id)
        XCTAssertEqual(reopened.deletedPages?.first?.page, previous)
        try store.save(reopened)
        XCTAssertEqual(try RevisionStore(directory: root).load(), reopened)
    }

    func testMissingOriginalRestoresAsExtraPageWithoutConsumingDeletedOriginal() throws {
        var (value, original, savedID) = try trimmed()
        try value.trashPage(original.id)
        let deletedOriginal = try XCTUnwrap(value.deletedPages?.first { $0.id == original.id })
        XCTAssertNil(value.marginRestoreTarget(for: try XCTUnwrap(value.deletedPages?.first { $0.id == savedID })))
        XCTAssertEqual(try value.restorePage(savedID), savedID)
        XCTAssertEqual(value.pages.count, 2)
        XCTAssertEqual(value.pages.first { $0.id == savedID }?.margins, original.margins)
        XCTAssertEqual(value.deletedPages?.first { $0.id == original.id }, deletedOriginal)
    }

    func testWrongPDFReferenceCannotReplaceAnotherPage() throws {
        var (value, _, savedID) = try trimmed()
        let otherID = try value.insertPDF(Data([4, 5]), geometries: [PaperStyle.geometry], at: 0)[0]
        let otherPage = value.pages[0]
        let snapshot = try XCTUnwrap(value.deletedPages?.first)
        value.deletedPages = [DeletedPage(page: snapshot.page, originalIndex: 0, deletedAt: snapshot.deletedAt,
            nextPageID: nil, previousPageID: otherID, reason: .marginReduction)]
        XCTAssertNil(value.marginRestoreTarget(for: value.deletedPages![0]))
        try value.restorePage(savedID)
        XCTAssertEqual(value.pages.first { $0.id == otherID }, otherPage)
        XCTAssertEqual(value.pages.count, 4)
    }

    func testReplacementAtBothCapacityLimitsDoesNotNeedAdditionalSlots() throws {
        var (value, original, savedID) = try trimmed()
        while value.pages.count < 500 {
            var page = Page(); page.paper = .blank; page.geometry = PaperStyle.geometry
            value.pages.append(page)
        }
        while value.deletedPages!.count < 500 {
            var page = Page(); page.paper = .blank; page.geometry = PaperStyle.geometry
            value.deletedPages!.append(DeletedPage(page: page, originalIndex: 0, deletedAt: Date(),
                nextPageID: nil, previousPageID: nil))
        }
        try value.validate()
        try value.restorePage(savedID)
        XCTAssertEqual(value.pages.count, 500)
        XCTAssertEqual(value.deletedPages?.count, 500)
        XCTAssertEqual(value.pages[0], original)
        let before = value
        let ordinary = try XCTUnwrap(value.deletedPages?.last?.id)
        XCTAssertThrowsError(try value.restorePage(ordinary))
        XCTAssertEqual(value, before)
    }

    func testMissingSelectionLeavesAllCurrentAndArchivedDataUnchanged() throws {
        var (value, _, _) = try trimmed()
        let before = value
        XCTAssertThrowsError(try value.restorePage(UUID()))
        XCTAssertEqual(value, before)
    }
}
