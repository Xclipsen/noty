import SwiftUI
import NotebookCore

/// One compact attached row; long sets of options scroll horizontally.
struct EditorToolOptions: View {
    @Binding var tool: WritingTool
    @Binding var preferences: ToolbarPreferences
    @Binding var showing: Bool
    @Binding var shapeOptions: ShapeToolOptions
    @Binding var selectionFilter: SelectionFilter
    @Binding var lassoMode: LassoMode
    @Binding var recognizeShapes: Bool
    let onInsertText: () -> Void
    let onPhoto: () -> Void
    let onImageFile: () -> Void
    let onPasteImage: () -> Void
    /// Measured width of the whole row (controls + close button + padding).
    var onContentWidth: (Double) -> Void = { _ in }

    static func preferredWidth(for tool: WritingTool) -> Double {
        switch tool {
        case .pen: 470
        case .pencil: 400
        case .laser: 520
        case .shape: 700
        case .marker: 520
        case .strokeEraser, .precisionEraser: 390
        case .image: 360
        case .selection, .inkSelection: 540
        default: 250
        }
    }
    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Self.itemSpacing) { controls }.frame(height: 44).fixedSize()
                    // Size the attached bar to its content instead of a fixed table.
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { onContentWidth(Double($0) + 64) }
            }.scrollBounceBehavior(.basedOnSize)
            Button { showing = false } label: {
                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).frame(width: 44, height: 44).contentShape(Rectangle())
            }.accessibilityLabel("Werkzeugoptionen schließen").notyTooltip("Optionen schließen")
        }.font(.system(size: 13, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 4)
            .buttonStyle(NotyToolStyle()).foregroundStyle(.white)
            .environment(\.notyTooltipAxis, .horizontal)
            .accessibilityElement(children: .contain).accessibilityLabel("\(tool.title) – Optionen")
    }

    // One grammar for every tool (feedback 22.10.2026): 44-pt cells, 18-pt
    // symbols, the same selection plate, colour well + width slider with its
    // value, groups separated by the toolbar's thin divider, 13-pt labels.
    static let itemSpacing = 6.0

    @ViewBuilder private var controls: some View {
        switch tool {
        case .pen, .pencil, .marker: inkControls
        case .shape: shapeControls
        case .strokeEraser, .precisionEraser: eraserControls
        case .text:
            labeled("Textfeld hinzufügen", symbol: "text.badge.plus", help: "Textfeld hinzufügen – in der Mitte der Ansicht") { showing = false; onInsertText() }
        case .image:
            // Sources first, clipboard after a group divider.
            labeled("Foto", symbol: "photo", help: "Foto aus der Mediathek einfügen") { showing = false; onPhoto() }
            labeled("Bilddatei", symbol: "folder", help: "Bilddatei aus Dateien einfügen") { showing = false; onImageFile() }
            groupDivider
            labeled("Einfügen", symbol: "doc.on.clipboard", help: "Bild aus der Zwischenablage einfügen") { showing = false; onPasteImage() }
        case .selection, .inkSelection: selectionControls
        case .read:
            Text("PDF-Text auswählen und lesen").foregroundStyle(.secondary).padding(.horizontal, 8)
        case .laser: laserControls
        }
    }

    /// Stift, Bleistift, Textmarker: colour and width | behaviour | favourite.
    @ViewBuilder private var inkControls: some View {
        colorWell
        widthControl
        groupDivider
        switch tool {
        case .pen:
            option("Autostift (auch für den Bleistift)", symbol: "a.circle", selected: preferences.automaticInk(for: .pen),
                   help: "Autostift – Schwarz oder Weiß nach Hintergrund") {
                preferences.setAutomaticInk(!preferences.automaticInk(for: .pen), for: .pen)
            }
            option("Durchkritzeln löscht", symbol: "scribble.variable", selected: preferences.scribbleErase ?? true,
                   help: "Durchkritzeln löscht – Gekritzel entfernt Striche") {
                preferences.scribbleErase = !(preferences.scribbleErase ?? true)
            }
            option("Nach Halten begradigen und Formen erkennen", symbol: "wand.and.stars", selected: recognizeShapes,
                   help: "Halten begradigt – Linien und Formen erkennen") { recognizeShapes.toggle() }
        case .pencil:
            option("Autostift: Schwarz oder Weiß nach Hintergrund", symbol: "a.circle", selected: preferences.automaticInk(for: .pencil),
                   help: "Autostift – Schwarz oder Weiß nach Hintergrund") {
                preferences.setAutomaticInk(!preferences.automaticInk(for: .pencil), for: .pencil)
            }
            option("Nach Halten begradigen und Formen erkennen", symbol: "wand.and.stars", selected: recognizeShapes,
                   help: "Halten begradigt – Linien und Formen erkennen") { recognizeShapes.toggle() }
        default:
            let tip = preferences.effectiveMarkerTip
            option("Runde Spitze", symbol: "circle.fill", selected: tip == .round, help: "Runde Spitze – gleichmäßiger Strich") { preferences.markerTip = .round }
            option("Keilspitze", symbol: "highlighter", selected: tip == .chisel, help: "Keilspitze – breit wie ein Textmarker") { preferences.markerTip = .chisel }
            groupDivider
            option("Immer gerade", symbol: "line.horizontal.3.decrease", selected: preferences.markerStraight ?? false,
                   help: "Immer gerade – Striche werden beim Loslassen gerade") {
                preferences.markerStraight = !(preferences.markerStraight ?? false)
            }
            option("Linie nach Halten begradigen", symbol: "wand.and.stars", selected: preferences.markerHoldStraighten ?? true,
                   help: "Halten begradigt – kurz halten macht die Linie gerade") {
                preferences.markerHoldStraighten = !(preferences.markerHoldStraighten ?? true)
            }
        }
        groupDivider
        option("Als Lieblingsstift speichern", symbol: "star", help: "Lieblingsstift – Farbe und Breite in der Leiste merken") {
            preferences.presets.append(InkPreset(tool: tool, color: preferences.inkColor(for: tool), width: preferences.inkWidth(for: tool),
                                                 markerTip: tool == .marker ? preferences.effectiveMarkerTip : nil))
        }.disabled(preferences.presets.count >= 12)
    }

    /// Formen: shape kind | line (colour, width, Autostift) | line style | fill.
    @ViewBuilder private var shapeControls: some View {
        ForEach(ShapeKind.allCases, id: \.self) { kind in
            let symbol = switch kind { case .line: "line.diagonal"; case .arrow: "arrow.up.right"; case .rectangle: "rectangle"; case .ellipse: "circle" }
            option(kind.title, symbol: symbol, selected: shapeOptions.kind == kind) { shapeOptions.kind = kind }
        }
        groupDivider
        colorWell
        widthControl
        option("Autostift (auch für den Bleistift)", symbol: "a.circle", selected: preferences.automaticInk(for: .pen),
               help: "Autostift – Schwarz oder Weiß nach Hintergrund") {
            preferences.setAutomaticInk(!preferences.automaticInk(for: .pen), for: .pen)
        }
        groupDivider
        // Line style as small line drawings instead of a text menu.
        ForEach(StrokePattern.allCases, id: \.self) { pattern in
            glyphOption(pattern.title, selected: shapeOptions.pattern == pattern, help: "Linie \(pattern.title.lowercased())") {
                shapeOptions.pattern = pattern
            } glyph: { patternGlyph(pattern) }
        }
        groupDivider
        shapeFillControls
    }

    /// Fill section of the shape options, the last group of the row. Further
    /// fill settings (colour, opacity) belong here, after the toggle.
    @ViewBuilder private var shapeFillControls: some View {
        option("Füllung", symbol: "square.fill", selected: shapeOptions.filled, help: "Füllung – Rechteck und Ellipse füllen") { shapeOptions.filled.toggle() }
    }

    /// Radierer: kind | width (precise only).
    @ViewBuilder private var eraserControls: some View {
        option("Ganzer Strich", symbol: "eraser.line.dashed", selected: tool == .strokeEraser, help: WritingTool.strokeEraser.hoverText) {
            preferences.eraserPrecision = false; tool = .strokeEraser
        }
        option("Präzise", symbol: "eraser", selected: tool == .precisionEraser, help: WritingTool.precisionEraser.hoverText) {
            preferences.eraserPrecision = true; tool = .precisionEraser
        }
        if tool == .precisionEraser {
            groupDivider
            widthSlider("Radiererbreite", value: $preferences.eraserWidth, range: 4...60, step: 1)
        }
    }

    /// Lasso: shape of the lasso | what it selects.
    @ViewBuilder private var selectionControls: some View {
        option("Freiform", symbol: "lasso", selected: lassoMode == .freeform, help: "Freiform – Auswahl frei umfahren") { lassoMode = .freeform }
        option("Rechteck", symbol: "rectangle.dashed", selected: lassoMode == .rectangle, help: "Rechteck – Auswahl aufziehen") { lassoMode = .rectangle }
        groupDivider
        option("Handschrift", symbol: "pencil.tip", selected: selectionFilter.ink, help: "Handschrift auswählen") { selectionFilter.ink.toggle() }
        option("Textfelder", symbol: "textformat", selected: selectionFilter.text, help: "Textfelder auswählen") { selectionFilter.text.toggle() }
        option("Bilder", symbol: "photo", selected: selectionFilter.images, help: "Bilder auswählen") { selectionFilter.images.toggle() }
        option("Formen", symbol: "square.on.circle", selected: selectionFilter.shapes, help: "Formen auswählen") { selectionFilter.shapes.toggle() }
    }

    /// Laserpointer: mode | colour | trail length.
    @ViewBuilder private var laserControls: some View {
        let style = preferences.laserStyle
        option("Punkt", symbol: "smallcircle.filled.circle", selected: style.mode == .dot, help: "Punkt – Leuchtpunkt folgt dem Stift") { preferences.laserMode = .dot }
        option("Spur", symbol: "scribble", selected: style.mode == .trail, help: "Spur – Linie verblasst") { preferences.laserMode = .trail }
        groupDivider
        ForEach(LaserPointerView.colors, id: \.name) { item in
            swatch(item.color.color, selected: item.color == style.color, title: "Laserfarbe \(item.name)") { preferences.laserColor = item.color }
        }
        if style.mode == .trail {
            groupDivider
            Picker("Spurdauer", selection: Binding(get: { style.fade }, set: { preferences.laserFade = $0 })) {
                Text("Kurz").tag(LaserFade.short); Text("Mittel").tag(LaserFade.medium)
                Text("Lang").tag(LaserFade.long); Text("Bis Absetzen").tag(LaserFade.untilLift)
            }.pickerStyle(.menu).frame(minHeight: 44).accessibilityLabel("Spurdauer").notyTooltip("Spurdauer – wie lange die Spur bleibt")
        }
    }

    // MARK: Building blocks

    /// Colour well of the current pen/shape (system colour picker).
    private var colorWell: some View {
        ColorPicker("Farbe", selection: Binding(get: { preferences.inkColor(for: tool).color }, set: {
            preferences.setInkColor(InkColor($0), for: tool)
        })).labelsHidden().frame(width: 44, height: 44).notyTooltip("Farbe")
    }
    /// Width of the current pen/shape: slider plus its value.
    private var widthControl: some View {
        widthSlider("Breite", value: Binding(get: { preferences.inkWidth(for: tool) }, set: { preferences.setInkWidth($0, for: tool) }),
                    range: ToolbarPreferences.widthRange(for: tool) ?? 1...12, step: tool == .marker ? 1 : 0.5)
    }
    private func widthSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        HStack(spacing: 6) {
            Slider(value: value, in: range, step: step) { Text(title) }.frame(width: 90, height: 44)
            Text(value.wrappedValue.formatted()).monospacedDigit().frame(minWidth: 25, alignment: .leading)
                .accessibilityHidden(true)
        }.notyTooltip(title)
    }
    /// Colour dot with the same ring as the selected state elsewhere.
    private func swatch(_ color: Color, selected: Bool, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle().fill(color).frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(.white.opacity(selected ? 0.95 : 0.3), lineWidth: selected ? 2.5 : 1))
                .frame(width: 34, height: 44).contentShape(Rectangle())
        }.accessibilityLabel(title).accessibilityAddTraits(selected ? .isSelected : []).notyTooltip(title)
    }
    /// Short drawing of a line style (solid, dashed, dotted).
    private func patternGlyph(_ pattern: StrokePattern) -> some View {
        Path { path in path.move(to: CGPoint(x: 3, y: 9)); path.addLine(to: CGPoint(x: 27, y: 9)) }
            .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: pattern == .dotted ? .round : .butt,
                                              dash: pattern == .solid ? [] : pattern == .dashed ? [6, 4] : [0.1, 5]))
            .frame(width: 30, height: 18)
    }
    /// Action with symbol and short label (no selection state), 44-pt target.
    private func labeled(_ title: String, symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 18)).frame(width: 24)
                Text(title).lineLimit(1)
            }
            .padding(.horizontal, 8).frame(minHeight: 44).contentShape(Rectangle())
        }.accessibilityLabel(help).notyTooltip(help)
    }
    /// Thin group divider like in the toolbar and the selection bars.
    private var groupDivider: some View {
        Rectangle().fill(.white.opacity(0.14)).frame(width: 0.5, height: 18).padding(.horizontal, 2)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
    private func option(_ title: String, symbol: String, selected: Bool = false, help: String? = nil, action: @escaping () -> Void) -> some View {
        glyphOption(title, selected: selected, help: help, action: action) {
            Image(systemName: symbol).font(.system(size: 18))
        }
    }
    /// Toggle/choice cell with any glyph; selected cells get the common plate.
    private func glyphOption<Glyph: View>(_ title: String, selected: Bool = false, help: String? = nil, action: @escaping () -> Void,
                                          @ViewBuilder glyph: () -> Glyph) -> some View {
        Button(action: action) {
            glyph()
                .frame(width: 44, height: 44).contentShape(Rectangle())
                .background(selected ? .white.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 10))
        }.accessibilityLabel(title).accessibilityAddTraits(selected ? .isSelected : []).notyTooltip(help ?? title)
    }
}
