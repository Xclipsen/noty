import SwiftUI
import NotebookCore

extension LawReaderView {
    // MARK: Keyboard mode (docs/KEYBOARD.md)

    func startKeys() {
        let router = KeyboardRouter.shared
        if let keyPanel { router.setTyping(keyPanel, false); return }
        let panel = KeyPanel(context: .law, label: "GESETZE")
        panel.leavesOnPageTouch = true
        panel.run = { runKey($0, count: $1) }
        panel.onLeave = { keyPanel = nil }
        keyPanel = panel
        router.enter(panel)
    }
    func leaveKeys() { if let keyPanel { KeyboardRouter.shared.leave(keyPanel) } }
    private func close() {
        leaveKeys()
        withAnimation(NotyMotion.panel(reduceMotion)) { laws.stashed = true }
    }
    /// Quick search and paragraph are typed through the router into the
    /// reader's own fields, whose live lookup then does the rest.
    private func startInput(_ field: HelixLawField) {
        guard let keyPanel else { return }
        keyPanel.input = field == .query ? $query : $number
        keyPanel.inputSymbol = field == .query ? "/" : "§"
        if field == .paragraph { number = "" }
        inputField = field
        KeyboardRouter.shared.setTyping(keyPanel, true)
    }
    private func runKey(_ action: HelixAction, count: Int?) {
        let times = count ?? 1
        if let keyPanel, keyPanel.typing {
            switch action {
            case .confirm:
                KeyboardRouter.shared.setTyping(keyPanel, false)
                let field: LawLookupField = inputField == .query ? .query : .number
                let value = inputField == .query ? query : number
                Task { await search(value, allowFullText: true, from: field) }
            case .cancelPanel:
                KeyboardRouter.shared.setTyping(keyPanel, false)
                // The field follows the reader again, as after any lookup.
                if inputField == .paragraph { number = section?.keys.first ?? "" }
            default: break
            }
            return
        }
        switch action {
        case .scroll(_, let y): textSelection.scroll(lines: y * times)
        case .scrollScreen(let fraction): textSelection.scroll(screens: fraction * Double(times))
        case .firstPage: textSelection.scrollToEdge(end: false)
        case .lastPage: textSelection.scrollToEdge(end: true)
        case .page(let delta): for _ in 0..<times { move(delta) }
        case .gotoPage:
            if let count { Task { await search(String(count), from: .number) } } else { startInput(.paragraph) }
        case .lawField(let field): startInput(field)
        case .confirm: followNextHit()
        case .cancelPanel, .laws: close()
        case .lawChoose: showLaws = true
        case .lawContents: showContents = true
        case .lawBookmarks: showBookmarks = true
        case .bookmark: toggleBookmark()
        case .lawView: Task { await togglePDF() }
        case .zoom(let step): if !viewPDF { fontSize = min(32, max(12, fontSize + Double(step * 2))) }
        case .lawMark(let on):
            if on, textSelection.range.length > 0 { mark(textSelection.range) }
            else if !on, !textSelection.marks.isEmpty { unmark(textSelection.marks) }
        default: break
        }
    }
    /// Enter in the reader: the next section with the searched words.
    private func followNextHit() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !term.isEmpty, let sections = document?.sections, let index = sections.firstIndex(where: { $0.id == sectionID }) else { return }
        let order = sections[(index + 1)...] + sections[...index]
        guard let found = order.first(where: { "\($0.label) \($0.title) \($0.text) \($0.notes)".lowercased().contains(term) }) else {
            KeyboardRouter.shared.show(note: "Kein Treffer"); return
        }
        textSelection.clear()
        pdfTarget = nil; sectionID = found.id; jumpParagraph = nil; loadError = ""
        if found.id == sections[index].id { KeyboardRouter.shared.show(note: "Suche von vorn") }
    }
}
