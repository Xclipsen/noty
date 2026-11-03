import XCTest
@testable import NotebookCore

final class LawMarkEditingTests: XCTestCase {
    private let yellow = "#F3CC37", green = "#59E659", blue = "#59BFFF"
    private func ids() -> () -> String {
        var n = 0
        return { n += 1; return "new-\(n)" }
    }
    private func mark(_ id: String, _ start: Int, _ end: Int, _ color: String? = "#F3CC37", section: String = "s1", fixed: Bool = false) -> LawMarkRange {
        LawMarkRange(id: id, sectionId: section, start: start, end: end, color: color, fixed: fixed)
    }
    private func plan(_ edit: LawMarkEdit, _ existing: [LawMarkRange], length: Int = 10_000) throws -> LawMarkPlan {
        try LawMarkEditing.plan(edit, existing: existing, sectionId: "s1", textLength: length, newID: ids())
    }
    /// The visible result as sorted (start, end, colour) triples.
    private func shape(_ marks: [LawMarkRange]) -> [String] {
        marks.filter { $0.sectionId == "s1" }.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
            .map { "\($0.start)-\($0.end) \(LawMarkEditing.colorKey($0.color))" }
    }
    private func after(_ edit: LawMarkEdit, _ existing: [LawMarkRange]) throws -> [String] {
        shape(LawMarkEditing.apply(try plan(edit, existing), to: existing))
    }

    func testAddToEmptySectionCreatesOneMarkWithNewID() throws {
        let result = try plan(.add(start: 3, end: 9, color: yellow), [])
        XCTAssertEqual(result.deletions, [])
        XCTAssertEqual(result.additions, [mark("new-1", 3, 9)])
    }
    func testExactDuplicateAndContainedSameColourDoNothing() throws {
        let existing = [mark("a", 2, 10)]
        XCTAssertTrue(try plan(.add(start: 2, end: 10, color: yellow), existing).isEmpty)
        XCTAssertTrue(try plan(.add(start: 4, end: 6, color: "#f3cc37"), existing).isEmpty)
        // nil and the earlier app yellow are the same colour.
        XCTAssertTrue(try plan(.add(start: 4, end: 6, color: nil), existing).isEmpty)
        XCTAssertTrue(try plan(.add(start: 4, end: 6, color: "#FFFF00"), existing).isEmpty)
    }
    func testSameColourOverlappingAndAdjacentMerge() throws {
        let existing = [mark("a", 0, 5), mark("b", 10, 15)]
        let overlap = try plan(.add(start: 3, end: 8, color: yellow), existing)
        XCTAssertEqual(Set(overlap.deletedIDs), ["a"])
        XCTAssertEqual(shape(overlap.additions), ["0-8 \(yellow)"])
        // Adjacent on both sides: one mark from 0 to 15.
        let bridge = try plan(.add(start: 5, end: 10, color: yellow), existing)
        XCTAssertEqual(Set(bridge.deletedIDs), ["a", "b"])
        XCTAssertEqual(shape(bridge.additions), ["0-15 \(yellow)"])
    }
    func testMergeIsTransitive() throws {
        let existing = [mark("a", 0, 4), mark("b", 6, 9), mark("c", 9, 12), mark("d", 20, 22)]
        XCTAssertEqual(try after(.add(start: 3, end: 7, color: yellow), existing), ["0-12 \(yellow)", "20-22 \(yellow)"])
    }
    func testOtherColourGivesWayAndIsSplit() throws {
        let existing = [mark("g", 0, 20, green)]
        let result = try plan(.add(start: 5, end: 10, color: yellow), existing)
        XCTAssertEqual(result.deletedIDs, ["g"])
        XCTAssertEqual(shape(result.additions), ["0-5 \(green)", "5-10 \(yellow)", "10-20 \(green)"])
        // Fully covered: only the new colour remains.
        XCTAssertEqual(try after(.add(start: 0, end: 30, color: yellow), existing), ["0-30 \(yellow)"])
        // Overlapping one end.
        XCTAssertEqual(try after(.add(start: 15, end: 25, color: blue), existing), ["0-15 \(green)", "15-25 \(blue)"])
    }
    func testNewColourWinsOverDifferentColourEvenWhenSameColourMerges() throws {
        let existing = [mark("y", 0, 10), mark("g", 10, 20, green)]
        XCTAssertEqual(try after(.add(start: 8, end: 14, color: yellow), existing), ["0-14 \(yellow)", "14-20 \(green)"])
        // A sub-range of a yellow mark with a green mark on top is not a duplicate.
        let legacy = [mark("y", 0, 10), mark("g", 4, 6, green)]
        XCTAssertEqual(try after(.add(start: 2, end: 8, color: yellow), legacy), ["0-10 \(yellow)"])
    }
    func testRemovePartSplitsAndRemoveAllDeletes() throws {
        let existing = [mark("a", 0, 10), mark("b", 12, 20, green)]
        let middle = try plan(.remove(start: 3, end: 6), existing)
        XCTAssertEqual(middle.deletedIDs, ["a"])
        XCTAssertEqual(shape(middle.additions), ["0-3 \(yellow)", "6-10 \(yellow)"])
        XCTAssertEqual(try after(.remove(start: 5, end: 15), existing), ["0-5 \(yellow)", "15-20 \(green)"])
        XCTAssertEqual(try after(.remove(start: 0, end: 30), existing), [])
        XCTAssertTrue(try plan(.remove(start: 10, end: 12), existing).isEmpty)
    }
    func testRemoveMarksAndOtherSectionsUntouched() throws {
        let existing = [mark("a", 0, 10), mark("x", 0, 10, section: "s2")]
        XCTAssertEqual(try plan(.removeMarks(["a", "x", "missing"]), existing).deletedIDs, ["a"])
        let added = try plan(.add(start: 0, end: 10, color: green), existing)
        XCTAssertFalse(added.deletedIDs.contains("x"))
        XCTAssertTrue(added.additions.allSatisfy { $0.sectionId == "s1" })
    }
    func testFixedPDFMarksAreNeverMergedOrSplit() throws {
        let existing = [mark("p", 5, 15, fixed: true)]
        // Adding the same colour over it creates its own text mark.
        let add = try plan(.add(start: 0, end: 10, color: yellow), existing)
        XCTAssertEqual(add.deletedIDs, [])
        XCTAssertEqual(shape(add.additions), ["0-10 \(yellow)"])
        // Removing part of it deletes it whole.
        let remove = try plan(.remove(start: 7, end: 8), existing)
        XCTAssertEqual(remove.deletedIDs, ["p"])
        XCTAssertEqual(remove.additions, [])
        // Recolouring keeps bounds and the fixed kind.
        let recolor = try plan(.recolor(["p"], color: green), existing)
        XCTAssertEqual(recolor.deletedIDs, ["p"])
        XCTAssertEqual(recolor.additions, [mark("new-1", 5, 15, green, fixed: true)])
        XCTAssertThrowsError(try plan(.resize("p", start: 0, end: 20), existing))
    }
    func testRecolorDeletesAndRecreatesWithNewIDAndMerges() throws {
        let existing = [mark("a", 0, 5), mark("g", 5, 9, green), mark("b", 20, 25)]
        let result = try plan(.recolor(["g"], color: yellow), existing)
        XCTAssertEqual(Set(result.deletedIDs), ["a", "g"])
        XCTAssertEqual(shape(result.additions), ["0-9 \(yellow)"])
        XCTAssertFalse(result.additions.contains { $0.id == "g" || $0.id == "a" })
        XCTAssertTrue(try plan(.recolor(["a"], color: "#f3cc37"), existing).isEmpty)
        // Several marks at once: the second step sees the first's result.
        XCTAssertEqual(try after(.recolor(["a", "b"], color: blue), existing), ["0-5 \(blue)", "5-9 \(green)", "20-25 \(blue)"])
        XCTAssertEqual(try after(.recolor(["a", "g"], color: blue), existing), ["0-9 \(blue)", "20-25 \(yellow)"])
    }
    func testResizeReplacesTheMarkKeepingItsColour() throws {
        let existing = [mark("g", 5, 10, green), mark("y", 12, 14)]
        XCTAssertEqual(try after(.resize("g", start: 6, end: 8), existing), ["6-8 \(green)", "12-14 \(yellow)"])
        XCTAssertEqual(try after(.resize("g", start: 0, end: 13), existing), ["0-13 \(green)", "13-14 \(yellow)"])
        XCTAssertTrue(try plan(.resize("g", start: 5, end: 10), existing).isEmpty)
        XCTAssertThrowsError(try plan(.resize("missing", start: 0, end: 3), existing)) { XCTAssertEqual($0 as? LawMarkError, .unknownMark) }
    }
    func testLimitsAndInvalidRanges() throws {
        XCTAssertThrowsError(try plan(.add(start: 0, end: 4001, color: yellow), [])) { XCTAssertEqual($0 as? LawMarkError, .tooLong(4001)) }
        XCTAssertNoThrow(try plan(.add(start: 0, end: 4000, color: yellow), []))
        XCTAssertThrowsError(try plan(.add(start: 5, end: 5, color: yellow), [])) { XCTAssertEqual($0 as? LawMarkError, .invalidRange) }
        XCTAssertThrowsError(try plan(.add(start: -1, end: 5, color: yellow), []))
        XCTAssertThrowsError(try plan(.add(start: 0, end: 11, color: yellow), [], length: 10))
        // Removing may cover more than the mark limit.
        XCTAssertNoThrow(try plan(.remove(start: 0, end: 9000), []))
    }
    func testMergeBeyondLimitIsStoredAsAdjoiningPieces() throws {
        let existing = [mark("a", 0, 3000), mark("b", 3500, 6000)]
        let result = try plan(.add(start: 2900, end: 3600, color: yellow), existing)
        XCTAssertEqual(Set(result.deletedIDs), ["a", "b"])
        XCTAssertEqual(shape(result.additions), ["0-4000 \(yellow)", "4000-6000 \(yellow)"])
        XCTAssertTrue(result.additions.allSatisfy { $0.length <= LawMarkEditing.maxLength })
    }
    func testInverseRestoresTheShapeWithFreshIDs() throws {
        let existing = [mark("a", 0, 10), mark("g", 12, 20, green)]
        for edit: LawMarkEdit in [.add(start: 5, end: 15, color: blue), .remove(start: 3, end: 14), .recolor(["g"], color: yellow), .removeMarks(["a"]), .resize("a", start: 1, end: 2)] {
            let forward = try plan(edit, existing)
            let changed = LawMarkEditing.apply(forward, to: existing)
            var n = 0
            let back = forward.inverse { n += 1; return "undo-\(n)" }
            XCTAssertEqual(Set(back.deletedIDs), Set(forward.additions.map(\.id)))
            XCTAssertTrue(back.additions.allSatisfy { $0.id.hasPrefix("undo-") }, "\(edit)")
            let restored = LawMarkEditing.apply(back, to: changed)
            XCTAssertEqual(shape(restored), shape(existing), "\(edit)")
            // Redo = inverse of the undo, again with new IDs.
            let redo = back.inverse { "redo-\(UUID())" }
            XCTAssertEqual(shape(LawMarkEditing.apply(redo, to: restored)), shape(changed), "\(edit)")
        }
        XCTAssertNotEqual(LawMarkEditing.newID(), LawMarkEditing.newID())
    }
    func testNewIDsAreLowerCaseUUIDs() {
        let id = LawMarkEditing.newID()
        XCTAssertNotNil(UUID(uuidString: id))
        XCTAssertEqual(id, id.lowercased())
    }
    func testThenCancelsMarksCreatedAndDeletedAgain() {
        let first = LawMarkPlan(deletions: [mark("a", 0, 5)], additions: [mark("n1", 0, 9), mark("n2", 20, 21)])
        let second = LawMarkPlan(deletions: [mark("n1", 0, 9), mark("b", 30, 31)], additions: [mark("n3", 0, 12)])
        let both = first.then(second)
        XCTAssertEqual(both.deletedIDs, ["a", "b"])
        XCTAssertEqual(both.additions.map(\.id), ["n2", "n3"])
    }
    func testAnchorForRangeUsesCanonicalQuote() {
        let canonical = LawTextAnchor.canonical("(1) Der Kaufmann – haftet.")
        let anchor = LawMarkEditing.anchor(for: mark("a", 4, 12), canonical: canonical)
        XCTAssertEqual(anchor, LawAnchor(sectionId: "s1", start: 4, end: 12, quote: "kaufmann"))
        XCTAssertNil(LawMarkEditing.anchor(for: mark("a", 4, 99), canonical: canonical))
        // Round trip through the original text mapping.
        let range = LawTextAnchor.originalRange(text: "(1) Der Kaufmann – haftet.", anchor: anchor!)
        XCTAssertEqual(range, NSRange(location: 8, length: 8))
    }
    func testTouching() {
        let marks = [mark("a", 0, 5), mark("b", 5, 9), mark("x", 0, 9, section: "s2")]
        XCTAssertEqual(LawMarkEditing.touching(4, 6, in: marks, sectionId: "s1").map(\.id), ["a", "b"])
        XCTAssertEqual(LawMarkEditing.touching(5, 6, in: marks, sectionId: "s1").map(\.id), ["b"])
    }

    // MARK: Words

    func testWordRangeWidensToWholeWords() {
        let text = "Der Kaufmann haftet für Schäden."
        let ns = text as NSString
        XCTAssertEqual(LawMarkEditing.wordRange(in: text, covering: NSRange(location: 6, length: 9)).map(ns.substring), "Kaufmann haftet")
        XCTAssertEqual(LawMarkEditing.wordRange(in: text, covering: NSRange(location: 25, length: 1)).map(ns.substring), "Schäden")
        XCTAssertNil(LawMarkEditing.wordRange(in: text, covering: NSRange(location: 3, length: 1)))
        XCTAssertEqual(LawMarkEditing.word(in: text, at: 5).map(ns.substring), "Kaufmann")
        // At the end of a word (caret after it) the word still counts.
        XCTAssertEqual(LawMarkEditing.word(in: text, at: 12).map(ns.substring), "Kaufmann")
        XCTAssertNil(LawMarkEditing.word(in: "  ", at: 1))
    }
    func testWordRangeKeepsSurrogatePairsAndCombiningMarksWhole() {
        let text = "Wert 𝔄𝔅 und Cafe\u{301} hier"
        let ns = text as NSString
        let start = ns.range(of: "𝔄", options: .literal).location
        let word = LawMarkEditing.wordRange(in: text, covering: NSRange(location: start + 1, length: 1))
        if let word { XCTAssertEqual(ns.substring(with: word), "𝔄𝔅") }
        let cafe = ns.range(of: "Cafe", options: .literal).location
        XCTAssertEqual(LawMarkEditing.word(in: text, at: cafe + 1).map(ns.substring), "Cafe\u{301}")
        // Paragraph numbers are words as well.
        XCTAssertEqual(LawMarkEditing.word(in: "(12) Satz", at: 2), NSRange(location: 1, length: 2))
    }
    func testWordRangeFromGivenWords() {
        let words = [NSRange(location: 0, length: 3), NSRange(location: 4, length: 8), NSRange(location: 13, length: 6)]
        XCTAssertEqual(LawMarkEditing.wordRange(covering: NSRange(location: 2, length: 3), words: words), NSRange(location: 0, length: 12))
        XCTAssertNil(LawMarkEditing.wordRange(covering: NSRange(location: 3, length: 1), words: words))
        XCTAssertEqual(LawMarkEditing.word(at: 12, words: words), NSRange(location: 4, length: 8))
        XCTAssertEqual(LawMarkEditing.word(at: 13, words: words), NSRange(location: 13, length: 6))
        XCTAssertNil(LawMarkEditing.word(at: 30, words: words))
        // Words cut by the search window are not reported half.
        let long = String(repeating: "a", count: 200) + " Ende"
        XCTAssertEqual(LawMarkEditing.word(in: long, at: 202), NSRange(location: 201, length: 4))
    }
    func testPencilStaysOnItsLine() {
        XCTAssertFalse(LawPencilLine.leaves(boundMidY: 100, lineHeight: 20, y: 111))
        XCTAssertFalse(LawPencilLine.leaves(boundMidY: 100, lineHeight: 20, y: 88))
        XCTAssertTrue(LawPencilLine.leaves(boundMidY: 100, lineHeight: 20, y: 113))
        XCTAssertTrue(LawPencilLine.leaves(boundMidY: 100, lineHeight: 20, y: 120))
        XCTAssertFalse(LawPencilLine.leaves(boundMidY: 100, lineHeight: 0, y: 500))
    }

    // MARK: PDF

    private func section(_ id: String, _ text: String, page: Int?, top: Double = 0) -> LawSection {
        LawSection(id: id, label: id, keys: [id], title: "", text: text, html: nil, notes: "", pdf: page.map { .init(page: $0, top: top) })
    }
    /// One glyph per UTF-16 unit; lines of 0.02 height, characters 0.01 wide.
    private func layout(_ lines: [String], top: Double = 0.1) -> LawPDFTextLayout {
        var glyphs: [LawPDFGlyph] = []
        for (row, line) in lines.enumerated() {
            for (column, unit) in Array(line.utf16).enumerated() {
                glyphs.append(LawPDFGlyph(unit: unit, x: 0.1 + Double(column) * 0.01, y: top + Double(row) * 0.03, width: 0.01, height: 0.02))
            }
            glyphs.append(LawPDFGlyph(unit: 32, x: 0, y: 0, width: 0, height: 0))
        }
        return LawPDFTextLayout(glyphs: glyphs, aspectRatio: 1.414)
    }
    func testUniqueIndexAndSectionCoverage() {
        XCTAssertEqual(LawPDFAnchoring.uniqueIndex("abcabc", "bca"), 1)
        XCTAssertEqual(LawPDFAnchoring.uniqueIndex("abcabc", "abc"), -1)
        XCTAssertEqual(LawPDFAnchoring.uniqueIndex("abc", ""), -1)
        let sections = [section("a", "x", page: 2, top: 0.5), section("b", "y", page: 3, top: 0.2), section("c", "z", page: nil), section("d", "w", page: 5)]
        XCTAssertTrue(LawPDFAnchoring.sectionCovers(sections, index: 0, page: 2, top: 0.6, bottom: 0.7))
        XCTAssertFalse(LawPDFAnchoring.sectionCovers(sections, index: 0, page: 2, top: 0.4, bottom: 0.7))
        XCTAssertTrue(LawPDFAnchoring.sectionCovers(sections, index: 0, page: 3, top: 0.0, bottom: 0.1))
        XCTAssertFalse(LawPDFAnchoring.sectionCovers(sections, index: 0, page: 3, top: 0.0, bottom: 0.3))
        // The following provision has no PDF position: boundary unknown.
        XCTAssertFalse(LawPDFAnchoring.sectionCovers(sections, index: 1, page: 3, top: 0.5, bottom: 0.6))
        XCTAssertFalse(LawPDFAnchoring.sectionCovers(sections, index: 2, page: 4, top: 0.5, bottom: 0.6))
        // The last provision runs to the end.
        XCTAssertTrue(LawPDFAnchoring.sectionCovers(sections, index: 3, page: 9, top: 0.5, bottom: 0.6))
    }
    func testMatchFindsOnlyUniqueQuoteOfCoveringSection() {
        let sections = [section("a", "Der Kaufmann haftet unbeschränkt.", page: 1), section("b", "Der Kaufmann haftet unbeschränkt.", page: 2)]
        let anchor = LawPDFAnchoring.match(sections, page: 2, quote: "Kaufmann haftet", top: 0.3, bottom: 0.4)
        XCTAssertEqual(anchor, LawAnchor(sectionId: "b", start: 3, end: 17, quote: "kaufmannhaftet"))
        // Fewer than 12 canonical characters: no anchor.
        XCTAssertNil(LawPDFAnchoring.match(sections, page: 2, quote: "Kaufmann", top: 0.3, bottom: 0.4))
        // Twice in the same section: ambiguous.
        let twice = [section("a", "Kaufmann haftet. Kaufmann haftet.", page: 1)]
        XCTAssertNil(LawPDFAnchoring.match(twice, page: 1, quote: "Kaufmann haftet", top: 0.3, bottom: 0.4))
        // Neighbouring provisions on one page: only the one covering the place counts.
        let both = [section("a", "Kaufmann haftet immer.", page: 1, top: 0), section("b", "Kaufmann haftet nie.", page: 1, top: 0.1)]
        XCTAssertNotNil(LawPDFAnchoring.match(both, page: 1, quote: "Kaufmann haftet", top: 0.05, bottom: 0.08))
        XCTAssertEqual(LawPDFAnchoring.match(both, page: 1, quote: "Kaufmann haftet", top: 0.05, bottom: 0.08)?.sectionId, "a")
    }
    func testQuoteUnderStrokeCoversWholeWordsOfOneLine() throws {
        let text = layout(["Der Kaufmann haftet", "unbeschraenkt fuer alles"])
        // Horizontal stroke through the middle of "Kaufmann ha" on line 1 (y 0.1…0.12).
        let points = [LawPDFPoint(0.145, 0.11), LawPDFPoint(0.245, 0.11)]
        let quote = try XCTUnwrap(LawPDFAnchoring.quoteUnderStroke(text, points: points))
        XCTAssertEqual(quote.quote, "kaufmannhaftet")
        XCTAssertEqual(quote.top, 0.1, accuracy: 1e-9)
        XCTAssertEqual(quote.bottom, 0.12, accuracy: 1e-9)
        XCTAssertNil(LawPDFAnchoring.quoteUnderStroke(text, points: [LawPDFPoint(0.145, 0.11)]))
        XCTAssertNil(LawPDFAnchoring.quoteUnderStroke(text, points: [LawPDFPoint(0.5, 0.5), LawPDFPoint(0.6, 0.5)]))
        // A diagonal scribble skipping letters in between gives no quote.
        let diagonal = [LawPDFPoint(0.105, 0.11), LawPDFPoint(0.18, 0.15)]
        XCTAssertNil(LawPDFAnchoring.quoteUnderStroke(text, points: diagonal))
    }
    func testRectanglesForAnchorJoinLines() throws {
        let sections = [section("a", "Der Kaufmann haftet unbeschraenkt fuer alles", page: 1)]
        let text = layout(["Der Kaufmann haftet", "unbeschraenkt fuer alles"])
        let anchor = LawAnchor(sectionId: "a", start: 3, end: 30, quote: (LawTextAnchor.canonical("Der Kaufmann haftet unbeschraenkt fuer alles") as NSString).substring(with: NSRange(location: 3, length: 27)))
        let rects = LawPDFAnchoring.rectangles(for: anchor, layout: text, sections: sections, page: 1)
        XCTAssertEqual(rects.count, 2)
        XCTAssertEqual(rects[0].x, 0.14, accuracy: 1e-9)
        XCTAssertEqual(rects[0].y, 0.1, accuracy: 1e-9)
        XCTAssertEqual(rects[1].y, 0.13, accuracy: 1e-9)
        XCTAssertEqual(rects[0].height, 0.02, accuracy: 1e-9)
        // Wrong page for the section, invalid anchor, or not on this page.
        XCTAssertEqual(LawPDFAnchoring.rectangles(for: anchor, layout: text, sections: [section("a", sections[0].text, page: 2)], page: 1), [])
        var wrong = anchor; wrong.quote = "x"
        XCTAssertEqual(LawPDFAnchoring.rectangles(for: wrong, layout: text, sections: sections, page: 1), [])
        XCTAssertEqual(LawPDFAnchoring.rectangles(for: anchor, layout: layout(["Etwas anderes"]), sections: sections, page: 1), [])
    }
    func testPencilTapFindsTheWordInThePDF() throws {
        let text = layout(["Der Kaufmann haftet"])
        let word = try XCTUnwrap(LawPDFAnchoring.word(at: LawPDFPoint(0.165, 0.11), layout: text))
        XCTAssertEqual(word.quote, "kaufmann")
        XCTAssertEqual(word.rectangles.count, 1)
        XCTAssertEqual(word.rectangles[0].x, 0.14, accuracy: 1e-9)
        XCTAssertEqual(word.rectangles[0].width, 0.08, accuracy: 1e-9)
        XCTAssertNil(LawPDFAnchoring.word(at: LawPDFPoint(0.135, 0.11), layout: text), "space between words")
        XCTAssertNil(LawPDFAnchoring.word(at: LawPDFPoint(0.5, 0.5), layout: text))
    }
    func testStrokesAreThinnedInsteadOfCut() {
        var points: [LawPDFPoint] = []
        for i in 0..<5000 { LawPDFAnchoring.append(LawPDFPoint(Double(i) * 0.0006, 0.5), to: &points) }
        XCTAssertLessThanOrEqual(points.count, LawPDFAnchoring.maxPoints)
        XCTAssertGreaterThan(points.count, 700)
        XCTAssertEqual(points.first, LawPDFPoint(0, 0.5))
        XCTAssertEqual(points.last?.x ?? 0, 4999 * 0.0006, accuracy: 1e-9, "the stroke still reaches its end")
        // Tiny moves are skipped.
        var still: [LawPDFPoint] = [LawPDFPoint(0.5, 0.5)]
        LawPDFAnchoring.append(LawPDFPoint(0.5001, 0.5), to: &still)
        XCTAssertEqual(still.count, 1)
        let many = (0..<4000).map { LawPDFPoint(Double($0), 0) }
        let thin = LawPDFAnchoring.thinned(many)
        XCTAssertEqual(thin.count, 1500)
        XCTAssertEqual(thin.first, many.first)
        XCTAssertEqual(thin.last, many.last)
        XCTAssertEqual(LawPDFAnchoring.thinned(Array(many.prefix(10))).count, 10)
    }
    func testRectangleLimit() {
        let rects = (0..<1200).map { LawPDFRect(x: Double($0 % 3) * 0.3, y: Double($0 / 3) * 0.002, width: 0.2, height: 0.0015) }
        let limited = LawPDFAnchoring.limitedRectangles(rects)
        XCTAssertLessThanOrEqual(limited.count, LawPDFAnchoring.maxRectangles)
        XCTAssertEqual(limited.first?.width ?? 0, 0.8, accuracy: 1e-9)
        XCTAssertEqual(LawPDFAnchoring.limitedRectangles(Array(rects.prefix(3))), Array(rects.prefix(3)))
    }
}
