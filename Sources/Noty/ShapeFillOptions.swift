import SwiftUI
import NotebookCore

/// Fill of new shapes in the shape tool's options (22.10.2026): own colour
/// (or „wie Strich“) and strength 10–100 %. Shown while „Füllung“ is on.
struct ShapeFillOptions: View {
    @Binding var options: ShapeToolOptions
    /// Current stroke colour of the tool (the fill follows it without own colour).
    let strokeColor: InkColor

    var body: some View {
        HStack(spacing: 8) {
            ColorPicker("Füllfarbe", selection: Binding(get: { (options.fillColor ?? strokeColor).opaque.color }, set: {
                options.fillColor = InkColor($0).opaque
            }), supportsOpacity: false).labelsHidden().frame(width: 44, height: 44)
                .accessibilityLabel("Füllfarbe")
            Button { options.fillColor = nil } label: {
                Image(systemName: "link").font(.system(size: 18))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
                    .background(options.fillColor == nil ? .white.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 10))
            }.accessibilityLabel("Füllung in Strichfarbe").accessibilityAddTraits(options.fillColor == nil ? .isSelected : [])
                .help("Füllung in Strichfarbe")
            Slider(value: Binding(get: { options.fillOpacity }, set: { options.fillOpacity = ShapeFill.rounded($0) }),
                   in: ShapeFill.opacityRange, step: 0.05) { Text("Deckkraft der Füllung") }.frame(width: 90, height: 44)
            Text(ShapeFill.percent(options.fillOpacity)).monospacedDigit().frame(minWidth: 38)
        }
    }
}

/// „Füllung“ in the style popover of selected shapes: on/off, colour and
/// strength. Every finished change is one undo step (`apply`).
struct ShapeFillStyleSection: View {
    struct Choice: Equatable {
        var filled: Bool
        /// nil: the fill follows each shape's stroke colour.
        var color: InkColor?
        var opacity: Double
    }
    @State var choice: Choice
    let apply: (Choice) -> Void

    static let palette: [(InkColor, String)] = [
        (InkColor(1, 0.8, 0), "Gelb"), (InkColor(1, 0.58, 0), "Orange"), (InkColor(1, 0.23, 0.19), "Rot"),
        (InkColor(1, 0.18, 0.33), "Pink"), (InkColor(0.2, 0.78, 0.35), "Grün"), (InkColor(0, 0.78, 0.75), "Mint"),
        (InkColor(0, 0.48, 1), "Blau"), (InkColor(0.69, 0.32, 0.87), "Lila"), (InkColor(0, 0, 0), "Schwarz"),
        (InkColor(0.33, 0.33, 0.33), "Dunkelgrau"), (InkColor(1, 1, 1), "Weiß"), (InkColor(0.6, 0.4, 0.2), "Braun")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Füllung", isOn: Binding(get: { choice.filled }, set: { choice.filled = $0; apply(choice) }))
                .font(.system(size: 17, weight: .semibold)).tint(.blue)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 6), count: 7), alignment: .leading, spacing: 6) {
                swatch(nil, name: "Wie Strich")
                ForEach(Self.palette, id: \.1) { swatch($0.0, name: $0.1) }
            }.disabled(!choice.filled).opacity(choice.filled ? 1 : 0.4)
            HStack {
                Text("Deckkraft").font(.system(size: 15))
                Slider(value: Binding(get: { choice.opacity }, set: { choice.opacity = ShapeFill.rounded($0) }),
                       in: ShapeFill.opacityRange, step: 0.05) { Text("Deckkraft der Füllung") } onEditingChanged: { editing in
                    if !editing { apply(choice) }
                }
                Text(ShapeFill.percent(choice.opacity)).monospacedDigit().frame(minWidth: 42, alignment: .trailing)
            }.disabled(!choice.filled).opacity(choice.filled ? 1 : 0.4)
        }.foregroundStyle(.white)
    }

    private func swatch(_ color: InkColor?, name: String) -> some View {
        let selected = choice.color.map { c in color.map { ShapeFill.sameHue(c, $0) } ?? false } ?? (color == nil)
        return Button { choice.color = color; apply(choice) } label: {
            ZStack {
                if let color { Circle().fill(color.color) }
                else { Circle().fill(.white.opacity(0.12)); Image(systemName: "link").font(.system(size: 13, weight: .semibold)) }
            }
            .frame(width: 30, height: 30)
            .overlay(Circle().strokeBorder(.white.opacity(selected ? 0.95 : 0.3), lineWidth: selected ? 2.5 : 1))
            .frame(width: 34, height: 34).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(color == nil ? "Füllung in Strichfarbe" : "Füllfarbe \(name)")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension InkColor {
    /// The same colour fully opaque (fill colours carry their strength separately).
    var opaque: InkColor { InkColor(red, green, blue, 1) }
}

extension ShapeFill {
    static func percent(_ opacity: Double) -> String { "\(Int((opacity * 100).rounded())) %" }
}
