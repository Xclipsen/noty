import Foundation
import XCTest
@testable import NotebookCore

final class NotebookDefaultsTests: XCTestCase {
    func testNewStandardPagesAndDraftFollowChangedDefaultWithoutTouchingWrittenPages() throws {
        var appearance = NotebookAppearance(); appearance.paper = .lined; appearance.color = .white; appearance.cover = .green
        var notebook = try Notebook.blank(title: "Mathe", appearance: appearance)
        notebook.pages[0].textBoxes = [TextBox(x: 40, y: 40, width: 300, height: 40, text: "Aufgabe 1")]
        let written = notebook.pages[0].id
        try notebook.setPageDefaults(paper: .grid, color: .dark, alsoEmptyPages: [written])
        XCTAssertEqual(notebook.appearance?.paper, .grid); XCTAssertEqual(notebook.appearance?.color, .dark)
        XCTAssertEqual(notebook.appearance?.cover, .green)
        XCTAssertEqual(notebook.pages[0].paperColor, .white, "written page keeps its colour")
        let draft = notebook.writingDraft()
        XCTAssertEqual(draft.paper, .grid); XCTAssertEqual(draft.paperColor, .dark)
        let id = try notebook.insertPaper(notebook.appearance!.paper, color: notebook.appearance!.color, at: 1)
        XCTAssertEqual(notebook.pages.first { $0.id == id }?.paperColor, .dark)
    }

    func testEmptyListedPaperPagesSwitchAlongAndLegacyNotebookKeepsPreview() throws {
        var notebook = Notebook.blank(title: "Alt")
        notebook = try notebook.preparedForPageEditing()
        _ = try notebook.insertPaper(.lined, color: .white, at: 1)
        let empty = notebook.pages[1].id
        XCTAssertNil(notebook.appearance)
        let changed = try notebook.setPageDefaults(paper: .lined, color: .dark, alsoEmptyPages: [empty])
        XCTAssertEqual(changed, 1)
        XCTAssertEqual(notebook.pages[1].paperColor, .dark)
        XCTAssertEqual(notebook.appearance?.coverEnabled, false, "library preview stays the first page")
        XCTAssertGreaterThanOrEqual(notebook.schemaVersion, 7)
        XCTAssertNoThrow(try notebook.validate())
        XCTAssertThrowsError(try notebook.setPageDefaults(paper: .legacyTest, color: .dark))
    }
}
