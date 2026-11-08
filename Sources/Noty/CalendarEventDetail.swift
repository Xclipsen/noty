import SwiftUI
import NotebookCore

/// Termindetails as one large floating window over the calendar
/// („Terminfenster überarbeitet (08.11.2026)“, docs/CALENDAR-PLAN.md): the
/// note – the normal noty editor (`ContentView` embedded) – is the window's
/// surface, edge to edge below one slim head (colour, Titel, Datum · Zeit ·
/// Raum, note state, Details, „…“, Schließen). The facts sit in a column
/// beside the page (wide) or in a strip above it that opens on demand
/// (narrow). Page flip, „Neue Seite“ and „Vergrößern“ are the editor's own
/// controls, not a second row above it.
///
/// Closing always goes through `model.selection = nil`, the same path as
/// before: the model commits and releases the note (`releaseNote`). The
/// window is dark like the editor it carries (which is always dark).
struct CalendarEventPanel: View {
    let event: CalendarEntry
    @ObservedObject var model: CalendarModel
    /// Esc closes the window only while nothing is presented over the calendar.
    var escapes = true
    /// Size the window may use (the calendar's area).
    var available: CGSize = CGSize(width: 900, height: 700)

    init(event: CalendarEntry, model: CalendarModel, escapes: Bool = true, available: CGSize = CGSize(width: 900, height: 700),
         pull: CalendarWindowPull = CalendarWindowPull()) {
        self.event = event
        self.model = model
        self.escapes = escapes
        self.available = available
        pullState = pull
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.calendarLocalChange) private var localChange
    @State private var confirmingRemoval = false
    @State private var detailsHeight: CGFloat = 120
    /// Remembered per arrangement: beside the page the column starts shown,
    /// above it the strip starts closed (the page keeps its height).
    @AppStorage("noty.calendar.window.detailsBeside") private var detailsBeside = true
    @AppStorage("noty.calendar.window.detailsAbove") private var detailsAbove = false
    /// An entry that asks for a look (Ausfall, Änderung, unclear note) opens
    /// the strip once; closing it here does not change the remembered choice.
    @State private var attentionDismissed = false
    /// Pull-down of the head (owned by the calendar, which also lightens the
    /// backdrop): the window follows the finger; past the threshold or with
    /// enough speed it closes, otherwise it springs back.
    @ObservedObject var pullState: CalendarWindowPull
    private var pull: CGFloat { pullState.value }
    @GestureState private var pulling = false
    /// The pull closed the window: it shrinks away from where it was let go.
    @State private var closing = false
    private var calendar: Calendar { model.calendar }

    /// Narrow windows: nearly the full area; otherwise about 92 %.
    private var size: CGSize {
        let compact = available.width < 700
        let width = compact ? available.width - 2 * CalendarSpace.s : min(1200, available.width * 0.92)
        let height = compact ? available.height - 2 * CalendarSpace.s : available.height * 0.92
        return CGSize(width: max(300, width), height: max(320, height))
    }
    /// Wide window: details as a column beside the page instead of above it.
    private var wide: Bool { size.width >= 900 }
    private static let columnWidth: CGFloat = 272

    private var needsAttention: Bool {
        event.status == .cancelled || event.status.note != nil || event.ghostLinkID != nil
    }
    private var detailsShown: Bool {
        wide ? detailsBeside : (detailsAbove || (needsAttention && !attentionDismissed))
    }
    private func toggleDetails() {
        if wide {
            detailsBeside.toggle()
        } else if detailsShown {
            detailsAbove = false
            attentionDismissed = true
        } else {
            detailsAbove = true
        }
    }

    var body: some View {
        let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        VStack(spacing: 0) {
            head
            Rectangle().fill(CalendarPalette.hairline).frame(height: 0.5)
            // One layout type that only changes axis, and the details as an
            // optional child before it: the note view (and its editor) keeps
            // its identity when the window changes width or details toggle.
            // Deliberately not animated: the page would re-fit every frame.
            layout {
                if detailsShown {
                    details
                    if wide {
                        Rectangle().fill(CalendarPalette.hairline).frame(width: 0.5)
                    } else {
                        Rectangle().fill(CalendarPalette.hairline).frame(height: 0.5)
                    }
                }
                CalendarNoteArea(event: event, model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: size.width, height: size.height)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5) }
        // The editor inside is always dark: head and details match it.
        .environment(\.colorScheme, .dark)
        .shadow(color: .black.opacity(0.4), radius: 36, y: 16)
        // Downward it follows the finger and shrinks a little; upward it only gives a bit (rubber band).
        .scaleEffect(1 - min(0.06, max(0, pull) / 2400), anchor: .top)
        .offset(y: pull >= 0 ? pull : -sqrt(-pull) * 3)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { close() }
        .onChange(of: event.id) { _, _ in attentionDismissed = false }
        .confirmationDialog("Termin löschen?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            if event.originalDate != nil || model.isSystemSeries(event) {
                Button("Nur diesen Termin löschen", role: .destructive) { localChange?.mark(); Task { await model.remove(event, scope: .single) } }
                Button("Alle Termine der Serie löschen", role: .destructive) { localChange?.mark(); Task { await model.remove(event, scope: .all) } }
            } else {
                Button("Termin löschen", role: .destructive) { localChange?.mark(); Task { await model.remove(event) } }
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

    /// Grabber, colour, title, Datum · Zeit · Raum, the note's state and the
    /// actions. The head (not the page) can be pulled down to close.
    private var head: some View {
        HStack(alignment: .center, spacing: CalendarSpace.m) {
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(model.entryColor(event)).frame(width: 4, height: 38)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: CalendarSpace.s) {
                    Text(event.title).font(.title3.weight(.semibold)).strikethrough(event.status == .cancelled)
                        .lineLimit(2).minimumScaleFactor(0.85)
                        .accessibilityAddTraits(.isHeader)
                    // With the details closed the state stays in view (never colour alone).
                    if !detailsShown, let label = event.status.label, let symbol = event.status.symbol {
                        statusBadge(label, symbol: symbol)
                    }
                }
                ViewThatFits(in: .horizontal) {
                    subtitle(CalendarText.longDate(event.start, calendar: calendar))
                    subtitle(CalendarText.shortDate(event.start, calendar: calendar))
                }
            }
            .layoutPriority(1)
            Spacer(minLength: CalendarSpace.s)
            CalendarNoteStatus(event: event, model: model)
            HStack(spacing: 0) {
                detailsButton
                moreMenu
                Button { close() } label: { Self.roundIcon("xmark") }
                    .buttonStyle(NotyPressStyle())
                    .accessibilityLabel("Termin schließen")
                    .help("Schließen (Esc)")
            }
        }
        // Esc is a keyboard way: the window goes at once, without shrinking.
        .background {
            Button("Termin schließen") { NotyMotion.instant { close() } }
                .keyboardShortcut(escapes ? .cancelAction : nil)
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        }
        .padding(.leading, CalendarSpace.l).padding(.trailing, CalendarSpace.s)
        .padding(.top, 14).padding(.bottom, CalendarSpace.s)
        .overlay(alignment: .top) {
            Capsule().fill(Color.primary.opacity(0.22)).frame(width: 36, height: 5)
                .padding(.top, 5)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .updating($pulling) { _, state, _ in state = true }
            .onChanged { value in pullState.value = value.translation.height }
            .onEnded { value in
                if value.translation.height > 120 || value.predictedEndTranslation.height > 320 {
                    closing = true
                    close()
                } else {
                    // Back up with the finger's speed (the one spring with a little overshoot).
                    let pulled = pullState.value
                    withAnimation(CalendarMotion.settle(reduceMotion, from: pulled, to: 0, velocity: value.velocity.height)) { pullState.value = 0 }
                }
            })
        // A cancelled pull (no `onEnded`, e.g. a system gesture took over) springs back too.
        .onChange(of: pulling) { _, active in
            if !active && !closing && pullState.value != 0 {
                let pulled = pullState.value
                withAnimation(CalendarMotion.settle(reduceMotion, from: pulled, to: 0)) { pullState.value = 0 }
            }
        }
    }

    /// „Dienstag, 3. November 2026 · 08:00–08:45 · R 204“.
    private func subtitle(_ date: String) -> some View {
        let parts = [date, event.timeText(calendar)] + (event.room.map { [$0] } ?? [])
        return Text(parts.joined(separator: " · "))
            .font(.subheadline).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            .accessibilityLabel([date, event.timeText(calendar)].joined(separator: ", ") + (event.room.map { ", Raum \($0)" } ?? ""))
    }

    private func statusBadge(_ label: String, symbol: String) -> some View {
        let tint: Color = event.status == .cancelled ? .orange : .primary
        return Label(label, systemImage: symbol)
            .labelStyle(CalendarCompactLabelStyle())
            .font(.caption.weight(.semibold)).foregroundStyle(tint)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.16)))
            .fixedSize()
    }

    /// 34-pt round symbol inside a 44-pt target (head actions).
    static func roundIcon(_ symbol: String, filled: Bool = false) -> some View {
        Image(systemName: symbol).font(.body.weight(.semibold))
            .foregroundStyle(filled ? Color.primary : .secondary)
            .frame(width: 34, height: 34)
            .background(Circle().fill(Color.primary.opacity(filled ? 0.2 : 0.1)))
            .frame(width: 44, height: 44).contentShape(Rectangle())
    }

    /// Column beside the page (wide) or strip above it (narrow); a small
    /// count when homework hides behind it.
    private var detailsButton: some View {
        let homework = detailsShown ? 0 : model.homework(for: event).count
        return Button { toggleDetails() } label: {
            Self.roundIcon(wide ? "sidebar.left" : "info", filled: detailsShown)
                .overlay(alignment: .topTrailing) {
                    if homework > 0 {
                        Text("\(homework)").font(.caption2.weight(.bold)).monospacedDigit()
                            .foregroundStyle(.white)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(Circle().fill(CalendarPalette.selection))
                            .padding(.top, 3).padding(.trailing, 3)
                    }
                }
        }
        .buttonStyle(NotyPressStyle())
        .accessibilityLabel("Termindetails")
        .accessibilityValue((detailsShown ? "eingeblendet" : "ausgeblendet") + (homework > 0 ? ", \(homework) Hausaufgaben" : ""))
        .help(detailsShown ? "Details ausblenden" : "Details einblenden")
    }

    private var colorKey: String? {
        guard !model.canEdit(event), let key = event.subjectKey, !event.isSample, model.canWrite else { return nil }
        return key
    }
    private var noteSession: CalendarNoteSession? {
        if case .session(let session) = model.noteState, session.entryID == event.id, model.enlargedDraft !== session { return session }
        return nil
    }

    /// Notiz (Vergrößern, Seite hinzufügen, verknüpfen), Fachfarbe or
    /// Bearbeiten, and Löschen last.
    @ViewBuilder private var moreMenu: some View {
        let session = noteSession
        if model.canEdit(event) || colorKey != nil || session != nil {
            Menu {
                if let session {
                    CalendarNoteMenuItems(session: session, editor: session.model, model: model, event: event)
                }
                if let key = colorKey {
                    Section {
                        Menu {
                            CalendarColorPicker(key: key, model: model)
                        } label: {
                            Label("Fachfarbe", systemImage: "paintpalette")
                        }
                    }
                }
                if model.canEdit(event) {
                    Section {
                        Button { model.draft = model.editDraft(for: event) } label: {
                            Label("Termin bearbeiten …", systemImage: "pencil")
                        }
                        Button(role: .destructive) { confirmingRemoval = true } label: {
                            Label("Termin löschen …", systemImage: "trash")
                        }
                    }
                }
            } label: {
                Self.roundIcon("ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(NotyPressStyle())
            .accessibilityLabel("Weitere Aktionen")
            .help("Weitere Aktionen")
        }
    }

    // MARK: Details

    private var details: some View {
        ScrollView {
            detailsContent
                .padding(.horizontal, CalendarSpace.l).padding(.vertical, CalendarSpace.m)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { detailsHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: wide ? Self.columnWidth : nil)
        .frame(maxHeight: wide ? .infinity : min(detailsHeight, max(96, size.height * 0.4)))
    }

    /// Status first, then the facts, homework and whatever else exists.
    private var detailsContent: some View {
        VStack(alignment: .leading, spacing: CalendarSpace.l) {
            if let label = event.status.label, let symbol = event.status.symbol { statusCallout(label, symbol: symbol) }
            facts
            let homework = model.homework(for: event)
            if !homework.isEmpty { homeworkSection(homework) }
            // Only the homework lines whose task is in the list above are
            // left out; others (e.g. due in a second lesson that day) stay.
            let notes = event.statusNotes.filter { !Self.listed($0, in: homework) }
            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(notes, id: \.self) { note in
                        Text(note).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if event.ghostLinkID != nil { assignment }
            if let text = event.details {
                Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Text(model.originText(for: event)).font(.caption).foregroundStyle(CalendarPalette.quiet)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusCallout(_ label: String, symbol: String) -> some View {
        let tint: Color = event.status == .cancelled ? .orange : .primary
        return HStack(alignment: .firstTextBaseline, spacing: CalendarSpace.s) {
            Image(systemName: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.subheadline.weight(.semibold)).foregroundStyle(tint)
                if let note = event.status.note {
                    Text(note).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, CalendarSpace.m).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.14)))
        .accessibilityElement(children: .combine)
    }

    /// Beside the page: quiet rows; above it: one wrapping line of chips.
    @ViewBuilder private var facts: some View {
        let source = [model.sourceTitle(event), model.sourceAccount(event)].compactMap { $0 }.joined(separator: " · ")
        let locked = model.isReadOnly(event)
        if wide {
            VStack(alignment: .leading, spacing: 10) {
                if let room = event.room { factRow("mappin.and.ellipse", room).accessibilityLabel("Raum \(room)") }
                if let teacher = event.teacher { factRow("person", teacher).accessibilityLabel("Lehrkraft \(teacher)") }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle().fill(model.entryColor(event)).frame(width: 9, height: 9).frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(source).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                        if locked {
                            Label("Schreibgeschützt", systemImage: "lock.fill").labelStyle(CalendarCompactLabelStyle())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                if let text = event.repeatText { factRow("repeat", text) }
                if let text = event.reminder { factRow("bell", text) }
            }
        } else {
            CalendarFlowLayout(spacing: 6) {
                if let room = event.room { CalendarChip(text: room, symbol: "mappin.and.ellipse").accessibilityLabel("Raum \(room)") }
                if let teacher = event.teacher { CalendarChip(text: teacher, symbol: "person").accessibilityLabel("Lehrkraft \(teacher)") }
                CalendarChip(text: source, dot: model.entryColor(event), trailingSymbol: locked ? "lock.fill" : nil)
                    .accessibilityLabel(locked ? "\(source), schreibgeschützt" : source)
                if let text = event.repeatText { CalendarChip(text: text, symbol: "repeat") }
                if let text = event.reminder { CalendarChip(text: text, symbol: "bell") }
            }
        }
    }

    private func factRow(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).font(.subheadline).foregroundStyle(.secondary)
        }
        .labelStyle(CalendarCompactLabelStyle())
        .accessibilityElement(children: .combine)
    }

    /// Whether a status line is the text form of a listed homework
    /// („Hausaufgabe fällig: …“ / „Hausaufgabe bis 12.11.: …“, see `homeworkNotes`).
    static func listed(_ note: String, in items: [CalendarHomeworkItem]) -> Bool {
        guard note.hasPrefix("Hausaufgabe") else { return false }
        return items.contains { item in
            let text = item.homework.text.isEmpty ? "ohne Text" : String(item.homework.text.prefix(200))
            return note.hasSuffix(": " + text) || note.hasSuffix(": " + text + " (erledigt)")
        }
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
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(systemOptions.prefix(6)) { candidate in
                    Button {
                        Task { await model.assign(event, toSystem: candidate) }
                    } label: {
                        Text("\(CalendarText.shortDate(candidate.start, calendar: calendar)) · \(candidate.timeText(calendar)) · \(candidate.title)")
                            .font(.footnote).monospacedDigit().multilineTextAlignment(.leading)
                            .frame(minHeight: 44, alignment: .leading)
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
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(options.prefix(6), id: \.id) { lesson in
                    Button {
                        Task { await model.assign(event, to: lesson) }
                    } label: {
                        Text("\(CalendarText.shortDate(lesson.start, calendar: calendar)) · \(CalendarText.timeRange(lesson.start, lesson.end, calendar: calendar)) · \(lesson.title)")
                            .font(.footnote).monospacedDigit().multilineTextAlignment(.leading)
                            .frame(minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(.borderless)
                }
                Text("noty ordnet nie anhand gleicher Titel zu; ohne Auswahl bleibt die Notiz hier erreichbar.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
