import XCTest
@testable import NotebookCore

/// Kalender Stufe B2: series (expansion, daylight saving, month ends,
/// exceptions, limits), note links and the rule-8 creation order, lesson
/// mapping for moved/cancelled lessons, subject colours and the migration of
/// B1 calendar packages. Fictitious data only.
final class CalendarB2Tests: XCTestCase {
    private var root: URL!
    private let zone = "Europe/Berlin"
    private var berlin: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: zone)!; return c }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-b2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func day(_ text: String) -> CivilDate { CivilDate(text)! }
    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        berlin.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }
    private func timed(_ y: Int, _ m: Int, _ d: Int, _ h: Int, minutes: Int = 90) -> CalendarEventTiming {
        let start = at(y, m, d, h)
        return .timed(start: start, end: start.addingTimeInterval(Double(minutes) * 60), timeZone: zone)
    }
    private func series(_ timing: CalendarEventTiming, _ rule: CalendarRecurrence, title: String = "Lerngruppe") -> LocalCalendarEvent {
        LocalCalendarEvent(id: UUID(), title: title, timing: timing, recurrence: rule, createdAt: Date(timeIntervalSince1970: 1_790_000_000))
    }
    private func dates(_ expansion: CalendarExpansion) -> [String] {
        expansion.occurrences.compactMap { $0.originalDate?.description }.sorted()
    }

    // MARK: Series

    func testWeeklySeriesKeepsWallClockAcrossDaylightSaving() {
        // Monday 19.10.2026 08:00; summer time ends on 25.10.2026.
        let event = series(timed(2026, 10, 19, 8), CalendarRecurrence(frequency: .weekly))
        let result = CalendarSeries.expand([event], from: day("2026-10-19"), to: day("2026-11-03"))
        XCTAssertEqual(dates(result), ["2026-10-19", "2026-10-26", "2026-11-02"])
        for occurrence in result.occurrences {
            guard case .timed(let start, let end, _) = occurrence.timing else { return XCTFail("zeitgebunden erwartet") }
            XCTAssertEqual(berlin.component(.hour, from: start), 8)
            XCTAssertEqual(end.timeIntervalSince(start), 90 * 60)
        }
        // Spring: 29.03.2026 is a Sunday without 02:00–03:00; the weekly series at 02:30 stays an occurrence.
        let night = series(timed(2026, 3, 22, 2, minutes: 30).shiftedMinutes(30), CalendarRecurrence(frequency: .weekly))
        let spring = CalendarSeries.expand([night], from: day("2026-03-22"), to: day("2026-04-06"))
        XCTAssertEqual(dates(spring), ["2026-03-22", "2026-03-29", "2026-04-05"])
        guard case .timed(let gap, let gapEnd, _) = spring.occurrences.first(where: { $0.originalDate == day("2026-03-29") })!.timing else { return XCTFail() }
        XCTAssertGreaterThan(gapEnd, gap)
        XCTAssertEqual(CivilDate(gap, calendar: berlin), day("2026-03-29"))
    }

    func testMonthlyOnThe31stSkipsShortMonthsAndCountsRealDates() {
        let rule = CalendarRecurrence(frequency: .monthly, end: .afterCount(4))
        let event = series(timed(2026, 1, 31, 18), rule)
        let result = CalendarSeries.expand([event], from: day("2026-01-01"), to: day("2027-01-01"))
        // February, April, June are skipped; four real dates.
        XCTAssertEqual(dates(result), ["2026-01-31", "2026-03-31", "2026-05-31", "2026-07-31"])
        XCTAssertTrue(CalendarSeries.generates(day("2026-07-31"), timing: event.timing, rule: rule))
        XCTAssertFalse(CalendarSeries.generates(day("2026-08-31"), timing: event.timing, rule: rule))
        XCTAssertFalse(CalendarSeries.generates(day("2026-02-28"), timing: event.timing, rule: rule))
        // Leap day: only in leap years.
        let leap = series(.allDay(start: day("2024-02-29"), end: day("2024-03-01")), CalendarRecurrence(frequency: .monthly, interval: 12))
        XCTAssertEqual(dates(CalendarSeries.expand([leap], from: day("2024-01-01"), to: day("2026-12-31"))), ["2024-02-29"])
        XCTAssertEqual(dates(CalendarSeries.expand([leap], from: day("2028-01-01"), to: day("2028-12-31"))), ["2028-02-29"])
    }

    func testExceptionsUntilAndChangedOccurrences() {
        var rule = CalendarRecurrence(frequency: .daily, end: .until(day("2026-11-06")))
        rule.exceptions = [day("2026-11-04")]
        // The 05.11. occurrence was moved to the 20.11. on its own.
        rule.overrides = [CalendarOccurrenceOverride(originalDate: day("2026-11-05"), title: "Verschoben", timing: timed(2026, 11, 20, 10))]
        let event = series(timed(2026, 11, 2, 8), rule)
        let week = CalendarSeries.expand([event], from: day("2026-11-01"), to: day("2026-11-09"))
        XCTAssertEqual(dates(week), ["2026-11-02", "2026-11-03", "2026-11-06"])
        let later = CalendarSeries.expand([event], from: day("2026-11-16"), to: day("2026-11-23"))
        XCTAssertEqual(later.occurrences.count, 1)
        XCTAssertEqual(later.occurrences[0].originalDate, day("2026-11-05"))
        XCTAssertEqual(later.occurrences[0].title, "Verschoben")
        XCTAssertTrue(later.occurrences[0].isOverride)
        // The changed occurrence keeps the identity of its original date (its note).
        XCTAssertEqual(later.occurrences[0].noteTarget, .local(event: event.id, date: day("2026-11-05")))
        // An exception also hides a changed occurrence of that date.
        rule.exceptions.append(day("2026-11-05"))
        let hidden = CalendarSeries.expand([series(timed(2026, 11, 2, 8), rule)], from: day("2026-11-16"), to: day("2026-11-23"))
        XCTAssertTrue(hidden.occurrences.isEmpty)
    }

    func testAllDaySeriesAndSingleEvents() {
        let trip = series(.allDay(start: day("2026-11-02"), end: day("2026-11-04")), CalendarRecurrence(frequency: .weekly, interval: 2))
        let single = LocalCalendarEvent(title: "Arzt", timing: timed(2026, 11, 3, 9))
        let result = CalendarSeries.expand([trip, single], from: day("2026-11-01"), to: day("2026-12-01"))
        XCTAssertEqual(dates(result), ["2026-11-02", "2026-11-16", "2026-11-30"])
        XCTAssertEqual(result.occurrences.filter { $0.originalDate == nil }.count, 1)
        guard case .allDay(let start, let end) = result.occurrences.first(where: { $0.originalDate == day("2026-11-16") })!.timing else { return XCTFail() }
        XCTAssertEqual(start, day("2026-11-16")); XCTAssertEqual(end, day("2026-11-18"))
        XCTAssertEqual(CalendarRecurrence(frequency: .weekly, interval: 2, end: .until(day("2026-12-20"))).text, "Alle 2 Wochen · bis 20.12.2026")
    }

    func testExpansionIsBoundedAndReportsTruncation() {
        // A daily series that started long ago is reached by jumping, not by walking.
        let old = series(timed(1990, 1, 1, 7), CalendarRecurrence(frequency: .daily))
        let week = CalendarSeries.expand([old], from: day("2026-11-02"), to: day("2026-11-09"))
        // Reaches back by the occurrence length (+1 day) for events reaching into the range.
        XCTAssertEqual(dates(week), ["2026-10-31", "2026-11-01", "2026-11-02", "2026-11-03", "2026-11-04", "2026-11-05",
                                     "2026-11-06", "2026-11-07", "2026-11-08", "2026-11-09"])
        XCTAssertTrue(week.truncated.isEmpty)
        // More occurrences than the per-series limit: reported, never silently cut.
        let long = CalendarSeries.expand([old], from: day("2026-01-01"), to: day("2027-09-01"))
        XCTAssertEqual(long.occurrences.count, CalendarSeries.maximumPerSeries)
        XCTAssertEqual(long.truncated, [old.id])
        // A range beyond the maximum is limited and reported as well.
        let weekly = series(timed(2026, 1, 5, 7), CalendarRecurrence(frequency: .weekly))
        let wide = CalendarSeries.expand([weekly], from: day("2026-01-01"), to: day("2030-01-01"))
        XCTAssertEqual(wide.truncated, [weekly.id])
        XCTAssertLessThanOrEqual(wide.occurrences.count, CalendarSeries.maximumRangeDays / 7 + 2)
    }

    func testSeriesValidationAndShift() throws {
        var state = CalendarState()
        var rule = CalendarRecurrence(frequency: .weekly, end: .afterCount(10), exceptions: [day("2026-11-09")])
        state.events = [series(timed(2026, 11, 2, 8), rule)]
        XCTAssertNoThrow(try state.validate())
        rule.end = .afterCount(0)
        state.events = [series(timed(2026, 11, 2, 8), rule)]
        XCTAssertThrowsError(try state.validate())
        rule.end = .until(day("2026-11-01"))
        state.events = [series(timed(2026, 11, 2, 8), rule)]
        XCTAssertThrowsError(try state.validate())
        let moved = CalendarSeries.shifted(CalendarRecurrence(frequency: .weekly, end: .until(day("2026-12-01")), exceptions: [day("2026-11-09")]), byDays: 1)
        XCTAssertEqual(moved.exceptions, [day("2026-11-10")])
        XCTAssertEqual(moved.end, .until(day("2026-12-02")))
    }

    // MARK: Links and persistence

    private func link(_ target: CalendarNoteTarget, document: UUID = UUID()) -> CalendarNoteLink {
        CalendarNoteLink(target: target, documentID: document, pageID: UUID(), createdAt: Date(timeIntervalSince1970: 1_793_000_000),
                         contextTitle: "Rechnungswesen", contextStart: at(2026, 11, 3, 8), contextEnd: at(2026, 11, 3, 9, 30))
    }

    func testLinksMappingsColoursAndSeriesRoundTrip() async throws {
        var state = CalendarState()
        let event = series(timed(2026, 11, 2, 8), CalendarRecurrence(frequency: .weekly, end: .until(day("2026-12-21")), exceptions: [day("2026-11-16")],
            overrides: [CalendarOccurrenceOverride(originalDate: day("2026-11-09"), title: "Später", timing: timed(2026, 11, 9, 10))]))
        state.events = [event]
        let anchor = CalendarLessonAnchor(source: "webuntis:abc", periodID: "4711", lessonID: "88", originalDate: day("2026-11-03"), originalStart: "2026-11-03T08:00")
        state.noteLinks = [link(.local(event: event.id, date: day("2026-11-09"))), link(.lesson(anchor))]
        state.lessonMappings = [CalendarLessonMapping(source: "webuntis:abc", fromPeriodID: "4711", fromDate: day("2026-11-03"),
                                                      toPeriodID: "4800", toDate: day("2026-11-05"), confirmedAt: Date(timeIntervalSince1970: 1_793_100_000))]
        state.settings.subjectColors = ["webuntis:12": "indigo"]
        state.settings.notesFolderID = UUID()
        let repository = CalendarRepository(areaRoot: root)
        _ = try await repository.load()
        try await repository.save(state, revision: 1)
        await repository.close()
        let reloaded = try await CalendarRepository(areaRoot: root).load()
        XCTAssertEqual(reloaded.state, state)
        XCTAssertFalse(reloaded.recovered)
        // Invalid colours or links are never committed.
        var bad = state
        bad.settings.subjectColors = ["webuntis:12": "red"]
        XCTAssertThrowsError(try bad.validate())
        bad = state
        bad.noteLinks.append(bad.noteLinks[0])
        XCTAssertThrowsError(try bad.validate())
        XCTAssertEqual(CalendarNoteTarget.local(event: event.id, date: nil).key, "local/\(event.id.uuidString)")
        XCTAssertNotEqual(CalendarNoteTarget.local(event: event.id, date: day("2026-11-09")).key, CalendarNoteTarget.local(event: event.id, date: nil).key)
    }

    // MARK: Rule 8: notebook first (library), then link

    private final class Steps: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func add(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return values }
    }
    private struct Injected: Error {}

    func testCreationCommitsNotebookThenLibraryThenLinkAndResumesWithoutDuplicates() async throws {
        let library = LibraryStore(root: root)
        _ = try await library.load()
        let folderSnapshot = try await library.createFolder(title: CalendarNotesFolder.title, parentID: nil)
        let folder = try XCTUnwrap(folderSnapshot.items.last?.id)
        let calendar = CalendarRepository(areaRoot: root)
        _ = try await calendar.load()
        let documentID = UUID()
        let target = CalendarNoteTarget.local(event: UUID(), date: nil)
        let creation = CalendarNoteCreation(documentID: documentID, target: target)
        let steps = Steps()
        let failLink = Steps()
        let root = self.root!
        var notebook = Notebook.blank(title: "Arzt · 03.11.2026")
        notebook.id = documentID
        let document = notebook
        let commit: @Sendable () async throws -> Void = {
            steps.add("notebook")
            try RevisionStore(directory: root.appendingPathComponent("Library/Documents/\(documentID.uuidString)")).save(document)
        }
        let adopt: @Sendable () async throws -> Void = {
            steps.add("library")
            _ = try await library.adoptImported(documentID, title: document.title, parentID: folder, replacing: nil)
        }
        let linkStep: @Sendable () async throws -> Void = {
            steps.add("link")
            if failLink.all.isEmpty { failLink.add("x"); throw Injected() }
            var state = CalendarState()
            state.noteLinks = [CalendarNoteLink(target: target, documentID: documentID, contextTitle: "Arzt",
                                                contextStart: Date(timeIntervalSince1970: 1_793_000_000), contextEnd: Date(timeIntervalSince1970: 1_793_003_600))]
            state.settings.notesFolderID = folder
            try await calendar.save(state, revision: 1)
        }
        do { try await creation.run(commitNotebook: commit, addToLibrary: adopt, link: linkStep); XCTFail("Fehler erwartet") } catch {}
        // The link failed: the notebook is committed and findable in „Kalendernotizen“, no link exists.
        let stage = await creation.stage
        XCTAssertEqual(stage, .inLibrary)
        XCTAssertEqual(steps.all, ["notebook", "library", "link"])
        let afterFailure = try await library.committedSnapshot()
        XCTAssertEqual(afterFailure.items.filter { $0.id == documentID }.map(\.parentID), [folder])
        await calendar.close()
        let unlinked = try await CalendarRepository(areaRoot: root).load()
        XCTAssertTrue(unlinked.state.noteLinks.isEmpty)
        // The retry only links again: same document, no second notebook.
        try await creation.run(commitNotebook: commit, addToLibrary: adopt, link: linkStep)
        XCTAssertEqual(steps.all, ["notebook", "library", "link", "link"])
        let finalStage = await creation.stage
        XCTAssertEqual(finalStage, .linked)
        await calendar.close()
        let linked = try await CalendarRepository(areaRoot: root).load()
        XCTAssertEqual(linked.state.noteLinks.map(\.documentID), [documentID])
        let documents = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Library/Documents").path)
        XCTAssertEqual(documents, [documentID.uuidString])
        let index = try await library.committedSnapshot()
        XCTAssertEqual(index.items.filter { !$0.isFolder }.count, 1)
    }

    func testFailedLibraryStepLeavesDiscoverablePackageAndConcurrentRunsShareOneCommit() async throws {
        let documentID = UUID()
        var notebook = Notebook.blank(title: "Notiz")
        notebook.id = documentID
        let document = notebook, root = self.root!
        let steps = Steps()
        let creation = CalendarNoteCreation(documentID: documentID, target: .local(event: UUID(), date: nil))
        let commit: @Sendable () async throws -> Void = {
            steps.add("notebook")
            try await Task.sleep(for: .milliseconds(50))
            try RevisionStore(directory: root.appendingPathComponent("Library/Documents/\(documentID.uuidString)")).save(document)
        }
        let failing: @Sendable () async throws -> Void = { steps.add("library"); throw Injected() }
        let never: @Sendable () async throws -> Void = { steps.add("link") }
        async let first: CalendarNoteCreation.Stage? = try? creation.run(commitNotebook: commit, addToLibrary: failing, link: never)
        async let second: CalendarNoteCreation.Stage? = try? creation.run(commitNotebook: commit, addToLibrary: failing, link: never)
        _ = await (first, second)
        XCTAssertEqual(steps.all.filter { $0 == "notebook" }.count, 1, "nur ein Heft")
        XCTAssertFalse(steps.all.contains("link"), "ohne Bibliothekseintrag kein Link")
        let stage = await creation.stage
        XCTAssertEqual(stage, .notebookCommitted)
        // The committed package is found by the next library load (not lost).
        let library = LibraryStore(root: root)
        let load = try await library.load()
        XCTAssertTrue(load.snapshot.items.contains { $0.id == documentID })
    }

    func testNotesFolderByIdentityAndTitles() async throws {
        let library = LibraryStore(root: root)
        _ = try await library.load()
        let own = try await library.createFolder(title: CalendarNotesFolder.title, parentID: nil).items.last!.id
        let stored = try await library.createFolder(title: "Umbenannt", parentID: nil).items.last!.id
        var snapshot = try await library.committedSnapshot()
        XCTAssertEqual(CalendarNotesFolder.usable(stored, in: snapshot), stored, "über die ID, auch umbenannt")
        XCTAssertNil(CalendarNotesFolder.usable(nil, in: snapshot), "nie über den Namen: \(own)")
        snapshot = try await library.trash(stored)
        XCTAssertNil(CalendarNotesFolder.usable(stored, in: snapshot), "Papierkorb zählt als fehlend")
        XCTAssertEqual(CalendarNotesFolder.noteTitle(subject: "Rechnungswesen", date: day("2026-11-03"), taken: []), "Rechnungswesen · 03.11.2026")
        let second = CalendarNotesFolder.noteTitle(subject: "Rechnungswesen", date: day("2026-11-03"), taken: ["Rechnungswesen · 03.11.2026"])
        XCTAssertNotEqual(second, "Rechnungswesen · 03.11.2026")
        XCTAssertTrue(second.hasPrefix("Rechnungswesen · 03.11.2026"))
        XCTAssertLessThanOrEqual(CalendarNotesFolder.noteTitle(subject: String(repeating: "x", count: 300), date: day("2026-11-03"), taken: []).count, 120)
    }

    // MARK: Lesson mapping

    private let connection = UUID()
    private func lesson(_ period: String, course: String?, date: String, hour: Int, cancelled: Bool = false, title: String = "Mathematik") -> CalendarLesson {
        let d = day(date)
        let key = CalendarOccurrenceKey(provider: "webuntis", connection: connection, sourceID: period, seriesID: course,
                                        originalStart: String(format: "%@T%02d:00", date, hour))
        var lesson = CalendarLesson(key: key, date: d, start: at(d.year, d.month, d.day, hour), end: at(d.year, d.month, d.day, hour + 1))
        lesson.subjectLong = title
        if cancelled { lesson.statuses = [.cancelled] }
        return lesson
    }
    private func snapshot(_ lessons: [CalendarLesson], days: [String]) throws -> CalendarSourceSnapshot {
        var snapshot = CalendarSourceSnapshot(connection: connection)
        try snapshot.merge(CalendarTimetableFetch(connection: connection, start: day(days[0]), end: day(days[1]),
                                                  fetchedAt: Date(timeIntervalSince1970: 1_793_000_000), lessons: lessons))
        return snapshot
    }

    func testLessonNotesFollowMovedAndCancelledLessons() throws {
        let anchor = CalendarLessonAnchor(source: "webuntis:abc", periodID: "100", lessonID: "7", originalDate: day("2026-11-03"), originalStart: "2026-11-03T08:00")
        // Same period id at another time (moved): found, although the B1 entry id changed.
        let moved = lesson("100", course: "7", date: "2026-11-05", hour: 10)
        guard case .found(let found) = CalendarLessonMatching.resolve(anchor, mappings: [], snapshot: try snapshot([moved], days: ["2026-11-02", "2026-11-09"])) else {
            return XCTFail("verschobene Stunde erwartet")
        }
        XCTAssertEqual(found.date, day("2026-11-05"))
        // Cancelled but still delivered: found with its state.
        let cancelled = lesson("100", course: "7", date: "2026-11-03", hour: 8, cancelled: true)
        guard case .found(let gone) = CalendarLessonMatching.resolve(anchor, mappings: [], snapshot: try snapshot([cancelled], days: ["2026-11-02", "2026-11-09"])) else {
            return XCTFail()
        }
        XCTAssertTrue(gone.isCancelled)
        // Gone under its id: unresolved, candidates only of the same course – never by title.
        let replacement = lesson("200", course: "7", date: "2026-11-04", hour: 8)
        let sameTitleOtherCourse = lesson("300", course: "9", date: "2026-11-03", hour: 8)
        let farAway = lesson("400", course: "7", date: "2026-11-20", hour: 8)
        let loaded = try snapshot([replacement, sameTitleOtherCourse, farAway], days: ["2026-11-02", "2026-11-23"])
        XCTAssertEqual(CalendarLessonMatching.resolve(anchor, mappings: [], snapshot: loaded), .unresolved(candidates: [replacement]))
        XCTAssertEqual(CalendarLessonMatching.resolve(anchor, mappings: [], snapshot: loaded, taken: ["200"]), .unresolved(candidates: []))
        // The user confirms the new lesson: the persisted mapping makes the note follow.
        let mapping = CalendarLessonMapping(source: "webuntis:abc", fromPeriodID: "100", fromDate: day("2026-11-03"), toPeriodID: "200", toDate: day("2026-11-04"))
        XCTAssertEqual(CalendarLessonMatching.resolve(anchor, mappings: [mapping], snapshot: loaded), .found(replacement))
        // Mappings of another account do not apply; cycles end.
        var foreign = mapping; foreign.source = "webuntis:other"
        XCTAssertEqual(CalendarLessonMatching.resolve(anchor, mappings: [foreign], snapshot: loaded), .unresolved(candidates: [replacement]))
        let back = CalendarLessonMapping(source: "webuntis:abc", fromPeriodID: "200", fromDate: day("2026-11-04"), toPeriodID: "100", toDate: day("2026-11-03"))
        XCTAssertEqual(CalendarLessonMatching.currentPeriod(anchor, mappings: [mapping, back]).period, "200")
        // Day not in the offline timetable: no statement, not „ungeklärt“.
        XCTAssertEqual(CalendarLessonMatching.resolve(anchor, mappings: [], snapshot: try snapshot([farAway], days: ["2026-11-16", "2026-11-23"])), .notLoaded)
        XCTAssertEqual(CalendarLessonMatching.resolve(anchor, mappings: [], snapshot: nil), .notLoaded)
        // Without a course id there are no candidates at all.
        var lonely = anchor; lonely.lessonID = nil
        XCTAssertEqual(CalendarLessonMatching.resolve(lonely, mappings: [], snapshot: loaded), .unresolved(candidates: []))
    }

    func testSourceIdentityIsStableAndSecretFree() throws {
        let setup = try WebUntisSetup(server: "https://example.webuntis.com/WebUntis", school: "Beispiel-Schule", user: "Max", key: "JBSWY3DPEHPK3PXP")
        let again = try WebUntisSetup(server: "example.webuntis.com", school: "beispiel-schule", user: "max", key: "GEZDGNBVGY3TQOJQ")
        XCTAssertEqual(WebUntis.sourceIdentity(setup), WebUntis.sourceIdentity(again), "Schlüssel gehört nicht zur Identität")
        XCTAssertFalse(WebUntis.sourceIdentity(setup).contains("Max"))
        XCTAssertFalse(WebUntis.sourceIdentity(setup).contains("JBSWY3DP"))
        let record = CalendarConnectionRecord(label: "Schule", connectedAt: Date(timeIntervalSince1970: 1_793_000_000))
        XCTAssertEqual(record.source, "connection:" + record.id.uuidString)
    }

    // MARK: Colours

    func testSubjectColoursAreStableAndAdjustable() {
        XCTAssertEqual(CalendarSubjectColor.key(subjectID: "12", name: "Mathematik"), "webuntis:12")
        XCTAssertEqual(CalendarSubjectColor.key(subjectID: nil, name: " Mathematik "), "name:mathematik")
        // Fixed values: the automatic colour must not change between builds.
        XCTAssertEqual(CalendarSubjectColor.name(for: "webuntis:12", chosen: [:]), CalendarSubjectColor.automatic[3])
        XCTAssertEqual(CalendarSubjectColor.name(for: "name:mathematik", chosen: [:]), CalendarSubjectColor.automatic[5])
        XCTAssertEqual(CalendarSubjectColor.name(for: "webuntis:12", chosen: ["webuntis:12": "indigo"]), "indigo")
        XCTAssertEqual(CalendarSubjectColor.name(for: "webuntis:12", chosen: ["webuntis:12": "unbekannt"]), CalendarSubjectColor.automatic[3])
        XCTAssertFalse(CalendarSubjectColor.choosable.contains(CalendarSubjectColor.personal))
        XCTAssertFalse(CalendarSubjectColor.choosable.contains("red"))
        XCTAssertFalse(CalendarSubjectColor.choosable.contains("blue"))
    }

    // MARK: Migration of B1 packages

    /// A calendar package exactly as Build 101 (format 1) wrote it.
    private func writeB1Package() throws -> (file: String, bytes: Data) {
        let package = root.appendingPathComponent("Calendar", isDirectory: true)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("Revisions"), withIntermediateDirectories: true)
        let json = #"{"connection":{"connectedAt":815000000,"id":"5C1A0B0E-1111-4222-8333-944455556666","kind":"webUntis","label":"Beispielschule","timeZone":"Europe\/Berlin"},"events":[{"createdAt":815000000,"details":"","id":"00000000-0000-4000-8000-000000000001","location":"Raum 1","modifiedAt":815000000,"timing":{"end":815005400,"kind":"timed","start":815000000,"timeZone":"Europe\/Berlin"},"title":"Elternabend"},{"createdAt":815000000,"details":"","id":"00000000-0000-4000-8000-000000000002","location":"","modifiedAt":815000000,"timing":{"endDate":"2026-11-07","kind":"allDay","startDate":"2026-11-05"},"title":"Klassenfahrt"}],"formatVersion":1,"settings":{"mode":"month","weekDays":7}}"#
        let bytes = Data(json.utf8)
        let file = UUID().uuidString + ".json"
        try bytes.write(to: package.appendingPathComponent("Revisions/\(file)"))
        let manifest = RevisionManifest(revisions: [RevisionRecord(file: file, byteCount: bytes.count, crc32: SnapshotChecksum.crc32(bytes), savedAtUnix: 1_793_000_000)])
        try JSONEncoder().encode(manifest).write(to: package.appendingPathComponent("manifest.json"))
        return (file, bytes)
    }

    func testB1PackageMigratesWithOldBytesArchivedFirst() async throws {
        let (file, bytes) = try writeB1Package()
        let package = root.appendingPathComponent("Calendar", isDirectory: true)
        let repository = CalendarRepository(areaRoot: root)
        let loaded = try await repository.load()
        XCTAssertEqual(loaded.state.formatVersion, CalendarState.currentFormat)
        XCTAssertEqual(loaded.state.events.map(\.title), ["Elternabend", "Klassenfahrt"])
        XCTAssertEqual(loaded.state.settings.weekDays, 7)
        XCTAssertEqual(loaded.state.settings.mode, "month")
        XCTAssertEqual(loaded.state.connection?.label, "Beispielschule")
        XCTAssertNil(loaded.state.connection?.sourceIdentity)
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.appendingPathComponent("Migration").path), "Lesen schreibt nichts")

        // A failed archive refuses the commit: nothing of format 2 is written.
        await repository.setFault { if $0 == .migrationArchive { throw Injected() } }
        var next = loaded.state
        next.settings.subjectColors = ["name:mathematik": "mint"]
        do { try await repository.save(next, revision: 1); XCTFail("Fehler erwartet") } catch {}
        let manifestAfterFailure = try Data(contentsOf: package.appendingPathComponent("manifest.json"))
        XCTAssertEqual(try JSONDecoder().decode(RevisionManifest.self, from: manifestAfterFailure).revisions.map(\.file), [file])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: package.appendingPathComponent("Revisions").path), [file])

        await repository.setFault { _ in }
        try await repository.save(next, revision: 2)
        let archived = try Data(contentsOf: package.appendingPathComponent("Migration/format-1-\(file)"))
        XCTAssertEqual(archived, bytes, "exakte Altbytes")
        await repository.close()
        let reopened = try await CalendarRepository(areaRoot: root).load()
        XCTAssertEqual(reopened.state, next)
        let manifest = try JSONDecoder().decode(RevisionManifest.self, from: Data(contentsOf: package.appendingPathComponent("manifest.json")))
        let newest = try Data(contentsOf: package.appendingPathComponent("Revisions/\(manifest.revisions[0].file)"))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: newest) as? [String: Any])?["formatVersion"] as? Int, CalendarState.currentFormat)
        // The old revision stays the fallback of the new manifest.
        XCTAssertEqual(manifest.revisions.map(\.file).last, file)
    }

    func testFormat1WithFormat2FieldsIsRejected() throws {
        let bytes = Data(#"{"events":[],"formatVersion":1,"noteLinks":[{"x":1}],"settings":{"mode":"week","weekDays":5}}"#.utf8)
        XCTAssertThrowsError(try CalendarStore.decode(bytes))
        let newer = Data(#"{"events":[],"formatVersion":4}"#.utf8)
        XCTAssertThrowsError(try CalendarStore.decode(newer)) { XCTAssertEqual($0 as? CalendarStoreError, .unsupportedFormat(4)) }
    }
}

private extension CalendarEventTiming {
    func shiftedMinutes(_ minutes: Int) -> CalendarEventTiming {
        guard case .timed(let start, let end, let zone) = self else { return self }
        return .timed(start: start.addingTimeInterval(Double(minutes) * 60), end: end.addingTimeInterval(Double(minutes) * 60), timeZone: zone)
    }
}
