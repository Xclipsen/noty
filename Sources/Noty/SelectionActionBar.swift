import UIKit

/// One action of a selection (Build 64: one bar for every object type).
enum SelectionAction: CaseIterable {
    case edit, style, cut, copy, duplicate, front, back, crop, turn, lock, fieldStyle, mirror, more, delete, paste

    var title: String {
        switch self {
        case .edit: "Bearbeiten"
        case .style: "Stil"
        case .cut: "Ausschneiden"
        case .copy: "Kopieren"
        case .duplicate: "Duplizieren"
        case .front: "Nach vorne"
        case .back: "Nach hinten"
        case .crop: "Zuschneiden"
        case .turn: "Um 90° drehen"
        case .lock: "Sperren"
        case .fieldStyle: "Feldstil"
        case .mirror: "Spiegeln"
        case .more: "Weitere Aktionen"
        case .delete: "Löschen"
        case .paste: "Einfügen"
        }
    }
    /// Short description shown with the name while hovering.
    var detail: String {
        switch self {
        case .edit: "Cursor in das Textfeld setzen"
        case .style: "Farbe und Strichstärke"
        case .cut: "Kopieren und entfernen"
        case .copy: "In die Zwischenablage"
        case .duplicate: "Kopie gleich daneben"
        case .front: "Über andere Objekte derselben Art"
        case .back: "Unter andere Objekte derselben Art"
        case .crop: "Bildausschnitt wählen"
        case .turn: "Im Uhrzeigersinn auf den nächsten rechten Winkel"
        case .lock: "Bild bleibt Hintergrund und lässt sich nicht verschieben"
        case .fieldStyle: "Füllung und Rahmen des Felds"
        case .mirror: "Handschrift waagerecht oder senkrecht spiegeln"
        case .more: "Einfügen, Auswahl aufheben"
        case .delete: "Auswahl entfernen"
        case .paste: "Zuletzt Kopiertes einfügen"
        }
    }
    var symbol: String {
        switch self {
        case .edit: "character.cursor.ibeam"
        case .style: "paintpalette"
        case .cut: "scissors"
        case .copy: "doc.on.doc"
        case .duplicate: "plus.square.on.square"
        case .front: "square.3.layers.3d.top.filled"
        case .back: "square.3.layers.3d.bottom.filled"
        case .crop: "crop"
        case .turn: "rotate.right"
        case .lock: "lock.open"
        case .fieldStyle: "rectangle.inset.filled"
        case .mirror: "arrow.left.and.right.righttriangle.left.righttriangle.right"
        case .more: "ellipsis"
        case .delete: "trash"
        case .paste: "doc.on.clipboard"
        }
    }
}

/// The dark action bar above a selection: one construction for fields,
/// images, shapes, handwriting and mixed selections. 44 × 44-pt symbol
/// buttons in groups with fine dividers, delete red and always last, names
/// with a short description after hovering (Pencil hover or pointer) and as
/// system tooltip; scrolls sideways when the window is narrower than the bar.
@MainActor
final class SelectionActionBar: UIScrollView {
    static let height: CGFloat = 52
    private let stack = UIStackView()
    private var buttons: [SelectionAction: UIButton] = [:]
    private var shown: [[SelectionAction]] = []
    private var switchedOn = Set<SelectionAction>()
    /// Tap on an action (menus run their own entries).
    var onAction: ((SelectionAction) -> Void)?
    /// Hover over a button lingered (button, text) or ended (nil).
    var onHover: ((UIButton?, String?) -> Void)?
    private var pendingHover: DispatchWorkItem?
    /// Full width of the shown buttons and dividers.
    private(set) var contentWidth: CGFloat = 0
    private struct State: Equatable {
        var groups: [[SelectionAction]]
        var disabled: Set<SelectionAction>, on: Set<SelectionAction>
        var titles: [SelectionAction: String], symbols: [SelectionAction: String]
    }
    private var lastState: State?

    override init(frame: CGRect) {
        super.init(frame: frame)
        overrideUserInterfaceStyle = .dark
        backgroundColor = UIColor(white: 0.13, alpha: 0.98)
        layer.cornerRadius = Self.height / 2; layer.cornerCurve = .continuous
        layer.borderWidth = 0.5; layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
        showsHorizontalScrollIndicator = false
        stack.axis = .horizontal; stack.spacing = 4; stack.alignment = .center
        stack.accessibilityContainerType = .semanticGroup; stack.accessibilityLabel = "Aktionen der Auswahl"
        addSubview(stack)
        for action in SelectionAction.allCases {
            let button = UIButton(type: .system)
            var config = UIButton.Configuration.plain()
            config.image = UIImage(systemName: action.symbol)
            config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
            config.baseForegroundColor = action == .delete ? .systemRed : .white
            button.configuration = config
            button.configurationUpdateHandler = { [weak self] button in
                let on = self?.switchedOn.contains(action) == true
                let base: UIColor = action == .delete ? .systemRed : on ? .systemBlue : .white
                button.configuration?.baseForegroundColor = button.isEnabled ? base : UIColor.white.withAlphaComponent(0.28)
            }
            button.accessibilityLabel = action.title; button.toolTip = "\(action.title) – \(action.detail)"
            button.widthAnchor.constraint(equalToConstant: 44).isActive = true
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
            if action != .more && action != .mirror {
                button.addAction(UIAction { [weak self] _ in self?.onAction?(action) }, for: .touchUpInside)
            } else { button.showsMenuAsPrimaryAction = true }
            let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
            button.addGestureRecognizer(hover)
            buttons[action] = button
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setMenu(_ menu: UIMenu, for action: SelectionAction) { buttons[action]?.menu = menu }

    /// Shows `groups` in order (dividers between them); `disabled` dimmed,
    /// `on` drawn as switched on (lock of a locked image).
    func show(_ groups: [[SelectionAction]], disabled: Set<SelectionAction> = [], on: Set<SelectionAction> = [],
              titles: [SelectionAction: String] = [:], symbols: [SelectionAction: String] = [:]) {
        let groups = groups.filter { !$0.isEmpty }
        // Called on every refresh (also per drag event): nothing to do when unchanged.
        let state = State(groups: groups, disabled: disabled, on: on, titles: titles, symbols: symbols)
        guard state != lastState else { return }
        lastState = state
        if groups != shown {
            shown = groups
            stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
            for (index, group) in groups.enumerated() {
                if index > 0 { stack.addArrangedSubview(divider()) }
                for action in group { if let button = buttons[action] { stack.addArrangedSubview(button) } }
            }
            let items = groups.reduce(0) { $0 + $1.count }
            contentWidth = CGFloat(items) * 44 + CGFloat(max(0, groups.count - 1)) + CGFloat(max(0, items + groups.count - 2)) * stack.spacing + 8
        }
        switchedOn = on
        for (action, button) in buttons {
            button.isEnabled = !disabled.contains(action)
            let title = titles[action] ?? action.title
            if button.accessibilityLabel != title { button.accessibilityLabel = title; button.toolTip = "\(title) – \(action.detail)" }
            button.configuration?.image = UIImage(systemName: symbols[action] ?? action.symbol)
            button.setNeedsUpdateConfiguration()
        }
        stack.frame = CGRect(x: 4, y: 4, width: contentWidth - 8, height: 44)
        contentSize = CGSize(width: contentWidth, height: Self.height)
    }
    var isEmpty: Bool { shown.isEmpty }

    private func divider() -> UIView {
        let line = UIView(); line.backgroundColor = UIColor.white.withAlphaComponent(0.14)
        line.isUserInteractionEnabled = false; line.isAccessibilityElement = false
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        line.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return line
    }

    @objc private func hovered(_ gesture: UIHoverGestureRecognizer) {
        guard let button = gesture.view as? UIButton else { return }
        switch gesture.state {
        case .began:
            pendingHover?.cancel()
            let text = button.toolTip ?? button.accessibilityLabel ?? ""
            let work = DispatchWorkItem { [weak self, weak button] in
                guard let self, let button, button.window != nil else { return }
                self.onHover?(button, text)
            }
            pendingHover = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65, execute: work)
        case .ended, .cancelled, .failed:
            pendingHover?.cancel(); pendingHover = nil
            onHover?(nil, nil)
        default: break
        }
    }
}
