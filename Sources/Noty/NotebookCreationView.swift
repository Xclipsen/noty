import SwiftUI
import NotebookCore

extension NotebookCover {
    var color: Color {
        switch self {
        case .blue: Color(red: 0.25, green: 0.55, blue: 0.82)
        case .purple: Color(red: 0.64, green: 0.49, blue: 0.80)
        case .green: Color(red: 0.24, green: 0.68, blue: 0.53)
        case .yellow: Color(red: 0.92, green: 0.77, blue: 0.30)
        case .coral: Color(red: 0.86, green: 0.43, blue: 0.42)
        case .gray: Color(white: 0.52)
        }
    }
    var title: String { switch self { case .blue: "Blau"; case .purple: "Lila"; case .green: "Grün"; case .yellow: "Gelb"; case .coral: "Koralle"; case .gray: "Grau" } }
}
extension PaperStyle {
    var title: String { switch self { case .blank: "Blanko"; case .lined: "Liniert"; case .grid: "Kariert"; case .legacyTest: "Schreibprobe" } }
}
extension PaperFormat {
    var title: String { rawValue == "letter" ? "US Letter" : rawValue.uppercased() }
}

struct NotebookCoverPreview: View {
    let appearance: NotebookAppearance
    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(appearance.coverEnabled ? appearance.cover.color : (appearance.color == .dark ? Color(white: 0.14) : .white))
            .overlay(alignment: .trailing) {
                if appearance.coverEnabled {
                    Rectangle().fill(.black.opacity(0.12)).frame(width: 13).padding(.trailing, 18)
                }
            }
            .overlay(alignment: .leading) {
                if appearance.coverEnabled { Rectangle().fill(.white.opacity(0.2)).frame(width: 5).padding(.leading, 8) }
            }
            .overlay {
                if !appearance.coverEnabled {
                    Image(systemName: appearance.paper == .grid ? "square.grid.3x3" : appearance.paper == .lined ? "line.3.horizontal" : "doc")
                        .font(.largeTitle).foregroundStyle(appearance.color == .dark ? .white.opacity(0.35) : .black.opacity(0.18))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.12)))
    }
}

/// Cover and paper pickers, shared by notebook creation and Settings › Papier-Standards.
struct NotebookAppearanceEditor: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var appearance: NotebookAppearance
    var paperHeading = "Papierstandard für dieses Notizbuch"
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if appearance.coverEnabled {
                Text("Umschlagfarbe").font(.headline)
                HStack(spacing: 16) {
                    ForEach(NotebookCover.allCases, id: \.self) { cover in
                        Button { appearance.cover = cover } label: {
                            Circle().fill(cover.color).frame(width: 38, height: 38)
                                .overlay { if appearance.cover == cover { Image(systemName: "checkmark").foregroundStyle(.white).bold() } }
                        }.buttonStyle(NotyPressStyle())
                            .accessibilityLabel("Umschlag \(cover.title)")
                            .accessibilityAddTraits(appearance.cover == cover ? .isSelected : [])
                    }
                }
            }
            Text(paperHeading).font(.headline)
            Picker("Größe", selection: $appearance.format) {
                ForEach(PaperFormat.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            Toggle("Querformat", isOn: $appearance.landscape)
            Picker("Papierfarbe", selection: $appearance.color) { Text("Weiß").tag(PaperColor.white); Text("Dunkel").tag(PaperColor.dark) }.pickerStyle(.segmented)
            Picker("Vorlage", selection: $appearance.paper) {
                Text("Blanko").tag(PaperStyle.blank); Text("Liniert").tag(PaperStyle.lined); Text("Kariert").tag(PaperStyle.grid)
            }.pickerStyle(.segmented)
            Text("Neue Papierseiten übernehmen diese Vorgaben. Importierte PDFs behalten ihr Originalformat.").font(.caption).foregroundStyle(.secondary)
        }
        .animation(NotyMotion.panel(reduceMotion), value: appearance.coverEnabled)
        .animation(NotyMotion.highlight(reduceMotion), value: appearance.cover)
        .animation(NotyMotion.highlight(reduceMotion), value: appearance.color)
    }
}

struct NotebookCreationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var appearance: NotebookAppearance
    @State private var creating = false
    let onCreate: (String, NotebookAppearance) async -> Bool
    /// Starts from the area's paper default (Settings › Papier-Standards), if any.
    init(defaultAppearance: NotebookAppearance? = nil, onCreate: @escaping (String, NotebookAppearance) async -> Bool) {
        _appearance = State(initialValue: defaultAppearance ?? NotebookAppearance())
        self.onCreate = onCreate
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top, spacing: 24) {
                        NotebookCoverPreview(appearance: appearance).aspectRatio(0.71, contentMode: .fit).frame(maxWidth: 170)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 18) {
                            TextField("Titel des Notizbuchs", text: $title).font(.title3).textFieldStyle(.roundedBorder)
                            Toggle("Umschlag", isOn: $appearance.coverEnabled)
                            Text("Der Umschlag erscheint in der Bibliothek und zählt nicht als Seite.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    NotebookAppearanceEditor(appearance: $appearance)
                }.padding(24)
            }
            .navigationTitle("Neues Notizbuch").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() }.disabled(creating) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Erstellen") {
                        creating = true
                        Task { if await onCreate(title, appearance) { dismiss() }; creating = false }
                    }.disabled(creating || (try? LibraryStore.validTitle(title)) == nil)
                }
            }
            .disabled(creating)
        }.preferredColorScheme(.dark)
    }
}

extension NotebookCore.LibraryItem {
    /// Library symbol: folder, notebook (Heft) or text document.
    func librarySymbol(filled: Bool) -> String {
        let name = isFolder ? "folder" : isTextDocument ? "doc.text" : "book.closed"
        return filled ? name + ".fill" : name
    }
    var libraryKindName: String { isFolder ? "Ordner" : isTextDocument ? "Textdokument" : "Notizbuch" }
}

/// „Neu › Textdokument“ (TEXT-REBUILD-62 §4): title, A4 portrait or
/// landscape, paper blank (default), lined or grid, white or dark like a
/// notebook (automatic text and ink colours turn light on dark paper).
/// Pages come from the text.
struct TextDocumentCreationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var landscape = false
    @State private var paper: PaperStyle = .blank
    @State private var color: PaperColor = .white
    @State private var creating = false
    let onCreate: (String, Bool, PaperStyle, PaperColor) async -> Bool
    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("Titel des Textdokuments", text: $title) }
                Section("Seite (A4)") {
                    Picker("Ausrichtung", selection: $landscape) {
                        Label("Hochformat", systemImage: "rectangle.portrait").tag(false)
                        Label("Querformat", systemImage: "rectangle").tag(true)
                    }.pickerStyle(.segmented)
                    Picker("Papier", selection: $paper) {
                        Text("Blanko").tag(PaperStyle.blank); Text("Liniert").tag(PaperStyle.lined); Text("Kariert").tag(PaperStyle.grid)
                    }.pickerStyle(.segmented)
                    Picker("Papierfarbe", selection: $color) { Text("Weiß").tag(PaperColor.white); Text("Dunkel").tag(PaperColor.dark) }
                        .pickerStyle(.segmented)
                }
                Section {
                    Text("Seiten entstehen beim Schreiben; am Ende steht immer eine leere Seite für Handschrift bereit. Handschrift bleibt fest auf ihrer Seite.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Neues Textdokument").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() }.disabled(creating) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Erstellen") {
                        creating = true
                        Task { if await onCreate(title, landscape, paper, color) { dismiss() }; creating = false }
                    }.disabled(creating || (try? LibraryStore.validTitle(title)) == nil)
                }
            }
            .disabled(creating)
        }.preferredColorScheme(.dark)
    }
}
