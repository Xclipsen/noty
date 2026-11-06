import SwiftUI
import NotebookCore

// Kalender, UI-Überarbeitung 06.11.2026: optional left sidebar like Apple
// Kalender/Fantastical – mini month, „Als Nächstes“ with countdown and the
// calendars. Only shown when the calendar keeps enough width; ⌃⌘S or the
// toolbar button hides it (`noty.calendar.sidebar`). Reads only existing
// model data (`events(on:)`, `hiddenSources`, `anchor`, `mode`).

extension CalendarModel {
    /// The next timed entries from `now` (running ones first), across the
    /// coming two weeks, holidays and all-day entries excluded. Cancelled
    /// lessons stay in: „fällt aus“ is exactly what one wants to know.
    func upcoming(after now: Date, limit: Int) -> [CalendarEntry] {
        var seen = Set<String>()
        var result: [CalendarEntry] = []
        let first = calendar.startOfDay(for: now)
        for offset in 0..<14 {
            let day = CalendarDates.day(offset, after: first, calendar: calendar)
            for entry in events(on: day) where !entry.allDay && entry.source != .holidays && entry.end > now {
                if seen.insert(entry.id).inserted { result.append(entry) }
            }
            if result.count >= limit { break }
        }
        return Array(result.sorted { $0.start < $1.start }.prefix(limit))
    }

    /// „4 Stunden · 1 Ausfall“ for one day (lessons only); nil without lessons.
    func lessonSummary(on day: Date) -> String? {
        let lessons = events(on: day).filter { $0.source == .timetable && !$0.allDay }
        guard !lessons.isEmpty else { return nil }
        var parts = [NotyText.count(lessons.count, "Stunde", "Stunden")]
        let cancelled = lessons.filter { $0.status == .cancelled }.count
        if cancelled > 0 { parts.append(NotyText.count(cancelled, "Ausfall", "Ausfälle")) }
        let changed = lessons.filter { if case .substitution = $0.status { true } else if case .roomChanged = $0.status { true } else { false } }.count
        if changed > 0 { parts.append(NotyText.count(changed, "Änderung", "Änderungen")) }
        return parts.joined(separator: " · ")
    }
}

struct CalendarSidebar: View {
    static let width: CGFloat = 264
    /// Below this total width the sidebar stays hidden (the grid keeps ≥ 600 pt).
    static let minimumTotalWidth: CGFloat = 864
    @ObservedObject var model: CalendarModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CalendarSpace.xl) {
                CalendarMiniMonth(model: model)
                CalendarUpNext(model: model)
                calendars
            }
            .padding(.horizontal, CalendarSpace.l).padding(.vertical, CalendarSpace.m)
        }
        .background(Color.white.opacity(0.025))
    }

    /// The calendars with their colour; tapping shows or hides one.
    private var calendars: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Kalender").font(.headline).accessibilityAddTraits(.isHeader).padding(.bottom, CalendarSpace.xs)
            ForEach(CalendarSource.allCases) { source in
                let shown = !model.hiddenSources.contains(source)
                Button {
                    if shown { model.hiddenSources.insert(source) } else { model.hiddenSources.remove(source) }
                } label: {
                    HStack(spacing: CalendarSpace.s) {
                        Image(systemName: shown ? "checkmark.circle.fill" : "circle")
                            .font(.body)
                            .foregroundStyle(shown ? sourceStyle(source) : AnyShapeStyle(Color.secondary))
                        Text(source.title).font(.subheadline).foregroundStyle(shown ? .primary : .secondary)
                        Spacer(minLength: 0)
                        if source.readOnly {
                            Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(minHeight: 40).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(source.readOnly ? "\(source.title), schreibgeschützt" : source.title)
                .accessibilityValue(shown ? "eingeblendet" : "ausgeblendet")
                .accessibilityAddTraits(.isToggle)
            }
        }
    }

    /// Lessons have one colour per subject: a small colour wheel stands for them.
    private func sourceStyle(_ source: CalendarSource) -> AnyShapeStyle {
        switch source {
        case .timetable:
            AnyShapeStyle(AngularGradient(colors: CalendarSubjectColor.automatic.map { CalendarPalette.color(named: $0) }, center: .center))
        case .personal: AnyShapeStyle(CalendarPalette.personal)
        case .holidays: AnyShapeStyle(CalendarPalette.holidays)
        case .system: AnyShapeStyle(CalendarPalette.system)
        }
    }
}

/// Mini month: browse months without moving the calendar, tap a day to go
/// there. The shown week/day is underlaid, days with entries get a dot,
/// holidays a faint band.
struct CalendarMiniMonth: View {
    @ObservedObject var model: CalendarModel
    /// Browsed month; nil follows the calendar.
    @State private var browsed: Date?
    private var calendar: Calendar { model.calendar }

    var body: some View {
        let month = browsed ?? model.anchor
        let grid = CalendarMonthGrid(month: month, calendar: calendar)
        let index = calendar.component(.month, from: month) - 1
        let range = CalendarDates.range(model.mode, anchor: model.anchor, weekDays: model.weekDays == 7 ? 7 : 5, calendar: calendar)
        let marksRange = model.mode == .week || model.mode == .day
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                Text("\(CalendarText.months[index]) \(String(calendar.component(.year, from: month)))")
                    .font(.headline).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button { browse(-1, from: month) } label: {
                    Image(systemName: "chevron.left").font(.footnote.weight(.semibold)).frame(width: 36, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Vorheriger Monat")
                Button { browse(1, from: month) } label: {
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).frame(width: 36, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Nächster Monat")
            }
            .buttonStyle(.borderless)
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { day in
                    Text(String(CalendarText.shortWeekdays[day].prefix(2)))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(day >= 5 ? CalendarPalette.quiet : Color.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .accessibilityHidden(true)
            ForEach(grid.weeks, id: \.days.first) { week in
                HStack(spacing: 0) {
                    ForEach(week.days, id: \.self) { day in
                        cell(day, inMonth: grid.contains(day, calendar: calendar),
                             inRange: marksRange && day >= range.start && day < range.end)
                    }
                }
            }
        }
        .onChange(of: model.anchor) { _, _ in browsed = nil }
    }

    private func browse(_ months: Int, from month: Date) {
        browsed = calendar.date(byAdding: .month, value: months, to: CalendarDates.startOfMonth(month, calendar: calendar))
    }

    private func cell(_ day: Date, inMonth: Bool, inRange: Bool) -> some View {
        let events = model.events(on: day)
        let holiday = events.contains { $0.source == .holidays }
        let count = events.filter { $0.source != .holidays }.count
        let isToday = calendar.isDate(day, inSameDayAs: model.today)
        let weekend = CalendarDates.weekdayIndex(day, calendar: calendar) >= 5
        return Button {
            model.anchor = day
            if model.mode == .year || model.mode == .month { model.mode = .day }
        } label: {
            VStack(spacing: 1) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.footnote.weight(isToday ? .bold : .regular)).monospacedDigit()
                    .foregroundStyle(isToday ? Color.white : !inMonth ? CalendarPalette.quiet : weekend ? Color.secondary : Color.primary)
                    .frame(width: 26, height: 26)
                    .background { if isToday { Circle().fill(CalendarPalette.today) } }
                Circle().fill(count > 0 && inMonth ? Color.secondary : .clear).frame(width: 4, height: 4)
            }
            .frame(maxWidth: .infinity).frame(height: 36)
            .background {
                if inRange {
                    RoundedRectangle(cornerRadius: 8).fill(CalendarPalette.selection.opacity(0.18))
                } else if holiday && inMonth {
                    RoundedRectangle(cornerRadius: 8).fill(CalendarPalette.holidays.opacity(0.16)).padding(.vertical, 4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel([CalendarText.longDate(day, calendar: calendar), isToday ? "heute" : nil,
                             count > 0 ? NotyText.count(count, "Termin", "Termine") : nil,
                             holiday ? "Ferien" : nil].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Zeigt den Tag")
        .accessibilityAddTraits(inRange ? .isSelected : [])
    }
}

/// „Als Nächstes“: the running and the next entries with a countdown;
/// tapping opens the event window. Updates every 30 seconds.
struct CalendarUpNext: View {
    @ObservedObject var model: CalendarModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            let items = model.upcoming(after: now, limit: 4)
            VStack(alignment: .leading, spacing: CalendarSpace.s) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Als Nächstes").font(.headline).accessibilityAddTraits(.isHeader)
                    if let summary = model.lessonSummary(on: now) {
                        Text("Heute: \(summary)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if items.isEmpty {
                    Text(model.loaded ? "In den nächsten zwei Wochen keine Termine mit Uhrzeit." : "Wird geladen …")
                        .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(items.enumerated()), id: \.element.id) { index, event in
                    row(event, now: now, first: index == 0)
                }
            }
        }
    }

    private func row(_ event: CalendarEntry, now: Date, first: Bool) -> some View {
        let color = CalendarPalette.color(event)
        let running = event.start <= now
        let cancelled = event.status == .cancelled
        let when = Self.when(event, now: now, calendar: model.calendar)
        return Button { model.show(event) } label: {
            HStack(alignment: .top, spacing: CalendarSpace.s) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4).frame(minHeight: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(when).font(.caption.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(running ? CalendarPalette.today : first ? Color.primary : Color.secondary)
                    HStack(spacing: 4) {
                        if let symbol = event.status.symbol {
                            Image(systemName: symbol).font(.caption2.weight(.bold)).foregroundStyle(cancelled ? Color.orange : .secondary)
                        }
                        Text(event.title).font(.subheadline.weight(.semibold)).strikethrough(cancelled).lineLimit(1)
                    }
                    let detail = [event.status.label, event.room].compactMap { $0 }.joined(separator: " · ")
                    if !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(cancelled ? Color.orange : .secondary).lineLimit(1)
                    }
                    if running { progress(event, now: now, color: color) }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6).padding(.horizontal, first ? 8 : 0)
            .background {
                if first { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(0.13)) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(when + ", " + event.accessibilityText(model.calendar, notes: model.hasNotes(event)))
        .accessibilityHint("Zeigt Details und Notizseite")
    }

    private func progress(_ event: CalendarEntry, now: Date, color: Color) -> some View {
        let total = max(1, event.end.timeIntervalSince(event.start))
        let done = min(1, max(0, now.timeIntervalSince(event.start) / total))
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule().fill(color).frame(width: geo.size.width * done)
            }
        }
        .frame(height: 4)
        .padding(.top, 2)
        .accessibilityHidden(true)
    }

    /// „Jetzt · noch 25 Min.“, „in 12 Min.“, „Heute 13:50“, „Morgen 08:00“, „Mo 9.11. 08:00“.
    static func when(_ event: CalendarEntry, now: Date, calendar: Calendar) -> String {
        let clock = CalendarText.clock(event.start, calendar: calendar)
        if event.start <= now {
            return "Jetzt · noch \(duration(event.end.timeIntervalSince(now)))"
        }
        let seconds = event.start.timeIntervalSince(now)
        if seconds < 60 * 60 { return "in \(duration(seconds)) · \(clock)" }
        if calendar.isDate(event.start, inSameDayAs: now) { return "Heute \(clock)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
           calendar.isDate(event.start, inSameDayAs: tomorrow) { return "Morgen \(clock)" }
        let weekday = CalendarText.shortWeekdays[CalendarDates.weekdayIndex(event.start, calendar: calendar)]
        let parts = calendar.dateComponents([.day, .month], from: event.start)
        return "\(weekday) \(parts.day ?? 1).\(parts.month ?? 1). \(clock)"
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        if minutes < 60 { return "\(minutes) Min." }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) Std." : "\(hours) Std. \(rest) Min."
    }
}
