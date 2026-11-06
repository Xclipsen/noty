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

/// Calendar in the library's detail column (docs/CALENDAR-PLAN.md, B1 and
/// „UI-Überarbeitung 06.11.2026“): Jahr · Monat · Woche · Tag from own
/// stored events, WebUntis lessons and holidays of the offline cache, or –
/// explicitly – fictitious samples.
/// Calm by default: a large period title with view switcher and ‹ Heute ›,
/// an optional sidebar (mini month, „Als Nächstes“, calendars), no status
/// line. WebUntis state lives behind the sync symbol of the toolbar; only
/// problems that need the user (storage, unsaved change, recovered state,
/// notices) appear as slim banners. Details and the note open as one large
/// floating window.
struct CalendarView: View {
    @ObservedObject var model: CalendarModel
    /// False while a notebook is open above the library: its keys must not reach the calendar behind it.
    var keysActive = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    /// Command palette (⇧⌘P) and key overview (⌘/) also take Esc.
    @ObservedObject private var router = KeyboardRouter.shared
    /// The sidebar is wanted (shown only when the width allows it).
    @AppStorage("noty.calendar.sidebar") private var sidebarWanted = true
    @State private var sidebarFits = false
    @State private var dayList: CalendarDayListRequest?
    @State private var searching = false
    @State private var connecting = false
    @State private var choosingColors = false
    @State private var editingReminders = false
    @State private var showingDeleted = false
    @State private var showingStatus = false
    @State private var connectAfterStatus = false
    /// „Schnell anlegen“ popover of „+“.
    @State private var quickEntry = false
    /// Complete homework list (from the sidebar).
    @State private var showingHomework = false
    /// The storage lock banner was put away: the sync symbol keeps the badge.
    @State private var hiddenStorageError: String?
    private var calendar: Calendar { model.calendar }
    private var shownWeekDays: Int { model.weekDays == 7 ? 7 : 5 }
    /// Calendar keys only while nothing is presented over it.
    private var keys: Bool {
        keysActive && model.enlargedDraft == nil && dayList == nil && !searching && !connecting && !choosingColors
            && !editingReminders && !showingDeleted && !showingStatus && !quickEntry && !showingHomework && model.draft == nil
            && model.pendingSeriesChange == nil && !router.paletteVisible && !router.helpVisible
    }
    /// Navigation keys (⌘← ⌘→ ⌘T ⌘1–⌘4) also rest while the event window is
    /// open: its note may be typing text, where ⌘← / ⌘→ move the caret.
    private var navigationKeys: Bool { keys && model.selectedEvent == nil }
    private func key(_ key: KeyEquivalent) -> KeyboardShortcut? {
        navigationKeys ? KeyboardShortcut(key, modifiers: .command) : nil
    }

    var body: some View {
        GeometryReader { geo in
            let sidebar = sidebarWanted && geo.size.width >= CalendarSidebar.minimumTotalWidth
            let contentWidth = geo.size.width - (sidebar ? CalendarSidebar.width : 0)
            HStack(spacing: 0) {
                if sidebar {
                    CalendarSidebar(model: model) { showingHomework = true }
                        .frame(width: CalendarSidebar.width)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    Rectangle().fill(CalendarPalette.hairline).frame(width: 0.5)
                }
                VStack(spacing: 0) {
                    header(wide: contentWidth >= 660)
                    if model.selectedEvent == nil { problemBanners }
                    content
                }
                .frame(maxWidth: .infinity)
            }
            .overlay { eventWindow(geo.size) }
            // Problems and toasts stay usable above the event window (a
            // failed delete, „Erneut speichern“ while a note is open).
            .overlay(alignment: .top) {
                if model.selectedEvent != nil { problemBanners.frame(maxWidth: 640).padding(.top, CalendarSpace.s) }
            }
            .overlay(alignment: .bottom) { toasts }
            .animation(NotyMotion.panel(reduceMotion), value: sidebar)
            .onChange(of: geo.size.width >= CalendarSidebar.minimumTotalWidth, initial: true) { _, fits in sidebarFits = fits }
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
        .sheet(isPresented: $choosingColors) { CalendarColorsSheet(model: model) }
        .sheet(isPresented: $editingReminders) { CalendarReminderSettingsSheet(model: model) }
        .sheet(isPresented: $showingDeleted) { CalendarDeletedEventsSheet(model: model) }
        .sheet(isPresented: $showingHomework) { CalendarHomeworkList(model: model) }
        .fullScreenCover(item: $model.enlargedDraft) { session in CalendarEnlargedDraft(session: session, model: model) }
        .confirmationDialog(model.pendingSeriesChange?.text ?? "", isPresented: Binding(
            get: { model.pendingSeriesChange != nil }, set: { if !$0 { model.pendingSeriesChange = nil } }), titleVisibility: .visible) {
            Button("Nur dieser Termin") { model.applyPendingSeriesChange(.single) }
            Button("Alle Termine der Serie") { model.applyPendingSeriesChange(.all) }
            Button("Abbrechen", role: .cancel) { model.pendingSeriesChange = nil }
        } message: {
            Text("Dieser Termin gehört zu einer Serie.")
        }
        .onChange(of: model.storageError) { _, error in if error == nil { hiddenStorageError = nil } }
        .background { shortcuts }
    }

    // MARK: Event window

    /// Dimmed calendar plus the floating window. Esc, pulling the head down,
    /// „Schließen“ and the VoiceOver escape end the selection. Tapping
    /// beside the window deliberately does nothing (it only blocks the
    /// calendar behind): a resting palm while writing with the Pencil
    /// arrives as an ordinary touch and must not close the note.
    private func eventWindow(_ size: CGSize) -> some View {
        ZStack {
            if model.selectedEvent != nil {
                Color.black.opacity(0.45)
                    .contentShape(Rectangle())
                    .onTapGesture {}
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
            if let event = model.selectedEvent {
                CalendarEventPanel(event: event, model: model, escapes: keys, available: size)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .frame(width: size.width, height: size.height)
        .animation(NotyMotion.palette(reduceMotion) ?? .easeOut(duration: 0.15), value: model.selection)
    }

    // MARK: Header (period, view switcher, ‹ Heute ›)

    private func header(wide: Bool) -> some View {
        HStack(alignment: .center, spacing: CalendarSpace.m) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: CalendarSpace.s) {
                    Text(CalendarText.headline(model.mode, anchor: model.anchor, weekDays: shownWeekDays, calendar: calendar))
                        .font(.title.weight(.bold)).lineLimit(1).minimumScaleFactor(0.6)
                        .accessibilityLabel(CalendarText.title(model.mode, anchor: model.anchor, weekDays: shownWeekDays, calendar: calendar))
                        .accessibilityAddTraits(.isHeader)
                    if model.showsSamples { sampleTag }
                }
                if let subline {
                    Text(subline).font(.subheadline).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                        .accessibilityHidden(true)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: CalendarSpace.s)
            if wide {
                Picker("Ansicht", selection: $model.mode) { modes }
                    .pickerStyle(.segmented)
                    .frame(width: 252)
                    .accessibilityLabel("Ansicht")
            } else {
                Menu {
                    Picker("Ansicht", selection: $model.mode) { modes }
                } label: {
                    HStack(spacing: CalendarSpace.xs) {
                        Text(model.mode.title).font(.subheadline.weight(.semibold))
                        Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
                    }
                    .padding(.horizontal, CalendarSpace.m)
                    .frame(minHeight: 44)
                    .background(Capsule().fill(Color.white.opacity(0.08)).padding(.vertical, 6))
                    .contentShape(Rectangle())
                }
                .foregroundStyle(.primary)
                .accessibilityLabel("Ansicht: \(model.mode.title)")
            }
            navigation
        }
        .padding(.leading, CalendarSpace.xl).padding(.trailing, CalendarSpace.l)
        .padding(.top, CalendarSpace.s).padding(.bottom, CalendarSpace.s)
    }

    /// Week: „KW 45 · 2.–6. November 2026“; day: the weekday and the KW.
    private var subline: String? {
        switch model.mode {
        case .week:
            return CalendarText.title(.week, anchor: model.anchor, weekDays: shownWeekDays, calendar: calendar)
        case .day:
            let weekday = CalendarText.weekdays[CalendarDates.weekdayIndex(model.anchor, calendar: calendar)]
            let isToday = calendar.isDate(model.anchor, inSameDayAs: model.today)
            return "\(isToday ? "Heute, " : "")\(weekday) · KW \(CalendarDates.isoWeek(model.anchor, calendar: calendar).week)"
        case .month, .year:
            return nil
        }
    }

    /// Demo mode is said once, quietly, beside the title; tapping ends it.
    private var sampleTag: some View {
        Button { model.showsSamples = false } label: {
            HStack(spacing: 4) {
                Image(systemName: "theatermasks").font(.caption2)
                Text("Beispieldaten").font(.caption.weight(.semibold))
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(0.1)))
            .padding(.vertical, 8).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityLabel("Beispieldaten, frei erfunden, nichts wird gespeichert")
        .accessibilityHint("Blendet die Beispieldaten aus")
    }

    /// ‹ Heute › as one quiet capsule.
    private var navigation: some View {
        HStack(spacing: 0) {
            Button { model.step(-1) } label: {
                Image(systemName: "chevron.left").font(.body.weight(.semibold)).frame(width: 40, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("Zurück")
            .help("Zurück (⌘←)")
            .keyboardShortcut(key(.leftArrow))
            Button { model.goToToday() } label: {
                Text("Heute").font(.subheadline.weight(.semibold)).padding(.horizontal, CalendarSpace.xs)
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
            .keyboardShortcut(key("t"))
            .help("Heute (⌘T)")
            Button { model.step(1) } label: {
                Image(systemName: "chevron.right").font(.body.weight(.semibold)).frame(width: 40, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("Vor")
            .help("Vor (⌘→)")
            .keyboardShortcut(key(.rightArrow))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .background(Capsule().fill(Color.white.opacity(0.08)).padding(.vertical, 6))
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

    /// Empty range: a quiet card, the grid stays usable. Never claims „keine
    /// Termine“ for a range whose timetable was not loaded.
    @ViewBuilder private var emptyHint: some View {
        let range = shownRange
        let coverage = model.coverage(range.start, range.end)
        let empty = !stride(from: 0, to: CalendarDates.days(from: range.start, to: range.end, calendar: calendar), by: 1)
            .contains { !model.events(on: CalendarDates.day($0, after: range.start, calendar: calendar)).isEmpty }
        let top: CGFloat = model.mode == .week || model.mode == .day ? 120 : 72
        if model.loaded, model.mode != .year, coverage == .notLoaded {
            HStack(alignment: .center, spacing: CalendarSpace.m) {
                Image(systemName: "icloud.slash").font(.title3).foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Zeitraum noch nicht geladen").font(.subheadline.weight(.semibold))
                    Text("Der Stundenplan liegt hierfür nicht offline vor. Eigene Termine werden angezeigt.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                Button("Laden") { model.loadShownRange() }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.bordered)
                    .disabled(model.syncing || model.credentialsMissing)
            }
            .padding(.leading, CalendarSpace.l).padding(.trailing, CalendarSpace.m).padding(.vertical, CalendarSpace.m)
            .notyGlass()
            .frame(maxWidth: 460)
            .padding(.horizontal, CalendarSpace.l)
            .padding(.top, top)
        } else if model.loaded, empty {
            VStack(spacing: CalendarSpace.xs) {
                Image(systemName: "calendar").font(.title2).foregroundStyle(.tertiary).padding(.bottom, 2)
                Text(emptyText).font(.subheadline.weight(.semibold))
                Text(emptyDetail).font(.caption).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, CalendarSpace.xl).padding(.vertical, CalendarSpace.l)
            .notyGlass()
            .frame(maxWidth: 420)
            .padding(.horizontal, CalendarSpace.l)
            .padding(.top, top)
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
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
        if model.listedSources.allSatisfy({ model.hiddenSources.contains($0) }) { return "Alle Kalender sind ausgeblendet." }
        if model.showsSamples { return "Beispieldaten: frei erfunden, nichts wird gespeichert." }
        if model.connection == nil {
            return model.mode == .year
                ? "Eigene Termine mit „+“ anlegen oder WebUntis im Menü „…“ verbinden."
                : "Eigene Termine mit „+“ anlegen oder WebUntis im Menü „…“ verbinden. Zum Ansehen: „Beispieldaten anzeigen“."
        }
        if model.mode == .year { return "Unterricht erscheint nur für geladene Zeiträume." }
        return "Laut WebUntis kein Unterricht; keine eigenen Termine."
    }

    // MARK: Problems and toasts

    /// Only what needs the user: a locked or failed store, an unsaved
    /// change, a recovered older state. Everything else is behind the sync
    /// symbol. An unsaved change cannot be put away – only saved again.
    @ViewBuilder private var problemBanners: some View {
        let storage = model.storageError.flatMap { $0 == hiddenStorageError ? nil : $0 }
        if storage != nil || model.saveError != nil || model.recoveredNotice != nil {
            VStack(spacing: CalendarSpace.s) {
                if let storage {
                    CalendarProblemBanner(symbol: "lock.trianglebadge.exclamationmark", text: storage,
                                          closeLabel: "Ausblenden (bleibt im Statussymbol)") { hiddenStorageError = storage }
                }
                if let error = model.saveError {
                    if model.unsaved {
                        CalendarProblemBanner(symbol: "exclamationmark.triangle", text: error,
                                              actionTitle: "Erneut speichern") { Task { await model.retrySave() } }
                    } else {
                        CalendarProblemBanner(symbol: "exclamationmark.triangle", text: error) { model.dismissNotices() }
                    }
                }
                if let notice = model.recoveredNotice {
                    CalendarProblemBanner(symbol: "clock.arrow.circlepath", text: notice) { model.dismissNotices() }
                }
            }
            .padding(.horizontal, CalendarSpace.l).padding(.bottom, CalendarSpace.s)
            .transition(.opacity)
        }
    }

    /// Bottom: a short notice (rejected drag, a note still being saved) and
    /// „Rückgängig“ for the last change.
    private var toasts: some View {
        VStack(spacing: CalendarSpace.s) {
            if let notice = model.notice {
                HStack(spacing: CalendarSpace.m) {
                    Image(systemName: "info.circle").foregroundStyle(.orange).accessibilityHidden(true)
                    Text(notice).font(.subheadline).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    Button { model.notice = nil } label: { Image(systemName: "xmark").font(.caption.weight(.semibold)).frame(width: 36, height: 36) }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Hinweis schließen")
                }
                .padding(.leading, CalendarSpace.l).padding(.trailing, 6).padding(.vertical, 4)
                .frame(maxWidth: 520)
                .notyGlass()
                .accessibilityElement(children: .contain)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let step = model.lastUndo {
                HStack(spacing: CalendarSpace.m) {
                    Text(step.text).font(.subheadline).lineLimit(1)
                    Button("Rückgängig") { Task { await model.undoLast() } }.font(.subheadline.weight(.semibold))
                    Button { model.dismissUndo() } label: { Image(systemName: "xmark").frame(width: 32, height: 32) }
                        .accessibilityLabel("Hinweis schließen")
                }
                .padding(.leading, CalendarSpace.l).padding(.trailing, 6).padding(.vertical, 6)
                .notyGlass()
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, CalendarSpace.l)
        .padding(.bottom, CalendarSpace.l)
        .animation(NotyMotion.panel(reduceMotion), value: model.notice)
        .animation(NotyMotion.panel(reduceMotion), value: model.lastUndo?.text)
    }

    // MARK: Toolbar

    /// Something worth the status symbol: WebUntis, system calendars, a
    /// storage lock, a truncated series.
    private var showsStatus: Bool {
        model.storageError != nil || !model.truncatedSeries.isEmpty
            || (!model.showsSamples && (model.connection != nil || model.systemEnabled))
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if sidebarFits {
                Button { sidebarWanted.toggle() } label: {
                    Label(sidebarWanted ? "Kalenderleiste ausblenden" : "Kalenderleiste einblenden", systemImage: "sidebar.squares.left")
                }
                .help("Kalenderleiste (⌃⌘S)")
                .disabled(model.selectedEvent != nil)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if showsStatus {
                Button { showingStatus = true } label: {
                    CalendarSyncSymbol(model: model, problem: statusProblem)
                }
                .popover(isPresented: $showingStatus, arrowEdge: .top) {
                    CalendarStatusPopover(model: model, connect: {
                        // The sheet follows once the popover is gone (`onDisappear`).
                        connectAfterStatus = true
                        showingStatus = false
                    }, close: { showingStatus = false })
                    .onDisappear {
                        if connectAfterStatus { connectAfterStatus = false; connecting = true }
                    }
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu { optionsMenu } label: {
                Label("Weitere Optionen", systemImage: "ellipsis.circle")
            }
            // The event window is modal: no calendar changes behind it.
            .disabled(model.selectedEvent != nil)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { quickEntry = true } label: { Label("Neuer Termin", systemImage: "plus") }
                .help("Schnell anlegen (⌥⌘N) · Formular (⌘N)")
                .disabled(!model.canWrite || model.showsSamples || model.selectedEvent != nil)
                .popover(isPresented: $quickEntry, arrowEdge: .top) {
                    CalendarQuickEntryPopover(model: model) { quickEntry = false }
                }
        }
    }

    /// The badge of the sync symbol: storage locked, refresh failed, access
    /// missing, system calendars not readable.
    private var statusProblem: Bool {
        if model.storageError != nil { return true }
        guard !model.showsSamples else { return false }
        if model.connection != nil && (model.syncError != nil || model.credentialsMissing) { return true }
        return model.systemEnabled && (model.systemAccess.problem != nil || model.systemError != nil)
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
            Button { choosingColors = true } label: { Label("Fachfarben …", systemImage: "paintpalette") }
                .disabled(model.showsSamples || !model.canWrite)
            Button { editingReminders = true } label: { Label("Erinnerungen …", systemImage: "bell") }
                .disabled(model.showsSamples)
            Button { showingDeleted = true } label: {
                Label(model.deletedEvents.isEmpty ? "Gelöschte Termine …" : "Gelöschte Termine (\(model.deletedEvents.count)) …", systemImage: "trash")
            }
            .disabled(model.showsSamples)
        }
        Section("Kalender") {
            ForEach(model.listedSources) { source in
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

    /// ⌘1–⌘4 like Apple Kalender: Tag, Woche, Monat, Jahr; ⌃⌘S the sidebar.
    private var shortcuts: some View {
        Group {
            Button("Tag") { model.mode = .day }.keyboardShortcut(key("1"))
            Button("Woche") { model.mode = .week }.keyboardShortcut(key("2"))
            Button("Monat") { model.mode = .month }.keyboardShortcut(key("3"))
            Button("Jahr") { model.mode = .year }.keyboardShortcut(key("4"))
            Button("Schnell anlegen") { quickEntry = true }
                .keyboardShortcut(navigationKeys && model.canWrite && !model.showsSamples ? KeyboardShortcut("n", modifiers: [.command, .option]) : nil)
            Button("Kalenderleiste") { sidebarWanted.toggle() }
                .keyboardShortcut(navigationKeys && sidebarFits ? KeyboardShortcut("s", modifiers: [.command, .control]) : nil)
        }
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }
}

private struct CalendarDayListRequest: Identifiable {
    let day: Date
    var id: Date { day }
}

/// „Fachfarben“: one automatic, adjustable colour per subject; own events
/// keep their own colour. State is never shown by colour alone.
struct CalendarColorsSheet: View {
    @ObservedObject var model: CalendarModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.subjects, id: \.key) { subject in
                        let name = CalendarSubjectColor.name(for: subject.key, chosen: model.subjectColors)
                        Menu {
                            CalendarColorPicker(key: subject.key, model: model)
                        } label: {
                            HStack {
                                Circle().fill(CalendarPalette.color(named: name)).frame(width: 12, height: 12)
                                Text(subject.name).foregroundStyle(.primary)
                                Spacer()
                                Text(model.subjectColors[subject.key] == nil ? "Automatisch · \(CalendarSubjectColor.title(name))" : CalendarSubjectColor.title(name))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(minHeight: 44)
                        }
                    }
                } footer: {
                    Text(model.subjects.isEmpty ? "Fächer erscheinen, sobald der Stundenplan aus WebUntis geladen ist."
                         : "Jedes Fach bekommt automatisch eine feste Farbe. Eigene Termine bleiben grün; Ausfall, Prüfung und Änderungen stehen zusätzlich als Symbol und Text.")
                }
            }
            .navigationTitle("Fachfarben")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
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
                                        + model.accessibilityText(event, notes: model.hasNotes(event)))
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
                                                             : "Titel, Ort, Raum oder Beschreibung: eigene Termine (Serien im angezeigten Jahr) und geladener Stundenplan."))
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
