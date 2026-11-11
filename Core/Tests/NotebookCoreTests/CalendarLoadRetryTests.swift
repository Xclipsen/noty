import XCTest
@testable import NotebookCore

/// Loading the calendar package while its write claim is still held by an
/// earlier owner (area switch A → B → A): that passes by itself and must
/// not lock the calendar; unreadable and newer packages stay locked at once.
/// Fictitious data only.
final class CalendarLoadRetryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private var package: URL { root.appendingPathComponent("Calendar", isDirectory: true) }

    private func state(_ title: String) -> CalendarState {
        var state = CalendarState()
        state.events = [LocalCalendarEvent(title: title, timing: .allDay(start: CivilDate("2026-11-04")!, end: CivilDate("2026-11-05")!))]
        return state
    }

    /// An owner that committed one event and still holds the write claim.
    private func holder() async throws -> CalendarRepository {
        let first = CalendarRepository(areaRoot: root)
        _ = try await first.load()
        try await first.save(state("Zahnarzt (fiktiv)"), revision: 1)
        return first
    }

    func testLoadSucceedsOnceTheEarlierOwnerLetsGo() async throws {
        let first = try await holder()
        let second = CalendarRepository(areaRoot: root, claimWait: 0)
        let loading = Task { try await second.load(retryingBusyAfter: [0.05, 0.05, 0.05, 0.05, 5]) }
        try await Task.sleep(nanoseconds: 120_000_000)
        await first.close()
        let loaded = try await loading.value
        // The committed state, never an empty one.
        XCTAssertEqual(loaded.state.events.map(\.title), ["Zahnarzt (fiktiv)"])
        // The claim is the new owner's now: it commits.
        try await second.save(state("Projekttag"), revision: 1)
        await second.close()
        let reopened = CalendarRepository(areaRoot: root, claimWait: 0)
        let again = try await reopened.load()
        XCTAssertEqual(again.state.events.map(\.title), ["Projekttag"])
        await reopened.close()
    }

    func testLoadReportsBusyAfterTheLastDelayAndCanBeAskedAgain() async throws {
        let first = try await holder()
        let second = CalendarRepository(areaRoot: root, claimWait: 0)
        do { _ = try await second.load(retryingBusyAfter: [0.01, 0.01]); XCTFail("belegt erwartet") }
        catch { XCTAssertEqual(error as? CalendarStoreError, .busy) }
        // Without delays: one attempt, as `load()`.
        do { _ = try await second.load(retryingBusyAfter: []); XCTFail("belegt erwartet") }
        catch { XCTAssertEqual(error as? CalendarStoreError, .busy) }
        await first.close()
        let loaded = try await second.load(retryingBusyAfter: [])
        XCTAssertEqual(loaded.state.events.map(\.title), ["Zahnarzt (fiktiv)"])
        await second.close()
    }

    func testNewerFormatIsThrownAtOnceAndStaysLocked() async throws {
        let first = try await holder()
        await first.close()
        try Data(#"{"formatVersion":9,"revisions":[]}"#.utf8).write(to: package.appendingPathComponent("manifest.json"))
        let locked = CalendarRepository(areaRoot: root, claimWait: 0)
        let started = Date()
        do { _ = try await locked.load(retryingBusyAfter: [30, 30]); XCTFail("gesperrt erwartet") }
        catch { XCTAssertEqual(error as? CalendarStoreError, .unsupportedFormat(9)) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        do { try await locked.save(state("B"), revision: 1); XCTFail("gesperrt erwartet") }
        catch { XCTAssertEqual(error as? CalendarStoreError, .unsupportedFormat(9)) }
        await locked.close()
    }

    func testClosingEndsTheAttemptsWithoutTakingTheClaim() async throws {
        let first = try await holder()
        let second = CalendarRepository(areaRoot: root, claimWait: 0)
        let started = Date()
        let loading = Task { try await second.load(retryingBusyAfter: [0.2, 30]) }
        try await Task.sleep(nanoseconds: 50_000_000)
        // The owner of `second` gave it up (area switch while it was still waiting).
        await second.close()
        await first.close()
        do { _ = try await loading.value; XCTFail("belegt erwartet") }
        catch { XCTAssertEqual(error as? CalendarStoreError, .busy) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        XCTAssertFalse(PackageWriteLock.shared.isHeld(package))
    }

    func testModelDelaysCoverARunningTimetableRequest() {
        // A WebUntis request of the earlier owner ends after 60 s at the latest.
        XCTAssertGreaterThanOrEqual(CalendarRepository.busyRetryDelays.reduce(0, +), 60)
        XCTAssertTrue(CalendarRepository.busyRetryDelays.allSatisfy { $0 > 0 && $0 <= 30 })
    }
}
