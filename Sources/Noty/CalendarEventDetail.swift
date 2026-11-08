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
                    .buttonStyle(.plain)
                    .accessibilityLabel("Termin schließen")
                    .help("Schließen (Esc)")
                    .keyboardShortcut(escapes ? .cancelAction : nil)
            }
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
                    withAnimation(CalendarMotion.bouncy(reduceMotion)) { pullState.value = 0 }
                }
            })
        // A cancelled pull (no `onEnded`, e.g. a system gesture took over) springs back too.
        .onChange(of: pulling) { _, active in
            if !active && !closing && pullState.value != 0 {
                withAnimation(CalendarMotion.bouncy(reduceMotion)) { pullState.value = 0 }
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
        .buttonStyle(.plain)
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
                            Label("Termin bearbeiten", systemImage: "pencil")
                        }
                        Button(role: .destructive) { confirmingRemoval = true } label: {
                            Label("Termin löschen", systemImage: "trash")
                        }
                    }
                }
            } label: {
                Self.roundIcon("ellipsis")
            }
            .accessibilityLabel("Weitere Aktionen")
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
                            .frame(minHeight: 32, alignment: .leading)
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
                            .frame(minHeight: 32, alignment: .leading)
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
        .background(Capsule().fill(prominent ? tint.opacity(0.16) : Color.primary.opacity(0.08)))
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
            case .unavailable(let text):
                message(symbol: "note.text", title: text)
            case .sample:
                CalendarSampleNote(pages: event.samplePages)
            default:
                ProgressView().controlSize(.large)
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
                : ("folder", "In „Kalendernotizen“", false)
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
