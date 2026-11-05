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
    // Tab/⇧Tab over lines: `TextIndentTests` (TextIndentEditing.tab), which
    // replaced `TextTabs.edits` (⇧Tab no longer deletes a tab inside a line).
}
