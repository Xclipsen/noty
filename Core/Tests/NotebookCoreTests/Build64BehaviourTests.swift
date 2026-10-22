import XCTest
@testable import NotebookCore

/// Build 64 (docs/TEXT-REBUILD-62.md, „Verhalten und Objektbedienung
/// vereinheitlicht“): shared rules the editor, previews and export use alike.
final class Build64BehaviourTests: XCTestCase {
    func testOverflowUsesOneToleranceForEditorPreviewAndExport() {
        let box = TextBox(x: 10, y: 10, width: 100, height: 40, text: "Text")
        XCTAssertFalse(box.overflows(textHeight: 40))
        XCTAssertFalse(box.overflows(textHeight: 40 + TextBox.overflowTolerance))
        XCTAssertTrue(box.overflows(textHeight: 40 + TextBox.overflowTolerance + 0.01))
        XCTAssertTrue(box.overflows(textHeight: 80))
        XCTAssertFalse(box.overflows(textHeight: .nan))
        XCTAssertFalse(box.overflows(textHeight: .infinity))
    }
}
