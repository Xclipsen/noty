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
        case .inkSelection: "Lasso"
        case .text: "Text"
        case .image: "Bilder"
        case .shape: "Formen"
        case .selection: "Gemischtes Lasso"
        case .read: "PDF lesen"
        case .pencil: "Bleistift"
        case .laser: "Laserpointer"
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
        case .pencil: "pencil"
        case .laser: "cursorarrow.rays"
        }
    }
    /// Name and very short description, shown after lingering over the tool
    /// (Pencil hover or pointer) and as `.help`.
    var hoverText: String {
        switch self {
        case .pen: "Stift – schreibt mit Druckstärke"
        case .pencil: "Bleistift – Graphit, Neigen schattiert"
        case .marker: "Textmarker – durchscheinend hervorheben"
        case .strokeEraser: "Radierer – löscht ganze Striche"
        case .precisionEraser: "Präzisionsradierer – löscht nur berührte Teile"
        case .inkSelection: "Lasso – Handschrift, Text, Bilder, Formen auswählen"
        case .selection: "Gemischtes Lasso – alles Berührte auswählen"
        case .text: "Text – Textfeld antippen oder anlegen"
        case .image: "Bilder – Foto, Datei oder Zwischenablage"
        case .shape: "Formen – Linie, Pfeil, Rechteck, Ellipse"
        case .read: "PDF lesen – Text auswählen, ohne zu schreiben"
        case .laser: "Laserpointer – zeigen, wird nicht gespeichert"
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
    /// Last pen/pencil/marker: non-ink tools show its colour when selected.
    var activeInk: WritingTool = .pen
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var vertical: Bool { axis == .vertical }
    /// First level: drawing/writing tools; the laser pointer and „PDF lesen“
    /// sit on the second level with the utilities (derived, order unchanged).
    private var primaryTools: [WritingTool] { preferences.primaryTools }
    private var secondaryTools: [WritingTool] { preferences.secondaryTools }

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
                    // The active tool lives on the other level (e.g. laser pointer).
                    .overlay(alignment: vertical ? .bottom : .trailing) {
                        if activeOnOtherLevel {
                            Circle().fill(Color(red: 0.45, green: 0.7, blue: 1)).frame(width: 5, height: 5)
                                .padding(vertical ? .bottom : .trailing, 7).allowsHitTesting(false)
                        }
                    }
            }.buttonStyle(NotyToolStyle())
                .accessibilityLabel(more ? "Hauptwerkzeuge" : "Weitere Werkzeuge")
                .notyTooltip(more ? "Hauptwerkzeuge – zurück zur ersten Ebene" : "Weitere Werkzeuge – Lineal, Suche, Anpassen …")
        }
        .environment(\.notyTooltipAxis, axis)
        .padding(ToolbarLayout.padding)
        .animation(NotyMotion.palette(reduceMotion), value: more)
        .animation(NotyMotion.highlight(reduceMotion), value: tool)
    }
    private var activeOnOtherLevel: Bool {
        let onSecond = secondaryTools.contains(tool)
        return more ? primaryTools.contains(tool) || tool == .precisionEraser : onSecond
    }
    private var levelTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.94))
    }
    @ViewBuilder private var buttons: some View {
        if more {
            ForEach(secondaryTools) { item in toolButton(item) }
            utility(ruler ? "Lineal ausblenden" : "Lineal einblenden", symbol: "ruler", selected: ruler,
                    detail: ruler ? "Lineal ausblenden" : "Lineal – gerade Linien am Lineal ziehen") { ruler.toggle() }
                .overlay(alignment: vertical ? .top : .leading) { if !secondaryTools.isEmpty { separator } }
            utility("Seitenbreite einpassen", symbol: "arrow.up.left.and.arrow.down.right",
                    detail: "Seitenbreite einpassen – ganze Breite zeigen", action: onFit)
            utility("Inhalte suchen", symbol: "magnifyingglass", detail: "Suchen – Text im Notizbuch finden", action: onSearch)
            if let onSecondView { utility("Zweite Ansicht", symbol: "rectangle.split.2x1", detail: "Zweite Ansicht – weiteres Notizbuch daneben", action: onSecondView) }
            utility("Werkzeugleiste anpassen", symbol: "slider.horizontal.3",
                    detail: "Anpassen – Reihenfolge, Position, Lieblingsstifte", action: onCustomize)
                .overlay(alignment: vertical ? .top : .leading) { separator }
        } else {
            ForEach(primaryTools) { item in toolButton(item) }
            ForEach(preferences.presets) { preset in
                Button {
                    switch preset.tool {
                    case .pen, .pencil: preferences.setInkColor(preset.color, for: preset.tool); preferences.setInkWidth(preset.width, for: preset.tool)
                    default:
                        preferences.markerColor = preset.color; preferences.markerWidth = preset.width
                        if let tip = preset.markerTip { preferences.markerTip = tip }
                    }
                    tool = preset.tool; settings = false
                } label: {
                    ToolbarGlyph(tool: preset.tool, markerTip: preset.markerTip ?? preferences.effectiveMarkerTip).frame(width: ToolbarLayout.cell, height: ToolbarLayout.cell).contentShape(Rectangle())
                        .overlay(alignment: .bottom) {
                            Circle().fill(preset.color.color).frame(width: 7, height: 7)
                                .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1)).offset(y: -1)
                        }
                }.buttonStyle(NotyToolStyle()).accessibilityLabel("Lieblingsstift, Breite \(preset.width.formatted())")
                    .notyTooltip("Lieblingsstift – \(preset.tool.title), Breite \(preset.width.formatted())")
            }
        }
    }
    /// Selection path shared with the Pencil squeeze palette: the tool actually
    /// chosen (eraser preference) and whether its options open.
    static func choice(_ item: WritingTool, preferences: ToolbarPreferences) -> (tool: WritingTool, options: Bool) {
        (item == .strokeEraser && preferences.eraserPrecision == true ? .precisionEraser : item,
         item == .image || item == .shape || item == .inkSelection)
    }
    private func toolButton(_ item: WritingTool) -> some View {
        let selected = tool == item || (item == .strokeEraser && tool == .precisionEraser)
        return Button {
            if selected { if item == .text { settings = false } else { settings.toggle() } }
            else {
                let choice = Self.choice(item, preferences: preferences)
                tool = choice.tool; settings = choice.options
            }
        } label: {
            // Selected: no box, the symbol itself grows and takes the ink colour.
            ToolbarGlyph(tool: item, selected: selected, ink: selected ? selectionInk(for: item) : nil,
                         markerTip: preferences.effectiveMarkerTip)
                .scaleEffect(selected ? 1.2 : 1)
                .frame(width: ToolbarLayout.cell, height: ToolbarLayout.cell).contentShape(Rectangle())
        }.buttonStyle(NotyToolStyle()).accessibilityLabel(item == .strokeEraser ? "Radierer" : item.title)
            .accessibilityAddTraits(selected ? .isSelected : [])
            // The eraser button stands for the eraser kind last chosen.
            .notyTooltip(item == .strokeEraser && preferences.eraserPrecision == true ? WritingTool.precisionEraser.hoverText : item.hoverText)
    }
    /// Colour of the active pen: ink tools their own, the laser its beam,
    /// every other tool the last used pen/pencil/marker (full opacity).
    private func selectionInk(for item: WritingTool) -> Color {
        var ink = item == .laser ? preferences.laserStyle.color : preferences.inkColor(for: item.isInk ? item : activeInk)
        ink.alpha = 1
        return ink.color
    }
    private func utility(_ title: String, symbol: String, selected: Bool = false, detail: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 23, weight: .regular)).symbolRenderingMode(.hierarchical)
                .foregroundStyle(selected ? AnyShapeStyle(Color.notyAccent)
                                 : AnyShapeStyle(LinearGradient(colors: [.white, .white.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing)))
                .scaleEffect(selected ? 1.15 : 1)
                .frame(width: ToolbarLayout.cell, height: ToolbarLayout.cell).contentShape(Rectangle())
        }.buttonStyle(NotyToolStyle()).accessibilityLabel(title).notyTooltip(detail ?? title)
            .accessibilityAddTraits(selected ? .isSelected : [])
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
            ToolbarCustomizationList(settings: settings)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        }
    }
}

/// Toolbar sections shared by the editor sheet and Settings › Stift & Werkzeuge.
struct ToolbarCustomizationList: View {
    @ObservedObject var settings: ToolbarSettingsModel
    var body: some View {
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
                Toggle("Auch mit dem Finger zeichnen", isOn: $settings.preferences.fingerDrawing)
                Text("Standard: Pencil schreibt, Finger navigiert. Bei Fingermalen mit zwei Fingern navigieren.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Werkzeuge umordnen") {
                ForEach(settings.preferences.primaryTools) { tool in Label(tool.title, systemImage: tool.symbol) }
                    .onMove { offsets, target in
                        var visible = settings.preferences.primaryTools
                        visible.move(fromOffsets: offsets, toOffset: target)
                        settings.preferences.reorderTools(visible)
                    }
            }
            Section {
                ForEach(settings.preferences.secondaryTools) { tool in Label(tool.title, systemImage: tool.symbol) }
                    .onMove { offsets, target in
                        var visible = settings.preferences.secondaryTools
                        visible.move(fromOffsets: offsets, toOffset: target)
                        settings.preferences.reorderTools(visible)
                    }
            } header: { Text("Zweite Ebene") } footer: { Text("Über den Pfeil am Ende der Werkzeugleiste, neben Lineal und Suche.") }
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
    }
}
