import XCTest
@testable import NotebookCore

/// Kalender Stufe C (06.11.2026): calendar format 4 (system calendar
/// settings, notes of system events, homework marks) with migration and
/// archive compatibility, matching of system event notes, the NRW holiday
/// fallback and WebUntis homework. Fictitious data only: no real school,
/// account, calendar or timetable.
final class CalendarStageCTests: XCTestCase {
    private var root: URL!
    private let zone = "Europe/Berlin"
    private var berlin: Calendar { CalendarDates.german(timeZone: TimeZone(identifier: zone)!) }
    private let created = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-c-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func day(_ text: String) -> CivilDate { CivilDate(text)! }
    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        berlin.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }
    private func event(_ item: String, external: String?, calendar: String = "cal-a", title: String = "Besprechung",
                       start: Date, occurrence: Date? = nil, recurring: Bool = false) -> CalendarSystemEvent {
        CalendarSystemEvent(itemID: item, externalID: external, calendarID: calendar, title: title, start: start,
                            end: start.addingTimeInterval(3600), timeZone: zone, occurrence: occurrence, recurring: recurring)
    }

    // MARK: Format 4

    private func writePackage(_ json: String) throws -> (file: String, bytes: Data) {
        let package = root.appendingPathComponent("Calendar", isDirectory: true)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("Revisions"), withIntermediateDirectories: true)
        let bytes = Data(json.utf8)
        let file = UUID().uuidString + ".json"
        try bytes.write(to: package.appendingPathComponent("Revisions/\(file)"))
        let manifest = RevisionManifest(revisions: [RevisionRecord(file: file, byteCount: bytes.count, crc32: SnapshotChecksum.crc32(bytes),
                                                                   savedAtUnix: 1_790_000_000)])
        try JSONEncoder().encode(manifest).write(to: package.appendingPathComponent("manifest.json"))
        return (file, bytes)
    }

    static let format3JSON = #"{"connection":null,"deletedEvents":[],"events":[{"createdAt":815000000,"details":"","id":"00000000-0000-4000-8000-000000000001","location":"","modifiedAt":815000000,"reminderMinutes":10,"timing":{"end":815005400,"kind":"timed","start":815000000,"timeZone":"Europe\/Berlin"},"title":"Elternabend"}],"formatVersion":3,"lessonMappings":[],"noteLinks":[],"settings":{"lessonReminderMinutes":10,"mode":"week","weekDays":5}}"#

    func testFormat3PackageMigratesToFormat4WithExactOldBytes() async throws {
        let (file, bytes) = try writePackage(Self.format3JSON)
        let repository = CalendarRepository(areaRoot: root)
        let loaded = try await repository.load()
        XCTAssertEqual(loaded.state.formatVersion, 4)
        XCTAssertEqual(loaded.state.events.first?.reminderMinutes, 10)
        XCTAssertNil(loaded.state.settings.systemCalendars)
        var next = loaded.state
        next.settings.systemCalendars = CalendarSystemSettings(enabled: true, hiddenCalendars: ["cal-geburtstage"], defaultTarget: "cal-a")
        next.homeworkDone = [CalendarHomeworkMark(source: "webuntis:abc", homeworkID: "9001", doneAt: created)]
        let anchor = CalendarSystemAnchor(externalID: "EXT-1", itemID: "item-1", calendarID: "cal-a", occurrence: at(2026, 11, 9, 10))
        next.noteLinks = [CalendarNoteLink(target: .system(anchor), documentID: UUID(), createdAt: created, contextTitle: "Besprechung",
                                           contextStart: at(2026, 11, 9, 10), contextEnd: at(2026, 11, 9, 11))]
        try await repository.save(next, revision: 1)
        let package = root.appendingPathComponent("Calendar", isDirectory: true)
        XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent("Migration/format-3-\(file)")), bytes, "exakte Altbytes")
        await repository.close()
        let reopened = try await CalendarRepository(areaRoot: root).load()
        XCTAssertEqual(reopened.state, next, "Rundlauf mit Systemkalendern, Systemnotiz und Hausaufgabenmarke")
        XCTAssertFalse(reopened.recovered)
    }

    func testFormat3WithFormat4FieldsIsRejectedAndFormat5Locks() {
        let withMarks = Self.format3JSON.replacingOccurrences(of: #""formatVersion":3"#,
            with: #""formatVersion":3,"homeworkDone":[{"doneAt":815000000,"homeworkID":"1","source":"webuntis:x"}]"#)
        XCTAssertThrowsError(try CalendarStore.decode(Data(withMarks.utf8)))
        let withSystem = Self.format3JSON.replacingOccurrences(of: #""weekDays":5}"#, with: #""weekDays":5,"systemCalendars":{"enabled":true}}"#)
        XCTAssertThrowsError(try CalendarStore.decode(Data(withSystem.utf8)))
        XCTAssertThrowsError(try CalendarStore.decode(Data(#"{"events":[],"formatVersion":5}"#.utf8))) {
            XCTAssertEqual($0 as? CalendarStoreError, .unsupportedFormat(5))
        }
    }

    func testInvalidFormat4FieldsAreRejected() throws {
        var state = CalendarState()
        state.homeworkDone = [CalendarHomeworkMark(source: "s", homeworkID: "1", doneAt: created),
                              CalendarHomeworkMark(source: "s", homeworkID: "1", doneAt: created)]
        XCTAssertThrowsError(try state.validate(), "doppelte Marke")
        state.homeworkDone = []
        state.settings.systemCalendars = CalendarSystemSettings(hiddenCalendars: ["a", "a"])
        XCTAssertThrowsError(try state.validate(), "doppelter ausgeblendeter Kalender")
        state.settings.systemCalendars = CalendarSystemSettings(hiddenCalendars: ["a"])
        XCTAssertNoThrow(try state.validate())
        state.noteLinks = [CalendarNoteLink(target: .system(CalendarSystemAnchor(externalID: nil, itemID: "", calendarID: "c", occurrence: nil)),
                                            documentID: UUID(), createdAt: created, contextTitle: "X", contextStart: created, contextEnd: created)]
        XCTAssertThrowsError(try state.validate(), "Systemanker ohne Kennung")
    }

    func testArchiveReadsFormat3AndCurrentAndRestoreDetachesSystemCalendars() throws {
        // As a B3 build writes it (an absent connection is omitted, never null).
        let old = try CalendarArchive.decodeState(Data(Self.format3JSON.replacingOccurrences(of: #""connection":null,"#, with: "").utf8))
        XCTAssertEqual(old.formatVersion, CalendarState.currentFormat, "Bibliotheksbackups älterer Builds bleiben lesbar")
        var state = old
        state.settings.systemCalendars = CalendarSystemSettings(enabled: true, defaultTarget: "cal-a")
        state.homeworkDone = [CalendarHomeworkMark(source: "webuntis:abc", homeworkID: "7", doneAt: created)]
        let bytes = try CalendarArchive.encodeState(state)
        XCTAssertEqual(try CalendarArchive.decodeState(bytes), state)
        XCTAssertThrowsError(try CalendarArchive.decodeState(Data(#"{"events":[],"formatVersion":5}"#.utf8))) {
            XCTAssertEqual($0 as? CalendarArchiveError, .unsupported(5))
        }
        let restored = try CalendarArchive.restored(CalendarArchiveContent(state: state), documents: [:], folders: [:])
        XCTAssertEqual(restored.state.settings.systemCalendars?.enabled, false, "Restore aktiviert keine Quelle")
        XCTAssertEqual(restored.state.settings.systemCalendars?.defaultTarget, "cal-a")
        XCTAssertEqual(restored.state.homeworkDone, state.homeworkDone)
    }

    // MARK: System event notes

    func testNoteOfASeriesOccurrenceFollowsItsOccurrenceNotTheTitle() {
        let original = at(2026, 11, 9, 10)
        let anchor = CalendarSystemAnchor(externalID: "EXT-1", itemID: "item-1", calendarID: "cal-a", occurrence: original)
        let read = (start: at(2026, 11, 1, 0), end: at(2026, 12, 1, 0))
        let moved = event("item-1", external: "EXT-1", start: at(2026, 11, 10, 14), occurrence: original, recurring: true)
        let other = event("item-1", external: "EXT-1", start: at(2026, 11, 16, 10), occurrence: at(2026, 11, 16, 10), recurring: true)
        let sameTitle = event("item-9", external: "EXT-9", start: original)
        let found = CalendarSystemMatching.resolve(anchor, events: [other, sameTitle, moved], read: read, contextStart: original)
        XCTAssertEqual(found, .found(moved), "verschobene Durchführung behält ihre Notiz")
        // Gone: „ungeklärt“, candidates of the same calendar only, nothing chosen by title.
        let foreign = event("item-5", external: "EXT-5", calendar: "cal-b", title: "Besprechung", start: original)
        guard case .unresolved(let candidates) = CalendarSystemMatching.resolve(anchor, events: [other, sameTitle, foreign], read: read,
                                                                                  contextStart: original) else { return XCTFail() }
        XCTAssertEqual(Set(candidates.map(\.itemID)), ["item-9", "item-1"])
        XCTAssertFalse(candidates.contains(foreign))
        // Outside the read range or nothing read: no statement.
        XCTAssertEqual(CalendarSystemMatching.resolve(anchor, events: [], read: (at(2027, 1, 1, 0), at(2027, 2, 1, 0)), contextStart: original), .notLoaded)
        XCTAssertEqual(CalendarSystemMatching.resolve(anchor, events: [moved], read: nil, contextStart: original), .notLoaded)
    }

    func testSingleEventMatchesByExternalIdentityAcrossCalendarsAndItemFallback() {
        let start = at(2026, 11, 12, 9)
        let read = (start: at(2026, 11, 1, 0), end: at(2026, 12, 1, 0))
        let single = event("item-2", external: "EXT-2", start: at(2026, 11, 13, 9))
        XCTAssertEqual(single.anchor.occurrence, nil)
        let anchor = CalendarSystemAnchor(externalID: "EXT-2", itemID: "item-old", calendarID: "cal-a", occurrence: nil)
        XCTAssertEqual(CalendarSystemMatching.resolve(anchor, events: [single], read: read, contextStart: start), .found(single),
                       "externe Kennung zählt, lokale Kennung darf wechseln")
        // An invitation in two calendars: the note's calendar decides; without it ambiguous.
        let copy = event("item-3", external: "EXT-2", calendar: "cal-b", start: at(2026, 11, 13, 9))
        XCTAssertEqual(CalendarSystemMatching.resolve(anchor, events: [copy, single], read: read, contextStart: start), .found(single))
        let elsewhere = CalendarSystemAnchor(externalID: "EXT-2", itemID: "x", calendarID: "cal-z", occurrence: nil)
        guard case .unresolved(let both) = CalendarSystemMatching.resolve(elsewhere, events: [copy, single], read: read, contextStart: start) else {
            return XCTFail("mehrdeutig muss ungeklärt sein")
        }
        XCTAssertEqual(both.count, 2)
        // Without external identity the device-local item id is used.
        let local = event("item-4", external: nil, start: start)
        XCTAssertEqual(CalendarSystemMatching.resolve(local.anchor, events: [local], read: read, contextStart: start), .found(local))
        XCTAssertNotEqual(local.anchor.key, single.anchor.key)
    }

    func testVisibleEventsRespectHiddenCalendarsAndDropExactDuplicates() {
        let a = event("1", external: "E1", start: at(2026, 11, 3, 8))
        let b = event("2", external: "E2", calendar: "cal-geburtstage", start: at(2026, 11, 3, 9))
        let invitation = event("3", external: "E1", calendar: "cal-b", start: at(2026, 11, 3, 8))
        XCTAssertEqual(CalendarSystemMatching.visible([a, b, a, invitation], settings: nil), [], "nicht verbunden: nichts")
        XCTAssertEqual(CalendarSystemMatching.visible([a, b], settings: CalendarSystemSettings(enabled: false)), [])
        let shown = CalendarSystemMatching.visible([b, a, a, invitation], settings: CalendarSystemSettings(hiddenCalendars: ["cal-geburtstage"]))
        XCTAssertEqual(shown.map(\.itemID).sorted(), ["1", "3"], "gleiche Einladung in zwei Kalendern bleibt zweimal, exakte Doppelung einmal")
        let calendars = [CalendarSystemCalendar(id: "cal-a", title: "Arbeit", account: "Exchange", colorHex: "#0078D4", writable: true),
                         CalendarSystemCalendar(id: "cal-geburtstage", title: "Geburtstage", account: "Andere", colorHex: "#888888", writable: false)]
        XCTAssertEqual(CalendarSystemMatching.defaultTarget(CalendarSystemSettings(defaultTarget: "cal-a"), calendars: calendars), "cal-a")
        XCTAssertNil(CalendarSystemMatching.defaultTarget(CalendarSystemSettings(defaultTarget: "cal-geburtstage"), calendars: calendars))
        XCTAssertNil(CalendarSystemMatching.defaultTarget(CalendarSystemSettings(hiddenCalendars: ["cal-a"], defaultTarget: "cal-a"), calendars: calendars))
        XCTAssertNil(CalendarSystemMatching.defaultTarget(CalendarSystemSettings(defaultTarget: "weg"), calendars: calendars))
        XCTAssertEqual(calendars[0].displayName, "Arbeit (Exchange)")
    }

    func testNotesFollowADeliberateSourceMove() {
        let eventID = UUID()
        let start = at(2026, 11, 20, 10)
        var links = [CalendarNoteLink(target: .local(event: eventID, date: nil), documentID: UUID(), createdAt: created, contextTitle: "A",
                                      contextStart: start, contextEnd: start),
                     CalendarNoteLink(target: .local(event: eventID, date: day("2026-11-20")), documentID: UUID(), createdAt: created,
                                      contextTitle: "Serie", contextStart: start, contextEnd: start)]
        let anchor = CalendarSystemAnchor(externalID: "EXT-7", itemID: "i7", calendarID: "cal-a", occurrence: nil)
        CalendarSourceMove.retargetLocal(&links, event: eventID, to: anchor)
        XCTAssertEqual(links[0].target, .system(anchor))
        XCTAssertEqual(links[1].target, .local(event: eventID, date: day("2026-11-20")), "Seriennotizen bleiben unberührt")
        let back = UUID()
        CalendarSourceMove.retargetSystem(&links, from: anchor, to: back)
        XCTAssertEqual(links[0].target, .local(event: back, date: nil))
        var moved = [CalendarNoteLink(target: .system(CalendarSystemAnchor(externalID: "EXT-7", itemID: "i7", calendarID: "cal-a",
                                                                          occurrence: start)),
                                      documentID: UUID(), createdAt: created, contextTitle: "A", contextStart: start, contextEnd: start)]
        let new = CalendarSystemAnchor(externalID: "EXT-8", itemID: "i8", calendarID: "cal-b", occurrence: nil)
        CalendarSourceMove.retarget(&moved, from: anchor, to: new)
        XCTAssertEqual(moved[0].target, .system(CalendarSystemAnchor(externalID: "EXT-8", itemID: "i8", calendarID: "cal-b", occurrence: start)))
    }

    func testAnchorCodingAndColourHex() throws {
        let anchor = CalendarSystemAnchor(externalID: "E", itemID: "i", calendarID: "c", occurrence: Date(timeIntervalSinceReferenceDate: 815_000_000.4))
        XCTAssertEqual(anchor.occurrence?.timeIntervalSinceReferenceDate, 815_000_000, "ganze Sekunden")
        let link = CalendarNoteLink(target: .system(anchor), documentID: UUID(), createdAt: created, contextTitle: "X",
                                    contextStart: created, contextEnd: created)
        XCTAssertEqual(try JSONDecoder().decode(CalendarNoteLink.self, from: JSONEncoder().encode(link)), link)
        XCTAssertEqual(CalendarNoteTarget.system(anchor).key, "system/x:E/815000000")
        XCTAssertEqual(CalendarColorHex.hex(red: 0, green: 0.4706, blue: 0.8314), "#0078D4")
        let parts = try XCTUnwrap(CalendarColorHex.components("#0078D4"))
        XCTAssertEqual(parts.blue, 212.0 / 255, accuracy: 0.0001)
        XCTAssertNil(CalendarColorHex.components("blau"))
    }

    // MARK: Holidays NRW

    func testEasterAndPublicHolidaysNRW() {
        XCTAssertEqual(CalendarHolidaysNRW.easterSunday(2025), day("2025-04-20"))
        XCTAssertEqual(CalendarHolidaysNRW.easterSunday(2026), day("2026-04-05"))
        XCTAssertEqual(CalendarHolidaysNRW.easterSunday(2027), day("2027-03-28"))
        XCTAssertEqual(CalendarHolidaysNRW.easterSunday(2028), day("2028-04-16"))
        XCTAssertEqual(CalendarHolidaysNRW.easterSunday(2038), day("2038-04-25"))
        let days = CalendarHolidaysNRW.publicHolidays(2026)
        XCTAssertEqual(days.count, 11)
        let byName = Dictionary(uniqueKeysWithValues: days.map { ($0.name, $0.start) })
        XCTAssertEqual(byName["Karfreitag"], day("2026-04-03"))
        XCTAssertEqual(byName["Christi Himmelfahrt"], day("2026-05-14"))
        XCTAssertEqual(byName["Pfingstmontag"], day("2026-05-25"))
        XCTAssertEqual(byName["Fronleichnam"], day("2026-06-04"))
        XCTAssertNil(byName["Ostersonntag"], "kein gesetzlicher Feiertag in NRW")
        XCTAssertTrue(days.allSatisfy { $0.start.days(to: $0.end) == 1 })
        XCTAssertEqual(days.map(\.start), days.map(\.start).sorted())
    }

    func testSchoolTableIsWellFormedWithExclusiveEnds() {
        let table = CalendarHolidaysNRW.schoolHolidays
        XCTAssertEqual(table.count, CalendarHolidaysNRW.schoolTable.count)
        XCTAssertTrue(zip(table, table.dropFirst()).allSatisfy { $0.end <= $1.start }, "keine Überlappung, sortiert")
        let summer = table.first { $0.name == "Sommerferien" && $0.start.year == 2026 }
        XCTAssertEqual(summer?.end, day("2026-09-02"), "letzter Ferientag einschließlich, gespeichert exklusiv")
        XCTAssertEqual(table.first { $0.name == "Pfingstferien" }?.start.days(to: table.first { $0.name == "Pfingstferien" }!.end), 1)
    }

    func testFallbackOnlyWhereWebUntisDeliversNothing() {
        let year = (day("2026-01-01"), day("2027-01-01"))
        let fallback = CalendarHolidaysNRW.holidays(from: year.0, to: year.1, webUntis: [])
        XCTAssertTrue(fallback.contains { $0.origin == .schoolTable && $0.holiday.name == "Herbstferien" && $0.holiday.start == day("2026-10-17") })
        XCTAssertTrue(fallback.contains { $0.origin == .publicHoliday && $0.holiday.name == "Tag der Deutschen Einheit" })
        // Christmas lies in the Weihnachtsferien: no second band; Allerheiligen (Sunday) after Herbstferien stays.
        XCTAssertFalse(fallback.contains { $0.origin == .publicHoliday && $0.holiday.start == day("2026-12-25") })
        XCTAssertTrue(fallback.contains { $0.origin == .publicHoliday && $0.holiday.start == day("2026-11-01") })
        // The school's own calendar for autumn 2026 to summer 2027 replaces the table there, not before.
        let school = [CalendarHoliday(id: "7", name: "Herbstferien Demo", start: day("2026-10-19"), end: day("2026-10-31")),
                      CalendarHoliday(id: "8", name: "Weihnachten Demo", start: day("2026-12-21"), end: day("2027-01-07"))]
        let merged = CalendarHolidaysNRW.holidays(from: year.0, to: year.1, webUntis: school)
        XCTAssertEqual(merged.filter { $0.origin == .webUntis }.count, 2)
        XCTAssertFalse(merged.contains { $0.origin == .schoolTable && $0.holiday.start >= day("2026-10-01") })
        XCTAssertTrue(merged.contains { $0.origin == .schoolTable && $0.holiday.name == "Sommerferien" }, "Sommer 2026 liegt vor dem WebUntis-Zeitraum")
        XCTAssertFalse(merged.contains { $0.origin == .publicHoliday && $0.holiday.start == day("2026-12-25") })
        // Outside the table years only public holidays.
        let later = CalendarHolidaysNRW.holidays(from: day("2031-01-01"), to: day("2032-01-01"), webUntis: [])
        XCTAssertTrue(later.allSatisfy { $0.origin == .publicHoliday })
        XCTAssertEqual(later.count, 11)
        XCTAssertEqual(Set(merged.map(\.id)).count, merged.count)
    }

    // MARK: Homework

    private let connection = UUID(uuidString: "5C1A0B0E-1111-4222-8333-944455556666")!

    private func user() throws -> WebUntisUser { try WebUntis.parseUserData(Data(WebUntisTests.userDataFixture.utf8)) }

    private func timetable(_ periods: [String]) -> Data {
        Data("{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"result\":{\"timetable\":{\"periods\":[\(periods.joined(separator: ","))]}}}".utf8)
    }
    private func period(_ id: Int, _ start: String, _ end: String, lesson: Int = 88, homework: String = "[]") -> String {
        """
        {"id":\(id),"lessonId":\(lesson),"startDateTime":"\(start)","endDateTime":"\(end)",
         "elements":[{"type":"SUBJECT","id":1,"orgId":1},{"type":"ROOM","id":10,"orgId":10}],
         "is":["REGULAR"],"homeWorks":\(homework)}
        """
    }

    func testParsesHomeworkTolerantlyWithoutRejectingTheTimetable() throws {
        let data = timetable([
            period(501, "2026-11-02T08:00", "2026-11-02T09:30", homework: """
            [{"id":9001,"lessonId":88,"startDate":"2026-11-02","endDate":"2026-11-04","text":"Aufgabe 3 und 4 (erfunden)","remark":"","completed":false,"attachments":[{"id":1}]},
             {"id":9002,"startDate":"20261102","endDate":"20261109","text":"Kapitel lesen","completed":true},
             {"id":9003,"text":"ohne Fälligkeit"},
             {"lessonId":88,"endDate":"2026-11-05","text":"ohne Kennung"},
             {"id":9004,"startDate":"2026-11-10","endDate":"2026-11-06","text":"Beginn nach Ende"}]
            """),
            period(502, "2026-11-04T08:00", "2026-11-04T09:30", homework: #"[{"id":9001,"endDate":"2026-11-04","text":"doppelt"}]"#),
            period(503, "2026-11-05T08:00", "2026-11-05T09:30", homework: "null"),
            period(504, "2026-11-06T08:00", "2026-11-06T09:30", homework: #""kaputt""#),
        ])
        let result = try WebUntis.parseTimetableWithHomework(data, user: user(), connection: connection, timeZone: berlin.timeZone,
                                                             start: day("2026-11-02"), end: day("2026-11-09"))
        XCTAssertEqual(result.lessons.count, 4, "Hausaufgaben verwerfen keinen Stundenplan")
        XCTAssertEqual(result.homework.map(\.id), ["9001", "9004", "9002"], "nach Fälligkeit")
        let first = try XCTUnwrap(result.homework.first { $0.id == "9001" })
        XCTAssertEqual(first.due, day("2026-11-04")); XCTAssertEqual(first.assigned, day("2026-11-02"))
        XCTAssertEqual(first.periodID, "501"); XCTAssertEqual(first.subject, "Mathematik"); XCTAssertEqual(first.lessonID, "88")
        XCTAssertNil(first.remark); XCTAssertEqual(first.attachmentCount, 1); XCTAssertEqual(first.text, "Aufgabe 3 und 4 (erfunden)")
        let second = try XCTUnwrap(result.homework.first { $0.id == "9002" })
        XCTAssertEqual(second.due, day("2026-11-09")); XCTAssertTrue(second.completedInSource); XCTAssertEqual(second.lessonID, "88")
        XCTAssertNil(result.homework.first { $0.id == "9004" }?.assigned, "Beginn nach Fälligkeit wird verworfen, die Aufgabe bleibt")
        XCTAssertEqual(try WebUntis.parseTimetable(data, user: user(), connection: connection, timeZone: berlin.timeZone,
                                                   start: day("2026-11-02"), end: day("2026-11-09")), result.lessons)
    }

    func testHomeworkInCacheIsReplacedByDayAndMarkedLocally() throws {
        let data = timetable([
            period(501, "2026-11-02T08:00", "2026-11-02T09:30", homework: #"[{"id":1,"endDate":"2026-11-04","text":"A"}]"#),
            period(502, "2026-11-04T08:00", "2026-11-04T09:30"),
            period(503, "2026-11-05T08:00", "2026-11-05T09:30", homework: #"[{"id":2,"endDate":"2026-11-12","text":"B"}]"#),
        ])
        let parsed = try WebUntis.parseTimetableWithHomework(data, user: user(), connection: connection, timeZone: berlin.timeZone,
                                                             start: day("2026-11-02"), end: day("2026-11-09"))
        var snapshot = CalendarSourceSnapshot(connection: connection)
        try snapshot.merge(CalendarTimetableFetch(connection: connection, start: day("2026-11-02"), end: day("2026-11-09"),
                                                  fetchedAt: created, lessons: parsed.lessons, homework: parsed.homework))
        XCTAssertEqual(snapshot.homework.map(\.id), ["1", "2"])
        XCTAssertNoThrow(try snapshot.validate())
        // A newer fetch of Monday only: homework 1 is gone there, 2 (Thursday) stays.
        try snapshot.merge(CalendarTimetableFetch(connection: connection, start: day("2026-11-02"), end: day("2026-11-03"),
                                                  fetchedAt: created.addingTimeInterval(60), lessons: [], homework: []))
        XCTAssertEqual(snapshot.homework.map(\.id), ["2"])
        // Round trip; a cache without the key (older build) reads as no homework.
        let bytes = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(CalendarSourceSnapshot.self, from: bytes), snapshot)
        var plain = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        plain["homework"] = nil
        let old = try JSONDecoder().decode(CalendarSourceSnapshot.self, from: JSONSerialization.data(withJSONObject: plain))
        XCTAssertEqual(old.homework, [])
        // Homework on a day that was never loaded is invalid.
        var broken = snapshot
        broken.homework[0].periodDate = day("2027-01-01")
        XCTAssertThrowsError(try broken.validate())
        // Items: the local mark decides, bound to the account; due lesson of the course.
        let full = try JSONDecoder().decode(CalendarSourceSnapshot.self, from: bytes)
        var withLesson = full
        try withLesson.merge(CalendarTimetableFetch(connection: connection, start: day("2026-11-02"), end: day("2026-11-09"),
                                                    fetchedAt: created.addingTimeInterval(120), lessons: parsed.lessons, homework: parsed.homework))
        let marks = [CalendarHomeworkMark(source: "webuntis:a", homeworkID: "1", doneAt: created),
                     CalendarHomeworkMark(source: "webuntis:fremd", homeworkID: "2", doneAt: created)]
        let items = CalendarHomeworkItem.items(snapshot: withLesson, marks: marks, source: "webuntis:a")
        XCTAssertEqual(items.map(\.id), ["1", "2"])
        XCTAssertEqual(items.map(\.done), [true, false], "Marke eines anderen Kontos zählt nicht")
        XCTAssertEqual(items[0].dueLessonID, "502", "Stunde des Kurses am Fälligkeitstag")
        XCTAssertNil(items[1].dueLessonID, "Fälligkeitstag nicht im Offline-Stundenplan")
        XCTAssertEqual(CalendarHomeworkItem.items(snapshot: nil, marks: marks, source: "webuntis:a"), [])
    }
}
