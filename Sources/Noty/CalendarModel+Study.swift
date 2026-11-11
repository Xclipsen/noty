import SwiftUI
import NotebookCore

// Lernfelder (calendar format 5, docs/LERNFELDER.md): lessons assigned to a
// Lernfeld by rules; a lesson block's note is a headed section of the field's
// notebook instead of a small notebook of its own; per block a topic, an own
// key sentence and pinned learning material. Fach-Hefte (format 6): the same
// sections in an ordinary notebook the user chose for a subject; the notebook
// opens full screen instead of beside the event.

/// Where a lesson block's section lives.
enum StudyHome: Equatable {
    case field(CalendarStudyField)
    /// Fach-Heft: the subject's own notebook, chosen by the user.
    case subject(CalendarSubjectNotebook)
    var id: UUID {
        switch self { case .field(let field): field.id; case .subject(let subject): subject.id }
    }
    var notebookID: UUID? {
        switch self { case .field(let field): field.notebookID; case .subject(let subject): subject.notebookID }
    }
    var isSubject: Bool { if case .subject = self { true } else { false } }
    /// Shown above the prompt.
    var displayName: String {
        switch self { case .field(let field): field.displayName; case .subject(let subject): subject.subjectName }
    }
}

/// The note area of a Lernfeld or Fach-Heft lesson: start (or open) its section.
struct CalendarStudyPrompt: Equatable {
    enum Notebook: Equatable {
        /// A new section goes into it.
        case ready(String)
        /// The notebook is in the trash: restore it or start a new one (Lernfeld) / choose another (Fach-Heft).
        case trashed(UUID, String)
        /// None yet (Lernfeld: the first section creates it) or deleted for good (Fach-Heft: choose another).
        case none
    }
    let home: StudyHome
    let notebook: Notebook
    /// Fach-Heft: the block already has its section; the prompt only opens it.
    var existingPage: UUID?
    var creating = false
    var failure: String?
}

/// A Lernfeld notebook being created (`createStudySection`): kept per field
/// until the notebook is committed, in the library and linked, so a retry
/// continues with the same notebook and page instead of making another.
struct CalendarStudyCreation {
    let documentID: UUID
    let pageID: UUID
    let title: String
    let model: EditorModel
}

extension CalendarModel {
    var schoolTimeZone: TimeZone {
        state.connection.flatMap { TimeZone(identifier: $0.timeZone) } ?? CalendarDefaults.timeZone
    }

    var studyFields: [CalendarStudyField] { state.studyFields.sorted { $0.number < $1.number } }

    func studyField(id: UUID) -> CalendarStudyField? { state.studyFields.first { $0.id == id } }

    /// The Lernfeld of a timetable lesson, nil without a matching rule.
    func studyField(for entry: CalendarEntry) -> CalendarStudyField? {
        var school = Calendar(identifier: .gregorian)
        school.timeZone = schoolTimeZone
        return studyField(for: entry, school: school)
    }

    private func studyField(for entry: CalendarEntry, school: Calendar) -> CalendarStudyField? {
        guard !entry.isSample, entry.source == .timetable, entry.ghostLinkID == nil, let key = entry.subjectKey,
              !state.studyRules.isEmpty else { return nil }
        let (weekday, minutes) = CalendarStudy.weekdayAndMinutes(entry.start, calendar: school)
        return CalendarStudy.field(subjectKey: key, weekday: weekday, startMinutes: minutes, rules: state.studyRules, fields: state.studyFields)
    }

    /// Lernfeld (by rule) or Fach-Heft (by subject) of a timetable lesson; the
    /// Lernfeld wins. Nil: the lesson gets a small note of its own.
    func studyHome(for entry: CalendarEntry) -> StudyHome? {
        var school = Calendar(identifier: .gregorian)
        school.timeZone = schoolTimeZone
        return studyHome(for: entry, school: school)
    }

    private func studyHome(for entry: CalendarEntry, school: Calendar) -> StudyHome? {
        if let field = studyField(for: entry, school: school) { return .field(field) }
        guard !entry.isSample, entry.source == .timetable, entry.ghostLinkID == nil, let key = entry.subjectKey,
              let subject = CalendarStudy.subjectNotebook(subjectKey: key, in: state.subjectNotebooks) else { return nil }
        return .subject(subject)
    }

    /// Entry id → id of the first lesson of its block, for every lesson of a
    /// Lernfeld or Fach-Heft (consecutive lessons of the same subject and home
    /// on one day share one heading, one topic and one link).
    /// The block's first lesson is its first one not cancelled (else its first).
    func studyBlocks(_ entries: [CalendarEntry]) -> [String: String] {
        guard !state.studyRules.isEmpty || !state.subjectNotebooks.isEmpty else { return [:] }
        var school = Calendar(identifier: .gregorian)
        school.timeZone = schoolTimeZone
        var byDay: [CivilDate: [(entry: CalendarEntry, key: String)]] = [:]
        for entry in entries where entry.source == .timetable && entry.ghostLinkID == nil {
            guard let subject = entry.subjectKey, let home = studyHome(for: entry, school: school) else { continue }
            byDay[CivilDate(entry.start, calendar: calendar), default: []].append((entry, subject + "|" + home.id.uuidString))
        }
        var result: [String: String] = [:]
        for (_, list) in byDay {
            let lessons = list.map { (subjectKey: $0.key, start: $0.entry.start, end: $0.entry.end) }
            for index in list.indices where result[list[index].entry.id] == nil {
                let block = CalendarStudy.block(of: index, in: lessons)
                guard let first = block.first(where: { list[$0].entry.status != .cancelled }) ?? block.first else { continue }
                for member in block { result[list[member].entry.id] = list[first].entry.id }
            }
        }
        return result
    }

    /// The first lesson of the block of `entry` (itself outside a Lernfeld).
    func studyAnchor(for entry: CalendarEntry) -> CalendarEntry {
        studyAnchorByEntry[entry.id].flatMap { event($0) } ?? entry
    }

    /// The end of the block of `entry`.
    func studyBlockEnd(for entry: CalendarEntry) -> Date {
        let anchor = studyAnchor(for: entry)
        let members = events(on: anchor.start).filter { studyAnchorByEntry[$0.id] == anchor.id }
        return members.map(\.end).max() ?? entry.end
    }

    /// What topic and material of `entry` belong to: its block's first lesson
    /// (a Lernfeld lesson) or the entry itself.
    func topicTarget(for entry: CalendarEntry) -> CalendarNoteTarget? {
        guard !entry.isSample else { return nil }
        if let link = linkByEntry[entry.id] { return link.target }
        return studyAnchor(for: entry).noteTarget ?? entry.noteTarget
    }

    /// The targets of all lessons of the block of `entry`, by start. A topic
    /// stored under one of them belongs to the block: its first lesson
    /// changes when a lesson is cancelled (`CalendarLessonTopics`).
    func topicBlockTargets(for entry: CalendarEntry) -> [CalendarNoteTarget] {
        let anchor = studyAnchor(for: entry)
        return events(on: anchor.start).filter { studyAnchorByEntry[$0.id] == anchor.id }.compactMap(\.noteTarget)
    }

    /// Found by the target's key (the same period with another start is the
    /// same lesson), else under another lesson of the block.
    func topic(for entry: CalendarEntry) -> CalendarLessonTopic? {
        guard let target = topicTarget(for: entry) else { return nil }
        return CalendarLessonTopics.topic(in: state.lessonTopics, target: target, block: topicBlockTargets(for: entry))
    }

    /// Topic, key sentence and pinned material: one commit; an entry that
    /// becomes empty is removed.
    func updateTopic(for entry: CalendarEntry, _ change: @escaping (inout CalendarLessonTopic) -> Void) async {
        guard canWrite, !showsSamples, let target = topicTarget(for: entry) else { return }
        let block = topicBlockTargets(for: entry)
        await commit { state in
            // Replaces the topic that is shown (never a second one with the same key).
            CalendarLessonTopics.update(&state.lessonTopics, target: target, block: block) { topic in
                change(&topic)
                topic.topic = String(topic.topic.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces).prefix(200))
                topic.summary = String(topic.summary.prefix(2_000))
                topic.modifiedAt = Date()
            }
        }
    }

    func setTopic(_ text: String, for entry: CalendarEntry) async {
        let old = topic(for: entry)?.topic ?? ""
        let new = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard new != old else { return }
        await updateTopic(for: entry) { $0.topic = new }
        updateSectionHeading(for: entry, oldTopic: old, newTopic: new)
    }

    func pin(_ ref: CalendarMaterialRef, for entry: CalendarEntry) async {
        await updateTopic(for: entry) { topic in
            guard !topic.materials.contains(where: { $0.package == ref.package && $0.key == ref.key }),
                  topic.materials.count < CalendarLessonTopic.maximumMaterials else { return }
            topic.materials.append(ref)
        }
    }

    func unpin(_ ref: CalendarMaterialRef, for entry: CalendarEntry) async {
        await updateTopic(for: entry) { $0.materials.removeAll { $0.package == ref.package && $0.key == ref.key } }
    }

    // MARK: Fields and rules (Einstellungen › Kalender › Lernfelder)

    /// Lernfelder of a material package that this area does not have yet.
    func importFields(from catalog: MaterialCatalog) async {
        await commit { state in
            for field in catalog.fields where !state.studyFields.contains(where: { $0.number == field.number }) {
                guard state.studyFields.count < CalendarStudy.maximumFields,
                      let title = CalendarState.validTitle(String(field.title.prefix(200))) else { continue }
                state.studyFields.append(CalendarStudyField(number: field.number, title: title, package: catalog.id))
            }
        }
    }

    func addField(number: Int, title: String) async -> Bool {
        guard let title = CalendarState.validTitle(title), (1...99).contains(number),
              !state.studyFields.contains(where: { $0.number == number }) else { return false }
        return await commit { $0.studyFields.append(CalendarStudyField(number: number, title: title)) }
    }

    /// Removes the field and its rules; its notebook, sections and topics stay.
    func removeField(_ id: UUID) async {
        await commit { state in
            state.studyRules.removeAll { $0.fieldID == id }
            state.studyFields.removeAll { $0.id == id }
        }
    }

    // MARK: Lernfeld-Heft wählen (Einstellungen › Kalender › Lernfelder)

    /// Notebooks the field may take: ordinary active notebooks of the library
    /// (no text documents, no calendar note, none of another field or of a
    /// subject), by title. The field's own notebook is not listed.
    func fieldNotebookCandidates(for field: CalendarStudyField) -> [NotebookCore.LibraryItem] {
        guard let library else { return [] }
        var taken = CalendarStudy.notebooksTaken(forField: field.id, fields: state.studyFields, subjects: state.subjectNotebooks)
        if let own = field.notebookID { taken.insert(own) }
        return CalendarNotesFolder.sectionNotebookCandidates(in: library.snapshot, notesFolder: state.settings.notesFolderID, taken: taken)
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Sections of lessons that already point into the field's current notebook.
    func fieldSectionCount(_ field: CalendarStudyField) -> Int {
        guard let id = field.notebookID else { return 0 }
        return state.noteLinks.filter { $0.documentID == id && $0.pageID != nil }.count
    }

    /// „Lernfeld-Heft wählen“: from the next lesson note on the field writes
    /// its sections into `item`, an existing notebook of the library (new
    /// sections go to its end, `StudySections.insertionIndex`). nil: the field
    /// lets its notebook go and gets a new one with the next note. The
    /// notebooks themselves and the sections written so far are not touched.
    @discardableResult
    func setFieldNotebook(_ item: NotebookCore.LibraryItem?, for fieldID: UUID) async -> Bool {
        guard canWrite, !showsSamples, let field = state.studyFields.first(where: { $0.id == fieldID }) else { return false }
        if let item {
            // Chosen from a list that may be older than the library: check again.
            guard fieldNotebookCandidates(for: field).contains(where: { $0.id == item.id }) else {
                notice = "„\(item.title)“ kann nicht mehr gewählt werden. Bitte ein anderes Heft wählen."
                return false
            }
        }
        // The note beside the event may show this field's prompt or section: close it first.
        await closeNote()
        let saved = await commit { state in
            try? CalendarStudy.setNotebook(item?.id, ofField: fieldID, fields: &state.studyFields, subjects: state.subjectNotebooks)
        }
        // A notebook this field was still creating is no longer its notebook (it stays in the library if it got that far).
        let changed = saved && state.studyFields.first(where: { $0.id == fieldID })?.notebookID == item?.id
        if changed { studyCreations[fieldID] = nil }
        if let entry = selectedEvent { showNote(for: entry) }
        return changed
    }

    /// The rule for exactly this subject/weekday/time window: set (field) or removed (nil).
    func setRule(subjectKey: String, subjectName: String, weekday: Int?, startFrom: Int?, startTo: Int?, field: UUID?) async {
        await commit { state in
            state.studyRules.removeAll {
                $0.subjectKey == subjectKey && $0.weekday == weekday && $0.startFrom == startFrom && $0.startTo == startTo
            }
            if let field {
                state.studyRules.append(CalendarStudyRule(subjectKey: subjectKey, subjectName: String(subjectName.prefix(200)),
                                                          weekday: weekday, startFrom: startFrom, startTo: startTo, fieldID: field))
            }
        }
    }

    func rule(subjectKey: String, weekday: Int?, startFrom: Int?, startTo: Int?) -> CalendarStudyRule? {
        state.studyRules.first { $0.subjectKey == subjectKey && $0.weekday == weekday && $0.startFrom == startFrom && $0.startTo == startTo }
    }

    /// One block of the timetable as the settings list it: a subject on a
    /// weekday from its first start to its last end (school time).
    struct TimetableSlot: Identifiable, Hashable {
        var id: String { "\(subjectKey)|\(weekday)|\(start)" }
        let subjectKey: String
        let subjectName: String
        let weekday: Int
        let start: Int
        let end: Int
        var label: String { "\(["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"][weekday - 1]) \(Self.clock(start))–\(Self.clock(end))" }
        static func clock(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
    }

    /// The blocks of the offline timetable, per subject and weekday (the
    /// most frequent start/end of a weekday's block wins).
    var timetableSlots: [TimetableSlot] {
        guard let lessons = snapshot?.lessons, !lessons.isEmpty else { return [] }
        let zone = schoolTimeZone
        var days: [String: [(key: String, name: String, start: Date, end: Date)]] = [:]
        for lesson in lessons where !lesson.isCancelled {
            let name = lesson.subjectLong ?? lesson.subject ?? lesson.title
            let key = CalendarSubjectColor.key(subjectID: lesson.subjectID, name: name)
            days["\(lesson.date)", default: []].append((key, lesson.subject ?? name, lesson.start, lesson.end))
        }
        var counts: [TimetableSlot: Int] = [:]
        for (_, list) in days {
            let tuples = list.map { (subjectKey: $0.key, start: $0.start, end: $0.end) }
            var seen = Set<Int>()
            for index in list.indices {
                let block = CalendarStudy.block(of: index, in: tuples)
                guard let first = block.first, seen.insert(first).inserted else { continue }
                let start = CalendarStudy.weekdayAndMinutes(list[first].start, timeZone: zone)
                let end = CalendarStudy.weekdayAndMinutes(block.map { list[$0].end }.max()!, timeZone: zone)
                let slot = TimetableSlot(subjectKey: list[first].key, subjectName: list[first].name, weekday: start.weekday,
                                         start: start.minutes, end: max(end.minutes, start.minutes + 1))
                counts[slot, default: 0] += 1
            }
        }
        var best: [String: (TimetableSlot, Int)] = [:]
        for (slot, count) in counts {
            let key = "\(slot.subjectKey)|\(slot.weekday)|\(slot.start / 60)"
            if best[key].map({ count > $0.1 }) ?? true { best[key] = (slot, count) }
        }
        return best.values.map(\.0).sorted { ($0.subjectName, $0.weekday, $0.start) < ($1.subjectName, $1.weekday, $1.start) }
    }

    // MARK: Fach-Hefte (Einstellungen › Kalender › Lernfelder, „…“ of a lesson)

    var subjectNotebooks: [CalendarSubjectNotebook] {
        state.subjectNotebooks.sorted { $0.subjectName.localizedStandardCompare($1.subjectName) == .orderedAscending }
    }

    func isSubjectNotebook(_ id: UUID) -> Bool { state.subjectNotebooks.contains { $0.notebookID == id } }

    /// Notebooks a subject may write into: ordinary active notebooks of the
    /// library (no text documents, no Lernfeld notebook, no calendar note,
    /// none of another subject), by title.
    func subjectNotebookCandidates(for entry: CalendarEntry) -> [NotebookCore.LibraryItem] {
        guard let library else { return [] }
        let taken = Set(state.subjectNotebooks.filter { $0.subjectKey != entry.subjectKey }.map(\.notebookID))
            .union(state.studyFields.compactMap(\.notebookID))
        return CalendarNotesFolder.sectionNotebookCandidates(in: library.snapshot, notesFolder: state.settings.notesFolderID, taken: taken)
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// „Fach-Heft wählen“: from now on every lesson of the subject (without a
    /// Lernfeld rule) writes a headed section into `item`; this lesson starts
    /// at once. Lessons already linked to a small note keep it.
    func assignSubjectNotebook(_ item: NotebookCore.LibraryItem, for entry: CalendarEntry) async {
        guard canWrite, !showsSamples, entry.source == .timetable, let key = entry.subjectKey else { return }
        if let session = noteSession, session.entryID == entry.id, session.phase != .draft || EditorModel.hasContent(session.model.notebook) {
            notice = "Diese Stunde hat schon eine eigene Notiz; das Fach-Heft gilt ab der nächsten Stunde."
        }
        await closeNote()
        let name = CalendarState.validTitle(entry.subject ?? entry.title) ?? "Fach"
        let subject = CalendarSubjectNotebook(subjectKey: key, subjectName: name, notebookID: item.id)
        guard await commit({ state in
            state.subjectNotebooks.removeAll { $0.subjectKey == key || $0.notebookID == item.id }
            state.subjectNotebooks.append(subject)
        }) else { return }
        guard selection == entry.id else { return }
        showNote(for: entry)
        if linkByEntry[entry.id] == nil { beginStudyNote(for: entry) }
    }

    /// „Zuordnung aufheben“: the subject's lessons get small notes again; the
    /// notebook and the sections written so far stay as they are.
    func removeSubjectNotebook(_ id: UUID) async {
        await commit { $0.subjectNotebooks.removeAll { $0.id == id } }
        if let entry = selectedEvent { releaseNote(); showNote(for: entry) }
    }

    /// A Fach-Heft lesson whose section exists: the notebook, full screen, at that page.
    func openSubjectSection(for entry: CalendarEntry) {
        guard let link = linkByEntry[entry.id] else { return }
        Task { [weak self] in await self?.openNotebook(link.documentID, page: link.pageID, for: entry) }
    }

    /// Full editor on `id` at `page`, back to this event afterwards. Never from
    /// inside the note queue: `closeNote` waits for it.
    private func openNotebook(_ id: UUID, page: UUID?, for entry: CalendarEntry) async {
        let back = "\(entry.title) · \(CalendarText.shortDate(entry.start, calendar: calendar))"
        await closeNote()
        if let library, let item = library.snapshot.items.first(where: { $0.id == id }), !library.snapshot.isTrashed(id) {
            await library.open(item, pageID: page, returnTitle: back)
        }
        // Not opened (package busy, notebook gone): the card beside the event comes back.
        if library?.opened?.id != id, selection == entry.id, let current = selectedEvent { showNote(for: current) }
    }

    // MARK: Lesson sections in the Lernfeld notebook

    /// A Lernfeld or Fach-Heft lesson without a section yet: offer to start one.
    func prepareStudyPrompt(for entry: CalendarEntry) -> Bool {
        guard linkByEntry[entry.id] == nil, let home = studyHome(for: entry) else { return false }
        noteState = .study(CalendarStudyPrompt(home: home, notebook: studyNotebookState(home.notebookID)))
        return true
    }

    /// A Fach-Heft lesson whose section exists: the card that opens the notebook
    /// (its editor never runs beside the event).
    func prepareSubjectPrompt(for entry: CalendarEntry, link: CalendarNoteLink) -> Bool {
        guard let subject = state.subjectNotebooks.first(where: { $0.notebookID == link.documentID }) else { return false }
        var prompt = CalendarStudyPrompt(home: .subject(subject), notebook: studyNotebookState(subject.notebookID))
        prompt.existingPage = link.pageID
        noteState = .study(prompt)
        return true
    }

    private func studyNotebookState(_ notebookID: UUID?) -> CalendarStudyPrompt.Notebook {
        guard let id = notebookID, let library, let item = library.snapshot.items.first(where: { $0.id == id }) else { return .none }
        return library.snapshot.isTrashed(id) ? .trashed(id, item.title) : .ready(item.title)
    }

    /// „Heft wiederherstellen“: the field's notebook back from the trash.
    func restoreStudyNotebook(_ id: UUID, for entry: CalendarEntry) async {
        await library?.restore(id)
        if selection == entry.id { noteState = .none; showNote(for: entry) }
    }

    /// „Mitschrift beginnen“: a heading page for the lesson block goes into
    /// the field's notebook (created at the library's top level when there
    /// is none yet, or – `replacingTrashed` – instead of one in the trash) at
    /// its chronological place, and the block links to it.
    func beginStudyNote(for entry: CalendarEntry, replacingTrashed: Bool = false) {
        let previous = noteQueue
        noteQueue = Task { [weak self] in
            await previous?.value
            await self?.createStudySection(for: entry, replacingTrashed: replacingTrashed)
        }
    }

    private func createStudySection(for entry: CalendarEntry, replacingTrashed: Bool) async {
        guard selection == entry.id, case .study(var prompt) = noteState else { return }
        guard let home = studyHome(for: entry), let library, library.ready, library.opened == nil, canWrite else { return }
        let anchor = studyAnchor(for: entry)
        guard let target = anchor.noteTarget else { return }
        if linkByEntry[entry.id] != nil { noteState = .none; showNote(for: entry); return }
        prompt.creating = true; prompt.failure = nil
        noteState = .study(prompt)
        func fail(_ text: String) {
            prompt.creating = false; prompt.failure = text
            if selection == entry.id { noteState = .study(prompt) }
        }

        let end = studyBlockEnd(for: entry)
        let heading = StudySections.heading(subject: anchor.subject ?? anchor.title, start: anchor.start, end: end,
                                            topic: topic(for: entry)?.topic ?? "", timeZone: schoolTimeZone)
        let restores = root.appendingPathComponent("Restores", isDirectory: true)
        let model: EditorModel, documentID: UUID, pageID: UUID, title: String
        var created = false
        let current = studyNotebookState(home.notebookID)
        if case .trashed = current, !replacingTrashed { fail(home.isSubject ? "Das Heft dieses Fachs liegt im Papierkorb." : "Das Heft dieses Lernfelds liegt im Papierkorb."); return }
        if case .ready = current, let id = home.notebookID, let item = library.snapshot.items.first(where: { $0.id == id }),
           let document = await library.openDocument(id) {
            documentID = id; title = item.title
            parked[id] = nil
            model = lingering.removeValue(forKey: id) ?? EditorModel(storageRoot: document.directory, restoreDirectory: restores, libraryTitle: item.title)
            guard await Self.waitUntilReady(model) else {
                if !(await model.flushBeforeClosing()) { lingering[id] = model }
                fail(model.error ?? "Das Heft „\(item.title)“ ist gerade nicht bearbeitbar. Es wurde nichts verändert.")
                return
            }
            // A heading of this block left by an earlier attempt is reused, never doubled.
            let linkedPages = Set(state.noteLinks.compactMap(\.pageID))
            if let existing = model.notebook.pages.first(where: { $0.textBoxes?.first?.text == heading && !linkedPages.contains($0.id) })?.id {
                pageID = existing
            } else {
                let sections = StudySections.sections(of: model.notebook, links: state.noteLinks, topics: state.lessonTopics)
                let index = StudySections.insertionIndex(for: anchor.start, in: model.notebook, sections: sections)
                guard let inserted = model.insertSectionPage(heading: heading, at: index) else {
                    if !(await model.flushBeforeClosing()) { lingering[id] = model }
                    fail(model.error ?? "Die Seite konnte nicht angelegt werden. Es wurde nichts verändert.")
                    return
                }
                pageID = inserted
            }
            // The page is saved before the lesson links to it.
            guard await model.waitForSave() else {
                if !(await model.flushBeforeClosing()) { lingering[id] = model }
                fail(model.saveBlocked ?? "Die neue Seite ist noch nicht gespeichert. Bitte erneut versuchen; es wird dieselbe Seite verwendet.")
                return
            }
        } else {
            // No usable notebook (none yet, deleted for good, unreadable, or one in the trash replaced on request).
            guard case .field(let field) = home else {
                // A Fach-Heft is always a notebook the user chose: never created here.
                fail("Das Heft dieses Fachs gibt es nicht mehr. Bitte ein anderes Heft wählen."); return
            }
            created = true
            if let pending = studyCreations[field.id] {
                documentID = pending.documentID; pageID = pending.pageID; title = pending.title
                model = lingering.removeValue(forKey: pending.documentID) ?? pending.model
            } else {
                documentID = UUID()
                title = NotebookTitles.unique(field.notebookTitle, taken: library.snapshot.activeNotebookTitles())
                var notebook = (try? Notebook.blank(title: title, appearance: defaultAppearance())) ?? Notebook.blank(title: title)
                notebook.id = documentID
                do {
                    pageID = try notebook.insertSectionPage(heading: heading, at: 0)
                    notebook.pages.removeAll { $0.id != pageID }
                    try notebook.validate()
                } catch { fail("Das Lernfeld-Heft konnte nicht vorbereitet werden: \(error.localizedDescription)"); return }
                model = EditorModel(storageRoot: library.newDocumentDirectory(documentID), restoreDirectory: restores, deferred: notebook)
                studyCreations[field.id] = CalendarStudyCreation(documentID: documentID, pageID: pageID, title: title, model: model)
            }
            guard await model.beginCommitting() else {
                fail(model.saveBlocked ?? "Das Lernfeld-Heft wurde noch nicht gespeichert. Bitte erneut versuchen.")
                return
            }
            do { try await library.adoptStudyNotebook(documentID, title: title) }
            catch {
                fail("Das Heft „\(title)“ ist gespeichert, aber noch nicht in der Bibliothek: \(CalendarNoteError.message(error)) Erneut versuchen verwendet dasselbe Heft.")
                return
            }
        }
        let link = CalendarNoteLink(target: target, documentID: documentID, pageID: pageID, hasContent: true,
                                    contextTitle: String((anchor.subject ?? anchor.title).prefix(300)),
                                    contextStart: anchor.start, contextEnd: end)
        let linked = await commit { state in
            if !state.noteLinks.contains(where: { $0.target == target && $0.documentID == documentID }) { state.noteLinks.append(link) }
            if created, case .field(let field) = home, let index = state.studyFields.firstIndex(where: { $0.id == field.id }) {
                state.studyFields[index].notebookID = documentID
            }
        }
        if created, case .field(let field) = home, state.studyFields.contains(where: { $0.id == field.id && $0.notebookID == documentID }) {
            studyCreations[field.id] = nil
        }
        if !linked {
            notice = "Die Seite in „\(title)“ ist angelegt, die Verknüpfung mit der Stunde aber noch nicht gespeichert (\(saveError ?? "")). noty versucht es weiter."
        }
        if home.isSubject {
            // Fach-Heft: the page is committed; the notebook opens full screen at it
            // (outside this queue: opening closes the note, which waits for the queue).
            guard await model.flushBeforeClosing() else {
                lingering[documentID] = model
                fail(model.saveBlocked ?? "Die neue Seite ist noch nicht gespeichert. Bitte erneut versuchen; es wird dieselbe Seite verwendet.")
                return
            }
            guard selection == entry.id else { return }
            Task { [weak self] in await self?.openNotebook(documentID, page: pageID, for: entry) }
            return
        }
        guard selection == entry.id else {
            if !(await model.flushBeforeClosing()) { lingering[documentID] = model }
            return
        }
        let session = CalendarNoteSession(entry: entry, target: target, documentID: documentID, title: title, model: model, phase: .saved,
                                          study: true)
        startStudySession(session)
        model.showPage(pageID)
    }

    /// The model has loaded its notebook and may be changed (≤ 20 s).
    static func waitUntilReady(_ model: EditorModel) async -> Bool {
        for _ in 0..<200 {
            if model.writable, !model.busy { return true }
            if !model.busy, !model.writable, model.documentLoaded || model.error != nil { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return model.writable && !model.busy
    }

    /// „Seite hinzufügen“ in a Lernfeld section: after the section's last page.
    func addStudyPage(_ session: CalendarNoteSession) -> Bool {
        guard session.study, session.model.writable else { return false }
        let sections = StudySections.sections(of: session.model.notebook, links: state.noteLinks)
        guard let section = StudySections.section(containing: session.model.page.id, in: sections)
                ?? sections.first(where: { $0.target == session.target }) else { return false }
        let defaults = session.model.notebook.pageDefaults
        session.model.insertPaper(defaults.paper, color: defaults.color, relativeTo: section.lastPageID)
        return true
    }

    /// The topic changed: a heading that still reads as generated follows.
    private func updateSectionHeading(for entry: CalendarEntry, oldTopic: String, newTopic: String) {
        guard let session = noteSession, session.study, session.model.writable,
              let link = linkByEntry[entry.id], link.documentID == session.documentID, let page = link.pageID,
              let box = session.model.notebook.pages.first(where: { $0.id == page })?.textBoxes?.first else { return }
        let base = StudySections.heading(subject: link.contextTitle, start: link.contextStart, end: link.contextEnd, topic: "",
                                         timeZone: schoolTimeZone)
        let expected = oldTopic.isEmpty ? base : StudySections.heading(subject: link.contextTitle, start: link.contextStart,
                                                                      end: link.contextEnd, topic: oldTopic, timeZone: schoolTimeZone)
        guard box.text == expected else { return }
        var changed = box
        changed.text = StudySections.heading(subject: link.contextTitle, start: link.contextStart, end: link.contextEnd,
                                             topic: newTopic, timeZone: schoolTimeZone)
        changed.height = max(box.height, Notebook.sectionHeadingHeight(changed.text, width: box.width, fontSize: box.style.fontSize))
        session.model.replaceFirstTextBox(changed, pageID: page)
    }

    /// Sections of a Lernfeld or Fach-Heft notebook for its page list („Inhalt“).
    func studySections(of notebook: Notebook) -> [StudySection] {
        guard state.studyFields.contains(where: { $0.notebookID == notebook.id }) || isSubjectNotebook(notebook.id) else { return [] }
        return StudySections.sections(of: notebook, links: state.noteLinks, topics: state.lessonTopics)
    }
}
