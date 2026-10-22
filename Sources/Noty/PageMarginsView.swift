import SwiftUI
import PencilKit
import NotebookCore

struct PageMarginChange {
    let original: Notebook
    let updated: Notebook
    let removedStrokes: Int
    let archivedPages: Int
    /// A paper colour flip recoloured ink: native canvases reload.
    var resetsEditor = false
}

@MainActor
extension EditorModel {
    /// `paper`: the paper page's own style/colour („Papier dieser Seite“).
    func prepareMarginChange(pageID: UUID, margins: PageMargins, wholeImport: Bool,
                             paper: (style: PaperStyle, color: PaperColor)? = nil) throws -> PageMarginChange {
        guard writable, !mutationsPaused, !busy, let target = notebook.pages.first(where: { $0.id == pageID }),
              sourcePage(for: target) != nil || target.writingSpaceExtendsPaper else {
            throw PageOperationError.missingPage
        }
        try margins.validate()
        var candidate = try notebook.preparedForPageEditing()
        var recoloured = false
        if let paper, target.writingSpaceExtendsPaper, paper.style != target.paper || paper.color != (target.paperColor ?? .white) {
            recoloured = paper.color != (target.paperColor ?? .white)
            try candidate.setPaper(paper.style, color: paper.color, pageID: pageID, recolorDrawing: inkRecolorStep)
        }
        let assignments = try candidate.marginsByPage(margins, relativeTo: pageID, wholeImport: wholeImport)
        let targets = candidate.pages.filter { assignments[$0.id] != nil }
        for page in targets {
            guard let value = assignments[page.id] else { throw StorageError.invalidDocument }
            var resized = page; resized.margins = value.isEmpty ? nil : value
            let allowed = resized.textBounds.cgRect.insetBy(dx: -0.01, dy: -0.01)
            if page.effectiveTextBoxes.contains(where: { !$0.fits(in: PageRect(allowed)) }) {
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
        // Paper pages only shrink up to their content (the sheet enforces it for
        // this page): nothing beside paper is ever cut, also for „Alle Papierseiten“.
        if removed > 0, target.writingSpaceExtendsPaper {
            throw NSError(domain: "noty", code: 6, userInfo: [NSLocalizedDescriptionKey:
                "Auf einer Papierseite liegt Handschrift im Bereich, der wegfallen würde. Es wird nichts gelöscht; bitte den Platz dort größer lassen."])
        }
        try candidate.applyMargins(assignments, trimmedDrawings: trimmed)
        // Native canvases reload only when handwriting was actually recoloured.
        return PageMarginChange(original: notebook, updated: candidate, removedStrokes: removed, archivedPages: trimmed.count,
                                resetsEditor: recoloured && !target.drawing.isEmpty)
    }

    func commitMarginChange(_ change: PageMarginChange) throws {
        guard writable, !mutationsPaused, !busy, notebook == change.original else {
            throw NSError(domain: "noty", code: 2, userInfo: [NSLocalizedDescriptionKey: "Die Seite wurde zwischenzeitlich geändert. Bitte den Schreibplatz erneut anwenden."])
        }
        // Structural installation goes through the same checked, monotone owner.
        try installMarginSnapshot(change.updated, resetEditor: change.resetsEditor)
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
    /// Paper pages: own paper and how far the writing space may shrink.
    @State private var paperStyle: PaperStyle
    @State private var paperColor: PaperColor
    @State private var minimum: PageSize
    /// Sharp render of the page as stored (with the chosen paper); the extra
    /// space around it is drawn live, so sliders respond without re-rendering.
    @State private var pageImage: UIImage?
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
        _paperStyle = State(initialValue: page?.paper ?? .blank)
        _paperColor = State(initialValue: page?.paperColor ?? .white)
        _minimum = State(initialValue: page.map { Self.contentOverhang(of: $0, base: size) } ?? PageSize(width: 0, height: 0))
    }
    /// Paper pages extend only right and down, in their own paper (seamless lines).
    private var extendsPaper: Bool { page?.writingSpaceExtendsPaper == true }

    private var page: Page? { model.notebook.pages.first { $0.id == pageID } }
    private var preview: Page? {
        guard var page else { return nil }
        if extendsPaper {
            page.paper = paperStyle; page.paperColor = paperColor
            var extra = margins; extra.style = paperStyle; extra.color = paperColor
            page.margins = extra.isEmpty ? nil : extra
        } else { page.margins = margins.isEmpty ? nil : margins }
        return page
    }
    private var base: PageSize { page?.geometry?.displaySize ?? .a4 }
    private var editable: Bool { model.writable && !model.mutationsPaused && !model.busy }

    var body: some View {
        NavigationStack {
            ScrollView {
                Group { if extendsPaper { paperContent } else { pdfContent } }
                    .padding(20).frame(maxWidth: 680)
                    .frame(maxWidth: .infinity)
            }
            .background(Color(white: 0.055))
            .navigationTitle(extendsPaper ? "Seite anpassen" : "Schreibplatz")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Anwenden") {
                        do {
                            let change = try model.prepareMarginChange(pageID: pageID, margins: margins, wholeImport: wholeImport,
                                                                       paper: extendsPaper ? (paperStyle, paperColor) : nil)
                            if change.removedStrokes > 0 { pending = change; confirming = true }
                            else { try model.commitMarginChange(change); dismiss() }
                        } catch { self.error = error.localizedDescription }
                    }.fontWeight(.semibold).disabled(!editable)
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
            .alert(extendsPaper ? "Seite nicht geändert" : "Schreibplatz nicht geändert", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Paper page („Seite anpassen“)

    private var paperContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let preview {
                paperPreview(preview)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Mehr Platz").font(.headline)
                VStack(spacing: 0) {
                    growthRow("Rechts verlängern", value: $margins.right, dimension: base.width, minimum: minimum.width, standard: 1)
                    Divider().padding(.vertical, 6)
                    growthRow("Unten verlängern", value: $margins.bottom, dimension: base.height, minimum: minimum.height, standard: 0.5)
                    Divider().padding(.vertical, 6)
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Gilt für", selection: $wholeImport) {
                            Text("Diese Seite").tag(false)
                            Text("Alle Papierseiten").tag(true)
                        }.pickerStyle(.segmented).disabled(!editable)
                        Text(wholeImport
                             ? "Jede vorhandene Papierseite wächst um denselben Anteil ihrer Größe. Neue Seiten bleiben normal, gelöschte unverändert."
                             : "Linien und Papierfarbe laufen nahtlos weiter. Kürzer geht nur bis zum Inhalt, es wird nie etwas gelöscht.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .notySheetCard()
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Papier dieser Seite").font(.headline)
                VStack(alignment: .leading, spacing: 14) {
                    LabeledContent("Vorlage") {
                        Picker("Vorlage", selection: $paperStyle) {
                            Text("Blanko").tag(PaperStyle.blank)
                            Text("Liniert").tag(PaperStyle.lined)
                            Text("Kariert").tag(PaperStyle.grid)
                        }.pickerStyle(.segmented).frame(maxWidth: 300)
                    }
                    LabeledContent("Farbe") {
                        Picker("Farbe", selection: $paperColor) {
                            Text("Weiß").tag(PaperColor.white)
                            Text("Dunkel").tag(PaperColor.dark)
                        }.pickerStyle(.segmented).frame(maxWidth: 200)
                    }
                    if paperColor != (page?.paperColor ?? .white) {
                        Text("Schwarze und weiße Schrift wird passend getauscht, farbige bleibt.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(!editable)
                .notySheetCard()
            }
        }
    }

    /// Live preview: the stored page is rendered once (sharp); paper, lines and
    /// the accent outline of the added space follow the sliders immediately.
    private func paperPreview(_ preview: Page) -> some View {
        let canvas = PageSize(width: base.width + margins.right, height: base.height + margins.bottom)
        let stored = PageSize(width: base.width + (page?.margins?.right ?? 0), height: base.height + (page?.margins?.bottom ?? 0))
        return Canvas { context, size in
            let k = size.width / canvas.width
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(paperColor == .dark ? .black : .white))
            context.stroke(Self.ruling(paperStyle, size: size, scale: k),
                           with: .color(Color(white: paperColor == .dark ? 0.3 : 0.8)), lineWidth: max(0.5, 0.5 * k))
            if let pageImage {
                context.draw(Image(uiImage: pageImage), in: CGRect(x: 0, y: 0, width: stored.width * k, height: stored.height * k))
            }
            let dash = StrokeStyle(lineWidth: 1.2, dash: [5, 4])
            for added in [CGRect(x: base.width * k, y: 0, width: margins.right * k, height: size.height),
                          CGRect(x: 0, y: base.height * k, width: base.width * k, height: margins.bottom * k)]
            where added.width > 0.5 && added.height > 0.5 {
                context.fill(Path(roundedRect: added, cornerRadius: 2), with: .color(Color.accentColor.opacity(0.12)))
                context.stroke(Path(roundedRect: added.insetBy(dx: 0.6, dy: 0.6), cornerRadius: 2), with: .color(Color.accentColor.opacity(0.9)), style: dash)
            }
        }
            .aspectRatio(canvas.width / canvas.height, contentMode: .fit)
            .task(id: "\(paperStyle.rawValue)-\(paperColor.rawValue)") {
                guard let rendered = convertedPage() else { return }
                pageImage = try? await PageThumbnailCache.render(rendered, source: .none, longestSide: 900)
            }
            .frame(maxWidth: .infinity).frame(height: 240)
            .padding(16)
            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .allowsHitTesting(false)
            .accessibilityElement().accessibilityLabel("Vorschau der Seite mit zusätzlichem Platz")
    }

    /// The stored page with the chosen paper, converted exactly like applying
    /// it (`Notebook.setPaper` with the app's ink step): on a colour flip the
    /// neutral ink, text and shapes swap too, so dark paper never previews
    /// black writing.
    private func convertedPage() -> Page? {
        guard var page else { return nil }
        var candidate = model.notebook
        if (try? candidate.setPaper(paperStyle, color: paperColor, pageID: pageID, recolorDrawing: model.inkRecolorStep)) != nil,
           let converted = candidate.pages.first(where: { $0.id == pageID }) { return converted }
        page.paper = paperStyle; page.paperColor = paperColor
        if var extra = page.margins { extra.style = paperStyle; extra.color = paperColor; page.margins = extra }
        return page
    }

    /// Same lines as `PDFExporter.drawPaper` for a paper page (one sheet,
    /// 32-pt side inset), scaled to the preview.
    private static func ruling(_ style: PaperStyle, size: CGSize, scale k: CGFloat) -> Path {
        var path = Path()
        guard style == .lined || style == .grid else { return path }
        let spacing = (style == .lined ? PaperRuling.spacing : 16) * k
        let bottom = size.height - (style == .lined ? 16 : 40) * k
        let from = 32 * k, to = size.width - 32 * k
        guard spacing > 0.5, to > from else { return path }
        for y in stride(from: PaperRuling.firstBaseline * k, through: bottom, by: spacing) {
            path.move(to: CGPoint(x: from, y: y)); path.addLine(to: CGPoint(x: to, y: y))
        }
        if style == .grid {
            for x in stride(from: from, through: to, by: spacing) {
                path.move(to: CGPoint(x: x, y: 40 * k)); path.addLine(to: CGPoint(x: x, y: size.height - 40 * k))
            }
        }
        return path
    }

    /// One growing edge: switch, quick steps (+¼/+½/+1 page) and a fine slider.
    /// It never goes below the page's content, so nothing can be cut off.
    private func growthRow(_ title: String, value: Binding<Double>, dimension: Double, minimum: Double, standard: Double) -> some View {
        let on = value.wrappedValue > 0
        let percent = Int((value.wrappedValue / dimension * 100).rounded())
        return VStack(alignment: .leading, spacing: 12) {
            Toggle(title, isOn: Binding(get: { value.wrappedValue > 0 },
                                       set: { value.wrappedValue = $0 ? max(minimum, dimension * standard) : 0 }))
                .toggleStyle(.switch).frame(minHeight: 36)
                .disabled(!editable || (on && minimum > 0))
            HStack(spacing: 8) {
                ForEach(Array(zip(["+¼ Seite", "+½ Seite", "+1 Seite"], [0.25, 0.5, 1.0])), id: \.0) { label, fraction in
                    let target = dimension * fraction
                    let chosen = on && abs(value.wrappedValue - target) < 0.5
                    Button(label) { value.wrappedValue = max(minimum, target) }
                        .font(.subheadline.weight(chosen ? .semibold : .regular))
                        .buttonStyle(.bordered).tint(chosen ? Color.accentColor : Color.gray)
                        .disabled(!on || !editable || target < minimum - 0.5)
                        .accessibilityLabel("\(title) \(label)")
                }
                Spacer(minLength: 0)
                Text(on ? "+\(percent) %" : "aus").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: (on ? minimum : 0)...max(1, max(dimension, value.wrappedValue)))
                .disabled(!on || !editable)
                .accessibilityLabel("\(title), Anteil")
            if minimum > 0.5 {
                Text("Hier liegt schon Inhalt: kürzer als \(Int((minimum / dimension * 100).rounded())) % geht nicht.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// How far content reaches beyond the base sheet (right/below), in page points.
    private static func contentOverhang(of page: Page, base: PageSize) -> PageSize {
        guard page.writingSpaceExtendsPaper else { return PageSize(width: 0, height: 0) }
        var maxX = 0.0, maxY = 0.0
        func include(_ rect: PageRect) { maxX = max(maxX, rect.x + rect.width); maxY = max(maxY, rect.y + rect.height) }
        if !page.drawing.isEmpty, let drawing = try? PKDrawing(data: page.drawing) {
            for stroke in drawing.strokes where !stroke.renderBounds.isNull { include(PageRect(stroke.renderBounds)) }
        }
        page.effectiveTextBoxes.forEach { include($0.rotatedBounds) }
        (page.images ?? []).forEach { include($0.rotatedBounds) }
        (page.shapes ?? []).forEach { include($0.bounds) }
        return PageSize(width: max(0, (maxX - base.width).rounded(.up)), height: max(0, (maxY - base.height).rounded(.up)))
    }

    // MARK: PDF page („Schreibplatz“)

    private var pdfContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let preview {
                VStack(alignment: .leading, spacing: 12) {
                    PageThumbnail(page: preview, source: model.sourcePage(for: preview), cache: cache)
                        .frame(maxWidth: .infinity).frame(height: 250)
                        .clipped().allowsHitTesting(false)
                        .accessibilityLabel("Vorschau der Seite mit zusätzlichem Schreibplatz")
                    Text("Die PDF behält ihre Größe und Farben. Die Seite wird um die gewählten Ränder erweitert.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Schreibränder").font(.headline)
                edge("Links", value: $margins.left, dimension: base.width)
                edge("Rechts", value: $margins.right, dimension: base.width)
                edge("Oben", value: $margins.top, dimension: base.height)
                edge("Unten", value: $margins.bottom, dimension: base.height)
            }
            marginPaper
            VStack(alignment: .leading, spacing: 12) {
                Text("Anwenden auf").font(.headline)
                Picker("Anwenden auf", selection: $wholeImport) {
                    Text("Aktuelle Seite").tag(false)
                    Text("Dieser PDF-Import").tag(true)
                }.pickerStyle(.segmented)
                Text("100 % ist so breit wie das PDF-Blatt. Bei einheitlicher Anzeige entspricht das einer normalen Seitenbreite. Gelöschte Seiten bleiben unverändert.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .notySheetCard()
        }
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
            .notySheetCard()
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

extension View {
    /// Card of noty's dark sheets (Schreibplatz, Seite anpassen).
    func notySheetCard() -> some View {
        padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle()).clipped()
    }
}
