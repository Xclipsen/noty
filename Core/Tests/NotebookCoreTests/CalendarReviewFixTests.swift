import XCTest
@testable import NotebookCore

/// Kalender review fixes after B3: moving a whole series moves its single
/// changed occurrences (days and wall clock, daylight saving), „Rückgängig“
/// restores an event together with its note links, the serial mutation
/// queue and the repository's save order under claim contention.
/// Fictitious data only.
final class CalendarReviewFixTests: XCTestCase {
    private var root: URL!
    private let zone = "Europe/Berlin"
    private var berlin: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: zone)!; return c }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-review-\(UUID().uuidString)", isDirectory: true)
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
    private func wall(_ date: Date) -> String {
        let c = berlin.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!)
    }
    private func wall(_ timing: CalendarEventTiming) -> String {
        guard case .timed(let start, let end, _) = timing else { return "\(timing)" }
        return "\(wall(start))–\(wall(end))"
    }
    private func series(_ timing: CalendarEventTiming, _ rule: CalendarRecurrence) -> LocalCalendarEvent {
        LocalCalendarEvent(title: "Lerngruppe", timing: timing, recurrence: rule, createdAt: Date(timeIntervalSince1970: 1_790_000_000))
    }
    private func link(_ target: CalendarNoteTarget) -> CalendarNoteLink {
        CalendarNoteLink(target: target, documentID: UUID(), pageID: UUID(), createdAt: Date(timeIntervalSince1970: 1_793_000_000),
                         contextTitle: "Lerngruppe", contextStart: at(2026, 11, 4, 8), contextEnd: at(2026, 11, 4, 9, 30))
    }

    // MARK: Finding 5: whole-series moves include changed occurrences

    func testMovingTheWholeSeriesMovesAChangedOccurrenceWithIt() {
        // Weekly on Monday 08:00; the occurrence of 9 Nov was moved to Tuesday 14:00.
        let base = timed(2026, 11, 2, 8)
        let rule = CalendarRecurrence(frequency: .weekly, overrides: [
            CalendarOccurrenceOverride(originalDate: day("2026-11-09"), title: "Verlegt", timing: timed(2026, 11, 10, 14))])
        // „Alle“ one week later.
        let next = timed(2026, 11, 9, 8)
        let moved = CalendarSeries.moved(rule, from: base, to: next)
        XCTAssertEqual(moved.overrides.map(\.originalDate), [day("2026-11-16")])
        XCTAssertEqual(wall(moved.overrides[0].timing), "2026-11-17 14:00–2026-11-17 15:30")
        // Shown once, at its new place, never at the old time under the new identity.
        let event = series(next, moved)
        let shown = CalendarSeries.expand([event], from: day("2026-11-09"), to: day("2026-11-23")).occurrences
        let changed = shown.filter(\.isOverride)
        XCTAssertEqual(changed.count, 1)
        XCTAssertEqual(changed.first?.originalDate, day("2026-11-16"))
        XCTAssertEqual(changed.first.map { wall($0.timing) }, "2026-11-17 14:00–2026-11-17 15:30")
        XCTAssertFalse(shown.contains { wall($0.timing).hasPrefix("2026-11-10 14:00") })

        // A time change of the whole series (08:00 → 09:30, ten minutes longer) moves it the same way.
        let later = CalendarSeries.moved(rule, from: base, to: timed(2026, 11, 2, 9, 30, minutes: 100))
        XCTAssertEqual(later.overrides[0].originalDate, day("2026-11-09"))
        XCTAssertEqual(wall(later.overrides[0].timing), "2026-11-10 15:30–2026-11-10 17:10")
    }

    func testSeriesMoveKeepsWallClockAcrossDaylightSaving() {
        // Summer time ends on 25 Oct 2026. Occurrence of 19 Oct changed to 14:00 (CEST).
        let base = timed(2026, 10, 12, 8)
        let rule = CalendarRecurrence(frequency: .weekly, overrides: [
            CalendarOccurrenceOverride(originalDate: day("2026-10-19"), title: "Verlegt", timing: timed(2026, 10, 19, 14))])
        let moved = CalendarSeries.moved(rule, from: base, to: timed(2026, 10, 19, 8))
        XCTAssertEqual(moved.overrides[0].originalDate, day("2026-10-26"))
        // Still 14:00 on the wall clock (CET), i.e. 7 days and one hour later in absolute time.
        XCTAssertEqual(wall(moved.overrides[0].timing), "2026-10-26 14:00–2026-10-26 15:30")
        guard case .timed(let oldStart, _, _) = rule.overrides[0].timing, case .timed(let newStart, _, _) = moved.overrides[0].timing else {
            return XCTFail("zeitgebunden erwartet")
        }
        XCTAssertEqual(newStart.timeIntervalSince(oldStart), 7 * 86_400 + 3_600)
    }

    func testAllDayAndKindChangesMoveByDaysOnly() {
        let base = CalendarEventTiming.allDay(start: day("2026-11-02"), end: day("2026-11-03"))
        let rule = CalendarRecurrence(frequency: .weekly, exceptions: [day("2026-11-16")], overrides: [
            CalendarOccurrenceOverride(originalDate: day("2026-11-09"), title: "Zwei Tage",
                                       timing: .allDay(start: day("2026-11-10"), end: day("2026-11-12")))])
        let moved = CalendarSeries.moved(rule, from: base, to: .allDay(start: day("2026-11-04"), end: day("2026-11-05")))
        XCTAssertEqual(moved.exceptions, [day("2026-11-18")])
        XCTAssertEqual(moved.overrides[0].originalDate, day("2026-11-11"))
        XCTAssertEqual(moved.overrides[0].timing, .allDay(start: day("2026-11-12"), end: day("2026-11-14")))
        // All-day series becomes timed on the next day: the changed occurrence keeps its own kind, one day later.
        let timedRule = CalendarRecurrence(frequency: .weekly, overrides: [
            CalendarOccurrenceOverride(originalDate: day("2026-11-09"), title: "Später", timing: timed(2026, 11, 9, 14))])
        let kind = CalendarSeries.moved(timedRule, from: base, to: timed(2026, 11, 3, 8))
        XCTAssertEqual(kind.overrides[0].originalDate, day("2026-11-10"))
        XCTAssertEqual(wall(kind.overrides[0].timing), "2026-11-10 14:00–2026-11-10 15:30")
        // Nothing moved: unchanged.
        XCTAssertEqual(CalendarSeries.moved(timedRule, from: timed(2026, 11, 2, 8), to: timed(2026, 11, 2, 8)), timedRule)
    }

    func testMovedSeriesStaysValid() throws {
        var state = CalendarState()
        let base = timed(2026, 11, 2, 8)
        let rule = CalendarRecurrence(frequency: .weekly, end: .until(day("2026-12-21")), exceptions: [day("2026-11-23")], overrides: [
            CalendarOccurrenceOverride(originalDate: day("2026-11-09"), title: "Verlegt", timing: timed(2026, 11, 10, 23, minutes: 30))])
        let next = timed(2026, 11, 3, 7, 30, minutes: 120)
        state.events = [series(next, CalendarSeries.moved(rule, from: base, to: next))]
        XCTAssertNoThrow(try state.validate())
        // Start like the series' start (one day, 30 minutes earlier), end like its end (one day later).
        XCTAssertEqual(wall(state.events[0].recurrence!.overrides[0].timing), "2026-11-11 22:30–2026-11-11 23:30")
    }

    // MARK: Finding 2: undo restores the event and its note links together

    func testUndoOfAMovedDailySeriesBringsItsNotesBack() {
        var state = CalendarState()
        let event = series(timed(2026, 11, 2, 8), CalendarRecurrence(frequency: .daily))
        let note = link(.local(event: event.id, date: day("2026-11-04")))
        let other = link(.local(event: UUID(), date: day("2026-11-04")))
        state.events = [event]
        state.noteLinks = [note, other]
        let undo = CalendarUndoSnapshot(capturing: state, event: event.id)
        XCTAssertEqual(undo.linkTargets.count, 1)

        // „Alle“ one day later: the note follows its occurrence to 5 Nov.
        var moved = event
        moved.timing = timed(2026, 11, 3, 8)
        moved.recurrence = CalendarSeries.moved(event.recurrence!, from: event.timing, to: moved.timing)
        state.events = [moved]
        CalendarNoteLinks.retarget(&state.noteLinks, event: event.id, old: event, new: moved)
        XCTAssertEqual(state.noteLinks[0].target, .local(event: event.id, date: day("2026-11-05")))
        // Meanwhile a new note on another occurrence.
        let newer = link(.local(event: event.id, date: day("2026-11-07")))
        state.noteLinks.append(newer)

        undo.restore(in: &state)
        XCTAssertEqual(state.events, [event])
        XCTAssertEqual(state.noteLinks.first { $0.id == note.id }?.target, .local(event: event.id, date: day("2026-11-04")))
        XCTAssertEqual(state.noteLinks.first { $0.id == other.id }, other)
        XCTAssertEqual(state.noteLinks.first { $0.id == newer.id }, newer)
        XCTAssertNoThrow(try state.validate())
    }

    func testUndoOfAMovedWeeklySeriesKeepsTheNoteOnAGeneratedOccurrence() {
        var state = CalendarState()
        let event = series(timed(2026, 11, 2, 8), CalendarRecurrence(frequency: .weekly))
        let note = link(.local(event: event.id, date: day("2026-11-09")))
        state.events = [event]
        state.noteLinks = [note]
        let undo = CalendarUndoSnapshot(capturing: state, event: event.id)
        var moved = event
        moved.timing = timed(2026, 11, 3, 8)
        moved.recurrence = CalendarSeries.moved(event.recurrence!, from: event.timing, to: moved.timing)
        state.events = [moved]
        CalendarNoteLinks.retarget(&state.noteLinks, event: event.id, old: event, new: moved)
        undo.restore(in: &state)
        guard case .local(_, let date?) = state.noteLinks[0].target else { return XCTFail("Durchführung erwartet") }
        // The restored series generates the note's occurrence again (it would vanish otherwise).
        XCTAssertTrue(CalendarSeries.generates(date, timing: state.events[0].timing, rule: state.events[0].recurrence!))
        XCTAssertEqual(date, day("2026-11-09"))
    }

    func testUndoOfADeletionRemovesTheTrashEntryAndNeverDeletesLinks() {
        var state = CalendarState()
        let event = series(timed(2026, 11, 2, 8), CalendarRecurrence(frequency: .weekly))
        let note = link(.local(event: event.id, date: day("2026-11-09")))
        state.events = [event]
        state.noteLinks = [note]
        let trash = CalendarDeletedEvent(event: event)
        let undo = CalendarUndoSnapshot(capturing: state, event: event.id, trashID: trash.id)
        state.events = []
        state.deletedEvents = [trash]
        XCTAssertNoThrow(try state.validate())
        // The user removes the link meanwhile: undo does not invent it again.
        state.noteLinks = []
        undo.restore(in: &state)
        XCTAssertEqual(state.events, [event])
        XCTAssertTrue(state.deletedEvents.isEmpty)
        XCTAssertTrue(state.noteLinks.isEmpty)
        XCTAssertNoThrow(try state.validate())

        // Undo of a new event removes it again.
        var empty = CalendarState()
        let created = series(timed(2026, 11, 2, 8), CalendarRecurrence(frequency: .daily))
        let creation = CalendarUndoSnapshot(capturing: empty, event: created.id)
        empty.events = [created]
        creation.restore(in: &empty)
        XCTAssertTrue(empty.events.isEmpty)
    }

    // MARK: Finding 4: one serial order of calendar mutations

    @MainActor private final class Log {
        var state: [String] = []
        var inside = 0
        var overlap = false
    }

    @MainActor
    func testMutationQueueRunsChangesOneAfterAnotherOnTheNewestState() async {
        let queue = CalendarMutationQueue()
        let log = Log()
        // A connection change and link commits started together (the review case):
        // each reads the newest state, writes for a while, then replaces it.
        let names = ["Verbindung", "Link", "Trennen"]
        var tasks: [Task<Void, Never>] = []
        for index in names.indices {
            let name = names[index]
            let pause: UInt64 = index == 0 ? 50_000_000 : 1_000_000
            tasks.append(Task { @MainActor in
                await queue.acquire()
                log.inside += 1
                if log.inside > 1 { log.overlap = true }
                let base = log.state
                try? await Task.sleep(nanoseconds: pause)
                log.state = base + [name]
                log.inside -= 1
                queue.release()
            })
        }
        for task in tasks { await task.value }
        XCTAssertFalse(log.overlap)
        XCTAssertEqual(log.state.sorted(), ["Link", "Trennen", "Verbindung"])
        XCTAssertFalse(queue.isBusy)
        // Uncontended: acquired at once.
        await queue.acquire()
        XCTAssertTrue(queue.isBusy)
        queue.release()
        XCTAssertFalse(queue.isBusy)
    }

    // MARK: Finding 6: save order rechecked after waiting for the claim

    private func titled(_ title: String) -> CalendarState {
        var state = CalendarState()
        state.events = [LocalCalendarEvent(id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, title: title,
                                           timing: timed(2026, 11, 4, 8), createdAt: Date(timeIntervalSince1970: 1_792_000_000))]
        return state
    }

    func testOlderSaveWaitingForTheClaimNeverReplacesANewerOne() async throws {
        for round in 0..<6 {
            let area = root.appendingPathComponent("area-\(round)", isDirectory: true)
            let package = area.appendingPathComponent("Calendar", isDirectory: true)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            // Another writer holds the package while both saves arrive.
            let other = try XCTUnwrap(PackageWriteLock.shared.claim(package))
            let repository = CalendarRepository(areaRoot: area, claimWait: 5)
            let older = titled("alt"), newer = titled("neu")
            async let a = repository.save(round.isMultiple(of: 2) ? older : newer, revision: round.isMultiple(of: 2) ? 1 : 2)
            async let b = repository.save(round.isMultiple(of: 2) ? newer : older, revision: round.isMultiple(of: 2) ? 2 : 1)
            try await Task.sleep(nanoseconds: 150_000_000)
            other.release()
            // Both share one claim (no second claim attempt that times out as „busy“).
            let results = try await [a, b]
            XCTAssertTrue(results.contains(true))
            await repository.close()
            let loaded = try await CalendarRepository(areaRoot: area).load()
            XCTAssertEqual(loaded.state.events.map(\.title), ["neu"], "Runde \(round)")
        }
    }

    func testClaimArrivingAfterCloseIsLetGo() async throws {
        let package = root.appendingPathComponent("Calendar", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let other = try XCTUnwrap(PackageWriteLock.shared.claim(package))
        let repository = CalendarRepository(areaRoot: root, claimWait: 5)
        let state = titled("alt")
        let waiting = Task { try await repository.save(state, revision: 1) }
        try await Task.sleep(nanoseconds: 100_000_000)
        await repository.close()
        other.release()
        do { _ = try await waiting.value; XCTFail("belegt erwartet") }
        catch { XCTAssertEqual(error as? CalendarStoreError, .busy) }
        XCTAssertFalse(PackageWriteLock.shared.isHeld(package))
    }
}
