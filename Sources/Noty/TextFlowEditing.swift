import UIKit
import NotebookCore

/// The same TextKit 1 glyph layout used by export/preview. Cut only between
/// complete visual lines and composed characters, never in an emoji/ligature.
@MainActor
enum TextFlowEditing {
    static func capacity(_ box: TextBox, page: Page) -> Int {
        // Laid out only as far as the page: `box` holds all the text behind it.
        let layout = TextObjectLayout(box, on: page, limitedTo: box.height)
        let source = box.text as NSString
        var end = 0
        layout.manager.enumerateLineFragments(forGlyphRange: layout.manager.glyphRange(for: layout.container)) { rect, _, _, glyphs, stop in
            guard rect.maxY * layout.coordinateScale <= box.height + 0.25 else { stop.pointee = true; return }
            let chars = layout.manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            end = NSMaxRange(chars)
        }
        end = min(end, source.length)
        if end < source.length, end > 0 {
            let cluster = source.rangeOfComposedCharacterSequence(at: end)
            if cluster.location < end { end = cluster.location }
        }
        return end
    }
    /// The empty line behind a final line break fits the segment's page.
    static func trailingLineFits(_ box: TextBox, page: Page) -> Bool {
        let layout = TextObjectLayout(box, on: page)
        let extra = layout.manager.extraLineFragmentRect
        return extra.height == 0 || extra.maxY * layout.coordinateScale <= box.height + 0.25
    }
}
