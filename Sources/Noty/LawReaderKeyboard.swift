import SwiftUI
import UIKit
import NotebookCore

extension LawReaderView {
    // MARK: Keys (docs/KEYBOARD.md, „Gesetzessammlung“)

    /// `laws.keyFocus` changed: `Space l`, ⌘L, ⇧⌘L, a tap or a field gave
    /// the window the keys. Registers the shortcuts (`LawKeyboard`) and, with
    /// the Helix mode on, the panel `GESETZE`. Also called from the reader's
    /// `onAppear` when the focus came first: the window's reader is created
    /// only once the window becomes visible (B14).
    func startKeys() {
        let keyboard = LawKeyboard.shared
        keyboard.attach(reader: LawReaderKeyActions(run: { runShortcut($0) }, selectionActive: { textSelection.active },
                                                    leave: { leaveHelixKeys() }), marks: markController)
        keyboard.markFocused()
        if let clearing = keyboard.takePendingSearch() { focusQuickSearch(clearing: clearing) } else { keyboard.claimSoon() }
        // Helix only in its mode; the shortcuts above work without it.
        let router = KeyboardRouter.shared
        guard router.isEnabled else { return }
        if let keyPanel { router.setTyping(keyPanel, false); return }
        let panel = KeyPanel(context: .law, label: "GESETZE")
        panel.leavesOnPageTouch = true
        panel.run = { runKey($0, count: $1) }
        panel.onLeave = {
            keyPanel = nil
            LawKeyboard.shared.blur()
        }
        keyPanel = panel
        router.enter(panel)
    }
    /// Hidden, closed or gone: the keys go back to the page.
    func leaveKeys() {
        LawKeyboard.shared.blur()
        leaveHelixKeys()
        LawKeyboard.shared.detachReader()
    }
    private func leaveHelixKeys() { if let keyPanel { KeyboardRouter.shared.leave(keyPanel) } }

    // MARK: Shortcuts (Core `LawShortcuts`)

    private func runShortcut(_ action: LawShortcuts.Action) {
        switch action {
        case .escape: escapeOneLevel()
        case .find: focusQuickSearch(clearing: false)
        case .hit(let forward):
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { focusQuickSearch(clearing: false) } else { followHit(forward: forward) }
        case .section(let delta): move(delta)
        case .scrollLines(let lines): textSelection.scroll(lines: lines)
        case .scrollScreens(let screens): textSelection.scroll(screens: 0.9 * Double(screens))
        case .edge(let end): textSelection.scrollToEdge(end: end)
        case .font(let step): changeFontSize(step)
        case .bookmark: toggleBookmark()
        case .chooseLaw: showLaws = true
        case .contents: showContents = true
        case .list: showBookmarks = true
        case .toggleView: Task { await togglePDF() }
        case .color(let number): markSelection(LawKeyboard.hex(number))
        case .lastColor: markSelection(markController.lastColor)
        case .removeMark: if textSelection.active { markController.removeSelection() }
        // The reader's own mark stack (never the notebook's undo); no step, no effect.
        case .undoMark: if markController.canUndo { markController.undo() }
        case .redoMark: if markController.canRedo { markController.redo() }
        default: break
        }
    }
    /// Esc, one level each: selection or chosen mark, then a field, then the
    /// open search surface, then the window.
    private func escapeOneLevel() {
        if textSelection.active || markController.adjusting != nil { markController.clearSelection(); return }
        // Quick search (`queryFocused`), then the paragraph field (a UITextField).
        if queryFocused { queryFocused = false; LawKeyboard.shared.claimSoon(); return }
        if let field = UIResponder.currentFirstResponder as? UITextField {
            field.resignFirstResponder(); LawKeyboard.shared.claimSoon(); return
        }
        if lookupShown != nil { NotyMotion.instant { closeLookup() }; LawKeyboard.shared.claimSoon(); return }
        LawKeyboard.shared.closeWindow()
    }
    /// ⌘L and ⌘F: the shared search surface opens in its search mode and
    /// takes the typing (`144 HGB` or words).
    private func focusQuickSearch(clearing: Bool) {
        if clearing { query = "" }
        textSelection.clear()
        // Keyboard-opened: no slide (tap paths in LawReaderControls stay animated).
        NotyMotion.instant { openLookup(.query) }
    }
    /// 1–5, ⇧⌘H, `m1`…`mm`: marks the text or PDF selection, recolours the
    /// chosen mark or finishes „Bereich anpassen“ (`LawMarkController.mark`,
    /// which also remembers the colour). `hex` nil: the pen's colour.
    private func markSelection(_ hex: String?) {
        guard textSelection.active || markController.adjusting != nil else { return }
        markController.mark(color: hex)
    }

    // MARK: Helix (`GESETZE`)

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
        case .confirm: followHit(forward: true)
        // Esc: a selection first, then the open search surface, then the
        // window closes (`Space l` closes at once).
        case .cancelPanel:
            if textSelection.active { textSelection.clear() } else if lookupShown != nil { NotyMotion.instant { closeLookup() } } else { LawKeyboard.shared.closeWindow() }
        case .laws: LawKeyboard.shared.closeWindow()
        case .lawPark: LawKeyboard.shared.parkWindow()
        case .lawChoose: showLaws = true
        case .lawContents: showContents = true
        case .lawBookmarks: showBookmarks = true
        case .bookmark: toggleBookmark()
        case .lawView: Task { await togglePDF() }
        case .zoom(let step): changeFontSize(step * times)
        case .lawColor(let number): runShortcut(.color(number))
        case .lawMark(let on): runShortcut(on ? .lastColor : .removeMark)
        case .undo: runShortcut(.undoMark)
        case .redo: runShortcut(.redoMark)
        default: break
        }
    }
    /// Enter, ⌘G, ⇧⌘G: the next or previous section with the searched words.
    private func followHit(forward: Bool) {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !term.isEmpty, let sections = document?.sections, let index = sections.firstIndex(where: { $0.id == sectionID }) else { return }
        let order = forward ? Array(sections[(index + 1)...]) + Array(sections[...index])
                            : Array(sections[..<index].reversed()) + Array(sections[index...].reversed())
        guard let found = order.first(where: { "\($0.label) \($0.title) \($0.text) \($0.notes)".lowercased().contains(term) }),
              let foundIndex = sections.firstIndex(where: { $0.id == found.id }) else {
            if KeyboardRouter.shared.isEnabled { KeyboardRouter.shared.show(note: "Kein Treffer") }
            else { loadError = "„\(query)“ wurde in \(entry?.abbr ?? "diesem Dokument") nicht gefunden." }
            return
        }
        textSelection.clear()
        pdfTarget = nil; sectionID = found.id; jumpParagraph = nil; loadError = ""
        follow(found, from: .query)
        if forward ? foundIndex <= index : foundIndex >= index { KeyboardRouter.shared.show(note: "Suche von vorn") }
    }
}

/// What the menu bar needs to know about the law window's reader for its
/// titles („Lesezeichen setzen“/„Lesezeichen entfernen“, „PDF zeigen“/
/// „Lesetext zeigen“); set by the visible window's `LawReaderView`.
@MainActor
final class LawReaderMenuState: ObservableObject {
    static let shared = LawReaderMenuState()
    @Published private(set) var bookmarked = false
    @Published private(set) var showsPDF = false
    func update(bookmarked: Bool, showsPDF: Bool) {
        if self.bookmarked != bookmarked { self.bookmarked = bookmarked }
        if self.showsPDF != showsPDF { self.showsPDF = showsPDF }
    }
}
