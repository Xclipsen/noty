import Foundation

/// „Inhalt“ of a notebook (not a text document): the paragraphs of its free
/// text fields set as Titel or Überschrift, in page order and, on a page, from
/// top to bottom. Read-only and pure; a tap in the page list jumps to the
/// page. Unterüberschriften are left out so the list stays an overview (a
/// lesson heading of a Lernfeld notebook is one and is listed as „Stunde“).
public struct NotebookHeading: Equatable, Identifiable, Sendable {
    public var id: String { "\(boxID.uuidString)-\(location)" }
    public let preset: TextStylePreset
    public let text: String
    public let pageID: UUID
    public let pageIndex: Int
    public let boxID: UUID
    /// UTF-16 start of the paragraph in the field.
    public let location: Int
}

extension Notebook {
    public static let headingLimit = 400
    static let headingTextLimit = 90

    public var fieldHeadings: [NotebookHeading] {
        var result: [NotebookHeading] = []
        for (index, page) in pages.enumerated() {
            let boxes = (page.textBoxes ?? []).filter { $0.flowID == nil }.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
            for box in boxes {
                let text = box.text as NSString
                var location = 0
                while location <= text.length {
                    let line = text.lineRange(for: NSRange(location: min(location, text.length), length: 0))
                    let paragraph = text.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !paragraph.isEmpty {
                        let preset = TextStylePreset.matching(box.style(at: line.location))
                        if preset == .title || preset == .heading {
                            let short = paragraph.count > Self.headingTextLimit ? String(paragraph.prefix(Self.headingTextLimit - 1)) + "…" : paragraph
                            result.append(NotebookHeading(preset: preset, text: short, pageID: page.id, pageIndex: index,
                                                          boxID: box.id, location: line.location))
                            if result.count >= Self.headingLimit { return result }
                        }
                    }
                    guard line.length > 0, line.location + line.length < text.length else { break }
                    location = line.location + line.length
                }
            }
        }
        return result
    }
}
