import Foundation
import XCTest
@testable import NotebookCore

/// ⌘A, the keyboard mode and paragraph styles work on the whole text of a
/// text document, although every page shows its own segment.
final class TextFlowRangeTests: XCTestCase {
    private let layout = TextFlowLayout(capacity: { _, box in min(10, (box.text as NSString).length) })

    private func flowing(_ text: String) throws -> Notebook {
        let document = try Notebook.textDocument(title: "Fluss")
        let first = try XCTUnwrap(document.textFlowSegments.first)
        var replacement = first.box; replacement.text = text; replacement.runs = nil
        return try document.reflowText(pageID: first.pageID, previous: first.box, replacement: replacement,
            selection: NSRange(location: (text as NSString).length, length: 0),
            pageCapacity: { _, box in min(10, (box.text as NSString).length) }).0
    }

    func testOffsetsAndPlacesRoundTripOverPages() throws {
        let document = try flowing("0123456789abcdefghijKLMNO")
        XCTAssertEqual(document.pages.count, 3)
        let second = document.textFlowSegments[1]
        XCTAssertEqual(document.textFlowOffset(boxID: second.box.id, location: 3), 13)
        XCTAssertEqual(document.textFlowPlace(at: 13), TextFlowPlace(pageID: second.pageID, boxID: second.box.id, location: 3))
        // A boundary belongs to the following text, the end to the last segment.
        XCTAssertEqual(document.textFlowPlace(at: 10)?.pageID, second.pageID)
        XCTAssertEqual(document.textFlowPlace(at: 10)?.location, 0)
        XCTAssertEqual(document.textFlowPlace(at: 25)?.pageID, document.pages[2].id)
        XCTAssertEqual(document.textFlowPlace(at: 25)?.location, 5)
    }

    func testRangePartsPerSegment() throws {
        let document = try flowing("0123456789abcdefghijKLMNO")
        let parts = document.textFlowParts(of: NSRange(location: 8, length: 14))
        let segments = document.textFlowSegments
        XCTAssertEqual(parts[segments[0].box.id], NSRange(location: 8, length: 2))
        XCTAssertEqual(parts[segments[1].box.id], NSRange(location: 0, length: 10))
        XCTAssertEqual(parts[segments[2].box.id], NSRange(location: 0, length: 2))
    }

    func testSelectAllThenDeleteEmptiesTheWholeDocument() throws {
        let document = try flowing("0123456789abcdefghijKLMNO")
        let (next, focus) = try document.editingTextFlow(range: NSRange(location: 0, length: 25), replacement: "", layout: layout)
        XCTAssertEqual(next.pages.count, 1, "emptied pages behind the caret disappear")
        XCTAssertEqual(next.textFlowContent?.text, "")
        XCTAssertEqual(focus.pageID, next.pages[0].id)
        XCTAssertEqual(focus.selection, NSRange(location: 0, length: 0))
        XCTAssertNoThrow(try next.validate())
    }

    func testTypingOverEverythingKeepsHandwritingPagesAndTheirSegments() throws {
        var document = try flowing("0123456789abcdefghijKLMNO")
        document.pages[2].drawing = Data([7])
        let (next, focus) = try document.editingTextFlow(range: NSRange(location: 0, length: 25), replacement: "neu", layout: layout)
        XCTAssertEqual(next.textFlowContent?.text, "neu")
        XCTAssertEqual(next.pages.map(\.id), document.pages.map(\.id), "the page with ink stays")
        XCTAssertEqual(next.pages[2].drawing, Data([7]))
        XCTAssertEqual(focus.pageID, next.pages[0].id)
        XCTAssertEqual(focus.selection.location, 3)
    }

    func testDeletingOverAPageChangePullsTheTextBackUp() throws {
        let document = try flowing("0123456789abcdefghijKLMNO")
        let (next, focus) = try document.editingTextFlow(range: NSRange(location: 8, length: 4), replacement: "", layout: layout)
        XCTAssertEqual(next.textFlowContent?.text, "01234567cdefghijKLMNO")
        XCTAssertEqual(next.textFlowSegments.map(\.box.text), ["01234567cd", "efghijKLMN", "O"])
        XCTAssertEqual(focus.pageID, next.pages[0].id)
        XCTAssertEqual(focus.selection.location, 8)
    }

    func testDeletingOnlyAtTheStartOfALaterPageAlsoPullsUp() throws {
        var document = try flowing("0123456789abcdefghij")
        // Page one has room again: the text of page two returns to it.
        var boxes = document.pages[0].effectiveTextBoxes; boxes[0].text = "01234"; boxes[0].runs = nil
        document.pages[0].textBoxes = boxes
        let (next, _) = try document.editingTextFlow(range: NSRange(location: 5, length: 3), replacement: "", layout: layout)
        XCTAssertEqual(next.textFlowSegments.first?.box.text, "01234defgh")
    }

    func testFormatOverAllPagesAndASplitParagraph() throws {
        let document = try flowing("0123456789abcde\nfgh")
        let (bold, _) = try document.restylingTextFlow(range: NSRange(location: 0, length: 19), layout: layout) { $0.bold = true }
        XCTAssertTrue(try XCTUnwrap(bold.textFlowContent).styleRuns.allSatisfy(\.style.bold))
        XCTAssertEqual(bold.textFlowContent?.text, document.textFlowContent?.text)
        // A paragraph split over a page change is one paragraph.
        let paragraph = try XCTUnwrap(document.textFlowParagraph(of: NSRange(location: 12, length: 0)))
        XCTAssertEqual(paragraph, NSRange(location: 0, length: 16))
        let (heading, _) = try document.restylingTextFlow(range: paragraph, layout: layout) { $0.fontSize = 22 }
        let whole = try XCTUnwrap(heading.textFlowContent)
        XCTAssertEqual(whole.style(at: 0).fontSize, 22)
        XCTAssertEqual(whole.style(at: 12).fontSize, 22, "the part on the next page")
        XCTAssertEqual(whole.style(at: 17).fontSize, TextStylePreset.body.fontSize, "the next paragraph stays")
    }

    func testReturnOnThePagesLastLineContinuesOnTheNextPage() throws {
        let document = try Notebook.textDocument(title: "Umbruch")
        let first = try XCTUnwrap(document.textFlowSegments.first)
        var replacement = first.box; replacement.text = "letzte\n"; replacement.runs = nil
        let (fitting, stays) = try document.reflowText(pageID: first.pageID, previous: first.box, replacement: replacement,
            selection: NSRange(location: 7, length: 0), trailingLineFits: { _, _ in true }, pageCapacity: { _, box in (box.text as NSString).length })
        XCTAssertEqual(fitting.pages.count, 1)
        XCTAssertEqual(stays.pageID, first.pageID)
        let draft = document.writingDraft()
        let (full, moved) = try document.reflowText(pageID: first.pageID, previous: first.box, replacement: replacement,
            selection: NSRange(location: 7, length: 0), trailingDraft: draft, trailingLineFits: { _, _ in false },
            pageCapacity: { _, box in (box.text as NSString).length })
        XCTAssertEqual(full.pages.count, 2)
        XCTAssertEqual(moved.pageID, draft.id, "the caret goes to the empty next page")
        XCTAssertEqual(moved.selection, NSRange(location: 0, length: 0))
        XCTAssertEqual(full.textFlowContent?.text, "letzte\n")
        XCTAssertNoThrow(try full.validate())
        XCTAssertEqual(full.exportedPageIDs(), [first.pageID], "the empty page is not exported")
        // Typing there continues the flow; deleting the break removes the page again.
        let empty = try XCTUnwrap(full.textFlowSegments.last)
        var typed = empty.box; typed.text = "x"; typed.runs = nil
        let (written, _) = try full.reflowText(pageID: empty.pageID, previous: empty.box, replacement: typed,
            selection: NSRange(location: 1, length: 0), pageCapacity: { _, box in (box.text as NSString).length })
        XCTAssertEqual(written.textFlowContent?.text, "letzte\nx")
    }

    func testAMultiPageDocumentStaysOneFlowThroughNotyImport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for directory in [root, outside] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        addTeardownBlock { for directory in [root, outside] { try? FileManager.default.removeItem(at: directory) } }
        let library = LibraryStore(root: root); _ = try await library.load()
        let document = try flowing("0123456789abcdefghijKLMNO")
        let url = outside.appendingPathComponent(NotyFile.fileName(for: document.title))
        _ = try BackupArchive.write(document, to: url)
        let repository = NotebookRepository(directory: root)
        let prepared = try await repository.prepareRestore(from: url)
        let result = try await NotebookImport.commit(prepared, repository: repository, library: library, parentID: nil, replacing: nil)
        let package = try await library.documentURL(id: result.id)
        let reopened = try RevisionStore(directory: package, readOnly: true).load()
        XCTAssertEqual(reopened.pages.count, 3)
        XCTAssertEqual(Set(reopened.textFlowSegments.compactMap(\.box.flowID)).count, 1)
        XCTAssertEqual(reopened.textFlowContent?.text, document.textFlowContent?.text)
    }

    func testUndoOverAPageChangeStillWorksAfterABookmark() throws {
        let document = try flowing("0123456789")
        let (grown, focus) = try document.editingTextFlow(range: NSRange(location: 10, length: 0), replacement: "abcde", layout: layout)
        XCTAssertEqual(grown.pages.count, 2)
        var history = NotebookUndoHistory()
        history.record(.textFlow, before: document, after: grown, afterFocus: focus)
        var marked = grown
        try marked.toggleBookmark(grown.pages[0].id)
        XCTAssertTrue(history.recordPages(before: grown, after: marked, undoPageID: grown.pages[0].id, redoPageID: grown.pages[0].id))
        let withoutBookmark = try XCTUnwrap(history.undo(marked))
        XCTAssertNil(withoutBookmark.notebook.pages[0].bookmarked)
        let original = try XCTUnwrap(history.undo(withoutBookmark.notebook))
        XCTAssertEqual(original.notebook.pages.count, 1)
        XCTAssertEqual(original.notebook.textFlowContent?.text, "0123456789")
    }

    func testAnEditWithAStaleRangeFails() throws {
        let document = try flowing("kurz")
        XCTAssertThrowsError(try document.editingTextFlow(range: NSRange(location: 2, length: 9), replacement: "", layout: layout))
    }
}
