import SwiftUI
import NotebookCore

/// Form for own events of „Persönlich“ (Stufe B1): single events, timed or
/// all-day (also several days). „Hinzufügen“/„Fertig“ closes only after the
/// commit; a failed commit keeps the form open with its input.
/// Repetitions and reminders follow in B2 and are not offered yet.
struct CalendarEventForm: View {
    @State var draft: CalendarDraft
    @ObservedObject var model: CalendarModel
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var failure: String?
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
                Section {
                    LabeledContent("Kalender") {
                        Label { Text("Persönlich") } icon: { Circle().fill(CalendarPalette.personal).frame(width: 8, height: 8) }
                    }
                    TextField("Beschreibung", text: $draft.details, axis: .vertical).lineLimit(2...8)
                } footer: {
                    Text("Wird nur auf diesem iPad in diesem Bereich gespeichert. Wiederholungen und Erinnerungen folgen in einem späteren Build. Unterricht aus WebUntis bleibt schreibgeschützt.")
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
                    Button(draft.editing == nil ? "Hinzufügen" : "Fertig") { save() }
                        .disabled(saving || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || invalidRange)
                }
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

    private func save() {
        saving = true
        failure = nil
        Task {
            let problem = await model.save(draft)
            saving = false
            if let problem { failure = problem } else { dismiss() }
        }
    }
}
