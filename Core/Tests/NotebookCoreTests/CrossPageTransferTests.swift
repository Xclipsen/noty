import Foundation
import XCTest
@testable import NotebookCore

final class CrossPageTransferTests: XCTestCase {
    private func placement(y: Double, scale: Double, left: Double = 0) -> NotebookPagePlacement {
        let content = PageRect(x: 10 + left * scale, y: y, width: 595 * scale, height: 842 * scale)
        return NotebookPagePlacement(id: UUID(), canvas: .init(width: 595 + left, height: 842),
            frame: PageRect(x: 10, y: y, width: (595 + left) * scale, height: 842 * scale),
            contentFrame: content, scale: scale, readingFrame: content)
    }

    func testMappingKeepsOnScreenPositionAndSize() throws {
        let source = placement(y: 0, scale: 1), target = placement(y: 844, scale: 0.5, left: 100)
        let start = PagePoint(x: 100, y: 700)
        let finger = PagePoint(x: 150, y: 900)
        let move = try XCTUnwrap(CrossPageMove(source: source, target: target, sourceStart: start, surfacePoint: finger))
        XCTAssertEqual(move.scale, 2, accuracy: 1e-9)
        // The grabbed point lands exactly below the finger on the target page.
        let mapped = move.apply(start)
        let surface = target.surfacePoint(forContent: mapped)
        XCTAssertEqual(surface.x, finger.x, accuracy: 1e-9); XCTAssertEqual(surface.y, finger.y, accuracy: 1e-9)
        // Another point keeps its on-screen offset (source scale 1 → offset 20/30).
        let other = target.surfacePoint(forContent: move.apply(.init(x: 120, y: 730)))
        XCTAssertEqual(other.x - finger.x, 20, accuracy: 1e-9); XCTAssertEqual(other.y - finger.y, 30, accuracy: 1e-9)
        let back = target.contentPoint(forSurface: surface)
        XCTAssertEqual(back.x, mapped.x, accuracy: 1e-9); XCTAssertEqual(back.y, mapped.y, accuracy: 1e-9)
        XCTAssertNil(CrossPageMove(sourceOrigin: .init(x: 0, y: 0), sourceScale: 0, targetOrigin: .init(x: 0, y: 0),
            targetScale: 1, sourceStart: start, surfacePoint: finger))
    }

    func testShiftMovesIntoLimitsIncludingNegativeMarginsAndRejectsOversize() throws {
        let limits = PageRect(x: -100, y: 0, width: 695, height: 842)
        XCTAssertEqual(CrossPageTransfer.shift(for: .init(x: 10, y: 10, width: 50, height: 50), into: limits), PagePoint(x: 0, y: 0))
        XCTAssertEqual(CrossPageTransfer.shift(for: .init(x: -130, y: -5, width: 50, height: 50), into: limits), PagePoint(x: 30, y: 5))
        XCTAssertEqual(CrossPageTransfer.shift(for: .init(x: 580, y: 820, width: 50, height: 50), into: limits), PagePoint(x: -35, y: -28))
        XCTAssertNil(CrossPageTransfer.shift(for: .init(x: 0, y: 0, width: 700, height: 10), into: limits))
        XCTAssertNil(CrossPageTransfer.shift(for: .init(x: 0, y: 0, width: 10, height: 900), into: limits))
    }

    func testObjectsScaleWithMoveAndInvalidFontSizesAreRejected() throws {
        let box = TextBox(x: 10, y: 20, width: 100, height: 40, text: "Notiz", style: TextBoxStyle(fontSize: 20))
        let image = ImageObject(data: Data([1]), pixelWidth: 10, pixelHeight: 10, x: 30, y: 40, width: 60, height: 50, rotation: 15)
        let shape = ShapeObject(kind: .rectangle, start: .init(x: 5, y: 5), end: .init(x: 25, y: 45), lineWidth: 3)
        let move = CrossPageMove(scale: 0.5, translation: .init(x: 100, y: -10))
        let moved = try CrossPageTransfer.move(.init(textBoxes: [box], images: [image], shapes: [shape]), by: move)
        XCTAssertEqual(moved.textBoxes[0].id, box.id)
        XCTAssertEqual(moved.textBoxes[0].rect, PageRect(x: 105, y: 0, width: 50, height: 20))
        XCTAssertEqual(moved.textBoxes[0].style.fontSize, 10)
        XCTAssertEqual(moved.images[0].id, image.id)
        XCTAssertEqual(moved.images[0].x, 115); XCTAssertEqual(moved.images[0].y, 10)
        XCTAssertEqual(moved.images[0].width, 30); XCTAssertEqual(moved.images[0].rotation, 15)
        XCTAssertEqual(moved.shapes[0].start, PagePoint(x: 102.5, y: -7.5))
        XCTAssertEqual(moved.shapes[0].lineWidth, 1.5)
        XCTAssertThrowsError(try CrossPageTransfer.move(.init(textBoxes: [box]), by: .init(scale: 0.2, translation: .init(x: 0, y: 0)))) {
            XCTAssertEqual($0 as? CrossPageTransferError, .invalidObject)
        }
        var flow = box; flow.flowID = UUID(); flow.flowRegion = .page
        XCTAssertThrowsError(try CrossPageTransfer.move(.init(textBoxes: [flow]), by: move))
        let shifted = moved.translated(by: .init(x: 1, y: 2))
        XCTAssertEqual(shifted.shapes[0].start, PagePoint(x: 103.5, y: -5.5)); XCTAssertEqual(shifted.textBoxes[0].y, 2)
        XCTAssertEqual(moved.bounds?.x, moved.shapes[0].bounds.x)
    }

    func testInsertingKeepsIdentitiesUnlessTheyCollideAndChecksLimits() throws {
        let existing = ShapeObject(kind: .line, start: .init(x: 10, y: 10), end: .init(x: 50, y: 50))
        var target = PageContent(page: Page()); target.shapes = [existing]
        let fresh = ShapeObject(kind: .line, start: .init(x: 60, y: 60), end: .init(x: 90, y: 90))
        var colliding = fresh; colliding.id = existing.id
        let limits = PageRect(x: 0, y: 0, width: 595, height: 842)
        let result = try CrossPageTransfer.inserting(.init(shapes: [fresh, colliding]), into: target, limits: limits)
        XCTAssertEqual(result.content.shapes.count, 3)
        XCTAssertEqual(result.objects.shapes[0].id, fresh.id)
        XCTAssertNotEqual(result.objects.shapes[1].id, existing.id)
        XCTAssertEqual(Set(result.content.shapes.map(\.id)).count, 3)
        let outside = ShapeObject(kind: .line, start: .init(x: -20, y: 60), end: .init(x: 90, y: 90))
        XCTAssertThrowsError(try CrossPageTransfer.inserting(.init(shapes: [outside]), into: target, limits: limits)) {
            XCTAssertEqual($0 as? CrossPageTransferError, .doesNotFit)
        }
        let remaining = CrossPageTransfer.removing(texts: [], images: [], shapes: [existing.id], from: result.content)
        XCTAssertFalse(remaining.shapes.contains { $0.id == existing.id })
    }

    func testReplaceContentsMovesObjectAtomicallyAndRejectsStaleState() throws {
        var book = Notebook.blank(title: "Verschieben")
        try book.insertPaper(.blank, at: 1)
        let a = book.pages[0].id, b = book.pages[1].id
        let shape = ShapeObject(kind: .line, start: .init(x: 10, y: 10), end: .init(x: 50, y: 50))
        try book.replaceShapes([shape], pageID: a)
        let sourceBefore = PageContent(page: book.pages[0]), targetBefore = PageContent(page: book.pages[1])
        var sourceAfter = sourceBefore; sourceAfter.shapes = []
        var targetAfter = targetBefore; targetAfter.shapes = [shape.translated(x: 5, y: 5)]
        let changes = [PageContentReplacement(pageID: a, expected: sourceBefore, replacement: sourceAfter),
                       PageContentReplacement(pageID: b, expected: targetBefore, replacement: targetAfter)]
        // Target first: the same identity briefly exists twice and must still pass.
        try book.replaceContents(changes.reversed())
        XCTAssertEqual(book.pages[0].shapes ?? [], [])
        XCTAssertEqual(book.pages[1].shapes?.first?.id, shape.id)
        // Replaying the same step is stale and changes nothing.
        let moved = book
        XCTAssertThrowsError(try book.replaceContents(changes)) { XCTAssertEqual($0 as? CrossPageTransferError, .conflict) }
        XCTAssertEqual(book, moved)
        // A single invalid page keeps every page unchanged.
        var invalid = targetAfter; invalid.shapes[0].end.x = 10_000
        XCTAssertThrowsError(try book.replaceContents([changes[0].inverted,
            PageContentReplacement(pageID: b, expected: targetAfter, replacement: invalid)]))
        XCTAssertEqual(book, moved)
        // Undo is the inverted, equally atomic operation.
        try book.replaceContents(changes.map(\.inverted))
        XCTAssertEqual(PageContent(page: book.pages[0]), sourceBefore)
        XCTAssertEqual(PageContent(page: book.pages[1]), targetBefore)
        XCTAssertThrowsError(try book.replaceContents([changes[0], changes[0]]))
        XCTAssertThrowsError(try book.replaceContents([]))
    }

    // Image tool: one image dragged onto the next page (writing space left of
    // the target sheet, so its canonical x starts negative).
    private func image(x: Double = 200, y: Double = 700, width: Double = 120, height: Double = 90) -> ImageObject {
        ImageObject(data: Data([0x89, 1, 2, 3]), pixelWidth: 400, pixelHeight: 300, x: x, y: y, width: width, height: height,
                    rotation: 30, crop: .init(x: 0.1, y: 0.2, width: 0.5, height: 0.6))
    }

    func testImageDroppedOnNextPageLandsBelowFingerWithSameIdentity() throws {
        let source = placement(y: 0, scale: 1), target = placement(y: 844, scale: 1, left: 100)
        let original = image()
        let grab = PagePoint(x: 230, y: 720)
        let finger = PagePoint(x: 260, y: 1100)
        let move = try XCTUnwrap(CrossPageMove(source: source, target: target, sourceStart: grab, surfacePoint: finger))
        let limits = PageRect(x: -100, y: 0, width: 695, height: 842)
        let placed = try CrossPageTransfer.place(.init(images: [original]), by: move, into: PageContent(page: Page()), limits: limits)
        let moved = try XCTUnwrap(placed.content.images.first)
        XCTAssertEqual(placed.offset, PagePoint(x: 0, y: 0))
        XCTAssertEqual(moved.id, original.id); XCTAssertEqual(moved.data, original.data)
        XCTAssertEqual(moved.crop, original.crop); XCTAssertEqual(moved.rotation, original.rotation)
        XCTAssertEqual(moved.locked, original.locked)
        XCTAssertEqual(moved.width, original.width); XCTAssertEqual(moved.height, original.height)
        // The grabbed point (30/20 inside the image) stays below the finger.
        let surface = target.surfacePoint(forContent: .init(x: moved.x + 30, y: moved.y + 20))
        XCTAssertEqual(surface.x, finger.x, accuracy: 1e-9); XCTAssertEqual(surface.y, finger.y, accuracy: 1e-9)
        // Target canonical coordinates: page gap and the 100-pt writing space.
        XCTAssertEqual(moved.x, 260 - 10 - 100 - 30, accuracy: 1e-9)
        XCTAssertEqual(moved.y, 1100 - 844 - 20, accuracy: 1e-9)
    }

    func testImageDroppedAtTargetEdgeIsShiftedInsideNeverClippedOrShrunk() throws {
        let source = placement(y: 0, scale: 1), target = placement(y: 844, scale: 0.5, left: 100)
        let original = image()
        let grab = PagePoint(x: 230, y: 720)
        // Finger at the far left of the target's writing space.
        let finger = PagePoint(x: 11, y: 845)
        let move = try XCTUnwrap(CrossPageMove(source: source, target: target, sourceStart: grab, surfacePoint: finger))
        let limits = PageRect(x: -100, y: 0, width: 695, height: 842)
        let placed = try CrossPageTransfer.place(.init(images: [original]), by: move, into: PageContent(page: Page()), limits: limits)
        let moved = try XCTUnwrap(placed.objects.images.first)
        XCTAssertTrue(moved.fits(in: limits))
        XCTAssertGreaterThan(placed.offset.x, 0); XCTAssertGreaterThan(placed.offset.y, 0)
        // Same on-screen size: source scale 1, target scale 0.5.
        XCTAssertEqual(moved.width, original.width * 2, accuracy: 1e-9)
        XCTAssertEqual(moved.rotatedBounds.x, limits.x, accuracy: 1e-6)
        XCTAssertEqual(moved.rotatedBounds.y, limits.y, accuracy: 1e-6)
        // Larger than the target's writable area: refused instead of clipped.
        let huge = image(x: 0, y: 0, width: 590, height: 400)
        XCTAssertThrowsError(try CrossPageTransfer.place(.init(images: [huge]), by: move, into: PageContent(page: Page()), limits: limits)) {
            XCTAssertEqual($0 as? CrossPageTransferError, .doesNotFit)
        }
    }

    func testFullTargetPageRefusesImageWithClearMessage() throws {
        var target = PageContent(page: Page())
        target.images = (0..<ImageLimits.maximumImagesPerPage).map { image(x: Double($0), y: 10, width: 20, height: 20) }
        let move = CrossPageMove(scale: 1, translation: .init(x: 0, y: -600))
        let limits = PageRect(x: 0, y: 0, width: 595, height: 842)
        XCTAssertThrowsError(try CrossPageTransfer.place(.init(images: [image()]), by: move, into: target, limits: limits)) {
            XCTAssertEqual($0 as? CrossPageTransferError, .pageFull)
        }
        let text = CrossPageTransferError.pageFull.message(image: true)
        XCTAssertTrue(text.contains("\(ImageLimits.maximumImagesPerPage) Bilder")); XCTAssertTrue(text.contains("bleibt"))
        XCTAssertEqual(CrossPageTransferError.pageFull.errorDescription, CrossPageTransferError.pageFull.message(image: false))
        XCTAssertTrue(CrossPageTransferError.doesNotFit.message(image: true).hasPrefix("Das Bild"))
        // One slot left: accepted.
        target.images.removeLast()
        XCTAssertEqual(try CrossPageTransfer.place(.init(images: [image()]), by: move, into: target, limits: limits).content.images.count,
                       ImageLimits.maximumImagesPerPage)
    }

    func testImageTransferIsOneAtomicReplacementWithInverse() throws {
        var book = Notebook.blank(title: "Bild verschieben")
        try book.insertPaper(.blank, at: 1)
        let a = book.pages[0].id, b = book.pages[1].id
        var locked = image(x: 20, y: 20, width: 40, height: 30); locked.locked = true
        let original = image()
        try book.replaceImages([locked, original], pageID: a)
        let sourceBefore = PageContent(page: book.pages[0]), targetBefore = PageContent(page: book.pages[1])
        var sourceAfter = sourceBefore; sourceAfter.images.removeAll { $0.id == original.id }
        let placed = try CrossPageTransfer.place(.init(images: [original]), by: .init(scale: 1, translation: .init(x: 0, y: -600)),
                                                 into: targetBefore, limits: book.pages[1].textBounds)
        let changes = [PageContentReplacement(pageID: a, expected: sourceBefore, replacement: sourceAfter),
                       PageContentReplacement(pageID: b, expected: targetBefore, replacement: placed.content)]
        try book.replaceContents(changes)
        XCTAssertEqual(book.pages[0].images?.map(\.id), [locked.id])
        XCTAssertEqual(book.pages[1].images?.first?.id, original.id)
        XCTAssertEqual(book.pages[1].images?.first?.data, original.data)
        XCTAssertEqual(book.pages[1].images?.first?.y ?? 0, 100, accuracy: 1e-9)
        try book.replaceContents(changes.map(\.inverted))
        XCTAssertEqual(PageContent(page: book.pages[0]), sourceBefore)
        XCTAssertEqual(PageContent(page: book.pages[1]), targetBefore)
    }
}
