import Foundation

/// Textneubau Stufe 1 (docs/TEXT-REBUILD-62.md): notebooks hold only free text
/// fields. Schema 14 adds rotation, automatic width and migrated page text
/// (`flowRegion` without `flowID`). The flowing word mode (`TextFlow.swift`)
/// stays for the later text document and is no longer used by notebooks.
extension TextBox {
    /// Lowest notebook schema for rotation, automatic width and migrated page text.
    public static let fieldSchemaVersion = 14

    /// Uses a schema-14 property (also the field style of Stufe 4). Plain
    /// free fields keep their older format.
    public var usesFieldFormat: Bool {
        rotation != nil || autoWidth != nil || (flowID == nil && flowRegion != nil) || fill != nil || border != nil
    }

    /// Rotation in degrees, 0 when unrotated.
    public var angle: Double { rotation ?? 0 }

    /// `degrees` normalised to −180…180; nil for (almost) no rotation, so an
    /// unrotated field never stores the property.
    public static func storedRotation(_ degrees: Double) -> Double? {
        guard degrees.isFinite else { return nil }
        var angle = degrees.truncatingRemainder(dividingBy: 360)
        if angle > 180 { angle -= 360 }
        if angle < -180 { angle += 360 }
        return abs(angle) < 0.01 ? nil : angle
    }

    private var axes: (u: PagePoint, v: PagePoint) {
        let radians = angle * .pi / 180
        let c = cos(radians), s = sin(radians)
        return (PagePoint(x: c, y: s), PagePoint(x: -s, y: c))
    }

    /// Page point of a point in the field's own unrotated coordinates
    /// (origin at its top-left corner).
    public func pagePoint(_ local: PagePoint) -> PagePoint {
        guard angle != 0 else { return PagePoint(x: x + local.x, y: y + local.y) }
        let (u, v) = axes
        return PagePoint(x: x + local.x * u.x + local.y * v.x, y: y + local.x * u.y + local.y * v.y)
    }

    /// The field's own unrotated coordinates of a page point.
    public func localPoint(_ point: PagePoint) -> PagePoint {
        let dx = point.x - x, dy = point.y - y
        guard angle != 0 else { return PagePoint(x: dx, y: dy) }
        let (u, v) = axes
        return PagePoint(x: dx * u.x + dy * u.y, y: dx * v.x + dy * v.y)
    }

    /// Top-left, top-right, bottom-right, bottom-left of the visible field on
    /// the page: the text frame widened by the field style's padding.
    public var corners: [PagePoint] {
        let p = fieldPadding
        return [pagePoint(.init(x: -p, y: -p)), pagePoint(.init(x: width + p, y: -p)),
                pagePoint(.init(x: width + p, y: height + p)), pagePoint(.init(x: -p, y: height + p))]
    }

    /// Corners of the text frame itself (where the text is laid out and clipped).
    public var textCorners: [PagePoint] {
        [pagePoint(.init(x: 0, y: 0)), pagePoint(.init(x: width, y: 0)),
         pagePoint(.init(x: width, y: height)), pagePoint(.init(x: 0, y: height))]
    }

    public var center: PagePoint { pagePoint(.init(x: width / 2, y: height / 2)) }

    /// Axis-aligned bounds of the rotated visible frame (with the style's
    /// padding): page limits, selection, lasso, snapping and transfers.
    public var rotatedBounds: PageRect {
        guard angle != 0 else {
            let p = fieldPadding
            return PageRect(x: x - p, y: y - p, width: width + 2 * p, height: height + 2 * p)
        }
        let points = corners
        let xs = points.map(\.x), ys = points.map(\.y)
        let minX = xs.min()!, minY = ys.min()!
        return PageRect(x: minX, y: minY, width: xs.max()! - minX, height: ys.max()! - minY)
    }

    /// The whole rotated frame lies inside `bounds` (page plus writing space).
    public func fits(in bounds: PageRect, tolerance: Double = 0.01) -> Bool {
        bounds.contains(rotatedBounds, tolerance: tolerance)
    }

    /// Inside the rotated visible frame (with padding), widened by `tolerance` page units.
    public func contains(_ point: PagePoint, tolerance: Double = 0) -> Bool {
        let local = localPoint(point)
        let reach = tolerance + fieldPadding
        return local.x >= -reach && local.x <= width + reach && local.y >= -reach && local.y <= height + reach
    }

    /// The same field turned to `degrees` about its centre (the rotation
    /// handle); the stored pivot moves accordingly.
    public func rotated(to degrees: Double) -> TextBox {
        let middle = center
        var result = self
        result.rotation = Self.storedRotation(degrees)
        let offset = result.pagePoint(.init(x: width / 2, y: height / 2))
        result.x += middle.x - offset.x; result.y += middle.y - offset.y
        return result
    }

    /// Shifted completely into `bounds`, or nil if the rotated frame is larger.
    public func shifted(into bounds: PageRect) -> TextBox? {
        let frame = rotatedBounds
        guard let offset = CrossPageTransfer.shift(for: frame, into: bounds) else { return nil }
        var result = self; result.x += offset.x; result.y += offset.y
        return result
    }

    /// Widest frame (same pivot, rotation and height) that still fits in
    /// `bounds`; at least `minimum`. Automatic width grows up to this.
    public func maximumWidth(in bounds: PageRect, minimum: Double = 1) -> Double {
        var probe = self
        func fits(_ w: Double) -> Bool { probe.width = w; return probe.fits(in: bounds, tolerance: 0) }
        guard fits(minimum) else { return minimum }
        var low = minimum, high = 14_400.0
        if fits(high) { return high }
        for _ in 0..<40 {
            let middle = (low + high) / 2
            if fits(middle) { low = middle } else { high = middle }
        }
        return low
    }

    /// Tallest frame (same pivot, rotation and width) inside `bounds`: the
    /// field never grows off the page; more text is marked as overflow.
    public func maximumHeight(in bounds: PageRect, minimum: Double = 1) -> Double {
        var probe = self
        func fits(_ h: Double) -> Bool { probe.height = h; return probe.fits(in: bounds, tolerance: 0) }
        guard fits(minimum) else { return minimum }
        var low = minimum, high = 14_400.0
        if fits(high) { return high }
        for _ in 0..<40 {
            let middle = (low + high) / 2
            if fits(middle) { low = middle } else { high = middle }
        }
        return low
    }
}

/// Soft rotation snapping of the field handle: strong at 0/90/180/270°,
/// weaker at the 45° diagonals.
public enum TextFieldRotation {
    public static let rightAngleReach = 6.0
    public static let diagonalReach = 2.5

    /// The angle to show and store, and the snap target if it engaged.
    public static func snapped(_ degrees: Double) -> (angle: Double, target: Double?) {
        let angle = TextBox.storedRotation(degrees) ?? 0
        let right = (angle / 90).rounded() * 90
        if abs(angle - right) <= rightAngleReach { return (right == -180 ? 180 : right, right == -180 ? 180 : right) }
        let diagonal = (angle / 45).rounded() * 45
        if abs(angle - diagonal) <= diagonalReach { return (diagonal, diagonal) }
        return (angle, nil)
    }

    /// Whole degrees for the small angle label (0…359).
    public static func label(_ degrees: Double) -> String {
        let whole = Int((degrees.truncatingRemainder(dividingBy: 360) + 360).rounded()) % 360
        return "\(whole)°"
    }
}

/// Where a tap opens a new field: the caret starts at the tap, the first line
/// is vertically centred on it; always completely on the page.
public enum TextFieldPlacement {
    public static func frame(tap: PagePoint, limits: PageRect, width: Double, lineHeight: Double) -> PageRect? {
        guard [tap.x, tap.y, width, lineHeight].allSatisfy(\.isFinite), width > 0, lineHeight > 0,
              limits.width >= width, limits.height >= lineHeight else { return nil }
        let x = max(limits.x, min(tap.x, limits.x + limits.width - width))
        let y = max(limits.y, min(tap.y - lineHeight / 2, limits.y + limits.height - lineHeight))
        return PageRect(x: x, y: y, width: width, height: lineHeight)
    }
}

/// Stage 2 (weiches Einrasten) plugs in here: it may adjust a proposed move
/// before the page limits apply.
public protocol MoveSnapping {
    func adjusted(_ translation: PagePoint, moving frame: PageRect) -> PagePoint
}

/// The one place object moves pass through (lasso and finger selections,
/// text fields dragged at their border): snapping first, then the page limits.
public enum ObjectMovement {
    public static func translation(moving frame: PageRect, by proposed: PagePoint, within limits: PageRect,
                                   snapping: MoveSnapping? = nil) -> PagePoint {
        let wanted = snapping?.adjusted(proposed, moving: frame) ?? proposed
        return SelectionTransform(frame: frame, anchor: .init(x: frame.x, y: frame.y), translation: wanted,
                                  scale: 1, limits: limits).translation
    }
}

extension Array where Element == TextBox {
    /// „Nach vorne“: drawn last (on top of the other fields); „Nach hinten“: first.
    public func movingField(_ id: UUID, toFront: Bool) -> [TextBox] {
        guard let index = firstIndex(where: { $0.id == id }) else { return self }
        var result = self
        let box = result.remove(at: index)
        if toFront { result.append(box) } else { result.insert(box, at: 0) }
        return result
    }
}

extension Page {
    /// Page text (flow segments) becomes free fields at exactly the same frame
    /// with the same text, runs and style; the region stays as layout
    /// (ruling, coordinate units). Empty segments carry no text and vanish.
    public func migratingTextFlow() -> Page {
        guard let boxes = textBoxes, boxes.contains(where: { $0.flowID != nil }) else { return self }
        var result = self
        result.textBoxes = boxes.compactMap { box in
            guard box.flowID != nil else { return box }
            guard !box.text.isEmpty else { return nil }
            var field = box; field.flowID = nil
            return field
        }
        return result
    }
}

extension Page {
    /// Top (page y) of each writing region that exists on this page.
    public var writingRegionTops: [TextFlowRegion: Double] {
        var tops: [TextFlowRegion: Double] = [:]
        for region in [TextFlowRegion.page, .left, .right, .top, .bottom] { tops[region] = writingRect(region)?.y }
        return tops
    }
}

extension TextBox {
    /// Page y the ruled line layout of this box is anchored at (nil: no
    /// ruling). Flow segments stand on the paper lines from their own top.
    /// Fields migrated from page text keep the layout they had at the top of
    /// their former region, wherever they are moved: their lines move with
    /// the field instead of jumping onto the paper lines (Feedback zu Build
    /// 62). Unmoved, this is exactly the old layout (segments start there).
    public func rulingAnchorY(regionTops: [TextFlowRegion: Double]) -> Double? {
        guard let region = flowRegion else { return nil }
        if flowID != nil { return y }
        return regionTops[region] ?? y
    }
}

extension Notebook {
    /// Any stored flow segment (active pages or page trash).
    public var containsTextFlow: Bool {
        (pages + (deletedPages ?? []).map(\.page)).contains { ($0.textBoxes ?? []).contains { $0.flowID != nil } }
    }

    /// Notebooks hold only free fields (schema 14). Applied in memory while
    /// decoding (`NotebookDecoding`), never written by merely opening: the
    /// first commit stores schema 14 after `RevisionStore` archived the exact
    /// confirmed old bytes. Active pages and the page trash alike.
    public func migratedTextFlow() throws -> Notebook {
        guard containsTextFlow else { return self }
        var next = self
        next.pages = pages.map { $0.migratingTextFlow() }
        if let deleted = deletedPages {
            next.deletedPages = deleted.map { entry in
                DeletedPage(page: entry.page.migratingTextFlow(), originalIndex: entry.originalIndex, deletedAt: entry.deletedAt,
                            nextPageID: entry.nextPageID, previousPageID: entry.previousPageID, reason: entry.reason)
            }
        }
        next.schemaVersion = max(TextBox.fieldSchemaVersion, next.schemaVersion)
        try next.validate()
        return next
    }

    /// Every text write path calls this next to `raiseSchemaForTextColors`;
    /// it only ever raises the schema.
    public mutating func raiseSchemaForTextFields(_ boxes: [TextBox]) {
        if boxes.contains(where: \.usesFieldFormat) { schemaVersion = max(TextBox.fieldSchemaVersion, schemaVersion) }
    }
}
