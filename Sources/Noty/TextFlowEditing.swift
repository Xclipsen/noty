import UIKit
import NotebookCore

/// The same TextKit 1 glyph layout used by export/preview. Cut only between
/// complete visual lines and composed characters, never in an emoji/ligature.
@MainActor
enum TextFlowEditing {
    static func capacity(_ box: TextBox) -> Int {
        let layout = TextObjectLayout(box)
        let source = box.text as NSString
        var end = 0
        layout.manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.manager.numberOfGlyphs)) { rect, _, _, glyphs, stop in
            guard rect.maxY <= box.height + 0.25 else { stop.pointee = true; return }
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
}
