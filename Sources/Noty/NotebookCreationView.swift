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

/// Paper pickers in one order for every place (Build 65): Größe › Ausrichtung
/// › Papier › Papierfarbe. Shared by „Neues Heft“, „Neues Textdokument“ and
/// Settings › Papier für neue Hefte. A text document has a fixed A4 size.
struct NotebookAppearanceEditor: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var appearance: NotebookAppearance
    var paperHeading = "Papier für neue Seiten"
    /// Text documents: size fixed, no cover colour.
    var fixedFormat: PaperFormat? = nil
    var note = "Neue Papierseiten übernehmen diese Vorgaben. Importierte PDFs behalten ihr Originalformat."
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if appearance.coverEnabled && fixedFormat == nil {
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
            if let fixedFormat {
                LabeledContent("Größe", value: "\(fixedFormat.title) (fest)")
            } else {
                Picker("Größe", selection: $appearance.format) {
                    ForEach(PaperFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
            }
            Picker("Ausrichtung", selection: $appearance.landscape) {
                Label("Hochformat", systemImage: "rectangle.portrait").tag(false)
                Label("Querformat", systemImage: "rectangle").tag(true)
            }.pickerStyle(.segmented)
            Picker("Papier", selection: $appearance.paper) {
                Text("Blanko").tag(PaperStyle.blank); Text("Liniert").tag(PaperStyle.lined); Text("Kariert").tag(PaperStyle.grid)
            }.pickerStyle(.segmented)
            Picker("Papierfarbe", selection: $appearance.color) { Text("Weiß").tag(PaperColor.white); Text("Dunkel").tag(PaperColor.dark) }.pickerStyle(.segmented)
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
        .animation(NotyMotion.panel(reduceMotion), value: appearance.coverEnabled)
        .animation(NotyMotion.highlight(reduceMotion), value: appearance.cover)
        .animation(NotyMotion.highlight(reduceMotion), value: appearance.color)
    }
}

/// One layout for „Neues Heft“ and „Neues Textdokument“: preview, title (and
/// for a Heft the cover), then the shared paper pickers.
private struct DocumentCreationForm: View {
    let kind: String
    @Binding var title: String
    @Binding var appearance: NotebookAppearance
    let textDocument: Bool
    let onSubmit: () -> Void
    @FocusState private var titleFocused: Bool
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 24) {
                    NotebookCoverPreview(appearance: appearance).aspectRatio(appearance.landscape ? 1.41 : 0.71, contentMode: .fit)
                        .frame(maxWidth: appearance.landscape ? 220 : 170)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 18) {
                        TextField("Titel", text: $title).font(.title3).textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Titel \(kind == "Heft" ? "des Hefts" : "des Textdokuments")")
                            .focused($titleFocused).onSubmit(onSubmit)
                        if textDocument {
                            Text("Seiten entstehen beim Schreiben; am Ende steht immer eine leere Seite für Handschrift bereit. Handschrift bleibt fest auf ihrer Seite.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Toggle("Umschlag", isOn: $appearance.coverEnabled)
                            Text("Der Umschlag erscheint in der Bibliothek und zählt nicht als Seite.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if textDocument {
                    NotebookAppearanceEditor(appearance: $appearance, paperHeading: "Seite", fixedFormat: .a4,
                                             note: "Gilt für alle Seiten des Textdokuments.")
                } else {
                    NotebookAppearanceEditor(appearance: $appearance)
                }
            }.padding(24)
        }
        // With a hardware keyboard the sheet goes on by keys alone; a field
        // focused during the presentation would not take.
        .task {
            guard KeyboardRouter.shared.keyboardSeen, (try? await Task.sleep(for: .milliseconds(450))) != nil else { return }
            titleFocused = true
        }
    }
}

struct NotebookCreationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var appearance: NotebookAppearance
    @State private var creating = false
    let onCreate: (String, NotebookAppearance) async -> Bool
    /// Starts from the area's paper default (Settings › Papier für neue Hefte), if any.
    init(defaultAppearance: NotebookAppearance? = nil, onCreate: @escaping (String, NotebookAppearance) async -> Bool) {
        _appearance = State(initialValue: defaultAppearance ?? NotebookAppearance())
        self.onCreate = onCreate
    }
    var body: some View {
        NavigationStack {
            DocumentCreationForm(kind: "Heft", title: $title, appearance: $appearance, textDocument: false, onSubmit: create)
            .navigationTitle("Neues Heft").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction).disabled(creating) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Erstellen", action: create).keyboardShortcut(.defaultAction)
                        .disabled(creating || (try? LibraryStore.validTitle(title)) == nil)
                }
            }
            .disabled(creating)
        }.preferredColorScheme(.dark)
    }
    /// Enter reaches this from the field as well as from the button.
    private func create() {
        guard !creating, (try? LibraryStore.validTitle(title)) != nil else { return }
        creating = true
        Task { if await onCreate(title, appearance) { dismiss() }; creating = false }
    }
}

extension NotebookCore.LibraryItem {
    /// Library symbol: folder, notebook (Heft) or text document.
    func librarySymbol(filled: Bool) -> String {
        let name = isFolder ? "folder" : isTextDocument ? "doc.text" : "book.closed"
        return filled ? name + ".fill" : name
    }
    var libraryKindName: String { isFolder ? "Ordner" : isTextDocument ? "Textdokument" : "Heft" }
}

/// „Neu › Textdokument“ (TEXT-REBUILD-62 §4), built like „Neues Heft“
/// (Build 65): A4 fixed, orientation, paper and paper colour start from the
/// area's paper default (Settings › Papier für neue Hefte); without one the
/// paper is blank. Pages come from the text.
struct TextDocumentCreationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var appearance: NotebookAppearance
    @State private var creating = false
    let onCreate: (String, Bool, PaperStyle, PaperColor) async -> Bool
    init(defaultAppearance: NotebookAppearance? = nil, onCreate: @escaping (String, Bool, PaperStyle, PaperColor) async -> Bool) {
        var start = NotebookAppearance()
        start.coverEnabled = false; start.format = .a4
        if let defaultAppearance {
            start.landscape = defaultAppearance.landscape; start.paper = defaultAppearance.paper; start.color = defaultAppearance.color
        }
        _appearance = State(initialValue: start)
        self.onCreate = onCreate
    }
    var body: some View {
        NavigationStack {
            DocumentCreationForm(kind: "Textdokument", title: $title, appearance: $appearance, textDocument: true, onSubmit: create)
            .navigationTitle("Neues Textdokument").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction).disabled(creating) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Erstellen", action: create).keyboardShortcut(.defaultAction)
                        .disabled(creating || (try? LibraryStore.validTitle(title)) == nil)
                }
            }
            .disabled(creating)
        }.preferredColorScheme(.dark)
    }
    private func create() {
        guard !creating, (try? LibraryStore.validTitle(title)) != nil else { return }
        creating = true
        Task { if await onCreate(title, appearance.landscape, appearance.paper, appearance.color) { dismiss() }; creating = false }
    }
}
