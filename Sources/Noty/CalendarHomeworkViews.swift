import SwiftUI
import NotebookCore

// Hausaufgaben aus WebUntis (offline timetable) with the local „erledigt“
// mark (never sent to WebUntis): rows for the sidebar, the event window and
// the complete list.

/// One homework: check box (44 pt), subject colour, text, due date, remark,
/// attachments and the WebUntis state – in words, not by colour.
struct CalendarHomeworkRow: View {
    let item: CalendarHomeworkItem
    @ObservedObject var model: CalendarModel
    var showsSubject = true
    var compact = false

    private var color: Color {
        let key = CalendarSubjectColor.key(subjectID: item.homework.subjectID, name: item.homework.subject ?? "Hausaufgabe")
        return CalendarPalette.color(named: CalendarSubjectColor.name(for: key, chosen: model.subjectColors))
    }

    var body: some View {
        let work = item.homework
        HStack(alignment: .top, spacing: CalendarSpace.s) {
            Button {
                Task { await model.setHomeworkDone(item.id, done: !item.done) }
            } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.done ? Color.green : Color.secondary)
                    .frame(width: 32, height: 44, alignment: .top)
                    .padding(.top, 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!model.canWrite)
            .accessibilityLabel(item.done ? "Als offen markieren" : "Als erledigt markieren")
            VStack(alignment: .leading, spacing: 2) {
                if showsSubject {
                    HStack(spacing: 5) {
                        Circle().fill(color).frame(width: 7, height: 7)
                        Text(work.subject ?? "Hausaufgabe").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                Text(work.text.isEmpty ? "ohne Text" : work.text)
                    .font(.subheadline).strikethrough(item.done).foregroundStyle(item.done ? .secondary : .primary)
                    .lineLimit(compact ? 3 : nil).fixedSize(horizontal: false, vertical: true)
                if let remark = work.remark, !compact {
                    Text(remark).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    Text(dueText).foregroundStyle(overdue ? Color.orange : .secondary)
                    if work.attachmentCount > 0 {
                        Label("\(work.attachmentCount)", systemImage: "paperclip").labelStyle(CalendarCompactLabelStyle())
                            .accessibilityLabel(NotyText.count(work.attachmentCount, "Anhang in WebUntis", "Anhänge in WebUntis"))
                    }
                    if work.completedInSource { Text("· in WebUntis erledigt") }
                }
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.top, 4)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(item.done ? "erledigt" : "offen")
    }

    private var overdue: Bool {
        !item.done && item.homework.due < CivilDate(model.today, calendar: model.calendar)
    }

    /// „fällig heute“, „fällig morgen“, „fällig Mo 9.11.“, „überfällig seit …“.
    private var dueText: String {
        let calendar = model.calendar
        let day = item.homework.due.start(in: calendar)
        let today = calendar.startOfDay(for: model.today)
        let days = CalendarDates.days(from: today, to: day, calendar: calendar)
        let weekday = CalendarText.shortWeekdays[CalendarDates.weekdayIndex(day, calendar: calendar)]
        let date = "\(weekday) \(item.homework.due.day).\(item.homework.due.month)."
        switch days {
        case 0: return "fällig heute"
        case 1: return "fällig morgen"
        case ..<0: return item.done ? "war fällig \(date)" : "überfällig seit \(date)"
        default: return "fällig \(date)"
        }
    }
}

/// Complete list (sidebar „Alle anzeigen“): open first, done on request.
struct CalendarHomeworkList: View {
    @ObservedObject var model: CalendarModel
    @Environment(\.dismiss) private var dismiss
    @State private var showsDone = false

    var body: some View {
        NavigationStack {
            let all = model.homework
            let items = all.filter { showsDone || !$0.done }
            List {
                ForEach(items) { item in
                    CalendarHomeworkRow(item: item, model: model)
                }
            }
            .overlay {
                if all.isEmpty {
                    ContentUnavailableView("Keine Hausaufgaben", systemImage: "book.closed",
                                           description: Text(model.connection == nil ? "Hausaufgaben kommen aus WebUntis. Bitte zuerst WebUntis verbinden."
                                                             : "Im geladenen Zeitraum liefert WebUntis keine Hausaufgaben."))
                } else if items.isEmpty {
                    ContentUnavailableView("Alles erledigt", systemImage: "checkmark.circle")
                }
            }
            .navigationTitle("Hausaufgaben")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Toggle("Erledigte zeigen", isOn: $showsDone).toggleStyle(.button) }
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                Text("„Erledigt“ gilt nur in noty und wird nicht an WebUntis gesendet.")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, CalendarSpace.s)
            }
        }
        .preferredColorScheme(.dark)
    }
}
