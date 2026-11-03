import SwiftUI
import NotebookCore

/// Month: seven columns with ISO week numbers, compact labelled rows.
/// What does not fit is counted in „+ n weitere“, never dropped.
struct CalendarMonthView: View {
    @ObservedObject var model: CalendarDesignModel
    let showAll: (Date) -> Void
    @ScaledMetric(relativeTo: .caption) private var line: CGFloat = 20
    @ScaledMetric(relativeTo: .caption) private var weekColumn: CGFloat = 30
    @ScaledMetric(relativeTo: .body) private var minimumRow: CGFloat = 104
    @ScaledMetric(relativeTo: .body) private var dateRow: CGFloat = 34
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
                    Text("KW").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).frame(width: weekColumn)
                        .accessibilityHidden(true)
                    ForEach(0..<7, id: \.self) { index in
                        Text(CalendarText.shortWeekdays[index]).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .frame(width: column)
                            .accessibilityLabel(CalendarText.weekdays[index])
                    }
                }
                .frame(height: header)
                Divider()
                // Large text or a short window: the rows keep their minimum height and scroll.
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ForEach(grid.weeks, id: \.days.first) { week in
                            HStack(spacing: 0) {
                                Text("\(week.number)").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                                    .frame(width: weekColumn, height: row, alignment: .top).padding(.top, 8)
                                    .accessibilityLabel("Kalenderwoche \(week.number)")
                                ForEach(week.days, id: \.self) { day in
                                    cell(day, inMonth: grid.contains(day, calendar: calendar), width: column, height: row)
                                }
                            }
                            .frame(height: row)
                            Divider()
                        }
                    }
                }
                .scrollDisabled(row * CGFloat(grid.weeks.count) <= available + 1)
            }
        }
    }

    private func cell(_ day: Date, inMonth: Bool, width: CGFloat, height: CGFloat) -> some View {
        let events = model.events(on: day)
        let capacity = Int((height - dateRow - 4) / line)
        let split = CalendarOverflow.split(total: events.count, capacity: capacity)
        let isToday = calendar.isDate(day, inSameDayAs: model.today)
        let weekend = CalendarDates.weekdayIndex(day, calendar: calendar) >= 5
        return VStack(alignment: .leading, spacing: 0) {
            Button { model.open(day, in: .day) } label: {
                Text("\(calendar.component(.day, from: day))")
                    .font(.callout.weight(isToday ? .bold : .regular)).monospacedDigit()
                    .foregroundStyle(isToday ? Color.white : inMonth ? Color.primary : Color.secondary)
                    .frame(minWidth: 28, minHeight: 28)
                    .background { if isToday { Circle().fill(CalendarPalette.today) } }
                    .frame(minWidth: 44, minHeight: dateRow, alignment: .leading)
                    .padding(.leading, 4)
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
                    Text(CalendarText.more(split.hidden)).font(.caption.weight(.semibold)).foregroundStyle(CalendarPalette.selection)
                        .frame(maxWidth: .infinity, minHeight: line, alignment: .leading).padding(.horizontal, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(split.hidden) weitere Termine am \(CalendarText.shortDate(day, calendar: calendar))")
                .accessibilityHint("Zeigt die vollständige Tagesliste")
            }
            Spacer(minLength: 0)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .background(weekend || !inMonth ? Color.white.opacity(0.025) : Color.clear)
        .overlay(alignment: .leading) { Rectangle().fill(Color(uiColor: .separator).opacity(0.6)).frame(width: 0.5) }
        .opacity(inMonth ? 1 : 0.75)
    }
}

/// One compact line of the month: colour mark, time, title, symbols.
struct CalendarMonthRow: View {
    let event: CalendarSampleEvent
    @ObservedObject var model: CalendarDesignModel

    var body: some View {
        let color = CalendarPalette.color(event)
        let selected = model.selection == event.id
        let notes = model.hasNotes(event)
        Button { model.selection = event.id } label: {
            HStack(spacing: 4) {
                if event.allDay {
                    RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4, height: 12)
                } else {
                    Circle().fill(color).frame(width: 7, height: 7)
                    Text(CalendarText.clock(event.start, calendar: model.calendar)).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
                if let symbol = event.status.symbol { Image(systemName: symbol).font(.caption2) }
                Text(event.title).font(.caption).strikethrough(event.status == .cancelled).lineLimit(1)
                Spacer(minLength: 0)
                if notes { Image(systemName: "note.text").font(.caption2) }
            }
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 4).fill(event.allDay ? color.opacity(0.25) : selected ? CalendarPalette.selection.opacity(0.25) : .clear)
            }
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
    @ObservedObject var model: CalendarDesignModel
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
                    Text(NotyText.count(events.count, "Termin", "Termine") + " · Beispieldaten")
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
    let event: CalendarSampleEvent
    @ObservedObject var model: CalendarDesignModel
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

/// Year: twelve compact months; marked event days and sample holidays.
struct CalendarYearView: View {
    @ObservedObject var model: CalendarDesignModel
    @ScaledMetric(relativeTo: .body) private var cell: CGFloat = 44
    private var calendar: Calendar { model.calendar }

    var body: some View {
        GeometryReader { geo in
            let tile = cell * 7 + 24
            let columns = max(1, Int((geo.size.width - 24) / (tile + 20)))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    legend
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(tile), spacing: 20, alignment: .top), count: columns),
                              alignment: .leading, spacing: 24) {
                        ForEach(CalendarDates.yearMonths(model.anchor, calendar: calendar), id: \.self) { month($0) }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 18) {
            Label { Text("Termine") } icon: { Circle().fill(Color.secondary).frame(width: 6, height: 6) }
            Label { Text("Ferien (Beispiel – keine echte Ferienquelle)") } icon: {
                RoundedRectangle(cornerRadius: 3).fill(CalendarPalette.holidays.opacity(0.4)).frame(width: 18, height: 10)
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func month(_ month: Date) -> some View {
        let grid = CalendarMonthGrid(month: month, calendar: calendar)
        let current = calendar.isDate(month, equalTo: model.today, toGranularity: .month)
        let index = calendar.component(.month, from: month) - 1
        return VStack(alignment: .leading, spacing: 4) {
            Button { model.open(month, in: .month) } label: {
                Text(CalendarText.months[index]).font(.headline)
                    .foregroundStyle(current ? CalendarPalette.today : .primary)
                    .frame(minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(CalendarText.months[index]) \(calendar.component(.year, from: month))")
            .accessibilityHint("Öffnet den Monat")
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { Text(String(CalendarText.shortWeekdays[$0].prefix(1))).frame(width: cell) }
            }
            .font(.caption2).foregroundStyle(.secondary).accessibilityHidden(true)
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
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(uiColor: .secondarySystemBackground)))
    }

    private func dayCell(_ day: Date) -> some View {
        let events = model.events(on: day)
        let holiday = events.first { $0.source == .holidays }
        let count = events.filter { $0.source != .holidays }.count
        let isToday = calendar.isDate(day, inSameDayAs: model.today)
        return Button { model.open(day, in: .day) } label: {
            VStack(spacing: 2) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.callout.weight(isToday ? .bold : .regular)).monospacedDigit()
                    .foregroundStyle(isToday ? Color.white : .primary)
                    .frame(width: 30, height: 28)
                    .background { if isToday { Circle().fill(CalendarPalette.today) } }
                Circle().fill(count > 0 ? Color.secondary : .clear).frame(width: 5, height: 5)
            }
            .frame(width: cell, height: cell)
            .background {
                if holiday != nil { Rectangle().fill(CalendarPalette.holidays.opacity(0.4)).padding(.vertical, 6) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel([CalendarText.longDate(day, calendar: calendar), isToday ? "heute" : nil,
                             count > 0 ? NotyText.count(count, "Termin", "Termine") : nil, holiday?.title].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Öffnet den Tag")
    }
}
