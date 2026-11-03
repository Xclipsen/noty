import SwiftUI
import NotebookCore

enum CalendarSettingsKey {
    /// 5 = Monday–Friday (default), 7 = whole week.
    static let weekDays = "noty.calendar.weekDays"
    /// Left panel (mini month, calendars) when there is room.
    static let panel = "noty.calendar.panel"
}

/// Calendar design stage (docs/CALENDAR-PLAN.md, Stufe A) in the library's
/// detail column: Jahr · Monat · Woche · Tag with fictitious sample data.
/// No calendar storage, no providers; notes live in memory only.
struct CalendarView: View {
    @ObservedObject var model: CalendarDesignModel
    /// False while a notebook is open above the library: its keys must not reach the calendar behind it.
    var keysActive = true
    @AppStorage(CalendarSettingsKey.weekDays) private var weekDays = 5
    @AppStorage(CalendarSettingsKey.panel) private var panelPreferred = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dayList: CalendarDayListRequest?
    @State private var searching = false
    @State private var enlarged: CalendarEnlargeRequest?
    private var calendar: Calendar { model.calendar }
    private var shownWeekDays: Int { weekDays == 7 ? 7 : 5 }
    /// Calendar keys only while nothing is presented over it.
    private var keys: Bool { keysActive && enlarged == nil && dayList == nil && !searching && model.draft == nil }
    private func key(_ key: KeyEquivalent) -> KeyboardShortcut? { keys ? KeyboardShortcut(key, modifiers: .command) : nil }

    var body: some View {
        GeometryReader { geo in
            let layout = CalendarScreenLayout(width: geo.size.width, panelPreferred: panelPreferred, hasSelection: model.selectedEvent != nil)
            HStack(spacing: 0) {
                if layout.panel {
                    CalendarSidePanel(model: model, weekDays: shownWeekDays)
                        .frame(width: CalendarScreenLayout.panelWidth)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    Divider()
                }
                VStack(spacing: 0) {
                    header
                    Divider()
                    content
                        .overlay(alignment: .bottom) { removalBanner }
                }
                .frame(maxWidth: .infinity)
                if layout.inlineDetail, let event = model.selectedEvent {
                    Divider()
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
        .onAppear { model.refreshToday() }
        .sheet(item: $model.draft) { CalendarEventForm(draft: $0, calendar: calendar) }
        .sheet(item: $dayList) { CalendarDayListSheet(day: $0.day, model: model) }
        .sheet(isPresented: $searching) { CalendarSearchSheet(model: model) }
        .fullScreenCover(item: $enlarged) { request in
            if let event = model.event(request.event.id) {
                CalendarEnlargedNote(event: event, model: model, page: request.page)
            }
        }
        .background { shortcuts }
    }

    // MARK: Header (date range, back/forward, Heute)

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(CalendarText.title(model.mode, anchor: model.anchor, weekDays: shownWeekDays, calendar: calendar))
                    .font(.title2.bold()).lineLimit(1).minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
                Label("Beispieldaten · nichts wird gespeichert", systemImage: "flask")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { model.step(-1) } label: {
                Image(systemName: "chevron.left").font(.body.weight(.semibold)).frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("Zurück")
            .help("Zurück (⌘←)")
            .keyboardShortcut(key(.leftArrow))
            Button("Heute") { model.goToToday() }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .keyboardShortcut(key("t"))
                .help("Heute (⌘T)")
            Button { model.step(1) } label: {
                Image(systemName: "chevron.right").font(.body.weight(.semibold)).frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("Vor")
            .help("Vor (⌘→)")
            .keyboardShortcut(key(.rightArrow))
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
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

    /// Empty range or hidden samples: a quiet hint, the grid stays usable.
    @ViewBuilder private var emptyHint: some View {
        let range = CalendarDates.range(model.mode, anchor: model.anchor, weekDays: shownWeekDays, calendar: calendar)
        let empty = !model.hasVisibleSamples || !stride(from: 0, to: CalendarDates.days(from: range.start, to: range.end, calendar: calendar), by: 1)
            .contains { !model.events(on: CalendarDates.day($0, after: range.start, calendar: calendar)).isEmpty }
        if empty {
            VStack(spacing: 4) {
                Label(emptyText, systemImage: "calendar").font(.subheadline.weight(.semibold))
                Text(model.showsSamples ? "Alle Kalender sind ausgeblendet." : "Beispieldaten sind ausgeblendet (Ansicht ohne Termine).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .notyGlass()
            .padding(.top, model.mode == .week || model.mode == .day ? 120 : 60)
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

    @ViewBuilder private var removalBanner: some View {
        if let removal = model.lastRemoval {
            HStack(spacing: 12) {
                Text("\(removal.title) ausgeblendet").font(.subheadline).lineLimit(1)
                Button("Rückgängig") { model.undoRemoval() }.font(.subheadline.weight(.semibold))
                Button { model.dismissRemoval() } label: { Image(systemName: "xmark").frame(width: 32, height: 32) }
                    .accessibilityLabel("Hinweis schließen")
            }
            .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 6)
            .notyGlass()
            .padding(.bottom, 16)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { withAnimation(NotyMotion.panel(reduceMotion)) { panelPreferred.toggle() } } label: {
                Label(panelPreferred ? "Kalenderleiste ausblenden" : "Kalenderleiste einblenden", systemImage: "sidebar.squares.left")
            }
            .help("Monatsübersicht und Kalender")
        }
        ToolbarItem(placement: .principal) {
            Picker("Ansicht", selection: $model.mode) {
                ForEach(CalendarMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(minWidth: 260, maxWidth: 340)
            .accessibilityLabel("Ansicht")
        }
        if model.mode == .week {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Wochentage", selection: $weekDays) {
                        Text("Montag – Freitag").tag(5)
                        Text("Ganze Woche").tag(7)
                    }
                } label: {
                    Label(shownWeekDays == 5 ? "5 Tage" : "7 Tage", systemImage: shownWeekDays == 5 ? "calendar.day.timeline.left" : "calendar")
                        .labelStyle(.titleAndIcon)
                }
                .accessibilityLabel("Wochentage: \(shownWeekDays == 5 ? "Montag bis Freitag" : "ganze Woche")")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { searching = true } label: { Label("Termine suchen", systemImage: "magnifyingglass") }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { model.requestNewEvent() } label: { Label("Neuer Termin", systemImage: "plus") }
                .help("Neuer Termin (⌘N)")
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

/// Which columns fit: no forced three columns on small space.
struct CalendarScreenLayout: Equatable {
    static let panelWidth: CGFloat = 304
    /// The calendar itself keeps at least this width beside the details.
    static let minimumCalendar: CGFloat = 500
    let panel: Bool
    let inlineDetail: Bool
    let detailWidth: CGFloat

    init(width: CGFloat, panelPreferred: Bool, hasSelection: Bool) {
        detailWidth = min(460, max(360, width * 0.36))
        inlineDetail = width - detailWidth >= Self.minimumCalendar
        let remaining = width - (hasSelection && inlineDetail ? detailWidth : 0)
        panel = panelPreferred && remaining - Self.panelWidth >= 600
    }
}

private struct CalendarDayListRequest: Identifiable {
    let day: Date
    var id: Date { day }
}

private struct CalendarEnlargeRequest: Identifiable {
    let id = UUID()
    let event: CalendarSampleEvent
    let page: Int
}

/// Left panel: mini month and the calendars with colour dots.
struct CalendarSidePanel: View {
    @ObservedObject var model: CalendarDesignModel
    let weekDays: Int
    @State private var month: Date?
    @ScaledMetric(relativeTo: .body) private var cell: CGFloat = 38
    private var calendar: Calendar { model.calendar }

    var body: some View {
        let shown = month ?? CalendarDates.startOfMonth(model.anchor, calendar: calendar)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                miniMonth(shown)
                calendars
                Toggle(isOn: $model.showsSamples) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Beispieldaten anzeigen")
                        Text("Aus: leere Ansicht prüfen").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 44)
                Label("Stufe A: Design mit erfundenen Daten. Kein WebUntis-Zugang, keine Speicherung.", systemImage: "flask")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .onChange(of: model.anchor) { _, _ in month = nil }
    }

    private func miniMonth(_ shown: Date) -> some View {
        let grid = CalendarMonthGrid(month: shown, calendar: calendar)
        let range = CalendarDates.range(model.mode, anchor: model.anchor, weekDays: weekDays, calendar: calendar)
        let index = calendar.component(.month, from: shown) - 1
        return VStack(spacing: 2) {
            HStack {
                Text("\(CalendarText.months[index]) \(String(calendar.component(.year, from: shown)))").font(.headline)
                Spacer()
                Button { month = calendar.date(byAdding: .month, value: -1, to: shown) } label: {
                    Image(systemName: "chevron.left").frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Vorheriger Monat")
                Button { month = calendar.date(byAdding: .month, value: 1, to: shown) } label: {
                    Image(systemName: "chevron.right").frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Nächster Monat")
            }
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { Text(CalendarText.shortWeekdays[$0]).frame(width: cell) }
            }
            .font(.caption2).foregroundStyle(.secondary).accessibilityHidden(true)
            ForEach(grid.weeks, id: \.days.first) { week in
                HStack(spacing: 0) {
                    ForEach(week.days, id: \.self) { day in
                        let inMonth = grid.contains(day, calendar: calendar)
                        let isToday = calendar.isDate(day, inSameDayAs: model.today)
                        let inRange = model.mode != .year && day >= range.start && day < range.end
                        Button { model.anchor = day } label: {
                            Text("\(calendar.component(.day, from: day))")
                                .font(.callout.weight(isToday ? .bold : .regular)).monospacedDigit()
                                .foregroundStyle(isToday ? Color.white : inMonth ? .primary : .secondary)
                                .frame(width: 30, height: 30)
                                .background { if isToday { Circle().fill(CalendarPalette.today) } }
                                .frame(width: cell, height: cell)
                                .background { if inRange { Rectangle().fill(CalendarPalette.selection.opacity(0.22)) } }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(CalendarText.longDate(day, calendar: calendar) + (isToday ? ", heute" : ""))
                        .accessibilityAddTraits(inRange ? .isSelected : [])
                    }
                }
            }
        }
    }

    private var calendars: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Kalender").font(.headline).padding(.bottom, 4).accessibilityAddTraits(.isHeader)
            ForEach(CalendarSource.allCases) { source in
                let shown = !model.hiddenSources.contains(source)
                Button {
                    if shown { model.hiddenSources.insert(source) } else { model.hiddenSources.remove(source) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: shown ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(shown ? CalendarPalette.selection : .secondary)
                        dots(source)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(source.title).foregroundStyle(.primary)
                            Text(source.origin).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if source.readOnly { Image(systemName: "lock").font(.caption).foregroundStyle(.secondary) }
                    }
                    .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(source.title), \(source.origin)\(source.readOnly ? ", schreibgeschützt" : "")")
                .accessibilityValue(shown ? "eingeblendet" : "ausgeblendet")
                .accessibilityHint("Blendet den Kalender ein oder aus")
            }
        }
    }

    /// Timetable: several subject colours (automatic per subject).
    @ViewBuilder private func dots(_ source: CalendarSource) -> some View {
        switch source {
        case .timetable:
            HStack(spacing: -3) {
                ForEach(0..<3, id: \.self) { Circle().fill(CalendarPalette.subjects[$0]).frame(width: 10, height: 10) }
            }
            .frame(width: 24)
        case .personal: Circle().fill(CalendarPalette.personal).frame(width: 10, height: 10).frame(width: 24)
        case .holidays: Circle().fill(CalendarPalette.holidays).frame(width: 10, height: 10).frame(width: 24)
        }
    }
}

/// Search over the sample entries; never silently limited.
struct CalendarSearchSheet: View {
    @ObservedObject var model: CalendarDesignModel
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
                                           description: Text("Titel, Raum, Lehrkraft oder Beschreibung (Beispieldaten des geladenen Jahres)."))
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
