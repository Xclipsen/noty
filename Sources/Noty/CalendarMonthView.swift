import SwiftUI
import NotebookCore

/// Month: seven clean columns, quiet ISO week numbers, at most three
/// compact lines per day. What does not fit is counted in „+ n weitere“,
/// never dropped.
struct CalendarMonthView: View {
    @ObservedObject var model: CalendarModel
    let showAll: (Date) -> Void
    @ScaledMetric(relativeTo: .caption) private var line: CGFloat = 20
    @ScaledMetric(relativeTo: .caption) private var weekColumn: CGFloat = 28
    @ScaledMetric(relativeTo: .body) private var minimumRow: CGFloat = 100
    @ScaledMetric(relativeTo: .body) private var dateRow: CGFloat = 32
    /// Calm cells: never more than three lines, the rest behind „+ n weitere“.
    private let maximumLines = 3
    private var calendar: Calendar { model.calendar }

    var body: some View {
        let grid = CalendarMonthGrid(month: model.anchor, calendar: calendar)
        GeometryReader { geo in
            let header: CGFloat = 28
            let available = geo.size.height - header
            let row = max(minimumRow, available / CGFloat(grid.weeks.count))
            let column = (geo.size.width - weekColumn) / 7
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: weekColumn)
                    ForEach(0..<7, id: \.self) { index in
                        Text(CalendarText.shortWeekdays[index]).font(.caption).foregroundStyle(.secondary)
                            .padding(.leading, CalendarSpace.s)
                            .frame(width: column, alignment: .leading)
                            .accessibilityLabel(CalendarText.weekdays[index])
                    }
                }
                .frame(height: header)
                Rectangle().fill(CalendarPalette.hairline).frame(height: 0.5)
                // Large text or a short window: the rows keep their minimum height and scroll.
                ScrollView(.vertical) {
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
                            Rectangle().fill(CalendarPalette.hairline).frame(height: 0.5)
                        }
                    }
                }
                .scrollDisabled(row * CGFloat(grid.weeks.count) <= available + 1)
            }
        }
    }

    private func cell(_ day: Date, inMonth: Bool, width: CGFloat, height: CGFloat) -> some View {
        let events = model.events(on: day)
        let capacity = min(maximumLines, Int((height - dateRow - 6) / line))
        let split = CalendarOverflow.split(total: events.count, capacity: capacity)
        let isToday = calendar.isDate(day, inSameDayAs: model.today)
        return VStack(alignment: .leading, spacing: 1) {
            Button { model.open(day, in: .day) } label: {
                Text("\(calendar.component(.day, from: day))")
                    .font(.subheadline.weight(isToday ? .semibold : .regular)).monospacedDigit()
                    .foregroundStyle(isToday ? Color.white : inMonth ? Color.primary : CalendarPalette.quiet)
                    .frame(minWidth: 26, minHeight: 26)
                    .background { if isToday { Circle().fill(CalendarPalette.today) } }
                    .padding(.leading, 3)
                    .frame(minWidth: 44, minHeight: dateRow, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(CalendarText.longDate(day, calendar: calendar) + (isToday ? ", heute" : "")
                                + ", " + NotyText.count(events.count, "Termin", "Termine"))
            .accessibilityHint("Öffnet den Tag")
            ForEach(events.prefix(split.shown)) { event in
                CalendarMonthRow(event: event, model: model).frame(height: line)
            }
            if split.hidden > 0 {
                Button { showAll(day) } label: {
                    Text(CalendarText.more(split.hidden)).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: line, alignment: .leading).padding(.horizontal, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(split.hidden) weitere Termine am \(CalendarText.shortDate(day, calendar: calendar))")
                .accessibilityHint("Zeigt die vollständige Tagesliste")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 3)
        .frame(width: width, height: height, alignment: .topLeading)
        .overlay(alignment: .leading) { Rectangle().fill(CalendarPalette.hairline.opacity(0.6)).frame(width: 0.5) }
        .opacity(inMonth ? 1 : 0.6)
    }
}

/// One compact line of the month: colour dot, title, time if it fits.
/// All-day entries get the stripe and tint of the week chips.
struct CalendarMonthRow: View {
    let event: CalendarEntry
    @ObservedObject var model: CalendarModel

    var body: some View {
        let color = CalendarPalette.color(event)
        let selected = model.selection == event.id
        let notes = model.hasNotes(event)
        let cancelled = event.status == .cancelled
        Button { model.selection = event.id } label: {
            HStack(spacing: CalendarSpace.xs) {
                if event.allDay {
                    Rectangle().fill(color).frame(width: 3)
                } else {
                    Circle().fill(color).frame(width: 6, height: 6)
                }
                if let symbol = event.status.symbol { Image(systemName: symbol).font(.caption2).foregroundStyle(.secondary) }
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
        .foregroundStyle(.primary)
        .accessibilityLabel(event.accessibilityText(model.calendar, notes: notes))
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
                        .accessibilityLabel(event.accessibilityText(model.calendar, notes: model.hasNotes(event)))
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
            RoundedRectangle(cornerRadius: 2).fill(CalendarPalette.color(event)).frame(width: 4, height: 36)
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
            if event.source.readOnly { Image(systemName: "lock").font(.caption).foregroundStyle(.secondary) }
        }
        .foregroundStyle(.primary)
        .frame(minHeight: 44)
    }
}

/// Year: twelve light months; a quiet dot marks event days, a faint band
/// the sample holidays. Tapping a day opens it, the month name the month.
struct CalendarYearView: View {
    @ObservedObject var model: CalendarModel
    @ScaledMetric(relativeTo: .body) private var cell: CGFloat = 44
    private var calendar: Calendar { model.calendar }

    var body: some View {
        GeometryReader { geo in
            let tile = cell * 7
            let columns = max(1, Int((geo.size.width - 2 * CalendarSpace.xl + 32) / (tile + 32)))
            ScrollView {
                VStack(alignment: .leading, spacing: CalendarSpace.l) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(tile), spacing: 32, alignment: .top), count: columns),
                              alignment: .leading, spacing: CalendarSpace.xl) {
                        ForEach(CalendarDates.yearMonths(model.anchor, calendar: calendar), id: \.self) { month($0) }
                    }
                    legend
                }
                .padding(.horizontal, CalendarSpace.xl).padding(.vertical, CalendarSpace.l)
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// Missing holiday data is never presented as „no holidays“.
    private var holidayLegend: String {
        if model.showsSamples { return "Ferien (Beispiel, keine echte Ferienquelle)" }
        if model.connection == nil { return "Ferien erst mit WebUntis-Verbindung" }
        return model.snapshot?.holidaysFetchedAt == nil ? "Ferien noch nicht geladen" : "Ferien laut WebUntis"
    }

    private var legend: some View {
        HStack(spacing: CalendarSpace.l) {
            Label { Text("Termine") } icon: { Circle().fill(Color.secondary).frame(width: 4, height: 4) }
            Label { Text(holidayLegend) } icon: {
                Capsule().fill(CalendarPalette.holidays.opacity(0.3)).frame(width: 16, height: 8)
            }
        }
        .font(.caption2).foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func month(_ month: Date) -> some View {
        let grid = CalendarMonthGrid(month: month, calendar: calendar)
        let current = calendar.isDate(month, equalTo: model.today, toGranularity: .month)
        let index = calendar.component(.month, from: month) - 1
        return VStack(alignment: .leading, spacing: 0) {
            Button { model.open(month, in: .month) } label: {
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
    }

    private func dayCell(_ day: Date) -> some View {
        let events = model.events(on: day)
        let holiday = events.first { $0.source == .holidays }
        let count = events.filter { $0.source != .holidays }.count
        let isToday = calendar.isDate(day, inSameDayAs: model.today)
        return Button { model.open(day, in: .day) } label: {
            VStack(spacing: 2) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.footnote.weight(isToday ? .semibold : .regular)).monospacedDigit()
                    .foregroundStyle(isToday ? Color.white : .primary)
                    .frame(width: 26, height: 26)
                    .background { if isToday { Circle().fill(CalendarPalette.today) } }
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
