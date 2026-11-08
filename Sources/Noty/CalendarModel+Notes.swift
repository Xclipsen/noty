import SwiftUI
import UIKit
import Combine
import NotebookCore

// Notes beside an event (Stufe B2): the event's note is an ordinary
// notebook of the area's library (`CalendarNoteSession`). Moved out of
// CalendarModel.swift unchanged.

extension CalendarModel {
    // MARK: Notes beside the event

    /// Indicator: a linked notebook with real content that is still in the
    /// library. An opened empty page shows nothing.
    func hasNotes(_ event: CalendarEntry) -> Bool {
        if event.isSample { return !event.samplePages.isEmpty }
        guard let link = linkByEntry[event.id], link.hasContent else { return false }
        guard let library else { return true }
        return library.snapshot.items.contains { $0.id == link.documentID } && !library.snapshot.isTrashed(link.documentID)
    }

    func link(for entry: CalendarEntry) -> CalendarNoteLink? { linkByEntry[entry.id] }

    func selectionChanged() {
        guard visible else { return }
        if let entry = selectedEvent { showNote(for: entry) } else { releaseNote() }
    }

    /// Opens the note area of `entry` (after the previous one is committed
    /// and closed). Serialized: a late close never overlaps a new open.
    func showNote(for entry: CalendarEntry) {
        let previous = noteQueue
        noteQueue = Task { [weak self] in
            await previous?.value
            await self?.prepareNote(for: entry)
        }
    }

    /// Calendar hidden, nothing selected or the library opens a notebook.
    func releaseNote() {
        let previous = noteQueue
        noteQueue = Task { [weak self] in
            await previous?.value
            await self?.closeNoteSession()
        }
    }

    /// For the library: commits and closes the note before it opens a notebook.
    /// False while a note's changes are still only in memory (kept and
    /// retried; the caller must not drop this model then).
    @discardableResult
    func closeNote() async -> Bool {
        releaseNote()
        await noteQueue?.value
        return lingering.isEmpty
    }

    /// Area switch (the switch disposes this model and everything it keeps
    /// in memory): commits and closes the note, resumes notes not created
    /// yet, retries notes not saved yet and an unsaved calendar change. Nil:
    /// nothing is only in memory any more; otherwise what would be lost
    /// (the switch then needs `discardUnsavedForAreaSwitch()` explicitly).
    func prepareAreaSwitch() async -> String? {
        await closeNote()
        await retryLingering(resumingCreations: true)
        // A commit still running finishes first.
        await mutations.acquire(); mutations.release()
        if unsaved { await retrySave() }
        var parts: [String] = []
        let titles = lingering.values.map { $0.notebook.title.isEmpty ? "Notiz" : "„\($0.notebook.title)“" }.sorted()
        if !titles.isEmpty {
            parts.append((titles.count == 1 ? "Die Kalendernotiz \(titles[0]) ist" : "Die Kalendernotizen \(titles.joined(separator: ", ")) sind")
                         + " noch nicht gespeichert (zum Beispiel weil ein Import noch läuft oder das Speichern fehlschlägt).")
        }
        if unsaved {
            parts.append("Die letzte Kalenderänderung ist noch nicht gespeichert. \(saveError ?? "")")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// The user chose to switch the area anyway: the notes and calendar
    /// changes that exist only in memory are let go explicitly.
    func discardUnsavedForAreaSwitch() {
        for model in lingering.values { model.abandonUnsavedChanges() }
        lingering = [:]
        parked = [:]
        creations = [:]
        unsaved = false
        saveError = nil
    }

    /// The app leaves the foreground: a note that has content but no
    /// notebook yet (its 400 ms input pause has not passed, or input kept
    /// resetting it) is created and committed now, and every running
    /// creation is protected by background time until it finished. Saved
    /// notes save themselves (`EditorModel.save`, own background time).
    func sceneLeftForeground() {
        var runs: [CalendarNoteSession] = []
        if let session = noteSession, session.phase != .saved {
            if session.phase != .creating, EditorModel.hasContent(session.model.notebook) || !session.model.deferredCommit {
                continueCreation(session)
            }
            if session.phase == .creating { runs.append(session) }
        }
        for (id, session) in parked where lingering[id] != nil && session.model.deferredCommit && session.phase != .saved {
            if session.phase != .creating { continueCreation(session) }
            if session.phase == .creating { runs.append(session) }
        }
        guard !runs.isEmpty else { return }
        let background = CalendarBackgroundTask(name: "noty-calendar-note")
        Task {
            for session in runs { await session.creation?.value }
            // A note created from the parked list commits its newest state and lets go.
            await retryLingering()
            background.end()
        }
    }

    private func prepareNote(for entry: CalendarEntry) async {
        if let session = noteSession, session.entryID == entry.id { return }
        await closeNoteSession()
        guard selection == entry.id else { return }
        guard !entry.isSample else { noteState = .sample; return }
        guard let target = entry.noteTarget ?? linkByEntry[entry.id]?.target else {
            noteState = .unavailable("Für diesen Eintrag gibt es keine Notizen.")
            return
        }
        guard let library, library.ready else { noteState = .unavailable("Die Bibliothek wird noch geladen."); return }
        guard library.opened == nil else { noteState = .unavailable("Die Notiz ist im Editor geöffnet."); return }
        guard canWrite else { noteState = .unavailable(storageError ?? "Der Kalender ist noch nicht geladen."); return }
        let restores = root.appendingPathComponent("Restores", isDirectory: true)
        if let link = linkByEntry[entry.id] {
            guard let item = library.snapshot.items.first(where: { $0.id == link.documentID }) else {
                noteState = .missing(.deleted, link); return
            }
            if library.snapshot.isTrashed(item.id) { noteState = .missing(.trashed(item.title), link); return }
            guard let document = await library.openDocument(item.id) else { noteState = .missing(.deleted, link); return }
            parked[item.id] = nil
            let model = lingering.removeValue(forKey: item.id)
                ?? EditorModel(storageRoot: document.directory, restoreDirectory: restores, libraryTitle: item.title)
            start(CalendarNoteSession(entry: entry, target: link.target, documentID: item.id, title: item.title, model: model, phase: .saved))
            return
        }
        // A note whose creation stopped: the same document again, never a second one.
        if let creation = creations[target.key] {
            let committed = await creation.stage >= .notebookCommitted
            parked[creation.documentID] = nil
            if let model = lingering.removeValue(forKey: creation.documentID)
                ?? (committed ? EditorModel(storageRoot: library.newDocumentDirectory(creation.documentID), restoreDirectory: restores) : nil) {
                let session = CalendarNoteSession(entry: entry, target: target, documentID: creation.documentID,
                                                  title: model.notebook.title.isEmpty ? noteTitle(for: entry) : model.notebook.title,
                                                  model: model, phase: .failed("Noch nicht fertig angelegt."))
                start(session)
                continueCreation(session)
                return
            }
            // Nothing of it exists anywhere: start afresh.
            creations[target.key] = nil
        }
        let id = UUID()
        let title = noteTitle(for: entry)
        var notebook = (try? Notebook.blank(title: title, appearance: defaultAppearance())) ?? Notebook.blank(title: title)
        notebook.id = id
        let model = EditorModel(storageRoot: library.newDocumentDirectory(id), restoreDirectory: restores, deferred: notebook)
        start(CalendarNoteSession(entry: entry, target: target, documentID: id, title: title, model: model, phase: .draft))
    }

    private func noteTitle(for entry: CalendarEntry) -> String {
        let day = entry.originalDate ?? CivilDate(entry.start, calendar: calendar)
        let taken = library?.snapshot.activeNotebookTitles() ?? []
        return CalendarNotesFolder.noteTitle(subject: entry.subject ?? entry.title, date: day, taken: taken)
    }

    private func start(_ session: CalendarNoteSession) {
        noteSession = session
        noteState = .session(session)
        session.observe { [weak self, weak session] notebook in
            guard let self, let session else { return }
            self.noteChanged(session, notebook: notebook)
        }
    }

    private func noteChanged(_ session: CalendarNoteSession, notebook: Notebook) {
        let content = EditorModel.hasContent(notebook)
        switch session.phase {
        case .draft:
            // First real input: create the notebook, then link it (rule 8).
            if content { continueCreation(session) }
        case .saved:
            if let index = state.noteLinks.firstIndex(where: { $0.documentID == session.documentID && $0.target == session.target }),
               state.noteLinks[index].hasContent != content {
                Task { await commit { if let i = $0.noteLinks.firstIndex(where: { $0.documentID == session.documentID && $0.target == session.target }) { $0.noteLinks[i].hasContent = content } } }
            }
        case .creating, .failed: break
        }
    }

    /// Runs (or resumes) rule 8 for the session's note. Input meanwhile goes
    /// into the same model and its next autosave; nothing is created twice.
    func continueCreation(_ session: CalendarNoteSession) {
        guard session.phase != .creating, session.phase != .saved, let library else { return }
        let key = session.target.key
        let creation = creations[key] ?? CalendarNoteCreation(documentID: session.documentID, target: session.target)
        guard creation.documentID == session.documentID else { return }
        creations[key] = creation
        session.phase = .creating
        let model = session.model, entry = session.entry
        let documentID = session.documentID, title = session.title, target = session.target
        let pageID = model.notebook.pages.first?.id
        let folder = CalendarFolderBox()
        session.creation = Task { [weak self] in
            do {
                try await creation.run(commitNotebook: { @MainActor in
                    guard await model.beginCommitting() else {
                        throw CalendarNoteError.notSaved(model.saveBlocked ?? "Die Notiz wurde noch nicht gespeichert; noty versucht es weiter.")
                    }
                }, addToLibrary: { @MainActor [weak self] in
                    folder.id = try await library.adoptCalendarNote(documentID, title: title, folder: self?.state.settings.notesFolderID)
                }, link: { @MainActor [weak self] in
                    guard let self else { throw CalendarNoteError.closed }
                    let link = CalendarNoteLink(target: target, documentID: documentID, pageID: pageID, hasContent: true,
                                                contextTitle: String(entry.title.prefix(300)), contextStart: entry.start, contextEnd: entry.end)
                    let usedFolder = folder.id ?? CalendarNotesFolder.usable(self.state.settings.notesFolderID, in: library.snapshot)
                    let ok = await self.commit { state in
                        if !state.noteLinks.contains(where: { $0.target == target && $0.documentID == documentID }) { state.noteLinks.append(link) }
                        if let usedFolder { state.settings.notesFolderID = usedFolder }
                    }
                    guard ok else { throw CalendarNoteError.linkNotSaved(self.saveError ?? "") }
                })
                session.phase = .saved
                self?.creations[key] = nil
            } catch {
                session.phase = .failed(CalendarNoteError.message(error))
            }
        }
    }

    private func closeNoteSession() async {
        noteState = .none
        enlargedDraft = nil
        guard let session = noteSession else { await retryLingering(); return }
        noteSession = nil
        session.stopObserving()
        let model = session.model
        // Written just before switching (the debounce had not fired yet): create it now.
        if session.phase == .draft, EditorModel.hasContent(model.notebook) { continueCreation(session) }
        await session.creation?.value
        if model.deferredCommit {
            // Never committed: an empty page leaves nothing behind. Written
            // content that could not be committed stays in memory and is
            // shown again with this event (same document, no second one).
            if EditorModel.hasContent(model.notebook) {
                lingering[session.documentID] = model
                parked[session.documentID] = session
                notice = "Die Notiz zu „\(session.entry.title)“ ist noch nicht gespeichert. Bitte den Termin erneut öffnen."
            }
        } else {
            if case .failed = session.phase {
                notice = "Die Notiz zu „\(session.entry.title)“ liegt in „Kalendernotizen“, ist aber noch nicht fertig mit dem Termin verknüpft. Beim nächsten Öffnen des Termins wird es erneut versucht."
            }
            if !(await model.flushBeforeClosing()) {
                lingering[session.documentID] = model
                notice = "Die Notiz zu „\(session.entry.title)“ konnte noch nicht gespeichert werden; noty versucht es weiter."
            }
        }
        await retryLingering()
    }

    /// `resumingCreations`: notes without a notebook yet run their creation
    /// again first (area switch; not on every note change, where a blocked
    /// package would make each switch wait).
    private func retryLingering(resumingCreations: Bool = false) async {
        if resumingCreations {
            for (id, session) in parked where lingering[id] != nil && session.model.deferredCommit && session.phase != .creating {
                continueCreation(session)
                await session.creation?.value
            }
        }
        for (id, model) in lingering where !model.deferredCommit {
            if await model.flushBeforeClosing() { lingering[id] = nil; parked[id] = nil }
        }
    }

    /// The library changed (trash, restore, rename): the note follows.
    func libraryChanged() {
        objectWillChange.send()
        guard let session = noteSession, let library else { return }
        let gone = session.phase == .saved && (!library.snapshot.items.contains { $0.id == session.documentID } || library.snapshot.isTrashed(session.documentID))
        if gone, let entry = selectedEvent {
            releaseNote()
            showNote(for: entry)
        }
    }

    /// „Vergrößern“: a saved note opens in the normal editor (the library's
    /// full-screen path) with „Zurück zu <Termin> · <Datum>“; a note that
    /// has no notebook yet is shown large over the calendar.
    func enlarge(_ entry: CalendarEntry) {
        guard let session = noteSession, session.entryID == entry.id else { return }
        if session.model.deferredCommit || session.phase == .creating { enlargedDraft = session; return }
        let id = session.documentID, page = session.model.page.id
        let back = "\(entry.title) · \(CalendarText.shortDate(entry.start, calendar: calendar))"
        Task {
            await closeNote()
            guard let library, let item = library.snapshot.items.first(where: { $0.id == id }), !library.snapshot.isTrashed(id) else { return }
            await library.open(item, pageID: page, returnTitle: back)
        }
    }

    /// Restores a trashed note from the library's trash.
    func restoreNote(_ link: CalendarNoteLink) async {
        await library?.restore(link.documentID)
        if let entry = selectedEvent { showNote(for: entry) }
    }

    /// Removes only the link; the notebook stays in the library.
    func unlink(_ link: CalendarNoteLink) async {
        await commit { $0.noteLinks.removeAll { $0.id == link.id } }
        if let entry = selectedEvent { noteState = .none; showNote(for: entry) }
    }

    /// Links an existing notebook of „Kalendernotizen“ again (after a failed
    /// link or a removed one). The notebook itself is not changed.
    func relink(_ entry: CalendarEntry, to item: NotebookCore.LibraryItem) async {
        guard let target = entry.noteTarget, linkByEntry[entry.id] == nil else { return }
        if let session = noteSession, session.entryID == entry.id, session.phase != .draft || EditorModel.hasContent(session.model.notebook) { return }
        await closeNote()
        let link = CalendarNoteLink(target: target, documentID: item.id, hasContent: true, contextTitle: String(entry.title.prefix(300)),
                                    contextStart: entry.start, contextEnd: entry.end)
        await commit { $0.noteLinks.append(link) }
        showNote(for: entry)
    }

    /// Notebooks of the notes folder that no link of this calendar uses.
    var unlinkedNotebooks: [NotebookCore.LibraryItem] {
        guard let library else { return [] }
        let used = Set(state.noteLinks.map(\.documentID))
        return library.calendarNotebooks(in: state.settings.notesFolderID).filter { !used.contains($0.id) }
    }

    /// Page flip and „Seite hinzufügen“ beside the event (the editor's own model).
    func addNotePage() {
        guard let model = noteSession?.model, model.writable, let last = model.notebook.pages.last else { return }
        let defaults = model.notebook.pageDefaults
        model.insertPaper(defaults.paper, color: defaults.color, relativeTo: last.id)
        model.pageIndex = model.notebook.pages.count - 1
    }
}

/// Background execution time for a note's creation (as the editor's own
/// `BackgroundSaveTask`): iOS may otherwise suspend the app in between.
@MainActor private final class CalendarBackgroundTask {
    private var identifier = UIBackgroundTaskIdentifier.invalid
    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }
    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

/// The folder the library step used, handed to the link step.
@MainActor private final class CalendarFolderBox { var id: UUID? }

enum CalendarNoteError: Error, LocalizedError {
    case notSaved(String)
    case linkNotSaved(String)
    case closed
    var errorDescription: String? {
        switch self {
        case .notSaved(let reason): "Die Notiz ist noch nicht gespeichert: \(reason)"
        case .linkNotSaved(let reason): "Die Notiz liegt in „Kalendernotizen“, die Verknüpfung mit dem Termin ist aber noch nicht gespeichert. \(reason)"
        case .closed: "Der Kalender wurde geschlossen."
        }
    }
    static func message(_ error: Error) -> String {
        if let error = error as? LocalizedError, let text = error.errorDescription { return text }
        return error.localizedDescription
    }
}

/// What the note area beside an event shows.
enum CalendarNoteState {
    enum Missing: Equatable { case trashed(String), deleted }
    case none
    case sample
    case unavailable(String)
    case missing(Missing, CalendarNoteLink)
    case session(CalendarNoteSession)
}

/// The note of one event while it is shown: the normal editor model of its
/// notebook (or of the not yet created one). One at a time; a new event gets
/// a new session and a new editor view, so late callbacks of the previous
/// canvas can only reach the previous notebook's model.
@MainActor
final class CalendarNoteSession: ObservableObject, Identifiable {
    enum Phase: Equatable {
        /// Only in memory: nothing written yet.
        case draft
        case creating
        case saved
        case failed(String)
    }
    let id = UUID()
    let entry: CalendarEntry
    var entryID: String { entry.id }
    let target: CalendarNoteTarget
    let documentID: UUID
    let title: String
    let model: EditorModel
    @Published var phase: Phase
    var creation: Task<Void, Never>?
    private var observer: AnyCancellable?

    init(entry: CalendarEntry, target: CalendarNoteTarget, documentID: UUID, title: String, model: EditorModel, phase: Phase) {
        self.entry = entry; self.target = target; self.documentID = documentID; self.title = title; self.model = model; self.phase = phase
    }

    func observe(_ changed: @escaping @MainActor (Notebook) -> Void) {
        observer = model.$notebook.dropFirst()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { notebook in MainActor.assumeIsolated { changed(notebook) } }
    }
    func stopObserving() { observer = nil }
}
