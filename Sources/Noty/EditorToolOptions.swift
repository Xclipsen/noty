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
        case .pen: 450
        case .pencil: 400
        case .laser: 480
        case .shape: 620
        case .marker: 420
        case .strokeEraser, .precisionEraser: 390
        case .image: 360
        case .selection, .inkSelection: 540
        default: 250
        }
    }
    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) { controls }.frame(height: 44).fixedSize()
                    // Size the attached bar to its content instead of a fixed table.
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { onContentWidth(Double($0) + 64) }
            }.scrollBounceBehavior(.basedOnSize)
            Button { showing = false } label: {
                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).frame(width: 44, height: 44).contentShape(Rectangle())
            }.accessibilityLabel("Werkzeugoptionen schließen")
        }.font(.system(size: 13, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 4)
            .buttonStyle(NotyToolStyle()).foregroundStyle(.white)
            .accessibilityElement(children: .contain).accessibilityLabel("\(tool.title) – Optionen")
    }

    @ViewBuilder private var controls: some View {
        if tool == .shape {
            ForEach(ShapeKind.toolKinds, id: \.self) { kind in
                let symbol = switch kind { case .line: "line.diagonal"; case .arrow: "arrow.up.right"; case .rectangle: "rectangle"; case .ellipse: "circle"; case .polygon: "triangle" }
                option(kind.title, symbol: symbol, selected: shapeOptions.kind == kind) { shapeOptions.kind = kind }
            }
        }
        if tool.isInk || tool == .shape {
            let marker = tool == .marker
            ColorPicker("Farbe", selection: Binding(get: { preferences.inkColor(for: tool).color }, set: {
                preferences.setInkColor(InkColor($0), for: tool)
            })).labelsHidden().frame(width: 44, height: 44)
            Slider(value: Binding(get: { preferences.inkWidth(for: tool) }, set: { preferences.setInkWidth($0, for: tool) }),
                   in: ToolbarPreferences.widthRange(for: tool) ?? 1...12, step: marker ? 1 : 0.5) { Text("Breite") }.frame(width: 90, height: 44)
            Text(preferences.inkWidth(for: tool).formatted()).monospacedDigit().frame(minWidth: 25)
            if tool == .pen || tool == .shape {
                option("Autostift (auch für den Bleistift)", symbol: "a.circle", selected: preferences.automaticInk(for: .pen)) {
                    preferences.setAutomaticInk(!preferences.automaticInk(for: .pen), for: .pen)
                }
            }
            if tool == .pencil {
                option("Autostift: Schwarz oder Weiß nach Hintergrund", symbol: "a.circle", selected: preferences.automaticInk(for: .pencil)) {
                    preferences.setAutomaticInk(!preferences.automaticInk(for: .pencil), for: .pencil)
                }
            }
            if tool == .pen {
                option("Durchkritzeln löscht", symbol: "scribble.variable", selected: preferences.scribbleErase ?? true) {
                    preferences.scribbleErase = !(preferences.scribbleErase ?? true)
                }
            }
            if tool == .marker {
                let tip = preferences.effectiveMarkerTip
                option("Runde Spitze", symbol: "circle.fill", selected: tip == .round) { preferences.markerTip = .round }
                option("Keilspitze", symbol: "highlighter", selected: tip == .chisel) { preferences.markerTip = .chisel }
                option("Immer gerade", symbol: "line.horizontal.3.decrease", selected: preferences.markerStraight ?? false) {
                    preferences.markerStraight = !(preferences.markerStraight ?? false)
                }
            }
            if tool == .marker {
                option("Linie nach Halten begradigen", symbol: "wand.and.stars", selected: preferences.markerHoldStraighten ?? true) {
                    preferences.markerHoldStraighten = !(preferences.markerHoldStraighten ?? true)
                }
            } else if tool.isInk {
                option("Nach Halten begradigen und Formen erkennen", symbol: "wand.and.stars", selected: recognizeShapes) { recognizeShapes.toggle() }
            }
            if tool != .shape {
                option("Als Lieblingsstift speichern", symbol: "star") {
                    preferences.presets.append(InkPreset(tool: tool, color: preferences.inkColor(for: tool), width: preferences.inkWidth(for: tool),
                                                         markerTip: tool == .marker ? preferences.effectiveMarkerTip : nil))
                }.disabled(preferences.presets.count >= 12)
            }
        }
        if tool == .strokeEraser || tool == .precisionEraser {
            Button("Strich") { preferences.eraserPrecision = false; tool = .strokeEraser }
                .padding(.horizontal, 8).frame(minWidth: 64, minHeight: 44).background(tool == .strokeEraser ? .white.opacity(0.16) : .clear, in: Capsule())
            Button("Präzise") { preferences.eraserPrecision = true; tool = .precisionEraser }
                .padding(.horizontal, 8).frame(minWidth: 64, minHeight: 44).background(tool == .precisionEraser ? .white.opacity(0.16) : .clear, in: Capsule())
            if tool == .precisionEraser {
                Slider(value: $preferences.eraserWidth, in: 4...60, step: 1) { Text("Radiererbreite") }.frame(width: 90, height: 44)
            }
        }
        if tool == .text {
            Button("Textfeld +", systemImage: "text.badge.plus") { showing = false; onInsertText() }.frame(minHeight: 44).contentShape(Rectangle())
        }
        if tool == .image {
            // Sources first, clipboard after a group divider; same symbol size
            // as the other options, with short labels instead of system buttons.
            labeled("Foto", symbol: "photo", help: "Foto aus der Mediathek einfügen") { showing = false; onPhoto() }
            labeled("Bilddatei", symbol: "folder", help: "Bilddatei aus Dateien einfügen") { showing = false; onImageFile() }
            groupDivider
            labeled("Einfügen", symbol: "doc.on.clipboard", help: "Bild aus der Zwischenablage einfügen") { showing = false; onPasteImage() }
        }
        if tool == .shape {
            Picker("Strich", selection: $shapeOptions.pattern) { ForEach(StrokePattern.allCases, id: \.self) { Text($0.title).tag($0) } }
                .pickerStyle(.menu).labelsHidden().frame(minHeight: 44)
            option("Füllung", symbol: "square.fill", selected: shapeOptions.filled) { shapeOptions.filled.toggle() }
        }
        if tool == .selection || tool == .inkSelection {
            option("Freiform", symbol: "lasso", selected: lassoMode == .freeform) { lassoMode = .freeform }
            option("Rechteck", symbol: "rectangle.dashed", selected: lassoMode == .rectangle) { lassoMode = .rectangle }
            option("Handschrift", symbol: "pencil.tip", selected: selectionFilter.ink) { selectionFilter.ink.toggle() }
            option("Textfelder", symbol: "textformat", selected: selectionFilter.text) { selectionFilter.text.toggle() }
            option("Bilder", symbol: "photo", selected: selectionFilter.images) { selectionFilter.images.toggle() }
            option("Formen", symbol: "square.on.circle", selected: selectionFilter.shapes) { selectionFilter.shapes.toggle() }
        }
        if tool == .read { Text("PDF-Text auswählen und lesen").foregroundStyle(.secondary) }
        if tool == .laser {
            let style = preferences.laserStyle
            option("Punkt", symbol: "smallcircle.filled.circle", selected: style.mode == .dot) { preferences.laserMode = .dot }
            option("Spur", symbol: "scribble", selected: style.mode == .trail) { preferences.laserMode = .trail }
            ForEach(LaserPointerView.colors, id: \.name) { item in
                Button { preferences.laserColor = item.color } label: {
                    Circle().fill(item.color.color).frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(.white.opacity(item.color == style.color ? 0.95 : 0.3), lineWidth: item.color == style.color ? 2.5 : 1))
                        .frame(width: 36, height: 44).contentShape(Rectangle())
                }.accessibilityLabel("Laserfarbe \(item.name)").accessibilityAddTraits(item.color == style.color ? .isSelected : [])
            }
            if style.mode == .trail {
                Picker("Spurdauer", selection: Binding(get: { style.fade }, set: { preferences.laserFade = $0 })) {
                    Text("Kurz").tag(LaserFade.short); Text("Mittel").tag(LaserFade.medium)
                    Text("Lang").tag(LaserFade.long); Text("Bis Absetzen").tag(LaserFade.untilLift)
                }.pickerStyle(.menu).frame(minHeight: 44).accessibilityLabel("Spurdauer")
            }
        }
    }
    /// Action with symbol and short label (no selection state), 44-pt target.
    private func labeled(_ title: String, symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 18)).frame(width: 24)
                Text(title).lineLimit(1)
            }
            .padding(.horizontal, 8).frame(minHeight: 44).contentShape(Rectangle())
        }.accessibilityLabel(help).help(help)
    }
    /// Thin group divider like in the toolbar and the selection bars.
    private var groupDivider: some View {
        Rectangle().fill(.white.opacity(0.14)).frame(width: 0.5, height: 18).allowsHitTesting(false).accessibilityHidden(true)
    }
    private func option(_ title: String, symbol: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18))
                .frame(width: 44, height: 44).contentShape(Rectangle())
                .background(selected ? .white.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 10))
        }.accessibilityLabel(title).accessibilityAddTraits(selected ? .isSelected : []).help(title)
    }
}
