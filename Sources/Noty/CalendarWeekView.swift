import SwiftUI
import NotebookCore

/// Week and day: fixed day headers, all-day row, vertically scrolling
/// 24-hour grid. Columns narrower than `minimumColumn` scroll sideways
/// instead of switching the chosen view.
struct CalendarTimeGrid: View {
    let days: [Date]
    @ObservedObject var model: CalendarModel
    /// Day view: more detail on the cards.
    var detailed = false
    @ScaledMetric(relativeTo: .body) private var hourHeight: CGFloat = 60
    @ScaledMetric(relativeTo: .caption) private var gutter: CGFloat = 52
    @ScaledMetric(relativeTo: .caption) private var laneHeight: CGFloat = 24
    @ScaledMetric(relativeTo: .headline) private var headerHeight: CGFloat = 58
    private let topInset: CGFloat = 10
    /// An own event is being moved or stretched: the grid does not scroll meanwhile.
    @State private var dragging = false
    /// Holding and dragging creates a new event (docs/CALENDAR-PLAN.md, „Termin
    /// per Halten und Ziehen anlegen“). The placeholder lives in its own
    /// object: a finger step re-renders only the placeholder; `creating`
    /// (once per creation) stops the scrolling.
    @State private var creation = CalendarCreateState()
    @State private var allDayCreation = CalendarCreateState()
    @State private var creating = false
    /// A hold on a read-only all-day chip created: its tap on release opens nothing.
    @State private var allDayGuard = CalendarSwipeGuard()
    // Start position (`CalendarScrollStart`; docs: CALENDAR-PLAN „Startposition“)
    /// A new view or period wants its start hour; done once the hour grid has a height.
    @State private var startPending = true
    /// Height of the hour grid's scroll view (0 until its first layout).
    @State private var viewport: CGFloat = 0
    /// The hour last put at the top by `placeStart`, and when.
    @State private var placedHour: Int?
    @State private var placedAt = Date.distantPast
    /// Bumped by every placement: a late second pass of an older one is dropped.
    @State private var placement = 0
    /// The user scrolled (or held, dragged, created) since the last placement:
    /// arriving data never moves the grid then.
    @State private var userScrolled = false
    @Environment(\.calendarTodayPulse) private var todayPulse
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.calendarZoom) private var zoom
    @Environment(\.calendarLocalChange) private var localChange
    private var calendar: Calendar { model.calendar }
    private var minimumColumn: CGFloat { days.count == 1 ? 260 : 96 }
    /// New events can be created here at all (the all-day row then stays visible).
    private var canCreate: Bool { model.canWrite && !model.showsSamples }
    /// … and right now: nothing presented above the grid, no own event being moved.
    private var creatable: Bool { canCreate && model.selectedEvent == nil && model.draft == nil && !dragging }

    var body: some View {
        GeometryReader { geo in
            let natural = (geo.size.width - gutter) / CGFloat(max(1, days.count))
            let column = max(natural, minimumColumn)
            let allDay = canCreate || !allDayItems.isEmpty
            // The hour grid's height before its own layout (first frame on iPadOS 18).
            let estimate = geo.size.height - headerHeight - 0.5 - (allDay ? allDayHeight : 0)
            let content = VStack(spacing: 0) {
                header(column)
                // When there is something all-day in the shown days – and always
                // while new events can be created (holding there creates all-day ones).
                if allDay { allDayRow(column) }
                Rectangle().fill(CalendarPalette.hairline).frame(height: 0.5)
                hours(column, estimate: estimate)
            }
            .frame(width: gutter + column * CGFloat(days.count), height: geo.size.height)
            if natural < minimumColumn {
                ScrollView(.horizontal) { content }
                    .scrollDisabled(dragging || creating)
                    .accessibilityHint("Waagerecht scrollbar, um alle Tage zu sehen")
            } else {
                content
            }
        }
        // Another period: a placeholder of the old days goes at once, and so does
        // the scroll lock of a card that was held meanwhile (⌘→ or „›“ with a
        // second finger remove the card; its own report need not arrive any more).
        .onChange(of: days) { _, _ in
            endCreations()
            if dragging { dragging = false }
        }
        // The form the placeholder opened closed (saved or cancelled): it goes.
        .onChange(of: model.draft?.id) { _, id in
            creation.formChanged(to: id)
            allDayCreation.formChanged(to: id)
        }
    }

    private func endCreations() {
        creation.clear(animated: false)
        allDayCreation.clear(animated: false)
        if creating { creating = false }
    }

    // MARK: Header

    /// Heads like Apple Kalender: the weekday small above the date, today's
    /// date in the red circle, weekends and holidays quieter (holidays also
    /// named in the all-day row, never by tint alone).
    private func header(_ column: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text("KW \(CalendarDates.isoWeek(days[0], calendar: calendar).week)")
                .font(.caption2.weight(.medium)).monospacedDigit().foregroundStyle(CalendarPalette.quiet)
                .frame(width: gutter)
                .accessibilityLabel("Kalenderwoche \(CalendarDates.isoWeek(days[0], calendar: calendar).week)")
            ForEach(days, id: \.self) { day in
                let isToday = calendar.isDate(day, inSameDayAs: model.today)
                let weekday = CalendarDates.weekdayIndex(day, calendar: calendar)
                let quiet = weekday >= 5 || isHoliday(day)
                Button { if days.count > 1 && zoom?.recentPinch != true { model.open(day, in: .day) } } label: {
                    VStack(spacing: 1) {
                        Text((detailed ? CalendarText.weekdays[weekday] : CalendarText.shortWeekdays[weekday]).uppercased())
                            .font(.caption2.weight(.semibold)).tracking(0.6)
                            .foregroundStyle(isToday ? CalendarPalette.today : quiet ? CalendarPalette.quiet : Color.secondary)
                        Text("\(calendar.component(.day, from: day))")
                            .font(.title3.weight(isToday ? .bold : .medium)).monospacedDigit()
                            .foregroundStyle(isToday ? Color.white : quiet ? Color.secondary : .primary)
                            .frame(minWidth: 32, minHeight: 32)
                            .background { if isToday { Circle().fill(CalendarPalette.today) } }
                            .calendarTodayPulse(isToday)
                    }
                    .frame(width: column, height: headerHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(days.count == 1)
                .accessibilityLabel(CalendarText.longDate(day, calendar: calendar) + (isToday ? ", heute" : "") + (isHoliday(day) ? ", Ferien" : ""))
                .accessibilityHint(days.count > 1 ? "Öffnet den Tag" : "")
                // Week: a pinch over this column opens the day; lights up after zooming out of it.
                .calendarZoomTarget(.day, start: day, cornerRadius: 8, enabled: days.count > 1)
            }
        }
        .frame(height: headerHeight)
    }

    private func isHoliday(_ day: Date) -> Bool { model.events(on: day).contains { $0.source == .holidays } }

    // MARK: All-day row

    private struct AllDayItem: Identifiable {
        let event: CalendarEntry
        let first: Int, last: Int, lane: Int
        var id: String { event.id }
    }

    private var allDayItems: [AllDayItem] {
        var seen = Set<String>()
        var spans: [(CalendarEntry, Int, Int)] = []
        for day in days {
            for event in model.events(on: day) where event.allDay && seen.insert(event.id).inserted {
                if let range = CalendarAllDayLayout.columns(start: event.start, endExclusive: event.end, days: days, calendar: calendar) {
                    spans.append((event, range.first, range.last))
                }
            }
        }
        let lanes = CalendarAllDayLayout.lanes(spans.map { ($0.1, $0.2) })
        return spans.indices.map { AllDayItem(event: spans[$0].0, first: spans[$0].1, last: spans[$0].2, lane: lanes[$0]) }
    }

    /// At least one lane: the empty row is where all-day events are created.
    private var allDayHeight: CGFloat {
        CGFloat(max(1, (allDayItems.map(\.lane).max() ?? -1) + 1)) * laneHeight + 6
    }

    private func allDayRow(_ column: CGFloat) -> some View {
        let items = allDayItems
        let height = allDayHeight
        return ZStack(alignment: .topLeading) {
            Text("ganztägig").font(.caption2).foregroundStyle(CalendarPalette.quiet)
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(width: gutter - 6, alignment: .trailing).padding(.top, 6)
                .accessibilityHidden(true)
            ForEach(items) { item in
                let width = CGFloat(item.last - item.first + 1) * column - 4
                CalendarAllDayChip(event: item.event, model: model, hold: allDayGuard)
                    .frame(width: width, height: laneHeight - 3)
                    .offset(x: gutter + CGFloat(item.first) * column + 2, y: 3 + CGFloat(item.lane) * laneHeight)
            }
            CalendarCreateAllDayPlaceholder(state: allDayCreation, gutter: gutter, column: column, days: days.count, height: height)
        }
        // Every lane stays visible; nothing is cut off.
        .frame(width: gutter + column * CGFloat(days.count), height: height, alignment: .topLeading)
        // Hold on free space and drag sideways: a new all-day event over the covered days.
        .background {
            CalendarHoldDrag(enabled: creatable,
                             canBegin: { allDayFree($0, column: column, items: items) },
                             interrupted: { zoom?.recentPinch == true }) { phase, point in
                allDayCreate(phase, point, column: column)
            }
            .accessibilityHidden(true)
        }
    }

    /// Where a hold in the all-day row may create: inside the day columns,
    /// on free space or on a read-only chip (holidays, lessons, read-only
    /// system calendars – a holiday band covers whole weeks, and all-day
    /// chips have no long press of their own). Own chips stay theirs.
    private func allDayFree(_ point: CGPoint, column: CGFloat, items: [AllDayItem]) -> Bool {
        let x = point.x - gutter
        guard x >= 0, x < column * CGFloat(days.count) else { return false }
        return !items.contains { item in
            !model.isReadOnly(item.event) && CGRect(x: gutter + CGFloat(item.first) * column + 2, y: 3 + CGFloat(item.lane) * laneHeight,
                   width: CGFloat(item.last - item.first + 1) * column - 4, height: laneHeight - 3)
                .insetBy(dx: -2, dy: -2).contains(point)
        }
    }

    private func allDayCreate(_ phase: CalendarHoldDrag.Phase, _ point: CGPoint, column: CGFloat) {
        let state = allDayCreation
        let x = Double(point.x - gutter)
        allDayGuard.mark()
        switch phase {
        case .began:
            let day = CalendarCreation.column(x: x, width: Double(column), count: days.count, current: nil, hysteresis: 8)
            state.clear(animated: false)
            state.anchorIndex = day
            state.column = day
            state.show(range: day...day, reduced: reduceMotion)
            creating = true
        case .changed:
            guard let anchor = state.anchorIndex else { return }
            let day = CalendarCreation.column(x: x, width: Double(column), count: days.count, current: state.column, hysteresis: 8)
            state.column = day
            state.show(range: CalendarCreation.days(from: anchor, to: day, count: days.count), reduced: reduceMotion)
        case .ended:
            creating = false
            guard let range = state.range, days.indices.contains(range.lowerBound), days.indices.contains(range.upperBound) else {
                state.clear(animated: true); return
            }
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

    // MARK: Hours

    private func y(_ minutes: Int) -> CGFloat { topInset + CGFloat(minutes) / 60 * hourHeight }

    private func hours(_ column: CGFloat, estimate: CGFloat) -> some View {
        // Once per grid render: derived from the whole offline timetable.
        let homework = model.homeworkDueEntryIDs
        let start = startHour
        let total = y(24 * 60) + topInset
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                ZStack(alignment: .topLeading) {
                    // Laid-out scroll targets (offsets below do not move layout frames).
                    VStack(spacing: 0) {
                        ForEach(0..<24, id: \.self) { hour in Color.clear.frame(height: hourHeight).id("hour-\(hour)") }
                    }
                    .padding(.top, topInset)
                    .allowsHitTesting(false).accessibilityHidden(true)
                    hourLines(column)
                    ForEach(Array(days.enumerated()), id: \.element) { index, day in
                        dayColumn(day, column: column, homework: homework)
                            .frame(width: column, height: y(24 * 60) + topInset, alignment: .topLeading)
                            .offset(x: gutter + CGFloat(index) * column)
                    }
                    nowLine(column)
                    CalendarCreateTimedPlaceholder(state: creation, days: days, calendar: calendar, gutter: gutter,
                                                   column: column, hourHeight: hourHeight, topInset: topInset)
                }
                .frame(width: gutter + column * CGFloat(days.count), height: y(24 * 60) + topInset, alignment: .topLeading)
                // Hold on free space and drag: a new event over the covered quarter hours
                // (and days); near the top/bottom edge the grid scrolls by itself.
                .background {
                    CalendarHoldDrag(enabled: creatable,
                                     canBegin: { gridFree($0, column: column) },
                                     autoScroll: true,
                                     interrupted: { zoom?.recentPinch == true }) { phase, point in
                        timedCreate(phase, point, column: column)
                    }
                    .accessibilityHidden(true)
                }
            }
            .scrollDisabled(dragging || creating)
            // iPadOS 18: a new grid (first open, Woche/Tag, zoom) is at its start
            // hour from the first frame; the passes of `placeStart` confirm it.
            .modifier(CalendarGridScrollStart(anchor: UnitPoint(x: 0.5, y: min(1, max(0, y(start * 60) / max(1, total - estimate)))),
                                              scrolled: { userScrolled = true }))
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                let first = viewport <= 0
                viewport = height
                // Waited for the first layout: now the targets have frames.
                if first, height > 0, startPending { placeStart(proxy) }
            }
            .onAppear { requestStart(proxy) }
            // ‹ ›, trackpad swipe, keys, „Heute“ and a notification: the new period's start.
            .onChange(of: days) { _, _ in requestStart(proxy) }
            // „Heute“ while today is already shown.
            .onChange(of: todayPulse.count) { _, _ in requestStart(proxy) }
            // Entries that arrive just after (loading, first fetch of a week).
            .onChange(of: start) { _, hour in dataMoved(to: hour, proxy) }
            // Holding, creating, moving: the user's position from now on. A
            // period change meanwhile places its start once they end.
            .onChange(of: creating) { _, now in if now { userScrolled = true } else if startPending { placeStart(proxy) } }
            .onChange(of: dragging) { _, now in if now { userScrolled = true } else if startPending { placeStart(proxy) } }
        }
    }

    // MARK: Start position

    /// The start hour of the shown days (`CalendarScrollStart`): the shown
    /// timed entries (hidden calendars do not count) and, when today is
    /// shown, the current time.
    private var startHour: Int {
        var seen = Set<String>()
        let entries = days.flatMap { model.events(on: $0) }
            .filter { !$0.allDay && seen.insert($0.id).inserted }
            .map { (start: $0.start, end: $0.end) }
        let now = Date()
        let today = days.firstIndex { calendar.isDate($0, inSameDayAs: now) }
        let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        return CalendarScrollStart.hour(items: CalendarScrollStart.items(days: days, entries: entries, calendar: calendar),
                                        today: today.map { (day: $0, minute: minute) })
    }

    /// A new view or period (also „Heute“): put its start hour at the top.
    private func requestStart(_ proxy: ScrollViewProxy) {
        startPending = true
        userScrolled = false
        placeStart(proxy)
    }

    /// Without animation (the period change has its own motion; keys none).
    /// Before the first layout it waits for the height (`onGeometryChange`).
    /// A second pass after this layout and a third a moment later: a scroll
    /// view that was just created (Woche/Tag, a width that switches to
    /// sideways scrolling) may not take an early `scrollTo` – the grid then
    /// stayed at 0:00. Never while holding, creating or moving.
    private func placeStart(_ proxy: ScrollViewProxy) {
        guard viewport > 0, !creating, !dragging else { return }
        startPending = false
        let hour = startHour
        placedHour = hour
        placedAt = Date()
        placement += 1
        let generation = placement
        scroll(proxy, to: hour)
        Task { @MainActor in
            scrollAgain(proxy, to: hour, generation: generation)
            try? await Task.sleep(for: .milliseconds(120))
            scrollAgain(proxy, to: hour, generation: generation)
        }
    }

    private func scrollAgain(_ proxy: ScrollViewProxy, to hour: Int, generation: Int) {
        guard generation == placement, !userScrolled, !creating, !dragging else { return }
        scroll(proxy, to: hour)
    }

    private func scroll(_ proxy: ScrollViewProxy, to hour: Int) {
        NotyMotion.instant { proxy.scrollTo("hour-\(hour)", anchor: .top) }
    }

    /// How long after a placement arriving entries may still move the grid.
    private static let settleWindow: TimeInterval = 20

    /// Entries arrived (or went) and the start hour is another one: follow
    /// it only shortly after the period was shown and only while nobody
    /// scrolled or touched the grid – a later refresh or a notification never
    /// moves it. iPadOS 17 cannot tell a user's scroll: there only periods
    /// and views place the grid.
    private func dataMoved(to hour: Int, _ proxy: ScrollViewProxy) {
        guard #available(iOS 18.0, *) else { return }
        guard !startPending, let placed = placedHour, hour != placed, !userScrolled, !creating, !dragging,
              model.selection == nil, model.draft == nil,
              Date().timeIntervalSince(placedAt) < Self.settleWindow else { return }
        placedHour = hour
        placement += 1
        scroll(proxy, to: hour)
    }

    private func hourLines(_ column: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            // Tapping empty space ends the selection.
            Color.clear.contentShape(Rectangle()).onTapGesture { model.selection = nil }
            ForEach(days.indices, id: \.self) { index in
                // Weekends and holidays slightly set apart (the holiday is named in the all-day row).
                if CalendarDates.weekdayIndex(days[index], calendar: calendar) >= 5 || isHoliday(days[index]) {
                    Rectangle().fill(Color.white.opacity(isHoliday(days[index]) ? 0.045 : 0.025))
                        .frame(width: column, height: y(24 * 60) + topInset).offset(x: gutter + CGFloat(index) * column)
                        .allowsHitTesting(false)
                }
                Rectangle().fill(CalendarPalette.hairline.opacity(0.6)).frame(width: 0.5, height: y(24 * 60) + topInset)
                    .offset(x: gutter + CGFloat(index) * column).allowsHitTesting(false)
            }
            ForEach(0..<25, id: \.self) { hour in
                HStack(spacing: 6) {
                    Text(CalendarText.hour(hour % 24)).font(.caption2).monospacedDigit().foregroundStyle(CalendarPalette.quiet)
                        .frame(width: gutter - 10, alignment: .trailing)
                        .opacity(hour == 0 || hour == 24 ? 0 : 1)
                    Rectangle().fill(CalendarPalette.hairline).frame(height: 0.5)
                }
                .frame(height: 14)
                .offset(y: y(hour * 60) - 7)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }

    /// Free space of the hour grid: inside the day columns and the 24 hours,
    /// not on a card (same layout as `dayColumn`) nor on the duration handle
    /// of the selected card. Evaluated once per press.
    private func gridFree(_ point: CGPoint, column: CGFloat) -> Bool {
        let x = point.x - gutter
        guard x >= 0, x < column * CGFloat(days.count), point.y >= topInset, point.y <= y(24 * 60) else { return false }
        let index = min(days.count - 1, Int(x / column))
        let inner = column - 8
        return !timedItems(days[index]).contains { item in
            let width = inner / CGFloat(item.placement.columns)
            let height = max(22, CGFloat(item.end - item.start) / 60 * hourHeight - 3)
            var rect = CGRect(x: gutter + CGFloat(index) * column + 4 + CGFloat(item.placement.column) * width,
                              y: y(item.start) + 1.5, width: max(20, width - 2), height: height)
            if model.selection == item.event.id { rect.size.height += 14 }
            return rect.insetBy(dx: -2, dy: -2).contains(point)
        }
    }

    /// Press: the quarter hour under the finger; drag: from there to the
    /// quarter hour (and day) under the finger, both included; let go: the
    /// form, pre-filled. Steps snap without animation.
    private func timedCreate(_ phase: CalendarHoldDrag.Phase, _ point: CGPoint, column: CGFloat) {
        let state = creation
        let x = Double(point.x - gutter)
        let minutes = Double((point.y - topInset) / hourHeight * 60)
        switch phase {
        case .began:
            let day = CalendarCreation.column(x: x, width: Double(column), count: days.count, current: nil)
            let cell = CalendarCreation.cell(day: day, minutes: minutes, dayCount: days.count)
            state.clear(animated: false)
            state.anchorCell = cell
            state.column = day
            state.show(span: CalendarCreation.span(from: cell, to: cell), reduced: reduceMotion)
            creating = true
        case .changed:
            guard let anchor = state.anchorCell else { return }
            let day = CalendarCreation.column(x: x, width: Double(column), count: days.count, current: state.column)
            state.column = day
            let cell = CalendarCreation.cell(day: day, minutes: minutes, dayCount: days.count)
            state.show(span: CalendarCreation.span(from: anchor, to: cell), reduced: reduceMotion)
        case .ended:
            creating = false
            guard let span = state.span, let dates = CalendarCreation.dates(span, days: days, calendar: calendar) else {
                state.clear(animated: true); return
            }
            if let id = model.requestNewEvent(start: dates.start, end: dates.end, allDay: false) {
                state.draftID = id
            } else {
                state.clear(animated: true)
            }
        case .cancelled:
            creating = false
            state.clear(animated: true)
        }
    }

    private struct TimedItem: Identifiable {
        let event: CalendarEntry
        let start: Int, end: Int
        let placement: CalendarColumnPlacement
        var id: String { event.id }
    }

    private func timedItems(_ day: Date) -> [TimedItem] {
        let events = model.events(on: day).filter { !$0.allDay }
        let slots = events.map { event -> (start: Int, end: Int) in
            (CalendarDates.minutesIntoDay(event.start, day: day, calendar: calendar),
             CalendarDates.minutesIntoDay(event.end, day: day, calendar: calendar))
        }
        let placements = CalendarOverlapLayout.place(slots, minimumLength: 20)
        return events.indices.map { TimedItem(event: events[$0], start: slots[$0].start, end: slots[$0].end, placement: placements[$0]) }
    }

    /// Cards come and go with motion only after the user's own change
    /// (`CalendarLocalChange`): new ones grow from 0.95, removed ones fade
    /// out faster. A sync or another device changes them without motion.
    /// A removed card keeps the transition of its last render, which may
    /// predate the user's change (before: `.identity`, no fade): so the
    /// removal is always `CalendarCardRemoval`, which reads the mark when
    /// the card goes. An insertion is rendered fresh; it moves only with the
    /// day column's animation of that render. Reduce Motion: opacity only.
    private func cardTransition(_ animated: Bool) -> AnyTransition {
        // The removal always carries its timing; `CalendarCardRemoval` drops it (the card
        // is gone at once) unless the user's own change is recent.
        let removal = AnyTransition(CalendarCardRemoval(change: localChange, reduced: reduceMotion))
            .animation(reduceMotion ? NotyMotion.fade : NotyMotion.exit)
        if reduceMotion { return .asymmetric(insertion: animated ? .opacity.animation(NotyMotion.fade) : .identity, removal: removal) }
        return .asymmetric(insertion: .scale(scale: 0.95).combined(with: .opacity), removal: removal)
    }

    private func dayColumn(_ day: Date, column: CGFloat, homework: Set<String>) -> some View {
        let items = timedItems(day)
        let animated = localChange?.recent == true
        return ZStack(alignment: .topLeading) {
            ForEach(items) { item in
                let inner = column - 8
                let width = inner / CGFloat(item.placement.columns)
                let height = max(22, (CGFloat(item.end - item.start) / 60) * hourHeight - 3)
                CalendarEventCard(event: item.event, model: model, height: height, detailed: detailed && item.placement.columns == 1,
                                  // Only own events: dragging a system calendar entry would write
                                  // into Apple Kalender/Outlook without a „Rückgängig“ (see plan).
                                  movable: item.event.writable && !model.showsSamples && model.canWrite,
                                  homework: homework.contains(item.event.id),
                                  hourHeight: hourHeight, column: days.count > 1 ? column : nil,
                                  onDragState: { dragging = $0 })
                    .frame(width: max(20, width - 2), height: height)
                    .offset(x: 4 + CGFloat(item.placement.column) * width, y: y(item.start) + 1.5)
                    .transition(cardTransition(animated))
            }
        }
        // New and removed entries (and the overlap re-flow) animate – only when
        // the set of entries of this day changed by the user's own action
        // (decided in the render of that change). Reduce Motion: the layout
        // stays instant, the transitions fade by themselves.
        .animation(animated ? NotyMotion.panel(reduceMotion) : nil, value: items.map(\.id))
    }

    /// Current time: a thin line across today only, the time in the gutter.
    @ViewBuilder private func nowLine(_ column: CGFloat) -> some View {
        if let index = days.firstIndex(where: { calendar.isDate($0, inSameDayAs: model.today) }) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let minutes = CalendarDates.minutesIntoDay(context.date, day: days[index], calendar: calendar)
                ZStack(alignment: .topLeading) {
                    Text(CalendarText.clock(context.date, calendar: calendar))
                        .font(.caption2.weight(.semibold)).monospacedDigit().foregroundStyle(CalendarPalette.today)
                        .frame(width: gutter - 10, alignment: .trailing)
                        .background(Color(uiColor: .systemBackground))
                        .offset(y: y(minutes) - 8)
                    // Faint across the whole week, strong in today's column.
                    Rectangle().fill(CalendarPalette.today.opacity(0.3)).frame(width: column * CGFloat(days.count), height: 1)
                        .offset(x: gutter, y: y(minutes) - 0.5)
                    Rectangle().fill(CalendarPalette.today).frame(width: column, height: 1.5)
                        .offset(x: gutter + CGFloat(index) * column, y: y(minutes) - 0.75)
                    Circle().fill(CalendarPalette.today).frame(width: 9, height: 9)
                        .offset(x: gutter + CGFloat(index) * column - 4.5, y: y(minutes) - 4.5)
                }
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityLabel("Aktuelle Uhrzeit \(CalendarText.clock(context.date, calendar: calendar))")
            }
        }
    }
}

/// Card of a timed occurrence: title and time first, room or state only
/// when it fits. Thin colour stripe and a faint tint; state is shown by
/// symbol (and strikethrough when cancelled), never by colour alone.
struct CalendarEventCard: View {
    let event: CalendarEntry
    @ObservedObject var model: CalendarModel
    let height: CGFloat
    var detailed = false
    /// Own event: long press + drag moves it (across days in the week), the
    /// handle at the bottom edge changes its duration.
    var movable = false
    /// Open homework is due in this lesson (small book symbol, VoiceOver).
    var homework = false
    var hourHeight: CGFloat = 60
    /// Width of one day column (week); nil: day view, no change of day.
    var column: CGFloat?
    var onDragState: (Bool) -> Void = { _ in }
    @GestureState private var move: CGSize?
    @GestureState private var stretch: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.calendarOrigin) private var origins
    @Environment(\.calendarLocalChange) private var localChange
    /// A pinch is running or just ended: its fingers neither open nor move the card.
    @Environment(\.calendarZoom) private var zoom
    /// After letting go: the card stays where it was dropped until the model
    /// moved the event (or springs back if the change was rejected). Bound
    /// to the times it was dropped from, so the new position never doubles up.
    @State private var settling: Settling?
    /// This card reported a running move/stretch (`onDragState(true)`) and has
    /// not taken it back yet.
    @State private var reportedDrag = false

    private struct Settling: Equatable {
        var offset: CGSize = .zero
        var stretch: CGFloat = 0
        let start: Date, end: Date
        /// Each drop is its own: a later, equal drop is never reset by an older wait.
        let token = UUID()
    }

    /// 15-minute steps in the week, 5 in the wider day view.
    private var snap: Int { column == nil ? 5 : 15 }
    private func minutes(_ dy: CGFloat) -> Int { Int((dy / hourHeight * 60 / CGFloat(snap)).rounded()) * snap }
    private func days(_ dx: CGFloat) -> Int {
        guard let column, column > 0 else { return 0 }
        return Int((dx / column).rounded())
    }

    var body: some View {
        let color = model.entryColor(event)
        let selected = model.selection == event.id
        let cancelled = event.status == .cancelled
        let notes = model.hasNotes(event)
        let time = event.timeText(model.calendar)
        let settled = settling.flatMap { $0.start == event.start && $0.end == event.end ? $0 : nil }
        let stretched = stretch.map { CGFloat(minutes($0)) / 60 * hourHeight } ?? settled?.stretch ?? 0
        let lifted = move != nil
        // Day view: room and teacher; week: state or room, whichever exists.
        let extra: String? = detailed ? [event.status.label, event.room, event.teacher].compactMap { $0 }.joined(separator: " · ")
                             : event.status.label ?? event.room
        // Tall cards: time, room (and teacher) on own lines, the state as a badge.
        let tall = height >= 64
        Button {
            guard zoom?.recentPinch != true else { return }
            origins?.tap(event.id, key: "card/" + event.id)
            model.selection = event.id
        } label: {
            HStack(spacing: 0) {
                Rectangle().fill(color).frame(width: 3)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        if let symbol = event.status.symbol {
                            Image(systemName: symbol).font(.caption2.weight(.bold))
                                .foregroundStyle(cancelled ? Color.orange : .secondary)
                        }
                        Text(event.title).font(.caption.weight(.semibold))
                            .strikethrough(cancelled).lineLimit(height < 44 ? 1 : 2)
                        Spacer(minLength: 0)
                        if homework {
                            Image(systemName: "book.closed.fill").font(.caption2).foregroundStyle(.secondary).accessibilityHidden(true)
                        }
                        if notes {
                            Image(systemName: "note.text").font(.caption2).foregroundStyle(.secondary).accessibilityHidden(true)
                        }
                        if event.originalDate != nil {
                            Image(systemName: "repeat").font(.system(size: 8)).foregroundStyle(.tertiary).accessibilityHidden(true)
                        }
                        if model.isReadOnly(event) {
                            Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(.tertiary).accessibilityHidden(true)
                        }
                    }
                    if tall {
                        // Below the badge height the state goes beside the time (if it fits).
                        ViewThatFits(in: .horizontal) {
                            if height < 84, let label = event.status.label { Text(time + " · " + label) }
                            Text(time)
                        }
                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                        if let place = (detailed ? [event.room, event.teacher].compactMap { $0 }.joined(separator: " · ") : event.room), !place.isEmpty {
                            Label(place, systemImage: "mappin.and.ellipse").labelStyle(CalendarCompactLabelStyle())
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if let label = event.status.label, height >= 84 {
                            Text(label).font(.caption2.weight(.semibold))
                                .foregroundStyle(cancelled ? Color.orange : .primary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill((cancelled ? Color.orange : Color.white).opacity(0.16)))
                        }
                    } else if height >= 36 {
                        // The extra text appears only if it fits beside the time.
                        ViewThatFits(in: .horizontal) {
                            if let extra, !extra.isEmpty { Text(time + " · " + extra) }
                            Text(time)
                        }
                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .foregroundStyle(.primary)
            .opacity(cancelled ? 0.55 : 1)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(CalendarPalette.tint(color, selected: selected || move != nil, cancelled: cancelled)))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                if selected || move != nil || stretch != nil { CalendarSelectionFrame(radius: 6) }
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        // Pressed: only the plain style's dimming (cards are tapped often).
        .buttonStyle(.plain)
        // Pointer only: a highlight in the card's shape.
        .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 6, style: .continuous))
        .hoverEffect(.highlight)
        .frame(height: max(20, height + stretched), alignment: .top)
        .frame(height: height, alignment: .top)
        .overlay(alignment: .top) { if let preview = previewText { dragLabel(preview) } }
        .overlay(alignment: .bottom) { if movable && selected && move == nil { resizeHandle.offset(y: stretched) } }
        .calendarOrigin("card/" + event.id)
        // Picked up: lifted with a shadow; every grid step snaps with a spring.
        .scaleEffect(lifted && !reduceMotion ? 1.04 : 1)
        .shadow(color: .black.opacity(lifted ? 0.45 : 0), radius: lifted ? 12 : 0, y: lifted ? 6 : 0)
        .offset(move.map { snapped($0) } ?? settled?.offset ?? .zero)
        .animation(NotyMotion.palette(reduceMotion), value: move.map { snapped($0) })
        .animation(NotyMotion.palette(reduceMotion), value: lifted)
        .zIndex(move != nil || stretch != nil || settled != nil ? 1 : 0)
        .gesture(LongPressGesture(minimumDuration: 0.35).sequenced(before: DragGesture(minimumDistance: 0))
            .updating($move) { value, state, _ in
                // Not while a pinch runs: a finger of it must not lift or move the card.
                if case .second(true, let drag) = value { state = zoom?.recentPinch == true ? nil : drag?.translation ?? .zero }
            }
            .onEnded { value in
                // Part of a pinch: nothing is moved, the card returns.
                guard case .second(true, let drag?) = value, zoom?.recentPinch != true else { return }
                drop(Settling(offset: snapped(drag.translation), start: event.start, end: event.end)) {
                    model.drag(event, days: days(drag.translation.width), minutes: minutes(drag.translation.height), resize: false)
                }
            }, including: movable ? .all : .subviews)
        .onChange(of: move != nil || stretch != nil) { _, active in
            reportedDrag = active
            onDragState(active)
        }
        // The card goes while it is held (another period, the event removed by a
        // sync): the change above need not be delivered any more, and the grid
        // would stay locked. Only the card that reported the drag takes it back.
        .onDisappear {
            if reportedDrag { reportedDrag = false; onDragState(false) }
        }
        .onChange(of: event.start) { _, _ in settling = nil }
        .onChange(of: event.end) { _, _ in settling = nil }
        .sensoryFeedback(.selection, trigger: move.map { minutes($0.height) + 10_000 * days($0.width) })
        .accessibilityLabel(model.accessibilityText(event, notes: notes, homework: homework))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(movable ? "Zeigt Details und Notizseite. Lange drücken und ziehen verschiebt den Termin." : "Zeigt Details und Notizseite")
        .accessibilityActions {
            if movable {
                Button("\(snap) Minuten früher") { model.drag(event, days: 0, minutes: -snap, resize: false) }
                Button("\(snap) Minuten später") { model.drag(event, days: 0, minutes: snap, resize: false) }
                if column != nil {
                    Button("Einen Tag früher") { model.drag(event, days: -1, minutes: 0, resize: false) }
                    Button("Einen Tag später") { model.drag(event, days: 1, minutes: 0, resize: false) }
                }
                Button("\(snap) Minuten länger") { model.drag(event, days: 0, minutes: snap, resize: true) }
                Button("\(snap) Minuten kürzer") { model.drag(event, days: 0, minutes: -snap, resize: true) }
            }
        }
    }

    /// The drag translation on the grid (whole days, whole `snap` minutes).
    private func snapped(_ translation: CGSize) -> CGSize {
        CGSize(width: CGFloat(days(translation.width)) * (column ?? 0), height: CGFloat(minutes(translation.height)) / 60 * hourHeight)
    }

    /// Keeps the dropped position until the model moved the event (its new
    /// start/end clear `settling`, see `onChange`). A change rejected at once
    /// (too short, invalid) springs back immediately; a cancelled series
    /// question shortly after; a commit that never arrives after 10 s.
    private func drop(_ value: Settling, _ change: () -> Void) {
        localChange?.mark()
        guard value.offset != .zero || value.stretch != 0 else { change(); return }
        settling = value
        let notice = model.notice
        change()
        if model.notice != notice && model.pendingSeriesChange?.entry.id != event.id {
            springBack(value.token)
            return
        }
        Task { @MainActor in
            var waited = 0, askedSeries = false
            while settling?.token == value.token && waited < 10_000 {
                try? await Task.sleep(for: .milliseconds(150))
                if model.pendingSeriesChange?.entry.id == event.id {
                    askedSeries = true
                } else {
                    // After „Abbrechen“ of the series question there is nothing to wait for long.
                    waited += askedSeries ? 600 : 150
                }
            }
            springBack(value.token)
        }
    }

    private func springBack(_ token: UUID) {
        guard settling?.token == token else { return }
        // After the drop gesture: back with a small overshoot (Reduce Motion: at once).
        withAnimation(CalendarMotion.settle(reduceMotion, from: 1, to: 0)) { settling = nil }
    }

    /// New times while dragging („09:15–10:45“, „+1 Tag“).
    private var previewText: String? {
        let calendar = model.calendar
        if let move {
            let shift = days(move.width), delta = minutes(move.height)
            let start = calendar.date(byAdding: .minute, value: delta, to: calendar.date(byAdding: .day, value: shift, to: event.start) ?? event.start) ?? event.start
            let end = calendar.date(byAdding: .minute, value: delta, to: calendar.date(byAdding: .day, value: shift, to: event.end) ?? event.end) ?? event.end
            let day = shift == 0 ? "" : " · " + CalendarText.shortWeekdays[CalendarDates.weekdayIndex(start, calendar: calendar)]
            return CalendarText.timeRange(start, end, calendar: calendar) + day
        }
        if let stretch {
            let end = calendar.date(byAdding: .minute, value: minutes(stretch), to: event.end) ?? event.end
            return end <= event.start ? "zu kurz" : CalendarText.timeRange(event.start, end, calendar: calendar)
        }
        return nil
    }

    private func dragLabel(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.semibold)).monospacedDigit()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .calendarAccentLabel(Capsule())
            .offset(y: -18)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Bottom edge: drag to change the duration (same steps as moving). The
    /// visible grip stays small; it takes touches 44 pt high.
    private var resizeHandle: some View {
        Capsule().fill(.tint).frame(width: 30, height: 5)
            .frame(maxWidth: .infinity).frame(height: 22)
            .contentShape(NotyHitShape())
            .offset(y: 11)
            .gesture(DragGesture(minimumDistance: 1)
                .updating($stretch) { value, state, _ in state = zoom?.recentPinch == true ? nil : value.translation.height }
                .onEnded { value in
                    guard zoom?.recentPinch != true else { return }
                    drop(Settling(stretch: CGFloat(minutes(value.translation.height)) / 60 * hourHeight, start: event.start, end: event.end)) {
                        model.drag(event, days: 0, minutes: minutes(value.translation.height), resize: true)
                    }
                })
            .accessibilityHidden(true)
    }
}

/// iPadOS 18+: the initial offset of a new hour grid (no first frame at
/// 0:00) and whether the user scrolls it. iPadOS 17: only `placeStart`.
private struct CalendarGridScrollStart: ViewModifier {
    let anchor: UnitPoint
    let scrolled: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .defaultScrollAnchor(anchor, for: .initialOffset)
                .onScrollPhaseChange { _, phase in
                    if phase == .tracking || phase == .interacting { scrolled() }
                }
        } else {
            content
        }
    }
}

/// All-day entry in the week/day row: same stripe and tint as the cards.
struct CalendarAllDayChip: View {
    let event: CalendarEntry
    @ObservedObject var model: CalendarModel
    /// A hold-and-drag that started on this chip (to create) does not open it on release.
    var hold: CalendarSwipeGuard?
    @Environment(\.calendarOrigin) private var origins
    @Environment(\.calendarZoom) private var zoom

    var body: some View {
        let color = model.entryColor(event)
        let selected = model.selection == event.id
        let notes = model.hasNotes(event)
        Button {
            guard zoom?.recentPinch != true, hold?.recent != true else { return }
            origins?.tap(event.id, key: "allday/" + event.id)
            model.selection = event.id
        } label: {
            HStack(spacing: CalendarSpace.xs) {
                Rectangle().fill(color).frame(width: 3)
                Text(event.title).font(.caption.weight(.medium)).lineLimit(1)
                Spacer(minLength: 0)
                if notes { Image(systemName: "note.text").font(.caption2).foregroundStyle(.secondary).padding(.trailing, 6) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(.primary)
            .background(CalendarPalette.tint(color, selected: selected))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay {
                if selected { CalendarSelectionFrame(radius: 5) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 5))
        .hoverEffect(.highlight)
        .calendarOrigin("allday/" + event.id)
        .accessibilityLabel(model.accessibilityText(event, notes: notes))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
