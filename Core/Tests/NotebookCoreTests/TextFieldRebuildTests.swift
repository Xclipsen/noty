import XCTest
@testable import NotebookCore

/// Textneubau Stufe 1 (docs/TEXT-REBUILD-62.md): notebooks hold only free
/// text fields; page text migrates; schema 14 (rotation, automatic width).
final class TextFieldRebuildTests: XCTestCase {
    private func p(_ x: Double, _ y: Double) -> PagePoint { PagePoint(x: x, y: y) }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Schema-13 notebook as Build ≤ 62 stored it: page text over two pages
    /// (one segment empty), a margin flow beside a PDF and a flow in the trash.
    private func flowNotebook() throws -> Notebook {
        var appearance = NotebookAppearance(); appearance.paper = .lined
        var book = try Notebook.blank(title: "Fluss", appearance: appearance)
        _ = try book.insertPaper(.lined, at: 1, geometry: PaperStyle.geometry)
        _ = try book.insertPDF(Data([1, 2, 3]), geometries: [PaperStyle.geometry], at: 2)
        book = try book.preparedForTextEditing()
        try book.setMargins(PageMargins(left: 200), pageIDs: [book.pages[2].id])
        let flow = UUID()
        let rect = try XCTUnwrap(book.pages[0].writingRect(.page))
        var first = TextBox(x: rect.x, y: rect.y, width: rect.width, height: rect.height, text: "Erste Seite\nmit Text")
        first.flowID = flow; first.flowRegion = .page
        var bold = first.style; bold.bold = true
        first.runs = [TextRun(location: 0, length: 5, style: bold)]
        var second = TextBox(x: rect.x, y: rect.y, width: rect.width, height: rect.height, text: "")
        second.flowID = flow; second.flowRegion = .page
        try book.replaceTextBoxes([first], pageID: book.pages[0].id)
        try book.replaceTextBoxes([second], pageID: book.pages[1].id)
        let margin = try XCTUnwrap(book.pages[2].writingRect(.left))
        var side = TextBox(x: margin.x, y: margin.y, width: margin.width, height: margin.height, text: "Randnotiz")
        side.flowID = UUID(); side.flowRegion = .left
        try book.replaceTextBoxes([side], pageID: book.pages[2].id)
        let copy = try book.duplicatePage(book.pages[0].id)
        try book.trashPage(copy)
        book.schemaVersion = 13
        try book.validate()
        return book
    }

    func testDecodingTurnsPageTextIntoFieldsAtExactlyTheSameFrame() throws {
        let book = try flowNotebook()
        let bytes = try JSONEncoder().encode(book)
        let decoded = try NotebookDecoding.decode(bytes)
        XCTAssertEqual(decoded.storedSchemaVersion, 13)
        let fields = decoded.notebook
        XCTAssertEqual(fields.schemaVersion, 14)
        XCTAssertFalse(fields.containsTextFlow)
        let before = book.pages[0].textBoxes![0], after = try XCTUnwrap(fields.pages[0].textBoxes?.first)
        XCTAssertEqual(after.id, before.id); XCTAssertNil(after.flowID); XCTAssertEqual(after.flowRegion, .page)
        XCTAssertEqual(after.rect, before.rect); XCTAssertEqual(after.text, before.text)
        XCTAssertEqual(after.runs, before.runs); XCTAssertEqual(after.style, before.style)
        XCTAssertNil(after.rotation); XCTAssertNil(after.autoWidth, "migrated page text keeps its fixed width")
        XCTAssertTrue(after.allowsObjectSelection)
        XCTAssertEqual(fields.pages[1].textBoxes, [], "an empty continuation segment carries no text and vanishes")
        // Margin text keeps its region: same ruling and coordinate units as before.
        let side = try XCTUnwrap(fields.pages[2].textBoxes?.first)
        XCTAssertEqual(side.flowRegion, .left); XCTAssertEqual(side.text, "Randnotiz")
        XCTAssertEqual(fields.pages[2].writingCoordinateScale(for: side), book.pages[2].writingCoordinateScale(for: book.pages[2].textBoxes![0]))
        // Page trash too.
        let trashed = try XCTUnwrap(fields.deletedPages?.first?.page.textBoxes?.first)
        XCTAssertNil(trashed.flowID); XCTAssertEqual(trashed.text, "Erste Seite\nmit Text")
        // Migrating again changes nothing; the pure decode path agrees.
        XCTAssertEqual(try fields.migratedTextFlow(), fields)
        XCTAssertEqual(try Notebook.decode(bytes), fields)
    }

    func testOpeningWritesNothingAndFirstCommitArchivesExactOldBytes() throws {
        let root = try directory()
        let book = try flowNotebook()
        let original = try JSONEncoder().encode(book)
        // A package written by an older build: its exact revision bytes.
        try RevisionStore(directory: root).save(book)
        let revisions = root.appendingPathComponent("Revisions")
        let files = try FileManager.default.contentsOfDirectory(at: revisions, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(try Data(contentsOf: files[0]).count, original.count)
        let acknowledged = try Data(contentsOf: files[0])

        let store = RevisionStore(directory: root)
        let opened = try store.load()
        XCTAssertEqual(opened.schemaVersion, 14)
        try store.save(opened) // unchanged since loading: no commit
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: revisions, includingPropertiesForKeys: nil).count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Migrations").path))

        var edited = opened
        var boxes = edited.pages[0].textBoxes!; boxes[0].text += "!"
        try edited.replaceTextBoxes(boxes, pageID: edited.pages[0].id)
        try store.save(edited)
        let folders = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Migrations"), includingPropertiesForKeys: nil)
        XCTAssertEqual(try Data(contentsOf: folders[0].appendingPathComponent("notebook-v13.json")), acknowledged)
        XCTAssertEqual(try RevisionStore(directory: root).load(), edited)
        XCTAssertEqual(try NotebookDecoding.decode(Data(contentsOf: folders[0].appendingPathComponent("notebook-v13.json"))).storedSchemaVersion, 13)
    }

    func testFailedArchiveOfOldBytesPreventsTheMigrationCommit() throws {
        let root = try directory()
        let book = try flowNotebook()
        try RevisionStore(directory: root).save(book)
        try Data("kein Ordner".utf8).write(to: root.appendingPathComponent("Migrations"))
        let store = RevisionStore(directory: root)
        var edited = try store.load()
        var boxes = edited.pages[0].textBoxes!; boxes[0].text = "geändert"
        try edited.replaceTextBoxes(boxes, pageID: edited.pages[0].id)
        XCTAssertThrowsError(try store.save(edited))
        let reloaded = try RevisionStore(directory: root).load()
        XCTAssertEqual(reloaded.pages[0].textBoxes?.first?.text, "Erste Seite\nmit Text", "the old state stays valid")
    }

    func testFieldPropertiesNeedSchemaFourteenAndOnlyRaiseWhenUsed() throws {
        var book = try Notebook.blank(title: "Felder", appearance: NotebookAppearance())
        let id = book.pages[0].id
        var plain = TextBox(x: 40, y: 40, width: 200, height: 30, text: "frei")
        try book.replaceTextBoxes([plain], pageID: id)
        XCTAssertLessThan(book.schemaVersion, 14, "plain free fields keep the older format")
        let lower = book.schemaVersion
        plain.autoWidth = true
        try book.replaceTextBoxes([plain], pageID: id)
        XCTAssertEqual(book.schemaVersion, 14)
        var stale = book; stale.schemaVersion = lower
        XCTAssertThrowsError(try stale.validate())
        // Removing the property never lowers the schema.
        plain.autoWidth = nil
        try book.replaceTextBoxes([plain], pageID: id)
        XCTAssertEqual(book.schemaVersion, 14)

        // Every content path raises: lasso (replaceContent) and cross-page moves.
        var other = try Notebook.blank(title: "Lasso", appearance: NotebookAppearance())
        var turned = TextBox(x: 100, y: 100, width: 120, height: 30, text: "gedreht"); turned.rotation = 30
        var content = PageContent(page: other.pages[0]); content.textBoxes = [turned]
        try other.replaceContent(content, pageID: other.pages[0].id)
        XCTAssertEqual(other.schemaVersion, 14)
        var third = try Notebook.blank(title: "Seiten", appearance: NotebookAppearance())
        let before = PageContent(page: third.pages[0])
        var after = before; after.textBoxes = [turned]
        try third.replaceContents([PageContentReplacement(pageID: third.pages[0].id, expected: before, replacement: after)])
        XCTAssertEqual(third.schemaVersion, 14)
    }

    func testFieldValidationAndLockedNewerSchema() throws {
        var box = TextBox(x: 40, y: 40, width: 100, height: 30, text: "x")
        box.autoWidth = false; XCTAssertThrowsError(try box.validate())
        box.autoWidth = true; XCTAssertNoThrow(try box.validate())
        box.rotation = 181; XCTAssertThrowsError(try box.validate())
        box.rotation = .nan; XCTAssertThrowsError(try box.validate())
        box.rotation = -90; XCTAssertNoThrow(try box.validate())
        box.rotation = 90 // turned downwards: stays on the page
        var flow = TextBox(text: "f"); flow.flowID = UUID()
        XCTAssertThrowsError(try flow.validate(), "a flow segment names its region")
        flow.flowRegion = .page; XCTAssertNoThrow(try flow.validate())
        flow.rotation = 10; XCTAssertThrowsError(try flow.validate(), "flow segments never rotate")

        var book = try Notebook.blank(title: "Neu", appearance: NotebookAppearance())
        try book.replaceTextBoxes([box], pageID: book.pages[0].id)
        let data = try JSONEncoder().encode(book)
        XCTAssertEqual(try Notebook.decode(data), book)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["schemaVersion"] = 13
        XCTAssertThrowsError(try Notebook.decode(JSONSerialization.data(withJSONObject: json)), "rotation under schema 13")
        json["schemaVersion"] = 16
        XCTAssertThrowsError(try Notebook.decode(JSONSerialization.data(withJSONObject: json))) { error in
            guard case StorageError.unsupportedSchema(16) = error else { return XCTFail("\(error)") }
        }
        // A region without a flow is schema 14 only.
        var migrated = TextBox(x: 40, y: 40, width: 100, height: 30, text: "m"); migrated.flowRegion = .page
        XCTAssertTrue(migrated.usesFieldFormat)
        var old = try Notebook.blank(title: "Alt", appearance: NotebookAppearance()).preparedForTextEditing()
        old.schemaVersion = 13; old.pages[0].textBoxes = [migrated]
        XCTAssertThrowsError(try old.validate())
        old.schemaVersion = 14; XCTAssertNoThrow(try old.validate())
    }

    func testRotatedFrameGeometryIsConsistentEverywhere() throws {
        var box = TextBox(x: 100, y: 100, width: 200, height: 50, text: "Dreh")
        XCTAssertEqual(box.rotatedBounds, box.rect)
        box.rotation = 90
        let corners = box.corners
        XCTAssertEqual(corners[0].x, 100, accuracy: 1e-9); XCTAssertEqual(corners[0].y, 100, accuracy: 1e-9)
        XCTAssertEqual(corners[1].x, 100, accuracy: 1e-9); XCTAssertEqual(corners[1].y, 300, accuracy: 1e-9, "x axis points down at 90°")
        XCTAssertEqual(corners[3].x, 50, accuracy: 1e-9); XCTAssertEqual(corners[3].y, 100, accuracy: 1e-9)
        let bounds = box.rotatedBounds
        XCTAssertEqual(bounds.x, 50, accuracy: 1e-9); XCTAssertEqual(bounds.width, 50, accuracy: 1e-9)
        XCTAssertEqual(bounds.height, 200, accuracy: 1e-9)
        box.rotation = 37
        for local in [p(0, 0), p(17, 3), p(200, 50), p(-5, 80)] {
            let back = box.localPoint(box.pagePoint(local))
            XCTAssertEqual(back.x, local.x, accuracy: 1e-9); XCTAssertEqual(back.y, local.y, accuracy: 1e-9)
        }
        XCTAssertTrue(box.contains(box.pagePoint(p(150, 25))))
        XCTAssertFalse(box.contains(box.pagePoint(p(150, 60))))
        XCTAssertTrue(box.contains(box.pagePoint(p(150, 60)), tolerance: 12))
        // The handle turns about the centre; the pivot follows.
        let centre = box.center
        let turned = box.rotated(to: 127)
        XCTAssertEqual(turned.angle, 127, accuracy: 1e-9)
        XCTAssertEqual(turned.center.x, centre.x, accuracy: 1e-9); XCTAssertEqual(turned.center.y, centre.y, accuracy: 1e-9)
        XCTAssertNil(box.rotated(to: 360).rotation, "an unrotated field stores no rotation")
        XCTAssertEqual(TextBox.storedRotation(-190), 170)
        // Bounds: the whole rotated frame, never partly off the page.
        let page = PageRect(x: 0, y: 0, width: 595, height: 842)
        XCTAssertTrue(box.fits(in: page))
        var edge = box; edge.x = 560
        XCTAssertFalse(edge.fits(in: page))
        let shifted = try XCTUnwrap(edge.shifted(into: page))
        XCTAssertTrue(shifted.fits(in: page))
        var long = TextBox(x: 400, y: 100, width: 50, height: 20); long.rotation = 0
        XCTAssertEqual(long.maximumWidth(in: page), 195, accuracy: 0.001)
        XCTAssertEqual(long.maximumHeight(in: page), 742, accuracy: 0.001)
        long.rotation = 90
        XCTAssertEqual(long.maximumWidth(in: page), 742, accuracy: 0.001, "at 90° the field grows downwards")
    }

    func testRotationSnapsSoftlyToRightAnglesAndWeakerToDiagonals() {
        XCTAssertEqual(TextFieldRotation.snapped(4).angle, 0); XCTAssertEqual(TextFieldRotation.snapped(4).target, 0)
        XCTAssertEqual(TextFieldRotation.snapped(95).angle, 90)
        XCTAssertEqual(TextFieldRotation.snapped(-176).angle, 180)
        XCTAssertNil(TextFieldRotation.snapped(10).target)
        XCTAssertEqual(TextFieldRotation.snapped(43).angle, 45)
        XCTAssertEqual(TextFieldRotation.snapped(41).angle, 41, "the diagonal pulls weaker than a right angle")
        XCTAssertEqual(TextFieldRotation.snapped(-133).angle, -135)
        XCTAssertEqual(TextFieldRotation.label(-90), "270°")
        XCTAssertEqual(TextFieldRotation.label(37.4), "37°")
    }

    func testTapsHitTextLinesAndARepeatedTapReachesTheFieldBelow() {
        var page = Page()
        let lower = TextBox(x: 40, y: 40, width: 300, height: 200, text: "unten")
        let upper = TextBox(x: 40, y: 40, width: 300, height: 200, text: "oben")
        var shape = ShapeObject(kind: .rectangle, start: p(30, 30), end: p(350, 250)); shape.fill = InkColor(0, 0, 0, 0.2)
        page.textBoxes = [lower, upper]; page.shapes = [shape]
        let content = PageContent(page: page)
        // Only the first line of each field carries text (y 40…60).
        let lines: (TextBox, PagePoint) -> Bool = { box, point in
            let local = box.localPoint(point); return local.x >= 0 && local.x <= 120 && local.y >= 0 && local.y <= 20
        }
        XCTAssertEqual(PageObjectHitTest.all(at: p(60, 50), in: content, textHit: lines), [.text(upper.id), .text(lower.id), .shape(shape.id)])
        XCTAssertEqual(PageObjectHitTest.topmost(at: p(60, 150), in: content, textHit: lines), .shape(shape.id),
                       "the empty part of a field reaches through")
        XCTAssertEqual(PageObjectHitTest.topmost(at: p(60, 150), in: content), .text(upper.id), "without line test: the frame")
        let hits = PageObjectHitTest.all(at: p(60, 50), in: content, textHit: lines)
        XCTAssertEqual(PageObjectHitTest.next(after: .text(upper.id), in: hits), .text(lower.id))
        XCTAssertEqual(PageObjectHitTest.next(after: .shape(shape.id), in: hits), .text(upper.id))
        XCTAssertNil(PageObjectHitTest.next(after: .text(upper.id), in: [.text(upper.id)]))
        // A rotated field is hit inside its turned frame only.
        var turned = TextBox(x: 400, y: 100, width: 100, height: 20, text: "schräg"); turned.rotation = 90
        page.textBoxes = [turned]
        XCTAssertEqual(PageObjectHitTest.topmost(at: p(390, 150), in: PageContent(page: page)), .text(turned.id))
        XCTAssertNil(PageObjectHitTest.topmost(at: p(450, 110), in: PageContent(page: page)))
    }

    func testFrontBackMovementAndNewFieldPlacement() throws {
        let a = TextBox(text: "a"), b = TextBox(text: "b"), c = TextBox(text: "c")
        XCTAssertEqual([a, b, c].movingField(a.id, toFront: true).map(\.text), ["b", "c", "a"])
        XCTAssertEqual([a, b, c].movingField(c.id, toFront: false).map(\.text), ["c", "a", "b"])
        XCTAssertEqual([a, b].movingField(UUID(), toFront: true).map(\.text), ["a", "b"])
        let page = PageRect(x: -100, y: 0, width: 695, height: 842)
        let frame = try XCTUnwrap(TextFieldPlacement.frame(tap: p(300, 400), limits: page, width: 20, lineHeight: 20))
        XCTAssertEqual(frame, PageRect(x: 300, y: 390, width: 20, height: 20), "caret at the tap, line centred on it")
        XCTAssertEqual(TextFieldPlacement.frame(tap: p(594, 841), limits: page, width: 20, lineHeight: 20),
                       PageRect(x: 575, y: 822, width: 20, height: 20), "never off the page")
        XCTAssertEqual(TextFieldPlacement.frame(tap: p(-150, -10), limits: page, width: 20, lineHeight: 20)?.x, -100,
                       "writing space left of a PDF counts")
        // The one move path clamps at the page (snapping plugs in before).
        struct Nudge: MoveSnapping {
            func adjusted(_ translation: PagePoint, moving frame: PageRect) -> PagePoint { PagePoint(x: translation.x + 3, y: translation.y) }
        }
        let moving = PageRect(x: 500, y: 100, width: 80, height: 20)
        XCTAssertEqual(ObjectMovement.translation(moving: moving, by: p(50, 10), within: PageRect(x: 0, y: 0, width: 595, height: 842)), p(15, 10))
        XCTAssertEqual(ObjectMovement.translation(moving: moving, by: p(5, 0), within: PageRect(x: 0, y: 0, width: 595, height: 842),
                                                  snapping: Nudge()), p(8, 0))
    }

    func testRotatedFieldsStayCompletelyOnThePage() throws {
        var book = try Notebook.blank(title: "Rand", appearance: NotebookAppearance())
        var box = TextBox(x: 560, y: 100, width: 30, height: 20, text: "x")
        try book.replaceTextBoxes([box], pageID: book.pages[0].id)
        box.rotation = -90 // turned up and to the left of x: still inside
        try book.replaceTextBoxes([box], pageID: book.pages[0].id)
        box.rotation = 180 // would reach left of 560 and above 100 … fits
        try book.replaceTextBoxes([box], pageID: book.pages[0].id)
        box.x = 10; box.rotation = 180 // left of the page
        XCTAssertThrowsError(try book.replaceTextBoxes([box], pageID: book.pages[0].id))
        // Lasso scaling keeps the pivot rule (scale about an anchor).
        var turned = TextBox(x: 100, y: 100, width: 100, height: 20, text: "s"); turned.rotation = 30
        let scaled = try turned.scaled(by: 2, around: p(100, 100), translation: p(0, 0))
        XCTAssertEqual(scaled.rotation, 30); XCTAssertEqual(scaled.width, 200); XCTAssertEqual(scaled.style.fontSize, 34)
        XCTAssertEqual(scaled.corners[2].x - 100, (turned.corners[2].x - 100) * 2, accuracy: 1e-9)
    }

    func testAutomaticColourOfMovedMigratedMarginTextFollowsItsPosition() throws {
        var margin = TextBox(x: -150, y: 40, width: 120, height: 30, text: "Rand"); margin.flowRegion = .left
        XCTAssertTrue(EditorInteractionPolicy.automaticTextIsLight(box: margin, pageSize: .a4, hasPDF: true, darkPaper: false, darkMargins: true))
        margin.x = 100 // moved onto the (light) PDF
        XCTAssertFalse(EditorInteractionPolicy.automaticTextIsLight(box: margin, pageSize: .a4, hasPDF: true, darkPaper: false, darkMargins: true))
        margin.flowID = UUID() // a real flow segment keeps following its region
        XCTAssertTrue(EditorInteractionPolicy.automaticTextIsLight(box: margin, pageSize: .a4, hasPDF: true, darkPaper: false, darkMargins: true))
    }

    func testMigratedPageTextKeepsItsLineLayoutWhenMovedAndNewFieldsHaveNone() throws {
        // Feedback zu Build 62: nothing aligns to lined or squared paper. A
        // migrated field keeps the layout of its former region top (unmoved:
        // exactly the old page text), moved anywhere its lines move along.
        var page = Page(); page.paper = .lined
        let tops = page.writingRegionTops
        let top = try XCTUnwrap(tops[.page])
        XCTAssertEqual(top, 16)
        var migrated = TextBox(x: 32, y: top, width: 531, height: 810, text: "Alt"); migrated.flowRegion = .page
        XCTAssertEqual(migrated.rulingAnchorY(regionTops: tops), top)
        migrated.y = 123.4 // moved by the user: same anchor, the lines do not jump
        XCTAssertEqual(migrated.rulingAnchorY(regionTops: tops), top)
        var flow = migrated; flow.flowID = UUID() // text document flow stands on the paper lines
        XCTAssertEqual(flow.rulingAnchorY(regionTops: tops), 123.4)
        XCTAssertNil(TextBox(x: 50, y: 77, text: "neu").rulingAnchorY(regionTops: tops), "new fields: no ruling")
        // A new field starts exactly at the tap (no line or grid alignment).
        let limits = PageRect(x: 0, y: 0, width: 595, height: 842)
        XCTAssertEqual(TextFieldPlacement.frame(tap: p(101.3, 150.7), limits: limits, width: 14, lineHeight: 17),
                       PageRect(x: 101.3, y: 142.2, width: 14, height: 17))
    }
}
