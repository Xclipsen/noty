import SwiftUI
import UniformTypeIdentifiers
import NotebookCore

/// Options are chosen before Files opens. Its temporary URL is handed directly
/// to the existing bounded local-copy importer while access is still available.
struct PDFImportSheet: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @State private var choosingFile = false
    @State private var extraSpace = false
    @State private var left = false
    @State private var right = true
    @State private var top = false
    @State private var bottom = false
    @State private var fraction = 0.6
    @State private var paper: PaperStyle = .blank
    @State private var color: PaperColor = .white
    let onImport: (URL, PageMargins?) -> Void
    let onError: (String) -> Void
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Gescannte Arbeitsblätter aus der Dateien-App importieren. Die PDF wird vollständig lokal kopiert.")
                    Toggle("Schreibplatz beim Import ergänzen", isOn: $extraSpace)
                }
                if extraSpace {
                    Section("Zusätzlicher Schreibplatz") {
                        Toggle("Links", isOn: $left); Toggle("Rechts", isOn: $right)
                        Toggle("Oben", isOn: $top); Toggle("Unten", isOn: $bottom)
                        Picker("Breite", selection: $fraction) {
                            Text("Schmal · 25 %").tag(0.25); Text("Mittel · 60 %").tag(0.6); Text("Breit · 100 %").tag(1.0)
                        }
                        Picker("Vorlage", selection: $paper) { Text("Blanko").tag(PaperStyle.blank); Text("Liniert").tag(PaperStyle.lined); Text("Kariert").tag(PaperStyle.grid) }
                        Picker("Farbe", selection: $color) { Text("Weiß").tag(PaperColor.white); Text("Dunkel").tag(PaperColor.dark) }
                        Text("Die PDF bleibt in Originalgröße. Schreibplatz lässt sich später im Seitenmenü ändern.").font(.caption)
                    }
                }
                Section { Button("PDF aus Dateien auswählen", systemImage: "doc.badge.plus") { choosingFile = true } }
            }
            .animation(NotyMotion.panel(reduceMotion), value: extraSpace)
            .navigationTitle("PDF importieren").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
            .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.pdf]) { result in
                switch result {
                case .success(let url):
                    let margins = extraSpace ? PageMargins(left: left ? fraction : 0, right: right ? fraction : 0,
                        top: top ? fraction : 0, bottom: bottom ? fraction : 0, style: paper, color: color) : nil
                    onImport(url, margins); dismiss()
                case .failure(let error): onError(error.localizedDescription)
                }
            }
        }.preferredColorScheme(.dark)
    }
}
