import SwiftUI
import UIKit

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
                .background(selected ? .white.opacity(NotyChrome.plateOpacity) : .clear, in: RoundedRectangle(cornerRadius: NotyChrome.plateRadius))
        }.accessibilityLabel(title).accessibilityAddTraits(selected ? .isSelected : []).notyTooltip(help ?? title, hint: help != nil)
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
        }.accessibilityLabel(help).notyTooltip(help, hint: false)
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
        }.accessibilityLabel(title).accessibilityAddTraits(selected ? .isSelected : []).notyTooltip(title, hint: false)
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
        }.notyTooltip(title, hint: false)
    }
}

/// One group divider for every dark bar, SwiftUI and UIKit alike
/// (polish audit F13): a hairline of fixed length, centred in the row.
enum NotyDivider {
    static let thickness: CGFloat = 0.5
    static let length: CGFloat = 20
    static let opacity: CGFloat = 0.18
    static var uiColor: UIColor { UIColor.white.withAlphaComponent(opacity) }

    /// UIKit divider for stack-based bars (selection bar, format bar).
    @MainActor static func makeView(vertical: Bool = false) -> UIView {
        let line = UIView(); line.backgroundColor = uiColor
        line.isUserInteractionEnabled = false; line.isAccessibilityElement = false
        line.widthAnchor.constraint(equalToConstant: vertical ? length : thickness).isActive = true
        line.heightAnchor.constraint(equalToConstant: vertical ? thickness : length).isActive = true
        return line
    }
}

/// Thin group divider like in the toolbar and the selection bars.
struct NotyGroupDivider: View {
    var body: some View {
        Rectangle().fill(.white.opacity(NotyDivider.opacity)).frame(width: NotyDivider.thickness, height: NotyDivider.length)
            .padding(.horizontal, 2)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Shared look of the dark chrome (polish audit F4/F20): the noty accent
/// marks "on/selected" and focus there; selected cells get the same white
/// plate; disabled items one dimming. Light lists keep the system accent
/// (#7DD3FC on white would be about 1.6:1).
enum NotyChrome {
    static let plateOpacity: CGFloat = 0.18
    static let plateRadius: CGFloat = 10
    static let disabledOpacity: CGFloat = 0.35
    static var plate: UIColor { UIColor.white.withAlphaComponent(plateOpacity) }
}

extension UIColor {
    /// `Color.notyAccent` for UIKit chrome.
    static let notyAccent = UIColor(red: 125 / 255, green: 211 / 255, blue: 252 / 255, alpha: 1)
}
