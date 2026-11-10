import SwiftUI
import NotebookCore

extension NotebookCover {
    /// The main colours follow Post-it tones (pink, orange, yellow, green,
    /// blue), so notebooks match the sticky notes of their subject.
    var color: Color {
        switch self {
        case .pink: Color(red: 0.98, green: 0.45, blue: 0.69)
        case .orange: Color(red: 1.0, green: 0.62, blue: 0.27)
        case .yellow: Color(red: 1.0, green: 0.87, blue: 0.36)
        case .green: Color(red: 0.60, green: 0.83, blue: 0.35)
        case .blue: Color(red: 0.35, green: 0.72, blue: 0.92)
        case .purple: Color(red: 0.64, green: 0.49, blue: 0.80)
        case .coral: Color(red: 0.86, green: 0.43, blue: 0.42)
        case .red: Color(red: 0.80, green: 0.21, blue: 0.23)
        case .teal: Color(red: 0.15, green: 0.58, blue: 0.58)
        case .navy: Color(red: 0.17, green: 0.27, blue: 0.52)
        case .brown: Color(red: 0.55, green: 0.38, blue: 0.25)
        case .gray: Color(white: 0.52)
        case .black: Color(white: 0.13)
        }
    }
    var title: String {
        switch self {
        case .pink: "Pink"; case .orange: "Orange"; case .yellow: "Gelb"; case .green: "Grün"; case .blue: "Blau"
        case .purple: "Lila"; case .coral: "Koralle"; case .red: "Rot"; case .teal: "Türkis"; case .navy: "Dunkelblau"
        case .brown: "Braun"; case .gray: "Grau"; case .black: "Schwarz"
        }
    }
    /// Light colours carry a dark checkmark.
    var markColor: Color { NotebookCover.main.contains(self) ? .black.opacity(0.7) : .white }
}

/// Cover colour choice: the five main colours (Post-it tones for the main
/// subjects) first, the further colours below. Shared by „Neues Heft“,
/// Settings › Papier für neue Hefte and „Umschlag ändern“.
struct NotebookCoverPicker: View {
    @Binding var cover: NotebookCover
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("Hauptfarben", NotebookCover.main, size: 44)
            row("Weitere Farben", NotebookCover.more, size: 34)
        }.keyOption(.choice($cover, NotebookCover.allCases))
    }
    private func row(_ title: String, _ covers: [NotebookCover], size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 14) {
                ForEach(covers, id: \.self) { item in
                    Button { cover = item } label: {
                        Circle().fill(item.color).frame(width: size, height: size)
                            .overlay(Circle().stroke(.white.opacity(0.15)))
                            .overlay { if cover == item { Image(systemName: "checkmark").foregroundStyle(item.markColor).bold() } }
                    }.buttonStyle(NotyPressStyle())
                        .accessibilityLabel("Umschlag \(item.title)")
                        .accessibilityAddTraits(cover == item ? .isSelected : [])
                }
            }
        }
    }
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
                NotebookCoverPicker(cover: $appearance.cover)
            }
            Text(paperHeading).font(.headline)
            if let fixedFormat {
                LabeledContent("Größe", value: "\(fixedFormat.title) (fest)")
            } else {
                Picker("Größe", selection: $appearance.format) {
                    ForEach(PaperFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).keyOption(.choice($appearance.format, PaperFormat.allCases))
            }
            Picker("Ausrichtung", selection: $appearance.landscape) {
                Label("Hochformat", systemImage: "rectangle.portrait").tag(false)
                Label("Querformat", systemImage: "rectangle").tag(true)
            }.pickerStyle(.segmented).keyOption(.toggle($appearance.landscape))
            Picker("Papier", selection: $appearance.paper) {
                Text("Blanko").tag(PaperStyle.blank); Text("Liniert").tag(PaperStyle.lined); Text("Kariert").tag(PaperStyle.grid)
            }.pickerStyle(.segmented).keyOption(.choice($appearance.paper, [.blank, .lined, .grid]))
            Picker("Papierfarbe", selection: $appearance.color) { Text("Weiß").tag(PaperColor.white); Text("Dunkel").tag(PaperColor.dark) }.pickerStyle(.segmented)
                .keyOption(.choice($appearance.color, [.white, .dark]))
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
                            .keyOption(.text($title))
                        // Near the limit the length shows, so a disabled „Erstellen“ has a visible reason.
                        let length = title.trimmingCharacters(in: .whitespacesAndNewlines).count
                        if let problem = NotyText.titleProblem(title), length <= 120 {
                            Text(problem).font(.caption).foregroundStyle(.orange)
                        } else if length > 100 {
                            Text(length > 120 ? "\(length)/120 Zeichen – bitte kürzen" : "\(length)/120 Zeichen")
                                .font(.caption).monospacedDigit()
                                .foregroundStyle(length > 120 ? Color.orange : Color.secondary)
                        }
                        if textDocument {
                            Text("Seiten entstehen beim Schreiben; am Ende steht immer eine leere Seite für Handschrift bereit. Handschrift bleibt fest auf ihrer Seite.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            keyToggle("Umschlag", isOn: $appearance.coverEnabled)
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
            DocumentCreationForm(kind: "Heft", title: $title, appearance: $appearance, textDocument: false)
            .navigationTitle("Neues Heft").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() }.disabled(creating) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Erstellen", action: create).disabled(!creatable)
                }
            }
            .disabled(creating)
        }.preferredColorScheme(.dark)
        .keyboardSheet(onDefault: { if creatable { create() } }, onCancel: { if !creating { dismiss() } })
    }
    private var creatable: Bool { !creating && (try? LibraryStore.validTitle(title)) != nil }
    private func create() {
        creating = true
        Task { if await onCreate(title, appearance) { dismiss() }; creating = false }
    }
}

/// Library „Umschlag ändern …“: cover on/off and colour of an existing
/// notebook. Paper and pages stay untouched.
struct NotebookCoverEditView: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @State private var appearance: NotebookAppearance
    @State private var saving = false
    private let initial: NotebookAppearance
    let onSave: (Bool, NotebookCover) async -> Bool
    init(title: String, current: NotebookAppearance, onSave: @escaping (Bool, NotebookCover) async -> Bool) {
        self.title = title; initial = current; self.onSave = onSave
        var start = current
        // A notebook without cover starts from the main colour picker, cover on.
        if !start.coverEnabled { start.coverEnabled = true }
        _appearance = State(initialValue: start)
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                HStack(alignment: .top, spacing: 24) {
                    NotebookCoverPreview(appearance: appearance).aspectRatio(appearance.landscape ? 1.41 : 0.71, contentMode: .fit)
                        .frame(maxWidth: appearance.landscape ? 200 : 150)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 18) {
                        keyToggle("Umschlag", isOn: $appearance.coverEnabled)
                        if appearance.coverEnabled {
                            NotebookCoverPicker(cover: $appearance.cover)
                        } else {
                            Text("Ohne Umschlag zeigt die Bibliothek die erste Seite.").font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Nur der Umschlag ändert sich; Seiten und Papier bleiben, wie sie sind.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(24)
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) { Button("Fertig", action: save).disabled(saving) }
            }
            .disabled(saving)
            .animation(.default, value: appearance.coverEnabled)
        }.preferredColorScheme(.dark)
        .keyboardSheet(onDefault: { if !saving { save() } }, onCancel: { if !saving { dismiss() } })
    }
    private func save() {
        guard appearance.coverEnabled != initial.coverEnabled || appearance.cover != initial.cover else { return dismiss() }
        saving = true
        Task { if await onSave(appearance.coverEnabled, appearance.cover) { dismiss() }; saving = false }
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
            DocumentCreationForm(kind: "Textdokument", title: $title, appearance: $appearance, textDocument: true)
            .navigationTitle("Neues Textdokument").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() }.disabled(creating) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Erstellen", action: create).disabled(!creatable)
                }
            }
            .disabled(creating)
        }.preferredColorScheme(.dark)
        .keyboardSheet(onDefault: { if creatable { create() } }, onCancel: { if !creating { dismiss() } })
    }
    private var creatable: Bool { !creating && (try? LibraryStore.validTitle(title)) != nil }
    private func create() {
        creating = true
        Task { if await onCreate(title, appearance.landscape, appearance.paper, appearance.color) { dismiss() }; creating = false }
    }
}
