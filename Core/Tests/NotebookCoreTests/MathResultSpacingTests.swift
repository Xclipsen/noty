import Foundation
import XCTest
@testable import NotebookCore

final class MathResultSpacingTests: XCTestCase {
    private func spaced(_ before: String, _ inserted: String, tail: String = "") -> String? {
        let after = before + inserted + tail
        let caret = (before as NSString).length + (inserted as NSString).length
        guard let edit = MathResultSpacing.edit(before: before + tail, after: after, caret: caret) else { return nil }
        return (after as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }
    func testResultBehindTheSignGetsASpace() {
        XCTAssertEqual(spaced("2+3=", "5"), "2+3= 5")
        XCTAssertEqual(spaced("24 Werktage / 6 * 5 =", "20"), "24 Werktage / 6 * 5 = 20")
        XCTAssertEqual(spaced("100 / 3=", "33,33"), "100 / 3= 33,33")
        XCTAssertEqual(spaced("5-8=", "−3"), "5-8= −3")
        XCTAssertEqual(spaced("5 km in m =", "5000 m"), "5 km in m = 5000 m")
        XCTAssertEqual(spaced("Summe\n2*3=", "6"), "Summe\n2*3= 6")
        XCTAssertEqual(spaced("2+3=", "5", tail: " Euro"), "2+3= 5 Euro")
    }
    func testEverythingElseStays() {
        XCTAssertNil(spaced("2+3= ", "5"), "space already there")
        XCTAssertNil(spaced("x=", "5"), "no calculation")
        XCTAssertNil(spaced("Seite 3=", "5"), "no calculation")
        XCTAssertNil(spaced("a+1==", "2"), "comparison")
        XCTAssertNil(spaced("2+3=", "Hallo"), "no result")
        XCTAssertNil(spaced("=", "5"))
        XCTAssertNil(MathResultSpacing.edit(before: "2+3=5", after: "2+3=", caret: 4), "deleting")
        XCTAssertNil(MathResultSpacing.edit(before: "1+1=1", after: "2+3=5", caret: 5), "replaced text")
    }
}
