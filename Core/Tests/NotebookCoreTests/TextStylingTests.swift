import XCTest
@testable import NotebookCore

final class TextStylingTests: XCTestCase {
    private func lined(dark: Bool = false) throws -> (Notebook, TextBox) {
        var appearance = NotebookAppearance(); appearance.paper = .lined; appearance.color = dark ? .dark : .white
        let book = try Notebook.blank(title: "Farben", appearance: appearance).preparedForTextEditing()
        let rect = try XCTUnwrap(book.pages[0].writingRect(.page))
        var box = TextBox(x: rect.x, y: rect.y, width: rect.width, height: rect.height, text: "Hallo Welt")
        box.flowID = UUID(); box.flowRegion = .page
        return (book, box)
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testColorFormatsRaiseSchemaToNineOnlyWhenUsedAndValidate() throws {
        var (book, box) = try lined()
        try book.replaceTextBoxes([box], pageID: book.pages[0].id)
        XCTAssertEqual(book.schemaVersion, 8)
        var marked = box.style; marked.highlighted = true; marked.highlightColor = .green
        box.runs = [TextRun(location: 0, length: 5, style: marked)]
        try book.replaceTextBoxes([box], pageID: book.pages[0].id)
        XCTAssertEqual(book.schemaVersion, 9)
        XCTAssertEqual(try Notebook.decode(JSONEncoder().encode(book)), book)
        var lowered = book; lowered.schemaVersion = 8
        XCTAssertThrowsError(try lowered.validate())
        var invalid = TextBoxStyle(); invalid.automaticColor = true; invalid.ink = InkColor(0.2, 0.2, 0.2)
        XCTAssertThrowsError(try invalid.validate())
        invalid.ink = nil; invalid.color = .blue
        XCTAssertThrowsError(try invalid.validate())
        invalid.color = .white
        XCTAssertNoThrow(try invalid.validate())
        var future = try JSONSerialization.jsonObject(with: JSONEncoder().encode(book)) as! [String: Any]
        future["schemaVersion"] = 10
        XCTAssertThrowsError(try Notebook.decode(JSONSerialization.data(withJSONObject: future))) { error in
            guard case StorageError.unsupportedSchema(10) = error else { return XCTFail("\(error)") }
        }
    }

    func testOtherWritePathsKeepSchemaNine() throws {
        var (book, box) = try lined()
        box.style.automaticColor = true
        let pageID = book.pages[0].id
        var content = PageContent(page: book.pages[0]); content.textBoxes = [box]
        try book.replaceContent(content, pageID: pageID)
        XCTAssertEqual(book.schemaVersion, 9)
        try book.replaceShapes([], pageID: pageID); try book.replaceImages([], pageID: pageID)
        XCTAssertEqual(book.schemaVersion, 9)
        var other = try lined().0
        let draft = other.writingDraft()
        var page = draft; page.textBoxes = [box]
        try other.materializeWritingDraft(page)
        XCTAssertEqual(other.schemaVersion, 9)
    }

    func testFlowUndoSnapshotNeverLowersMigratedSchema() throws {
        var (book, box) = try lined()
        try book.replaceTextBoxes([box], pageID: book.pages[0].id)
        let before = book
        var after = book
        var page = after.writingDraft(); var next = box; next.id = UUID(); next.style.highlightColor = .pink; next.style.highlighted = true
        page.textBoxes = [next]
        try after.materializeWritingDraft(page)
        XCTAssertEqual(after.schemaVersion, 9)
        var history = NotebookUndoHistory()
        history.record(.textFlow, before: before, after: after)
        let undone = try XCTUnwrap(history.undo(after)).notebook
        XCTAssertEqual(undone.schemaVersion, 9)
        XCTAssertEqual(undone.pages, before.pages)
        let redone = try XCTUnwrap(history.redo(undone)).notebook
        XCTAssertEqual(redone, after)
    }

    func testMigrationArchivesExactSchemaEightBytesAndFailureBlocksCommit() throws {
        let root = try directory()
        var (book, box) = try lined()
        try book.replaceTextBoxes([box], pageID: book.pages[0].id)
        try RevisionStore(directory: root).save(book)
        let committed = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Revisions"), includingPropertiesForKeys: nil)
        XCTAssertEqual(committed.count, 1)
        let acknowledged = try Data(contentsOf: committed[0])
        let store = RevisionStore(directory: root)
        var upgraded = try store.load()
        box.style.automaticColor = true
        try upgraded.replaceTextBoxes([box], pageID: book.pages[0].id)
        try store.save(upgraded)
        let folders = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Migrations"), includingPropertiesForKeys: nil)
        XCTAssertEqual(folders.count, 1)
        let archived = try Data(contentsOf: folders[0].appendingPathComponent("notebook-v8.json"))
        XCTAssertEqual(archived, acknowledged)
        XCTAssertEqual(try Notebook.decode(archived), book)
        XCTAssertEqual(try RevisionStore(directory: root).load(), upgraded)

        let blocked = try directory()
        try RevisionStore(directory: blocked).save(book)
        try Data("kein Ordner".utf8).write(to: blocked.appendingPathComponent("Migrations"))
        let failing = RevisionStore(directory: blocked)
        var candidate = try failing.load()
        try candidate.replaceTextBoxes([box], pageID: book.pages[0].id)
        XCTAssertThrowsError(try failing.save(candidate))
        XCTAssertEqual(try RevisionStore(directory: blocked).load(), book)
    }

    func testAutomaticColorResolvesAgainstPaperMarginsAndPDF() throws {
        var box = TextBox(); box.style.automaticColor = true
        box.runs = [TextRun(location: 0, length: 0 + 1, style: box.style)]; box.text = "a"
        XCTAssertEqual(box.resolvingAutomaticColor(light: true).style.color, .white)
        XCTAssertEqual(box.resolvingAutomaticColor(light: true).runs?.first?.style.color, .white)
        XCTAssertEqual(box.resolvingAutomaticColor(light: true).style.automaticColor, true)
        var fixed = TextBox(); fixed.style.color = .black
        XCTAssertEqual(fixed.resolvingAutomaticColor(light: true), fixed)
        let a4 = PageSize.a4
        XCTAssertTrue(EditorInteractionPolicy.automaticTextIsLight(box: box, pageSize: a4, hasPDF: false, darkPaper: true, darkMargins: false))
        XCTAssertFalse(EditorInteractionPolicy.automaticTextIsLight(box: box, pageSize: a4, hasPDF: true, darkPaper: true, darkMargins: true))
        var margin = box; margin.x = -100; margin.y = 40
        XCTAssertTrue(EditorInteractionPolicy.automaticTextIsLight(box: margin, pageSize: a4, hasPDF: true, darkPaper: false, darkMargins: true))
        margin.x = 40; margin.flowID = UUID(); margin.flowRegion = .right
        XCTAssertTrue(EditorInteractionPolicy.automaticTextIsLight(box: margin, pageSize: a4, hasPDF: true, darkPaper: false, darkMargins: true))

        var (book, flow) = try lined(dark: true)
        flow.style.automaticColor = true; flow.style.color = .black
        try book.replaceTextBoxes([flow], pageID: book.pages[0].id)
        XCTAssertEqual(book.pages[0].resolvedTextBoxes.first?.style.color, .white)
        XCTAssertEqual(book.pages[0].textBoxes?.first?.style.color, .black)
    }

    func testWholeNotebookConversionKeepsAutomaticTextAutomatic() throws {
        var style = TextBoxStyle(); style.automaticColor = true
        let dark = PaperInkInversion.converted(style, to: .dark)
        XCTAssertEqual(dark.color, .white); XCTAssertEqual(dark.automaticColor, true); XCTAssertNil(dark.ink)
        XCTAssertEqual(PaperInkInversion.converted(dark, to: .white).color, .black)
        var (book, box) = try lined()
        box.style.automaticColor = true
        try book.replaceTextBoxes([box], pageID: book.pages[0].id)
        _ = try book.setPageDefaults(paper: .lined, color: .dark, scope: .wholeNotebook)
        XCTAssertEqual(book.pages[0].textBoxes?.first?.style.color, .white)
        XCTAssertEqual(book.pages[0].textBoxes?.first?.style.automaticColor, true)
        XCTAssertEqual(book.schemaVersion, 9)
    }

    func testPresetsFitRulingAndLabelsMatchOldSizes() {
        XCTAssertEqual(TextStylePreset.allCases.map(\.title), ["Titel", "Überschrift", "Unterüberschrift", "Text", "Beschriftung"])
        for preset in TextStylePreset.allCases {
            XCTAssertEqual(TextStylePreset.rulingLines(fontSize: preset.fontSize), preset == .title ? 2 : 1, preset.title)
            var style = TextBoxStyle(); preset.apply(to: &style)
            XCTAssertEqual(TextStylePreset.matching(style), preset)
            // Lines of one size keep a constant pitch of whole ruling lines.
            let ascent = preset.fontSize * 0.952, descent = preset.fontSize * 0.241
            var baseline = PaperRuling.baseline(forNatural: 16 + ascent)
            for _ in 0..<5 {
                let next = PaperRuling.baseline(forNatural: baseline + descent + ascent)
                XCTAssertEqual(next - baseline, Double(TextStylePreset.rulingLines(fontSize: preset.fontSize)) * PaperRuling.spacing, accuracy: 0.0001)
                baseline = next
            }
        }
        for (size, bold, preset) in [(32.0, true, TextStylePreset.title), (26, true, .heading), (21, true, .heading), (14, false, .body), (12, false, .caption), (18, false, .body)] {
            var style = TextBoxStyle(); style.fontSize = size; style.bold = bold
            XCTAssertEqual(TextStylePreset.matching(style), preset)
        }
    }

    func testClearingFormattingKeepsParagraphAndLink() {
        var style = TextBoxStyle(font: .serif, fontSize: 30, bold: true, italic: true, underline: true, color: .red)
        style.fontName = "Courier"; style.ink = InkColor(0.1, 0.5, 0.2); style.strikethrough = true; style.baseline = 1
        style.highlighted = true; style.highlightColor = .blue; style.alignment = .center; style.indent = 40; style.link = "https://example.org"
        let plain = style.clearingCharacterFormatting(light: true)
        XCTAssertEqual(plain.font, .system); XCTAssertNil(plain.fontName); XCTAssertEqual(plain.fontSize, 14)
        XCTAssertFalse(plain.bold || plain.italic || plain.underline)
        XCTAssertNil(plain.strikethrough); XCTAssertNil(plain.baseline); XCTAssertNil(plain.highlighted); XCTAssertNil(plain.highlightColor)
        XCTAssertEqual(plain.automaticColor, true); XCTAssertEqual(plain.color, .white); XCTAssertNil(plain.ink)
        XCTAssertEqual(plain.alignment, .center); XCTAssertEqual(plain.indent, 40); XCTAssertEqual(plain.link, "https://example.org")
        XCTAssertNoThrow(try plain.validate())
    }

    func testStatisticsIgnoreListMarkersAndLineBreaks() {
        let stats = TextStatistics("• Erstes Wort\n1. zwei – drei\n☐ Aufgabe 👍🏽\r\n\n  ◦ x")
        XCTAssertEqual(stats.words, 6)
        XCTAssertEqual(stats.characters, "Erstes Wort".count + "zwei – drei".count + "Aufgabe 👍🏽".count + 1)
        XCTAssertEqual(stats.charactersWithoutSpaces, 10 + 9 + 8 + 1)
        XCTAssertEqual(TextStatistics(""), TextStatistics("\n\n"))
    }

    func testTypewriterKeepsCaretInUpperThird() {
        let visible = PageRect(x: 0, y: 100, width: 800, height: 600)
        let low = NotebookViewportGeometry.typewriterOffset(caret: .init(x: 10, y: 500, width: 2, height: 20), visible: visible)
        XCTAssertEqual(low.y, 100 + 520 - 300, accuracy: 0.0001)
        let high = NotebookViewportGeometry.typewriterOffset(caret: .init(x: 10, y: 150, width: 2, height: 20), visible: visible)
        XCTAssertEqual(high.y, 100)
        let above = NotebookViewportGeometry.typewriterOffset(caret: .init(x: 10, y: 40, width: 2, height: 20), visible: visible)
        XCTAssertEqual(above.y, 40)
    }

    func testCaretRevealMovesOnlyForHiddenCaretAndAvoidsChrome() {
        // Free area below a 64-pt header, above the keyboard (content coordinates).
        let visible = PageRect(x: 0, y: 1064, width: 800, height: 500)
        let caret = PageRect(x: 100, y: 1070, width: 2, height: 18)
        // Tap/selection: visible caret never moves the view, even near the edge.
        XCTAssertEqual(NotebookViewportGeometry.caretRevealDelta(caret: caret, visible: visible, kind: .navigation), .init(x: 0, y: 0))
        XCTAssertEqual(NotebookViewportGeometry.caretRevealDelta(caret: caret, visible: visible, kind: nil), .init(x: 0, y: 0))
        // Typing near the edge keeps a small margin.
        XCTAssertEqual(NotebookViewportGeometry.caretRevealDelta(caret: caret, visible: visible, kind: .typing).y, -14, accuracy: 1e-9)
        // Caret under the header (back arrow / toolbar): back into the free area.
        let underHeader = PageRect(x: 100, y: 1030, width: 2, height: 18)
        XCTAssertEqual(NotebookViewportGeometry.caretRevealDelta(caret: underHeader, visible: visible, kind: .navigation).y, -54, accuracy: 1e-9)
        // Below the keyboard: scroll down just enough.
        let low = PageRect(x: 100, y: 1600, width: 2, height: 18)
        XCTAssertEqual(NotebookViewportGeometry.caretRevealDelta(caret: low, visible: visible, kind: .typing).y, 1618 - 1544, accuracy: 1e-9)
        // Zoomed in: horizontal only when the caret leaves the area.
        let right = PageRect(x: 830, y: 1200, width: 2, height: 18)
        let sideways = NotebookViewportGeometry.caretRevealDelta(caret: right, visible: visible, kind: .typing)
        XCTAssertEqual(sideways.x, 52, accuracy: 1e-9); XCTAssertEqual(sideways.y, 0)
        // Floating toolbar over the caret: step just past it, nearest side.
        let toolbar = PageRect(x: 50, y: 1190, width: 400, height: 52)
        let covered = PageRect(x: 100, y: 1200, width: 2, height: 18)
        let around = NotebookViewportGeometry.caretRevealDelta(caret: covered, visible: visible, obstructions: [toolbar], kind: .navigation)
        XCTAssertEqual(around.y, 1218 - 1182, accuracy: 1e-9, "caret ends 8 pt above the toolbar")
        XCTAssertEqual(NotebookViewportGeometry.caretRevealDelta(caret: PageRect(x: 600, y: 1200, width: 2, height: 18), visible: visible,
            obstructions: [toolbar], kind: .navigation), .init(x: 0, y: 0))
        // Typewriter: upper third of the free area while typing.
        let typed = NotebookViewportGeometry.caretRevealDelta(caret: PageRect(x: 100, y: 1400, width: 2, height: 18), visible: visible, kind: .typewriter)
        XCTAssertEqual(typed.y, 1418 - (1084 + 460.0 / 3), accuracy: 1e-9)
        XCTAssertTrue(CaretReveal.typewriter > .typing && CaretReveal.typing > .navigation)
    }

    func testTextRasterScaleNeverCoarserThanDisplayAndStepsBySqrtTwo() {
        XCTAssertEqual(TextRasterScale.quantized(1), 1, accuracy: 1e-9)
        XCTAssertEqual(TextRasterScale.quantized(1.2), 2.0.squareRoot(), accuracy: 1e-9)
        XCTAssertEqual(TextRasterScale.quantized(2.2), 2 * 2.0.squareRoot(), accuracy: 1e-9)
        for zoom in stride(from: 0.3, through: 13.0, by: 0.17) {
            let q = TextRasterScale.quantized(zoom)
            XCTAssertGreaterThanOrEqual(q, zoom - 1e-9); XCTAssertLessThan(q, zoom * 2.0.squareRoot() + 1e-9)
        }
        XCTAssertEqual(TextRasterScale.quantized(.nan), 1)
        // Viewport-bounded raster at 13× page zoom stays within the 16-MP plane limit.
        let viewport = InkRenderViewport(page: .init(width: 595, height: 842), visible: .init(x: 200, y: 300, width: 100, height: 75),
            scale: TextRasterScale.quantized(13))
        let scale = EditorRenderGeometry.contentScale(size: viewport.frame.size, displayScale: viewport.scale, screenScale: 2)
        XCTAssertLessThanOrEqual(viewport.frame.width * viewport.frame.height * scale * scale, 16_000_001)
        XCTAssertGreaterThanOrEqual(scale, 26 - 1e-6, "sharp at the shown resolution")
    }
}
