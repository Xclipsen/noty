import SwiftUI
import NotebookCore

// Mitteilungen (docs/CALENDAR-PLAN.md, 08.11.2026): the bell beside
// the sync symbol and its history popover.

/// Bell of the toolbar with the number of unread entries (never colour
/// alone: VoiceOver says the number).
struct CalendarBellSymbol: View {
    let unread: Int

    var body: some View {
        Image(systemName: unread > 0 ? "bell.badge" : "bell")
            .overlay(alignment: .topTrailing) {
                if unread > 0 {
                    Text(unread > 99 ? "99+" : "\(unread)")
                        .font(.caption2.weight(.bold)).monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Capsule().fill(Color.red))
                        .overlay { Capsule().strokeBorder(Color(uiColor: .systemBackground), lineWidth: 1.5) }
                        .fixedSize()
                        .offset(x: 10, y: -8)
                        // A data change, not a user action: only a short fade.
                        .transition(.opacity)
                }
            }
            .animation(NotyMotion.fade, value: unread > 0)
            .accessibilityElement()
            .accessibilityLabel("Mitteilungen")
            .accessibilityValue(unread == 0 ? "Keine ungelesenen" : NotyText.count(unread, "ungelesene", "ungelesene"))
            .accessibilityHint("Zeigt den Verlauf")
            .help("Mitteilungen")
    }
}

/// History of the shown area, newest first: tapping an entry opens its
/// day/entry (as the notification would) and marks it read.
struct CalendarNotificationsPopover: View {
    @ObservedObject var model: CalendarModel
    let openSettings: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.notificationLog.records.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.notificationLog.records) { record in
                            row(record)
                            Divider().padding(.leading, 52)
                        }
                    }
                }
            }
        }
        .frame(idealWidth: 380, maxWidth: 420)
        .frame(minHeight: 160, idealHeight: 420)
        .presentationCompactAdaptation(.popover)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: CalendarSpace.s) {
            HStack(spacing: CalendarSpace.s) {
                Text("Mitteilungen").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer(minLength: CalendarSpace.s)
                Button("Alle gelesen") { model.markAllNotificationsRead() }
                    .font(.subheadline.weight(.semibold))
                    .disabled(model.unreadNotifications == 0)
                Button { openSettings() } label: {
                    Image(systemName: "gearshape").frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Einstellungen für Mitteilungen")
            }
            .buttonStyle(.borderless)
            switch model.reminderPermission {
            case .notDetermined:
                Button { Task { await model.enableNotifications() } } label: {
                    Label("Mitteilungen auf dem iPad einschalten", systemImage: "bell.badge")
                }
                .buttonStyle(.bordered)
                .font(.footnote.weight(.semibold))
            case .denied:
                Label("Mitteilungen für noty sind in den iPad-Einstellungen aus; neue Einträge erscheinen nur hier.", systemImage: "bell.slash")
                    .font(.footnote).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            case .allowed:
                EmptyView()
            }
        }
        .padding(.horizontal, CalendarSpace.l).padding(.vertical, CalendarSpace.m)
    }

    private var empty: some View {
        VStack(spacing: CalendarSpace.s) {
            Image(systemName: "bell").font(.title2).foregroundStyle(.secondary).accessibilityHidden(true)
            Text("Noch keine Mitteilungen").font(.subheadline.weight(.semibold))
            Text("Stundenplanänderungen, Morgen-Überblicke und Erinnerungen erscheinen hier – auch die, die nur in den Ruhezeiten kamen.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(CalendarSpace.xl)
    }

    private func row(_ record: CalendarNotificationRecord) -> some View {
        Button {
            close()
            model.open(record)
        } label: {
            HStack(alignment: .top, spacing: CalendarSpace.m) {
                Image(systemName: symbol(record.kind))
                    .font(.body).foregroundStyle(tint(record.kind))
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: CalendarSpace.s) {
                        Text(record.title).font(.subheadline.weight(record.read ? .regular : .semibold)).lineLimit(2)
                        Spacer(minLength: CalendarSpace.xs)
                        Text(when(record.date)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    if !record.body.isEmpty {
                        Text(record.body).font(.footnote).foregroundStyle(.secondary).lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Circle().fill(record.read ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.tint)).frame(width: 8, height: 8)
                    .padding(.top, 6)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, CalendarSpace.l).padding(.vertical, CalendarSpace.m)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel((record.read ? "" : "Ungelesen, ") + record.title + ", " + record.body + ", " + when(record.date))
        .accessibilityHint(record.day == nil ? "" : "Öffnet den Tag im Kalender")
        .contextMenu {
            if !record.read {
                Button("Als gelesen markieren", systemImage: "envelope.open") { model.markNotificationRead(record.id) }
            }
        }
    }

    private func symbol(_ kind: CalendarNotificationRecord.Kind) -> String {
        switch kind {
        case .change: "arrow.triangle.swap"
        case .overview: "sun.horizon"
        case .event: "bell"
        case .lesson: "graduationcap"
        }
    }

    private func tint(_ kind: CalendarNotificationRecord.Kind) -> Color {
        switch kind {
        case .change: .orange
        case .overview: .yellow
        case .event, .lesson: .secondary
        }
    }

    /// „07:12“ today, „gestern 07:12“, otherwise „Mo 2.11.“.
    private func when(_ date: Date) -> String {
        let calendar = model.calendar
        let clock = CalendarText.clock(date, calendar: calendar)
        if calendar.isDateInToday(date) { return clock }
        if calendar.isDateInYesterday(date) { return "gestern \(clock)" }
        let parts = calendar.dateComponents([.day, .month], from: date)
        return "\(CalendarText.shortWeekdays[CalendarDates.weekdayIndex(date, calendar: calendar)]) \(parts.day ?? 1).\(parts.month ?? 1)."
    }
}
