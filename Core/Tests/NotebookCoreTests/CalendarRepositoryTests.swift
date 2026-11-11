import XCTest
@testable import NotebookCore

/// Kalender Stufe B1: confirmed calendar state in `<Bereich>/Calendar/`
/// (revisions, manifest last, recovery, locks) and its source cache.
/// Fictitious data only.
final class CalendarRepositoryTests: XCTestCase {
    private var root: URL!
    private let berlin: Calendar = { var c = CalendarDates.german(timeZone: TimeZone(identifier: "Europe/Berlin")!); c.locale = nil; return c }()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private var package: URL { root.appendingPathComponent("Calendar", isDirectory: true) }
    private var revisionFiles: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: package.appendingPathComponent("Revisions").path)) ?? []).sorted()
    }
    private func day(_ text: String) -> CivilDate { CivilDate(text)! }

    private func state(_ titles: [String], connection: CalendarConnectionRecord? = nil) -> CalendarState {
        var state = CalendarState()
        state.events = titles.enumerated().map { index, title in
            LocalCalendarEvent(id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index + 1))!, title: title,
                               location: "Raum \(index)", timing: .timed(start: Date(timeIntervalSince1970: 1_793_000_000 + Double(index) * 3600),
                                                                     end: Date(timeIntervalSince1970: 1_793_001_800 + Double(index) * 3600),
                                                                     timeZone: "Europe/Berlin"),
                               createdAt: Date(timeIntervalSince1970: 1_792_000_000))
        }
        state.connection = connection
        return state
    }

    private func snapshotOfFiles() throws -> [String: Data] {
        var result: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(at: package, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            if (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
                result[url.path.replacingOccurrences(of: package.path, with: "")] = try Data(contentsOf: url)
            }
        }
        return result
    }

    // MARK: Model

    func testCivilDatesAndAllDayIntervalsAcrossDaylightSaving() throws {
        XCTAssertNil(CivilDate("2026-02-29"))
        XCTAssertNotNil(CivilDate("2028-02-29"))
        XCTAssertNil(CivilDate("2026-13-01"))
        XCTAssertNil(CivilDate("26-11-04"))
        XCTAssertEqual(day("2026-12-31").adding(days: 1), day("2027-01-01"))
        XCTAssertEqual(day("2028-02-28").adding(days: 1), day("2028-02-29"))
        XCTAssertEqual(day("2026-03-01").days(to: day("2026-04-01")), 31)
        // All-day on the spring-forward Sunday: 23 hours, still exactly one day.
        let spring = CalendarEventTiming.allDay(start: day("2026-03-29"), end: day("2026-03-30")).interval(in: berlin)
        XCTAssertEqual(spring.end.timeIntervalSince(spring.start), 23 * 3600)
        let autumn = CalendarEventTiming.allDay(start: day("2026-10-25"), end: day("2026-10-26")).interval(in: berlin)
        XCTAssertEqual(autumn.end.timeIntervalSince(autumn.start), 25 * 3600)
        // Civil dates do not move with the viewer's time zone.
        var tokyo = Calendar(identifier: .gregorian); tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertEqual(CivilDate(day("2026-11-04").start(in: tokyo), calendar: tokyo), day("2026-11-04"))
        let json = try JSONEncoder().encode(day("2026-11-04"))
        XCTAssertEqual(String(decoding: json, as: UTF8.self), "\"2026-11-04\"")
    }

    func testTimingValidation() {
        XCTAssertNotNil(CalendarEventTiming.allDay(start: day("2026-11-04"), end: day("2026-11-04")).problem)
        XCTAssertNil(CalendarEventTiming.allDay(start: day("2026-11-04"), end: day("2026-11-05")).problem)
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        XCTAssertNotNil(CalendarEventTiming.timed(start: now, end: now, timeZone: "Europe/Berlin").problem)
        XCTAssertNotNil(CalendarEventTiming.timed(start: now, end: now + 60, timeZone: "Mars/Olympus").problem)
        XCTAssertNil(CalendarEventTiming.timed(start: now, end: now + 60, timeZone: "Europe/Berlin").problem)
        var invalid = state(["A"])
        invalid.events[0].title = "  "
        XCTAssertThrowsError(try invalid.validate())
        var duplicate = state(["A", "B"])
        duplicate.events[1] = LocalCalendarEvent(id: duplicate.events[0].id, title: "B", timing: duplicate.events[1].timing)
        XCTAssertThrowsError(try duplicate.validate())
    }

    // MARK: Commit and reload

    func testMissingPackageIsEmptyAndCommitsRoundTrip() async throws {
        let repository = CalendarRepository(areaRoot: root)
        let empty = try await repository.load()
        XCTAssertEqual(empty.state, CalendarState())
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.path)) // opening writes nothing
        var next = state(["Zahnarzt (fiktiv)"])
        next.events.append(LocalCalendarEvent(title: "Projekttag", timing: .allDay(start: day("2026-11-04"), end: day("2026-11-06"))))
        next.settings.weekDays = 7
        next.settings.mode = CalendarMode.month.rawValue
        try await repository.save(next, revision: 1)
        await repository.close()

        let reopened = CalendarRepository(areaRoot: root)
        let loaded = try await reopened.load()
        XCTAssertEqual(loaded.state, next)
        XCTAssertFalse(loaded.recovered)
        // Three newest revisions in the manifest plus those of the previous
        // manifest (four files); older acknowledged ones are dropped.
        for index in 2...6 { try await reopened.save(state((0..<index).map { "T\($0)" }), revision: index) }
        XCTAssertEqual(revisionFiles.count, 4)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: package.appendingPathComponent("manifest.json"))) as? [String: Any]
        XCTAssertEqual(manifest?["formatVersion"] as? Int, 1)
        XCTAssertEqual((manifest?["revisions"] as? [Any])?.count, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.appendingPathComponent("manifest-previous.json").path))
    }

    func testOlderSaveNeverReplacesNewer() async throws {
        let repository = CalendarRepository(areaRoot: root)
        _ = try await repository.load()
        let newer = state(["neu"]), older = state(["alt"])
        let committedNewer = try await repository.save(newer, revision: 5)
        let committedOlder = try await repository.save(older, revision: 4)
        XCTAssertTrue(committedNewer)
        XCTAssertFalse(committedOlder)
        await repository.close()
        let loaded = try await CalendarRepository(areaRoot: root).load()
        XCTAssertEqual(loaded.state, newer)
    }

    func testWriteFailureKeepsCommittedStateAndLeavesNoRevision() async throws {
        let repository = CalendarRepository(areaRoot: root)
        _ = try await repository.load()
        let good = state(["bestätigt"])
        try await repository.save(good, revision: 1)
        let before = try snapshotOfFiles()
        struct Injected: Error {}
        for stage in [CalendarStore.CommitStage.revisionWritten, .previousWritten] {
            await repository.setFault { if $0 == stage { throw Injected() } }
            do {
                try await repository.save(state(["nie gespeichert"]), revision: 2)
                XCTFail("Fehler erwartet")
            } catch is Injected {}
            XCTAssertEqual(revisionFiles.count, 1, "\(stage)")
        }
        await repository.setFault { _ in }
        // manifest.json unchanged: the commit point was never reached.
        XCTAssertEqual(try snapshotOfFiles()["/manifest.json"], before["/manifest.json"])
        await repository.close()
        let reloaded = try await CalendarRepository(areaRoot: root).load()
        XCTAssertEqual(reloaded.state, good)
        // The retry after the failure succeeds.
        let retry = CalendarRepository(areaRoot: root)
        _ = try await retry.load()
        try await retry.save(state(["zweiter Versuch"]), revision: 3)
        await retry.close()
        let final = try await CalendarRepository(areaRoot: root).load()
        XCTAssertEqual(final.state.events.map(\.title), ["zweiter Versuch"])
    }

    func testUnknownNewerFormatLocksWithoutTouchingFiles() async throws {
        let repository = CalendarRepository(areaRoot: root)
        _ = try await repository.load()
        try await repository.save(state(["A"]), revision: 1)
        await repository.close()
        // A newer noty wrote format 2 into the newest revision (same file, new bytes + record).
        let manifestURL = package.appendingPathComponent("manifest.json")
        var manifest = try JSONDecoder().decode(RevisionManifest.self, from: Data(contentsOf: manifestURL))
        let futureBytes = Data(#"{"formatVersion":7,"events":[],"unknownField":true}"#.utf8)
        let futureFile = UUID().uuidString + ".json"
        try futureBytes.write(to: package.appendingPathComponent("Revisions/\(futureFile)"))
        manifest.revisions.insert(RevisionRecord(file: futureFile, byteCount: futureBytes.count, crc32: SnapshotChecksum.crc32(futureBytes)), at: 0)
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        let before = try snapshotOfFiles()

        let locked = CalendarRepository(areaRoot: root)
        do { _ = try await locked.load(); XCTFail("gesperrt erwartet") }
        catch { XCTAssertEqual(error as? CalendarStoreError, .unsupportedFormat(7)) }
        do { try await locked.save(state(["B"]), revision: 1); XCTFail("gesperrt erwartet") }
        catch { XCTAssertEqual(error as? CalendarStoreError, .unsupportedFormat(7)) }
        XCTAssertEqual(try snapshotOfFiles(), before)

        // A newer manifest format locks as well.
        try Data(#"{"formatVersion":9,"revisions":[]}"#.utf8).write(to: manifestURL)
        let locked2 = CalendarRepository(areaRoot: root, claimWait: 0)
        await locked.close()
        do { _ = try await locked2.load(); XCTFail("gesperrt erwartet") }
        catch { XCTAssertEqual(error as? CalendarStoreError, .unsupportedFormat(9)) }
    }

    func testCorruptNewestRevisionFallsBackAndKeepsTheDamagedFile() async throws {
        let repository = CalendarRepository(areaRoot: root)
        _ = try await repository.load()
        try await repository.save(state(["eins"]), revision: 1)
        try await repository.save(state(["zwei"]), revision: 2)
        await repository.close()
        let manifest = try JSONDecoder().decode(RevisionManifest.self, from: Data(contentsOf: package.appendingPathComponent("manifest.json")))
        let newest = package.appendingPathComponent("Revisions/\(manifest.revisions[0].file)")
        var bytes = try Data(contentsOf: newest)
        bytes[bytes.count / 2] ^= 0x20
        try bytes.write(to: newest)

        let recovered = CalendarRepository(areaRoot: root)
        let loaded = try await recovered.load()
        XCTAssertTrue(loaded.recovered)
        XCTAssertEqual(loaded.state.events.map(\.title), ["eins"])
        try await recovered.save(state(["drei"]), revision: 1)
        // The skipped (possibly newer) file is never deleted.
        XCTAssertTrue(FileManager.default.fileExists(atPath: newest.path))
        await recovered.close()
        let final = try await CalendarRepository(areaRoot: root).load()
        XCTAssertEqual(final.state.events.map(\.title), ["drei"])
        XCTAssertFalse(final.recovered)
    }

    func testDamagedManifestUsesPreviousAndIsQuarantinedOnCommit() async throws {
        let repository = CalendarRepository(areaRoot: root)
        _ = try await repository.load()
        try await repository.save(state(["eins"]), revision: 1)
        try await repository.save(state(["zwei"]), revision: 2)
        await repository.close()
        try Data("{kaputt".utf8).write(to: package.appendingPathComponent("manifest.json"))
        let recovered = CalendarRepository(areaRoot: root)
        let loaded = try await recovered.load()
        XCTAssertTrue(loaded.recovered)
        XCTAssertEqual(loaded.state.events.map(\.title), ["eins"])
        try await recovered.save(state(["drei"]), revision: 1)
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: package.appendingPathComponent("Quarantine").path)
        XCTAssertEqual(quarantined.count, 1)
        await recovered.close()
        let final = try await CalendarRepository(areaRoot: root).load()
        XCTAssertEqual(final.state.events.map(\.title), ["drei"])
    }

    func testPackageWithoutReadableRevisionLocksInsteadOfStartingEmpty() async throws {
        let repository = CalendarRepository(areaRoot: root)
        _ = try await repository.load()
        try await repository.save(state(["A"]), revision: 1)
        await repository.close()
        for file in revisionFiles { try FileManager.default.removeItem(at: package.appendingPathComponent("Revisions/\(file)")) }
        let broken = CalendarRepository(areaRoot: root)
        do { _ = try await broken.load(); XCTFail("gesperrt erwartet") }
        catch { XCTAssertEqual(error as? CalendarStoreError, .noCompleteRevision) }
        do { try await broken.save(CalendarState(), revision: 9); XCTFail("gesperrt erwartet") }
        catch { XCTAssertEqual(error as? CalendarStoreError, .noCompleteRevision) }
        XCTAssertTrue(revisionFiles.isEmpty)
    }

    func testSecondWriterIsRefused() async throws {
        let first = CalendarRepository(areaRoot: root)
        _ = try await first.load()
        let second = CalendarRepository(areaRoot: root, claimWait: 0)
        do { _ = try await second.load(); XCTFail("belegt erwartet") }
        catch { XCTAssertEqual(error as? CalendarStoreError, .busy) }
        await first.close()
        _ = try await second.load()
        await second.close()

        // Outside the process lock (another process): the changed manifest is detected.
        let a = CalendarStore(directory: package), b = CalendarStore(directory: package)
        _ = try a.load(); _ = try b.load()
        try b.save(state(["B"]))
        XCTAssertThrowsError(try a.save(state(["A"]))) { XCTAssertEqual($0 as? CalendarStoreError, .concurrentChange) }
        XCTAssertEqual(try CalendarStore(directory: package).load().events.map(\.title), ["B"])
    }

    // MARK: Source cache

    private func lesson(_ id: String, _ date: String, connection: UUID) -> CalendarLesson {
        let start = day(date).start(in: berlin).addingTimeInterval(8 * 3600)
        return CalendarLesson(key: CalendarOccurrenceKey(provider: "webuntis", connection: connection, sourceID: id, seriesID: "7",
                                                         originalStart: "\(date)T08:00"), date: day(date), start: start, end: start + 5400)
    }

    func testSourceCacheIsSeparateReplaceableAndBoundToTheConnection() async throws {
        let record = CalendarConnectionRecord(label: "Demo Schule", connectedAt: Date(timeIntervalSince1970: 1_792_000_000))
        let repository = CalendarRepository(areaRoot: root)
        _ = try await repository.load()
        // Without a committed connection a fetch is discarded.
        let fetch = CalendarTimetableFetch(connection: record.id, start: day("2026-11-02"), end: day("2026-11-07"),
                                           fetchedAt: Date(timeIntervalSince1970: 1_793_000_000),
                                           lessons: [lesson("1", "2026-11-02", connection: record.id)])
        do { _ = try await repository.merge(fetch); XCTFail("verworfen erwartet") }
        catch { XCTAssertEqual(error as? CalendarStoreError, .staleConnection) }
        try await repository.save(state(["eigener Termin"], connection: record), revision: 1)
        let merged = try await repository.merge(fetch)
        XCTAssertEqual(merged.lessons(on: day("2026-11-02"))?.count, 1)
        _ = try await repository.replaceHolidays([CalendarHoliday(id: "1", name: "Ferien (fiktiv)", start: day("2026-12-21"), end: day("2027-01-05"))],
                                                 fetchedAt: Date(timeIntervalSince1970: 1_793_000_000), connection: record.id)
        await repository.close()

        // Persisted beside, not inside, the confirmed state.
        let reopened = CalendarRepository(areaRoot: root)
        let loaded = try await reopened.load()
        XCTAssertEqual(loaded.state.events.map(\.title), ["eigener Termin"])
        let cached = try await reopened.sourceSnapshot()
        XCTAssertEqual(cached?.lessons.map(\.key.sourceID), ["1"])
        XCTAssertEqual(cached?.holidays.map(\.name), ["Ferien (fiktiv)"])
        XCTAssertEqual(cached?.coverage(from: day("2026-11-09"), to: day("2026-11-14")), .notLoaded)

        // Disconnect: connection removed, cache dropped, own events untouched.
        var disconnected = loaded.state
        disconnected.connection = nil
        try await reopened.save(disconnected, revision: 2)
        try await reopened.removeSourceCache(connection: record.id)
        let none = try await reopened.sourceSnapshot()
        XCTAssertNil(none)
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.appendingPathComponent("Cache/\(record.id.uuidString).json").path))
        await reopened.close()
        let final = try await CalendarRepository(areaRoot: root).load()
        XCTAssertEqual(final.state.events.map(\.title), ["eigener Termin"])
        XCTAssertNil(final.state.connection)
    }

    func testDamagedCacheIsEmptyAndNewerCacheIsLeftAlone() async throws {
        let record = CalendarConnectionRecord(label: "Demo Schule")
        let repository = CalendarRepository(areaRoot: root)
        _ = try await repository.load()
        try await repository.save(state([], connection: record), revision: 1)
        let cacheURL = package.appendingPathComponent("Cache/\(record.id.uuidString).json")
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{nicht json".utf8).write(to: cacheURL)
        let damaged = try await repository.sourceSnapshot()
        XCTAssertEqual(damaged?.days, [:]) // nothing loaded – never „no lessons“
        await repository.close()

        let future = Data(#"{"formatVersion":4,"connection":"x"}"#.utf8)
        try future.write(to: cacheURL)
        let other = CalendarRepository(areaRoot: root)
        _ = try await other.load()
        do { _ = try await other.sourceSnapshot(); XCTFail("gesperrt erwartet") }
        catch { XCTAssertEqual(error as? CalendarStoreError, .unsupportedFormat(4)) }
        let fetch = CalendarTimetableFetch(connection: record.id, start: day("2026-11-02"), end: day("2026-11-03"),
                                           fetchedAt: Date(), lessons: [])
        do { _ = try await other.merge(fetch); XCTFail("gesperrt erwartet") }
        catch { XCTAssertEqual(error as? CalendarStoreError, .unsupportedFormat(4)) }
        XCTAssertEqual(try Data(contentsOf: cacheURL), future)
        await other.close()
    }
}
