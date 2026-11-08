import SwiftUI
import NotebookCore

/// „Fachfarben“ as a sheet of the calendar (menu „…“); the same list as
/// Einstellungen › Kalender › Fachfarben.
struct CalendarColorsSheet: View {
    @ObservedObject var model: CalendarModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            CalendarColorsList(model: model)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}

/// One automatic, adjustable colour per subject; own events keep their own
/// colour. State is never shown by colour alone.
struct CalendarColorsList: View {
    @ObservedObject var model: CalendarModel

    var body: some View {
        List {
            Section {
                ForEach(model.subjects, id: \.key) { subject in
                    let name = CalendarSubjectColor.name(for: subject.key, chosen: model.subjectColors)
                    // Keys: ←/→ (or space) step through „Automatisch“ and the colours.
                    let choice = Binding<String>(get: { model.subjectColors[subject.key] ?? "" },
                                                 set: { model.setSubjectColor(subject.key, to: $0.isEmpty ? nil : $0) })
                    Menu {
                        CalendarColorPicker(key: subject.key, model: model)
                    } label: {
                        HStack {
                            Circle().fill(CalendarPalette.color(named: name)).frame(width: 12, height: 12)
                            Text(subject.name).foregroundStyle(.primary)
                            Spacer()
                            Text(model.subjectColors[subject.key] == nil ? "Automatisch · \(CalendarSubjectColor.title(name))" : CalendarSubjectColor.title(name))
                                .foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 44)
                    }
                    .keyOption(.choice(choice, [""] + CalendarSubjectColor.choosable))
                }
            } footer: {
                Text(model.subjects.isEmpty ? "Fächer erscheinen, sobald der Stundenplan aus WebUntis geladen ist."
                     : "Jedes Fach bekommt automatisch eine feste Farbe. Eigene Termine bleiben grün; Ausfall, Prüfung und Änderungen stehen zusätzlich als Symbol und Text.")
            }
        }
        .navigationTitle("Fachfarben")
    }
}
