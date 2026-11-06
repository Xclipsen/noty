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
        guard let trigger = quickLawTrigger(editor) else { hideLawSuggestions(); return }
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
        state.shown = nil; state.indexWatch = nil
        state.strip?.isHidden = true
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
        guard !suggestions.isEmpty else { hideLawSuggestions(); return }
        showLawSuggestions(suggestions, trigger: trigger, editor: editor)
    }

    private func showLawSuggestions(_ suggestions: [LawSuggestion], trigger: LawSuggestionTrigger, editor: PageTextView) {
        let state = lawSuggestion
        state.shown = (editor.objectID, trigger, editor.textStorage.string)
        let strip = state.strip ?? {
            let made = LawSuggestionStrip()
            self.accessory.addSubview(made)
            state.strip = made
            return made
        }()
        strip.show(suggestions, in: accessory) { [weak self] lawID in self?.acceptLawSuggestion(lawID) }
        strip.onClose = { [weak self] in self?.hideLawSuggestions() }
        // Section titles still being indexed: the chips follow once they arrive.
        if state.indexWatch == nil {
            state.indexWatch = LawSuggestionModel.shared.$indexGeneration.dropFirst()
                .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
                .sink { [weak self, weak editor] _ in
                    MainActor.assumeIsolated {
                        guard let self, let editor, let shown = self.lawSuggestion.shown, shown.fieldID == editor.objectID else { return }
                        self.refreshLawSuggestions(editor, expected: shown.trigger)
                    }
                }
        }
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
        backgroundColor = UIColor(white: 0.07, alpha: 1)
        layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor; layer.borderWidth = 0.5
        stack.axis = .horizontal; stack.spacing = 6; stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        accessibilityLabel = "Gesetz ergänzen"
        shouldGroupAccessibilityChildren = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ suggestions: [LawSuggestion], in bar: UIView, choose: @escaping (String) -> Void) {
        self.choose = choose
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        let mark = UIImageView(image: UIImage(systemName: "paragraphsign", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)))
        mark.tintColor = UIColor.white.withAlphaComponent(0.55); mark.isAccessibilityElement = false
        stack.addArrangedSubview(mark)
        for suggestion in suggestions {
            var config = UIButton.Configuration.filled()
            config.baseBackgroundColor = UIColor.systemBlue.withAlphaComponent(0.28)
            config.baseForegroundColor = .white
            config.cornerStyle = .capsule
            config.title = suggestion.label
            config.titleLineBreakMode = .byTruncatingTail
            config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes; attributes.font = .systemFont(ofSize: 15, weight: .medium); return attributes
            }
            let button = UIButton(configuration: config)
            button.heightAnchor.constraint(equalToConstant: 36).isActive = true
            button.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
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
        closeButton.accessibilityLabel = "Vorschläge ausblenden"
        closeButton.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
        stack.addArrangedSubview(closeButton)
        // Covers the leading part of the bar only; the format buttons stay
        // reachable to the right of it.
        let size = stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        let width = min(bar.bounds.width, size.width + 16)
        frame = CGRect(x: 0, y: 0, width: width, height: bar.bounds.height)
        autoresizingMask = [.flexibleHeight]
        isHidden = false
        bar.bringSubviewToFront(self)
    }
}
