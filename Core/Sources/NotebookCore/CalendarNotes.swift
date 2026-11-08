import Foundation

// Kalender Stufe B2 (docs/CALENDAR-PLAN.md §4): event notes are ordinary
// noty notebooks in the library folder „Kalendernotizen“. The calendar
// package stores only links by identity (document id, optional page id; the
// area is the package's own area, links never cross areas), never names,
// paths or positions. Removing an event or a connection never deletes a
// notebook; removing a link never deletes anything else.

/// What a note belongs to.
public enum CalendarNoteTarget: Hashable, Sendable, Codable {
    /// An own event; `date` = original date of one occurrence of a series
    /// (a series occurrence owns its note, rule 5), nil for single events.
    case local(event: UUID, date: CivilDate?)
    /// One WebUntis lesson (see `CalendarLessonAnchor`).
    case lesson(CalendarLessonAnchor)
    /// One event (occurrence) of a system calendar (Apple/Outlook, format 4).
    case system(CalendarSystemAnchor)

    private enum CodingKeys: String, CodingKey { case kind, event, date, lesson, system }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "local": self = .local(event: try c.decode(UUID.self, forKey: .event), date: try c.decodeIfPresent(CivilDate.self, forKey: .date))
        case "lesson": self = .lesson(try c.decode(CalendarLessonAnchor.self, forKey: .lesson))
        case "system": self = .system(try c.decode(CalendarSystemAnchor.self, forKey: .system))
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unbekanntes Notizziel")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .local(let event, let date):
            try c.encode("local", forKey: .kind); try c.encode(event, forKey: .event); try c.encodeIfPresent(date, forKey: .date)
        case .lesson(let anchor):
            try c.encode("lesson", forKey: .kind); try c.encode(anchor, forKey: .lesson)
        case .system(let anchor):
            try c.encode("system", forKey: .kind); try c.encode(anchor, forKey: .system)
        }
    }

    public var isSystem: Bool { if case .system = self { true } else { false } }

    /// Stable text form (dictionary keys, pending creations).
    public var key: String {
        switch self {
        case .local(let event, let date): "local/\(event.uuidString)" + (date.map { "/\($0)" } ?? "")
        case .lesson(let anchor): "lesson/\(anchor.source)/\(anchor.periodID)"
        case .system(let anchor): "system/" + anchor.key
        }
    }
}

/// A WebUntis lesson as it was when the note was written. The period `id`
/// is the identity; course (`lessonId`) and original date only help to find
/// candidates when WebUntis later delivers the lesson under another id.
public struct CalendarLessonAnchor: Hashable, Sendable, Codable {
    /// `CalendarConnectionRecord.source` of the account.
    public var source: String
    public var periodID: String
    public var lessonID: String?
    public var originalDate: CivilDate
    /// Local start as delivered when the note was written („2026-11-04T08:00“).
    public var originalStart: String

    public init(source: String, periodID: String, lessonID: String?, originalDate: CivilDate, originalStart: String) {
        self.source = source; self.periodID = periodID; self.lessonID = lessonID
        self.originalDate = originalDate; self.originalStart = originalStart
    }

    public init(lesson: CalendarLesson, source: String) {
        self.init(source: source, periodID: lesson.key.sourceID, lessonID: lesson.key.seriesID,
                  originalDate: lesson.date, originalStart: lesson.key.originalStart)
    }
}

/// Link of one target to one notebook.
public struct CalendarNoteLink: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public var target: CalendarNoteTarget
    public var documentID: UUID
    /// The page the note started on (optional; the notebook stays the target).
    public var pageID: UUID?
    public var createdAt: Date
    /// Last seen: the notebook has handwriting, text, images or shapes. Only
    /// then the event shows the note symbol.
    public var hasContent: Bool
    /// Context of the target when last seen, for a target that can no longer
    /// be resolved (the note stays reachable, „ungeklärt“).
    public var contextTitle: String
    public var contextStart: Date
    public var contextEnd: Date

    public init(id: UUID = UUID(), target: CalendarNoteTarget, documentID: UUID, pageID: UUID? = nil, createdAt: Date = Date(),
                hasContent: Bool = true, contextTitle: String, contextStart: Date, contextEnd: Date) {
        self.id = id; self.target = target; self.documentID = documentID; self.pageID = pageID; self.createdAt = createdAt
        self.hasContent = hasContent; self.contextTitle = contextTitle; self.contextStart = contextStart; self.contextEnd = contextEnd
    }

    private enum CodingKeys: String, CodingKey { case id, target, documentID, pageID, createdAt, hasContent, contextTitle, contextStart, contextEnd }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        target = try c.decode(CalendarNoteTarget.self, forKey: .target)
        documentID = try c.decode(UUID.self, forKey: .documentID)
        pageID = try c.decodeIfPresent(UUID.self, forKey: .pageID)
        createdAt = Date(timeIntervalSinceReferenceDate: try c.decode(Double.self, forKey: .createdAt))
        hasContent = try c.decode(Bool.self, forKey: .hasContent)
        contextTitle = try c.decode(String.self, forKey: .contextTitle)
        contextStart = Date(timeIntervalSinceReferenceDate: try c.decode(Double.self, forKey: .contextStart))
        contextEnd = Date(timeIntervalSinceReferenceDate: try c.decode(Double.self, forKey: .contextEnd))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(target, forKey: .target); try c.encode(documentID, forKey: .documentID)
        try c.encodeIfPresent(pageID, forKey: .pageID); try c.encode(createdAt.timeIntervalSinceReferenceDate, forKey: .createdAt)
        try c.encode(hasContent, forKey: .hasContent); try c.encode(contextTitle, forKey: .contextTitle)
        try c.encode(contextStart.timeIntervalSinceReferenceDate, forKey: .contextStart)
        try c.encode(contextEnd.timeIntervalSinceReferenceDate, forKey: .contextEnd)
    }

    var isValid: Bool {
        guard (1...300).contains(contextTitle.count), CalendarState.validInstant(createdAt),
              CalendarState.validInstant(contextStart), CalendarState.validInstant(contextEnd), contextEnd >= contextStart else { return false }
        if case .lesson(let anchor) = target {
            return (1...300).contains(anchor.source.count) && (1...100).contains(anchor.periodID.count)
                && (anchor.lessonID?.count ?? 0) <= 100 && anchor.originalStart.count <= 40
        }
        if case .system(let anchor) = target { return anchor.isValid }
        return true
    }
}

/// A lesson the user assigned anew: WebUntis no longer delivers period
/// `fromPeriodID` and the user confirmed `toPeriodID` as the same lesson
/// (moved). Notes of the old period follow. Never derived from titles.
public struct CalendarLessonMapping: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public var source: String
    public var fromPeriodID: String
    public var fromDate: CivilDate
    public var toPeriodID: String
    public var toDate: CivilDate
    public var confirmedAt: Date

    public init(id: UUID = UUID(), source: String, fromPeriodID: String, fromDate: CivilDate,
                toPeriodID: String, toDate: CivilDate, confirmedAt: Date = Date()) {
        self.id = id; self.source = source; self.fromPeriodID = fromPeriodID; self.fromDate = fromDate
        self.toPeriodID = toPeriodID; self.toDate = toDate; self.confirmedAt = confirmedAt
    }

    private enum CodingKeys: String, CodingKey { case id, source, fromPeriodID, fromDate, toPeriodID, toDate, confirmedAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); source = try c.decode(String.self, forKey: .source)
        fromPeriodID = try c.decode(String.self, forKey: .fromPeriodID); fromDate = try c.decode(CivilDate.self, forKey: .fromDate)
        toPeriodID = try c.decode(String.self, forKey: .toPeriodID); toDate = try c.decode(CivilDate.self, forKey: .toDate)
        confirmedAt = Date(timeIntervalSinceReferenceDate: try c.decode(Double.self, forKey: .confirmedAt))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(source, forKey: .source)
        try c.encode(fromPeriodID, forKey: .fromPeriodID); try c.encode(fromDate, forKey: .fromDate)
        try c.encode(toPeriodID, forKey: .toPeriodID); try c.encode(toDate, forKey: .toDate)
        try c.encode(confirmedAt.timeIntervalSinceReferenceDate, forKey: .confirmedAt)
    }

    var isValid: Bool {
        (1...300).contains(source.count) && (1...100).contains(fromPeriodID.count) && (1...100).contains(toPeriodID.count)
            && fromPeriodID != toPeriodID && CalendarState.validInstant(confirmedAt)
    }
}

/// Where the lesson of a note is now.
public enum CalendarLessonResolution: Equatable, Sendable {
    /// Same period id (also when moved or cancelled), or a confirmed mapping.
    case found(CalendarLesson)
    /// The (mapped) original day is not in the offline timetable: no statement.
    case notLoaded
    /// The day is loaded but the lesson is gone: „ungeklärt“. Candidates of
    /// the same course nearby for the user to choose; never merged by title.
    case unresolved(candidates: [CalendarLesson])
}

public enum CalendarLessonMatching {
    /// Days around the original date searched for candidates.
    public static let candidateDays = 14

    /// Follows confirmed mappings (at most 16 steps, no cycles).
    public static func currentPeriod(_ anchor: CalendarLessonAnchor, mappings: [CalendarLessonMapping]) -> (period: String, date: CivilDate) {
        var period = anchor.periodID, date = anchor.originalDate
        var seen: Set<String> = [period]
        for _ in 0..<16 {
            guard let next = mappings.last(where: { $0.source == anchor.source && $0.fromPeriodID == period }),
                  seen.insert(next.toPeriodID).inserted else { break }
            period = next.toPeriodID; date = next.toDate
        }
        return (period, date)
    }

    /// `taken`: period ids that other notes already resolve to (not offered
    /// as candidates).
    public static func resolve(_ anchor: CalendarLessonAnchor, mappings: [CalendarLessonMapping],
                               snapshot: CalendarSourceSnapshot?, taken: Set<String> = []) -> CalendarLessonResolution {
        guard let snapshot else { return .notLoaded }
        let current = currentPeriod(anchor, mappings: mappings)
        let matches = snapshot.lessons.filter { $0.key.sourceID == current.period }
        if let lesson = matches.min(by: { abs(current.date.days(to: $0.date)) < abs(current.date.days(to: $1.date)) }) {
            return .found(lesson)
        }
        guard snapshot.days[current.date.description] != nil else { return .notLoaded }
        guard let course = anchor.lessonID else { return .unresolved(candidates: []) }
        let candidates = snapshot.lessons.filter {
            $0.key.seriesID == course && !taken.contains($0.key.sourceID) && $0.key.sourceID != current.period
                && abs(current.date.days(to: $0.date)) <= candidateDays
        }
        return .unresolved(candidates: candidates.sorted {
            let a = abs(current.date.days(to: $0.date)), b = abs(current.date.days(to: $1.date))
            return a != b ? a < b : $0.start < $1.start
        })
    }
}

/// The library folder of the notes, by identity only.
public enum CalendarNotesFolder {
    public static let title = "Kalendernotizen"

    /// The stored folder if it still is an active folder of `snapshot`;
    /// otherwise nil (the caller creates a new one and stores its id). Never
    /// looked up by name: a folder of the same name may be the user's own.
    public static func usable(_ id: UUID?, in snapshot: LibrarySnapshot) -> UUID? {
        guard let id, snapshot.items.contains(where: { $0.id == id && $0.isFolder }), !snapshot.isTrashed(id) else { return nil }
        return id
    }

    /// „Rechnungswesen · 03.11.2026“, at most 120 characters, unique among
    /// the active notebooks (a double lesson gets „… (2)“).
    public static func noteTitle(subject: String, date: CivilDate, taken: [String]) -> String {
        let suffix = String(format: " · %02d.%02d.%04d", date.day, date.month, date.year)
        let name = subject.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        let base = String((name.isEmpty ? "Notiz" : name).prefix(120 - suffix.count - 5)) + suffix
        return NotebookTitles.unique(base, taken: taken)
    }
}

/// Plan §4 rule 8 for one new note: (1) the notebook package is committed
/// completely, (2) it is added to the library (folder „Kalendernotizen“),
/// (3) only then the calendar link is committed. A failed step stops the
/// run; the next run resumes exactly there with the same document identity,
/// so retries never create a second notebook. Concurrent runs share one.
public actor CalendarNoteCreation {
    public enum Stage: Int, Comparable, Sendable {
        case none, notebookCommitted, inLibrary, linked
        public static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }
    }

    public nonisolated let documentID: UUID
    public nonisolated let target: CalendarNoteTarget
    public private(set) var stage: Stage = .none
    public private(set) var lastError: String?
    private var running: Task<Stage, Error>?

    public init(documentID: UUID, target: CalendarNoteTarget) {
        self.documentID = documentID
        self.target = target
    }

    @discardableResult
    public func run(commitNotebook: @escaping @Sendable () async throws -> Void,
                    addToLibrary: @escaping @Sendable () async throws -> Void,
                    link: @escaping @Sendable () async throws -> Void) async throws -> Stage {
        if let running { return try await running.value }
        let task = Task { () throws -> Stage in
            if stage < .notebookCommitted { try await commitNotebook(); stage = .notebookCommitted }
            if stage < .inLibrary { try await addToLibrary(); stage = .inLibrary }
            if stage < .linked { try await link(); stage = .linked }
            return stage
        }
        running = task
        defer { running = nil }
        do {
            let result = try await task.value
            lastError = nil
            return result
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            throw error
        }
    }
}

extension CalendarState {
    /// A notebook was replaced by an earlier state of it (BACKUP-RESTORE-PLAN:
    /// the restored state gets a new identity but keeps its page IDs; today's
    /// state moves to the trash). Event notes and the Lernfeld follow the
    /// restored notebook. False when nothing referred to `old`.
    @discardableResult
    public mutating func notebookReplaced(_ old: UUID, by new: UUID) -> Bool {
        guard old != new else { return false }
        var changed = false
        for index in noteLinks.indices where noteLinks[index].documentID == old {
            noteLinks[index].documentID = new; changed = true
        }
        for index in studyFields.indices where studyFields[index].notebookID == old {
            studyFields[index].notebookID = new; changed = true
        }
        return changed
    }

    /// Notebooks the calendar refers to (event notes, Lernfelder).
    public var referencedNotebooks: Set<UUID> {
        Set(noteLinks.map(\.documentID)).union(studyFields.compactMap(\.notebookID))
    }
}
