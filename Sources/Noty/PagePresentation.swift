import UIKit
import PDFKit
import NotebookCore

extension Page {
    /// No PDF parsing/rendering during SwiftUI layout. Legacy pages retain A4.
    var previewAspectRatio: CGFloat {
        let base = geometry?.displaySize ?? .a4
        return (base.width + (margins?.left ?? 0) + (margins?.right ?? 0))
            / (base.height + (margins?.top ?? 0) + (margins?.bottom ?? 0))
    }
}

extension PageRect {
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    init(_ rect: CGRect) { self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height) }
}

extension PageSize {
    var cgSize: CGSize { CGSize(width: width, height: height) }
    var bounds: CGRect { CGRect(origin: .zero, size: cgSize) }
}

extension PageTransform {
    var cgTransform: CGAffineTransform { CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty) }
}

extension PDFPageGeometry {
    init(_ page: CGPDFPage) throws {
        try self.init(mediaBox: PageRect(page.getBoxRect(.mediaBox)),
                      cropBox: PageRect(page.getBoxRect(.cropBox)), rotation: Int(page.rotationAngle))
    }

    static var testPaper: PDFPageGeometry {
        try! PDFPageGeometry(mediaBox: .init(x: 0, y: 0, width: 595, height: 842),
                             cropBox: .init(x: 0, y: 0, width: 595, height: 842), rotation: 0)
    }
}

extension PageLayout {
    init(page: Page, source: CGPDFPage?) throws {
        let sourceGeometry = try source.map { try PDFPageGeometry($0) } ?? page.geometry ?? .testPaper
        if let stored = page.geometry, stored != sourceGeometry { throw StorageError.invalidDocument }
        self.init(source: sourceGeometry, legacyA4: page.geometry == nil, margins: page.margins)
    }

    var textFrame: CGRect {
        CGRect(x: contentOrigin.x + contentCanvas.width * 48 / 595,
               y: contentOrigin.y + contentCanvas.height * 625 / 842,
               width: contentCanvas.width * 499 / 595, height: contentCanvas.height * 169 / 842)
    }

    var textInsets: UIEdgeInsets {
        // Version-1 UITextView used 8pt vertical inset plus 5pt line padding.
        let horizontal: CGFloat = legacyA4 ? 5 : 8
        return UIEdgeInsets(top: 8, left: horizontal, bottom: 8, right: horizontal)
    }
    var textContentFrame: CGRect { textFrame.inset(by: textInsets) }
    var canonicalInkBounds: CGRect {
        CGRect(x: -contentOrigin.x, y: -contentOrigin.y, width: canvas.width, height: canvas.height)
    }
    var inkTranslation: CGAffineTransform { CGAffineTransform(translationX: contentOrigin.x, y: contentOrigin.y) }
}
