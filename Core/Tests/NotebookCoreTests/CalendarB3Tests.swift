import XCTest
@testable import NotebookCore

/// Kalender Stufe B3: calendar format 3 (reminders, deleted events), the
/// calendar part of the library backup (format 3: capture, archive,
/// independent rejection, restore into a new area with remapped links and a
/// detached connection, no secrets) and the reminder planning (rolling window,
/// deterministic identifiers, daylight saving, cancelled lessons). Fictitious
/// data only: no real school, timetable or access data.
final class CalendarB3Tests: XCTestCase {
    private var root: URL!
    private let zone = "Europe/Berlin"
    private var berlin: Calendar { CalendarDates.german(timeZone: TimeZone(identifier: zone)!) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-b3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func day(_ text: String) -> CivilDate { CivilDate(text)! }
    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        berlin.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }
    private func timed(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0, minutes: Int = 90) -> CalendarEventTiming {
        let start = at(y, m, d, h, min)
        return .timed(start: start, end: start.addingTimeInterval(Double(minutes) * 60), timeZone: zone)
    }
    private let created = Date(timeIntervalSince1970: 1_790_000_000)

    private func lesson(_ connection: UUID, period: String, course: String = "88", _ y: Int, _ m: Int, _ d: Int, _ h: Int,
                        subject: String = "Mathematik", cancelled: Bool = false) -> CalendarLesson {
        let start = at(y, m, d, h)
        let key = CalendarOccurrenceKey(provider: "webuntis", connection: connection, sourceID: period, seriesID: course,
                                        originalStart: String(format: "%04d-%02d-%02dT%02d:00", y, m, d, h))
        var value = CalendarLesson(key: key, date: CivilDate(year: y, month: m, day: d)!, start: start, end: start.addingTimeInterval(45 * 60))
        value.subjectLong = subject; value.subjectID = "12"; value.rooms = ["R 101"]
        if cancelled { value.statuses = [.cancelled] }
        return value
    }

    // MARK: Format 3

    func testFormat2PackageMigratesToFormat3WithExactOldBytes() async throws {
        let package = root.appendingPathComponent("Calendar", isDirectory: true)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("Revisions"), withIntermediateDirectories: true)
        let json = #"{"connection":null,"events":[{"createdAt":815000000,"details":"","id":"00000000-0000-4000-8000-000000000001","location":"","modifiedAt":815000000,"timing":{"end":815005400,"kind":"timed","start":815000000,"timeZone":"Europe\/Berlin"},"title":"Elternabend"}],"formatVersion":2,"lessonMappings":[],"noteLinks":[],"settings":{"mode":"week","subjectColors":{"name:mathematik":"mint"},"weekDays":5}}"#
        let bytes = Data(json.utf8)
        let file = UUID().uuidString + ".json"
        try bytes.write(to: package.appendingPathComponent("Revisions/\(file)"))
        let manifest = RevisionManifest(revisions: [RevisionRecord(file: file, byteCount: bytes.count, crc32: SnapshotChecksum.crc32(bytes),
                                                                   savedAtUnix: 1_790_000_000)])
        try JSONEncoder().encode(manifest).write(to: package.appendingPathComponent("manifest.json"))
        let repository = CalendarRepository(areaRoot: root)
        let loaded = try await repository.load()
        XCTAssertEqual(loaded.state.formatVersion, CalendarState.currentFormat)
        XCTAssertEqual(loaded.state.settings.subjectColors, ["name:mathematik": "mint"])
        var next = loaded.state
        next.events[0].reminderMinutes = 15
        try await repository.save(next, revision: 1)
        XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent("Migration/format-2-\(file)")), bytes, "exakte Altbytes")
        await repository.close()
        let reopened = try await CalendarRepository(areaRoot: root).load()
        XCTAssertEqual(reopened.state.events[0].reminderMinutes, 15)
        // Format 2 with B3 fields is not format 2; format 4 locks.
        let mixed = Data(#"{"events":[],"formatVersion":2,"deletedEvents":[],"settings":{"mode":"week","weekDays":5,"lessonReminderMinutes":10}}"#.utf8)
        XCTAssertThrowsError(try CalendarStore.decode(mixed))
        XCTAssertThrowsError(try CalendarStore.decode(Data(#"{"events":[],"formatVersion":5}"#.utf8))) {
            XCTAssertEqual($0 as? CalendarStoreError, .unsupportedFormat(5))
        }
    }

    func testRemindersAndDeletedEventsAreValidated() throws {
        let series = LocalCalendarEvent(title: "Lerngruppe", timing: timed(2026, 11, 2, 15),
                                        recurrence: CalendarRecurrence(frequency: .weekly, exceptions: [day("2026-11-09")]),
                                        reminderMinutes: 10, createdAt: created)
        var state = CalendarState()
        state.events = [series]
        state.deletedEvents = [CalendarDeletedEvent(event: series, occurrence: day("2026-11-09"), deletedAt: created)]
        state.settings.lessonReminderMinutes = 10
        XCTAssertNoThrow(try state.validate())
        var bad = state; bad.events[0].reminderMinutes = 7
        XCTAssertThrowsError(try bad.validate(), "nur Vorgaben")
        bad = state; bad.settings.lessonReminderMinutes = 0
        XCTAssertThrowsError(try bad.validate())
        bad = state; bad.deletedEvents[0].occurrence = day("2026-11-10")
        XCTAssertThrowsError(try bad.validate(), "die Serie erzeugt den Tag nicht")
        bad = state; bad.deletedEvents = [CalendarDeletedEvent(event: series, deletedAt: created)]
        XCTAssertThrowsError(try bad.validate(), "ein Termin ist aktiv oder gelöscht, nicht beides")
        let encoded = try CalendarStore.encoder.encode(state)
        XCTAssertEqual(try CalendarStore.decode(encoded), state)
        // Defaults: no reminder, no lesson reminder, nothing deleted.
        let fresh = LocalCalendarEvent(title: "Neu", timing: timed(2026, 11, 2, 9))
        XCTAssertNil(fresh.reminderMinutes)
        XCTAssertNil(CalendarSettings().lessonReminderMinutes)
        XCTAssertFalse(String(decoding: try CalendarStore.encoder.encode(CalendarState()), as: UTF8.self).contains("deletedEvents"))
    }

    // MARK: Reminder planning

    func testReminderTimesKeepWallClockAcrossDaylightSaving() {
        // Monday 26.10.2026 08:00, the day after summer time ended.
        var event = LocalCalendarEvent(title: "Klausur", location: "Aula", timing: timed(2026, 10, 26, 8), reminderMinutes: 1_440, createdAt: created)
        var state = CalendarState(); state.events = [event]
        let now = at(2026, 10, 20, 12)
        var plan = CalendarReminderPlanner.plan(state: state, snapshot: nil, now: now, calendar: berlin)
        XCTAssertEqual(plan.requests.map(\.fireDate), [at(2026, 10, 25, 8)], "1 Tag vorher: gleiche Uhrzeit trotz Zeitumstellung")
        XCTAssertEqual(plan.requests.first?.id, "noty.calendar.event.\(event.id.uuidString).single")
        XCTAssertTrue(plan.requests.first?.body.contains("Aula") == true)
        event.reminderMinutes = 30
        state.events = [event]
        plan = CalendarReminderPlanner.plan(state: state, snapshot: nil, now: now, calendar: berlin)
        XCTAssertEqual(plan.requests.map(\.fireDate), [at(2026, 10, 26, 7, 30)])
        // A weekly series over the spring change keeps 08:00 local; all-day at 09:00 of the day.
        let spring = LocalCalendarEvent(title: "Sport", timing: timed(2026, 3, 23, 8), recurrence: CalendarRecurrence(frequency: .weekly),
                                        reminderMinutes: 0, createdAt: created)
        let trip = LocalCalendarEvent(title: "Ausflug", timing: .allDay(start: day("2026-03-30"), end: day("2026-03-31")),
                                      reminderMinutes: 60, createdAt: created)
        state.events = [spring, trip]
        plan = CalendarReminderPlanner.plan(state: state, snapshot: nil, now: at(2026, 3, 24, 12), calendar: berlin, horizonDays: 14)
        let springTimes = plan.requests.filter { $0.title == "Sport" }.map(\.fireDate)
        XCTAssertEqual(springTimes, [at(2026, 3, 30, 8), at(2026, 4, 6, 8)])
        XCTAssertEqual(plan.requests.filter { $0.title == "Ausflug" }.map(\.fireDate), [at(2026, 3, 30, 8)])
        XCTAssertEqual(Set(plan.requests.map(\.id)).count, plan.requests.count)
    }

    func testRollingWindowIsCappedDeterministicAndSaysUntilWhen() {
        let connection = UUID()
        var state = CalendarState()
        state.connection = CalendarConnectionRecord(id: connection, label: "Beispielschule", connectedAt: created, sourceIdentity: "webuntis:test")
        state.settings.lessonReminderMinutes = 10
        var snapshot = CalendarSourceSnapshot(connection: connection)
        // 4 weeks × 5 days × 6 lessons = 120 lessons; one cancelled lesson per day.
        var lessons: [CalendarLesson] = []
        for week in 0..<4 {
            for weekday in 0..<5 {
                let date = day("2026-11-09").adding(days: week * 7 + weekday)
                for hour in 8..<14 {
                    lessons.append(lesson(connection, period: "\(date)-\(hour)", date.year, date.month, date.day, hour, cancelled: hour == 13))
                }
            }
        }
        snapshot.lessons = lessons
        for lesson in lessons { snapshot.days[lesson.date.description] = 815_000_000 }
        let now = at(2026, 11, 8, 18)
        let plan = CalendarReminderPlanner.plan(state: state, snapshot: snapshot, now: now, calendar: berlin)
        XCTAssertEqual(plan.requests.count, 50, "höchstens 50 geplante Erinnerungen")
        XCTAssertTrue(plan.requests.allSatisfy { $0.kind == .lesson && !$0.body.isEmpty })
        XCTAssertFalse(plan.requests.contains { $0.id.contains("-13.") || $0.title.isEmpty })
        XCTAssertFalse(plan.requests.contains { request in lessons.first { $0.isCancelled && request.id.contains($0.key.sourceID) } != nil },
                       "ausgefallene Stunden ohne Erinnerung")
        XCTAssertEqual(plan.requests.map(\.fireDate), plan.requests.map(\.fireDate).sorted())
        XCTAssertEqual(plan.requests.first?.fireDate, at(2026, 11, 9, 7, 50))
        let until = try! XCTUnwrap(plan.plannedUntil)
        XCTAssertTrue(plan.requests.allSatisfy { $0.fireDate < until })
        XCTAssertGreaterThan(plan.deferred, 0)
        // Same input, same identifiers (a reschedule replaces, never duplicates).
        let again = CalendarReminderPlanner.plan(state: state, snapshot: snapshot, now: now, calendar: berlin)
        XCTAssertEqual(again, plan)
        // Off by default; a snapshot of another connection never counts.
        state.settings.lessonReminderMinutes = nil
        XCTAssertEqual(CalendarReminderPlanner.plan(state: state, snapshot: snapshot, now: now, calendar: berlin), CalendarReminderPlan())
        state.settings.lessonReminderMinutes = 10
        state.connection = CalendarConnectionRecord(label: "Andere", connectedAt: created)
        XCTAssertTrue(CalendarReminderPlanner.plan(state: state, snapshot: snapshot, now: now, calendar: berlin).requests.isEmpty)
    }

    func testEditsReplaceTheSameIdentifierAndExceptionsDropReminders() {
        let event = LocalCalendarEvent(title: "Nachhilfe", timing: timed(2026, 11, 10, 16), recurrence: CalendarRecurrence(frequency: .weekly, end: .afterCount(3)),
                                       reminderMinutes: 15, createdAt: created)
        var state = CalendarState(); state.events = [event]
        let now = at(2026, 11, 9, 9)
        let before = CalendarReminderPlanner.plan(state: state, snapshot: nil, now: now, calendar: berlin)
        XCTAssertEqual(before.requests.map(\.id), ["2026-11-10", "2026-11-17", "2026-11-24"].map { "noty.calendar.event.\(event.id.uuidString).\($0)" })
        // Moved one hour later, one occurrence deleted, one changed on its own.
        var moved = event
        moved.timing = timed(2026, 11, 10, 17)
        moved.recurrence!.exceptions = [day("2026-11-17")]
        moved.recurrence!.overrides = [CalendarOccurrenceOverride(originalDate: day("2026-11-24"), title: "Nachhilfe (verlegt)", timing: timed(2026, 11, 25, 15))]
        state.events = [moved]
        let after = CalendarReminderPlanner.plan(state: state, snapshot: nil, now: now, calendar: berlin)
        XCTAssertEqual(after.requests.map(\.id), ["2026-11-10", "2026-11-24"].map { "noty.calendar.event.\(event.id.uuidString).\($0)" })
        XCTAssertEqual(after.requests.map(\.fireDate), [at(2026, 11, 10, 16, 45), at(2026, 11, 25, 14, 45)])
        XCTAssertEqual(after.requests.last?.title, "Nachhilfe (verlegt)")
        // Past reminders are never planned; switching the reminder off empties the plan.
        XCTAssertTrue(CalendarReminderPlanner.plan(state: state, snapshot: nil, now: at(2026, 11, 26, 0), calendar: berlin).requests.isEmpty)
        state.events[0].reminderMinutes = nil
        XCTAssertNil(CalendarReminderPlanner.plan(state: state, snapshot: nil, now: now, calendar: berlin).plannedUntil)
    }

    // MARK: Library backup with calendar

    private struct Area {
        let notebook: Notebook
        let folder: UUID
        let state: CalendarState
        let snapshot: CalendarSourceSnapshot
        let goneDocument: UUID
    }

    /// A library with one note in „Kalendernotizen“ and a calendar package
    /// with a series, a deleted event, links (one to a notebook deleted for
    /// good), a mapping, colours, reminders and a connection with timetable.
    private func makeArea(at areaRoot: URL) async throws -> Area {
        let library = LibraryStore(root: areaRoot)
        _ = try await library.load()
        let folderSnapshot = try await library.createFolder(title: CalendarNotesFolder.title, parentID: nil)
        let folder = try XCTUnwrap(folderSnapshot.items.last?.id)
        var notebook = Notebook.blank(title: "Mathematik · 10.11.2026")
        notebook.pages[0].text = "Stundennotiz"
        try RevisionStore(directory: areaRoot.appendingPathComponent("Library/Documents/\(notebook.id.uuidString)")).save(notebook)
        _ = try await library.adoptImported(notebook.id, title: notebook.title, parentID: folder, replacing: nil)

        let connection = UUID()
        let setup = try WebUntisSetup(server: "erfunden-geheim.example.invalid", school: "Beispielschule", user: "max.erfunden",
                                  key: "JBSWY3DPEHPK3PXPGEHEIMGEHEIM")
        var state = CalendarState()
        let series = LocalCalendarEvent(title: "Lerngruppe", location: "Bibliothek", timing: timed(2026, 11, 2, 15),
                                        recurrence: CalendarRecurrence(frequency: .weekly, end: .afterCount(10), exceptions: [day("2026-11-16")],
                                            overrides: [CalendarOccurrenceOverride(originalDate: day("2026-11-09"), title: "Lerngruppe (später)", timing: timed(2026, 11, 9, 17))]),
                                        reminderMinutes: 30, createdAt: created)
        let gone = LocalCalendarEvent(title: "Zahnarzt", timing: timed(2026, 11, 12, 10), createdAt: created)
        state.events = [series]
        state.deletedEvents = [CalendarDeletedEvent(event: gone, deletedAt: created.addingTimeInterval(60)),
                               CalendarDeletedEvent(event: series, occurrence: day("2026-11-16"), deletedAt: created.addingTimeInterval(120))]
        state.connection = CalendarConnectionRecord(id: connection, label: setup.school, connectedAt: created, sourceIdentity: WebUntis.sourceIdentity(setup))
        let anchor = CalendarLessonAnchor(source: WebUntis.sourceIdentity(setup), periodID: "4711", lessonID: "88",
                                          originalDate: day("2026-11-10"), originalStart: "2026-11-10T08:00")
        let goneDocument = UUID()
        state.noteLinks = [
            CalendarNoteLink(target: .lesson(anchor), documentID: notebook.id, pageID: notebook.pages[0].id, createdAt: created,
                             contextTitle: "Mathematik", contextStart: at(2026, 11, 10, 8), contextEnd: at(2026, 11, 10, 8, 45)),
            CalendarNoteLink(target: .local(event: gone.id, date: nil), documentID: notebook.id, createdAt: created,
                             contextTitle: "Zahnarzt", contextStart: at(2026, 11, 12, 10), contextEnd: at(2026, 11, 12, 11)),
            CalendarNoteLink(target: .local(event: series.id, date: day("2026-11-02")), documentID: goneDocument, createdAt: created,
                             contextTitle: "Lerngruppe", contextStart: at(2026, 11, 2, 15), contextEnd: at(2026, 11, 2, 16, 30)),
        ]
        state.lessonMappings = [CalendarLessonMapping(source: anchor.source, fromPeriodID: "4711", fromDate: day("2026-11-10"),
                                                      toPeriodID: "4800", toDate: day("2026-11-11"), confirmedAt: created)]
        state.settings.subjectColors = ["webuntis:12": "indigo"]
        state.settings.notesFolderID = folder
        state.settings.lessonReminderMinutes = 10
        state.settings.weekDays = 7
        let repository = CalendarRepository(areaRoot: areaRoot)
        _ = try await repository.load()
        try await repository.save(state, revision: 1)
        let fetched = Date(timeIntervalSince1970: 1_794_000_000)
        _ = try await repository.merge(CalendarTimetableFetch(connection: connection, start: day("2026-11-09"), end: day("2026-11-14"),
            fetchedAt: fetched, lessons: [lesson(connection, period: "4800", 2026, 11, 11, 8), lesson(connection, period: "4801", 2026, 11, 12, 9, cancelled: true)]))
        _ = try await repository.replaceHolidays([CalendarHoliday(id: "1", name: "Weihnachtsferien", start: day("2026-12-23"), end: day("2027-01-07"))],
                                                 fetchedAt: fetched, connection: connection)
        await repository.close()
        return Area(notebook: notebook, folder: folder, state: state, snapshot: try XCTUnwrap(CalendarArchive.readCache(
            directory: areaRoot.appendingPathComponent("Calendar"), connection: connection)), goneDocument: goneDocument)
    }

    func testArchiveWithCalendarRestoresIntoNewAreaWithRemappedLinksAndDetachedConnection() async throws {
        let source = root.appendingPathComponent("Source", isDirectory: true)
        let area = try await makeArea(at: source)
        let plan = try await LibraryStore(root: source).backupPlan()
        let capture = try XCTUnwrap(plan.calendar)
        XCTAssertEqual(capture.droppedLinks, 1, "Link auf endgültig gelöschtes Heft wird nicht gesichert")
        XCTAssertFalse(capture.sourceMissing)
        let archive = root.appendingPathComponent("bibliothek.notylibrary")
        let summary = try LibraryArchive.write(plan, to: archive)
        XCTAssertEqual(summary.formatVersion, 3)
        let archived = try XCTUnwrap(summary.calendar)
        var expected = area.state
        expected.noteLinks.removeAll { $0.documentID == area.goneDocument }
        XCTAssertEqual(archived.state, expected)
        XCTAssertEqual(archived.source, area.snapshot)
        XCTAssertEqual(archived.source?.days.values.first, Date(timeIntervalSince1970: 1_794_000_000).timeIntervalSinceReferenceDate, "Datenstand bleibt")

        // Restore into a new area.
        let workspaces = WorkspaceStore(root: root.appendingPathComponent("Workspaces", isDirectory: true))
        let prepared = try await workspaces.prepareRestore(file: archive)
        XCTAssertEqual(prepared.summary.calendar, archived)
        let restoredArea = try await workspaces.commitRestore(prepared, title: "Restore 1")
        let data = try await workspaces.directory(for: restoredArea.id)
        let restored = try await CalendarRepository(areaRoot: data).load()
        XCTAssertFalse(restored.recovered)
        let state = restored.state
        XCTAssertEqual(state.events, expected.events)
        XCTAssertEqual(state.deletedEvents, expected.deletedEvents)
        XCTAssertEqual(state.lessonMappings, expected.lessonMappings)
        XCTAssertEqual(state.settings, expected.settings, "Farben, Ordner, Wochentage, Erinnerungseinstellung")
        XCTAssertEqual(state.noteLinks, expected.noteLinks, "Links zeigen auf die gleich nummerierten Hefte des neuen Bereichs")
        // Every link reaches a notebook of the restored area itself.
        let restoredLibrary = try await LibraryStore(root: data).committedSnapshot()
        let restoredDocuments = Set(restoredLibrary.items.filter { !$0.isFolder }.map(\.id))
        XCTAssertTrue(state.noteLinks.allSatisfy { restoredDocuments.contains($0.documentID) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.appendingPathComponent("Library/Documents/\(area.notebook.id.uuidString)").path))
        XCTAssertEqual(CalendarNotesFolder.usable(state.settings.notesFolderID, in: restoredLibrary), area.folder)
        // The connection is detached: new id (no keychain item can match), same account identity.
        let connection = try XCTUnwrap(state.connection)
        XCTAssertNotEqual(connection.id, area.state.connection!.id)
        XCTAssertEqual(connection.source, area.state.connection!.source)
        XCTAssertEqual(connection.label, area.state.connection!.label)
        // The timetable came along with its fetch times, bound to the new id.
        let repository = CalendarRepository(areaRoot: data)
        _ = try await repository.load()
        let snapshot = try await repository.sourceSnapshot()
        await repository.close()
        XCTAssertEqual(snapshot?.connection, connection.id)
        XCTAssertEqual(snapshot?.days, area.snapshot.days)
        XCTAssertEqual(snapshot?.holidays, area.snapshot.holidays)
        XCTAssertEqual(snapshot?.lessons.map(\.key.sourceID), area.snapshot.lessons.map(\.key.sourceID))
        XCTAssertTrue(snapshot?.lessons.allSatisfy { $0.key.connection == connection.id } == true)
        // Lesson notes still resolve through the mapping against the restored timetable.
        guard case .lesson(let anchor) = state.noteLinks[0].target else { return XCTFail() }
        guard case .found(let found) = CalendarLessonMatching.resolve(anchor, mappings: state.lessonMappings, snapshot: snapshot) else { return XCTFail() }
        XCTAssertEqual(found.key.sourceID, "4800")
        // The original area is untouched.
        let original = try await CalendarRepository(areaRoot: source).load()
        XCTAssertEqual(original.state, area.state)
        // A second backup of the restored area is again a complete format-3 archive.
        let second = try LibraryArchive.write(try await LibraryStore(root: data).backupPlan(), to: root.appendingPathComponent("zweites.notylibrary"))
        XCTAssertEqual(second.formatVersion, 3)
        XCTAssertEqual(second.calendar?.state.noteLinks, expected.noteLinks)
    }

    func testOldArchivesRestoreWithoutCalendarAndAreasWithoutCalendarStayFormat2() async throws {
        let source = root.appendingPathComponent("Plain", isDirectory: true)
        let library = LibraryStore(root: source)
        _ = try await library.load()
        var notebook = Notebook.blank(title: "Heft")
        notebook.pages[0].text = "Inhalt"
        var index = LibrarySnapshot()
        index.items = [LibraryItem(id: notebook.id, title: notebook.title, source: .library)]
        let bundle = LibraryBundle(snapshot: index, documents: [notebook])
        let workspaces = WorkspaceStore(root: root.appendingPathComponent("Workspaces", isDirectory: true))
        for (name, bytes) in [("v1", try LibraryArchive.encodeVersion1(bundle)), ("v2", try LibraryArchive.encode(bundle))] {
            let file = root.appendingPathComponent("\(name).notylibrary")
            try bytes.write(to: file)
            let prepared = try await workspaces.prepareRestore(file: file)
            XCTAssertNil(prepared.summary.calendar)
            XCTAssertLessThanOrEqual(prepared.summary.formatVersion, 2)
            let area = try await workspaces.commitRestore(prepared, title: "Alt \(name)")
            let data = try await workspaces.directory(for: area.id)
            XCTAssertFalse(FileManager.default.fileExists(atPath: data.appendingPathComponent("Calendar").path), "kein Kalenderbestand")
            let loaded = try await CalendarRepository(areaRoot: data).load()
            XCTAssertEqual(loaded.state, CalendarState())
        }
        // An area whose calendar holds only defaults writes format 2 (older builds can restore it).
        let repository = CalendarRepository(areaRoot: source)
        _ = try await repository.load()
        try await repository.save(CalendarState(), revision: 1)
        await repository.close()
        let plan = try await library.backupPlan()
        XCTAssertNil(plan.calendar)
        let summary = try LibraryArchive.write(plan, to: root.appendingPathComponent("leer.notylibrary"))
        XCTAssertEqual(summary.formatVersion, 2)
    }

    /// Rebuilds an archive record by record (CRCs and end totals recomputed).
    private func rebuild(_ data: Data, header: [String: Any]? = nil, transform: (inout [(descriptor: [String: Any], payload: Data)]) -> Void) throws -> Data {
        var offset = 8
        func take(_ count: Int) -> Data { defer { offset += count }; return data.subdata(in: offset..<(offset + count)) }
        func length() -> Int { take(4).reduce(0) { $0 << 8 | Int($1) } }
        var headerObject = try JSONSerialization.jsonObject(with: take(length())) as! [String: Any]
        if let header { headerObject.merge(header) { _, new in new } }
        var records: [(descriptor: [String: Any], payload: Data)] = []
        while true {
            let descriptor = try JSONSerialization.jsonObject(with: take(length())) as! [String: Any]
            if descriptor["kind"] as? String == "end" { break }
            records.append((descriptor, take(descriptor["byteCount"] as! Int)))
        }
        transform(&records)
        func prefixed(_ bytes: Data) -> Data {
            var count = UInt32(bytes.count).bigEndian
            return Data(bytes: &count, count: 4) + bytes
        }
        func encoded(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
        var output = Data("NOTYLIB\n".utf8) + prefixed(try encoded(headerObject))
        var total = 0
        for var record in records {
            if record.descriptor["crc32"] != nil { record.descriptor["crc32"] = StreamingCRC32.checksum(record.payload); record.descriptor["byteCount"] = record.payload.count }
            output += prefixed(try encoded(record.descriptor)) + record.payload
            total += record.payload.count
        }
        return output + prefixed(try encoded(["kind": "end", "records": records.count, "payloadBytes": total]))
    }

    func testNewerDamagedOrDanglingCalendarArchivesAreRejectedBeforePublishing() async throws {
        let source = root.appendingPathComponent("Source", isDirectory: true)
        _ = try await makeArea(at: source)
        let archive = root.appendingPathComponent("bibliothek.notylibrary")
        _ = try LibraryArchive.write(try await LibraryStore(root: source).backupPlan(), to: archive)
        let valid = try Data(contentsOf: archive)
        let workspaces = WorkspaceStore(root: root.appendingPathComponent("Workspaces", isDirectory: true))
        func calendarRecord(_ records: inout [(descriptor: [String: Any], payload: Data)], _ change: (inout [String: Any]) -> Void) {
            let index = records.firstIndex { $0.descriptor["kind"] as? String == "calendar" }!
            var object = try! JSONSerialization.jsonObject(with: records[index].payload) as! [String: Any]
            change(&object)
            records[index].payload = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        var flipped = valid
        let marker = valid.range(of: Data("Lerngruppe".utf8))!
        flipped[marker.lowerBound] ^= 0x20
        let cases: [(String, Data, (Error) -> Void)] = [
            ("Bibliotheksformat 4", try rebuild(valid, header: ["libraryBackupVersion": 4]) { _ in },
             { XCTAssertEqual($0 as? LibraryArchiveError, .unsupported(4)) }),
            ("beschädigter Kalenderteil", flipped, { guard case BackupError.checksumMismatch = $0 else { return XCTFail("\($0)") } }),
            ("Kalenderformat 5", try rebuild(valid) { calendarRecord(&$0) { $0["formatVersion"] = 5 } },
             { XCTAssertEqual($0 as? CalendarArchiveError, .unsupported(5)) }),
            ("Link auf fremdes Heft", try rebuild(valid) { records in calendarRecord(&records) { state in
                var links = state["noteLinks"] as! [[String: Any]]
                links[0]["documentID"] = UUID().uuidString
                state["noteLinks"] = links
            } }, { XCTAssertEqual($0 as? CalendarArchiveError, .danglingReference) }),
            ("Geheimnisfeld in der Verbindung", try rebuild(valid) { records in calendarRecord(&records) { state in
                var connection = state["connection"] as! [String: Any]
                connection["key"] = "JBSWY3DPEHPK3PXP"
                state["connection"] = connection
            } }, { XCTAssertEqual($0 as? CalendarArchiveError, .invalid) }),
            ("Kalender fehlt in Format 3", try rebuild(valid) { $0.removeAll { ($0.descriptor["kind"] as? String)?.hasPrefix("calendar") == true } },
             { XCTAssertEqual($0 as? LibraryArchiveError, .invalid) }),
            ("Stundenplan ohne Kalender davor", try rebuild(valid) { records in
                let index = records.firstIndex { $0.descriptor["kind"] as? String == "calendar" }!
                records.swapAt(index, index + 1)
            }, { XCTAssertEqual($0 as? LibraryArchiveError, .invalid) }),
        ]
        XCTAssertNoThrow(try LibraryArchive.decode(try rebuild(valid) { _ in }), "der Nachbau selbst ist gültig")
        for (name, bytes, check) in cases {
            let file = root.appendingPathComponent("fall-\(UUID().uuidString).notylibrary")
            try bytes.write(to: file)
            do { _ = try await workspaces.prepareRestore(file: file); XCTFail("\(name): angenommen") } catch { check(error) }
            XCTAssertThrowsError(try LibraryArchive.decode(bytes), name)
        }
        let listing = try await workspaces.list()
        XCTAssertTrue(listing.workspaces.isEmpty, "nichts veröffentlicht")
        let staging = root.appendingPathComponent("Workspaces/Staging")
        XCTAssertTrue(((try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []).isEmpty, "keine Stage übrig")
    }

    func testArchiveNeverContainsAccessData() async throws {
        let source = root.appendingPathComponent("Source", isDirectory: true)
        _ = try await makeArea(at: source)
        let archive = root.appendingPathComponent("bibliothek.notylibrary")
        _ = try LibraryArchive.write(try await LibraryStore(root: source).backupPlan(), to: archive)
        let bytes = try Data(contentsOf: archive)
        // The fictitious „Freigabe“ of `makeArea`: server, user and key never appear.
        for secret in ["erfunden-geheim", "example.invalid", "max.erfunden", "JBSWY3DPEHPK3PXPGEHEIMGEHEIM", "GEHEIMGEHEIM"] {
            XCTAssertNil(bytes.range(of: Data(secret.utf8)), "„\(secret)“ im Archiv")
            XCTAssertNil(bytes.range(of: Data(secret.lowercased().utf8)))
        }
        XCTAssertNotNil(bytes.range(of: Data("Beispielschule".utf8)), "nur der angezeigte Schulname")
        // A notebook backup stays a notebook backup: no calendar record kind is accepted there.
        XCTAssertNil(try BackupArchive.encode(Notebook.blank(title: "Heft")).range(of: Data("calendar".utf8)))
    }

    // MARK: Restored areas never activate a source

    func testRestoredConnectionNeedsReconnectAndKeepsB1Anchors() throws {
        let old = UUID()
        var state = CalendarState()
        state.connection = CalendarConnectionRecord(id: old, label: "Beispielschule", connectedAt: created)  // B1 record, no identity
        let anchor = CalendarLessonAnchor(source: "connection:" + old.uuidString, periodID: "1", lessonID: nil,
                                          originalDate: day("2026-11-10"), originalStart: "2026-11-10T08:00")
        let document = UUID()
        state.noteLinks = [CalendarNoteLink(target: .lesson(anchor), documentID: document, createdAt: created, contextTitle: "Deutsch",
                                            contextStart: at(2026, 11, 10, 8), contextEnd: at(2026, 11, 10, 9))]
        let content = CalendarArchiveContent(state: state)
        let fresh = UUID()
        let restored = try CalendarArchive.restored(content, documents: [document: document], folders: [:], connection: fresh)
        XCTAssertEqual(restored.state.connection?.id, fresh)
        XCTAssertEqual(restored.state.connection?.source, anchor.source, "B1-Notizen behalten ihren Anker")
        let other = UUID()
        let remapped = try CalendarArchive.restored(content, documents: [document: other], folders: [:], connection: fresh)
        XCTAssertEqual(remapped.state.noteLinks.map(\.documentID), [other], "explizite ID-Abbildung")
        XCTAssertThrowsError(try CalendarArchive.restored(content, documents: [:], folders: [:])) {
            XCTAssertEqual($0 as? CalendarArchiveError, .danglingReference)
        }
    }
}
