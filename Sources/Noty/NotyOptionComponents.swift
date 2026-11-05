import SwiftUI

// Building blocks of the attached tool option rows (`EditorToolOptions`),
// usable by other compact bars such as the law reader's. One grammar
// (feedback 22.10.2026): 44-pt cells, 18-pt symbols, the same selection
// plate, groups separated by the toolbar's thin divider, 13-pt labels. Colour
// and button style come from the surrounding bar (`NotyToolStyle`, white).

/// Toggle/choice cell with any glyph; selected cells get the common plate.
struct NotyGlyphOption<Glyph: View>: View {
    let title: String
    var selected = false
    var help: String? = nil
    let action: () -> Void
    let glyph: Glyph
    init(_ title: String, selected: Bool = false, help: String? = nil, action: @escaping () -> Void, @ViewBuilder glyph: () -> Glyph) {
        self.title = title; self.selected = selected; self.help = help; self.action = action; self.glyph = glyph()
    }
    var body: some View {
        Button(action: action) {
            glyph
                .frame(width: 44, height: 44).contentShape(Rectangle())
                .background(selected ? .white.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 10))
        }.accessibilityLabel(title).accessibilityAddTraits(selected ? .isSelected : []).notyTooltip(help ?? title)
    }
}

/// `NotyGlyphOption` with an SF Symbol.
struct NotySymbolOption: View {
    let title: String
    let symbol: String
    var selected = false
    var help: String? = nil
    let action: () -> Void
    init(_ title: String, symbol: String, selected: Bool = false, help: String? = nil, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.selected = selected; self.help = help; self.action = action
    }
    var body: some View {
        NotyGlyphOption(title, selected: selected, help: help, action: action) {
            Image(systemName: symbol).font(.system(size: 18))
        }
    }
}

/// Action with symbol and short label (no selection state), 44-pt target.
struct NotyLabeledOption: View {
    let title: String
    let symbol: String
    let help: String
    let action: () -> Void
    init(_ title: String, symbol: String, help: String, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.help = help; self.action = action
    }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 18)).frame(width: 24)
                Text(title).lineLimit(1)
            }
            .padding(.horizontal, 8).frame(minHeight: 44).contentShape(Rectangle())
        }.accessibilityLabel(help).notyTooltip(help)
    }
}

/// Colour dot with the same ring as the selected state elsewhere.
struct NotySwatch: View {
    let color: Color
    let selected: Bool
    let title: String
    let action: () -> Void
    init(_ color: Color, selected: Bool, title: String, action: @escaping () -> Void) {
        self.color = color; self.selected = selected; self.title = title; self.action = action
    }
    var body: some View {
        Button(action: action) {
            Circle().fill(color).frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(.white.opacity(selected ? 0.95 : 0.3), lineWidth: selected ? 2.5 : 1))
                .frame(width: 34, height: 44).contentShape(Rectangle())
        }.accessibilityLabel(title).accessibilityAddTraits(selected ? .isSelected : []).notyTooltip(title)
    }
}

/// Slider plus its value, e.g. a pen or eraser width.
struct NotyWidthSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    init(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) {
        self.title = title; _value = value; self.range = range; self.step = step
    }
    var body: some View {
        HStack(spacing: 6) {
            Slider(value: $value, in: range, step: step) { Text(title) }.frame(width: 90, height: 44)
            Text(value.formatted()).monospacedDigit().frame(minWidth: 25, alignment: .leading)
                .accessibilityHidden(true)
        }.notyTooltip(title)
    }
}

/// Thin group divider like in the toolbar and the selection bars.
struct NotyGroupDivider: View {
    var body: some View {
        Rectangle().fill(.white.opacity(0.14)).frame(width: 0.5, height: 18).padding(.horizontal, 2)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}
