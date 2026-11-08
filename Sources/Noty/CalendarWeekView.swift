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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.calendarZoom) private var zoom
    private var calendar: Calendar { model.calendar }
    private var minimumColumn: CGFloat { days.count == 1 ? 260 : 96 }

    var body: some View {
        GeometryReader { geo in
            let natural = (geo.size.width - gutter) / CGFloat(max(1, days.count))
            let column = max(natural, minimumColumn)
            let content = VStack(spacing: 0) {
                header(column)
                // Only when there is something all-day in the shown days.
                if !allDayItems.isEmpty { allDayRow(column) }
                Rectangle().fill(CalendarPalette.hairline).frame(height: 0.5)
                hours(column)
            }
            .frame(width: gutter + column * CGFloat(days.count), height: geo.size.height)
            if natural < minimumColumn {
                ScrollView(.horizontal) { content }
                    .accessibilityHint("Waagerecht scrollbar, um alle Tage zu sehen")
            } else {
                content
            }
        }
    }

    // MARK: Header

    /// Heads like Apple Kalender: the weekday small above the date, today's
    /// date in the red circle, weekends and holidays quieter (holidays also
    /// named in the all-day row, never by tint alone).
    private func header(_ column: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text("KW \(CalendarDates.isoWeek(days[0], calendar: calendar).week)")
                .font(.caption2.weight(.medium)).foregroundStyle(CalendarPalette.quiet)
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

    private func allDayRow(_ column: CGFloat) -> some View {
        let items = allDayItems
        let lanes = (items.map(\.lane).max() ?? -1) + 1
        return ZStack(alignment: .topLeading) {
            Text("ganztägig").font(.caption2).foregroundStyle(CalendarPalette.quiet)
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(width: gutter - 6, alignment: .trailing).padding(.top, 6)
                .accessibilityHidden(true)
            ForEach(items) { item in
                let width = CGFloat(item.last - item.first + 1) * column - 4
                CalendarAllDayChip(event: item.event, model: model)
                    .frame(width: width, height: laneHeight - 3)
                    .offset(x: gutter + CGFloat(item.first) * column + 2, y: 3 + CGFloat(item.lane) * laneHeight)
            }
        }
        // Every lane stays visible; nothing is cut off.
        .frame(width: gutter + column * CGFloat(days.count), height: CGFloat(lanes) * laneHeight + 6, alignment: .topLeading)
    }

    // MARK: Hours

    private func y(_ minutes: Int) -> CGFloat { topInset + CGFloat(minutes) / 60 * hourHeight }

    private func hours(_ column: CGFloat) -> some View {
        // Once per grid render: derived from the whole offline timetable.
        let homework = model.homeworkDueEntryIDs
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
                }
                .frame(width: gutter + column * CGFloat(days.count), height: y(24 * 60) + topInset, alignment: .topLeading)
            }
            .scrollDisabled(dragging)
            .onAppear {
                let hour = days.contains { calendar.isDate($0, inSameDayAs: model.today) }
                    ? max(0, calendar.component(.hour, from: Date()) - 1) : 7
                // After the first layout pass, otherwise the targets have no frames yet.
                Task { @MainActor in proxy.scrollTo("hour-\(hour)", anchor: .top) }
            }
        }
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

    private func dayColumn(_ day: Date, column: CGFloat, homework: Set<String>) -> some View {
        let items = timedItems(day)
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
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.85).combined(with: .opacity))
            }
        }
        // New and removed entries (and the overlap re-flow) animate – only when
        // the set of entries of this day changes, not on every model update.
        .animation(CalendarMotion.smooth(reduceMotion), value: items.map(\.id))
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
                // Glides to the next half minute instead of jumping.
                .animation(reduceMotion ? nil : .linear(duration: 1), value: minutes)
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
    /// After letting go: the card stays where it was dropped until the model
    /// moved the event (or springs back if the change was rejected). Bound
    /// to the times it was dropped from, so the new position never doubles up.
    @State private var settling: Settling?

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
        Button { origins?.tap(event.id, key: "card/" + event.id); model.selection = event.id } label: {
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
                if selected || move != nil || stretch != nil {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(CalendarPalette.selection, lineWidth: 1.5)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(height: max(20, height + stretched), alignment: .top)
        .frame(height: height, alignment: .top)
        .overlay(alignment: .top) { if let preview = previewText { dragLabel(preview) } }
        .overlay(alignment: .bottom) { if movable && selected && move == nil { resizeHandle.offset(y: stretched) } }
        .calendarOrigin("card/" + event.id)
        // Picked up: lifted with a shadow; every grid step snaps with a spring.
        .scaleEffect(lifted && !reduceMotion ? 1.04 : 1)
        .shadow(color: .black.opacity(lifted ? 0.45 : 0), radius: lifted ? 12 : 0, y: lifted ? 6 : 0)
        .offset(move.map { snapped($0) } ?? settled?.offset ?? .zero)
        .animation(reduceMotion ? nil : CalendarMotion.snappy(false), value: move.map { snapped($0) })
        .animation(reduceMotion ? nil : CalendarMotion.snappy(false), value: lifted)
        .zIndex(move != nil || stretch != nil || settled != nil ? 1 : 0)
        .gesture(LongPressGesture(minimumDuration: 0.35).sequenced(before: DragGesture(minimumDistance: 0))
            .updating($move) { value, state, _ in
                if case .second(true, let drag) = value { state = drag?.translation ?? .zero }
            }
            .onEnded { value in
                guard case .second(true, let drag?) = value else { return }
                drop(Settling(offset: snapped(drag.translation), start: event.start, end: event.end)) {
                    model.drag(event, days: days(drag.translation.width), minutes: minutes(drag.translation.height), resize: false)
                }
            }, including: movable ? .all : .subviews)
        .onChange(of: move != nil || stretch != nil) { _, active in onDragState(active) }
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
        withAnimation(CalendarMotion.bouncy(reduceMotion)) { settling = nil }
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
            .background(CalendarPalette.selection, in: Capsule())
            .foregroundStyle(.white)
            .offset(y: -18)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Bottom edge: drag to change the duration (same steps as moving).
    private var resizeHandle: some View {
        Capsule().fill(CalendarPalette.selection).frame(width: 30, height: 5)
            .frame(maxWidth: .infinity).frame(height: 22)
            .contentShape(Rectangle())
            .offset(y: 11)
            .gesture(DragGesture(minimumDistance: 1)
                .updating($stretch) { value, state, _ in state = value.translation.height }
                .onEnded { value in
                    drop(Settling(stretch: CGFloat(minutes(value.translation.height)) / 60 * hourHeight, start: event.start, end: event.end)) {
                        model.drag(event, days: 0, minutes: minutes(value.translation.height), resize: true)
                    }
                })
            .accessibilityHidden(true)
    }
}

/// All-day entry in the week/day row: same stripe and tint as the cards.
struct CalendarAllDayChip: View {
    let event: CalendarEntry
    @ObservedObject var model: CalendarModel
    @Environment(\.calendarOrigin) private var origins

    var body: some View {
        let color = model.entryColor(event)
        let selected = model.selection == event.id
        let notes = model.hasNotes(event)
        Button { origins?.tap(event.id, key: "allday/" + event.id); model.selection = event.id } label: {
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
                if selected { RoundedRectangle(cornerRadius: 5).strokeBorder(CalendarPalette.selection, lineWidth: 1.5) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .calendarOrigin("allday/" + event.id)
        .accessibilityLabel(model.accessibilityText(event, notes: notes))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
