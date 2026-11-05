import XCTest
@testable import NotebookCore

/// Hanging indent, Return carrying indentation and markers on, arrow lists
/// and the typing replacement (docs/TEXT-FIELDS.md, Nachtrag Einzug).
final class TextHangingIndentTests: XCTestCase {
    private func apply(_ edits: [TextListEditing.Edit], to text: String) -> String {
        let value = NSMutableString(string: text)
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) { value.replaceCharacters(in: edit.range, with: edit.replacement) }
        return value as String
    }
    private func caretEnd(_ text: String) -> NSRange { NSRange(location: (text as NSString).length, length: 0) }

    // MARK: Prefix

    func testPrefixRecognisesIndentationMarkersAndSeparators() throws {
        let cases: [(String, String, String?, String)] = [
            ("\t-> Ort der Lieferung", "\t", "->", " "),
            ("\t\t- Käufer", "\t\t", "-", " "),
            ("• Punkt", "", "•", " "),
            ("→  zwei Leerzeichen", "", "→", "  "),
            ("⇒\tSchluss", "", "⇒", "\t"),
            ("12. Mai", "", "12.", " "),
            ("3) drei", "", "3)", " "),
            ("(2) Absatz", "", "(2)", " "),
            ("a) erstens", "", "a)", " "),
            ("B) zweitens", "", "B)", " "),
            ("aa) Gliederung", "", "aa)", " "),
            ("(c) Buchstabe", "", "(c)", " "),
            ("☐ Aufgabe", "", "☐", " "),
            ("    Bsp.: Text", "    ", nil, ""),
            ("+ Vorteil", "", "+", " "),
            ("– Gedanke", "", "–", " "),
        ]
        for (line, indent, marker, separator) in cases {
            let prefix = try XCTUnwrap(TextParagraphPrefix(line: line), line)
            XCTAssertEqual(prefix.indent, indent, line)
            XCTAssertEqual(prefix.marker, marker, line)
            XCTAssertEqual(prefix.separator, separator, line)
        }
    }

    func testOrdinaryTextHasNoPrefix() {
        // German abbreviations, words, numbers without a space behind: text.
        for line in ["z. B. so", "i. d. R. nicht", "Bsp.: A kauft", "-5 Grad", "3.5 kg", "abc) x", "ab) x", "Aa) x", "1234567. x", "->kein Abstand", "Text", ""] {
            XCTAssertNil(TextParagraphPrefix(line: line), line)
        }
    }

    func testNextMarkerCountsOnAndEndsBehindZ() {
        func next(_ line: String) -> String? { TextParagraphPrefix(line: line)?.nextMarker }
        XCTAssertEqual(next("19. x"), "20.")
        XCTAssertEqual(next("3) x"), "4)")
        XCTAssertEqual(next("(9) x"), "(10)")
        XCTAssertEqual(next("a) x"), "b)")
        XCTAssertEqual(next("C) x"), "D)")
        XCTAssertEqual(next("bb) x"), "cc)")
        XCTAssertEqual(next("(a) x"), "(b)")
        XCTAssertNil(next("z) x"))
        XCTAssertEqual(next("☑ x"), "☐")
        XCTAssertEqual(next("-> x"), "->")
        XCTAssertNil(next("\tx"))
    }

    // MARK: Hanging indent

    /// Every character 10 wide, tabs on a 35 grid.
    private func bodyStart(_ text: String, indent: Double = 0, width: Double = 400) -> Double? {
        TextHangingIndent.bodyStart(in: text as NSString, paragraphStart: 0, firstLineIndent: indent, tabInterval: 35, width: width) { Double($0.length) * 10 }
    }

    func testWrappedLinesStartUnderTheTextBehindThePrefix() {
        XCTAssertEqual(bodyStart("\t-> Ort der bewegten Lieferung ist dort"), 35 + 30)
        XCTAssertEqual(bodyStart("\t\t- Käufer oder Verkäufer"), 70 + 20)
        XCTAssertEqual(bodyStart("• Punkt"), 20)
        XCTAssertEqual(bodyStart("\tBsp.: A kauft"), 35, "indentation alone hangs at the indentation")
        XCTAssertEqual(bodyStart("a)\tText"), 35, "a tab behind the marker runs to the next stop")
        XCTAssertEqual(bodyStart("- Text", indent: 20), 40, "the paragraph indent counts")
        XCTAssertEqual(bodyStart("\tText", indent: 20), 35, "a tab from the indent runs to the next stop of the grid")
        XCTAssertEqual(bodyStart("\tText", indent: 35), 70, "also exactly on a stop")
    }

    func testNoHangingIndentWithoutPrefixTextOrRoom() {
        XCTAssertNil(bodyStart("Normaler Absatz"))
        XCTAssertNil(bodyStart("- "), "nothing behind the marker")
        XCTAssertNil(bodyStart("\t\t"), "white space only")
        XCTAssertNil(bodyStart("\t\t\t\t\t\t- Text", width: 400), "prefix beyond half the width")
        XCTAssertEqual(bodyStart("\t\t\t\t\t- Text", width: 400), 195)
        XCTAssertNil(bodyStart("- Text", width: 30))
    }

    func testHangingIndentReadsOnlyItsOwnParagraph() {
        let text = "Erster Absatz\n\t- zweiter\nText" as NSString
        let second = TextHangingIndent.bodyStart(in: text, paragraphStart: 14, firstLineIndent: 0, tabInterval: 35, width: 400) { Double($0.length) * 10 }
        XCTAssertEqual(second, 55)
        XCTAssertNil(TextHangingIndent.bodyStart(in: text, paragraphStart: 0, firstLineIndent: 0, tabInterval: 35, width: 400) { _ in 10 })
        // Measured ranges never reach into the text or the next paragraph.
        var ranges: [NSRange] = []
        _ = TextHangingIndent.bodyStart(in: text, paragraphStart: 14, firstLineIndent: 0, tabInterval: 35, width: 400) { ranges.append($0); return 0 }
        XCTAssertEqual(ranges, [NSRange(location: 15, length: 2)])
    }

    // MARK: Return

    func testReturnCarriesIndentationAndMarker() {
        for (line, expected) in [("\t-> Ort", "\n\t-> "), ("\t\t- Käufer", "\n\t\t- "), ("→ Folge", "\n→ "), ("a) eins", "\nb) "),
                                 ("(1) Abs", "\n(2) "), ("•\tTab", "\n•\t"), ("3) drei", "\n4) "), ("z) Ende", "\n")] {
            XCTAssertEqual(TextListEditing.newline(in: line, range: caretEnd(line))?.replacement, expected, line)
        }
    }

    func testReturnInIndentedParagraphKeepsItsIndentation() throws {
        let text = "\tBsp.: A kauft"
        XCTAssertNil(TextListEditing.newline(in: text, range: caretEnd(text)), "no marker: not a list")
        XCTAssertEqual(TextListEditing.indentedNewline(in: text, range: caretEnd(text)), .init(range: caretEnd(text), replacement: "\n\t"))
        XCTAssertEqual(TextListEditing.indentedNewline(in: "  zwei", range: NSRange(location: 4, length: 0))?.replacement, "\n  ")
        XCTAssertNil(TextListEditing.indentedNewline(in: "ohne Einzug", range: NSRange(location: 4, length: 0)))
        XCTAssertNil(TextListEditing.indentedNewline(in: "\tText", range: NSRange(location: 1, length: 0)), "caret at the text start: a plain break")
        XCTAssertNil(TextListEditing.indentedNewline(in: "\tText", range: NSRange(location: 0, length: 0)))
        // A selection is replaced by the break.
        let selected = try XCTUnwrap(TextListEditing.indentedNewline(in: "\tab cd", range: NSRange(location: 3, length: 2)))
        XCTAssertEqual(apply([selected], to: "\tab cd"), "\tab\n\td")
    }

    func testReturnOnEmptyLineMovesOutOneStep() throws {
        // White space only: one tab, then the spaces (at most four) go.
        var text = "Text\n\t\t"
        for expected in ["Text\n\t", "Text\n"] {
            let edit = try XCTUnwrap(TextListEditing.indentedNewline(in: text, range: caretEnd(text)))
            text = apply([edit], to: text)
            XCTAssertEqual(text, expected)
        }
        XCTAssertNil(TextListEditing.indentedNewline(in: text, range: caretEnd(text)), "nothing left: a plain break")
        XCTAssertEqual(apply([TextListEditing.indentedNewline(in: "      ", range: caretEnd("      "))!], to: "      "), "  ")
        // An empty item moves out one step and keeps its marker; the caret stays behind it.
        var item = "x\n\t\t- "
        for expected in ["x\n\t- ", "x\n- ", "x\n"] {
            let edit = try XCTUnwrap(TextListEditing.newline(in: item, range: caretEnd(item)))
            XCTAssertFalse(edit.replacement.hasPrefix("\n"))
            item = apply([edit], to: item)
            XCTAssertEqual(item, expected)
            XCTAssertEqual(NSMaxRange(TextListEditing.selection(caretEnd(item), after: [])), (item as NSString).length)
        }
        let arrow = try XCTUnwrap(TextListEditing.newline(in: "\t-> ", range: caretEnd("\t-> ")))
        XCTAssertEqual(arrow, .init(range: NSRange(location: 0, length: 4), replacement: "-> "))
    }

    func testEmptyLineWithTextBehindCaretIsAPlainBreak() {
        XCTAssertNil(TextListEditing.indentedNewline(in: "\t\tText", range: NSRange(location: 1, length: 0)))
        XCTAssertNil(TextListEditing.indentedNewline(in: "\t\t", range: NSRange(location: 1, length: 0)))
    }

    // MARK: Arrow list

    func testArrowListToggleContinuationAndNesting() {
        let toggled = TextListEditing.toggle(.arrow, in: "eins\nzwei", range: NSRange(location: 0, length: 9))
        XCTAssertEqual(apply(toggled, to: "eins\nzwei"), "→ eins\n→ zwei")
        XCTAssertTrue(TextListEditing.isActive(.arrow, in: "→ eins\n-> zwei", range: NSRange(location: 0, length: 12)))
        XCTAssertFalse(TextListEditing.isActive(.bullet, in: "→ eins", range: NSRange(location: 0, length: 0)))
        let removed = TextListEditing.toggle(.arrow, in: "→ eins\n=> zwei", range: NSRange(location: 0, length: 13))
        XCTAssertEqual(apply(removed, to: "→ eins\n=> zwei"), "eins\nzwei")
        XCTAssertEqual(apply(TextListEditing.toggle(.bullet, in: "→ eins", range: NSRange(location: 2, length: 0)), to: "→ eins"), "• eins")
        // Tab nests an arrow item like any list item; the arrow stays.
        let box = TextBox(x: 0, y: 0, width: 300, height: 40, text: "→ eins")
        let plan = box.listNesting(selection: NSRange(location: 3, length: 0), outdent: false)
        XCTAssertEqual(plan?.indents, [TextPlacement.indentStep])
        XCTAssertEqual(plan?.markers, [])
    }

    func testArrowItemsDoNotChangeNumbering() {
        let text = "1. eins\n→ Folge\n2. zwei"
        XCTAssertEqual(TextListEditing.normalize(text, level: { _ in 0 }, changed: NSRange(location: 8, length: 7)), [])
        XCTAssertNil(TextListEditing.autoList(in: "-> ", caret: 3), "an arrow typed stays as typed")
    }

    // MARK: Typing replacement

    private func typed(_ text: String) -> String {
        var value = ""
        for character in text {
            value.append(character)
            if let replacement = TextSymbolReplacement.replacement(in: value, caret: (value as NSString).length) {
                value = apply([replacement.edit], to: value)
            }
        }
        return value
    }

    func testArrowsAndSignsReplaceWhileTyping() {
        XCTAssertEqual(typed("A -> B"), "A → B")
        XCTAssertEqual(typed("A => B"), "A ⇒ B")
        XCTAssertEqual(typed("A <- B"), "A ← B")
        XCTAssertEqual(typed("A <-> B"), "A ↔ B")
        XCTAssertEqual(typed("A <=> B"), "A ⇔ B")
        XCTAssertEqual(typed("x <= 3, y >= 4, z != 5, π ~= 3,14, 5 +- 1"), "x ≤ 3, y ≥ 4, z ≠ 5, π ≈ 3,14, 5 ± 1")
        XCTAssertEqual(typed("\t-> Ort"), "\t→ Ort")
        XCTAssertEqual(typed("a - b = c > d"), "a - b = c > d", "single signs stay")
    }

    func testBackspaceBehindASymbolBringsBackWhatWasTyped() throws {
        let replacement = try XCTUnwrap(TextSymbolReplacement.replacement(in: "A ->", caret: 4))
        XCTAssertEqual(replacement.edit, .init(range: NSRange(location: 2, length: 2), replacement: "→"))
        let after = apply([replacement.edit], to: "A ->")
        let back = try XCTUnwrap(TextSymbolReplacement.reverting(replacement, in: after, caret: 3))
        XCTAssertEqual(apply([back], to: after), "A ->")
        XCTAssertNil(TextSymbolReplacement.reverting(replacement, in: after, caret: 2), "caret elsewhere")
        XCTAssertNil(TextSymbolReplacement.reverting(replacement, in: "A x", caret: 3), "symbol gone")
        // The chained arrow comes back as typed.
        let chained = try XCTUnwrap(TextSymbolReplacement.replacement(in: "←>", caret: 2))
        XCTAssertEqual(chained.typed, "<->")
        XCTAssertEqual(apply([TextSymbolReplacement.reverting(chained, in: "↔", caret: 1)!], to: "↔"), "<->")
    }

    func testReplacementKeepsCalculatorSigns() {
        // „=“ alone and „=“ after a number stay for the calculator.
        XCTAssertNil(TextSymbolReplacement.replacement(in: "2+3=", caret: 4))
        XCTAssertNil(TextSymbolReplacement.replacement(in: "=", caret: 1))
        // The calculator does not compute behind the replaced signs.
        for text in ["2 <=", "2 >=", "2 !=", "2 ~="] {
            XCTAssertNil(TextCalculator.calculation(in: text, caret: (text as NSString).length), text)
        }
    }
}
