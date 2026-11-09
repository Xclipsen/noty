import Foundation

/// A Lernfeld of the user's vocational training (calendar format 5,
/// docs/LERNFELDER.md). Lessons are assigned to it by `CalendarStudyRule`s;
/// their notes become headed sections of one long-lived notebook.
public struct CalendarStudyField: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    /// 1…99, unique in the area („LF 3“).
    public var number: Int
    public var title: String
    /// The field's notebook by identity; nil until the first lesson note.
    public var notebookID: UUID?
    /// `MaterialCatalog.id` the field was taken from, if any.
    public var package: String?

    public init(id: UUID = UUID(), number: Int, title: String, notebookID: UUID? = nil, package: String? = nil) {
        self.id = id; self.number = number; self.title = title; self.notebookID = notebookID; self.package = package
    }

    /// „LF 3“
    public var shortName: String { "LF \(number)" }
    /// „LF 3 · Umsatzsteuerrechtliche Sachverhalte bearbeiten“
    public var displayName: String { "LF \(number) · \(title)" }
    /// Name of the field's notebook in the library.
    public var notebookTitle: String { "LF \(number) – \(title)".prefix(120).trimmingCharacters(in: .whitespaces) }

    var isValid: Bool {
        (1...99).contains(number) && CalendarState.validTitle(title) == title
            && (package.map(MaterialCatalog.isIdentifier) ?? true)
    }

    private enum CodingKeys: String, CodingKey { case id, number, title, notebookID, package }
}

/// A subject's own notebook („Fach-Heft“, calendar format 6, docs/LERNFELDER.md):
/// every lesson of the subject that no Lernfeld rule claims gets a headed
/// section in this ordinary notebook of the library, chosen by the user (the
/// notebook keeps its identity; nothing is created for it).
public struct CalendarSubjectNotebook: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    /// `CalendarSubjectColor.key(subjectID:name:)`.
    public var subjectKey: String
    /// Shown name of the subject („Religion“).
    public var subjectName: String
    public var notebookID: UUID

    public init(id: UUID = UUID(), subjectKey: String, subjectName: String, notebookID: UUID) {
        self.id = id; self.subjectKey = subjectKey; self.notebookID = notebookID
        self.subjectName = CalendarState.validTitle(subjectName) ?? String(subjectName.prefix(200))
    }

    var isValid: Bool { (1...300).contains(subjectKey.count) && CalendarState.validTitle(subjectName) == subjectName }

    private enum CodingKeys: String, CodingKey { case id, subjectKey, subjectName, notebookID }
}

/// Which lessons belong to a field: a subject (WebUntis subject key, as for
/// subject colours), optionally only on one weekday and/or with a start in a
/// time window. The most specific matching rule wins (weekday and time over
/// weekday over time over subject only); equal ones: the first.
public struct CalendarStudyRule: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    /// `CalendarSubjectColor.key(subjectID:name:)`.
    public var subjectKey: String
    /// Shown name of the subject („SR“).
    public var subjectName: String
    /// ISO weekday 1 = Monday … 7 = Sunday; nil = every day.
    public var weekday: Int?
    /// Start of the lesson in minutes after midnight (school time): from
    /// inclusive, to exclusive; both nil = any time.
    public var startFrom: Int?
    public var startTo: Int?
    public var fieldID: UUID

    public init(id: UUID = UUID(), subjectKey: String, subjectName: String, weekday: Int? = nil, startFrom: Int? = nil,
                startTo: Int? = nil, fieldID: UUID) {
        self.id = id; self.subjectKey = subjectKey; self.subjectName = subjectName; self.weekday = weekday
        self.startFrom = startFrom; self.startTo = startTo; self.fieldID = fieldID
    }

    var specificity: Int { (weekday == nil ? 0 : 2) + (startFrom == nil ? 0 : 1) }

    func matches(subjectKey: String, weekday: Int, startMinutes: Int) -> Bool {
        guard subjectKey == self.subjectKey else { return false }
        if let day = self.weekday, day != weekday { return false }
        if let from = startFrom, let to = startTo, !(from..<to).contains(startMinutes) { return false }
        return true
    }

    var isValid: Bool {
        (1...300).contains(subjectKey.count) && (1...200).contains(subjectName.count)
            && (weekday.map { (1...7).contains($0) } ?? true)
            && ((startFrom == nil && startTo == nil)
                || (startFrom.map { (0..<1440).contains($0) } ?? false) && (startTo.map { (1...1440).contains($0) } ?? false)
                && startFrom! < startTo!)
    }

    /// „SR · Mo · 08:00–10:15“
    public var label: String {
        var parts = [subjectName]
        if let weekday { parts.append(CalendarStudy.weekdayNames[weekday - 1]) }
        if let from = startFrom, let to = startTo { parts.append("ab \(CalendarStudy.clock(from)) bis \(CalendarStudy.clock(to))") }
        return parts.joined(separator: " · ")
    }
}

/// A piece of learning material pinned to a lesson („Festhalten“): the stable
/// key of a `MaterialHit` in a package plus a text snapshot, so the topic card
/// stays readable without the package.
public struct CalendarMaterialRef: Hashable, Sendable, Codable {
    /// `MaterialCatalog.id`.
    public var package: String
    /// `MaterialHit.id`: `lesson:<id>`, `unit:<chapter>:<page>`, `page:<chapter>:<page>`.
    public var key: String
    public var label: String
    /// „LF 3 · Kapitel 4 · S. 5–9“
    public var detail: String?

    public init(package: String, key: String, label: String, detail: String? = nil) {
        self.package = package; self.key = key; self.label = String(label.prefix(300)); self.detail = detail.map { String($0.prefix(300)) }
    }

    var isValid: Bool {
        MaterialCatalog.isIdentifier(package) && (3...200).contains(key.count) && !key.contains("\n")
            && (1...300).contains(label.count) && (detail?.count ?? 0) <= 300
    }
}

/// Topic, own key sentence and pinned material of one lesson block or event
/// (format 5). Belongs to the same target as its note (`CalendarNoteLink`).
public struct CalendarLessonTopic: Identifiable, Equatable, Sendable, Codable {
    public static let maximumMaterials = 30
    public let id: UUID
    public var target: CalendarNoteTarget
    /// „Die Lieferung“; may be empty while only material is pinned.
    public var topic: String
    /// The user's own key sentence („Merksatz“).
    public var summary: String
    public var materials: [CalendarMaterialRef]
    public var modifiedAt: Date

    public init(id: UUID = UUID(), target: CalendarNoteTarget, topic: String = "", summary: String = "",
                materials: [CalendarMaterialRef] = [], modifiedAt: Date = Date()) {
        self.id = id; self.target = target; self.topic = topic; self.summary = summary; self.materials = materials
        self.modifiedAt = modifiedAt
    }

    public var isEmpty: Bool { topic.isEmpty && summary.isEmpty && materials.isEmpty }

    var isValid: Bool {
        topic.count <= 200 && !topic.contains("\n") && summary.count <= 2_000 && materials.count <= Self.maximumMaterials
            && materials.allSatisfy(\.isValid) && Set(materials.map { $0.package + "\n" + $0.key }).count == materials.count
            && CalendarState.validInstant(modifiedAt)
    }

    private enum CodingKeys: String, CodingKey { case id, target, topic, summary, materials, modifiedAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        target = try c.decode(CalendarNoteTarget.self, forKey: .target)
        topic = try c.decodeIfPresent(String.self, forKey: .topic) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        materials = try c.decodeIfPresent([CalendarMaterialRef].self, forKey: .materials) ?? []
        modifiedAt = Date(timeIntervalSinceReferenceDate: try c.decode(Double.self, forKey: .modifiedAt))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(target, forKey: .target)
        if !topic.isEmpty { try c.encode(topic, forKey: .topic) }
        if !summary.isEmpty { try c.encode(summary, forKey: .summary) }
        if !materials.isEmpty { try c.encode(materials, forKey: .materials) }
        try c.encode(modifiedAt.timeIntervalSinceReferenceDate, forKey: .modifiedAt)
    }
}

public enum CalendarStudy {
    public static let maximumFields = 40
    public static let maximumRules = 500
    public static let maximumTopics = 20_000
    public static let maximumSubjectNotebooks = 200
    static let weekdayNames = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]

    static func clock(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }

    /// The field of a lesson, nil without a matching rule.
    public static func field(subjectKey: String, weekday: Int, startMinutes: Int, rules: [CalendarStudyRule],
                             fields: [CalendarStudyField]) -> CalendarStudyField? {
        var best: (rule: CalendarStudyRule, specificity: Int)?
        for rule in rules where rule.matches(subjectKey: subjectKey, weekday: weekday, startMinutes: startMinutes) {
            if best == nil || rule.specificity > best!.specificity { best = (rule, rule.specificity) }
        }
        guard let best else { return nil }
        return fields.first { $0.id == best.rule.fieldID }
    }

    /// ISO weekday (Monday 1) and minutes after midnight of `date` in `timeZone`.
    public static func weekdayAndMinutes(_ date: Date, timeZone: TimeZone) -> (weekday: Int, minutes: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return weekdayAndMinutes(date, calendar: calendar)
    }

    /// The same with a prepared calendar (many lessons in a row).
    public static func weekdayAndMinutes(_ date: Date, calendar: Calendar) -> (weekday: Int, minutes: Int) {
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        let weekday = ((parts.weekday ?? 2) + 5) % 7 + 1
        return (weekday, (parts.hour ?? 0) * 60 + (parts.minute ?? 0))
    }

    /// The lessons of one block: consecutive lessons of the same subject on
    /// the same day with at most `gap` between them. `lessons` must be the
    /// lessons of one day; returns the indices of the block of `index`,
    /// sorted by start. One block gets one heading and one topic.
    public static func block(of index: Int, in lessons: [(subjectKey: String, start: Date, end: Date)],
                             gap: TimeInterval = 20 * 60) -> [Int] {
        guard lessons.indices.contains(index) else { return [] }
        let key = lessons[index].subjectKey
        let order = lessons.indices.filter { lessons[$0].subjectKey == key }.sorted { lessons[$0].start < lessons[$1].start }
        guard let position = order.firstIndex(of: index) else { return [index] }
        var lower = position, upper = position
        while lower > 0, lessons[order[lower]].start.timeIntervalSince(lessons[order[lower - 1]].end) <= gap { lower -= 1 }
        while upper < order.count - 1, lessons[order[upper + 1]].start.timeIntervalSince(lessons[order[upper]].end) <= gap { upper += 1 }
        return Array(order[lower...upper])
    }

    /// The subject notebook of a lesson, nil when the subject has none.
    public static func subjectNotebook(subjectKey: String, in subjects: [CalendarSubjectNotebook]) -> CalendarSubjectNotebook? {
        subjects.first { $0.subjectKey == subjectKey }
    }

    static func validate(fields: [CalendarStudyField], rules: [CalendarStudyRule], topics: [CalendarLessonTopic],
                         subjects: [CalendarSubjectNotebook] = []) throws {
        // One notebook per subject, one subject per notebook, never a Lernfeld's notebook.
        guard subjects.count <= maximumSubjectNotebooks, Set(subjects.map(\.id)).count == subjects.count,
              Set(subjects.map(\.subjectKey)).count == subjects.count,
              Set(subjects.map(\.notebookID)).count == subjects.count, subjects.allSatisfy(\.isValid),
              Set(subjects.map(\.notebookID)).isDisjoint(with: fields.compactMap(\.notebookID)) else { throw CalendarStoreError.invalidState }
        guard fields.count <= maximumFields, rules.count <= maximumRules, topics.count <= maximumTopics,
              Set(fields.map(\.id)).count == fields.count, Set(fields.map(\.number)).count == fields.count,
              fields.allSatisfy(\.isValid),
              Set(fields.compactMap(\.notebookID)).count == fields.compactMap(\.notebookID).count,
              Set(rules.map(\.id)).count == rules.count, rules.allSatisfy(\.isValid),
              rules.allSatisfy({ rule in fields.contains { $0.id == rule.fieldID } }),
              Set(topics.map(\.id)).count == topics.count, Set(topics.map(\.target.key)).count == topics.count,
              topics.allSatisfy(\.isValid) else { throw CalendarStoreError.invalidState }
    }
}
