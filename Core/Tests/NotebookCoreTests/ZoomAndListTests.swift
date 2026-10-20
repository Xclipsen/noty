import XCTest
@testable import NotebookCore

final class ZoomAndListTests: XCTestCase {
    private func apply(_ edits: [TextListEditing.Edit], to text: String) -> String {
        let value = NSMutableString(string: text)
        for edit in edits.reversed() { value.replaceCharacters(in: edit.range, with: edit.replacement) }
        return value as String
    }
    func testEachListButtonTogglesOnAndOffWithoutStackingMarkers() {
        for kind in [TextListEditing.Kind.bullet, .numbered] {
            let source = "Erste\nZweite\nDritte"
            let range = NSRange(location: 0, length: (source as NSString).length)
            let on = TextListEditing.toggle(kind, in: source, range: range)
            let listed = apply(on, to: source)
            XCTAssertTrue(TextListEditing.isActive(kind, in: listed, range: .init(location: 0, length: (listed as NSString).length)))
            let off = TextListEditing.toggle(kind, in: listed, range: .init(location: 0, length: (listed as NSString).length))
            XCTAssertEqual(apply(off, to: listed), source)
        }
        let tasks = "☑ fertig\n☐ offen"
        XCTAssertEqual(apply(TextListEditing.toggle(.checkbox, in: tasks, range: .init(location: 0, length: (tasks as NSString).length)), to: tasks), "☑ fertig\n☑ offen")
    }
    func testSwitchingListKindKeepsIndentUnicodeAndOnlyEditsPrefixes() {
        let text = "  • 👨‍👩‍👧‍👦\n\t9. é"
        let edits = TextListEditing.toggle(.numbered, in: text, range: .init(location: 0, length: (text as NSString).length))
        XCTAssertEqual(apply(edits, to: text), "  1. 👨‍👩‍👧‍👦\n\t2. é")
        XCTAssertEqual(edits.map(\.range.length), [2,3])
        XCTAssertEqual(edits[0].range.location, 2)
    }
    func testCaretFollowsEmptyListToggleAndDoesNotSelectNextLineAtBoundary() {
        let start = NSRange(location: 0, length: 0)
        let on = TextListEditing.toggle(.checkbox, in: "", range: start)
        XCTAssertEqual(TextListEditing.selection(start, after: on), .init(location: 2, length: 0))
        let off = TextListEditing.toggle(.checkbox, in: "☑ ", range: .init(location: 2, length: 0))
        XCTAssertEqual(TextListEditing.selection(.init(location: 2, length: 0), after: off), start)
        let text = "one\ntwo"
        let edits = TextListEditing.toggle(.bullet, in: text, range: .init(location: 0, length: 4))
        XCTAssertEqual(apply(edits, to: text), "• one\ntwo")
        XCTAssertTrue(TextListEditing.toggle(.bullet, in: text, range: .init(location: -1, length: 0)).isEmpty)
    }
    func testChangingListKindAtCaretConvertsConnectedEntriesIncludingEmptyLastItem() {
        let tasks = "Davor\n☐ Hey\n☐ \nDanach"
        let caret = ("Davor\n☐ Hey\n☐ " as NSString).length
        let bullets = TextListEditing.toggle(.bullet, in: tasks, range: .init(location: caret, length: 0))
        XCTAssertEqual(apply(bullets, to: tasks), "Davor\n• Hey\n• \nDanach")
        let numbered = TextListEditing.toggle(.numbered, in: "• Hey\n• Hey\n• ", range: .init(location: 14, length: 0))
        XCTAssertEqual(apply(numbered, to: "• Hey\n• Hey\n• "), "1. Hey\n2. Hey\n3. ")
    }
    func testListConversionStopsAtIndentationOrNormalParagraphAndRespectsExplicitSelection() {
        let source = "• eins\n  • unter\n• zwei\nNormal\n• drei"
        let edits = TextListEditing.toggle(.numbered, in: source, range: .init(location: 20, length: 0))
        XCTAssertEqual(apply(edits, to: source), "• eins\n  • unter\n1. zwei\nNormal\n• drei")
        let selected = TextListEditing.toggle(.numbered, in: "• eins\n• zwei", range: .init(location: 9, length: 2))
        XCTAssertEqual(apply(selected, to: "• eins\n• zwei"), "• eins\n1. zwei")
    }
    func testIndentedListEnterContinuesAndSecondEnterExits() throws {
        let source = "  2. Hey"
        let next = try XCTUnwrap(TextListEditing.newline(in: source, range: .init(location: (source as NSString).length, length: 0)))
        XCTAssertEqual(next.replacement, "\n  3. ")
        let empty = "  3. "
        let exit = try XCTUnwrap(TextListEditing.newline(in: empty, range: .init(location: (empty as NSString).length, length: 0)))
        XCTAssertEqual(apply([exit], to: empty), "")
    }
    func testSingleDestinationCombinesElasticScaleAndWholePageFocus() throws {
        let range = NotebookViewportGeometry.zoomRange(viewport: .init(width: 900, height: 1000), page: .a4)
        let page = PageRect(x: 100, y: 900, width: 595, height: 842)
        let target = try XCTUnwrap(NotebookViewportGeometry.zoomDestination(scale: range.minimum * 0.7, range: range,
            page: page, widthRegion: page, viewport: .init(width: 900, height: 1000), center: .init(x: 30, y: 400)))
        XCTAssertEqual(target.scale, range.minimum)
        XCTAssertEqual(target.offset.x, (100 + 595.0 / 2) * range.minimum - 450, accuracy: 0.0001)
        XCTAssertEqual(target.offset.y, 400 * range.minimum - 500, accuracy: 0.0001)
        XCTAssertLessThan(NotebookViewportGeometry.elasticMinimum(range), range.minimum)
    }
    func testWidthSnapKeepsVerticalReadingPositionAndStrongZoomStaysFree() throws {
        let range = NotebookViewportGeometry.zoomRange(viewport: .init(width: 900, height: 800), page: .a4)
        let page = PageRect(x: 20, y: 0, width: 595, height: 842)
        let target = try XCTUnwrap(NotebookViewportGeometry.zoomDestination(scale: range.fit * 0.98, range: range,
            page: page, widthRegion: page, viewport: .init(width: 900, height: 800), center: .init(x: 600, y: 700)))
        XCTAssertEqual(target.scale, range.fit)
        XCTAssertEqual(target.offset.y, 700 * range.fit - 400, accuracy: 0.0001)
        XCTAssertNil(NotebookViewportGeometry.zoomDestination(scale: range.fit * 2, range: range,
            page: page, widthRegion: page, viewport: .init(width: 900, height: 800), center: .init(x: 600, y: 700)))
    }
    func testNativeInkZoomAndInverseTransformKeepEveryPointInPlace() {
        for scale in [0.05, 0.5, 1, 2, 6] {
            let plan = InkRenderViewport(page: .a4, visible: .init(x: 100, y: 180, width: 200, height: 250), scale: scale)
            let p = PagePoint(x: 220, y: 320)
            let native = PagePoint(x: p.x * scale, y: p.y * scale)
            let displayed = PagePoint(x: plan.frame.x + (native.x - plan.nativeOffset.x) / scale,
                                      y: plan.frame.y + (native.y - plan.nativeOffset.y) / scale)
            XCTAssertEqual(displayed.x, p.x, accuracy: 0.0001); XCTAssertEqual(displayed.y, p.y, accuracy: 0.0001)
        }
    }
    func testLargePageNativeViewportStaysScreenSizedAndClipsToPage() {
        let scale = 4.0
        let plan = InkRenderViewport(page: .init(width: 14400, height: 14400),
            visible: .init(x: 12000, y: 13000, width: 250, height: 200), scale: scale)
        XCTAssertLessThanOrEqual(plan.nativeSize.width, 1768)
        XCTAssertLessThanOrEqual(plan.nativeSize.height, 1568)
        XCTAssertGreaterThanOrEqual(plan.frame.x, 0)
        let edge = InkRenderViewport(page: .a4, visible: .init(x: -100, y: -100, width: 900, height: 1000), scale: 1)
        XCTAssertEqual(edge.frame, .init(x: 0, y: 0, width: 595, height: 842))
    }
    func testZoomScaleAndFocusUseExactlyTheSameAnimationProgress() {
        let range = NotebookViewportGeometry.zoomRange(viewport: .init(width: 900, height: 1000), page: .a4)
        let target = NotebookViewportGeometry.zoomDestination(scale: range.minimum * 0.7, range: range,
            page: .init(x: 0, y: 0, width: 595, height: 842), widthRegion: .init(x: 0, y: 0, width: 595, height: 842),
            viewport: .init(width: 900, height: 1000), center: .init(x: 10, y: 10))!
        let transition = ZoomTransition(fromScale: 0.3, fromOffset: .init(x: 500, y: 300), destination: target)
        XCTAssertEqual(transition.value(at: 0).scale, 0.3)
        XCTAssertEqual(transition.value(at: 0).offset, .init(x: 500, y: 300))
        XCTAssertEqual(transition.value(at: 1), target)
        let mid = transition.value(at: 0.5)
        let zoomProgress = (mid.scale - 0.3) / (target.scale - 0.3)
        let positionProgress = (mid.offset.x - 500) / (target.offset.x - 500)
        XCTAssertEqual(zoomProgress, positionProgress, accuracy: 0.000001)
    }
    func testInkResolutionBucketsNeverUnderSampleAndViewportMovesInBoundedSteps() {
        for scale in [0.04, 0.3, 1, 1.3, 2.9, 5] {
            let bucket = EditorRenderGeometry.inkScale(displayScale: scale)
            XCTAssertGreaterThanOrEqual(bucket, scale)
            XCTAssertLessThanOrEqual(bucket, scale * sqrt(2) + 0.000001)
        }
        for scale in [6.0, 12, 30] {
            XCTAssertEqual(EditorRenderGeometry.inkScale(displayScale: scale), EditorRenderGeometry.maximumInkScale)
        }
        let a = InkRenderViewport(page: .init(width: 14400, height: 14400), visible: .init(x: 1000, y: 1000, width: 900, height: 900), scale: 1)
        let b = InkRenderViewport(page: .init(width: 14400, height: 14400), visible: .init(x: 1001, y: 1001, width: 900, height: 900), scale: 1)
        XCTAssertEqual(a, b)
    }
    func testFullPlaneResolutionIsBoundedWithoutReducingNormalRetinaDetail() {
        XCTAssertEqual(EditorRenderGeometry.contentScale(size: .a4, displayScale: 1, screenScale: 2), 2)
        let size = PageSize(width: 14400, height: 14400)
        let scale = EditorRenderGeometry.contentScale(size: size, displayScale: 6, screenScale: 2)
        XCTAssertLessThanOrEqual(size.width * size.height * scale * scale, 16_000_001)
    }
}
