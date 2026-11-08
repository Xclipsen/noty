import SwiftUI
import NotebookCore

// MARK: Notes

/// The note area of the event window: the normal noty editor on the event's
/// notebook – or the not yet saved page of a new note, writable at once –
/// edge to edge on the editor's own dark backdrop. Its controls (page flip,
/// „Neue Seite“, „Vergrößern“ as the editor's leading button) are the
/// editor's; other states show one calm message on the same backdrop.
struct CalendarNoteArea: View {
    let event: CalendarEntry
    @ObservedObject var model: CalendarModel

    var body: some View {
        ZStack {
            Color(uiColor: NotebookViewport.backdrop)
            switch model.noteState {
            case .session(let session) where session.entryID == event.id:
                if model.enlargedDraft === session {
                    message(symbol: "arrow.up.left.and.arrow.down.right", title: "Die Notiz ist groß geöffnet.")
                } else {
                    ContentView(model: session.model, isLibraryDocument: true,
                                onCloseWorkspace: { model.enlarge(event) },
                                embedded: true, closeTitle: "Vergrößern", closeSymbol: "arrow.up.left.and.arrow.down.right")
                        // A new view per note: late callbacks never reach another event's notebook.
                        .id(session.id)
                }
            case .missing(let reason, let link):
                missing(reason, link: link)
            case .study(let prompt):
                CalendarStudyPromptView(event: event, prompt: prompt, model: model)
            case .unavailable(let text):
                message(symbol: "note.text", title: text)
            case .sample:
                CalendarSampleNote(pages: event.samplePages)
            default:
                // Most notes open at once: the wait shows only after 300 ms, in words.
                CalendarDelayedProgress(text: "Notiz wird geöffnet …", large: true)
            }
        }
        .task(id: event.id) { model.showNote(for: event) }
    }

    private func message(symbol: String, title: String, text: String? = nil) -> some View {
        message(symbol: symbol, title: title, text: text) { EmptyView() }
    }

    /// Symbol, title, explanation and the actions, centred on the backdrop.
    private func message<Actions: View>(symbol: String, title: String, text: String?, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: CalendarSpace.s) {
            Image(systemName: symbol).font(.system(size: 30, weight: .regular)).foregroundStyle(.secondary)
                .padding(.bottom, CalendarSpace.xs)
                .accessibilityHidden(true)
            VStack(spacing: CalendarSpace.s) {
                Text(title).font(.headline)
                if let text {
                    Text(text).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            VStack(spacing: CalendarSpace.s) { actions() }
                .padding(.top, CalendarSpace.m)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 380)
        .padding(CalendarSpace.xl)
    }

    /// Trash or permanently deleted: explained, never a same-named notebook.
    @ViewBuilder private func missing(_ reason: CalendarNoteState.Missing, link: CalendarNoteLink) -> some View {
        switch reason {
        case .trashed(let title):
            message(symbol: "trash", title: "Die Notiz „\(title)“ liegt im Papierkorb.",
                    text: "Wiederherstellen zeigt sie hier wieder. „Verknüpfung lösen“ lässt sie im Papierkorb und gibt die Fläche für eine neue Notiz frei.") {
                Button("Wiederherstellen") { Task { await model.restoreNote(link) } }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                unlinkButton(link)
            }
        case .deleted:
            message(symbol: "questionmark.folder", title: "Die verknüpfte Notiz wurde endgültig gelöscht.",
                    text: "noty öffnet dafür kein anderes Heft, auch kein gleichnamiges. „Verknüpfung lösen“ gibt die Fläche für eine neue Notiz frei.") {
                unlinkButton(link)
            }
        }
    }

    private func unlinkButton(_ link: CalendarNoteLink) -> some View {
        Button("Verknüpfung lösen", role: .destructive) { Task { await model.unlink(link) } }
            .buttonStyle(.bordered).controlSize(.large)
    }
}

/// The note's state in the window head, in words (never „gespeichert“
/// before the commit and the link); icon only where the head is narrow.
struct CalendarNoteStatus: View {
    let event: CalendarEntry
    @ObservedObject var model: CalendarModel

    var body: some View {
        if case .session(let session) = model.noteState, session.entryID == event.id {
            CalendarNoteStatusLabel(session: session, editor: session.model, model: model)
        }
    }
}

private struct CalendarNoteStatusLabel: View {
    @ObservedObject var session: CalendarNoteSession
    @ObservedObject var editor: EditorModel
    @ObservedObject var model: CalendarModel

    var body: some View {
        switch session.phase {
        case .failed(let reason):
            // A failure always keeps its words and the retry.
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(reason).font(.caption).lineLimit(2)
                Button("Erneut") { model.continueCreation(session) }
                    .font(.caption.weight(.semibold)).buttonStyle(.bordered).controlSize(.small)
            }
            .frame(maxWidth: 280)
            .accessibilityElement(children: .combine)
        default:
            let info = content
            ViewThatFits(in: .horizontal) {
                Label(info.text, systemImage: info.symbol).lineLimit(1)
                Image(systemName: info.symbol).frame(width: 28, height: 28)
            }
            .font(.caption).foregroundStyle(info.warn ? Color.orange : .secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(info.text)
            .help(info.text)
        }
    }

    private var content: (symbol: String, text: String, warn: Bool) {
        switch session.phase {
        case .draft: ("pencil.tip", "Schreiben legt die Notiz an", false)
        case .creating: ("arrow.triangle.2.circlepath", "Wird angelegt …", false)
        default:
            editor.saveFailed
                ? ("exclamationmark.triangle.fill", "Nicht gespeichert", true)
                : session.study ? ("book.pages", "In „\(session.title)“", false) : ("folder", "In „Kalendernotizen“", false)
        }
    }
}

/// The note's entries of the head menu: Vergrößern, Seite hinzufügen and –
/// for an empty new note – linking an existing one again.
struct CalendarNoteMenuItems: View {
    @ObservedObject var session: CalendarNoteSession
    @ObservedObject var editor: EditorModel
    @ObservedObject var model: CalendarModel
    let event: CalendarEntry

    var body: some View {
        Section("Notiz") {
            Button { model.enlarge(event) } label: {
                Label("Vergrößern", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            Button { model.addNotePage() } label: {
                Label("Seite hinzufügen", systemImage: "plus.rectangle.portrait")
            }
            .disabled(!editor.writable || editor.notebook.pages.count >= 500)
            if session.phase == .draft, !EditorModel.hasContent(editor.notebook), !model.unlinkedNotebooks.isEmpty {
                Menu {
                    ForEach(model.unlinkedNotebooks.prefix(30)) { item in
                        Button(item.title) { Task { await model.relink(event, to: item) } }
                    }
                } label: {
                    Label("Vorhandene Notiz verknüpfen", systemImage: "link")
                }
            }
        }
    }
}

/// Demo mode: the fictitious note, read only.
struct CalendarSampleNote: View {
    let pages: [String]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CalendarSpace.m) {
                if pages.isEmpty {
                    Text("Im Beispielmodus wird keine Notiz angelegt.").foregroundStyle(.secondary)
                }
                ForEach(pages.indices, id: \.self) { index in
                    Text(pages[index]).font(.body).foregroundStyle(Color.black)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(CalendarSpace.l)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 4))
                }
                Text("Beispiel · wird nicht gespeichert").font(.caption2).foregroundStyle(CalendarPalette.quiet)
            }
            .padding(CalendarSpace.s)
        }
    }
}

/// A note without a notebook yet, shown large over the calendar (the same
/// editor model; its first input creates the notebook as beside the event).
struct CalendarEnlargedDraft: View {
    @ObservedObject var session: CalendarNoteSession
    @ObservedObject var model: CalendarModel

    var body: some View {
        ContentView(model: session.model, isLibraryDocument: true, onCloseWorkspace: { model.enlargedDraft = nil },
                    closeTitle: "Zurück zu \(session.entry.title) · \(CalendarText.shortDate(session.entry.start, calendar: model.calendar))")
            .id(session.id)
    }
}
