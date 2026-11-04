import Foundation

extension PageWorkflowCheck {
    /// Kalender B3: an area with a calendar (series with exception and changed
    /// occurrence, reminder, deleted event, links, mapping, colours, notes
    /// folder, WebUntis connection record with offline timetable) as library
    /// archive format 3, restored into a new area. Fictitious data only; the
    /// fictitious access data must not appear in the archive. Leaves
    /// `kalender.notylibrary`, `kalender-corrupt.notylibrary`, the source area
    /// `Kalender/` and the restored area's path in `kalender-restore-path.txt`
    /// for the Python verifiers (`check_calendar_backup.py`).
    static func checkCalendarBackup(root: URL) async throws
        -> (format3: Bool, identical: Bool, linksLocal: Bool, detached: Bool, secretFree: Bool, corruptRejected: Bool) {
        var berlin = Calendar(identifier: .gregorian); berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Date { berlin.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m))! }
        func timed(_ d: Int, _ h: Int, minutes: Int = 90) -> CalendarEventTiming {
            .timed(start: at(d, h), end: at(d, h).addingTimeInterval(Double(minutes) * 60), timeZone: "Europe/Berlin")
        }
        let created = Date(timeIntervalSince1970: 1_790_000_000)
        let area = root.appendingPathComponent("Kalender", isDirectory: true)
        let library = LibraryStore(root: area)
        _ = try await library.load()
        let folder = try await library.createFolder(title: CalendarNotesFolder.title, parentID: nil).items.last!.id
        var note = Notebook.blank(title: "Mathematik · 10.11.2026"); note.pages[0].text = "Stundennotiz (erfunden)"
        try RevisionStore(directory: area.appendingPathComponent("Library/Documents/\(note.id.uuidString)")).save(note)
        _ = try await library.adoptImported(note.id, title: note.title, parentID: folder, replacing: nil)
        let setup = try WebUntisSetup(server: "erfunden-geheim.example.invalid", school: "Beispielschule", user: "max.erfunden",
                                      key: "JBSWY3DPEHPK3PXPGEHEIMGEHEIM")
        let connection = UUID()
        var state = CalendarState()
        let series = LocalCalendarEvent(title: "Lerngruppe", location: "Bibliothek", timing: timed(2, 15),
            recurrence: CalendarRecurrence(frequency: .weekly, end: .afterCount(10), exceptions: [CivilDate("2026-11-16")!],
                overrides: [CalendarOccurrenceOverride(originalDate: CivilDate("2026-11-09")!, title: "Lerngruppe (später)", timing: timed(9, 17))]),
            reminderMinutes: 30, createdAt: created)
        let gone = LocalCalendarEvent(title: "Zahnarzt", timing: timed(12, 10), createdAt: created)
        state.events = [series]
        state.deletedEvents = [CalendarDeletedEvent(event: gone, deletedAt: created),
                               CalendarDeletedEvent(event: series, occurrence: CivilDate("2026-11-16")!, deletedAt: created)]
        state.connection = CalendarConnectionRecord(id: connection, label: setup.school, connectedAt: created, sourceIdentity: WebUntis.sourceIdentity(setup))
        let anchor = CalendarLessonAnchor(source: WebUntis.sourceIdentity(setup), periodID: "4711", lessonID: "88",
                                          originalDate: CivilDate("2026-11-10")!, originalStart: "2026-11-10T08:00")
        state.noteLinks = [CalendarNoteLink(target: .lesson(anchor), documentID: note.id, pageID: note.pages[0].id, createdAt: created,
                                            contextTitle: "Mathematik", contextStart: at(10, 8), contextEnd: at(10, 8, 45)),
                           CalendarNoteLink(target: .local(event: gone.id, date: nil), documentID: note.id, createdAt: created,
                                            contextTitle: "Zahnarzt", contextStart: at(12, 10), contextEnd: at(12, 11))]
        state.lessonMappings = [CalendarLessonMapping(source: anchor.source, fromPeriodID: "4711", fromDate: CivilDate("2026-11-10")!,
                                                      toPeriodID: "4800", toDate: CivilDate("2026-11-11")!, confirmedAt: created)]
        state.settings.subjectColors = ["webuntis:12": "indigo"]; state.settings.notesFolderID = folder
        state.settings.lessonReminderMinutes = 10
        let repository = CalendarRepository(areaRoot: area)
        _ = try await repository.load()
        try await repository.save(state, revision: 1)
        var lesson = CalendarLesson(key: CalendarOccurrenceKey(provider: "webuntis", connection: connection, sourceID: "4800", seriesID: "88",
                                                               originalStart: "2026-11-11T08:00"),
                                    date: CivilDate("2026-11-11")!, start: at(11, 8), end: at(11, 8, 45))
        lesson.subjectLong = "Mathematik"; lesson.rooms = ["R 101"]
        let snapshot = try await repository.merge(CalendarTimetableFetch(connection: connection, start: CivilDate("2026-11-09")!,
            end: CivilDate("2026-11-14")!, fetchedAt: Date(timeIntervalSince1970: 1_794_000_000), lessons: [lesson]))
        await repository.close()

        let archive = root.appendingPathComponent("kalender.notylibrary")
        let summary = try LibraryArchive.write(try await library.backupPlan(), to: archive)
        let bytes = try Data(contentsOf: archive)
        let secretFree = ["erfunden-geheim", "example.invalid", "max.erfunden", "JBSWY3DPEHPK3PXPGEHEIMGEHEIM"]
            .allSatisfy { bytes.range(of: Data($0.utf8)) == nil }
        var corrupt = bytes
        corrupt[bytes.range(of: Data("Lerngruppe".utf8))!.lowerBound] ^= 0x20
        let corruptFile = root.appendingPathComponent("kalender-corrupt.notylibrary")
        try corrupt.write(to: corruptFile)
        let workspaces = WorkspaceStore(root: root.appendingPathComponent("KalenderWorkspaces"))
        var corruptRejected = false
        do { _ = try await workspaces.prepareRestore(file: corruptFile) } catch { corruptRejected = true }
        let nothingPublished = try await workspaces.list().workspaces.isEmpty
        let restoredArea = try await workspaces.commitRestore(try await workspaces.prepareRestore(file: archive), title: "Kalender-Restore")
        let data = try await workspaces.directory(for: restoredArea.id)
        try data.path.write(to: root.appendingPathComponent("kalender-restore-path.txt"), atomically: true, encoding: .utf8)
        let restoredRepository = CalendarRepository(areaRoot: data)
        let restored = try await restoredRepository.load().state
        let restoredSnapshot = try await restoredRepository.sourceSnapshot()
        await restoredRepository.close()
        let documents = Set(try await LibraryStore(root: data).committedSnapshot().items.filter { !$0.isFolder }.map(\.id))
        var comparable = restored; comparable.connection = state.connection
        let identical = comparable == state && restoredSnapshot?.days == snapshot.days
            && restoredSnapshot?.lessons.map(\.key.sourceID) == snapshot.lessons.map(\.key.sourceID)
        let detached = restored.connection?.id != connection && restored.connection?.source == state.connection?.source
            && restoredSnapshot?.connection == restored.connection?.id
        return (summary.formatVersion == 3, identical, restored.noteLinks.allSatisfy { documents.contains($0.documentID) }, detached,
                secretFree, corruptRejected && nothingPublished)
    }
}
