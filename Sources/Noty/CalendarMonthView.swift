import SwiftUI
import NotebookCore

/// Remembers a gesture that just ended over the month (holding and
/// dragging to create): the cells' buttons ignore the touch that was part of
/// it (their tap may still arrive on release).
final class CalendarSwipeGuard {
    private var at = Date.distantPast
    func mark() { at = Date() }
    var recent: Bool { Date().timeIntervalSince(at) < 0.45 }
}

/// Month: seven clean columns, quiet ISO week numbers, at most three
/// compact lines per day. What does not fit is counted in „+ n weitere“,
/// never dropped.
/// „Monat senkrecht blättern (08.11.2026)“: the months lie one below the
/// other and turn page by page with a vertical scroll (finger, trackpad,
/// mouse wheel) – each page is one month filling the height. Does a month
/// of six weeks not fit (large text, small window), the months scroll
/// freely instead, each with a small title. The page in the middle is the
/// shown month: it moves the anchor (title, zoom, „Heute“), and every
/// other change of the anchor (‹ ›, keys, trackpad swipe, mini month) turns
/// to its page without scrolling motion. Only visible months are rendered.
/// Holding a day and dragging over days and weeks creates an all-day event.
struct CalendarMonthView: View {
    @ObservedObject var model: CalendarModel
    let showAll: (Date) -> Void
    /// The user scrolled to another month (its first day): the calendar
    /// moves the anchor there without the period motion.
    let scrolled: (Date) -> Void
    @State private var tapGuard = CalendarSwipeGuard()
    /// Pinch between the views: its fingers are no tap.
    @Environment(\.calendarZoom) private var zoom
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The page in the middle (first day of its month); written by scrolling.
    @State private var visibleMonth: Date?
    /// The months shown: `reach` either side of a centre month (computed
    /// once per recentring, not per render).
    @State private var months: [Date]
    /// The scroll came to rest (iPadOS 18+; before: always): only then does
    /// the scrolled month become the anchor, so a page dragged and let go
    /// back does not flicker the title.
    @State private var scrollIdle = true
    /// Programmatic turns (anchor changed, size changed, recentred): the
    /// position the scroll view reports meanwhile is not the user's.
    @State private var settling = CalendarSwipeGuard()
    @State private var creation = CalendarCreateState()
    @State private var creating = false
    @ScaledMetric(relativeTo: .caption) private var line: CGFloat = 20
    @ScaledMetric(relativeTo: .caption) private var weekColumn: CGFloat = 28
    @ScaledMetric(relativeTo: .body) private var minimumRow: CGFloat = 100
    @ScaledMetric(relativeTo: .body) private var dateRow: CGFloat = 32
    @ScaledMetric(relativeTo: .headline) private var titleRow: CGFloat = 36
    /// Calm cells: never more than three lines, the rest behind „+ n weitere“.
    private let maximumLines = 3
    /// Below this column width the lines become coloured dots.
    static let dotColumn: CGFloat = 76
    /// Months rendered lazily either side of `center` (five years); it is
    /// recentred long before the user reaches an end.
    static let reach = 60
    private var calendar: Calendar { model.calendar }
    private var creatable: Bool { model.canWrite && !model.showsSamples && model.selectedEvent == nil && model.draft == nil }

    init(model: CalendarModel, showAll: @escaping (Date) -> Void, scrolled: @escaping (Date) -> Void) {
        _model = ObservedObject(wrappedValue: model)
        self.showAll = showAll
        self.scrolled = scrolled
        let month = CalendarDates.startOfMonth(model.anchor, calendar: model.calendar)
        _visibleMonth = State(initialValue: month)
        _months = State(initialValue: Self.window(around: month, calendar: model.calendar))
    }

    private static func window(around month: Date, calendar: Calendar) -> [Date] {
        (-reach...reach).map { CalendarDates.shift(month, mode: .month, by: $0, calendar: calendar) }
    }
    private var center: Date { months[Self.reach] }
    private var anchorMonth: Date { CalendarDates.startOfMonth(model.anchor, calendar: calendar) }
    private func distance(_ from: Date, _ to: Date) -> Int {
        calendar.dateComponents([.month], from: from, to: to).month ?? 0
    }

    var body: some View {
        GeometryReader { geo in
            let column = (geo.size.width - weekColumn) / 7
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: weekColumn)
                    ForEach(0..<7, id: \.self) { index in
                        Text(CalendarText.shortWeekdays[index].uppercased()).font(.caption2.weight(.semibold)).tracking(0.6)
                            .foregroundStyle(index >= 5 ? CalendarPalette.quiet : Color.secondary)
                            .padding(.leading, CalendarSpace.s)
                            .frame(width: column, alignment: .leading)
                            .accessibilityLabel(CalendarText.weekdays[index])
                    }
                }
                .frame(height: 28)
                Rectangle().fill(CalendarPalette.hairline).frame(height: 0.5)
                GeometryReader { inner in
                    pages(column: column, height: inner.size.height)
                }
            }
        }
        // The form the placeholder opened closed (saved or cancelled): it goes.
        .onChange(of: model.draft?.id) { _, id in creation.formChanged(to: id) }
        .accessibilityAction(named: "Nächster Monat") { model.step(1) }
        .accessibilityAction(named: "Vorheriger Monat") { model.step(-1) }
    }

    private func pages(column: CGFloat, height: CGFloat) -> some View {
        // Paging only when every month (up to six weeks) fits its page.
        let paging = 6 * (minimumRow + 0.5) <= height
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    // Own id type: a page's month start must not equal the id of
                    // its first day's cell or week row (`scrollTo` would find those).
                    ForEach(months.map(CalendarMonthPage.init), id: \.self) { page in
                        self.page(page.start, column: column, height: paging ? height : nil)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(CalendarMonthPaging(paging: paging))
            .scrollPosition(id: Binding(get: { visibleMonth.map(CalendarMonthPage.init) },
                                        set: { visibleMonth = $0?.start }), anchor: .center)
            .modifier(CalendarMonthScrollStart(centered: paging, idle: $scrollIdle))
            .scrollIndicators(.hidden)
            .scrollDisabled(creating)
            .onAppear { turn(to: anchorMonth, proxy) }
            // Rotation, Split View, Dynamic Type: back to the anchor's page.
            .onChange(of: height) { _, _ in turn(to: anchorMonth, proxy) }
            .onChange(of: paging) { _, _ in turn(to: anchorMonth, proxy) }
            .onChange(of: anchorMonth) { _, month in
                if month != visibleMonth { turn(to: month, proxy) }
            }
            .onChange(of: visibleMonth) { _, _ in commitScroll(proxy) }
            .onChange(of: scrollIdle) { _, _ in commitScroll(proxy) }
        }
    }

    /// Shows `month`'s page without scrolling motion (taps get the period
    /// motion of the calendar, keys none). Recentres the months first when
    /// it lies near or beyond their ends.
    private func turn(to month: Date, _ proxy: ScrollViewProxy) {
        settling.mark()
        if abs(distance(center, month)) > Self.reach - 12 {
            NotyMotion.instant { months = Self.window(around: month, calendar: calendar) }
        }
        NotyMotion.instant {
            visibleMonth = month
            proxy.scrollTo(CalendarMonthPage(start: month), anchor: .center)
        }
        // After the layout of new pages (first appearance, recentred months).
        Task { @MainActor in
            NotyMotion.instant { proxy.scrollTo(CalendarMonthPage(start: month), anchor: .center) }
        }
    }

    /// The user's scroll rests on another month: it becomes the anchor.
    private func commitScroll(_ proxy: ScrollViewProxy) {
        guard scrollIdle, let month = visibleMonth else { return }
        if settling.recent {
            // A programmatic turn is still landing: keep the anchor's page.
            if month != anchorMonth { NotyMotion.instant { visibleMonth = anchorMonth } }
            return
        }
        guard month != anchorMonth else { return }
        scrolled(month)
        if abs(distance(center, month)) > Self.reach - 12 { turn(to: month, proxy) }
    }

    /// One month: its weeks (paging: filling `height`; free: rows of the
    /// minimum height below a small title). Pinch targets and creating
    /// only on the shown page (a week can be on two pages).
    private func page(_ month: Date, column: CGFloat, height: CGFloat?) -> some View {
        let grid = CalendarMonthGrid(month: month, calendar: calendar)
        let count = CGFloat(grid.weeks.count)
        let row = height.map { max(minimumRow, ($0 - 0.5 * count) / count) } ?? minimumRow
        let pitch = row + 0.5
        let shown = month == visibleMonth
        let days = grid.weeks.flatMap(\.days)
        return VStack(spacing: 0) {
            if height == nil {
                let index = calendar.component(.month, from: month) - 1
                Text("\(CalendarText.months[index]) \(calendar.component(.year, from: month))")
                    .font(.headline)
                    .padding(.leading, weekColumn + CalendarSpace.s)
                    .frame(maxWidth: .infinity, minHeight: titleRow, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(spacing: 0) {
                ForEach(grid.weeks, id: \.days.first) { week in
                    HStack(spacing: 0) {
                        Text("\(week.number)").font(.caption2).monospacedDigit().foregroundStyle(CalendarPalette.quiet)
                            .frame(width: weekColumn, height: row, alignment: .top).padding(.top, 9)
                            .accessibilityLabel("Kalenderwoche \(week.number)")
                        ForEach(week.days, id: \.self) { day in
                            cell(day, inMonth: grid.contains(day, calendar: calendar), width: column, height: row)
                        }
                    }
                    .frame(height: row)
                    // Pinch on the row opens this week; lights up after zooming out of it.
                    .calendarZoomTarget(.week, start: week.days[0], cornerRadius: 6, enabled: shown)
                    Rectangle().fill(CalendarPalette.hairline).frame(height: 0.5)
                }
            }
            .overlay(alignment: .topLeading) {
                CalendarCreateMonthPlaceholder(state: creation, page: month, left: weekColumn, column: column, row: pitch, rows: grid.weeks.count)
            }
            // Hold a day and drag over days and weeks: a new all-day event.
            .background {
                CalendarHoldDrag(enabled: creatable && shown,
                                 canBegin: { monthFree($0, days: days, column: column, row: row, pitch: pitch, rows: grid.weeks.count) },
                                 interrupted: { zoom?.recentPinch == true }) { phase, point in
                    monthCreate(phase, point, month: month, days: days, column: column, pitch: pitch, rows: grid.weeks.count)
                }
                .accessibilityHidden(true)
            }
        }
        .frame(height: height)
    }

    /// Where a hold may create: the date and the free part of a day cell –
    /// not its entry lines, „+ n weitere“ or the dots (same layout as `cell`),
    /// which keep their taps and may get a long press of their own later.
    private func monthFree(_ point: CGPoint, days: [Date], column: CGFloat, row: CGFloat, pitch: CGFloat, rows: Int) -> Bool {
        guard point.x >= weekColumn, point.y >= 0, column > 0, pitch > 0 else { return false }
        let index = CalendarCreation.gridIndex(x: Double(point.x - weekColumn), y: Double(point.y), cellWidth: Double(column),
                                               cellHeight: Double(pitch), columns: 7, rows: rows)
        guard days.indices.contains(index) else { return false }
        let count = model.events(on: days[index]).count
        guard count > 0 else { return true }
        let occupied: CGFloat
        if column < Self.dotColumn {
            occupied = 40
        } else {
            let capacity = min(maximumLines, Int((row - dateRow - 6) / line))
            let split = CalendarOverflow.split(total: count, capacity: capacity)
            occupied = CGFloat(split.shown + (split.hidden > 0 ? 1 : 0)) * (line + 1)
        }
        let y = point.y - CGFloat(index / 7) * pitch
        return y < dateRow - 1 || y > dateRow + occupied + 2
    }

    /// Press: the day under the finger; drag: every day from there to the
    /// day under the finger (row by row); let go: the form, all-day.
    private func monthCreate(_ phase: CalendarHoldDrag.Phase, _ point: CGPoint, month: Date, days: [Date],
                             column: CGFloat, pitch: CGFloat, rows: Int) {
        let state = creation
        let index = CalendarCreation.gridIndex(x: Double(point.x - weekColumn), y: Double(point.y), cellWidth: Double(column),
                                               cellHeight: Double(pitch), columns: 7, rows: rows)
        tapGuard.mark()
        switch phase {
        case .began:
            state.clear(animated: false)
            state.page = month
            state.anchorIndex = index
            state.show(range: index...index, reduced: reduceMotion)
            creating = true
        case .changed:
            guard state.page == month, let anchor = state.anchorIndex else { return }
            state.show(range: CalendarCreation.days(from: anchor, to: index, count: days.count), reduced: reduceMotion)
        case .ended:
            creating = false
            guard state.page == month, let range = state.range, days.indices.contains(range.lowerBound),
                  days.indices.contains(range.upperBound) else { state.clear(animated: true); return }
            if let id = model.requestNewEvent(start: days[range.lowerBound], end: days[range.upperBound], allDay: true) {
                state.draftID = id
            } else {
                state.clear(animated: true)
            }
        case .cancelled:
            creating = false
            state.clear(animated: true)
        }
    }

    private func cell(_ day: Date, inMonth: Bool, width: CGFloat, height: CGFloat) -> some View {
        let events = model.events(on: day)
        let capacity = min(maximumLines, Int((height - dateRow - 6) / line))
        let split = CalendarOverflow.split(total: events.count, capacity: capacity)
        let isToday = calendar.isDate(day, inSameDayAs: model.today)
        let weekend = CalendarDates.weekdayIndex(day, calendar: calendar) >= 5
        let holiday = events.contains { $0.source == .holidays }
        return VStack(alignment: .leading, spacing: 1) {
            Button { if !tapGuard.recent && zoom?.recentPinch != true { model.open(day, in: .day) } } label: {
                Text("\(calendar.component(.day, from: day))")
                    .font(.subheadline.weight(isToday ? .bold : .regular)).monospacedDigit()
                    .foregroundStyle(isToday ? Color.white : !inMonth ? CalendarPalette.quiet : weekend ? Color.secondary : Color.primary)
                    .frame(minWidth: 26, minHeight: 26)
                    .background { if isToday { Circle().fill(CalendarPalette.today) } }
                    .calendarTodayPulse(isToday)
                    .padding(.leading, 3)
                    .frame(minWidth: 44, minHeight: dateRow, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(CalendarText.longDate(day, calendar: calendar) + (isToday ? ", heute" : "")
                                + ", " + NotyText.count(events.count, "Termin", "Termine"))
            .accessibilityHint("Öffnet den Tag")
            if width < Self.dotColumn {
                dots(events, day: day)
            } else {
                ForEach(events.prefix(split.shown)) { event in
                    CalendarMonthRow(event: event, model: model, swipe: tapGuard).frame(height: line)
                }
                if split.hidden > 0 {
                    Button { if !tapGuard.recent && zoom?.recentPinch != true { showAll(day) } } label: {
                        Text(CalendarText.more(split.hidden)).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                            .frame(maxWidth: .infinity, minHeight: line, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(NotyText.count(split.hidden, "weiterer Termin", "weitere Termine") + " am \(CalendarText.shortDate(day, calendar: calendar))")
                    .accessibilityHint("Zeigt die vollständige Tagesliste")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 3)
        .frame(width: width, height: height, alignment: .topLeading)
        .background {
            // Weekends and holidays slightly set apart, today faintly marked.
            if isToday {
                CalendarPalette.today.opacity(0.07)
            } else if inMonth && (weekend || holiday) {
                Color.white.opacity(holiday ? 0.045 : 0.025)
            }
        }
        .overlay(alignment: .leading) { Rectangle().fill(CalendarPalette.hairline.opacity(0.6)).frame(width: 0.5) }
        .opacity(inMonth ? 1 : 0.6)
    }

    /// Narrow columns: one coloured dot per entry (at most eight) and
    /// „+ n“; the whole area opens the complete day list – nothing is dropped.
    @ViewBuilder private func dots(_ events: [CalendarEntry], day: Date) -> some View {
        if !events.isEmpty {
            let shown = events.prefix(8)
            let cancelled = events.filter { $0.status == .cancelled }.count
            Button { if !tapGuard.recent && zoom?.recentPinch != true { showAll(day) } } label: {
                VStack(alignment: .leading, spacing: 3) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(7), spacing: 3), count: 4), alignment: .leading, spacing: 3) {
                        ForEach(shown) { event in
                            // Cancelled: a hollow ring, not only a fainter dot.
                            if event.status == .cancelled {
                                Circle().strokeBorder(model.entryColor(event), lineWidth: 1.5).frame(width: 7, height: 7)
                            } else {
                                Circle().fill(model.entryColor(event)).frame(width: 7, height: 7)
                            }
                        }
                    }
                    if events.count > shown.count {
                        Text("+ \(events.count - shown.count)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 6).padding(.top, 2)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .topLeading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NotyText.count(events.count, "Termin", "Termine")
                                + (cancelled > 0 ? ", davon \(NotyText.count(cancelled, "Ausfall", "Ausfälle"))" : "")
                                + " am \(CalendarText.shortDate(day, calendar: calendar))")
            .accessibilityHint("Zeigt die vollständige Tagesliste")
        }
    }
}

/// One compact line of the month: colour dot, title, time if it fits.
/// All-day entries get the stripe and tint of the week chips.
struct CalendarMonthRow: View {
    let event: CalendarEntry
    @ObservedObject var model: CalendarModel
    @Environment(\.calendarOrigin) private var origins
    @Environment(\.calendarZoom) private var zoom
    /// Month grid: a hold-and-drag that ends on the row does not open it.
    var swipe: CalendarSwipeGuard?

    var body: some View {
        let color = model.entryColor(event)
        let selected = model.selection == event.id
        let notes = model.hasNotes(event)
        let cancelled = event.status == .cancelled
        Button {
            guard swipe?.recent != true, zoom?.recentPinch != true else { return }
            origins?.tap(event.id, key: "month/" + event.id)
            model.selection = event.id
        } label: {
            HStack(spacing: CalendarSpace.xs) {
                if event.allDay {
                    Rectangle().fill(color).frame(width: 3)
                } else {
                    Circle().fill(color).frame(width: 6, height: 6)
                }
                if let symbol = event.status.symbol {
                    Image(systemName: symbol).font(.caption2.weight(.semibold)).foregroundStyle(cancelled ? Color.orange : .secondary)
                }
                Text(event.title).font(.caption).strikethrough(cancelled).lineLimit(1).layoutPriority(1)
                Spacer(minLength: 2)
                if notes { Image(systemName: "note.text").font(.caption2).foregroundStyle(.secondary) }
                if !event.allDay {
                    // The start time yields first when the column is narrow.
                    ViewThatFits(in: .horizontal) {
                        Text(CalendarText.clock(event.start, calendar: model.calendar))
                        Color.clear.frame(width: 0)
                    }
                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .padding(.trailing, CalendarSpace.xs).padding(.leading, event.allDay ? 0 : CalendarSpace.xs)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .opacity(cancelled ? 0.55 : 1)
            .background {
                if event.allDay || selected {
                    RoundedRectangle(cornerRadius: 4).fill(CalendarPalette.tint(event.allDay ? color : CalendarPalette.selection, selected: selected && event.allDay))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay { if selected { RoundedRectangle(cornerRadius: 4).strokeBorder(CalendarPalette.selection, lineWidth: 1.5) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 4))
        .hoverEffect(.highlight)
        .foregroundStyle(.primary)
        .calendarOrigin("month/" + event.id)
        .accessibilityLabel(model.accessibilityText(event, notes: notes))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Complete list of one day („+ n weitere“).
struct CalendarDayListSheet: View {
    let day: Date
    @ObservedObject var model: CalendarModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            let events = model.events(on: day)
            List {
                Section {
                    ForEach(events) { event in
                        Button {
                            model.selection = event.id
                            dismiss()
                        } label: { CalendarListRow(event: event, model: model) }
                        .accessibilityLabel(model.accessibilityText(event, notes: model.hasNotes(event)))
                    }
                } footer: {
                    Text(NotyText.count(events.count, "Termin", "Termine") + (model.showsSamples ? " · Beispieldaten" : ""))
                }
            }
            .overlay { if events.isEmpty { ContentUnavailableView("Keine Termine", systemImage: "calendar") } }
            .navigationTitle(CalendarText.longDate(day, calendar: model.calendar))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fertig") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Tag öffnen") { model.open(day, in: .day); dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// Row of lists (day list, search).
struct CalendarListRow: View {
    let event: CalendarEntry
    @ObservedObject var model: CalendarModel
    var showsDate = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(model.entryColor(event)).frame(width: 4, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if let symbol = event.status.symbol { Image(systemName: symbol).font(.caption) }
                    Text(event.title).font(.body.weight(.medium)).strikethrough(event.status == .cancelled)
                    if model.hasNotes(event) { Image(systemName: "note.text").font(.caption).foregroundStyle(.secondary) }
                }
                Text([showsDate ? CalendarText.shortDate(event.start, calendar: model.calendar) : nil,
                      event.timeText(model.calendar), event.room, event.status.label].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            if model.isReadOnly(event) { Image(systemName: "lock").font(.caption).foregroundStyle(.secondary) }
        }
        .foregroundStyle(.primary)
        .frame(minHeight: 44)
    }
}

/// Year: twelve light months; a quiet dot marks event days, a faint band
/// the holidays (WebUntis, else the built-in NRW table; samples: fictitious).
/// Tapping a day opens it, the month name the month.
/// „Jahr öffnet beim aktuellen Monat (08.11.2026)“: the anchor's month
/// stands in the middle – on opening (without a first frame at January),
/// after zooming out of a month (that month lights up there), after ‹ ›,
/// „Heute“ and a change of the anchor. In the running year without
/// navigation the anchor is today, so it is the current month.
struct CalendarYearView: View {
    @ObservedObject var model: CalendarModel
    @Environment(\.calendarZoom) private var zoom
    @Environment(\.calendarTodayPulse) private var todayPulse
    @ScaledMetric(relativeTo: .body) private var cell: CGFloat = 44
    /// Estimates for the opening position (iPadOS 18): weekday letters and
    /// one legend line.
    @ScaledMetric(relativeTo: .caption2) private var smallLine: CGFloat = 14
    /// Month tile at the scroll position; starts at the anchor's month.
    @State private var focus: CalendarYearTile?
    private var calendar: Calendar { model.calendar }

    init(model: CalendarModel) {
        _model = ObservedObject(wrappedValue: model)
        _focus = State(initialValue: CalendarYearTile(month: model.calendar.component(.month, from: model.anchor)))
    }

    var body: some View {
        GeometryReader { geo in
            let tile = cell * 7
            let columns = max(1, Int((geo.size.width - 2 * CalendarSpace.xl + 32) / (tile + 32)))
            let first = CalendarDates.startOfYear(model.anchor, calendar: calendar)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: CalendarSpace.l) {
                        // One scroll target layout; its children (the tiles) carry
                        // their own id type, distinct from the numbers inside a tile.
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(tile), spacing: 32, alignment: .top), count: columns),
                                  alignment: .leading, spacing: CalendarSpace.xl) {
                            ForEach((1...12).map(CalendarYearTile.init), id: \.self) { item in
                                month(CalendarDates.shift(first, mode: .month, by: item.month - 1, calendar: calendar))
                                    .id(item)
                            }
                        }
                        .scrollTargetLayout()
                        legend
                    }
                    .padding(.horizontal, CalendarSpace.xl).padding(.vertical, CalendarSpace.l)
                    .frame(maxWidth: .infinity)
                }
                .scrollPosition(id: $focus, anchor: .center)
                .modifier(CalendarYearScrollStart(anchor: openingAnchor(columns: columns, viewport: geo.size.height)))
                .onAppear { center(proxy) }
                .onChange(of: model.anchor) { _, _ in center(proxy) }
                .onChange(of: columns) { _, _ in center(proxy) }
                // „Heute“ tapped while the anchor already was today.
                .onChange(of: todayPulse.count) { _, _ in center(proxy) }
            }
        }
    }

    /// The anchor's month into the middle, without scrolling motion (the
    /// period change has its own); again after the first layout pass.
    private func center(_ proxy: ScrollViewProxy) {
        let item = CalendarYearTile(month: calendar.component(.month, from: model.anchor))
        NotyMotion.instant {
            focus = item
            proxy.scrollTo(item, anchor: .center)
        }
        Task { @MainActor in NotyMotion.instant { proxy.scrollTo(item, anchor: .center) } }
    }

    /// Where the scroll view opens (iPadOS 18, `.initialOffset`): the unit
    /// point that puts the anchor's month row about into the middle, from
    /// the layout's sizes – so the first frame is not January. `center`
    /// then corrects the last points.
    private func openingAnchor(columns: Int, viewport: CGFloat) -> UnitPoint {
        let rows = (12 + columns - 1) / columns
        let row = (calendar.component(.month, from: model.anchor) - 1) / columns
        let tileHeight = 44 + smallLine + 6 * cell
        let content = 2 * CalendarSpace.l + CGFloat(rows) * tileHeight + CGFloat(rows - 1) * CalendarSpace.xl
            + CalendarSpace.l + 2 * smallLine
        guard content > viewport + 1 else { return .top }
        let middle = CalendarSpace.l + CGFloat(row) * (tileHeight + CalendarSpace.xl) + tileHeight / 2
        let fraction = (middle - viewport / 2) / (content - viewport)
        return UnitPoint(x: 0.5, y: min(1, max(0, fraction)))
    }

    /// The same source as in the status popover (`holidaySourceText`):
    /// WebUntis holidays where loaded, otherwise NRW from the built-in table.
    private var holidayLegend: String {
        model.showsSamples ? "Ferien (Beispiel, keine echte Ferienquelle)" : model.holidaySourceText
    }

    private var legend: some View {
        HStack(alignment: .top, spacing: CalendarSpace.l) {
            Label { Text("Termine") } icon: { Circle().fill(Color.secondary).frame(width: 4, height: 4) }
            Label { Text(holidayLegend).fixedSize(horizontal: false, vertical: true) } icon: {
                Capsule().fill(CalendarPalette.holidays.opacity(0.3)).frame(width: 16, height: 8)
            }
        }
        .font(.caption2).foregroundStyle(.secondary)
        .frame(maxWidth: 640, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func month(_ month: Date) -> some View {
        let grid = CalendarMonthGrid(month: month, calendar: calendar)
        let current = calendar.isDate(month, equalTo: model.today, toGranularity: .month)
        let index = calendar.component(.month, from: month) - 1
        return VStack(alignment: .leading, spacing: 0) {
            Button { if zoom?.recentPinch != true { model.open(month, in: .month) } } label: {
                Text(CalendarText.months[index]).font(.headline)
                    .foregroundStyle(current ? CalendarPalette.today : .primary)
                    .padding(.leading, 6)
                    .frame(minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(CalendarText.months[index]) \(calendar.component(.year, from: month))")
            .accessibilityHint("Öffnet den Monat")
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { Text(String(CalendarText.shortWeekdays[$0].prefix(1))).frame(width: cell) }
            }
            .font(.caption2).foregroundStyle(CalendarPalette.quiet).accessibilityHidden(true)
            // Always six rows: the tiles line up across the year.
            ForEach(0..<6, id: \.self) { row in
                HStack(spacing: 0) {
                    if row < grid.weeks.count {
                        ForEach(grid.weeks[row].days, id: \.self) { day in
                            if grid.contains(day, calendar: calendar) { dayCell(day) } else { Color.clear.frame(width: cell, height: cell) }
                        }
                    } else {
                        Color.clear.frame(width: cell * 7, height: cell)
                    }
                }
            }
        }
        // Pinch on the tile opens this month; lights up after zooming out of it.
        .calendarZoomTarget(.month, start: month, cornerRadius: 12)
    }

    private func dayCell(_ day: Date) -> some View {
        let events = model.events(on: day)
        let holiday = events.first { $0.source == .holidays }
        let count = events.filter { $0.source != .holidays }.count
        let isToday = calendar.isDate(day, inSameDayAs: model.today)
        return Button { if zoom?.recentPinch != true { model.open(day, in: .day) } } label: {
            VStack(spacing: 2) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.footnote.weight(isToday ? .semibold : .regular)).monospacedDigit()
                    .foregroundStyle(isToday ? Color.white : .primary)
                    .frame(width: 26, height: 26)
                    .background { if isToday { Circle().fill(CalendarPalette.today) } }
                    .calendarTodayPulse(isToday)
                Circle().fill(count > 0 ? Color.secondary : .clear).frame(width: 4, height: 4)
            }
            .frame(width: cell, height: cell)
            .background {
                if holiday != nil { Rectangle().fill(CalendarPalette.holidays.opacity(0.22)).padding(.vertical, 7) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel([CalendarText.longDate(day, calendar: calendar), isToday ? "heute" : nil,
                             count > 0 ? NotyText.count(count, "Termin", "Termine") : nil, holiday?.title].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Öffnet den Tag")
    }
}

/// Scroll identity of a month page (its first day). A plain `Date` would
/// equal the identity of that day's cell and of a week row starting on it.
struct CalendarMonthPage: Hashable {
    let start: Date
}

/// Year: scroll identity of a month tile (1–12), distinct from the plain
/// numbers of the weekday and row loops inside the tiles.
struct CalendarYearTile: Hashable {
    let month: Int
}

/// Month pages: one page per scroll when every month fits its page,
/// otherwise free scrolling (large text, small window). Aligned to the
/// pages themselves (`viewAligned`, at most one per gesture), not to the
/// container's height like `.paging`: a page measured a little differently
/// from the scroll container (safe area, rounding) still lands exactly, also
/// after the mouse wheel.
struct CalendarMonthPaging: ScrollTargetBehavior {
    let paging: Bool

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        if paging { ViewAlignedScrollTargetBehavior(limitBehavior: .always).updateTarget(&target, context: context) }
    }
}

/// iPadOS 18+: the year opens at `anchor` (the anchor's month row); before,
/// `CalendarYearView.center` scrolls there on appear.
private struct CalendarYearScrollStart: ViewModifier {
    let anchor: UnitPoint

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.defaultScrollAnchor(anchor, for: .initialOffset)
        } else {
            content
        }
    }
}

/// iPadOS 18+: the months open on the middle page (the anchor's month)
/// without a first frame elsewhere, and report when a scroll comes to rest.
/// iPadOS 17: `ScrollViewReader` turns to the page on appear; every scroll
/// position counts at once.
private struct CalendarMonthScrollStart: ViewModifier {
    let centered: Bool
    @Binding var idle: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .defaultScrollAnchor(centered ? .center : nil, for: .initialOffset)
                .onScrollPhaseChange { _, phase in
                    let rest = phase == .idle
                    if idle != rest { idle = rest }
                }
        } else {
            content
        }
    }
}
