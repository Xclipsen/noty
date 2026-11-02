import Foundation
import XCTest
@testable import NotebookCore

final class TextCalculatorTests: XCTestCase {
    /// The text after typing „=“ at the end of `typed`, nil when nothing happens.
    private func typed(_ typed: String) -> String? {
        let text = typed as NSString
        guard let calculation = TextCalculator.calculation(in: typed, caret: text.length) else { return nil }
        return text.replacingCharacters(in: calculation.edit.range, with: calculation.edit.replacement)
    }
    private func value(_ text: String) -> String? { TextCalculator.evaluate(text).flatMap(TextCalculator.format) }

    func testResultIsWrittenLikeTheCalculation() {
        XCTAssertEqual(typed("2+5="), "2+5=7")
        XCTAssertEqual(typed("2 + 5 ="), "2 + 5 = 7")
        XCTAssertEqual(typed("2 + 5="), "2 + 5 = 7")
        XCTAssertEqual(typed("2+5 ="), "2+5 = 7")
        XCTAssertEqual(typed("12 : 4="), "12 : 4 = 3")
        XCTAssertEqual(typed("Summe: 2+3="), "Summe: 2+3=5")
        XCTAssertEqual(typed("Summe: 2 + 3 ="), "Summe: 2 + 3 = 5")
        XCTAssertEqual(typed("erste Zeile\n7*6="), "erste Zeile\n7*6=42")
    }

    func testResultRangeNamesTheNumber() throws {
        let calculation = try XCTUnwrap(TextCalculator.calculation(in: "20/4=", caret: 5))
        XCTAssertEqual(calculation.edit.range, NSRange(location: 4, length: 1))
        XCTAssertEqual(calculation.result, NSRange(location: 5, length: 1))
        let after = ("20/4=" as NSString).replacingCharacters(in: calculation.edit.range, with: calculation.edit.replacement) as NSString
        XCTAssertEqual(after.substring(with: calculation.result), "5")
        XCTAssertEqual(TextListEditing.selection(NSRange(location: 5, length: 0), after: [calculation.edit]),
                       NSRange(location: after.length, length: 0), "the caret stands behind the result")
    }

    func testEverythingElseStaysAsTyped() {
        for text in ["=", "x=", "x = 5=", "Seite 3=", "3=", "a==", "2+=", "1/0=", "x2+3=", "2+3==", "31.12.2026=", "(2+3="] {
            XCTAssertNil(typed(text), text)
        }
        XCTAssertNil(TextCalculator.calculation(in: "2+3= steht hier", caret: 4), "not in front of existing text")
        XCTAssertNil(TextCalculator.calculation(in: "2+3", caret: 3), "no sign")
    }

    func testLabelsInFrontOfACalculationAreNotPartOfIt() {
        XCTAssertEqual(typed("3: 2+3="), "3: 2+3=5")
        XCTAssertEqual(typed("1. 2+3="), "1. 2+3=5")
        XCTAssertEqual(typed("(2) 2+3="), "(2) 2+3=5")
        XCTAssertEqual(typed("a) 2+3="), "a) 2+3=5")
        XCTAssertEqual(typed("Summe 2+3="), "Summe 2+3=5")
        XCTAssertEqual(typed("x = 2+3="), "x = 2+3=5")
    }

    func testAnExpressionWithUnknownsIsNoCalculation() {
        for text in ["2x + 3 + 4 =", "x^2+3=", "x² + 3 + 4 =", "a - 2 - 3 =", "a+b+2+3=", "sin(30+60)=", "sqrt(16)+2=", "f(x) + 2 + 3 =",
                     "5 m + 3 + 1 =", "10 € + 5 + 3 =", "x:2+3=", "2 (3+4)=", "2 2+3=", "3 + 5m ="] {
            XCTAssertNil(typed(text), text)
        }
    }

    func testArithmeticIsExact() {
        XCTAssertEqual(value("0,1+0,2"), "0,3")
        XCTAssertEqual(value("2+3*4"), "14")
        XCTAssertEqual(value("(2+3)*4"), "20")
        XCTAssertEqual(value("2^10"), "1024")
        XCTAssertEqual(value("2^-1"), "0,5")
        XCTAssertEqual(value("-2^2"), "-4")
        XCTAssertEqual(value("(-2)^2"), "4")
        XCTAssertEqual(value("2^3^2"), "512")
        XCTAssertEqual(value("2*-3"), "-6")
        XCTAssertEqual(value(".5+1"), "1,5")
        XCTAssertEqual(value("0.125*8"), "1")
        XCTAssertEqual(value("-3+1"), "-2")
        XCTAssertEqual(value("10/4"), "2,5")
        XCTAssertEqual(value("1/3"), "0,3333333333")
        XCTAssertEqual(value("24 / 6 * 5"), "20")
        XCTAssertEqual(value("28 / 12 x 5"), nil, "x is no operator")
        XCTAssertEqual(value("28 × 2 ÷ 7"), "8")
        XCTAssertNil(value("2^0,5"))
        XCTAssertNil(value("1/0"))
        XCTAssertNil(value("9^1000"), "too large to be exact")
    }

    func testPercent() {
        XCTAssertEqual(value("200+10%"), "220")
        XCTAssertEqual(value("200-10%"), "180")
        XCTAssertEqual(value("200*10%"), "20")
        XCTAssertEqual(value("50%"), "0,5")
        XCTAssertEqual(typed("200\n+10%\n="), "200\n+10%\n= 220")
        XCTAssertEqual(typed("200\n- 10 %\n="), "200\n- 10 %\n= 180")
        XCTAssertEqual(typed("200\n* 10%\n="), "200\n* 10%\n= 20")
    }

    func testNumbersInGermanAndOtherNotation() {
        XCTAssertEqual(value("1.234,5+0,5"), "1235")
        XCTAssertEqual(value("1.000.000+1"), "1000001")
        XCTAssertEqual(value("1,234.5+0.5"), "1235")
        XCTAssertEqual(value("3.14+1"), "4,14")
        XCTAssertEqual(value("1,5+1,5"), "3")
        XCTAssertNil(value("1,2,3+1"))
    }

    func testFromTopToBottom() {
        XCTAssertEqual(typed("12,50\n7,25\n3\n="), "12,50\n7,25\n3\n= 22,75")
        XCTAssertEqual(typed("100\n- 30\n---\n="), "100\n- 30\n---\n= 70")
        XCTAssertEqual(typed("2\n+3\n*4\n="), "2\n+3\n*4\n= 20", "line by line, like a calculator")
        XCTAssertEqual(typed("90\n: 3\n="), "90\n: 3\n= 30")
        XCTAssertEqual(typed("  5\n  6\n  ="), "  5\n  6\n  = 11")
        XCTAssertEqual(typed("Miete 500\nStrom 80\n-Rabatt 30\n="), "Miete 500\nStrom 80\n-Rabatt 30\n= 550")
        XCTAssertEqual(typed("2*3\n4\n="), "2*3\n4\n= 10")
    }

    func testColumnEndsAtAnEmptyLineOrPlainText() {
        XCTAssertEqual(typed("99\n\n1\n2\n="), "99\n\n1\n2\n= 3")
        XCTAssertEqual(typed("Rechnung\n1\n2\n="), "Rechnung\n1\n2\n= 3")
        XCTAssertNil(typed("5\n="), "one number is no calculation")
        XCTAssertNil(typed("Text\n="))
        XCTAssertEqual(typed("x + 3\n1\n2\n="), "x + 3\n1\n2\n= 3", "an expression is no label")
        XCTAssertEqual(typed("a - 3\n1\n2\n="), "a - 3\n1\n2\n= 3")
    }

    func testAnEarlierResultCarriesOn() {
        XCTAssertEqual(typed("1\n2\n= 3\n+ 4\n="), "1\n2\n= 3\n+ 4\n= 7")
    }

    func testCompositionAndEmojiKeepTheirOffsets() {
        XCTAssertEqual(typed("👩‍💻 2 + 3 ="), "👩‍💻 2 + 3 = 5")
    }
}
