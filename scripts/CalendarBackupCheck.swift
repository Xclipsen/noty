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
        // Format 6: an ordinary notebook of the library as a subject's Fach-Heft.
        var religion = Notebook.blank(title: "Religion (erfunden)"); religion.pages[0].text = "Fach-Heft (erfunden)"
        try RevisionStore(directory: area.appendingPathComponent("Library/Documents/\(religion.id.uuidString)")).save(religion)
        _ = try await library.adoptImported(religion.id, title: religion.title, parentID: nil, replacing: nil)
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
                                            contextTitle: "Zahnarzt", contextStart: at(12, 10), contextEnd: at(12, 11)),
                           // Format 4: note of a system calendar occurrence (fictitious identifiers).
                           CalendarNoteLink(target: .system(CalendarSystemAnchor(externalID: "ERFUNDEN-EXT-1", itemID: "erfunden-item-1",
                                                                                 calendarID: "erfunden-kalender", occurrence: at(13, 9))),
                                            documentID: note.id, createdAt: created, contextTitle: "Teamtermin",
                                            contextStart: at(13, 9), contextEnd: at(13, 10))]
        state.settings.systemCalendars = CalendarSystemSettings(enabled: true, hiddenCalendars: ["erfunden-geburtstage"],
                                                                defaultTarget: "erfunden-kalender")
        state.homeworkDone = [CalendarHomeworkMark(source: WebUntis.sourceIdentity(setup), homeworkID: "9001", doneAt: created)]
        state.lessonMappings = [CalendarLessonMapping(source: anchor.source, fromPeriodID: "4711", fromDate: CivilDate("2026-11-10")!,
                                                      toPeriodID: "4800", toDate: CivilDate("2026-11-11")!, confirmedAt: created)]
        state.settings.subjectColors = ["webuntis:12": "indigo"]; state.settings.notesFolderID = folder
        state.settings.lessonReminderMinutes = 10
        // Format 5: a Lernfeld with its notebook, a rule and a lesson topic with pinned material (fictitious).
        let field = CalendarStudyField(number: 3, title: "Umsatzsteuer (erfunden)", notebookID: note.id, package: "beispiel-material")
        state.studyFields = [field]
        state.studyRules = [CalendarStudyRule(subjectKey: "webuntis:12", subjectName: "SR", weekday: 1, startFrom: 480, startTo: 630,
                                              fieldID: field.id)]
        state.lessonTopics = [CalendarLessonTopic(target: .lesson(anchor), topic: "Die Lieferung", summary: "Merksatz (erfunden)",
            materials: [CalendarMaterialRef(package: "beispiel-material", key: "lesson:00000000-0000-4000-8000-000000000042",
                                            label: "Ort der Lieferung", detail: "LF 3 · Kapitel 4 · S. 5–9")], modifiedAt: created)]
        state.subjectNotebooks = [CalendarSubjectNotebook(subjectKey: "webuntis:77", subjectName: "Religion", notebookID: religion.id)]
        let repository = CalendarRepository(areaRoot: area)
        _ = try await repository.load()
        try await repository.save(state, revision: 1)
        var lesson = CalendarLesson(key: CalendarOccurrenceKey(provider: "webuntis", connection: connection, sourceID: "4800", seriesID: "88",
                                                               originalStart: "2026-11-11T08:00"),
                                    date: CivilDate("2026-11-11")!, start: at(11, 8), end: at(11, 8, 45))
        lesson.subjectLong = "Mathematik"; lesson.rooms = ["R 101"]
        let homework = CalendarHomework(id: "9001", lessonID: "88", periodID: "4800", periodDate: CivilDate("2026-11-11")!,
                                        assigned: CivilDate("2026-11-11")!, due: CivilDate("2026-11-13")!, subject: "Mathematik",
                                        text: "Aufgabe 1 (erfunden)")
        let snapshot = try await repository.merge(CalendarTimetableFetch(connection: connection, start: CivilDate("2026-11-09")!,
            end: CivilDate("2026-11-14")!, fetchedAt: Date(timeIntervalSince1970: 1_794_000_000), lessons: [lesson], homework: [homework]))
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
        // A restore never activates a source: system calendars come back switched off.
        let systemDetached = restored.settings.systemCalendars?.enabled == false
        comparable.settings.systemCalendars?.enabled = true
        let identical = comparable == state && systemDetached && restoredSnapshot?.days == snapshot.days
            && restoredSnapshot?.homework == snapshot.homework
            && restoredSnapshot?.lessons.map(\.key.sourceID) == snapshot.lessons.map(\.key.sourceID)
        let detached = restored.connection?.id != connection && restored.connection?.source == state.connection?.source
            && restoredSnapshot?.connection == restored.connection?.id
        let linksLocal = restored.noteLinks.allSatisfy { documents.contains($0.documentID) }
            && restored.studyFields.allSatisfy { $0.notebookID.map(documents.contains) ?? true }
            && restored.subjectNotebooks.allSatisfy { documents.contains($0.notebookID) }
        return (summary.formatVersion == 3, identical, linksLocal, detached,
                secretFree, corruptRejected && nothingPublished)
    }
}
