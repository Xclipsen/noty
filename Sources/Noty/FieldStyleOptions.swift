import SwiftUI
import NotebookCore

/// „Feldstil“ of a selected text field (Textneubau Stufe 4): fill none or one
/// of six light colours, frame none / text colour / accent colour. Common
/// option grammar of `EditorToolOptions` (44-pt cells, 18-pt symbols, the
/// selection plate, hover names). Every choice is one undo step (`apply`).
struct FieldStyleOptions: View {
    struct Choice: Equatable {
        var fill: TextFieldFill?
        var border: TextFieldBorder?
    }
    @State var choice: Choice
    let apply: (Choice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Feldstil").font(.system(size: 17, weight: .semibold))
            Text("Füllung").font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.7))
            HStack(spacing: EditorToolOptions.itemSpacing) {
                cell("Keine Füllung", help: "Keine Füllung", selected: choice.fill == nil) {
                    choice.fill = nil
                } glyph: {
                    Image(systemName: "circle.slash").font(.system(size: 18))
                }
                ForEach(TextFieldFill.allCases, id: \.self) { fill in
                    cell("Füllung \(fill.title)", help: "Füllung \(fill.title)", selected: choice.fill == fill) {
                        choice.fill = fill
                    } glyph: {
                        Circle().fill(Color(uiColor: fill.uiColor)).frame(width: 24, height: 24)
                            .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                    }
                }
            }
            Text("Rahmen").font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.7)).padding(.top, 4)
            HStack(spacing: EditorToolOptions.itemSpacing) {
                cell("Kein Rahmen", help: "Kein Rahmen", selected: choice.border == nil) {
                    choice.border = nil
                } glyph: {
                    Image(systemName: "square.dashed").font(.system(size: 18))
                }
                cell("Rahmen in Textfarbe", help: "Rahmen in Textfarbe – dünn", selected: choice.border == .text) {
                    choice.border = .text
                } glyph: {
                    frameGlyph(.white)
                }
                cell("Rahmen in Akzentfarbe", help: "Rahmen in Akzentfarbe – dünn", selected: choice.border == .accent) {
                    choice.border = .accent
                } glyph: {
                    frameGlyph(Color(red: TextFieldBorder.accentRGB.red, green: TextFieldBorder.accentRGB.green,
                                     blue: TextFieldBorder.accentRGB.blue))
                }
            }
        }
        .padding(16).foregroundStyle(.white)
        .buttonStyle(NotyToolStyle())
        .environment(\.notyTooltipAxis, .horizontal)
        .notyTooltipHost()
        .accessibilityElement(children: .contain).accessibilityLabel("Feldstil")
    }

    private func frameGlyph(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 4).strokeBorder(color, lineWidth: 1.5).frame(width: 22, height: 16)
    }

    private func cell<Glyph: View>(_ title: String, help: String, selected: Bool, action: @escaping () -> Void,
                                   @ViewBuilder glyph: () -> Glyph) -> some View {
        Button {
            action(); apply(choice)
        } label: {
            glyph()
                .frame(width: 44, height: 44).contentShape(Rectangle())
                .background(selected ? .white.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 10))
        }.accessibilityLabel(title).accessibilityAddTraits(selected ? .isSelected : []).notyTooltip(help)
    }
}
