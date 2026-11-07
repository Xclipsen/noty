// „Gesetzesbezug …“ im Heftmenü (docs/PARAGRAPH-LINKS.md, P2): Standardgesetz
// und Veranlagungsjahr dieses Hefts, als Geräteeinstellung (NotebookLawPreferences).
import SwiftUI
import NotebookCore

struct NotebookLawContextView: View {
    let documentID: UUID
    let title: String
    @ObservedObject private var preferences = NotebookLawPreferences.shared
    @ObservedObject private var catalog = LawSuggestionModel.shared
    @Environment(\.dismiss) private var dismiss

    private var context: NotebookLawContext { preferences.context(for: documentID) }
    private func change(_ edit: (inout NotebookLawContext) -> Void) {
        var next = context; edit(&next)
        preferences.set(next, for: documentID)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        LawChoiceList(selection: context.defaultLawID, entries: catalog.entries) { id in change { $0.defaultLawID = id } }
                    } label: {
                        LabeledContent("Standardgesetz", value: lawName(context.defaultLawID))
                    }
                } footer: {
                    Text("Ein bloßes „§ 35a“ ohne Gesetz verweist dann auf dieses Gesetz, wenn davor im selben Text kein anderes genannt ist. Beim Tippen wird es zuerst vorgeschlagen.")
                }
                Section {
                    Picker("Veranlagungsjahr", selection: Binding(get: { context.taxYear ?? 0 }, set: { year in change { $0.taxYear = year == 0 ? nil : year } })) {
                        Text("Keins").tag(0)
                        ForEach(years, id: \.self) { year in
                            Text(String(year)).tag(year)
                        }
                    }
                } footer: {
                    Text("Verweise in diesem Heft zeigen die Fassung, die in diesem Jahr galt, soweit sie auf dem iPad vorliegt.")
                }
                Section {
                    if !context.isEmpty {
                        Button("Gesetzesbezug entfernen", role: .destructive) { preferences.set(NotebookLawContext(), for: documentID) }
                    }
                } footer: {
                    Text("Gilt nur auf diesem iPad und nur für „\(title)“. Die Einstellung wird nicht im Heft gespeichert und ist deshalb nicht im Backup, im PDF oder im Abgleich mit anderen Apps enthalten.")
                }
            }
            .navigationTitle("Gesetzesbezug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
            }
        }
    }

    /// 2015 … next year, newest first; a stored year outside that range
    /// (accepted from 1990 to 2100) stays visible as its own entry.
    private var years: [Int] {
        var list = Array((NotebookLawPreferences.firstYear...NotebookLawPreferences.lastYear).reversed())
        if let stored = context.taxYear, !list.contains(stored) {
            list.append(stored); list.sort(by: >)
        }
        return list
    }

    private func lawName(_ id: String?) -> String {
        guard let id else { return "Keins" }
        return catalog.entry(id)?.abbr ?? id.uppercased()
    }
}

/// Searchable choice of a law: none, then laws, then administrative documents.
private struct LawChoiceList: View {
    let selection: String?
    let entries: [LawEntry]
    let choose: (String?) -> Void
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private func matches(_ entry: LawEntry) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return entry.abbr.localizedCaseInsensitiveContains(q) || entry.name.localizedCaseInsensitiveContains(q)
            || (entry.aliases ?? []).contains { $0.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        let laws = entries.filter { $0.kind != "administration" && matches($0) }
        let administrative = entries.filter { $0.kind == "administration" && matches($0) }
        List {
            if query.isEmpty {
                row(id: nil, abbr: "Keins", name: "Bloße Paragraphen bleiben ohne Gesetz")
            }
            if !laws.isEmpty {
                Section("Gesetze") { ForEach(laws) { row(id: $0.id, abbr: $0.abbr, name: $0.name) } }
            }
            if !administrative.isEmpty {
                Section("Verwaltungsvorschriften") { ForEach(administrative) { row(id: $0.id, abbr: $0.abbr, name: $0.name) } }
            }
            if entries.isEmpty {
                Text("Der Gesetzeskatalog ist noch nicht geladen.").foregroundStyle(.secondary)
            }
        }
        .searchable(text: $query, prompt: "Gesetz suchen")
        .navigationTitle("Standardgesetz")
    }

    private func row(id: String?, abbr: String, name: String) -> some View {
        Button {
            choose(id); dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(abbr).foregroundStyle(.primary)
                    Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if selection == id { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == id ? .isSelected : [])
    }
}
