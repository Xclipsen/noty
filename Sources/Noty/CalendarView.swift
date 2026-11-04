import SwiftUI
import NotebookCore

/// Spacing scale of the calendar: 4 · 8 · 12 · 16 · 24.
enum CalendarSpace {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
}

/// Calendar in the library's detail column (docs/CALENDAR-PLAN.md, Stufe B1):
/// Jahr · Monat · Woche · Tag from own stored events, WebUntis lessons and
/// holidays of the offline cache, or – explicitly – fictitious samples.
/// Deliberately lean: period title, ‹ Heute ›, view switcher, „+“; the rest
/// (week length, calendars, WebUntis, sample data, search) lives in one „…“ menu.
struct CalendarView: View {
    @ObservedObject var model: CalendarModel
    /// False while a notebook is open above the library: its keys must not reach the calendar behind it.
    var keysActive = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var dayList: CalendarDayListRequest?
    @State private var searching = false
    @State private var connecting = false
    @State private var enlarged: CalendarEnlargeRequest?
    private var calendar: Calendar { model.calendar }
    private var shownWeekDays: Int { model.weekDays == 7 ? 7 : 5 }
    /// Calendar keys only while nothing is presented over it.
    private var keys: Bool { keysActive && enlarged == nil && dayList == nil && !searching && !connecting && model.draft == nil }
    private func key(_ key: KeyEquivalent) -> KeyboardShortcut? { keys ? KeyboardShortcut(key, modifiers: .command) : nil }

    var body: some View {
        GeometryReader { geo in
            let layout = CalendarScreenLayout(width: geo.size.width)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    header
                    statusLine
                    content
                        .overlay(alignment: .bottom) { removalBanner }
                }
                .frame(maxWidth: .infinity)
                if layout.inlineDetail, let event = model.selectedEvent {
                    Rectangle().fill(CalendarPalette.hairline).frame(width: 0.5)
                    CalendarEventPanel(event: event, model: model, escapes: keys) { enlarged = CalendarEnlargeRequest(event: event, page: $0) }
                        .frame(width: layout.detailWidth)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .overlay {
                // Narrow window/portrait: the note large over the calendar, clear way back.
                if !layout.inlineDetail, let event = model.selectedEvent {
                    CalendarEventPanel(event: event, model: model, overlay: true, escapes: keys) { enlarged = CalendarEnlargeRequest(event: event, page: $0) }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(NotyMotion.panel(reduceMotion), value: layout)
            .animation(NotyMotion.panel(reduceMotion), value: model.selection)
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("Kalender")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .onAppear { model.refreshToday(); model.visible = true }
        .onDisappear { model.visible = false }
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.refreshToday(); model.refreshIfDue() } }
        // While shown: at most every 15 minutes (the model enforces the interval).
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { break }
                // Not while a notebook covers the calendar.
                if scenePhase == .active && keysActive { model.refreshIfDue() }
            }
        }
        .sheet(item: $model.draft) { CalendarEventForm(draft: $0, model: model) }
        .sheet(item: $dayList) { CalendarDayListSheet(day: $0.day, model: model) }
        .sheet(isPresented: $searching) { CalendarSearchSheet(model: model) }
        .sheet(isPresented: $connecting) { CalendarConnectionSheet(model: model) }
        .fullScreenCover(item: $enlarged) { request in
            if let event = model.event(request.event.id) {
                CalendarEnlargedNote(event: event, model: model, page: request.page)
            }
        }
        .background { shortcuts }
    }

    // MARK: Header (period, ‹ Heute ›)

    private var header: some View {
        HStack(spacing: 0) {
            Text(CalendarText.headline(model.mode, anchor: model.anchor, weekDays: shownWeekDays, calendar: calendar))
                .font(.title2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                .accessibilityLabel(CalendarText.title(model.mode, anchor: model.anchor, weekDays: shownWeekDays, calendar: calendar))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: CalendarSpace.s)
            Button { model.step(-1) } label: {
                Image(systemName: "chevron.left").font(.body.weight(.medium)).frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("Zurück")
            .help("Zurück (⌘←)")
            .keyboardShortcut(key(.leftArrow))
            Button { model.goToToday() } label: {
                Text("Heute").font(.body.weight(.medium)).padding(.horizontal, CalendarSpace.xs)
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
            .keyboardShortcut(key("t"))
            .help("Heute (⌘T)")
            Button { model.step(1) } label: {
                Image(systemName: "chevron.right").font(.body.weight(.medium)).frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("Vor")
            .help("Vor (⌘→)")
            .keyboardShortcut(key(.rightArrow))
        }
        .buttonStyle(.borderless)
        .padding(.leading, CalendarSpace.xl).padding(.trailing, CalendarSpace.m)
        .padding(.top, CalendarSpace.xs).padding(.bottom, CalendarSpace.xs)
    }

    @ViewBuilder private var content: some View {
        Group {
            switch model.mode {
            case .week:
                CalendarTimeGrid(days: CalendarDates.weekDays(containing: model.anchor, count: shownWeekDays, calendar: calendar), model: model)
            case .day:
                CalendarTimeGrid(days: [calendar.startOfDay(for: model.anchor)], model: model, detailed: true)
            case .month:
                CalendarMonthView(model: model) { dayList = CalendarDayListRequest(day: $0) }
            case .year:
                CalendarYearView(model: model)
            }
        }
        .overlay(alignment: .top) { emptyHint }
    }

    private var shownRange: (start: Date, end: Date) {
        CalendarDates.range(model.mode, anchor: model.anchor, weekDays: shownWeekDays, calendar: calendar)
    }

    /// Empty range: a quiet hint, the grid stays usable. Never claims „keine
    /// Termine“ for a range whose timetable was not loaded.
    @ViewBuilder private var emptyHint: some View {
        let range = shownRange
        let coverage = model.coverage(range.start, range.end)
        let empty = !stride(from: 0, to: CalendarDates.days(from: range.start, to: range.end, calendar: calendar), by: 1)
            .contains { !model.events(on: CalendarDates.day($0, after: range.start, calendar: calendar)).isEmpty }
        if model.loaded, model.mode != .year, coverage == .notLoaded {
            VStack(spacing: CalendarSpace.s) {
                Text("Zeitraum noch nicht geladen").font(.subheadline.weight(.semibold))
                Text("Der Stundenplan liegt für diesen Zeitraum nicht offline vor. Eigene Termine werden angezeigt.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.mode != .year {
                    Button("Laden") { model.loadShownRange() }.font(.subheadline.weight(.semibold)).disabled(model.syncing)
                }
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, CalendarSpace.l).padding(.vertical, CalendarSpace.m)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            .padding(.top, model.mode == .week || model.mode == .day ? 140 : 80)
            .frame(maxWidth: 420)
        } else if model.loaded, empty {
            VStack(spacing: CalendarSpace.xs) {
                Text(emptyText).font(.subheadline.weight(.semibold))
                Text(emptyDetail).font(.caption).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, CalendarSpace.l).padding(.vertical, CalendarSpace.m)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            .padding(.top, model.mode == .week || model.mode == .day ? 140 : 80)
            .frame(maxWidth: 420)
            .allowsHitTesting(false)
        }
    }

    private var emptyText: String {
        switch model.mode {
        case .year: "Keine Termine in diesem Jahr"
        case .month: "Keine Termine in diesem Monat"
        case .week: "Keine Termine in dieser Woche"
        case .day: "Keine Termine an diesem Tag"
        }
    }

    private var emptyDetail: String {
        if model.hiddenSources.count == CalendarSource.allCases.count { return "Alle Kalender sind ausgeblendet (Menü „…“)." }
        if model.showsSamples { return "Beispieldaten: frei erfunden, nichts wird gespeichert." }
        if model.connection == nil {
            return model.mode == .year
                ? "Eigene Termine mit „+“ anlegen oder WebUntis im Menü „…“ verbinden."
                : "Eigene Termine mit „+“ anlegen oder WebUntis im Menü „…“ verbinden. Zum Ansehen: „Beispieldaten anzeigen“."
        }
        if model.mode == .year { return "Unterricht erscheint nur für geladene Zeiträume." }
        return "Laut WebUntis kein Unterricht; keine eigenen Termine."
    }

    /// One quiet line under the title: WebUntis „Stand“, refresh, errors,
    /// storage problems and the demo hint. Hidden when there is nothing to say.
    @ViewBuilder private var statusLine: some View {
        let items = statusItems
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(items.indices, id: \.self) { index in
                    let item = items[index]
                    HStack(spacing: CalendarSpace.s) {
                        if let symbol = item.symbol {
                            Image(systemName: symbol).font(.caption).foregroundStyle(item.warning ? Color.orange : Color.secondary)
                        }
                        Text(item.text).font(.caption).foregroundStyle(item.warning ? Color.primary : Color.secondary)
                            .lineLimit(2)
                        if let action = item.action {
                            Button(action.title) { perform(action) }.font(.caption.weight(.semibold)).buttonStyle(.borderless)
                        }
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.leading, CalendarSpace.xl).padding(.trailing, CalendarSpace.l).padding(.bottom, CalendarSpace.xs)
        }
    }

    private enum StatusAction {
        case retrySave, dismiss, hideSamples, connect, refresh
        var title: String {
            switch self {
            case .retrySave: "Erneut speichern"
            case .dismiss: "OK"
            case .hideSamples: "Ausblenden"
            case .connect: "Verbinden …"
            case .refresh: "Erneut"
            }
        }
    }

    private struct StatusItem {
        var symbol: String?
        var text: String
        var warning = false
        var action: StatusAction?
    }

    private func perform(_ action: StatusAction) {
        switch action {
        case .retrySave: Task { await model.retrySave() }
        case .dismiss: model.dismissNotices()
        case .hideSamples: model.showsSamples = false
        case .connect: connecting = true
        case .refresh: model.refreshNow()
        }
    }

    private var statusItems: [StatusItem] {
        var items: [StatusItem] = []
        if let error = model.storageError { items.append(StatusItem(symbol: "lock.trianglebadge.exclamationmark", text: error, warning: true)) }
        if let error = model.saveError {
            items.append(StatusItem(symbol: "exclamationmark.triangle", text: error, warning: true,
                                    action: model.unsaved ? .retrySave : .dismiss))
        }
        if let notice = model.recoveredNotice {
            items.append(StatusItem(symbol: "clock.arrow.circlepath", text: notice, warning: true, action: .dismiss))
        }
        if model.showsSamples {
            items.append(StatusItem(symbol: "theatermasks", text: "Beispieldaten – frei erfunden, nichts wird gespeichert",
                                    action: .hideSamples))
        } else if model.connection != nil, !model.hiddenSources.contains(.timetable) {
            items.append(sourceItem)
        }
        return items
    }

    private var sourceItem: StatusItem {
        if model.credentialsMissing {
            return StatusItem(symbol: "key", text: "WebUntis: Zugangsdaten fehlen auf diesem iPad", warning: true,
                              action: .connect)
        }
        let range = shownRange
        var stand: String?
        switch model.coverage(range.start, range.end) {
        case .loaded(let oldest)?: stand = model.standText(oldest)
        case .partial(let oldest)?: stand = model.standText(oldest) + " · teilweise geladen"
        default: stand = nil
        }
        if model.syncing {
            return StatusItem(symbol: "arrow.triangle.2.circlepath", text: "Stundenplan wird aktualisiert …" + (stand.map { " · \($0)" } ?? ""))
        }
        if let error = model.syncError {
            return StatusItem(symbol: "exclamationmark.icloud", text: "Aktualisierung fehlgeschlagen: \(error)" + (stand.map { " · \($0)" } ?? ""),
                              warning: true, action: .refresh)
        }
        return StatusItem(symbol: "lock", text: "Stundenplan aus WebUntis · " + (stand ?? "noch nicht geladen"))
    }

    @ViewBuilder private var removalBanner: some View {
        if let removal = model.lastRemoval {
            HStack(spacing: CalendarSpace.m) {
                Text("\(removal.title) gelöscht").font(.subheadline).lineLimit(1)
                Button("Rückgängig") { Task { await model.undoRemoval() } }.font(.subheadline.weight(.semibold))
                Button { model.dismissRemoval() } label: { Image(systemName: "xmark").frame(width: 32, height: 32) }
                    .accessibilityLabel("Hinweis schließen")
            }
            .padding(.leading, CalendarSpace.l).padding(.trailing, 6).padding(.vertical, 6)
            .notyGlass()
            .padding(.bottom, CalendarSpace.l)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            if sizeClass == .compact {
                // Narrow window: one compact menu instead of four segments.
                Menu {
                    Picker("Ansicht", selection: $model.mode) { modes }
                } label: {
                    HStack(spacing: CalendarSpace.xs) {
                        Text(model.mode.title).font(.headline)
                        Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(.primary)
                    .frame(minHeight: 44)
                }
                .accessibilityLabel("Ansicht: \(model.mode.title)")
            } else {
                Picker("Ansicht", selection: $model.mode) { modes }
                    .pickerStyle(.segmented)
                    .frame(width: 280)
                    .accessibilityLabel("Ansicht")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu { optionsMenu } label: {
                Label("Weitere Optionen", systemImage: "ellipsis.circle")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { model.requestNewEvent() } label: { Label("Neuer Termin", systemImage: "plus") }
                .help("Neuer Termin (⌘N)")
                .disabled(!model.canWrite || model.showsSamples)
        }
    }

    /// Tag · Woche · Monat · Jahr, in the order of ⌘1–⌘4.
    private var modes: some View {
        ForEach([CalendarMode.day, .week, .month, .year]) { Text($0.title).tag($0) }
    }

    @ViewBuilder private var optionsMenu: some View {
        Section {
            Picker(selection: $model.weekDays) {
                Text("Montag – Freitag").tag(5)
                Text("Ganze Woche").tag(7)
            } label: {
                Label("Wochentage", systemImage: "calendar.day.timeline.left")
            }
            .pickerStyle(.menu)
            Button { searching = true } label: { Label("Termine suchen", systemImage: "magnifyingglass") }
        }
        Section("Kalender") {
            ForEach(CalendarSource.allCases) { source in
                Toggle(isOn: Binding(
                    get: { !model.hiddenSources.contains(source) },
                    set: { shown in if shown { model.hiddenSources.remove(source) } else { model.hiddenSources.insert(source) } }
                )) {
                    Text(source.readOnly ? "\(source.title) · schreibgeschützt" : source.title)
                }
            }
        }
        Section("WebUntis (inoffiziell)") {
            if model.connection != nil {
                Button { model.refreshNow() } label: { Label("Aktualisieren", systemImage: "arrow.clockwise") }
                    .disabled(model.syncing || model.credentialsMissing || model.showsSamples)
                Button { connecting = true } label: { Label("WebUntis-Verbindung …", systemImage: "link") }
            } else {
                Button { connecting = true } label: { Label("WebUntis verbinden …", systemImage: "link.badge.plus") }
                    .disabled(!model.canWrite)
            }
        }
        Section("Ansicht") {
            Toggle("Beispieldaten anzeigen", isOn: $model.showsSamples)
            Text("Nur zum Ansehen: frei erfundene Termine, nichts wird gespeichert.")
        }
    }

    /// ⌘1–⌘4 like Apple Kalender: Tag, Woche, Monat, Jahr.
    private var shortcuts: some View {
        Group {
            Button("Tag") { model.mode = .day }.keyboardShortcut(key("1"))
            Button("Woche") { model.mode = .week }.keyboardShortcut(key("2"))
            Button("Monat") { model.mode = .month }.keyboardShortcut(key("3"))
            Button("Jahr") { model.mode = .year }.keyboardShortcut(key("4"))
        }
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }
}

/// Whether the details fit beside the calendar: no forced columns on small space.
struct CalendarScreenLayout: Equatable {
    /// The calendar itself keeps at least this width beside the details.
    static let minimumCalendar: CGFloat = 500
    let inlineDetail: Bool
    let detailWidth: CGFloat

    init(width: CGFloat) {
        detailWidth = min(440, max(360, width * 0.36))
        inlineDetail = width - detailWidth >= Self.minimumCalendar
    }
}

private struct CalendarDayListRequest: Identifiable {
    let day: Date
    var id: Date { day }
}

private struct CalendarEnlargeRequest: Identifiable {
    let id = UUID()
    let event: CalendarEntry
    let page: Int
}

/// Search over the sample entries; never silently limited.
struct CalendarSearchSheet: View {
    @ObservedObject var model: CalendarModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private static let shownLimit = 200

    var body: some View {
        NavigationStack {
            let results = model.search(query)
            List {
                ForEach(results.prefix(Self.shownLimit)) { event in
                    Button {
                        model.show(event)
                        dismiss()
                    } label: { CalendarListRow(event: event, model: model, showsDate: true) }
                    .accessibilityLabel(CalendarText.longDate(event.start, calendar: model.calendar) + ", "
                                        + event.accessibilityText(model.calendar, notes: model.hasNotes(event)))
                }
                if results.count > Self.shownLimit {
                    Text("\(results.count - Self.shownLimit) weitere Treffer – Suche genauer eingeben.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .overlay {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    ContentUnavailableView("Termine suchen", systemImage: "magnifyingglass",
                                           description: Text(model.showsSamples ? "Titel, Raum, Lehrkraft oder Beschreibung (Beispieldaten des angezeigten Jahres)."
                                                             : "Titel, Ort, Raum oder Beschreibung: eigene Termine und geladener Stundenplan."))
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Termine suchen")
            .navigationTitle("Suche")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fertig") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}
