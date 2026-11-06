import SwiftUI
import NotebookCore

/// Termindetails as one large floating window over the calendar (UI-
/// Überarbeitung 06.11.2026): a compact head (colour, Titel, Datum/Uhrzeit,
/// chips for state, Raum, Lehrkraft, Kalender), then the event's note – the
/// normal noty editor (`ContentView` embedded) – as the main element.
/// Closing always goes through `model.selection = nil`, the same path as
/// before: the model commits and releases the note (`releaseNote`).
struct CalendarEventPanel: View {
    let event: CalendarEntry
    @ObservedObject var model: CalendarModel
    /// Esc closes the window only while nothing is presented over the calendar.
    var escapes = true
    /// Size the window may use (the calendar's area).
    var available: CGSize = CGSize(width: 900, height: 700)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmingRemoval = false
    @State private var infoHeight: CGFloat = 120
    /// Pull-down of the head: past the threshold the window closes.
    @State private var pull: CGFloat = 0
    private var calendar: Calendar { model.calendar }

    /// Narrow windows: nearly the full area; otherwise about 90 %.
    private var size: CGSize {
        let compact = available.width < 700
        let width = compact ? available.width - 2 * CalendarSpace.s : min(1180, available.width * 0.9)
        let height = compact ? available.height - 2 * CalendarSpace.s : available.height * 0.9
        return CGSize(width: max(300, width), height: max(320, height))
    }
    /// Wide window: details as a column beside the page instead of above it.
    private var wide: Bool { size.width >= 900 }

    var body: some View {
        let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        VStack(spacing: 0) {
            head
            Rectangle().fill(CalendarPalette.hairline).frame(height: 0.5)
            // One layout type that only changes axis: the note view (and its
            // editor) keeps its identity when the window changes width.
            layout {
                ScrollView {
                    info
                        .padding(.horizontal, CalendarSpace.l).padding(.vertical, CalendarSpace.m)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { infoHeight = $0 }
                }
                .frame(width: wide ? 300 : nil)
                .frame(maxHeight: wide ? .infinity : min(infoHeight, max(84, size.height * 0.24)))
                if wide {
                    Rectangle().fill(CalendarPalette.hairline).frame(width: 0.5)
                } else {
                    Rectangle().fill(CalendarPalette.hairline).frame(height: 0.5)
                }
                CalendarNoteArea(event: event, model: model)
                    .padding(.horizontal, CalendarSpace.s).padding(.top, CalendarSpace.xs).padding(.bottom, CalendarSpace.s)
            }
        }
        .frame(width: size.width, height: size.height)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.55), radius: 40, y: 18)
        .offset(y: pull)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { close() }
        .confirmationDialog("Termin löschen?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            if event.originalDate != nil || model.isSystemSeries(event) {
                Button("Nur diesen Termin löschen", role: .destructive) { Task { await model.remove(event, scope: .single) } }
                Button("Alle Termine der Serie löschen", role: .destructive) { Task { await model.remove(event, scope: .all) } }
            } else {
                Button("Termin löschen", role: .destructive) { Task { await model.remove(event) } }
            }
        } message: {
            Text(removalMessage)
        }
    }

    /// System calendar entries are deleted in Apple Kalender/Outlook (no
    /// „Gelöschte Termine“ there); own entries go to „Gelöschte Termine“.
    private var removalMessage: String {
        if model.isSystem(event) {
            return "„\(event.title)“ wird im Kalender „\(model.sourceTitle(event))“ des iPads gelöscht; iPadOS überträgt das an das Konto. noty kann das nicht rückgängig machen. Notizen bleiben in „Kalendernotizen“ erhalten."
        }
        return event.originalDate != nil
            ? "„\(event.title)“ wiederholt sich. Gelöschtes lässt sich unter „…“ › „Gelöschte Termine“ wiederherstellen; Notizen bleiben in „Kalendernotizen“ erhalten."
            : "„\(event.title)“ kommt in „Gelöschte Termine“ (Menü „…“) und lässt sich dort wiederherstellen. Notizen bleiben in „Kalendernotizen“ erhalten."
    }

    /// The same way as before: the model commits and releases the note.
    private func close() { model.selection = nil }

    // MARK: Head

    /// Grabber, colour, title, date · time, the menu and „Schließen“. The
    /// head (not the page) can be pulled down to close.
    private var head: some View {
        VStack(spacing: 0) {
            Capsule().fill(Color.white.opacity(0.22)).frame(width: 40, height: 5)
                .padding(.top, 7).padding(.bottom, 3)
                .accessibilityHidden(true)
            HStack(alignment: .top, spacing: CalendarSpace.m) {
                RoundedRectangle(cornerRadius: 2.5).fill(model.entryColor(event)).frame(width: 5, height: 44)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.title).font(.title2.weight(.bold)).strikethrough(event.status == .cancelled)
                        .lineLimit(2).minimumScaleFactor(0.8)
                        .accessibilityAddTraits(.isHeader)
                    Text(CalendarText.longDate(event.start, calendar: calendar) + " · " + event.timeText(calendar))
                        .font(.subheadline).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: CalendarSpace.s)
                actions
                Button { close() } label: {
                    Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Termin schließen")
                .help("Schließen (Esc)")
                .keyboardShortcut(escapes ? .cancelAction : nil)
            }
            .padding(.leading, CalendarSpace.l).padding(.trailing, CalendarSpace.s).padding(.bottom, CalendarSpace.s)
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in pull = max(0, value.translation.height) }
            .onEnded { value in
                if value.translation.height > 120 || value.predictedEndTranslation.height > 320 {
                    close()
                } else {
                    withAnimation(NotyMotion.panel(reduceMotion)) { pull = 0 }
                }
            })
    }

    /// Bearbeiten/Löschen (own entries) or the subject colour (lessons).
    @ViewBuilder private var actions: some View {
        if model.canEdit(event) {
            Menu {
                Button { model.draft = model.editDraft(for: event) } label: {
                    Label("Bearbeiten", systemImage: "pencil")
                }
                Button(role: .destructive) { confirmingRemoval = true } label: {
                    Label("Löschen", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis").font(.body.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.white.opacity(0.1)))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("Termin bearbeiten oder löschen")
        } else if let key = event.subjectKey, !event.isSample, model.canWrite {
            Menu {
                CalendarColorPicker(key: key, model: model)
            } label: {
                Image(systemName: "paintpalette").font(.body)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.white.opacity(0.1)))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("Fachfarbe von \(event.subject ?? event.title)")
        }
    }

    // MARK: Details

    /// Chips for the short facts, then only the rows that have content.
    private var info: some View {
        VStack(alignment: .leading, spacing: CalendarSpace.m) {
            CalendarFlowLayout(spacing: 6) {
                if let label = event.status.label, let symbol = event.status.symbol {
                    CalendarChip(text: label, symbol: symbol, tint: event.status == .cancelled ? .orange : .primary, prominent: true)
                }
                if let room = event.room { CalendarChip(text: room, symbol: "mappin.and.ellipse").accessibilityLabel("Raum \(room)") }
                if let teacher = event.teacher { CalendarChip(text: teacher, symbol: "person").accessibilityLabel("Lehrkraft \(teacher)") }
                let source = [model.sourceTitle(event), model.sourceAccount(event)].compactMap { $0 }.joined(separator: " · ")
                CalendarChip(text: source, dot: model.entryColor(event), trailingSymbol: model.isReadOnly(event) ? "lock.fill" : nil)
                    .accessibilityLabel(model.isReadOnly(event) ? "\(source), schreibgeschützt" : source)
                if let text = event.repeatText { CalendarChip(text: text, symbol: "repeat") }
                if let text = event.reminder { CalendarChip(text: text, symbol: "bell") }
            }
            if let note = event.status.note, let label = event.status.label {
                Text("\(label): \(note)").font(.subheadline.weight(.medium))
                    .foregroundStyle(event.status == .cancelled ? Color.orange : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let homework = model.homework(for: event)
            if !homework.isEmpty { homeworkSection(homework) }
            // Homework lines of the lesson are shown above with their check box.
            ForEach(event.statusNotes.filter { homework.isEmpty || !$0.hasPrefix("Hausaufgabe") }, id: \.self) { note in
                Text(note).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if event.ghostLinkID != nil { assignment }
            if let text = event.details {
                Text(text).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text(model.originText(for: event)).font(.caption).foregroundStyle(CalendarPalette.quiet)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Homework given in or due in this lesson, with the local „erledigt“.
    private func homeworkSection(_ items: [CalendarHomeworkItem]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Hausaufgaben").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(items) { item in
                CalendarHomeworkRow(item: item, model: model, showsSubject: false)
            }
        }
    }

    /// „Ungeklärt“: the user may give the note to a lesson of the same course
    /// or – for a system calendar note – to a system event.
    @ViewBuilder private var assignment: some View {
        let options = event.ghostLinkID.flatMap { model.candidates[$0] } ?? []
        let systemOptions = event.ghostLinkID.flatMap { model.systemCandidates[$0] } ?? []
        if !systemOptions.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Gehört die Notiz zu einem dieser Termine im Systemkalender?").font(.footnote.weight(.semibold))
                ForEach(systemOptions.prefix(6)) { candidate in
                    Button {
                        Task { await model.assign(event, toSystem: candidate) }
                    } label: {
                        Text("\(CalendarText.shortDate(candidate.start, calendar: calendar)) · \(candidate.timeText(calendar)) · \(candidate.title)")
                            .font(.footnote).monospacedDigit().frame(minHeight: 32, alignment: .leading)
                    }
                    .buttonStyle(.borderless)
                }
                Text("noty ordnet nie selbst anhand gleicher Titel zu; ohne Auswahl bleibt die Notiz hier erreichbar.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
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
}

/// Small rounded fact („Ausfall“, „R 204“, „Stundenplan 🔒“): symbol plus
/// text, never colour alone.
struct CalendarChip: View {
    let text: String
    var symbol: String?
    var dot: Color?
    var trailingSymbol: String?
    var tint: Color = .secondary
    /// Status: stronger fill and the tint on the text too.
    var prominent = false

    var body: some View {
        HStack(spacing: 5) {
            if let dot { Circle().fill(dot).frame(width: 8, height: 8) }
            if let symbol { Image(systemName: symbol).font(.caption.weight(.semibold)).foregroundStyle(prominent ? tint : .secondary) }
            Text(text).font(.footnote.weight(prominent ? .semibold : .regular)).foregroundStyle(prominent ? tint : .primary)
                .lineLimit(2)
            if let trailingSymbol { Image(systemName: trailingSymbol).font(.system(size: 9)).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Capsule().fill(prominent ? tint.opacity(0.16) : Color.white.opacity(0.07)))
        .accessibilityElement(children: .combine)
    }
}

/// Left-aligned rows that wrap (chips of the event head).
struct CalendarFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + CGFloat(max(0, rows.count - 1)) * spacing
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            let needed = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.items.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
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
