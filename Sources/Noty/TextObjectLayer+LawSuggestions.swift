// Tippvorschlag (docs/PARAGRAPH-LINKS.md, P2): steht vor der Schreibmarke ein
// bloßes „§ 35a“, zeigt die Formatleiste über der Tastatur bis zu drei Gesetze.
// Ein Tipp ergänzt „ EStG“ als eigener Rückgängig-Schritt; Fokus und Marke
// bleiben. Erkennung: billiges Muster an der Marke, danach entprellt der
// Erkenner aus Core (kein Gesetz davor oder dahinter, zuletzt genanntes Gesetz).
import UIKit
import Combine
import NotebookCore

/// Per text layer: the pending check and what the strip shows.
@MainActor
final class LawSuggestionState {
    var work: DispatchWorkItem?
    /// Field, trigger and the field's text the chips were made for.
    var shown: (fieldID: UUID, trigger: LawSuggestionTrigger, text: String)?
    var strip: LawSuggestionStrip?
    var indexWatch: AnyCancellable?
    /// The trigger the last check ran for (also without chips): an index
    /// that arrives later checks it again.
    var pending: (fieldID: UUID, trigger: LawSuggestionTrigger)?
    /// × closed the chips for this citation (field, start): they stay away
    /// while the caret stays behind it.
    var dismissed: (fieldID: UUID, location: Int)?
    /// Delay after the last keystroke before the scanner runs.
    static let delay: TimeInterval = 0.28
}

extension TextObjectLayer {
    /// Default law and whether links are on, from the page this layer belongs to.
    private var lawPage: (enabled: Bool, defaultLawID: String?) {
        var view: UIView? = superview
        while let current = view {
            if let sheet = current as? WorksheetView, let configuration = sheet.configuration {
                return (configuration.lawCitations, configuration.lawContext.defaultLawID)
            }
            view = current.superview
        }
        return (false, nil)
    }

    /// After every text change of a classic field (`textViewDidChange`).
    func lawSuggestionTextChanged(_ editor: PageTextView) {
        let state = lawSuggestion
        state.work?.cancel(); state.work = nil
        guard let trigger = quickLawTrigger(editor) else { state.dismissed = nil; hideLawSuggestions(); return }
        let id = editor.objectID
        if let dismissed = state.dismissed {
            guard dismissed.fieldID == id, dismissed.location == trigger.range.location else { state.dismissed = nil; return scheduleLaw(trigger, editor) }
            return
        }
        scheduleLaw(trigger, editor)
    }

    private func scheduleLaw(_ trigger: LawSuggestionTrigger, _ editor: PageTextView) {
        let state = lawSuggestion
        let id = editor.objectID
        let work = DispatchWorkItem { [weak self, weak editor] in
            guard let self, let editor, self.fields[id]?.editor === editor else { return }
            self.refreshLawSuggestions(editor, expected: trigger)
        }
        state.work = work
        DispatchQueue.main.asyncAfter(deadline: .now() + LawSuggestionState.delay, execute: work)
    }

    /// Caret moved (`textViewDidChangeSelection`): the chips stay only while
    /// the caret still stands right behind the same citation.
    func lawSuggestionSelectionChanged(_ editor: PageTextView) {
        let state = lawSuggestion
        guard let shown = state.shown else { return }
        guard shown.fieldID == editor.objectID, let trigger = quickLawTrigger(editor),
              trigger.range.location == shown.trigger.range.location else { hideLawSuggestions(); return }
    }

    func hideLawSuggestions() {
        let state = lawSuggestion
        state.work?.cancel(); state.work = nil
        state.shown = nil; state.pending = nil; state.indexWatch = nil
        state.strip?.isHidden = true
    }

    /// × on the strip: hidden, and not shown again for this citation.
    private func dismissLawSuggestions() {
        let state = lawSuggestion
        if let shown = state.shown { state.dismissed = (shown.fieldID, shown.trigger.range.location) }
        hideLawSuggestions()
    }

    /// The cheap check, on every keystroke: only plain typing at a caret.
    private func quickLawTrigger(_ editor: PageTextView) -> LawSuggestionTrigger? {
        guard active, editor.isFirstResponder, editor.markedTextRange == nil, editor.selectedRange.length == 0,
              KeyboardRouter.shared.allowsTyping, LawCitationPreviewModel.shared.scanner != nil else { return nil }
        return LawSuggestionTrigger.find(in: editor.textStorage.string as NSString, caret: editor.selectedRange.location)
    }

    private func refreshLawSuggestions(_ editor: PageTextView, expected: LawSuggestionTrigger) {
        guard let trigger = quickLawTrigger(editor), trigger == expected,
              let scanner = LawCitationPreviewModel.shared.scanner else { hideLawSuggestions(); return }
        let page = lawPage
        guard page.enabled else { hideLawSuggestions(); return }
        let text = editor.textStorage.string as NSString
        // The paragraph-sized neighbourhood: a law written right before or
        // behind the number („EStG § 35a“, „§ 35a EStG“) means no chips, and
        // the last law named before it ranks second.
        var start = max(0, trigger.range.location - 4000)
        if start > 0 { start = text.rangeOfComposedCharacterSequence(at: start).location }
        var end = min(text.length, trigger.caret + 24)
        if end < text.length { end = NSMaxRange(text.rangeOfComposedCharacterSequence(at: end)) }
        let window = text.substring(with: NSRange(location: start, length: end - start))
        let local = NSRange(location: trigger.range.location - start, length: trigger.range.length)
        let found = scanner.citations(in: window, defaultLawID: nil)
        if found.contains(where: { !$0.inferredLaw && NSIntersectionRange($0.range, local).length > 0 }) { hideLawSuggestions(); return }
        let model = LawSuggestionModel.shared
        let previous = found.last(where: { !$0.inferredLaw && $0.range.location < local.location
            && model.entry($0.lawID)?.kind != "administration" })?.lawID
        let suggestions = model.suggestions(key: trigger.key, defaultLawID: page.defaultLawID, previousLawID: previous)
        watchLawIndex(editor, trigger: trigger)
        guard !suggestions.isEmpty else {
            lawSuggestion.shown = nil; lawSuggestion.strip?.isHidden = true
            return
        }
        showLawSuggestions(suggestions, trigger: trigger, editor: editor)
    }

    /// Section titles or the offline check still running: the same trigger is
    /// checked again when they arrive (chips appear or get their titles).
    private func watchLawIndex(_ editor: PageTextView, trigger: LawSuggestionTrigger) {
        let state = lawSuggestion
        state.pending = (editor.objectID, trigger)
        guard state.indexWatch == nil else { return }
        state.indexWatch = LawSuggestionModel.shared.$indexGeneration.dropFirst()
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self, weak editor] _ in
                MainActor.assumeIsolated {
                    guard let self, let editor, let pending = self.lawSuggestion.pending, pending.fieldID == editor.objectID,
                          self.fields[pending.fieldID]?.editor === editor else { return }
                    self.refreshLawSuggestions(editor, expected: pending.trigger)
                }
            }
    }

    private func showLawSuggestions(_ suggestions: [LawSuggestion], trigger: LawSuggestionTrigger, editor: PageTextView) {
        let state = lawSuggestion
        // Only over the bar's leading style menus („Textstil“, „Schrift“) as
        // they stand now; the format buttons right of them stay uncovered.
        let room = lawSuggestionRoom
        guard room >= 150 else { state.shown = nil; state.strip?.isHidden = true; return }
        state.shown = (editor.objectID, trigger, editor.textStorage.string)
        let strip = state.strip ?? {
            let made = LawSuggestionStrip()
            self.accessory.addSubview(made)
            made.pin(to: self.accessory)
            state.strip = made
            return made
        }()
        strip.onClose = { [weak self] in self?.dismissLawSuggestions() }
        strip.show(suggestions, width: room) { [weak self] lawID in self?.acceptLawSuggestion(lawID) }
        accessory.bringSubviewToFront(strip)
    }

    /// Visible width of the bar's leading style menus (up to the end of
    /// „Schrift“); less when the bar is scrolled.
    private var lawSuggestionRoom: CGFloat {
        guard let font = buttons["Schrift"], font.window != nil else { return 0 }
        accessory.layoutIfNeeded()
        // In bar coordinates, so a scrolled bar leaves less room.
        let end = font.convert(font.bounds, to: accessory).maxX + 2
        return min(end, accessory.bounds.width - 120)
    }

    /// Chip tapped: „ EStG“ behind the citation, one undo step of its own;
    /// the field keeps focus, the caret stays behind what was typed.
    private func acceptLawSuggestion(_ lawID: String) {
        let state = lawSuggestion
        guard let shown = state.shown, let entry = LawSuggestionModel.shared.entry(lawID),
              let editor = fields[shown.fieldID]?.editor, editor.isFirstResponder, editor.markedTextRange == nil,
              editor.textStorage.string == shown.text, editor.selectedRange == NSRange(location: shown.trigger.caret, length: 0),
              let index = boxes.firstIndex(where: { $0.id == shown.fieldID }) else { hideLawSuggestions(); return }
        hideLawSuggestions()
        let edit = TextListEditing.Edit(range: NSRange(location: NSMaxRange(shown.trigger.range), length: 0), replacement: " " + entry.abbr)
        onUndoBoundary?()
        applyListEdits([edit], at: index, editor: editor)
        onUndoBoundary?()
    }
}

/// The chips at the leading edge of the format bar, above its buttons.
@MainActor
final class LawSuggestionStrip: UIView {
    private let stack = UIStackView()
    private var choose: ((String) -> Void)?
    var onClose: (() -> Void)?

    init() {
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 0.07, alpha: 1); clipsToBounds = true
        layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor; layer.borderWidth = 0.5
        stack.axis = .horizontal; stack.spacing = 6; stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        accessibilityLabel = "Gesetz ergänzen"
        shouldGroupAccessibilityChildren = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var width: NSLayoutConstraint?

    /// Leading edge of the bar, its full height: follows rotation and width changes.
    func pin(to bar: UIView) {
        translatesAutoresizingMaskIntoConstraints = false
        let width = widthAnchor.constraint(equalToConstant: 280)
        let limit = widthAnchor.constraint(lessThanOrEqualTo: bar.widthAnchor, constant: -120)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: bar.leadingAnchor), topAnchor.constraint(equalTo: bar.topAnchor),
            bottomAnchor.constraint(equalTo: bar.bottomAnchor), width, limit
        ])
        self.width = width
    }

    /// `width`: the room the strip may cover; the chips shrink to fit it
    /// (only the abbreviation when a title would not fit).
    func show(_ suggestions: [LawSuggestion], width room: CGFloat, choose: @escaping (String) -> Void) {
        self.choose = choose
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        let mark = UIImageView(image: UIImage(systemName: "paragraphsign", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)))
        mark.tintColor = UIColor.white.withAlphaComponent(0.55); mark.isAccessibilityElement = false
        mark.setContentHuggingPriority(.required, for: .horizontal)
        stack.addArrangedSubview(mark)
        // Mark, close button, margins and gaps; the rest is shared by the chips.
        let fixed: CGFloat = 16 + 18 + 40 + CGFloat(suggestions.count + 1) * stack.spacing
        let each = max(56, (room - fixed) / CGFloat(max(1, suggestions.count)))
        for suggestion in suggestions {
            var config = UIButton.Configuration.filled()
            config.baseBackgroundColor = UIColor.systemBlue.withAlphaComponent(0.28)
            config.baseForegroundColor = .white
            config.cornerStyle = .capsule
            config.title = each < 130 ? suggestion.abbr : suggestion.label
            config.titleLineBreakMode = .byTruncatingTail
            config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes; attributes.font = .systemFont(ofSize: 15, weight: .medium); return attributes
            }
            let button = UIButton(configuration: config)
            button.heightAnchor.constraint(equalToConstant: 36).isActive = true
            button.widthAnchor.constraint(lessThanOrEqualToConstant: each).isActive = true
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            button.accessibilityLabel = "\(suggestion.abbr) ergänzen"
            button.accessibilityValue = suggestion.label
            let id = suggestion.lawID
            button.addAction(UIAction { [weak self] _ in self?.choose?(id) }, for: .touchUpInside)
            stack.addArrangedSubview(button)
        }
        var close = UIButton.Configuration.plain()
        close.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        close.baseForegroundColor = UIColor.white.withAlphaComponent(0.6)
        let closeButton = UIButton(configuration: close)
        closeButton.widthAnchor.constraint(equalToConstant: 40).isActive = true
        closeButton.heightAnchor.constraint(equalToConstant: 40).isActive = true
        closeButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        closeButton.accessibilityLabel = "Vorschläge ausblenden"
        closeButton.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
        stack.addArrangedSubview(closeButton)
        let natural = stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width + 16
        width?.constant = min(room, natural)
        isHidden = false
    }
}
