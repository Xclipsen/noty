import Foundation

public enum NotebookCover: String, Codable, CaseIterable, Sendable {
    case blue, purple, green, yellow, coral, gray
}

public enum PaperFormat: String, Codable, CaseIterable, Sendable {
    case a4, a5, a3, letter
    public var size: PageSize {
        switch self {
        case .a4: .init(width: 595, height: 842)
        case .a5: .init(width: 420, height: 595)
        case .a3: .init(width: 842, height: 1191)
        case .letter: .init(width: 612, height: 792)
        }
    }
}

public struct NotebookAppearance: Codable, Equatable, Sendable {
    public var coverEnabled = true
    public var cover: NotebookCover = .blue
    public var format: PaperFormat = .a4
    public var landscape = false
    public var paper: PaperStyle = .blank
    public var color: PaperColor = .white
    public init() {}
    public var geometry: PDFPageGeometry {
        let size = format.size
        let box = PageRect(x: 0, y: 0, width: landscape ? size.height : size.width,
                          height: landscape ? size.width : size.height)
        return try! PDFPageGeometry(mediaBox: box, cropBox: box, rotation: 0)
    }
    public func validate() throws {
        guard paper != .legacyTest else { throw StorageError.invalidDocument }
    }
}

extension Notebook {
    public static func blank(title: String, appearance: NotebookAppearance) throws -> Notebook {
        try appearance.validate()
        var result = blank(title: title)
        result.schemaVersion = 7; result.appearance = appearance
        result.pages[0].geometry = appearance.geometry
        result.pages[0].paper = appearance.paper; result.pages[0].paperColor = appearance.color
        try result.validate()
        return result
    }
}
