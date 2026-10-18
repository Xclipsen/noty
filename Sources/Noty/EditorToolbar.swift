import SwiftUI
import NotebookCore

typealias EditorTool = WritingTool

extension WritingTool {
    var title: String {
        switch self {
        case .pen: "Stift"
        case .marker: "Marker"
        case .strokeEraser: "Ganzer Strich"
        case .precisionEraser: "Präzisionsradierer"
        case .inkSelection: "Handschrift auswählen"
        case .text: "Text"
        case .image: "Bilder"
        case .shape: "Formen"
        case .selection: "Gemischtes Lasso"
        case .read: "PDF lesen"
        }
    }
    var symbol: String {
        switch self {
        case .pen: "pencil.tip"
        case .marker: "highlighter"
        case .strokeEraser: "eraser.line.dashed"
        case .precisionEraser: "eraser"
        case .inkSelection: "lasso"
        case .text: "textformat"
        case .image: "photo"
        case .shape: "square.on.circle"
        case .selection: "lasso.and.sparkles"
        case .read: "hand.draw"
        }
    }
}

struct EditorToolbar: View {
    @Binding var tool: EditorTool
    @Binding var preferences: ToolbarPreferences
    var onFit: () -> Void
    var onCustomize: () -> Void
    var onSearch: () -> Void
    var onSecondView: (() -> Void)?
    @Binding var ruler: Bool
    @Binding var more: Bool
    @Binding var settings: Bool
    var axis: ToolbarAxis
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionSpace
    private var vertical: Bool { axis == .vertical }
    private var mainTools: [WritingTool] { preferences.order.filter { ![.precisionEraser, .inkSelection].contains($0) } }

    var body: some View {
        let stack = vertical ? AnyLayout(VStackLayout(spacing: ToolbarLayout.spacing)) : AnyLayout(HStackLayout(spacing: ToolbarLayout.spacing))
        stack {
            ScrollView(vertical ? .vertical : .horizontal, showsIndicators: false) {
                let choices = vertical ? AnyLayout(VStackLayout(spacing: ToolbarLayout.spacing)) : AnyLayout(HStackLayout(spacing: ToolbarLayout.spacing))
                choices { buttons }.id(more).transition(levelTransition)
            }.scrollBounceBehavior(.basedOnSize)
            Button {
                withAnimation(NotyMotion.palette(reduceMotion)) { more.toggle(); settings = false }
            } label: {
                Image(systemName: vertical ? "chevron.down" : "chevron.right")
                    .font(.system(size: 20, weight: .regular)).foregroundStyle(.white.opacity(0.88))
                    .rotationEffect(.degrees(more ? 180 : 0))
                    .frame(width: ToolbarLayout.cell, height: ToolbarLayout.cell).contentShape(Rectangle())
            }.buttonStyle(NotyToolStyle())
                .accessibilityLabel(more ? "Hauptwerkzeuge" : "Weitere Werkzeuge")
        }
        .padding(ToolbarLayout.padding)
        .animation(NotyMotion.palette(reduceMotion), value: more)
        .animation(NotyMotion.highlight(reduceMotion), value: tool)
    }
    private var levelTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.94))
    }
    @ViewBuilder private var buttons: some View {
        if more {
            utility(ruler ? "Lineal ausblenden" : "Lineal einblenden", symbol: "ruler", selected: ruler) { ruler.toggle() }
            toolButton(.inkSelection)
            utility("Seitenbreite einpassen", symbol: "arrow.up.left.and.arrow.down.right", action: onFit)
            utility("Inhalte suchen", symbol: "magnifyingglass", action: onSearch)
            if let onSecondView { utility("Zweite Ansicht", symbol: "rectangle.split.2x1", action: onSecondView) }
            utility("Werkzeugleiste anpassen", symbol: "slider.horizontal.3", action: onCustomize)
                .overlay(alignment: vertical ? .top : .leading) { separator }
        } else {
            ForEach(mainTools) { item in
                toolButton(item).overlay(alignment: vertical ? .top : .leading) {
                    if item == .read { separator }
                }
            }
            ForEach(preferences.presets) { preset in
                Button {
                    if preset.tool == .pen { preferences.penColor = preset.color; preferences.penWidth = preset.width; preferences.autoPen = false }
                    else { preferences.markerColor = preset.color; preferences.markerWidth = preset.width }
                    tool = preset.tool; settings = false
                } label: {
                    ToolbarGlyph(tool: preset.tool).frame(width: ToolbarLayout.cell, height: ToolbarLayout.cell).contentShape(Rectangle())
                        .overlay(alignment: .bottom) {
                            Circle().fill(preset.color.color).frame(width: 7, height: 7)
                                .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1)).offset(y: -1)
                        }
                }.buttonStyle(NotyToolStyle()).accessibilityLabel("Lieblingsstift, Breite \(preset.width.formatted())")
            }
        }
    }
    private func toolButton(_ item: WritingTool) -> some View {
        let selected = tool == item || (item == .strokeEraser && tool == .precisionEraser)
        return Button {
            if selected { if item == .text { settings = false } else { settings.toggle() } }
            else {
                settings = false
                tool = item == .strokeEraser && preferences.eraserPrecision == true ? .precisionEraser : item
                if item == .image { settings = true }
            }
        } label: {
            ToolbarGlyph(tool: item, selected: selected)
                .frame(width: ToolbarLayout.cell, height: ToolbarLayout.cell).contentShape(Rectangle())
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(LinearGradient(colors: [.white.opacity(0.12), .blue.opacity(0.13)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.23), lineWidth: 0.6))
                            .frame(width: 44, height: 44)
                            .matchedGeometryEffect(id: "selected-tool", in: selectionSpace)
                    }
                }
        }.buttonStyle(NotyToolStyle()).accessibilityLabel(item == .strokeEraser ? "Radierer" : item.title)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func utility(_ title: String, symbol: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 23, weight: .regular)).symbolRenderingMode(.hierarchical)
                .foregroundStyle(LinearGradient(colors: [.white, .white.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: ToolbarLayout.cell, height: ToolbarLayout.cell).contentShape(Rectangle())
                .background(selected ? Color.white.opacity(0.17) : .clear, in: RoundedRectangle(cornerRadius: 13))
        }.buttonStyle(NotyToolStyle()).accessibilityLabel(title).help(title)
    }

    private var separator: some View {
        Rectangle().fill(.white.opacity(0.14))
            .frame(width: vertical ? 18 : 0.5, height: vertical ? 0.5 : 18)
            .offset(x: vertical ? 0 : -2, y: vertical ? -2 : 0).allowsHitTesting(false)
    }

}

struct ToolbarCustomizationView: View {
    @ObservedObject var settings: ToolbarSettingsModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if !settings.status.isEmpty {
                    Section {
                        Text(settings.status)
                        Button("Erneut speichern") { settings.save() }.disabled(!settings.writable)
                    }
                }
                Section("Position und Eingabe") {
                    Picker("Werkzeugleiste", selection: Binding(get: { settings.preferences.effectiveDock }, set: { settings.preferences.dock = $0 })) {
                        Text("Oben").tag(ToolbarDock.top)
                        Text("Unten").tag(ToolbarDock.bottom)
                        Text("Links").tag(ToolbarDock.left)
                        Text("Rechts").tag(ToolbarDock.right)
                        if settings.preferences.dockOnly == false { Text("Schwebend").tag(ToolbarDock.floating) }
                    }
                    Toggle("Nur an Andockpunkten", isOn: Binding(get: { settings.preferences.dockOnly ?? true }, set: {
                        settings.preferences.dockOnly = $0
                        if $0 && settings.preferences.dock == .floating { settings.preferences.dock = .top }
                    }))
                    if settings.preferences.dockOnly == false {
                        Picker("Schwebende Ausrichtung", selection: Binding(get: { settings.preferences.floatingAxis ?? .horizontal }, set: {
                            settings.preferences.floatingAxis = $0; settings.preferences.dock = .floating
                        })) {
                            Text("Horizontal").tag(ToolbarAxis.horizontal)
                            Text("Vertikal").tag(ToolbarAxis.vertical)
                        }.pickerStyle(.segmented)
                    }
                    Text("Standard: nur die vier Andockpunkte. Für freies Verschieben ausschalten; dann wechselt ein Doppeltipp auf den Griff die Ausrichtung.").font(.caption).foregroundStyle(.secondary)
                    Toggle("Pencil-Vorschau", isOn: Binding(get: { settings.preferences.pencilPreview ?? true }, set: { settings.preferences.pencilPreview = $0 }))
                    Toggle("Auch mit dem Finger zeichnen", isOn: $settings.preferences.fingerDrawing)
                    Text("Standard: Pencil schreibt, Finger navigiert. Bei Fingermalen mit zwei Fingern navigieren.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Werkzeuge umordnen") {
                    ForEach(settings.preferences.order) { tool in Label(tool.title, systemImage: tool.symbol) }
                        .onMove { offsets, target in settings.preferences.order.move(fromOffsets: offsets, toOffset: target) }
                }
                Section("Lieblingsstifte") {
                    if settings.preferences.presets.isEmpty { Text("Stift erneut antippen und als Lieblingsstift speichern.").foregroundStyle(.secondary) }
                    ForEach(settings.preferences.presets) { preset in
                        Label("\(preset.tool.title) · \(preset.width.formatted())", systemImage: preset.tool.symbol).foregroundStyle(preset.color.color)
                    }.onDelete { settings.preferences.presets.remove(atOffsets: $0) }
                        .onMove { settings.preferences.presets.move(fromOffsets: $0, toOffset: $1) }
                }
            }
            .environment(\.editMode, .constant(.active))
            .disabled(!settings.writable)
            .navigationTitle("Werkzeugleiste")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        }
    }
}
