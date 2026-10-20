import Foundation

/// Canonical worksheet bounds remain unchanged. Only their placement in the
/// scrolling surface is scaled; PDF, ink and all objects share this transform.
public struct NotebookPagePlacement: Equatable, Sendable {
    public let id: UUID
    public let canvas: PageSize
    public let frame: PageRect
    public let contentFrame: PageRect
    public let scale: Double
    /// Base sheet without writing space (reading width, zoom-out limit). The
    /// fit/snap target is the complete `frame` including the writing space.
    public let readingFrame: PageRect

    public func surfaceRect(for contentRect: PageRect) -> PageRect {
        PageRect(x: contentFrame.x + contentRect.x * scale,
                 y: contentFrame.y + contentRect.y * scale,
                 width: contentRect.width * scale, height: contentRect.height * scale)
    }

    /// Surface x of the sheet's outer edges, writing space included. Writing
    /// scroll lets each edge travel at most to the middle of the screen
    /// (user request 20.10.2026; before: centre of the outermost region to the
    /// opposite screen edge, which pushed narrow writing space almost off screen).
    public var writingScrollAnchors: (left: Double, right: Double) {
        (left: frame.x, right: frame.x + frame.width)
    }
}

public struct NotebookViewportLayout: Equatable, Sendable {
    /// Consecutive sheets touch; only a thin grey rule (drawn in this seam)
    /// separates them, so the notebook reads as one continuous surface.
    public static let pageGap = 2.0
    public let pages: [NotebookPagePlacement]
    public let size: PageSize

    public init(pages: [Page], selectedPageID: UUID, paging: Bool, normalizeWidths: Bool) {
        let visible = paging ? pages.filter { $0.id == selectedPageID } : pages
        let targetWidth = PageSize.a4.width
        let values = visible.map { page in
            let base = page.geometry?.displaySize ?? .a4
            let scale = normalizeWidths ? targetWidth / base.width : 1
            return (page: page, base: base, scale: scale)
        }
        let left = values.map { ($0.page.margins?.left ?? 0) * $0.scale }.max() ?? 0
        let right = values.map { ($0.page.margins?.right ?? 0) * $0.scale }.max() ?? 0
        let width = normalizeWidths ? left + (values.map { $0.base.width * $0.scale }.max() ?? targetWidth) + right
            : values.map { $0.page.textBounds.width }.max() ?? targetWidth
        var y = 0.0
        var result: [NotebookPagePlacement] = []
        for value in values {
            let canvas = value.page.textBounds.size
            let scaledLeft = (value.page.margins?.left ?? 0) * value.scale
            let scaledTop = (value.page.margins?.top ?? 0) * value.scale
            let x = normalizeWidths ? left - scaledLeft : (width - canvas.width) / 2
            let frame = PageRect(x: x, y: y, width: canvas.width * value.scale, height: canvas.height * value.scale)
            let content = PageRect(x: x + scaledLeft, y: y + scaledTop,
                width: value.base.width * value.scale, height: value.base.height * value.scale)
            result.append(NotebookPagePlacement(id: value.page.id, canvas: canvas, frame: frame,
                contentFrame: content, scale: value.scale,
                readingFrame: PageRect(x: content.x, y: content.y,
                    width: content.width,
                    height: content.height)))
            y += frame.height + Self.pageGap
        }
        self.pages = result
        size = PageSize(width: width, height: max(1, y - Self.pageGap))
    }
}
