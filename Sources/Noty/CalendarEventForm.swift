import SwiftUI
import NotebookCore

/// Event form of the design stage: every field of the planned first
/// version, nothing is saved (Stufe A).
struct CalendarEventForm: View {
    @State var draft: CalendarDraft
    let calendar: Calendar
    @Environment(\.dismiss) private var dismiss
    @State private var askingScope = false
    @State private var newException = Date()

    private var invalidRange: Bool { draft.allDay ? calendar.startOfDay(for: draft.end) < calendar.startOfDay(for: draft.start) : draft.end <= draft.start }
    private var editingSeries: Bool { draft.editing?.seriesID != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Titel", text: $draft.title)
                    TextField("Ort", text: $draft.location)
                }
                Section {
                    Toggle("Ganztägig", isOn: $draft.allDay)
                    DatePicker("Beginn", selection: $draft.start, displayedComponents: draft.allDay ? [.date] : [.date, .hourAndMinute])
                    DatePicker("Ende", selection: $draft.end, displayedComponents: draft.allDay ? [.date] : [.date, .hourAndMinute])
                } footer: {
                    if invalidRange {
                        Label("Das Ende liegt vor dem Beginn. Bitte eine gültige Zeitspanne wählen.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                repeatSection
                reminderSection
                Section {
                    LabeledContent("Kalender") {
                        Label { Text("Persönlich") } icon: { Circle().fill(CalendarPalette.personal).frame(width: 8, height: 8) }
                    }
                    TextField("Beschreibung", text: $draft.details, axis: .vertical).lineLimit(2...8)
                } footer: {
                    Text("Entwurf: Eingaben werden nicht gespeichert. Unterricht aus WebUntis bleibt schreibgeschützt.")
                }
            }
            .navigationTitle(draft.editing == nil ? "Neuer Termin" : "Termin bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(draft.editing == nil ? "Hinzufügen" : "Fertig") {
                        if editingSeries { askingScope = true } else { dismiss() }
                    }
                    .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || invalidRange)
                }
            }
            .confirmationDialog("Änderung übernehmen für", isPresented: $askingScope, titleVisibility: .visible) {
                Button("Nur diesen Termin") { dismiss() }
                Button("Gesamte Serie") { dismiss() }
            } message: { Text("Entwurf: Es wird nichts gespeichert.") }
        }
        .environment(\.locale, Locale(identifier: "de_DE"))
        .environment(\.calendar, calendar)
        .preferredColorScheme(.dark)
        .onChange(of: draft.start) { old, new in
            // Moving the start keeps the duration.
            if let moved = calendar.date(byAdding: .second, value: Int(draft.end.timeIntervalSince(old)), to: new) { draft.end = moved }
        }
    }

    /// „Wiederholen“ stays one row until a rule is chosen; end and
    /// exceptions are behind a disclosure.
    @ViewBuilder private var repeatSection: some View {
        Section {
            Picker("Wiederholen", selection: $draft.repeatRule) {
                ForEach(CalendarDraft.Repeat.allCases) { Text($0.title).tag($0) }
            }
            if draft.repeatRule != .never {
                Picker("Endet", selection: $draft.repeatEnd) {
                    ForEach(CalendarDraft.RepeatEnd.allCases) { Text($0.title).tag($0) }
                }
                switch draft.repeatEnd {
                case .never: EmptyView()
                case .onDate: DatePicker("Letzter Termin", selection: $draft.repeatUntil, in: draft.start..., displayedComponents: [.date])
                case .afterCount: Stepper("Nach \(draft.repeatCount) Terminen", value: $draft.repeatCount, in: 2...500)
                }
                DisclosureGroup(draft.exceptions.isEmpty ? "Ausnahmen" : "Ausnahmen (\(draft.exceptions.count))") {
                    ForEach(draft.exceptions, id: \.self) { date in
                        Text(CalendarText.longDate(date, calendar: calendar))
                    }
                    .onDelete { draft.exceptions.remove(atOffsets: $0) }
                    HStack {
                        DatePicker("Ausnahme am", selection: $newException, displayedComponents: [.date])
                        Button("Hinzufügen") {
                            let day = calendar.startOfDay(for: newException)
                            if !draft.exceptions.contains(day) { draft.exceptions.append(day); draft.exceptions.sort() }
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        } footer: {
            if draft.repeatRule != .never { Text(repeatSummary) }
        }
    }

    private var repeatSummary: String {
        let weekday = CalendarText.weekdays[CalendarDates.weekdayIndex(draft.start, calendar: calendar)]
        var parts: [String]
        switch draft.repeatRule {
        case .never: return ""
        case .daily: parts = ["Täglich"]
        case .weekly: parts = ["Wöchentlich am \(weekday)"]
        case .monthly: parts = ["Monatlich am \(calendar.component(.day, from: draft.start))."]
        }
        switch draft.repeatEnd {
        case .never: parts.append("ohne Ende")
        case .onDate: parts.append("bis \(CalendarText.numericDate(draft.repeatUntil, calendar: calendar))")
        case .afterCount: parts.append("\(draft.repeatCount) Termine")
        }
        if !draft.exceptions.isEmpty { parts.append(NotyText.count(draft.exceptions.count, "Ausnahme", "Ausnahmen")) }
        return parts.joined(separator: ", ") + "."
    }

    @ViewBuilder private var reminderSection: some View {
        Section {
            Toggle("Erinnerung", isOn: $draft.reminder)
            if draft.reminder {
                Picker("Zeitpunkt", selection: $draft.reminderMinutes) {
                    Text("Zum Beginn").tag(0)
                    ForEach([5, 10, 15, 30, 60], id: \.self) { Text("\($0) Minuten vorher").tag($0) }
                    Text("1 Tag vorher").tag(1440)
                }
            }
        } footer: {
            if draft.reminder { Text("Für Unterricht folgt eine allgemeine Einstellung (z. B. 10 Minuten vorher); doppelte Hinweise werden vermieden.") }
        }
    }
}
