import SwiftUI
import NotebookCore

/// Form for own events of „Persönlich“ (Stufe B2): single events and series
/// (täglich, wöchentlich, monatlich; Ende nie, nach Anzahl oder am Datum;
/// einzelne Ausnahmen), timed or all-day (also several days). A changed
/// occurrence of a series asks „Nur dieser Termin“ / „Alle Termine der
/// Serie“. „Hinzufügen“/„Fertig“ closes only after the commit; a rejected
/// change keeps the form open with its input. Reminders follow in B3.
struct CalendarEventForm: View {
    @State var draft: CalendarDraft
    @ObservedObject var model: CalendarModel
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var failure: String?
    @State private var askingScope = false
    @State private var newException = Date()
    private var calendar: Calendar { model.calendar }

    private var invalidRange: Bool {
        draft.allDay ? calendar.startOfDay(for: draft.end) < calendar.startOfDay(for: draft.start) : draft.end <= draft.start
    }

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
                Section {
                    LabeledContent("Kalender") {
                        Label { Text("Persönlich") } icon: { Circle().fill(CalendarPalette.personal).frame(width: 8, height: 8) }
                    }
                    TextField("Beschreibung", text: $draft.details, axis: .vertical).lineLimit(2...8)
                } footer: {
                    Text("Wird nur auf diesem iPad in diesem Bereich gespeichert. Erinnerungen folgen in einem späteren Build. Unterricht aus WebUntis bleibt schreibgeschützt.")
                }
                if let failure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
            }
            .disabled(saving)
            .navigationTitle(draft.editing == nil ? "Neuer Termin" : "Termin bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(draft.editing == nil ? "Hinzufügen" : "Fertig") {
                        if draft.isSeriesOccurrence { askingScope = true } else { save(.all) }
                    }
                    .disabled(saving || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || invalidRange)
                }
            }
            .confirmationDialog("Änderung übernehmen für", isPresented: $askingScope, titleVisibility: .visible) {
                if !draft.changesSeries(calendar: calendar) {
                    Button("Nur dieser Termin") { save(.single) }
                }
                Button("Alle Termine der Serie") { save(.all) }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                Text(draft.changesSeries(calendar: calendar)
                     ? "Wiederholung oder Ausnahmen wurden geändert; das betrifft die ganze Serie."
                     : "Dieser Termin gehört zu einer Serie. Notizen einzelner Termine bleiben bei ihrem Termin.")
            }
        }
        .environment(\.locale, Locale(identifier: "de_DE"))
        .environment(\.calendar, calendar)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(saving)
        .onChange(of: draft.start) { old, new in
            // Moving the start keeps the duration.
            if let moved = calendar.date(byAdding: .second, value: Int(draft.end.timeIntervalSince(old)), to: new) { draft.end = moved }
        }
    }

    /// „Wiederholen“ stays one row until a rule is chosen; end and
    /// exceptions follow only then.
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
                case .afterCount: Stepper("Nach \(draft.repeatCount) Terminen", value: $draft.repeatCount, in: 1...CalendarRecurrence.maximumCount)
                }
                DisclosureGroup(draft.exceptionDates.isEmpty ? "Ausnahmen" : "Ausnahmen (\(draft.exceptionDates.count))") {
                    ForEach(draft.exceptionDates, id: \.self) { date in
                        Text(CalendarText.longDate(date.start(in: calendar), calendar: calendar))
                    }
                    .onDelete { draft.exceptionDates.remove(atOffsets: $0); draft.exceptionsEdited = true }
                    HStack {
                        DatePicker("Ausnahme am", selection: $newException, displayedComponents: [.date])
                        Button("Hinzufügen") {
                            let day = CivilDate(newException, calendar: calendar)
                            if !draft.exceptionDates.contains(day) {
                                draft.exceptionDates.append(day); draft.exceptionDates.sort(); draft.exceptionsEdited = true
                            }
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
        let day = calendar.component(.day, from: draft.start)
        var parts: [String]
        switch draft.repeatRule {
        case .never: return ""
        case .daily: parts = ["Täglich"]
        case .weekly: parts = ["Wöchentlich am \(weekday)"]
        case .monthly: parts = ["Monatlich am \(day)."]
        }
        switch draft.repeatEnd {
        case .never: parts.append("ohne Ende")
        case .onDate: parts.append("bis \(CalendarText.numericDate(draft.repeatUntil, calendar: calendar))")
        case .afterCount: parts.append(draft.repeatCount == 1 ? "1 Termin" : "\(draft.repeatCount) Termine")
        }
        if !draft.exceptionDates.isEmpty { parts.append(NotyText.count(draft.exceptionDates.count, "Ausnahme", "Ausnahmen")) }
        var text = parts.joined(separator: ", ") + "."
        if draft.repeatRule == .monthly && day > 28 { text += " In Monaten ohne den \(day). entfällt der Termin." }
        return text
    }

    private func save(_ scope: CalendarModel.SeriesScope) {
        saving = true
        failure = nil
        Task {
            let problem = await model.save(draft, scope: scope)
            saving = false
            if let problem { failure = problem } else { dismiss() }
        }
    }
}
