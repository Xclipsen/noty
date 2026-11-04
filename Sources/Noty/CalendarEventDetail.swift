import SwiftUI
import NotebookCore

/// Termindetails: a minimal head (Titel, Datum/Uhrzeit, Kalender, Ort),
/// only the rows that have content, then „Notizen“: the event's note as a
/// real noty page (the normal editor, `ContentView` embedded) as the main
/// element. `overlay`: large view over the calendar in narrow windows, with
/// a clear way back.
struct CalendarEventPanel: View {
    let event: CalendarEntry
    @ObservedObject var model: CalendarModel
    var overlay = false
    /// Esc closes the panel only while nothing is presented over the calendar.
    var escapes = true
    @State private var confirmingRemoval = false
    @State private var detailsHeight: CGFloat = 160
    private var calendar: Calendar { model.calendar }

    var body: some View {
        VStack(spacing: 0) {
            bar
            GeometryReader { geo in
                // Wide overlay: details beside the page; otherwise stacked.
                if overlay && geo.size.width >= 760 {
                    HStack(alignment: .top, spacing: 0) {
                        ScrollView { details.padding(CalendarSpace.xl) }.frame(width: 320)
                        Rectangle().fill(CalendarPalette.hairline).frame(width: 0.5)
                        CalendarNoteArea(event: event, model: model).padding(CalendarSpace.s)
                    }
                } else {
                    VStack(spacing: 0) {
                        // As tall as the details, at most a quarter: the page keeps the room.
                        ScrollView {
                            details.padding(.horizontal, CalendarSpace.l).padding(.bottom, CalendarSpace.m)
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { detailsHeight = $0 }
                        }
                        .frame(height: min(detailsHeight, max(110, geo.size.height * 0.26)))
                        Rectangle().fill(CalendarPalette.hairline).frame(height: 0.5)
                        CalendarNoteArea(event: event, model: model).padding(.horizontal, CalendarSpace.xs).padding(.top, CalendarSpace.xs)
                    }
                }
            }
        }
        .background(Color(uiColor: .systemBackground))
        .confirmationDialog("Termin löschen?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            if event.originalDate != nil {
                Button("Nur diesen Termin löschen", role: .destructive) { Task { await model.remove(event, scope: .single) } }
                Button("Alle Termine der Serie löschen", role: .destructive) { Task { await model.remove(event, scope: .all) } }
            } else {
                Button("Termin löschen", role: .destructive) { Task { await model.remove(event) } }
            }
        } message: {
            Text(event.originalDate != nil
                 ? "„\(event.title)“ wiederholt sich. Gelöschtes lässt sich unter „…“ › „Gelöschte Termine“ wiederherstellen; Notizen bleiben in „Kalendernotizen“ erhalten."
                 : "„\(event.title)“ kommt in „Gelöschte Termine“ (Menü „…“) und lässt sich dort wiederherstellen. Notizen bleiben in „Kalendernotizen“ erhalten.")
        }
    }

    /// Back/close and one menu with Bearbeiten/Löschen (own entries) or the
    /// subject colour (lessons).
    private var bar: some View {
        HStack(spacing: 0) {
            if overlay {
                Button { model.selection = nil } label: {
                    Label("Kalender", systemImage: "chevron.backward").font(.body.weight(.medium))
                        .padding(.horizontal, CalendarSpace.xs)
                        .frame(minHeight: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Zurück zum Kalender")
                .keyboardShortcut(escapes ? .cancelAction : nil)
            }
            Spacer()
            if event.writable {
                Menu {
                    Button { model.draft = model.editDraft(for: event) } label: {
                        Label("Bearbeiten", systemImage: "pencil")
                    }
                    Button(role: .destructive) { confirmingRemoval = true } label: {
                        Label("Löschen", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.body).frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Termin bearbeiten oder löschen")
            } else if let key = event.subjectKey, !event.isSample, model.canWrite {
                Menu {
                    CalendarColorPicker(key: key, model: model)
                } label: {
                    Image(systemName: "paintpalette").font(.body).frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Fachfarbe von \(event.subject ?? event.title)")
            }
            if !overlay {
                Button { model.selection = nil } label: {
                    Image(systemName: "xmark").font(.body.weight(.medium)).foregroundStyle(.secondary)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Details schließen")
                .keyboardShortcut(escapes ? .cancelAction : nil)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, CalendarSpace.xs)
    }

    // MARK: Details

    private var details: some View {
        VStack(alignment: .leading, spacing: CalendarSpace.s) {
            Text(event.title).font(.title3.weight(.semibold)).strikethrough(event.status == .cancelled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 3) {
                Text(CalendarText.longDate(event.start, calendar: calendar) + " · " + event.timeText(calendar)).monospacedDigit()
                if let place = [event.room, event.teacher].compactMap({ $0 }).joined(separator: " · ").nilIfEmpty {
                    Text(place)
                }
                HStack(spacing: 6) {
                    Circle().fill(CalendarPalette.color(event)).frame(width: 7, height: 7)
                    Text("\(event.source.title) · \(event.originText)")
                    if event.source.readOnly { Image(systemName: "lock").font(.caption2).accessibilityLabel("schreibgeschützt") }
                }
                .accessibilityElement(children: .combine)
            }
            .font(.subheadline).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if let label = event.status.label, let symbol = event.status.symbol {
                Label(statusText(label), systemImage: symbol)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(event.status == .cancelled ? Color.orange : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(event.statusNotes, id: \.self) { note in
                Text(note).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if event.ghostLinkID != nil { assignment }
            // Only rows with content; „keine Erinnerung“ is not shown.
            if event.repeatText != nil || event.reminder != nil {
                VStack(alignment: .leading, spacing: 3) {
                    if let text = event.repeatText { Label(text, systemImage: "repeat") }
                    if let text = event.reminder { Label(text, systemImage: "bell") }
                }
                .font(.footnote).foregroundStyle(.secondary).labelStyle(CalendarCompactLabelStyle())
            }
            if let text = event.details {
                Text(text).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// „Ungeklärt“: the user may give the note to a lesson of the same course.
    @ViewBuilder private var assignment: some View {
        let options = event.ghostLinkID.flatMap { model.candidates[$0] } ?? []
        if !options.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Gehört die Notiz zu einer dieser Stunden desselben Kurses?").font(.footnote.weight(.semibold))
                ForEach(options.prefix(6), id: \.id) { lesson in
                    Button {
                        Task { await model.assign(event, to: lesson) }
                    } label: {
                        Text("\(CalendarText.shortDate(lesson.start, calendar: calendar)) · \(CalendarText.timeRange(lesson.start, lesson.end, calendar: calendar)) · \(lesson.title)")
                            .font(.footnote).monospacedDigit().frame(minHeight: 32, alignment: .leading)
                    }
                    .buttonStyle(.borderless)
                }
                Text("noty ordnet nie anhand gleicher Titel zu; ohne Auswahl bleibt die Notiz hier erreichbar.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func statusText(_ label: String) -> String {
        if let note = event.status.note { return "\(label): \(note)" }
        return label
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Small icon + text with tight spacing for metadata rows.
struct CalendarCompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.frame(width: 16)
            configuration.title
        }
    }
}

/// „Automatisch“ plus the named subject colours.
struct CalendarColorPicker: View {
    let key: String
    @ObservedObject var model: CalendarModel

    var body: some View {
        let chosen = model.subjectColors[key]
        Picker("Fachfarbe", selection: Binding<String>(get: { chosen ?? "" }, set: { model.setSubjectColor(key, to: $0.isEmpty ? nil : $0) })) {
            Label("Automatisch (\(CalendarSubjectColor.title(CalendarSubjectColor.name(for: key, chosen: [:]))))", systemImage: "wand.and.stars").tag("")
            ForEach(CalendarSubjectColor.choosable, id: \.self) { name in
                Label {
                    Text(CalendarSubjectColor.title(name))
                } icon: {
                    Image(systemName: "circle.fill").foregroundStyle(CalendarPalette.color(named: name))
                }
                .tag(name)
            }
        }
        .pickerStyle(.inline)
    }
}

// MARK: Notes

/// The note area beside an event: one quiet row (state, pages, add page,
/// more) and the note itself – the normal noty editor on the event's
/// notebook, or the not yet saved page of a new note.
struct CalendarNoteArea: View {
    let event: CalendarEntry
    @ObservedObject var model: CalendarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch model.noteState {
            case .session(let session) where session.entryID == event.id:
                CalendarNoteControls(session: session, editor: session.model, model: model, event: event)
                if model.enlargedDraft === session {
                    placeholder("Die Notiz ist groß geöffnet.", symbol: "arrow.up.left.and.arrow.down.right")
                } else {
                    ContentView(model: session.model, isLibraryDocument: true,
                                onCloseWorkspace: { model.enlarge(event) },
                                embedded: true, closeTitle: "Vergrößern", closeSymbol: "arrow.up.left.and.arrow.down.right")
                        // A new view per note: late callbacks never reach another event's notebook.
                        .id(session.id)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            case .missing(let reason, let link):
                header
                missing(reason, link: link)
            case .unavailable(let text):
                header
                placeholder(text, symbol: "note.text")
            case .sample:
                header
                CalendarSampleNote(pages: event.samplePages)
            default:
                header
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: event.id) { model.showNote(for: event) }
    }

    private var header: some View {
        Text("Notizen").font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
            .frame(minHeight: 36).padding(.horizontal, CalendarSpace.s)
    }

    private func placeholder(_ text: String, symbol: String) -> some View {
        VStack(spacing: CalendarSpace.s) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.secondary)
            Text(text).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(CalendarSpace.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Trash or permanently deleted: explained, never a same-named notebook.
    private func missing(_ reason: CalendarNoteState.Missing, link: CalendarNoteLink) -> some View {
        VStack(spacing: CalendarSpace.m) {
            Image(systemName: reason == .deleted ? "questionmark.folder" : "trash").font(.title2).foregroundStyle(.secondary)
            switch reason {
            case .trashed(let title):
                Text("Die Notiz „\(title)“ liegt im Papierkorb.").font(.subheadline.weight(.semibold))
                Text("Wiederherstellen zeigt sie hier wieder. „Verknüpfung lösen“ lässt sie im Papierkorb und gibt die Fläche für eine neue Notiz frei.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Wiederherstellen") { Task { await model.restoreNote(link) } }.buttonStyle(.borderedProminent)
            case .deleted:
                Text("Die verknüpfte Notiz wurde endgültig gelöscht.").font(.subheadline.weight(.semibold))
                Text("noty öffnet dafür kein anderes Heft, auch kein gleichnamiges. „Verknüpfung lösen“ gibt die Fläche für eine neue Notiz frei.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button("Verknüpfung lösen", role: .destructive) { Task { await model.unlink(link) } }
        }
        .multilineTextAlignment(.center)
        .padding(CalendarSpace.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// „Notizen“, the save state in words, page flip (with several pages), add
/// page, linking again and „Vergrößern“.
struct CalendarNoteControls: View {
    @ObservedObject var session: CalendarNoteSession
    @ObservedObject var editor: EditorModel
    @ObservedObject var model: CalendarModel
    let event: CalendarEntry

    var body: some View {
        HStack(spacing: 0) {
            Text("Notizen").font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
                .fixedSize().padding(.leading, CalendarSpace.s).padding(.trailing, CalendarSpace.s)
            state
            Spacer(minLength: CalendarSpace.xs)
            let pages = editor.notebook.pages.count
            if pages > 1 {
                Button { editor.pageIndex = max(0, editor.pageIndex - 1) } label: {
                    Image(systemName: "chevron.left").frame(width: 32, height: 40).contentShape(Rectangle())
                }
                .disabled(editor.pageIndex == 0)
                .accessibilityLabel("Vorherige Seite")
                Text("\(min(editor.pageIndex, pages - 1) + 1)/\(pages)").font(.footnote).monospacedDigit().foregroundStyle(.secondary).fixedSize()
                    .accessibilityLabel("Seite \(min(editor.pageIndex, pages - 1) + 1) von \(pages)")
                Button { editor.pageIndex = min(pages - 1, editor.pageIndex + 1) } label: {
                    Image(systemName: "chevron.right").frame(width: 32, height: 40).contentShape(Rectangle())
                }
                .disabled(editor.pageIndex >= pages - 1)
                .accessibilityLabel("Nächste Seite")
            }
            Button { model.addNotePage() } label: {
                Image(systemName: "plus.rectangle.portrait").frame(width: 40, height: 40).contentShape(Rectangle())
            }
            .disabled(!editor.writable || pages >= 500)
            .accessibilityLabel("Seite hinzufügen")
            .help("Seite hinzufügen")
            if session.phase == .draft, !EditorModel.hasContent(editor.notebook), !model.unlinkedNotebooks.isEmpty {
                Menu {
                    Section("Vorhandene Notiz verknüpfen") {
                        ForEach(model.unlinkedNotebooks.prefix(30)) { item in
                            Button(item.title) { Task { await model.relink(event, to: item) } }
                        }
                    }
                } label: {
                    Image(systemName: "link").frame(width: 40, height: 40).contentShape(Rectangle())
                }
                .accessibilityLabel("Vorhandene Notiz aus „Kalendernotizen“ verknüpfen")
            }
            Button { model.enlarge(event) } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 40, height: 40).contentShape(Rectangle())
            }
            .accessibilityLabel("Vergrößern")
            .help("Notiz groß im Editor öffnen")
        }
        .font(.body)
        .buttonStyle(.borderless)
    }

    /// Never „gespeichert“ before the commit and the link.
    @ViewBuilder private var state: some View {
        switch session.phase {
        case .draft:
            Text("Schreiben legt die Notiz an").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        case .creating:
            Label("Wird angelegt …", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        case .saved:
            Text(editor.saveFailed ? "Nicht gespeichert" : "In „Kalendernotizen“").font(.caption)
                .foregroundStyle(editor.saveFailed ? Color.orange : .secondary).lineLimit(1)
        case .failed(let reason):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(reason).font(.caption).lineLimit(2)
                Button("Erneut") { model.continueCreation(session) }.font(.caption.weight(.semibold))
            }
            .accessibilityElement(children: .combine)
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
