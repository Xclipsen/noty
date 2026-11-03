import XCTest
@testable import NotebookCore

final class TextTypingTests: XCTestCase {
    private func pairing(_ typed: String, _ text: String, at caret: Int) -> TextTyping.Pairing? {
        TextTyping.pairing(typed, in: text as NSString, at: caret)
    }

    func testOpeningClosesNextToNoWord() {
        for open in ["(", "[", "{"] {
            XCTAssertEqual(pairing(open, "", at: 0)?.advance, 1, open)
            XCTAssertEqual(pairing(open, " b", at: 0)?.insert.count, 2, open)
            XCTAssertNil(pairing(open, "b", at: 0), "a word behind: \(open)")
        }
        XCTAssertEqual(pairing("(", "a b", at: 1)?.insert, "()", "a word in front does not count for brackets")
        XCTAssertEqual(pairing("(", "_b", at: 0)?.insert, "()", "`_` is no word character here, as in Helix")
    }
    func testQuotesNeedNoWordOnEitherSide() {
        for quote in ["\"", "'"] {
            XCTAssertEqual(pairing(quote, "", at: 0)?.insert, quote + quote)
            XCTAssertNil(pairing(quote, "a", at: 1), "after a word, like `don't`")
            XCTAssertNil(pairing(quote, "a", at: 0))
            XCTAssertNil(pairing(quote, "ä", at: 1), "Umlaute are word characters")
            XCTAssertEqual(pairing(quote, "_", at: 1)?.insert, quote + quote)
        }
    }
    func testClosingStepsOverItsHalf() {
        XCTAssertEqual(pairing(")", "()", at: 1), .init(insert: "", advance: 1))
        XCTAssertEqual(pairing("\"", "\"\"", at: 1), .init(insert: "", advance: 1))
        XCTAssertNil(pairing(")", "(a", at: 2))
        XCTAssertNil(pairing("]", "()", at: 1))
    }
    func testOnlyTheseCharactersCount() {
        for other in ["<", "`", "“", "„", "a", "ab", "()", "\n", ""] { XCTAssertNil(pairing(other, "", at: 0), other) }
    }
    func testBackspaceTakesAnEmptyPair() {
        XCTAssertEqual(TextTyping.pairDeletion(in: "()", at: 1), NSRange(location: 0, length: 2))
        XCTAssertEqual(TextTyping.pairDeletion(in: "x\"\"y", at: 2), NSRange(location: 1, length: 2))
        XCTAssertNil(TextTyping.pairDeletion(in: "(]", at: 1))
        XCTAssertNil(TextTyping.pairDeletion(in: "(a)", at: 1))
        XCTAssertNil(TextTyping.pairDeletion(in: "()", at: 0))
        XCTAssertNil(TextTyping.pairDeletion(in: "()", at: 2))
    }

    private func newline(_ text: String, at caret: Int, length: Int = 0) -> String? {
        TextTyping.newline(in: text, range: NSRange(location: caret, length: length)).map { edit in
            (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        }
    }
    func testANewLineKeepsTheIndent() {
        XCTAssertEqual(newline("  ab", at: 4), "  ab\n  ")
        XCTAssertEqual(newline("\tab", at: 3), "\tab\n\t")
        XCTAssertEqual(newline("  ab cd", at: 4), "  ab\n   cd", "only white space in front of the caret goes")
        XCTAssertEqual(newline("  ab  ", at: 6), "  ab\n  ")
        XCTAssertEqual(newline("  ab", at: 2), "\n  ab", "in the indent itself the line moves down")
        XCTAssertEqual(newline("  ", at: 2), "\n  ")
        XCTAssertEqual(newline("  ab cd", at: 3, length: 2), "  a\n  cd", "a selection goes")
    }
    func testAnUnindentedLineStaysNative() {
        XCTAssertNil(newline("ab", at: 2))
        XCTAssertNil(newline("ab  ", at: 4))
        XCTAssertNil(newline("", at: 0))
        XCTAssertNil(newline("ab", at: 9))
    }
    func testTheCaretEndsBehindTheReplacement() throws {
        let edit = try XCTUnwrap(TextTyping.newline(in: "  ab", range: NSRange(location: 2, length: 0)))
        XCTAssertEqual(edit.range.location + (edit.replacement as NSString).length, 3)
    }
}
