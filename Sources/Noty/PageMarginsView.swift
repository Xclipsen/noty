import SwiftUI
import PencilKit
import NotebookCore

struct PageMarginChange {
    let original: Notebook
    let updated: Notebook
    let removedStrokes: Int
    let archivedPages: Int
}

@MainActor
extension EditorModel {
    func prepareMarginChange(pageID: UUID, margins: PageMargins, wholeImport: Bool) throws -> PageMarginChange {
        guard writable, !mutationsPaused, !busy, let target = notebook.pages.first(where: { $0.id == pageID }),
              sourcePage(for: target) != nil || target.writingSpaceExtendsPaper else {
            throw PageOperationError.missingPage
        }
        try margins.validate()
        var candidate = try notebook.preparedForPageEditing()
        let assignments = try candidate.marginsByPage(margins, relativeTo: pageID, wholeImport: wholeImport)
        let targets = candidate.pages.filter { assignments[$0.id] != nil }
        for page in targets {
            guard let value = assignments[page.id] else { throw StorageError.invalidDocument }
            var resized = page; resized.margins = value.isEmpty ? nil : value
            let allowed = resized.textBounds.cgRect.insetBy(dx: -0.01, dy: -0.01)
            if page.effectiveTextBoxes.contains(where: { !allowed.contains($0.rect.cgRect) }) {
                throw NSError(domain: "noty", code: 3, userInfo: [NSLocalizedDescriptionKey:
                    "Ein Textfeld liegt im entfernten Schreibplatz. Bitte das Feld zuerst verschieben oder löschen; der Rand wurde nicht verändert."])
            }
            if (page.images ?? []).contains(where: { !$0.fits(in: resized.textBounds) }) {
                throw NSError(domain: "noty", code: 4, userInfo: [NSLocalizedDescriptionKey:
                    "Ein Bild liegt im entfernten Schreibplatz. Bitte das Bild zuerst entsperren und verschieben oder verkleinern; der Rand wurde nicht verändert."])
            }
            if (page.shapes ?? []).contains(where: { !resized.textBounds.contains($0.bounds, tolerance: 0.02) }) {
                throw NSError(domain: "noty", code: 5, userInfo: [NSLocalizedDescriptionKey:
                    "Eine Form liegt im entfernten Schreibplatz. Bitte zuerst verschieben oder verkleinern."])
            }
        }
        var trimmed: [UUID: Data] = [:]
        var removed = 0
        for page in targets where !page.drawing.isEmpty {
            let originalPage = notebook.pages.first { $0.id == page.id }!
            let source = sourcePage(for: originalPage)?.pageRef
            let old = try PageLayout(page: originalPage, source: source)
            guard let pageMargins = assignments[page.id] else { throw StorageError.invalidDocument }
            var resized = originalPage; resized.margins = pageMargins.isEmpty ? nil : pageMargins
            let proposed = try PageLayout(page: resized, source: source)
            let drawing = try PKDrawing(data: page.drawing)
            let keep = drawing.strokes.filter { stroke in
                let visible = stroke.renderBounds.intersection(old.canonicalInkBounds)
                return visible.isNull || visible.isEmpty || proposed.canonicalInkBounds.contains(visible)
            }
            let count = drawing.strokes.count - keep.count
            if count > 0 { trimmed[page.id] = PKDrawing(strokes: keep).dataRepresentation(); removed += count }
        }
        try candidate.applyMargins(assignments, trimmedDrawings: trimmed)
        return PageMarginChange(original: notebook, updated: candidate, removedStrokes: removed, archivedPages: trimmed.count)
    }

    func commitMarginChange(_ change: PageMarginChange) throws {
        guard writable, !mutationsPaused, !busy, notebook == change.original else {
            throw NSError(domain: "noty", code: 2, userInfo: [NSLocalizedDescriptionKey: "Die Seite wurde zwischenzeitlich geändert. Bitte den Schreibplatz erneut anwenden."])
        }
        // Structural installation goes through the same checked, monotone owner.
        try installMarginSnapshot(change.updated)
    }
}

struct PageMarginsView: View {
    @ObservedObject var model: EditorModel
    let pageID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var margins: PageMargins
    @State private var wholeImport = false
    @State private var pending: PageMarginChange?
    @State private var confirming = false
    @State private var error: String?
    @StateObject private var cache = PageThumbnailCache()

    init(model: EditorModel, pageID: UUID) {
        self.model = model; self.pageID = pageID
        let page = model.notebook.pages.first { $0.id == pageID }
        let size = page?.geometry?.displaySize ?? .a4
        // Paper grows by a full page width to the right by default, like the
        // PDF writing space; it always continues the sheet's own paper.
        let start: PageMargins = if let page, page.writingSpaceExtendsPaper {
            PageMargins(right: size.width, style: page.paper ?? .blank, color: page.paperColor ?? .white)
        } else { .normalPageBesidePDF(size) }
        _margins = State(initialValue: page?.margins ?? start)
    }
    /// Paper pages extend only right and down, in their own paper (seamless lines).
    private var extendsPaper: Bool { page?.writingSpaceExtendsPaper == true }

    private var page: Page? { model.notebook.pages.first { $0.id == pageID } }
    private var preview: Page? {
        guard var page else { return nil }; page.margins = margins.isEmpty ? nil : margins; return page
    }
    private var base: PageSize { page?.geometry?.displaySize ?? .a4 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let preview {
                        VStack(alignment: .leading, spacing: 12) {
                            PageThumbnail(page: preview, source: model.sourcePage(for: preview), cache: cache)
                                .frame(maxWidth: .infinity).frame(height: 250)
                                .clipped().allowsHitTesting(false)
                                .accessibilityLabel("Vorschau der Seite mit zusätzlichem Schreibplatz")
                            Text(extendsPaper
                                 ? "Die Seite wird nach rechts oder unten verlängert. Linien und Papierfarbe laufen nahtlos weiter, vorhandene Inhalte bleiben, wo sie sind."
                                 : "Die PDF behält ihre Größe und Farben. Die Seite wird um die gewählten Ränder erweitert.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text(extendsPaper ? "Zusätzlicher Platz" : "Schreibränder").font(.headline)
                        if !extendsPaper { edge("Links", value: $margins.left, dimension: base.width) }
                        edge("Rechts", value: $margins.right, dimension: base.width)
                        if !extendsPaper { edge("Oben", value: $margins.top, dimension: base.height) }
                        edge("Unten", value: $margins.bottom, dimension: base.height)
                    }
                    if !extendsPaper { marginPaper }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Anwenden auf").font(.headline)
                        Picker("Anwenden auf", selection: $wholeImport) {
                            Text("Aktuelle Seite").tag(false)
                            Text(extendsPaper ? "Alle Papierseiten" : "Dieser PDF-Import").tag(true)
                        }.pickerStyle(.segmented)
                        Text(extendsPaper
                             ? "100 % ist so breit bzw. hoch wie die Seite. „Alle Papierseiten“ erweitert jede vorhandene Papierseite um denselben Anteil; neue Seiten bleiben normal. Gelöschte Seiten bleiben unverändert."
                             : "100 % ist so breit wie das PDF-Blatt. Bei einheitlicher Anzeige entspricht das einer normalen Seitenbreite. Gelöschte Seiten bleiben unverändert.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 16))
                    .contentShape(Rectangle()).clipped()
                }
                .padding(20).frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .background(Color(white: 0.055))
            .navigationTitle("Schreibplatz")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Anwenden") {
                        do {
                            let change = try model.prepareMarginChange(pageID: pageID, margins: margins, wholeImport: wholeImport)
                            if change.removedStrokes > 0 { pending = change; confirming = true }
                            else { try model.commitMarginChange(change); dismiss() }
                        } catch { self.error = error.localizedDescription }
                    }.disabled(!model.writable || model.mutationsPaused || model.busy)
                }
            }
            .alert("Handschrift liegt im entfernten Rand", isPresented: $confirming) {
                Button("Abbrechen", role: .cancel) { pending = nil }
                Button("Sichern und verkleinern", role: .destructive) {
                    guard let pending else { return }
                    do { try model.commitMarginChange(pending); self.pending = nil; dismiss() }
                    catch { self.error = error.localizedDescription }
                }
            } message: {
                Text("\(pending?.removedStrokes ?? 0) betroffene Striche werden ganz entfernt. \(pending?.archivedPages ?? 0) vollständige Seitenstände mit dem bisherigen Schreibplatz bleiben im Seitenpapierkorb. Wiederherstellen setzt die bestehende Seite zurück und sichert ihren aktuellen Stand vorher im Papierkorb.")
            }
            .alert("Schreibplatz nicht geändert", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
        .preferredColorScheme(.dark)
    }

    /// Style and colour of the extra space beside a PDF (paper pages use their own).
    private var marginPaper: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Papier im zusätzlichen Platz").font(.headline)
            VStack(alignment: .leading, spacing: 16) {
                Text("Papierart").font(.subheadline)
                Picker("Papierart", selection: $margins.style) {
                    Text("Blanko").tag(PaperStyle.blank)
                    Text("Liniert").tag(PaperStyle.lined)
                    Text("Kariert").tag(PaperStyle.grid)
                }.pickerStyle(.segmented)
                Text("Papierfarbe").font(.subheadline)
                Picker("Papierfarbe", selection: $margins.color) {
                    Text("Weiß").tag(PaperColor.white)
                    Text("Dunkel").tag(PaperColor.dark)
                }.pickerStyle(.segmented)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 16))
            .contentShape(Rectangle()).clipped()
        }
    }

    private func edge(_ title: String, value: Binding<Double>, dimension: Double) -> some View {
        // Every control stays mounted when the edge is off. Changing one toggle
        // must not insert rows or move the hit regions of the other edges.
        let enabled = value.wrappedValue > 0
        let editable = model.writable && !model.mutationsPaused && !model.busy
        return VStack(alignment: .leading, spacing: 10) {
            Toggle(title, isOn: Binding(get: { value.wrappedValue > 0 },
                                       set: { value.wrappedValue = $0 ? dimension : 0 }))
                .toggleStyle(.switch)
                .frame(minHeight: 44)
                .disabled(!editable)
                .accessibilityIdentifier("margin.\(title).toggle")
            Slider(value: value, in: 0...max(1, max(dimension, value.wrappedValue)))
                .frame(height: 32)
                .disabled(!enabled || !editable)
                .accessibilityLabel("Breite \(title)")
            HStack(spacing: 8) {
                ForEach(Array(zip(["Schmal", "Mittel", "Breit"], [0.25, 0.6, 1.0])), id: \.0) { label, fraction in
                    Button(label) { value.wrappedValue = dimension * fraction }
                        .buttonStyle(.bordered)
                        .disabled(!enabled || !editable)
                        .accessibilityLabel("\(title) \(label)")
                }
                Spacer(minLength: 0)
                Text("\(Int((value.wrappedValue / dimension * 100).rounded())) %")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }.frame(minHeight: 40)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 16))
        .contentShape(Rectangle()).clipped()
    }
}
