import Foundation
import XCTest
@testable import NotebookCore

/// BACKUP-RESTORE-PLAN Phases 2–4: tiered retention of automatic backups,
/// local backup summaries, local states as files for the staged import.
final class RestorePhasesTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("restore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

    // MARK: Phase 3: tiered retention

    func testDailyBackupsKeepSevenDaysFourWeeksAndSixMonths() {
        var policy = ExternalBackupPolicy(); policy.keep = 7
        let now = Date(timeIntervalSince1970: 1_794_000_000)   // a fixed moment
        // One backup a day for a year, newest first.
        let names = (0..<365).map { policy.filename(at: now.addingTimeInterval(-Double($0) * 86_400)) }
        let removed = Set(policy.obsolete(names, verified: names[0], calendar: utc))
        let kept = names.filter { !removed.contains($0) }
        XCTAssertTrue(kept.contains(names[0]))
        XCTAssertTrue(names[0..<7].allSatisfy { kept.contains($0) }, "die letzten 7 Tage")
        let days = kept.map { Int((now.timeIntervalSince1970 - policy.timestamp($0)!) / 86_400) }
        XCTAssertTrue(days.contains { (20...35).contains($0) }, "ein Stand vor etwa vier Wochen")
        XCTAssertTrue(days.contains { (150...190).contains($0) }, "ein Stand vor etwa einem halben Jahr")
        XCTAssertFalse(days.contains { $0 > 200 }, "nichts älter als die Monatsstaffel")
        XCTAssertLessThanOrEqual(kept.count, 7 + 4 + 6 + 2, "gestaffelt, nicht alles")
        // Never more than before for backups of a single day (old behaviour).
        let sameDay = (0..<8).map { policy.filename(at: now.addingTimeInterval(-Double($0))) }
        XCTAssertEqual(Set(policy.obsolete(sameDay, verified: sameDay[0], calendar: utc)), Set([sameDay[7]]))
    }

    func testTiersCanBeTurnedOffAndAreValidated() throws {
        var policy = ExternalBackupPolicy(); policy.keep = 3; policy.keepWeeks = 0; policy.keepMonths = 0
        let now = Date(timeIntervalSince1970: 1_794_000_000)
        let names = (0..<40).map { policy.filename(at: now.addingTimeInterval(-Double($0) * 86_400)) }
        let kept = names.filter { !policy.obsolete(names, verified: names[0], calendar: utc).contains($0) }
        XCTAssertEqual(kept.count, 7, "nur die täglichen Stände der letzten Woche")
        policy.keepWeeks = 13
        XCTAssertThrowsError(try policy.validate())
        // Older policies without the fields decode with the defaults.
        let old = try JSONDecoder().decode(ExternalBackupPolicy.self, from: JSONEncoder().encode(ExternalBackupPolicy()))
        XCTAssertNil(old.keepWeeks)
        XCTAssertNoThrow(try old.validate())
    }

    // MARK: Phase 3: summaries

    private func archiveSummary(_ notebooks: [(UUID, String, UInt32)], trashed: UUID? = nil, at time: TimeInterval) throws -> LibraryArchiveSummary {
        var snapshot = LibrarySnapshot()
        for (id, title, _) in notebooks {
            var item = LibraryItem(id: id, title: title, parentID: nil, source: .library)
            if id == trashed { item.deletedAt = Date(timeIntervalSince1970: time) }
            snapshot.items.append(item)
        }
        return LibraryArchiveSummary(createdAt: Date(timeIntervalSince1970: time), snapshot: snapshot, toolbar: ToolbarPreferences(),
                                     notebooks: notebooks.map { LibraryArchiveChunk(id: $0.0, byteCount: 100, crc32: $0.2) },
                                     file: LibraryArchiveFileInfo(byteCount: 1_000, crc32: 1))
    }

    func testSummariesSayWhatChangedAndFindTheStatesOfOneNotebook() throws {
        let bio = UUID(), mathe = UUID(), deutsch = UUID()
        var index = BackupSummaryIndex(series: UUID())
        let first = BackupSummary(file: "a.notylibrary", archive: try archiveSummary([(bio, "Bio", 1), (mathe, "Mathe", 1)], at: 1_000), previous: nil)
        index.record(first)
        XCTAssertNil(first.changed)
        XCTAssertEqual(first.line, "2 Hefte")
        let second = BackupSummary(file: "b.notylibrary",
                                   archive: try archiveSummary([(bio, "Bio", 2), (mathe, "Mathe", 1), (deutsch, "Deutsch", 7)], at: 2_000),
                                   previous: index.newest)
        index.record(second)
        XCTAssertEqual(Set(second.changed ?? []), [bio, deutsch])
        XCTAssertEqual(second.line, "3 Hefte · 2 geändert (Bio, Deutsch)")
        let third = BackupSummary(file: "c.notylibrary",
                                  archive: try archiveSummary([(bio, "Bio", 2), (mathe, "Mathe", 1), (deutsch, "Deutsch", 7)], trashed: mathe, at: 3_000),
                                  previous: index.newest)
        index.record(third)
        XCTAssertEqual(third.line, "2 Hefte · 1 entfernt")
        // Bio: two states (c and b hold the same one), Mathe only in a and b (one state).
        let bioStates = index.states(of: bio)
        XCTAssertEqual(bioStates.map(\.summary.file), ["c.notylibrary", "a.notylibrary"])
        XCTAssertEqual(bioStates.map(\.sameStateCount), [2, 1])
        XCTAssertEqual(index.states(of: mathe).map(\.summary.file), ["b.notylibrary"])
        // Archives gone from the target leave the index.
        index.record(third, existing: ["c.notylibrary", "b.notylibrary"])
        XCTAssertEqual(index.summaries.map(\.file), ["c.notylibrary", "b.notylibrary"])

        let root = try directory()
        try index.save(root: root)
        XCTAssertEqual(BackupSummaryIndex.load(root: root, series: index.series), index)
        XCTAssertEqual(BackupSummaryIndex.load(root: root, series: UUID()).summaries, [], "andere Reihe: leer")
        try Data("kaputt".utf8).write(to: BackupSummaryIndex.url(root: root, series: index.series))
        XCTAssertEqual(BackupSummaryIndex.load(root: root, series: index.series).summaries, [], "beschädigt: leer, kein Fehler")
    }

    // MARK: Phase 2: local states into the library

    func testLocalStateBecomesAVerifiedFileWithItsOwnTitle() async throws {
        let root = try directory()
        let repository = NotebookRepository(directory: root)
        var document = Notebook.blank(title: "Bio")
        document.pages[0].text = "alter Stand"
        try await repository.save(document, revision: 1)
        document.pages[0].text = "neuer Stand"
        try await repository.save(document, revision: 2)
        let history = try await repository.localHistory()
        let older = try XCTUnwrap(history.revisions.last)
        let file = root.appendingPathComponent("stand.notybackup")
        try await repository.exportLocalRevision(id: older.id, title: "Bio (Stand 08.11.2026, 10:00)", to: file)

        let target = NotebookRepository(directory: try directory())
        let prepared = try await target.prepareRestore(from: file)
        XCTAssertEqual(prepared.sourceDocumentID, document.id, "gleiche Herkunft: Ersetzen ist möglich")
        XCTAssertEqual(prepared.document.title, "Bio (Stand 08.11.2026, 10:00)")
        XCTAssertEqual(prepared.document.pages[0].text, "alter Stand")
        // The package itself is untouched: still the newer state.
        let current = try await repository.load().0
        XCTAssertEqual(current.pages[0].text, "neuer Stand")
        do { try await repository.exportLocalRevision(id: UUID(), title: "x", to: root.appendingPathComponent("nein.notybackup")); XCTFail() }
        catch { }

        // The same read-only, as Settings uses it for a closed notebook.
        let readOnly = try LocalStates.history(package: root)
        XCTAssertEqual(readOnly.revisions.map(\.id), history.revisions.map(\.id))
        let second = root.appendingPathComponent("lesend.notybackup")
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        try LocalStates.export(package: root, revision: older.id, title: "Bio (Stand)", to: second)
        let after = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        XCTAssertEqual(after, (before + ["lesend.notybackup"]).sorted(), "nichts im Paket geschrieben")
        let again = try await target.prepareRestore(from: second)
        XCTAssertEqual(again.document.pages[0].text, "alter Stand")
    }

    // MARK: Ersetzen: the calendar follows the restored notebook

    func testCalendarFollowsAReplacedNotebook() {
        let lernfeld = UUID(), other = UUID(), restored = UUID()
        var state = CalendarState()
        state.studyFields = [CalendarStudyField(number: 4, title: "Einkommensteuer", notebookID: lernfeld)]
        let anchor = CalendarLessonAnchor(source: "webuntis:erfunden", periodID: "1", lessonID: nil, originalDate: CivilDate("2026-11-09")!,
                                          originalStart: "2026-11-09T08:00")
        let page = UUID(), time = Date(timeIntervalSince1970: 1_794_000_000)
        state.noteLinks = [
            CalendarNoteLink(target: .lesson(anchor), documentID: lernfeld, pageID: page, createdAt: time,
                             contextTitle: "SR", contextStart: time, contextEnd: time.addingTimeInterval(2_700)),
            CalendarNoteLink(target: .local(event: UUID(), date: nil), documentID: other, createdAt: time,
                             contextTitle: "Zahnarzt", contextStart: time, contextEnd: time.addingTimeInterval(3_600)),
        ]
        XCTAssertEqual(state.referencedNotebooks, [lernfeld, other])
        XCTAssertFalse(state.notebookReplaced(UUID(), by: restored), "nicht verknüpft: nichts geändert")
        XCTAssertTrue(state.notebookReplaced(lernfeld, by: restored))
        XCTAssertEqual(state.studyFields[0].notebookID, restored)
        XCTAssertEqual(state.noteLinks[0].documentID, restored)
        XCTAssertEqual(state.noteLinks[0].pageID, page, "die Stunde bleibt an ihrer Seite")
        XCTAssertEqual(state.noteLinks[1].documentID, other)
        XCTAssertEqual(state.referencedNotebooks, [restored, other])
    }
}
