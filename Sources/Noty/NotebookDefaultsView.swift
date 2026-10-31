import SwiftUI
import NotebookCore

/// Change an existing notebook's standard paper afterwards, e.g. make every new
/// page dark – optionally converting empty pages or the whole notebook.
struct NotebookDefaultsView: View {
    let onApply: (PaperStyle, PaperColor, PageDefaultsScope) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var paper: PaperStyle
    @State private var color: PaperColor
    @State private var scope: PageDefaultsScope = .emptyPages

    /// `current`: the notebook's present standard page (`Notebook.pageDefaults`).
    /// Starts from it directly instead of a later onAppear write, so the sheet
    /// never first shows (or applies) Blanko/Weiß.
    init(current: NotebookAppearance, onApply: @escaping (PaperStyle, PaperColor, PageDefaultsScope) -> Void) {
        self.onApply = onApply
        _paper = State(initialValue: current.paper == .legacyTest ? .blank : current.paper)
        _color = State(initialValue: current.color)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Papier", selection: $paper) {
                        Text("Blanko").tag(PaperStyle.blank)
                        Text("Liniert").tag(PaperStyle.lined)
                        Text("Kariert").tag(PaperStyle.grid)
                    }.pickerStyle(.segmented)
                    Picker("Papierfarbe", selection: $color) {
                        Text("Weiß").tag(PaperColor.white)
                        Text("Dunkel").tag(PaperColor.dark)
                    }.pickerStyle(.segmented)
                } header: { Text("Neue Seiten") } footer: {
                    Text("Gilt für jede neue Papierseite und die leere Seite am Ende des Hefts.")
                }
                Section {
                    Picker("Bestehende Seiten", selection: $scope) {
                        Text("Nur neue Seiten").tag(PageDefaultsScope.newPagesOnly)
                        Text("Leere Papierseiten").tag(PageDefaultsScope.emptyPages)
                        Text("Ganzes Heft umstellen").tag(PageDefaultsScope.wholeNotebook)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: { Text("Bestehende Seiten") } footer: { Text(footer) }
            }
            .navigationTitle("Papier für neue Seiten")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Übernehmen") { onApply(paper, color, scope); dismiss() }
                }
            }
        }.preferredColorScheme(.dark)
    }

    private var footer: String {
        switch scope {
        case .newPagesOnly:
            "Bestehende Seiten und PDFs bleiben unverändert."
        case .emptyPages:
            "Unbeschriebene Papierseiten erhalten Papier und Farbe. Beschriebene Seiten und PDFs bleiben unverändert."
        case .wholeNotebook:
            "Alle Papierseiten erhalten Papier und Farbe, auch beschriebene; bei Liniert/Kariert ändert sich nur der Hintergrund. "
                + "Wechselt die Farbe, wird schwarze und fast schwarze Handschrift, Schrift und Form weiß – und umgekehrt. "
                + "Andere Farben wie Rot, Blau oder Textmarker sowie Bilder bleiben. "
                + "PDF-Scans und alles darauf bleiben unverändert; der Schreibraum neben PDFs wechselt die Farbe mit, "
                + "umgefärbt wird dort nur, was vollständig im Schreibraum liegt. "
                + "„Rückgängig“ nimmt die Umstellung vollständig zurück; der vorherige Stand bleibt außerdem über „Lokale Wiederherstellungspunkte“ erreichbar."
        }
    }
}
