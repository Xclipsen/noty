import SwiftUI
import NotebookCore

/// One compact attached row; long sets of options scroll horizontally.
struct EditorToolOptions: View {
    @Binding var tool: WritingTool
    @Binding var preferences: ToolbarPreferences
    @Binding var showing: Bool
    @Binding var shapeOptions: ShapeToolOptions
    @Binding var selectionFilter: SelectionFilter
    @Binding var recognizeShapes: Bool
    let onInsertText: () -> Void
    let onPhoto: () -> Void
    let onImageFile: () -> Void
    let onPasteImage: () -> Void

    static func preferredWidth(for tool: WritingTool) -> Double {
        switch tool {
        case .pen, .shape: 450
        case .marker: 320
        case .strokeEraser, .precisionEraser: 390
        case .image: 370
        case .selection: 400
        default: 250
        }
    }
    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) { controls }.frame(height: 44)
            }.scrollBounceBehavior(.basedOnSize)
            Button { showing = false } label: {
                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).frame(width: 44, height: 44).contentShape(Rectangle())
            }.accessibilityLabel("Werkzeugoptionen schließen")
        }.font(.system(size: 13, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 4)
            .buttonStyle(NotyToolStyle()).foregroundStyle(.white)
            .accessibilityElement(children: .contain).accessibilityLabel("\(tool.title) – Optionen")
    }

    @ViewBuilder private var controls: some View {
        if tool == .pen || tool == .marker || tool == .shape {
            let marker = tool == .marker
            ColorPicker("Farbe", selection: Binding(get: { (marker ? preferences.markerColor : preferences.penColor).color }, set: {
                if marker { preferences.markerColor = InkColor($0) }
                else { preferences.penColor = InkColor($0); preferences.autoPen = false }
            })).labelsHidden().frame(width: 44, height: 44)
            Slider(value: marker ? $preferences.markerWidth : $preferences.penWidth,
                   in: marker ? 4...40 : 1...12, step: marker ? 1 : 0.5) { Text("Breite") }.frame(width: 90, height: 44)
            Text((marker ? preferences.markerWidth : preferences.penWidth).formatted()).monospacedDigit().frame(minWidth: 25)
            if tool == .pen {
                option("Autostift", symbol: "a.circle", selected: preferences.autoPen ?? false) { preferences.autoPen = !(preferences.autoPen ?? false) }
                option("Form nach Halten erkennen", symbol: "wand.and.stars", selected: recognizeShapes) { recognizeShapes.toggle() }
            }
            if tool != .shape {
                option("Als Lieblingsstift speichern", symbol: "star") {
                    preferences.presets.append(InkPreset(tool: tool, color: marker ? preferences.markerColor : preferences.penColor,
                        width: marker ? preferences.markerWidth : preferences.penWidth))
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
            Button("Fotos", systemImage: "photo.on.rectangle") { showing = false; onPhoto() }.frame(minHeight: 44).contentShape(Rectangle())
            Button("Dateien", systemImage: "folder") { showing = false; onImageFile() }.frame(minHeight: 44).contentShape(Rectangle())
            Button("Einfügen", systemImage: "doc.on.clipboard") { showing = false; onPasteImage() }.frame(minHeight: 44).contentShape(Rectangle())
        }
        if tool == .shape {
            Picker("Form", selection: $shapeOptions.kind) { ForEach(ShapeKind.allCases, id: \.self) { Text($0.title).tag($0) } }
                .pickerStyle(.menu).labelsHidden().frame(minHeight: 44)
            Picker("Strich", selection: $shapeOptions.pattern) { ForEach(StrokePattern.allCases, id: \.self) { Text($0.title).tag($0) } }
                .pickerStyle(.menu).labelsHidden().frame(minHeight: 44)
            option("Füllung", symbol: "square.fill", selected: shapeOptions.filled) { shapeOptions.filled.toggle() }
        }
        if tool == .selection {
            option("Handschrift", symbol: "pencil.tip", selected: selectionFilter.ink) { selectionFilter.ink.toggle() }
            option("Textfelder", symbol: "textformat", selected: selectionFilter.text) { selectionFilter.text.toggle() }
            option("Bilder", symbol: "photo", selected: selectionFilter.images) { selectionFilter.images.toggle() }
            option("Formen", symbol: "square.on.circle", selected: selectionFilter.shapes) { selectionFilter.shapes.toggle() }
        }
        if tool == .inkSelection { Text("Nur Handschrift auswählen").foregroundStyle(.secondary) }
        if tool == .read { Text("PDF-Text auswählen und lesen").foregroundStyle(.secondary) }
    }
    private func option(_ title: String, symbol: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18))
                .frame(width: 44, height: 44).contentShape(Rectangle())
                .background(selected ? .white.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 10))
        }.accessibilityLabel(title).accessibilityAddTraits(selected ? .isSelected : []).help(title)
    }
}
