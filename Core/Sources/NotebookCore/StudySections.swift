import Foundation

/// A lesson section of a Lernfeld notebook: the page a lesson link points to
/// (its heading page) and every following page up to the next section's
/// heading page. Derived from the calendar's note links, nothing is stored
/// in the notebook besides the ordinary heading text field.
public struct StudySection: Identifiable, Equatable, Sendable {
    public var id: UUID { linkID }
    public var linkID: UUID
    public var target: CalendarNoteTarget
    /// Heading page and the pages of the section in notebook order.
    public var pageIDs: [UUID]
    public var start: Date
    public var end: Date
    public var title: String
    public var topic: String
    public var headingPageID: UUID { pageIDs[0] }
    public var lastPageID: UUID { pageIDs[pageIDs.count - 1] }
}

public enum StudySections {
    /// Sections of `notebook` from the links pointing into it, in page order.
    /// Links without page or to a page that no longer exists are left out;
    /// two links on one page: the earlier lesson keeps it.
    public static func sections(of notebook: Notebook, links: [CalendarNoteLink],
                                topics: [CalendarLessonTopic] = []) -> [StudySection] {
        let order = Dictionary(notebook.pages.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        let topicByTarget = Dictionary(topics.map { ($0.target.key, $0.topic) }, uniquingKeysWith: { a, _ in a })
        var byPage: [Int: CalendarNoteLink] = [:]
        for link in links where link.documentID == notebook.id {
            guard let page = link.pageID, let index = order[page] else { continue }
            if let existing = byPage[index], existing.contextStart <= link.contextStart { continue }
            byPage[index] = link
        }
        let starts = byPage.keys.sorted()
        return starts.enumerated().map { position, index in
            let link = byPage[index]!
            let stop = position + 1 < starts.count ? starts[position + 1] : notebook.pages.count
            return StudySection(linkID: link.id, target: link.target, pageIDs: notebook.pages[index..<stop].map(\.id),
                                start: link.contextStart, end: link.contextEnd, title: link.contextTitle,
                                topic: topicByTarget[link.target.key] ?? "")
        }
    }

    /// Where the heading page of a lesson starting at `start` goes: after the
    /// last page of the latest earlier section; before the earliest section
    /// if all are later; at the end of a notebook without sections.
    public static func insertionIndex(for start: Date, in notebook: Notebook, sections: [StudySection]) -> Int {
        let order = Dictionary(notebook.pages.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        if let earlier = sections.filter({ $0.start <= start }).max(by: { $0.start < $1.start }),
           let last = order[earlier.lastPageID] {
            return last + 1
        }
        if let later = sections.min(by: { $0.start < $1.start }), let first = order[later.headingPageID] {
            return first
        }
        return notebook.pages.count
    }

    /// The section a page belongs to.
    public static func section(containing page: UUID, in sections: [StudySection]) -> StudySection? {
        sections.first { $0.pageIDs.contains(page) }
    }

    /// „Mo 10.11.2026 · SR · 1.–3. Std.“ style heading of a lesson block.
    public static func heading(subject: String, start: Date, end: Date, topic: String, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.weekday, .day, .month, .year, .hour, .minute], from: start)
        let endParts = calendar.dateComponents([.hour, .minute], from: end)
        let weekday = CalendarStudy.weekdayNames[((parts.weekday ?? 2) + 5) % 7]
        let date = String(format: "%@ %02d.%02d.%04d", weekday, parts.day ?? 1, parts.month ?? 1, parts.year ?? 2000)
        let time = String(format: "%02d:%02d–%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, endParts.hour ?? 0, endParts.minute ?? 0)
        var text = "\(date) · \(subject) · \(time)"
        let topic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        if !topic.isEmpty { text += " – \(topic)" }
        return String(text.prefix(300))
    }
}

extension Notebook {
    /// A new page at `index` (the notebook's page defaults) with `heading`
    /// as a bold text field at the top: the start of a lesson section.
    public mutating func insertSectionPage(heading: String, at index: Int) throws -> UUID {
        var next = self
        let defaults = next.pageDefaults
        let id = try next.insertPaper(defaults.paper, color: defaults.color, at: index, geometry: next.appearance?.geometry)
        guard let page = next.pages.first(where: { $0.id == id }) else { throw PageOperationError.missingPage }
        let size = page.geometry?.displaySize ?? .a4
        let style = TextBoxStyle(fontSize: 18, bold: true, color: defaults.color == .dark ? .white : .black)
        var box = TextBox(x: 40, y: 32, width: max(60, size.width - 80), height: 26, text: heading, style: style)
        box.height = Self.sectionHeadingHeight(heading, width: box.width, fontSize: style.fontSize)
        try next.replaceTextBoxes([box], pageID: id)
        self = next
        return id
    }

    /// A generous height for a bold heading of `text` in `width` (wider
    /// glyphs assumed than most): the field never cuts its text off.
    public static func sectionHeadingHeight(_ text: String, width: Double, fontSize: Double) -> Double {
        let perLine = max(8, Int(width / (fontSize * 0.62)))
        let lines = max(1, (text.count + perLine - 1) / perLine)
        return Double(lines) * fontSize * 1.35 + 4
    }
}
