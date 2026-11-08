import SwiftUI
import NotebookCore

/// Form for own events of „Persönlich“ (Stufe B2): single events and series
/// (täglich, wöchentlich, monatlich; Ende nie, nach Anzahl oder am Datum;
/// einzelne Ausnahmen), timed or all-day (also several days). A changed
/// occurrence of a series asks „Nur dieser Termin“ / „Alle Termine der
/// Serie“. „Hinzufügen“/„Fertig“ closes only after the commit; a rejected
/// change keeps the form open with its input. Optional reminder (B3, off by
/// default): switching it on asks iPadOS for permission once. Stufe C: the
/// target is chosen consciously – noty („Persönlich“) or a writable system
/// calendar (Apple Kalender, Outlook/Exchange); system events keep their
/// calendar unless another one is chosen (single events only).
struct CalendarEventForm: View {
    @State var draft: CalendarDraft
    @ObservedObject var model: CalendarModel
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var failure: String?
    @State private var askingScope = false
    @State private var newException = Date()
    /// Where the event is written; set on appear from the entry or the default.
    @State private var target: CalendarWriteTarget = .local
    @State private var targetSet = false
    private var systemTarget: Bool { target != .local }
    private var editingSystem: Bool { model.isSystemSeries(draft.editing) || (draft.editing.map { model.isSystem($0) } ?? false) }
    private var asksScope: Bool { draft.isSeriesOccurrence || model.isSystemSeries(draft.editing) }
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
                if model.hasComplexSystemRule(draft.editing) {
                    Section {
                        LabeledContent("Wiederholen", value: "im Kalender festgelegt")
                    } footer: {
                        Text("Diese Wiederholung kann noty nicht darstellen; sie bleibt unverändert. Ändern bitte in Apple Kalender bzw. Outlook.")
                    }
                } else {
                    repeatSection
                }
                reminderSection
                Section {
                    targetPicker
                    TextField("Beschreibung", text: $draft.details, axis: .vertical).lineLimit(2...8)
                } footer: {
                    Text(targetFooter)
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
                        if asksScope { askingScope = true } else { save(.all) }
                    }
                    .disabled(saving || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || invalidRange)
                }
            }
            .confirmationDialog("Änderung übernehmen für", isPresented: $askingScope, titleVisibility: .visible) {
                // A changed rule (also of a system series) concerns the whole series: only „Alle“.
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
        .onAppear {
            guard !targetSet else { return }
            targetSet = true
            target = draft.editing.flatMap { model.writeTarget(of: $0) } ?? (draft.editing == nil ? model.systemDefaultTarget : .local)
        }
        .onChange(of: draft.start) { old, new in
            // Moving the start keeps the duration.
            if let moved = calendar.date(byAdding: .second, value: Int(draft.end.timeIntervalSince(old)), to: new) { draft.end = moved }
        }
    }

    /// Off by default; presets from „Zum Beginn“ to „1 Tag vorher“. A series
    /// reminds before every occurrence.
    @ViewBuilder private var reminderSection: some View {
        let general = model.notificationSettings.eventReminders && !draft.allDay && !systemTarget
        Section {
            Toggle("Erinnerung", isOn: $draft.reminder)
                .onChange(of: draft.reminder) { _, on in
                    // System calendars remind themselves (no noty notification).
                    if on, !systemTarget { Task { await model.requestReminderPermission() } }
                }
            if draft.reminder {
                Picker("Wann", selection: $draft.reminderMinutes) {
                    ForEach(CalendarReminder.presets, id: \.self) { Text(CalendarReminder.text($0)).tag($0) }
                }
            }
        } footer: {
            if !draft.reminder && general {
                Text("Ohne eigene Erinnerung gilt die allgemeine: \(CalendarReminder.text(model.notificationSettings.eventMinutes)) (Benachrichtigungen).")
            } else if draft.reminder && systemTarget {
                Text("Die Erinnerung trägt der Systemkalender ein und meldet sie selbst.")
            } else if draft.reminder {
                switch model.reminderPermission {
                case .denied:
                    Label("Mitteilungen für noty sind ausgeschaltet. Bitte in den iPad-Einstellungen › Mitteilungen › noty erlauben; bis dahin erscheint keine Erinnerung.",
                          systemImage: "bell.slash").foregroundStyle(.orange)
                default:
                    Text(draft.allDay ? "Ganztägige Termine erinnern ausgehend von 9:00 Uhr am ersten Tag." :
                         (draft.repeatRule != .never ? "Gilt für jeden Termin der Serie." : "Mitteilung auf diesem iPad."))
                }
            }
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
                if !systemTarget {
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

    /// „Kalender“: noty or one of the shown writable system calendars.
    @ViewBuilder private var targetPicker: some View {
        let calendars = model.writableSystemCalendars
        if calendars.isEmpty && target == .local {
            LabeledContent("Kalender") {
                Label { Text("Persönlich") } icon: { Circle().fill(CalendarPalette.personal).frame(width: 8, height: 8) }
            }
        } else {
            Picker("Kalender", selection: $target) {
                Label { Text("Persönlich (noty)") } icon: { Circle().fill(CalendarPalette.personal).frame(width: 8, height: 8) }
                    .tag(CalendarWriteTarget.local)
                ForEach(calendars) { item in
                    Label { Text(item.displayName) } icon: { Circle().fill(dot(item.colorHex)).frame(width: 8, height: 8) }
                        .tag(CalendarWriteTarget.system(calendarID: item.id))
                }
                // The entry's own calendar, also when it is hidden meanwhile.
                if case .system(let id) = target, !calendars.contains(where: { $0.id == id }) {
                    Text(model.systemCalendars.first { $0.id == id }?.displayName ?? "Bisheriger Kalender").tag(target)
                }
            }
        }
    }

    private func dot(_ hex: String) -> Color {
        guard let c = CalendarColorHex.components(hex) else { return .gray }
        return Color(red: c.red, green: c.green, blue: c.blue)
    }

    private var targetFooter: String {
        let original = draft.editing.flatMap { model.writeTarget(of: $0) }
        var text: String
        switch target {
        case .local:
            text = "Wird nur auf diesem iPad in diesem Bereich gespeichert. Unterricht aus WebUntis bleibt schreibgeschützt."
        case .system(let id):
            let name = model.systemCalendars.first { $0.id == id }?.displayName ?? "den Systemkalender"
            text = "Wird über iPadOS in „\(name)“ eingetragen; Apple Kalender bzw. Outlook übernehmen den Termin, sobald das Konto ihn abgleicht. Notizen bleiben in noty und werden nicht hochgeladen."
        }
        if let original, original != target {
            text += draft.repeatRule != .never || editingSystem && model.isSystemSeries(draft.editing)
                ? " Serien lassen sich nicht in einen anderen Kalender verschieben."
                : " Der Termin wird in den gewählten Kalender verschoben; Notizen gehen mit."
        }
        return text
    }

    private func save(_ scope: CalendarModel.SeriesScope) {
        saving = true
        failure = nil
        let target = target
        Task {
            let problem = await model.save(draft, scope: scope, target: target)
            saving = false
            if let problem { failure = problem } else { dismiss() }
        }
    }
}
