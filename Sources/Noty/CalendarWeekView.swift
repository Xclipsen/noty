import SwiftUI
import NotebookCore

/// Week and day: fixed day headers, all-day row, vertically scrolling
/// 24-hour grid. Columns narrower than `minimumColumn` scroll sideways
/// instead of switching the chosen view.
struct CalendarTimeGrid: View {
    let days: [Date]
    @ObservedObject var model: CalendarDesignModel
    /// Day view: more detail on the cards.
    var detailed = false
    @ScaledMetric(relativeTo: .body) private var hourHeight: CGFloat = 54
    @ScaledMetric(relativeTo: .caption) private var gutter: CGFloat = 54
    @ScaledMetric(relativeTo: .caption) private var laneHeight: CGFloat = 26
    @ScaledMetric(relativeTo: .headline) private var headerHeight: CGFloat = 54
    private let topInset: CGFloat = 10
    private var calendar: Calendar { model.calendar }
    private var minimumColumn: CGFloat { days.count == 1 ? 260 : 96 }

    var body: some View {
        GeometryReader { geo in
            let natural = (geo.size.width - gutter) / CGFloat(max(1, days.count))
            let column = max(natural, minimumColumn)
            let content = VStack(spacing: 0) {
                header(column)
                allDayRow(column)
                Divider()
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

    private func header(_ column: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text("KW \(CalendarDates.isoWeek(days[0], calendar: calendar).week)")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: gutter)
                .accessibilityLabel("Kalenderwoche \(CalendarDates.isoWeek(days[0], calendar: calendar).week)")
            ForEach(days, id: \.self) { day in
                let isToday = calendar.isDate(day, inSameDayAs: model.today)
                let weekday = CalendarDates.weekdayIndex(day, calendar: calendar)
                Button { if days.count > 1 { model.open(day, in: .day) } } label: {
                    HStack(spacing: 6) {
                        Text(detailed ? CalendarText.weekdays[weekday] : CalendarText.shortWeekdays[weekday])
                            .font(.subheadline).foregroundStyle(isToday ? CalendarPalette.today : .secondary)
                        Text("\(calendar.component(.day, from: day))")
                            .font(.title3.weight(isToday ? .bold : .regular)).monospacedDigit()
                            .foregroundStyle(isToday ? Color.white : .primary)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background { if isToday { Capsule().fill(CalendarPalette.today) } }
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
        let event: CalendarSampleEvent
        let first: Int, last: Int, lane: Int
        var id: String { event.id }
    }

    private var allDayItems: [AllDayItem] {
        var seen = Set<String>()
        var spans: [(CalendarSampleEvent, Int, Int)] = []
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
            Text("ganztägig").font(.caption2).foregroundStyle(.secondary)
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
        .frame(width: gutter + column * CGFloat(days.count), height: max(30, CGFloat(lanes) * laneHeight + 6), alignment: .topLeading)
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.5))
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
                let day = days[index]
                if calendar.isDate(day, inSameDayAs: model.today) {
                    Rectangle().fill(CalendarPalette.today.opacity(0.05))
                        .frame(width: column, height: y(24 * 60) + topInset).offset(x: gutter + CGFloat(index) * column)
                        .allowsHitTesting(false)
                } else if CalendarDates.weekdayIndex(day, calendar: calendar) >= 5 {
                    Rectangle().fill(Color.white.opacity(0.025))
                        .frame(width: column, height: y(24 * 60) + topInset).offset(x: gutter + CGFloat(index) * column)
                        .allowsHitTesting(false)
                }
                Rectangle().fill(Color(uiColor: .separator).opacity(0.6)).frame(width: 0.5, height: y(24 * 60) + topInset)
                    .offset(x: gutter + CGFloat(index) * column).allowsHitTesting(false)
            }
            ForEach(0..<25, id: \.self) { hour in
                HStack(spacing: 4) {
                    Text(CalendarText.hour(hour % 24)).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: gutter - 8, alignment: .trailing)
                        .opacity(hour == 24 ? 0 : 1)
                    Rectangle().fill(Color(uiColor: .separator)).frame(height: 0.5)
                }
                .frame(height: 14)
                .offset(y: y(hour * 60) - 7)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }

    private struct TimedItem: Identifiable {
        let event: CalendarSampleEvent
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
                let inner = column - 6
                let width = inner / CGFloat(item.placement.columns)
                let height = max(22, (CGFloat(item.end - item.start) / 60) * hourHeight - 2)
                CalendarEventCard(event: item.event, model: model, height: height, detailed: detailed && item.placement.columns == 1)
                    .frame(width: max(20, width - 2), height: height)
                    .offset(x: 3 + CGFloat(item.placement.column) * width, y: y(item.start) + 1)
            }
        }
    }

    @ViewBuilder private func nowLine(_ column: CGFloat) -> some View {
        if let index = days.firstIndex(where: { calendar.isDate($0, inSameDayAs: model.today) }) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let minutes = CalendarDates.minutesIntoDay(context.date, day: days[index], calendar: calendar)
                ZStack(alignment: .topLeading) {
                    Text(CalendarText.clock(context.date, calendar: calendar))
                        .font(.caption2.weight(.bold)).monospacedDigit().foregroundStyle(CalendarPalette.today)
                        .frame(width: gutter - 8, alignment: .trailing)
                        .background(Color(uiColor: .systemBackground))
                        .offset(y: y(minutes) - 8)
                    Circle().fill(CalendarPalette.today).frame(width: 9, height: 9)
                        .offset(x: gutter + CGFloat(index) * column - 4.5, y: y(minutes) - 4.5)
                    Rectangle().fill(CalendarPalette.today).frame(width: column, height: 2)
                        .offset(x: gutter + CGFloat(index) * column, y: y(minutes) - 1)
                }
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityLabel("Aktuelle Uhrzeit \(CalendarText.clock(context.date, calendar: calendar))")
            }
        }
    }
}

/// Card of a timed occurrence: start, end, title and room stay readable;
/// state is shown by symbol and text, never by colour alone.
struct CalendarEventCard: View {
    let event: CalendarSampleEvent
    @ObservedObject var model: CalendarDesignModel
    let height: CGFloat
    var detailed = false

    var body: some View {
        let color = CalendarPalette.color(event)
        let selected = model.selection == event.id
        let cancelled = event.status == .cancelled
        let notes = model.hasNotes(event)
        Button { model.selection = event.id } label: {
            HStack(spacing: 0) {
                Rectangle().fill(color).frame(width: 4)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 3) {
                        if let symbol = event.status.symbol { Image(systemName: symbol).font(.caption2.weight(.bold)) }
                        Text(event.title).font(.caption.weight(.semibold)).strikethrough(cancelled).lineLimit(height < 40 ? 1 : 2)
                        Spacer(minLength: 0)
                        if notes { Image(systemName: "note.text").font(.caption2.weight(.bold)).accessibilityHidden(true) }
                    }
                    if height >= 36 {
                        Text(event.timeText(model.calendar)).font(.caption2).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                    }
                    if height >= 52, let room = event.room {
                        Text(room).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if height >= 66, let label = event.status.label {
                        Text(label).font(.caption2.weight(.bold)).lineLimit(1)
                    }
                    if detailed {
                        if height >= 80, let teacher = event.teacher { Text(teacher).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                        if height >= 96, case .substitution(let note) = event.status { Text(note).font(.caption2).lineLimit(2) }
                        if height >= 110, let details = event.details { Text(details).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
                    }
                }
                .padding(.horizontal, 5).padding(.vertical, 3)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .foregroundStyle(.primary)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(color.opacity(cancelled ? 0.10 : 0.26))
                    if cancelled { CalendarHatch().stroke(color.opacity(0.35), lineWidth: 1).clipShape(RoundedRectangle(cornerRadius: 6)) }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(selected ? CalendarPalette.selection : Color.black.opacity(0.25), lineWidth: selected ? 2.5 : 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(event.accessibilityText(model.calendar, notes: notes))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint("Zeigt Details und Notizseite")
    }
}

/// All-day entry in the week/day row.
struct CalendarAllDayChip: View {
    let event: CalendarSampleEvent
    @ObservedObject var model: CalendarDesignModel

    var body: some View {
        let color = CalendarPalette.color(event)
        let selected = model.selection == event.id
        let notes = model.hasNotes(event)
        Button { model.selection = event.id } label: {
            HStack(spacing: 4) {
                Image(systemName: event.source == .holidays ? "sun.max" : "calendar").font(.caption2)
                Text(event.title).font(.caption.weight(.medium)).lineLimit(1)
                Spacer(minLength: 0)
                if notes { Image(systemName: "note.text").font(.caption2) }
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(.primary)
            .background(RoundedRectangle(cornerRadius: 5).fill(color.opacity(event.source == .holidays ? 0.22 : 0.32)))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(selected ? CalendarPalette.selection : .clear, lineWidth: 2.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(event.accessibilityText(model.calendar, notes: notes))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Diagonal lines for cancelled lessons (a second cue besides the strikethrough).
struct CalendarHatch: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = -rect.height
        while x < rect.width {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += 8
        }
        return path
    }
}
