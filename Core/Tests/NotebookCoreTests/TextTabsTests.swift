import Foundation
import XCTest
@testable import NotebookCore

final class TextTabsTests: XCTestCase {
    func testGridGrowsWithTheFontAndNeverEnds() {
        XCTAssertEqual(TextTabs.interval(fontSize: 14), 35)
        XCTAssertEqual(TextTabs.interval(fontSize: 35), 88)
        XCTAssertEqual(TextTabs.interval(fontSize: 1), 8)
        XCTAssertEqual(TextTabs.nextStop(after: 0, interval: 35), 35)
        XCTAssertEqual(TextTabs.nextStop(after: 34.9, interval: 35), 35)
        XCTAssertEqual(TextTabs.nextStop(after: 35, interval: 35), 70, "on a stop a tab still moves on")
        // Past the twelve default stops of iOS, where text used to wrap.
        XCTAssertEqual(TextTabs.nextStop(after: 400, interval: 35), 420)
    }
    func testOneGridForAWholeFieldFollowsItsLargestText() {
        var box = TextBox(x: 0, y: 0, width: 300, height: 100, text: "\tab\ncd", style: TextBoxStyle())
        box.style.fontSize = 14
        XCTAssertEqual(TextTabs.interval(box), 35)
        var large = box.style; large.fontSize = 43
        box.runs = [TextRun(location: 0, length: 1, style: box.style), TextRun(location: 1, length: 5, style: large)]
        XCTAssertEqual(TextTabs.interval(box), 108, "a tab of 14 pt at the line start has no grid of its own")
        box.runs = []
        XCTAssertEqual(TextTabs.interval(box), 35)
    }
    private func apply(_ edits: [TextListEditing.Edit], to text: String) -> String {
        let value = NSMutableString(string: text)
        for edit in edits.reversed() { value.replaceCharacters(in: edit.range, with: edit.replacement) }
        return value as String
    }
    func testSingleLineTabIsLeftToTheTextView() {
        XCTAssertNil(TextTabs.edits(in: "abc", selection: NSRange(location: 1, length: 0), outdent: false))
        XCTAssertNil(TextTabs.edits(in: "abc", selection: NSRange(location: 0, length: 2), outdent: false))
    }
    func testBackTabRemovesTheTabBeforeTheCaretThenAtTheLineStart() throws {
        let before = try XCTUnwrap(TextTabs.edits(in: "a\tb", selection: NSRange(location: 2, length: 0), outdent: true))
        XCTAssertEqual(apply(before, to: "a\tb"), "ab")
        let start = try XCTUnwrap(TextTabs.edits(in: "x\n\tab", selection: NSRange(location: 4, length: 0), outdent: true))
        XCTAssertEqual(apply(start, to: "x\n\tab"), "x\nab")
        XCTAssertNil(TextTabs.edits(in: "ab", selection: NSRange(location: 1, length: 0), outdent: true))
    }
    func testSelectionOverLinesMovesEachLineAndSkipsEmptyOnes() throws {
        let text = "eins\n\nzwei\ndrei"
        let all = NSRange(location: 1, length: 8)
        let moved = try XCTUnwrap(TextTabs.edits(in: text, selection: all, outdent: false))
        XCTAssertEqual(apply(moved, to: text), "\teins\n\n\tzwei\ndrei")
        let tabbed = "\teins\n\tzwei"
        let back = try XCTUnwrap(TextTabs.edits(in: tabbed, selection: NSRange(location: 0, length: 11), outdent: true))
        XCTAssertEqual(apply(back, to: tabbed), "eins\nzwei")
    }
    func testSelectionEndingBehindALineBreakLeavesTheNextLine() throws {
        let text = "a\nb\nc"
        let moved = try XCTUnwrap(TextTabs.edits(in: text, selection: NSRange(location: 0, length: 4), outdent: false))
        XCTAssertEqual(apply(moved, to: text), "\ta\n\tb\nc")
    }
}
