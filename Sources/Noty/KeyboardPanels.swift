import SwiftUI
import UIKit
import GameController
import NotebookCore

/// A part of the app with keys of its own (docs/KEYBOARD.md): the sidebar, a
/// sheet, the law reader, a question. While one is open its context decides
/// what keys mean; the newest open one has them. Sheets bring a responder
/// (`KeyPanelHostView`), everything else takes the keys from whoever has them.
@MainActor
final class KeyPanel: Identifiable {
    let context: HelixContext
    /// Shown beside the mode.
    let label: String
    /// Lives in a sheet: the keys need a responder there.
    let ownsResponder: Bool
    /// The page was used with touch or Pencil: the keys belong to it again.
    var leavesOnPageTouch = false
    var run: @MainActor (HelixAction, Int?) -> Void
    /// What the palette offers here beside the key bindings.
    var commands: () -> [PaletteCommand] = { [] }
    var onLeave: (@MainActor () -> Void)?
    /// The text keys go to while `typing`; a dialog shows it in its own field.
    var input: Binding<String>?
    /// Without an own field the input line shows the text, under this sign.
    var inputSymbol: String?
    /// Letters without a binding start typing: search lists.
    var typesUnbound = false
    fileprivate(set) var typing = false
    weak var host: KeyPanelHostView?

    init(context: HelixContext, label: String, ownsResponder: Bool = false, run: @escaping @MainActor (HelixAction, Int?) -> Void = { _, _ in }) {
        self.context = context; self.label = label; self.ownsResponder = ownsResponder; self.run = run
    }
}

/// Yes or no with keys: touch keeps the system dialogs, a question raised by
/// a key stays in the app, so that nothing has to win the responder back.
struct KeyQuestion: Identifiable {
    struct Option: Identifiable {
        let id = UUID()
        let title: String
        var destructive = false
        var run: () -> Void = {}
    }
    let id = UUID()
    let title: String
    let message: String
    var options: [Option]
    var chosen: UUID
}

/// One entry of the colour and stroke panel.
struct KeyChoiceItem: Identifiable {
    let id = UUID()
    let title: String
    var color: Color?
    let apply: () -> Void
}
struct KeyChoiceRow: Identifiable {
    let id = UUID()
    let title: String
    let items: [KeyChoiceItem]
    /// Colour palettes wrap into rows of this many.
    static func rows(_ title: String, _ items: [KeyChoiceItem], width: Int) -> [KeyChoiceRow] {
        stride(from: 0, to: items.count, by: width).map { start in
            KeyChoiceRow(title: start == 0 ? title : "", items: Array(items[start..<min(start + width, items.count)]))
        }
    }
}
struct KeyChoices {
    let title: String
    let rows: [KeyChoiceRow]
    var cursor: KeyChoiceCursor
}

extension KeyboardRouter {
    var activePanel: KeyPanel? { panels.active }
    /// The newest panel with a responder: a sheet, also under a question.
    var sheetPanel: KeyPanel? { panels.last { $0.ownsResponder } }
    /// A hardware keyboard is there, or was used; without one sheets stay as they are.
    var hasKeyboard: Bool { keyboardSeen || GCKeyboard.coalesced != nil }

    func enter(_ panel: KeyPanel) {
        panels.enter(panel)
        panelChanged()
        if panel.ownsResponder { reclaim() }
    }
    func leave(_ panel: KeyPanel) {
        guard panels.leave(panel) else { return }
        panel.typing = false
        panel.onLeave?()
        panelChanged()
        // A closing sheet took the responder along, whatever closed it.
        reclaim()
    }
    func panelChanged() {
        dropSequence()
        panelRevision &+= 1
        refreshLabel()
    }
    func setTyping(_ panel: KeyPanel, _ typing: Bool) {
        guard panel.typing != typing else { return }
        panel.typing = typing
        panelChanged()
    }
    /// Touch or Pencil on the page, a tap into a text: panels over the page give the keys back.
    func pageTouched() {
        for panel in panels.panels.reversed() where panel.leavesOnPageTouch { leave(panel) }
    }
    /// The editor or library changed place: what was opened by a key over it is gone.
    func dropQuestions() {
        for panel in panels.panels.reversed() where !panel.ownsResponder { leave(panel) }
    }

    /// A key while a panel's line is open. True: used.
    func panelKey(_ token: String, _ panel: KeyPanel) -> Bool {
        guard let input = panel.input else { return false }
        switch KeyInputLine.apply(token, to: input.wrappedValue) {
        case .text(let value): input.wrappedValue = value; panelRevision &+= 1
        case .submit: panel.run(.confirm, nil)
        case .cancel: panel.run(.cancelPanel, nil)
        case .step(let delta): panel.run(.listMove(delta), nil)
        case .ignored: break
        }
        return true
    }
    /// A letter a search list has no use for goes on into its line.
    func typeUnbound(_ token: String) -> Bool {
        guard let panel = activePanel, panel.typesUnbound, panel.input != nil, token.count == 1 || token == "<BS>" else { return false }
        setTyping(panel, true)
        return panelKey(token, panel)
    }
    /// ⌘V while a panel's line is open.
    func pasteIntoPanel() {
        guard let panel = activePanel, panel.typing, let input = panel.input, let text = UIPasteboard.general.string else { return }
        input.wrappedValue = KeyInputLine.pasted(text, to: input.wrappedValue)
        panelRevision &+= 1
    }

    /// Yes or no over whatever is open. `safe`: Enter alone does not do what
    /// cannot be undone, `Abbrechen` is chosen then.
    func ask(_ title: String, message: String, confirm: String, destructive: Bool = true, safe: Bool = false, run: @escaping () -> Void) {
        let yes = KeyQuestion.Option(title: confirm, destructive: destructive, run: run), no = KeyQuestion.Option(title: "Abbrechen")
        present(KeyQuestion(title: title, message: message, options: [yes, no], chosen: safe ? no.id : yes.id))
    }
    func present(_ open: KeyQuestion) {
        question = open
        let panel = KeyPanel(context: .dialog, label: "RÜCKFRAGE")
        panel.run = { [weak self, weak panel] action, _ in
            guard let self, let panel, let open = self.question else { return }
            let ids = open.options.map(\.id)
            switch action {
            case .listMove(let delta), .adjustOption(let delta):
                self.question?.chosen = KeyOptionRing.step(from: open.chosen, by: delta, in: ids) ?? open.chosen
            case .confirm, .toggleOption:
                let chosen = open.options.first { $0.id == open.chosen }
                self.leave(panel)
                chosen?.run()
            case .cancelPanel: self.leave(panel)
            default: break
            }
        }
        panel.onLeave = { [weak self] in self?.question = nil }
        enter(panel)
    }
    /// A tap on a question: an option, or nil beside it.
    func handleQuestionTap(_ option: UUID?) {
        guard let panel = activePanel, panel.label == "RÜCKFRAGE" else { return }
        if let option { question?.chosen = option; panel.run(.confirm, nil) } else { panel.run(.cancelPanel, nil) }
    }
    /// One line of text in the input line (a name): Enter takes it, Esc does not.
    func askText(_ title: String, value: String = "", confirm: @escaping (String) -> Void) {
        var text = value
        let panel = KeyPanel(context: .dialog, label: "EINGABE")
        panel.inputSymbol = title
        panel.input = Binding(get: { text }, set: { text = $0 })
        panel.run = { [weak self, weak panel] action, _ in
            guard let self, let panel else { return }
            switch action {
            case .confirm:
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                self.leave(panel)
                confirm(text)
            case .cancelPanel: self.leave(panel)
            default: break
            }
        }
        enter(panel)
        setTyping(panel, true)
    }
    /// The colour and stroke panel. Moving only shows; Enter or a digit chooses.
    func openChoices(_ title: String, rows: [KeyChoiceRow]) {
        guard !rows.isEmpty else { return }
        choices = KeyChoices(title: title, rows: rows, cursor: KeyChoiceCursor(rows: rows.map(\.items.count)))
        let panel = KeyPanel(context: .color, label: "FARBE")
        panel.leavesOnPageTouch = true
        panel.run = { [weak self, weak panel] action, _ in
            guard let self, let panel, let open = self.choices else { return }
            @MainActor func choose(_ cursor: KeyChoiceCursor) {
                let item = open.rows[cursor.row].items[cursor.column]
                self.leave(panel)
                item.apply()
            }
            switch action {
            case .focusItem(let dx, let dy): self.choices?.cursor.move(dx: dx, dy: dy)
            case .pickEntry(let number):
                var cursor = open.cursor
                if cursor.pick(number) { choose(cursor) }
            case .confirm: choose(open.cursor)
            case .cancelPanel: self.leave(panel)
            default: break
            }
        }
        panel.onLeave = { [weak self] in self?.choices = nil }
        enter(panel)
    }
}

/// Keys inside a sheet: stays first responder like the library's host, until a
/// text field is tapped. Esc, Tab, Enter, the space bar and the arrows also
/// come as key commands, or the focus system of a list would take them.
final class KeyPanelHostView: UIView {
    weak var panel: KeyPanel? { didSet { panel?.host = self } }
    override var canBecomeFirstResponder: Bool { true }
    private var observing = false
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        panel?.host = self
        KeyboardRouter.shared.reclaim()
        guard !observing else { return }
        observing = true
        // A tapped field finished, or a keyboard was attached with the sheet open.
        for name in [UITextField.textDidEndEditingNotification, UITextView.textDidEndEditingNotification, .GCKeyboardDidConnect] {
            NotificationCenter.default.addObserver(self, selector: #selector(focusChanged), name: name, object: nil)
        }
    }
    @objc private func focusChanged() { KeyboardRouter.shared.reclaim() }
    private var controller: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }
    /// A question over the sheet is the system's until it closes; a field the
    /// user tapped keeps its keys; a text below a sheet has lost them already.
    func claim() {
        let router = KeyboardRouter.shared
        guard window != nil, !isFirstResponder, router.isEnabled, router.hasKeyboard, controller?.presentedViewController == nil else { return }
        if let current = UIResponder.currentFirstResponder, current is UIKeyInput, !(current is any KeyboardTextTarget) { return }
        becomeFirstResponder()
    }
    /// The list of this sheet, for options outside the visible part.
    var scrollView: UIScrollView? {
        var best: UIScrollView?
        func walk(_ view: UIView) {
            if let scroll = view as? UIScrollView, scroll.contentSize.height > 0, scroll.bounds.height > (best?.bounds.height ?? 0) { best = scroll }
            view.subviews.forEach(walk)
        }
        controller?.view.map(walk)
        return best
    }
    private static let commands: [UIKeyCommand] = {
        let plain = [UIKeyCommand.inputEscape, "\t", "\r", " ", UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow]
        let inputs = plain.map { ($0, UIKeyModifierFlags()) } + [("\t", UIKeyModifierFlags.shift)]
        return inputs.map { input, flags in
            let command = UIKeyCommand(input: input, modifierFlags: flags, action: #selector(keyCommand(_:)))
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }()
    override var keyCommands: [UIKeyCommand]? {
        KeyboardRouter.shared.isEnabled ? (super.keyCommands ?? []) + Self.commands : super.keyCommands
    }
    @objc private func keyCommand(_ command: UIKeyCommand) {
        let token: String? = switch command.input {
        case UIKeyCommand.inputEscape: "<Esc>"
        case "\t": command.modifierFlags.contains(.shift) ? "<S-Tab>" : "<Tab>"
        case "\r": "<CR>"
        case " ": "<Space>"
        case UIKeyCommand.inputUpArrow: "<Up>"
        case UIKeyCommand.inputDownArrow: "<Down>"
        case UIKeyCommand.inputLeftArrow: "<Left>"
        case UIKeyCommand.inputRightArrow: "<Right>"
        default: nil
        }
        if let token { KeyboardRouter.shared.handle(token: token) }
    }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        action == #selector(paste(_:)) ? KeyboardRouter.shared.activePanel?.typing == true && UIPasteboard.general.hasStrings
            : super.canPerformAction(action, withSender: sender)
    }
    override func paste(_ sender: Any?) { KeyboardRouter.shared.pasteIntoPanel() }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !KeyboardRouter.shared.handle(presses) { super.pressesBegan(presses, with: event) }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !KeyboardRouter.shared.pressEnded(presses) { super.pressesEnded(presses, with: event) }
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !KeyboardRouter.shared.pressEnded(presses) { super.pressesCancelled(presses, with: event) }
    }
}

/// A switch that takes part in the keys of its sheet.
@MainActor func keyToggle(_ title: String, isOn: Binding<Bool>) -> some View {
    Toggle(title, isOn: isOn).keyOption(.toggle(isOn))
}

struct KeyPanelHost: UIViewRepresentable {
    let panel: KeyPanel
    func makeUIView(context: Context) -> KeyPanelHostView {
        let view = KeyPanelHostView()
        view.panel = panel
        return view
    }
    func updateUIView(_ view: KeyPanelHostView, context: Context) { view.panel = panel }
}

// MARK: Dialogs

/// What the keys do to one control of a dialog.
enum KeyOption {
    case action(() -> Void)
    case toggle(Binding<Bool>)
    case step((Int) -> Void)
    /// Keys type into this field; `Tab` and the arrows leave it.
    case text(Binding<String>)

    static func choice<Value: Equatable>(_ binding: Binding<Value>, _ values: [Value]) -> KeyOption {
        .step { binding.wrappedValue = KeyChoice.stepped(binding.wrappedValue, by: $0, in: values) }
    }
    static func slider(_ binding: Binding<Double>, in range: ClosedRange<Double>, step: Double) -> KeyOption {
        .step { binding.wrappedValue = KeyChoice.stepped(binding.wrappedValue, by: $0, in: range, step: step) }
    }
}

/// The options of one sheet or settings page. Every control says with
/// `keyOption` what it is; where it stands decides the order, so that a new
/// control needs no list to be kept. Rows of a long list only exist while
/// visible: at the last one the list scrolls and the walk goes on.
@MainActor
final class KeyOptionScope: ObservableObject {
    private struct Entry { var option: KeyOption; var enabled = true }
    @Published private(set) var focused: UUID?
    private var entries: [UUID: Entry] = [:]
    /// Apart from `entries`: the first report may come before the control appeared.
    private var frames: [UUID: CGRect] = [:]
    private var onDefault: (() -> Void)?
    private var onCancel: () -> Void = {}
    func configure(onDefault: (() -> Void)?, onCancel: @escaping () -> Void) { self.onDefault = onDefault; self.onCancel = onCancel }
    private(set) lazy var panel: KeyPanel = {
        let panel = KeyPanel(context: .dialog, label: "DIALOG", ownsResponder: true)
        panel.run = { [weak self] action, count in self?.run(action, count: count ?? 1) }
        return panel
    }()

    func show(_ id: UUID, _ option: KeyOption) {
        if entries[id] == nil { entries[id] = Entry(option: option) }
    }
    func hide(_ id: UUID) { entries[id] = nil }
    func update(_ id: UUID, _ option: KeyOption, enabled: Bool) {
        entries[id]?.option = option; entries[id]?.enabled = enabled
    }
    func place(_ id: UUID, _ frame: CGRect) { frames[id] = frame }

    private var order: [UUID] {
        KeyOptionRing.order(entries.map { id, entry in
            let frame = frames[id] ?? .zero
            return .init(id: id, x: frame.minX, y: frame.minY, enabled: entry.enabled)
        })
    }
    /// With a keyboard a dialog that starts with a field starts in it.
    func start() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, self.focused == nil, KeyboardRouter.shared.hasKeyboard, KeyboardRouter.shared.isEnabled,
                  let first = self.order.first, case .text = self.entries[first]?.option else { return }
            self.focus(first)
        }
    }
    private func focus(_ id: UUID) {
        focused = id
        let router = KeyboardRouter.shared
        if case .text(let binding)? = entries[id]?.option {
            panel.input = binding
            router.setTyping(panel, true)
        } else { router.setTyping(panel, false) }
        reveal(id)
    }
    private func walk(_ delta: Int) {
        let scroll = panel.host?.scrollView
        if let next = KeyOptionRing.step(from: focused, by: delta, in: order, wraps: false) { focus(next); return }
        if let scroll, canScroll(scroll, delta) {
            scrollPage(scroll, delta)
            // The next rows have to appear first.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(130))
                guard let self else { return }
                if let next = KeyOptionRing.step(from: self.focused, by: delta, in: self.order) { self.focus(next) }
            }
            return
        }
        if let next = KeyOptionRing.step(from: focused, by: delta, in: order) { focus(next) }
    }
    private func canScroll(_ scroll: UIScrollView, _ delta: Int) -> Bool {
        let inset = scroll.adjustedContentInset
        return delta > 0 ? scroll.contentOffset.y + scroll.bounds.height - inset.bottom < scroll.contentSize.height - 1
            : scroll.contentOffset.y + inset.top > 1
    }
    private func scrollPage(_ scroll: UIScrollView, _ delta: Int) {
        move(scroll, by: scroll.bounds.height * 0.7 * (delta > 0 ? 1 : -1))
    }
    private func move(_ scroll: UIScrollView, by distance: CGFloat) {
        let inset = scroll.adjustedContentInset
        let limit = max(-inset.top, scroll.contentSize.height - scroll.bounds.height + inset.bottom)
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: min(limit, max(-inset.top, scroll.contentOffset.y + distance))), animated: false)
    }
    /// Keeps the chosen control on screen.
    private func reveal(_ id: UUID) {
        guard let frame = frames[id], let scroll = panel.host?.scrollView else { return }
        let area = scroll.convert(scroll.bounds, to: nil).inset(by: scroll.adjustedContentInset)
        if frame.maxY > area.maxY { move(scroll, by: frame.maxY - area.maxY + 16) }
        else if frame.minY < area.minY { move(scroll, by: frame.minY - area.minY - 16) }
    }
    private func run(_ action: HelixAction, count: Int) {
        switch action {
        case .listMove(let delta): for _ in 0..<min(count, 50) { walk(delta) }
        case .listFirst: if let first = order.first { focus(first) }
        case .listLast: if let last = order.last { focus(last) }
        case .confirm:
            if let focused, case .action(let action)? = entries[focused]?.option { action() }
            else { onDefault?() }
        case .toggleOption: adjust(1, activates: true)
        case .adjustOption(let delta): adjust(delta * count, activates: false)
        case .cancelPanel: onCancel()
        default: break
        }
    }
    private func adjust(_ delta: Int, activates: Bool) {
        guard let focused else { return }
        switch entries[focused]?.option {
        case .action(let action)?: if activates { action() }
        case .toggle(let binding)?: binding.wrappedValue.toggle()
        case .step(let step)?: step(delta)
        default: break
        }
    }
}

private struct KeyOptionScopeKey: EnvironmentKey { static let defaultValue: KeyOptionScope? = nil }
extension EnvironmentValues {
    var keyOptionScope: KeyOptionScope? {
        get { self[KeyOptionScopeKey.self] }
        set { self[KeyOptionScopeKey.self] = newValue }
    }
}

private struct KeyOptionModifier: ViewModifier {
    let option: KeyOption
    @Environment(\.keyOptionScope) private var scope
    func body(content: Content) -> some View {
        if let scope { content.modifier(Registered(option: option, scope: scope)) } else { content }
    }
    private struct Registered: ViewModifier {
        let option: KeyOption
        @ObservedObject var scope: KeyOptionScope
        @Environment(\.isEnabled) private var enabled
        @State private var id = UUID()
        func body(content: Content) -> some View {
            let _ = scope.update(id, option, enabled: enabled)
            content
                .overlay {
                    if scope.focused == id {
                        RoundedRectangle(cornerRadius: 8).strokeBorder(.tint, lineWidth: 2).padding(-4).allowsHitTesting(false)
                    }
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { scope.place(id, $0) }
                .onAppear { scope.show(id, option); scope.update(id, option, enabled: enabled) }
                .onDisappear { scope.hide(id) }
        }
    }
}

private struct KeyboardSheetModifier: ViewModifier {
    var onDefault: (() -> Void)?
    var onCancel: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var scope = KeyOptionScope()
    private var cancel: () -> Void { onCancel ?? { dismiss() } }
    func body(content: Content) -> some View {
        let _ = scope.configure(onDefault: onDefault, onCancel: cancel)
        content
            .environment(\.keyOptionScope, scope)
            .background(KeyPanelHost(panel: scope.panel).frame(width: 0, height: 0).accessibilityHidden(true))
            .background { KeyEscapeButton(fallback: cancel) }
            .overlay { KeyboardOverlay(scope: .library, panel: scope.panel.id) }
            .onAppear { KeyboardRouter.shared.enter(scope.panel); scope.start() }
            .onDisappear { KeyboardRouter.shared.leave(scope.panel) }
    }
}

/// Esc where no responder of the router has the keys (a tapped field), the
/// same way as the rest, so that one press stays one.
struct KeyEscapeButton: View {
    let fallback: () -> Void
    var body: some View {
        Button("") { if !KeyboardRouter.shared.handle(token: "<Esc>") { fallback() } }
            .keyboardShortcut(.cancelAction).frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
    }
}

extension View {
    /// This control takes part in the keys of its sheet.
    func keyOption(_ option: KeyOption) -> some View { modifier(KeyOptionModifier(option: option)) }
    /// A sheet or page with the common keys: `Tab`, `j`/`k`, Enter, Esc, space
    /// bar. Enter on no action is `onDefault`; Esc is `onCancel`, otherwise
    /// `dismiss`, which leaves a pushed page and closes a sheet.
    func keyboardSheet(onDefault: (() -> Void)? = nil, onCancel: (() -> Void)? = nil) -> some View {
        modifier(KeyboardSheetModifier(onDefault: onDefault, onCancel: onCancel))
    }
}
