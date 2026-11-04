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
    @ScaledMetric(relativeTo: .headline) private var headerHeight: CGFloat = 44
    private let topInset: CGFloat = 10
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

    /// Compact heads „Mo 3“; today's number in the accent circle.
    private func header(_ column: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text("KW \(CalendarDates.isoWeek(days[0], calendar: calendar).week)")
                .font(.caption2).foregroundStyle(CalendarPalette.quiet)
                .frame(width: gutter)
                .accessibilityLabel("Kalenderwoche \(CalendarDates.isoWeek(days[0], calendar: calendar).week)")
            ForEach(days, id: \.self) { day in
                let isToday = calendar.isDate(day, inSameDayAs: model.today)
                let weekday = CalendarDates.weekdayIndex(day, calendar: calendar)
                Button { if days.count > 1 { model.open(day, in: .day) } } label: {
                    HStack(spacing: 5) {
                        Text(detailed ? CalendarText.weekdays[weekday] : CalendarText.shortWeekdays[weekday])
                            .font(.subheadline).foregroundStyle(isToday ? CalendarPalette.today : .secondary)
                        Text("\(calendar.component(.day, from: day))")
                            .font(.subheadline.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(isToday ? Color.white : .primary)
                            .frame(minWidth: 26, minHeight: 26)
                            .background { if isToday { Circle().fill(CalendarPalette.today) } }
                    }
                    .frame(width: column, height: headerHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(days.count == 1)
                .accessibilityLabel(CalendarText.longDate(day, calendar: calendar) + (isToday ? ", heute" : ""))
                .accessibilityHint(days.count > 1 ? "Öffnet den Tag" : "")
            }
        }
        .frame(height: headerHeight)
    }

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
        ScrollViewReader { proxy in
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
                        dayColumn(day, column: column)
                            .frame(width: column, height: y(24 * 60) + topInset, alignment: .topLeading)
                            .offset(x: gutter + CGFloat(index) * column)
                    }
                    nowLine(column)
                }
                .frame(width: gutter + column * CGFloat(days.count), height: y(24 * 60) + topInset, alignment: .topLeading)
            }
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
                if CalendarDates.weekdayIndex(days[index], calendar: calendar) >= 5 {
                    Rectangle().fill(Color.white.opacity(0.02))
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

    private func dayColumn(_ day: Date, column: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(timedItems(day)) { item in
                let inner = column - 8
                let width = inner / CGFloat(item.placement.columns)
                let height = max(22, (CGFloat(item.end - item.start) / 60) * hourHeight - 3)
                CalendarEventCard(event: item.event, model: model, height: height, detailed: detailed && item.placement.columns == 1)
                    .frame(width: max(20, width - 2), height: height)
                    .offset(x: 4 + CGFloat(item.placement.column) * width, y: y(item.start) + 1.5)
            }
        }
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
                    Circle().fill(CalendarPalette.today).frame(width: 7, height: 7)
                        .offset(x: gutter + CGFloat(index) * column - 3.5, y: y(minutes) - 3.5)
                    Rectangle().fill(CalendarPalette.today.opacity(0.85)).frame(width: column, height: 1)
                        .offset(x: gutter + CGFloat(index) * column, y: y(minutes) - 0.5)
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

    var body: some View {
        let color = CalendarPalette.color(event)
        let selected = model.selection == event.id
        let cancelled = event.status == .cancelled
        let notes = model.hasNotes(event)
        let time = event.timeText(model.calendar)
        // Day view: room and teacher; week: state or room, whichever exists.
        let extra: String? = detailed ? [event.status.label, event.room, event.teacher].compactMap { $0 }.joined(separator: " · ")
                             : event.status.label ?? event.room
        Button { model.selection = event.id } label: {
            HStack(spacing: 0) {
                Rectangle().fill(color).frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        if let symbol = event.status.symbol {
                            Image(systemName: symbol).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        Text(event.title).font(.caption.weight(.semibold))
                            .strikethrough(cancelled).lineLimit(height < 44 ? 1 : 2)
                        Spacer(minLength: 0)
                        if notes {
                            Image(systemName: "note.text").font(.caption2).foregroundStyle(.secondary).accessibilityHidden(true)
                        }
                        if event.source.readOnly {
                            Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(.tertiary).accessibilityHidden(true)
                        }
                    }
                    if height >= 36 {
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
            .background(RoundedRectangle(cornerRadius: 5).fill(CalendarPalette.tint(color, selected: selected, cancelled: cancelled)))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay {
                if selected { RoundedRectangle(cornerRadius: 5).strokeBorder(CalendarPalette.selection, lineWidth: 1.5) }
            }
            .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(event.accessibilityText(model.calendar, notes: notes))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint("Zeigt Details und Notizseite")
    }
}

/// All-day entry in the week/day row: same stripe and tint as the cards.
struct CalendarAllDayChip: View {
    let event: CalendarEntry
    @ObservedObject var model: CalendarModel

    var body: some View {
        let color = CalendarPalette.color(event)
        let selected = model.selection == event.id
        let notes = model.hasNotes(event)
        Button { model.selection = event.id } label: {
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
        .accessibilityLabel(event.accessibilityText(model.calendar, notes: notes))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
