import Foundation

// Hausaufgaben aus WebUntis (docs/CALENDAR-PLAN.md, 06.11.2026). The mobile
// API attaches homework to the periods of `getTimetable2017` (`homeWorks`:
// id, lessonId, startDate, endDate, text, remark, completed, attachments).
// The field names come from community clients and are UNVERIFIED against the
// user's school; a period without them simply has no homework. The homework
// lives in the replaceable offline cache (like the lessons). Only the user's
// own „erledigt“ mark is confirmed local data (calendar format 4) – it is
// never sent to WebUntis.

/// One homework as delivered (cache).
public struct CalendarHomework: Identifiable, Equatable, Hashable, Sendable, Codable {
    /// WebUntis homework id.
    public var id: String
    /// Course (`lessonId`), when delivered.
    public var lessonID: String?
    /// Period the homework was delivered with, and its civil date (the
    /// cache replaces homework by the days of a fetch, like lessons).
    public var periodID: String
    public var periodDate: CivilDate
    /// Given on (`startDate`) and due on (`endDate`).
    public var assigned: CivilDate?
    public var due: CivilDate
    public var subject: String?
    public var subjectID: String?
    public var text: String
    public var remark: String?
    /// WebUntis' own flag (shown only as a hint; the local mark decides).
    public var completedInSource: Bool
    public var attachmentCount: Int

    public init(id: String, lessonID: String?, periodID: String, periodDate: CivilDate, assigned: CivilDate?, due: CivilDate,
                subject: String? = nil, subjectID: String? = nil, text: String, remark: String? = nil,
                completedInSource: Bool = false, attachmentCount: Int = 0) {
        self.id = id; self.lessonID = lessonID; self.periodID = periodID; self.periodDate = periodDate
        self.assigned = assigned; self.due = due; self.subject = subject; self.subjectID = subjectID
        self.text = text; self.remark = remark; self.completedInSource = completedInSource; self.attachmentCount = attachmentCount
    }

    var isValid: Bool {
        (1...100).contains(id.count) && (1...100).contains(periodID.count) && (lessonID?.count ?? 0) <= 100
            && text.count <= 20_000 && (remark?.count ?? 0) <= 20_000 && (subject?.count ?? 0) <= 300
            && (subjectID?.count ?? 0) <= 100 && (0...10_000).contains(attachmentCount)
            && (assigned.map { $0 <= due } ?? true)
    }
}

/// „Erledigt“ marked by the user (calendar format 4), bound to the account
/// identity so it survives a reconnect of the same „Freigabe“.
public struct CalendarHomeworkMark: Identifiable, Equatable, Sendable, Codable {
    /// `CalendarConnectionRecord.source` of the account.
    public var source: String
    public var homeworkID: String
    public var doneAt: Date
    public var id: String { source + "/" + homeworkID }

    public init(source: String, homeworkID: String, doneAt: Date = Date()) {
        self.source = source; self.homeworkID = homeworkID; self.doneAt = doneAt
    }

    private enum CodingKeys: String, CodingKey { case source, homeworkID, doneAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(String.self, forKey: .source); homeworkID = try c.decode(String.self, forKey: .homeworkID)
        doneAt = Date(timeIntervalSinceReferenceDate: try c.decode(Double.self, forKey: .doneAt))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(source, forKey: .source); try c.encode(homeworkID, forKey: .homeworkID)
        try c.encode(doneAt.timeIntervalSinceReferenceDate, forKey: .doneAt)
    }

    var isValid: Bool { (1...300).contains(source.count) && (1...100).contains(homeworkID.count) && CalendarState.validInstant(doneAt) }
}

/// One homework for the views: the cached homework plus the local mark.
public struct CalendarHomeworkItem: Identifiable, Equatable, Sendable {
    public var homework: CalendarHomework
    public var done: Bool
    /// Period id of a lesson of the course on the due day (the lesson the
    /// homework is due in), when the offline timetable has one.
    public var dueLessonID: String?
    public var id: String { homework.id }

    public static func items(snapshot: CalendarSourceSnapshot?, marks: [CalendarHomeworkMark], source: String?) -> [CalendarHomeworkItem] {
        guard let snapshot else { return [] }
        guard !snapshot.homework.isEmpty else { return [] }
        let done = Set(marks.filter { $0.source == source }.map(\.homeworkID))
        var firstLesson: [String: String] = [:]
        for lesson in snapshot.lessons where !lesson.isCancelled {
            guard let course = lesson.key.seriesID else { continue }
            let key = course + "|" + lesson.date.description
            if firstLesson[key] == nil { firstLesson[key] = lesson.key.sourceID }
        }
        return snapshot.homework.map { homework in
            let lesson = homework.lessonID.flatMap { firstLesson[$0 + "|" + homework.due.description] }
            return CalendarHomeworkItem(homework: homework, done: done.contains(homework.id), dueLessonID: lesson)
        }.sorted { ($0.homework.due, $0.homework.subject ?? "", $0.homework.id) < ($1.homework.due, $1.homework.subject ?? "", $1.homework.id) }
    }
}

extension WebUntis {
    /// Homework dates: „YYYY-MM-DD“, „YYYYMMDD“ or with a time part.
    static func homeworkDate(_ text: String?) -> CivilDate? {
        guard var raw = text?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let cut = raw.firstIndex(where: { $0 == "T" || $0 == " " }) { raw = String(raw[..<cut]) }
        if raw.count == 8, raw.allSatisfy({ $0.isASCII && $0.isNumber }) {
            raw = String(raw.prefix(4)) + "-" + String(raw.dropFirst(4).prefix(2)) + "-" + String(raw.suffix(2))
        }
        return CivilDate(raw)
    }
}
