import SwiftUI
import NotebookCore

/// „Fachfarben“: one automatic, adjustable colour per subject; own events
/// keep their own colour. State is never shown by colour alone.
struct CalendarColorsSheet: View {
    @ObservedObject var model: CalendarModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.subjects, id: \.key) { subject in
                        let name = CalendarSubjectColor.name(for: subject.key, chosen: model.subjectColors)
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
                    }
                } footer: {
                    Text(model.subjects.isEmpty ? "Fächer erscheinen, sobald der Stundenplan aus WebUntis geladen ist."
                         : "Jedes Fach bekommt automatisch eine feste Farbe. Eigene Termine bleiben grün; Ausfall, Prüfung und Änderungen stehen zusätzlich als Symbol und Text.")
                }
            }
            .navigationTitle("Fachfarben")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}
