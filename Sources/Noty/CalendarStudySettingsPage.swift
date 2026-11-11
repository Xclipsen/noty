import SwiftUI
import NotebookCore

/// Einstellungen › Kalender › Lernfelder (docs/LERNFELDER.md): the area's
/// Lernfelder and which lessons belong to them – a whole subject, or one
/// block of the timetable (weekday and time) that differs from it.
struct CalendarStudySettingsPage: View {
    @ObservedObject var model: CalendarModel
    @ObservedObject private var materials = MaterialLibrary.shared
    @State private var adding = false
    @State private var newNumber = ""
    @State private var newTitle = ""
    @State private var removing: CalendarStudyField?
    @State private var choosingNotebook: CalendarStudyField?

    var body: some View {
        Form {
            if !model.canWrite {
                Section { Label(model.storageError ?? "Der Kalender ist noch nicht geladen.", systemImage: "lock").foregroundStyle(.orange) }
            }
            fieldsSection
            if !model.studyFields.isEmpty { assignmentSection }
            if !model.subjectNotebooks.isEmpty { subjectsSection }
        }
        .navigationTitle("Lernfelder")
        .task { materials.load() }
        .alert("Lernfeld hinzufügen", isPresented: $adding) {
            TextField("Nummer, z. B. 3", text: $newNumber).keyboardType(.numberPad)
            TextField("Titel", text: $newTitle)
            Button("Hinzufügen") {
                let number = Int(newNumber.trimmingCharacters(in: .whitespaces)) ?? 0, title = newTitle
                Task { _ = await model.addField(number: number, title: title) }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: { Text("Nummer 1–99, noch nicht vergeben.") }
        .sheet(item: $choosingNotebook) { field in CalendarFieldNotebookPicker(field: field, model: model) }
        .confirmationDialog("Lernfeld entfernen?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { field in
            Button("\(field.displayName) entfernen", role: .destructive) { Task { await model.removeField(field.id) } }
        } message: { _ in
            Text("Die Zuordnungen dieses Lernfelds werden entfernt. Das Heft, seine Seiten, Themen und festgehaltenes Material bleiben erhalten.")
        }
    }

    // MARK: Fields

    private var fieldsSection: some View {
        Section {
            ForEach(model.studyFields) { field in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(field.displayName)
                        Text(notebookText(field)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Menu {
                        notebookActions(field)
                        Button("Entfernen", systemImage: "trash", role: .destructive) { removing = field }
                    } label: {
                        Image(systemName: "ellipsis.circle").imageScale(.large).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }
                    .accessibilityLabel("Heft und Aktionen für \(field.shortName)")
                }
                .swipeActions { Button("Entfernen", role: .destructive) { removing = field } }
                .contextMenu {
                    notebookActions(field)
                    Button("Entfernen", systemImage: "trash", role: .destructive) { removing = field }
                }
            }
            ForEach(materials.packages, id: \.catalog.id) { package in
                let missing = package.catalog.fields.filter { field in !model.studyFields.contains { $0.number == field.number } }
                if !missing.isEmpty {
                    Button {
                        Task { await model.importFields(from: package.catalog) }
                    } label: {
                        Label("\(missing.count) Lernfelder aus „\(package.catalog.title)“ übernehmen", systemImage: "square.and.arrow.down")
                    }
                }
            }
            Button { newNumber = ""; newTitle = ""; adding = true } label: { Label("Lernfeld hinzufügen …", systemImage: "plus") }
        } header: {
            Text("Lernfelder")
        } footer: {
            Text("Jedes Lernfeld bekommt ein eigenes Heft „LF n – Titel“, sobald die erste Stunde mitgeschrieben wird. Es liegt oben in der Bibliothek und lässt sich verschieben oder umbenennen. Über „…“ › „Heft wählen“ schreibt ein Lernfeld stattdessen in ein vorhandenes Heft der Bibliothek, neue Stunden kommen dort ans Ende.")
        }
        .disabled(!model.canWrite)
    }

    /// „Heft wählen …“ / „Anderes Heft wählen …“ and, with a notebook, letting it go.
    @ViewBuilder private func notebookActions(_ field: CalendarStudyField) -> some View {
        Button(field.notebookID == nil ? "Heft wählen …" : "Anderes Heft wählen …", systemImage: "book.closed") { choosingNotebook = field }
        if field.notebookID != nil {
            Button("Heft lösen", systemImage: "link.badge.minus") { Task { await model.setFieldNotebook(nil, for: field.id) } }
        }
    }

    // MARK: Fach-Hefte (format 6)

    private var subjectsSection: some View {
        Section {
            ForEach(model.subjectNotebooks) { subject in
                VStack(alignment: .leading, spacing: 2) {
                    Text(subject.subjectName)
                    Text(subjectNotebookText(subject)).font(.caption).foregroundStyle(.secondary)
                }
                .swipeActions { Button("Aufheben", role: .destructive) { Task { await model.removeSubjectNotebook(subject.id) } } }
                .contextMenu {
                    Button("Zuordnung aufheben", systemImage: "link.badge.minus", role: .destructive) { Task { await model.removeSubjectNotebook(subject.id) } }
                }
            }
        } header: {
            Text("Fach-Hefte")
        } footer: {
            Text("Stunden dieser Fächer schreiben in das gewählte Heft der Bibliothek: je Stunde eine neue Seite mit Überschrift, das Heft öffnet sich groß. Zugeordnet wird in der Stunde im Kalender („…“ › „Fach-Heft wählen“); ein Lernfeld hat Vorrang. Aufheben lässt Heft und bisherige Seiten unverändert.")
        }
        .disabled(!model.canWrite)
    }

    private func subjectNotebookText(_ subject: CalendarSubjectNotebook) -> String {
        guard let library = model.library, let item = library.snapshot.items.first(where: { $0.id == subject.notebookID }) else {
            return "Heft gibt es nicht mehr · beim nächsten Öffnen der Stunde neu wählen"
        }
        return library.snapshot.isTrashed(item.id) ? "Heft „\(item.title)“ liegt im Papierkorb" : "Heft „\(item.title)“"
    }

    private func notebookText(_ field: CalendarStudyField) -> String {
        guard let id = field.notebookID, let library = model.library,
              let item = library.snapshot.items.first(where: { $0.id == id }) else { return "Heft entsteht mit der ersten Mitschrift" }
        return library.snapshot.isTrashed(id) ? "Heft „\(item.title)“ liegt im Papierkorb" : "Heft „\(item.title)“"
    }

    // MARK: Assignment

    private var assignmentSection: some View {
        let slots = model.timetableSlots
        let subjects = Dictionary(grouping: slots, by: \.subjectKey)
        let keys = subjects.keys.sorted { (subjects[$0]?.first?.subjectName ?? $0) < (subjects[$1]?.first?.subjectName ?? $1) }
        return Section {
            if keys.isEmpty {
                Text("Noch kein Stundenplan geladen. Nach dem Verbinden mit WebUntis stehen hier die Fächer.")
                    .foregroundStyle(.secondary)
            }
            ForEach(keys, id: \.self) { key in
                let list = subjects[key] ?? []
                let name = list.first?.subjectName ?? key
                fieldPicker(name, selection: binding(subjectKey: key, name: name, weekday: nil, from: nil, to: nil))
                if list.count > 1 || model.state.studyRules.contains(where: { $0.subjectKey == key && $0.weekday != nil }) {
                    ForEach(list) { slot in
                        fieldPicker("   \(slot.label)", selection: binding(subjectKey: key, name: name, weekday: slot.weekday,
                                                                         from: slot.start, to: slot.end), inherit: true)
                            .font(.subheadline)
                    }
                }
            }
        } header: {
            Text("Zuordnung nach Stundenplan")
        } footer: {
            Text("Erst das ganze Fach, dann bei Bedarf einzelne Blöcke anders, z. B. „SR“ → LF 4 und „SR Mo 08:00–10:15“ → LF 3. Der genauere Eintrag gewinnt. Stunden ohne Lernfeld bekommen weiter eine eigene kleine Notiz.")
        }
        .disabled(!model.canWrite)
    }

    private func fieldPicker(_ title: String, selection: Binding<UUID?>, inherit: Bool = false) -> some View {
        Picker(title, selection: selection) {
            Text(inherit ? "wie das Fach" : "kein Lernfeld").tag(UUID?.none)
            ForEach(model.studyFields) { field in Text(field.shortName + " · " + field.title).tag(UUID?.some(field.id)) }
        }
    }

    private func binding(subjectKey: String, name: String, weekday: Int?, from: Int?, to: Int?) -> Binding<UUID?> {
        Binding(
            get: { model.rule(subjectKey: subjectKey, weekday: weekday, startFrom: from, startTo: to)?.fieldID },
            set: { field in
                Task { await model.setRule(subjectKey: subjectKey, subjectName: name, weekday: weekday, startFrom: from, startTo: to, field: field) }
            })
    }
}
