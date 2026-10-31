import SwiftUI
import UniformTypeIdentifiers
import NotebookCore

/// Writing space next to an imported PDF: right by default, optionally also
/// left. Paper and colour start from the notebook's standard paper, so a lined
/// notebook gets lined writing space.
struct PDFWritingSpaceOptions: View {
    @Binding var enabled: Bool
    @Binding var left: Bool
    @Binding var fraction: Double
    @Binding var paper: PaperStyle
    @Binding var color: PaperColor
    var body: some View {
        Toggle("Schreibplatz rechts", isOn: $enabled)
        if enabled {
            Toggle("Zusätzlich links", isOn: $left)
            Picker("Breite", selection: $fraction) {
                Text("25 %").tag(0.25); Text("60 %").tag(0.6); Text("100 %").tag(1.0)
            }.pickerStyle(.segmented)
            HStack {
                Picker("Vorlage", selection: $paper) {
                    Text("Blanko").tag(PaperStyle.blank); Text("Liniert").tag(PaperStyle.lined); Text("Kariert").tag(PaperStyle.grid)
                }.pickerStyle(.segmented)
                Picker("Farbe", selection: $color) {
                    Text("Weiß").tag(PaperColor.white); Text("Dunkel").tag(PaperColor.dark)
                }.pickerStyle(.segmented).frame(maxWidth: 170)
            }
        }
    }
    static func margins(enabled: Bool, left: Bool, fraction: Double, paper: PaperStyle, color: PaperColor) -> PageMargins? {
        enabled ? PageMargins(left: left ? fraction : 0, right: fraction, style: paper, color: color) : nil
    }
}

/// Options are chosen before Files opens. Its temporary URL is handed directly
/// to the existing bounded local-copy importer while access is still available.
struct PDFImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var choosingFile = false
    @State private var extraSpace = true
    @State private var left = false
    @State private var fraction = 1.0
    @State private var paper: PaperStyle
    @State private var color: PaperColor
    let onImport: (URL, PageMargins?) -> Void
    let onError: (String) -> Void
    init(defaults: NotebookAppearance? = nil, onImport: @escaping (URL, PageMargins?) -> Void, onError: @escaping (String) -> Void) {
        _paper = State(initialValue: defaults?.paper ?? .blank)
        _color = State(initialValue: defaults?.color ?? .dark)
        self.onImport = onImport; self.onError = onError
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PDFWritingSpaceOptions(enabled: $extraSpace, left: $left, fraction: $fraction, paper: $paper, color: $color)
                } footer: {
                    Text("Die PDF wird vollständig lokal kopiert; das Original bleibt unverändert. 100 % entspricht einer normalen Seitenbreite.")
                }
                Section { Button("PDF aus Dateien wählen …", systemImage: "doc.badge.plus") { choosingFile = true } }
            }
            .navigationTitle("PDF importieren").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
            .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.pdf]) { result in
                switch result {
                case .success(let url):
                    onImport(url, PDFWritingSpaceOptions.margins(enabled: extraSpace, left: left, fraction: fraction, paper: paper, color: color))
                    dismiss()
                case .failure(let error): onError(error.localizedDescription)
                }
            }
        }.preferredColorScheme(.dark)
    }
}
