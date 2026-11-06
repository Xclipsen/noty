import Foundation

// Kalender Stufe C (docs/CALENDAR-PLAN.md §7): Apple Kalender and Outlook
// (Microsoft 365 / Exchange accounts added in the iPad settings) through the
// system calendar store. The app layer reads EventKit and maps it to these
// plain values; everything here is platform independent: the per-area
// settings (format 4), the anchor of an event note, matching an anchor to
// the events read now, and the merge rules. System events are NOT stored in
// the calendar package: the system store is the offline copy itself, read
// anew on app activation, on store changes and by hand („Systemkalender
// zuletzt eingelesen …“). Never reported as „synchronisiert“.

/// One calendar of the system store (Apple, iCloud, Exchange/M365, …).
public struct CalendarSystemCalendar: Identifiable, Equatable, Hashable, Sendable {
    /// `EKCalendar.calendarIdentifier` (device local; may change when an account is added again).
    public var id: String
    public var title: String
    /// Account/source title, e.g. „iCloud“, „Exchange“, „Outlook“, „Auf meinem iPad“.
    public var account: String
    /// „#RRGGBB“ of the calendar colour.
    public var colorHex: String
    /// `allowsContentModifications` (read-only: subscriptions, birthdays, shared read-only).
    public var writable: Bool

    public init(id: String, title: String, account: String, colorHex: String, writable: Bool) {
        self.id = id; self.title = title; self.account = account; self.colorHex = colorHex; self.writable = writable
    }

    /// „Arbeit (Exchange)“.
    public var displayName: String { account.isEmpty || account == title ? title : "\(title) (\(account))" }
}

/// One occurrence read from the system store.
public struct CalendarSystemEvent: Identifiable, Equatable, Hashable, Sendable {
    /// `calendarItemIdentifier` (device local, the same for every occurrence of a series).
    public var itemID: String
    /// `calendarItemExternalIdentifier` (the server's identity, shared across
    /// devices; may be missing or – for some account types – change).
    public var externalID: String?
    public var calendarID: String
    public var title: String
    public var location: String
    public var notes: String
    public var start: Date
    public var end: Date
    public var allDay: Bool
    /// Time zone identifier of a timed event (nil: floating).
    public var timeZone: String?
    /// Original start of this occurrence (`occurrenceDate`) when the event
    /// belongs to a series – also for a moved („detached“) occurrence.
    public var occurrence: Date?
    public var recurring: Bool
    public var detached: Bool
    public var cancelled: Bool

    public init(itemID: String, externalID: String?, calendarID: String, title: String, location: String = "", notes: String = "",
                start: Date, end: Date, allDay: Bool = false, timeZone: String? = nil, occurrence: Date? = nil,
                recurring: Bool = false, detached: Bool = false, cancelled: Bool = false) {
        self.itemID = itemID; self.externalID = externalID?.nilIfBlank; self.calendarID = calendarID
        self.title = title; self.location = location; self.notes = notes; self.start = start; self.end = end
        self.allDay = allDay; self.timeZone = timeZone; self.occurrence = occurrence
        self.recurring = recurring; self.detached = detached; self.cancelled = cancelled
    }

    /// Entry id shown in the calendar (unique per occurrence and calendar).
    public var id: String { "system/" + anchor.key + "/" + calendarID }

    /// The note anchor of this occurrence.
    public var anchor: CalendarSystemAnchor {
        CalendarSystemAnchor(externalID: externalID, itemID: itemID, calendarID: calendarID,
                             occurrence: recurring || detached ? (occurrence ?? start) : nil)
    }
}

/// What a note of a system event belongs to: the event's identity plus –
/// for a series – the original start of the occurrence (rule 5: a note
/// belongs to one occurrence). Never title or the current time.
public struct CalendarSystemAnchor: Hashable, Sendable, Codable {
    /// `calendarItemExternalIdentifier`; nil when the store had none.
    public var externalID: String?
    /// `calendarItemIdentifier` (fallback identity, device local).
    public var itemID: String
    /// Calendar when the note was written (disambiguation only).
    public var calendarID: String
    /// Original occurrence start of a series occurrence; nil for a single event.
    public var occurrence: Date?

    public init(externalID: String?, itemID: String, calendarID: String, occurrence: Date?) {
        self.externalID = externalID?.nilIfBlank; self.itemID = itemID; self.calendarID = calendarID
        // Whole seconds: EventKit dates of the same occurrence differ in sub-second noise at most.
        self.occurrence = occurrence.map { Date(timeIntervalSinceReferenceDate: $0.timeIntervalSinceReferenceDate.rounded()) }
    }

    public var identity: String { externalID.map { "x:" + $0 } ?? "i:" + itemID }

    /// Stable key („system/x:<external>/<seconds>“ or „…/-“).
    public var key: String {
        identity + "/" + (occurrence.map { String(Int64($0.timeIntervalSinceReferenceDate.rounded())) } ?? "-")
    }

    private enum CodingKeys: String, CodingKey { case externalID, itemID, calendarID, occurrence }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(externalID: try c.decodeIfPresent(String.self, forKey: .externalID), itemID: try c.decode(String.self, forKey: .itemID),
                  calendarID: try c.decode(String.self, forKey: .calendarID),
                  occurrence: try c.decodeIfPresent(Double.self, forKey: .occurrence).map { Date(timeIntervalSinceReferenceDate: $0) })
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(externalID, forKey: .externalID); try c.encode(itemID, forKey: .itemID)
        try c.encode(calendarID, forKey: .calendarID)
        try c.encodeIfPresent(occurrence?.timeIntervalSinceReferenceDate, forKey: .occurrence)
    }

    var isValid: Bool {
        (externalID?.count ?? 1) <= 500 && (1...500).contains(itemID.count) && (1...500).contains(calendarID.count)
            && (occurrence.map(CalendarState.validInstant) ?? true)
    }
}

/// Per-area settings of the system calendars (format 4).
public struct CalendarSystemSettings: Equatable, Sendable, Codable {
    public static let maximumHidden = 500
    /// The user connected the system calendars in this area. Off after a
    /// restore (a restore never activates a source).
    public var enabled: Bool
    /// Calendars switched off (new calendars of an account appear).
    public var hiddenCalendars: [String]
    /// Preselected target of new events; nil: noty („Persönlich“).
    public var defaultTarget: String?

    public init(enabled: Bool = true, hiddenCalendars: [String] = [], defaultTarget: String? = nil) {
        self.enabled = enabled; self.hiddenCalendars = hiddenCalendars; self.defaultTarget = defaultTarget
    }

    private enum CodingKeys: String, CodingKey { case enabled, hiddenCalendars, defaultTarget }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        hiddenCalendars = try c.decodeIfPresent([String].self, forKey: .hiddenCalendars) ?? []
        defaultTarget = try c.decodeIfPresent(String.self, forKey: .defaultTarget)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(hiddenCalendars, forKey: .hiddenCalendars)
        try c.encodeIfPresent(defaultTarget, forKey: .defaultTarget)
    }

    var isValid: Bool {
        hiddenCalendars.count <= Self.maximumHidden && Set(hiddenCalendars).count == hiddenCalendars.count
            && hiddenCalendars.allSatisfy { (1...500).contains($0.count) } && (defaultTarget.map { (1...500).contains($0.count) } ?? true)
    }
}

/// Where a note's system event is now.
public enum CalendarSystemResolution: Equatable, Sendable {
    case found(CalendarSystemEvent)
    /// No access, system calendars off, or the note's time is outside the
    /// range read now: no statement (never „deleted“).
    case notLoaded
    /// Read, but the event is gone or no longer unique: „ungeklärt“; the
    /// user may choose one of `candidates` (same calendar, nearby). Never
    /// matched by title automatically.
    case unresolved(candidates: [CalendarSystemEvent])
}

public enum CalendarSystemMatching {
    public static let candidateDays = 14

    /// `read`: the time range the events were read for (nil: nothing read).
    /// `contextStart`: when the target was last seen (the link's context).
    public static func resolve(_ anchor: CalendarSystemAnchor, events: [CalendarSystemEvent], read: (start: Date, end: Date)?,
                               contextStart: Date) -> CalendarSystemResolution {
        guard let read else { return .notLoaded }
        var matches = events.filter { event in
            // Server identity first; the device-local item id also counts (an
            // event created by noty before its first upload has no external id yet).
            if let external = anchor.externalID, let other = event.externalID, external == other { return true }
            return event.itemID == anchor.itemID
        }
        matches = matches.filter { $0.anchor.occurrence == anchor.occurrence }
        if matches.count > 1 {
            // The same server event in two calendars (e.g. an invitation): the original calendar decides.
            let same = matches.filter { $0.calendarID == anchor.calendarID }
            if same.count == 1 { matches = same }
        }
        if matches.count == 1 { return .found(matches[0]) }
        let reference = anchor.occurrence ?? contextStart
        guard reference >= read.start, reference < read.end else { return matches.isEmpty ? .notLoaded : .unresolved(candidates: matches) }
        if !matches.isEmpty { return .unresolved(candidates: matches.sorted { $0.calendarID < $1.calendarID }) }
        let window = Double(candidateDays) * 86_400
        let nearby = events.filter { $0.calendarID == anchor.calendarID && abs($0.start.timeIntervalSince(reference)) <= window }
        return .unresolved(candidates: nearby.sorted {
            let a = abs($0.start.timeIntervalSince(reference)), b = abs($1.start.timeIntervalSince(reference))
            return a != b ? a < b : $0.id < $1.id
        })
    }

    /// Events of the shown calendars, duplicates removed: the same
    /// occurrence delivered twice for one calendar counts once. The same
    /// server event in two calendars stays twice (both are real; the
    /// origin is shown), never merged by title or time.
    public static func visible(_ events: [CalendarSystemEvent], settings: CalendarSystemSettings?) -> [CalendarSystemEvent] {
        guard let settings, settings.enabled else { return [] }
        let hidden = Set(settings.hiddenCalendars)
        var seen = Set<String>()
        return events.filter { !hidden.contains($0.calendarID) && seen.insert($0.id).inserted }
            .sorted { ($0.start, $0.id) < ($1.start, $1.id) }
    }

    /// The target of new events: the stored default if it still is a
    /// writable shown calendar, else nil (noty „Persönlich“).
    public static func defaultTarget(_ settings: CalendarSystemSettings?, calendars: [CalendarSystemCalendar]) -> String? {
        guard let settings, settings.enabled, let id = settings.defaultTarget,
              calendars.contains(where: { $0.id == id && $0.writable }), !settings.hiddenCalendars.contains(id) else { return nil }
        return id
    }
}

/// What a form writes to: noty's own calendar or a writable system calendar.
public enum CalendarWriteTarget: Hashable, Sendable {
    case local
    case system(calendarID: String)

    public var calendarID: String? { if case .system(let id) = self { id } else { nil } }
}

/// How the note links of one event follow a deliberate change of its
/// source (form: another target calendar). Only single events move between
/// sources; the new event is written first, the old one removed after –
/// a failure in between leaves both (visible), never none.
public enum CalendarSourceMove {
    /// Links of the local single event `id` now belong to `anchor`.
    public static func retargetLocal(_ links: inout [CalendarNoteLink], event id: UUID, to anchor: CalendarSystemAnchor) {
        for index in links.indices {
            if case .local(let event, nil) = links[index].target, event == id { links[index].target = .system(anchor) }
        }
    }

    /// Links of a system single event now belong to the local event `id`.
    public static func retargetSystem(_ links: inout [CalendarNoteLink], from anchor: CalendarSystemAnchor, to id: UUID) {
        for index in links.indices {
            if case .system(let old) = links[index].target, old.identity == anchor.identity, old.occurrence == nil {
                links[index].target = .local(event: id, date: nil)
            }
        }
    }

    /// Links of a system event follow when the store gives it a new identity
    /// (e.g. moved to another calendar by noty): `old` → `new`.
    public static func retarget(_ links: inout [CalendarNoteLink], from old: CalendarSystemAnchor, to new: CalendarSystemAnchor) {
        for index in links.indices {
            if case .system(let anchor) = links[index].target, anchor.identity == old.identity {
                var moved = new
                moved.occurrence = anchor.occurrence
                links[index].target = .system(moved)
            }
        }
    }
}

public enum CalendarSystemNotes {
    /// „Alle Termine der Serie“ moved by `seconds`: the notes of its
    /// occurrences follow (their original starts move the same way).
    public static func shift(_ links: inout [CalendarNoteLink], identity: String, by seconds: TimeInterval) {
        guard seconds != 0 else { return }
        for index in links.indices {
            guard case .system(var anchor) = links[index].target, anchor.identity == identity, let occurrence = anchor.occurrence else { continue }
            anchor.occurrence = Date(timeIntervalSinceReferenceDate: (occurrence.timeIntervalSinceReferenceDate + seconds).rounded())
            links[index].target = .system(anchor)
        }
    }
}

/// „#RRGGBB“ from components 0…1 (app: CGColor of the calendar).
public enum CalendarColorHex {
    public static func hex(red: Double, green: Double, blue: Double) -> String {
        func part(_ v: Double) -> String { String(format: "%02X", Int((min(1, max(0, v.isFinite ? v : 0)) * 255).rounded())) }
        return "#" + part(red) + part(green) + part(blue)
    }

    /// Approximate colours of the named calendar colours (system palette).
    static let named: [(String, String)] = [
        ("orange", "#FF9500"), ("purple", "#AF52DE"), ("teal", "#30B0C7"), ("pink", "#FF2D55"), ("yellow", "#FFCC00"),
        ("brown", "#A2845E"), ("cyan", "#32ADE6"), ("olive", "#9EAD33"), ("indigo", "#5856D6"), ("mint", "#00C7BE"),
        ("gray", "#8E8E93"), ("green", "#34C759"),
    ]

    /// The named colour closest to `hex` (for views that know only names).
    public static func nearestName(_ hex: String) -> String {
        guard let c = components(hex) else { return "gray" }
        return named.min { a, b in
            func distance(_ entry: (String, String)) -> Double {
                guard let n = components(entry.1) else { return .infinity }
                return pow(n.red - c.red, 2) + pow(n.green - c.green, 2) + pow(n.blue - c.blue, 2)
            }
            return distance(a) < distance(b)
        }?.0 ?? "gray"
    }

    public static func components(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }
}
