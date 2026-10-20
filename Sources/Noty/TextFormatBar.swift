import UIKit
import NotebookCore

/// Format bar above the keyboard (style, size, colour, lists, counter).
extension TextObjectLayer {
    func makeAccessory() -> UIView {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 1024, height: 54))
        root.overrideUserInterfaceStyle = .dark; root.backgroundColor = UIColor(white: 0.045, alpha: 0.98)
        root.layer.borderColor = UIColor.white.withAlphaComponent(0.16).cgColor; root.layer.borderWidth = 0.5
        let scroll = UIScrollView(frame: root.bounds)
        scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]; scroll.showsHorizontalScrollIndicator = false
        let stack = UIStackView(); stack.axis = .horizontal; stack.spacing = 2; stack.alignment = .center
        func button(_ key: String, title: String? = nil, symbol: String? = nil, width: CGFloat = 44, action: Selector? = nil) -> UIButton {
            let button = UIButton(type: .system)
            var config = UIButton.Configuration.plain()
            config.baseForegroundColor = .white
            config.title = title
            if let symbol { config.image = formatIcon(symbol) }
            config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6)
            button.configuration = config
            button.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
            button.widthAnchor.constraint(equalToConstant: width).isActive = true
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
            button.layer.cornerRadius = 9; button.accessibilityLabel = key
            if let action { button.addTarget(self, action: action, for: .touchUpInside) }
            stack.addArrangedSubview(button); buttons[key] = button
            return button
        }
        func separator() {
            let view = UIView(); view.backgroundColor = UIColor.white.withAlphaComponent(0.14)
            view.widthAnchor.constraint(equalToConstant: 1).isActive = true
            view.heightAnchor.constraint(equalToConstant: 26).isActive = true
            stack.addArrangedSubview(view)
        }
        let preset = button("Textstil", title: "Text", width: 150)
        preset.backgroundColor = UIColor.white.withAlphaComponent(0.055); preset.showsMenuAsPrimaryAction = true
        preset.menu = UIMenu(title: "Absatzstil", children: TextStylePreset.allCases.map { item in
            UIAction(title: item.title, subtitle: "\(Int(item.fontSize)) pt\(item.bold ? " · fett" : "")") { [weak self] _ in self?.applyPreset(item) }
        })
        let family = button("Schrift", title: "System", width: 124)
        family.backgroundColor = UIColor.white.withAlphaComponent(0.055); family.showsMenuAsPrimaryAction = true
        family.menu = UIMenu(children: [
            UIAction(title: "System") { [weak self] _ in self?.changeStyle { $0.font = .system; $0.fontName = nil } },
            UIAction(title: "Serif") { [weak self] _ in self?.changeStyle { $0.font = .serif; $0.fontName = nil } },
            UIAction(title: "Festbreite") { [weak self] _ in self?.changeStyle { $0.font = .monospaced; $0.fontName = nil } },
            UIAction(title: "Weitere Schriften …", image: UIImage(systemName: "textformat")) { [weak self] _ in self?.chooseFont() }
        ])
        button("Kleiner", symbol: "minus.circle", action: #selector(smaller)).accessibilityLabel = "Schrift kleiner"
        _ = button("Schriftgröße", title: "14", width: 38)
        buttons["Schriftgröße"]?.isUserInteractionEnabled = false
        button("Größer", symbol: "plus.circle", action: #selector(larger)).accessibilityLabel = "Schrift größer"
        button("Farbe", symbol: "circle.fill", action: #selector(chooseColor)).accessibilityLabel = "Textfarbe"
        separator()
        _ = button("Fett", symbol: "bold", action: #selector(toggleBold))
        _ = button("Kursiv", symbol: "italic", action: #selector(toggleItalic))
        _ = button("Unterstrichen", symbol: "underline", action: #selector(toggleTextUnderline))
        _ = button("Weitere Textformate", symbol: "chevron.down", action: #selector(showExtraFormats))
        separator()
        let marker = button("Markieren", symbol: "highlighter", action: #selector(toggleHighlight))
        marker.accessibilityHint = "Lang drücken für weitere Markerfarben"
        marker.menu = UIMenu(title: "Markerfarbe", children: HighlightColor.allCases.map { color in
            UIAction(title: color.title, image: swatch(color.uiColor.withAlphaComponent(0.6))) { [weak self] _ in self?.applyHighlight(color) }
        } + [UIAction(title: "Markierung entfernen", image: UIImage(systemName: "xmark.circle")) { [weak self] _ in self?.applyHighlight(nil) }])
        let link = button("Link", symbol: "link"); link.addAction(UIAction { [weak self] _ in self?.editLink() }, for: .touchUpInside)
        separator()
        for (key, symbol, kind) in [("Checkbox", "checkmark.circle", TextListEditing.Kind.checkbox), ("Aufzählung", "list.bullet", .bullet), ("Nummerierung", "list.number", .numbered)] {
            let item = button(key, symbol: symbol)
            if kind == .checkbox { item.accessibilityLabel = "Checkliste" }
            item.addAction(UIAction { [weak self] _ in self?.toggleList(kind) }, for: .touchUpInside)
        }
        _ = button("Ausrichten", symbol: "text.alignleft", action: #selector(showAlignment))
        separator()
        let decrease = button("Einzug verkleinern", symbol: "decrease.indent")
        decrease.addAction(UIAction { [weak self] _ in self?.indentFromBar(outdent: true) }, for: .touchUpInside)
        let increase = button("Einzug vergrößern", symbol: "increase.indent")
        increase.addAction(UIAction { [weak self] _ in self?.indentFromBar(outdent: false) }, for: .touchUpInside)
        separator()
        let counter = button("Wortzahl", title: "0 Wörter", width: 112)
        counter.showsMenuAsPrimaryAction = true
        counter.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes; attributes.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular); return attributes
        }
        let typewriter = button("Schreibmaschinen-Modus", symbol: "text.line.first.and.arrowtriangle.forward")
        typewriter.addAction(UIAction { [weak self] _ in Self.typewriterEnabled.toggle(); self?.updateAccessory() }, for: .touchUpInside)
        typewriter.accessibilityHint = "Hält die Schreibzeile im oberen Drittel"
        separator()
        _ = button("Fertig", symbol: "keyboard.chevron.compact.down", action: #selector(finishEditing))
        stack.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        ])
        root.addSubview(scroll); root.autoresizingMask = [.flexibleWidth]
        return root
    }
    private var presentingController: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder { if let controller = current as? UIViewController { return controller }; responder = current.next }
        return nil
    }
    private struct FormatIconChoice {
        var label: String
        var symbol: String
        var selected: Bool
        var change: (inout TextBoxStyle) -> Void
    }
    /// Fixed-size vector canvases keep differently shaped SF symbols centered.
    private func formatIcon(_ name: String) -> UIImage? {
        guard let symbol = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .regular)) else { return nil }
        return UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { _ in
            let scale = min(22 / max(1, symbol.size.width), 22 / max(1, symbol.size.height))
            let size = CGSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
            symbol.draw(in: CGRect(x: (24 - size.width) / 2, y: (24 - size.height) / 2, width: size.width, height: size.height))
        }.withRenderingMode(.alwaysTemplate)
    }
    @objc private func showExtraFormats() {
        guard let style = selectionStyle else { return }
        showIconMenu(sourceKey: "Weitere Textformate", choices: [
            .init(label: "Durchstreichen", symbol: "strikethrough", selected: style.strikethrough == true,
                change: { $0.strikethrough = !($0.strikethrough ?? false) }),
            .init(label: "Hochstellen", symbol: "textformat.superscript", selected: style.baseline == 1,
                change: { $0.baseline = $0.baseline == 1 ? nil : 1 }),
            .init(label: "Tiefstellen", symbol: "textformat.subscript", selected: style.baseline == -1,
                change: { $0.baseline = $0.baseline == -1 ? nil : -1 }),
            .init(label: "Formatierung entfernen", symbol: "eraser", selected: false,
                change: { [light = selectedLight] in $0 = $0.clearingCharacterFormatting(light: light) })
        ])
    }
    @objc private func showAlignment() {
        guard let style = selectionStyle else { return }
        let choices: [FormatIconChoice] = [("Links", "text.alignleft", TextAlignment.left),
            ("Mittig", "text.aligncenter", .center), ("Rechts", "text.alignright", .right),
            ("Blocksatz", "text.justify", .justified)].map { label, symbol, value in
                FormatIconChoice(label: label, symbol: symbol, selected: (style.alignment ?? .left) == value,
                    change: { $0.alignment = value })
            }
        showIconMenu(sourceKey: "Ausrichten", choices: choices, paragraph: true)
    }
    private func showIconMenu(sourceKey: String, choices: [FormatIconChoice], paragraph: Bool = false) {
        guard let controller = presentingController, controller.presentedViewController == nil,
              let source = buttons[sourceKey], rememberFormatSelection(), let selectedID,
              let editor = fields[selectedID]?.editor, editor.markedTextRange == nil else { return }
        let insertion = editor.typingAttributes
        let original = NSAttributedString(attributedString: editor.attributedText)
        let popover = UIViewController(); popover.overrideUserInterfaceStyle = .dark
        popover.view.backgroundColor = UIColor(white: 0.09, alpha: 1)
        popover.preferredContentSize = CGSize(width: choices.count * 44 + 16, height: 60)
        popover.modalPresentationStyle = .popover
        for (index, choice) in choices.enumerated() {
            let button = UIButton(type: .system)
            button.frame = CGRect(x: 8 + index * 44, y: 8, width: 44, height: 44)
            button.setImage(formatIcon(choice.symbol), for: .normal)
            button.tintColor = .white; button.layer.cornerRadius = 9
            button.backgroundColor = choice.selected ? UIColor.systemBlue.withAlphaComponent(0.4) : .clear
            button.isSelected = choice.selected; button.accessibilityLabel = choice.label
            button.addAction(UIAction { [weak self, weak popover, weak editor] _ in
                defer { popover?.dismiss(animated: true) }
                guard let self, let editor, editor.attributedText.isEqual(to: original), self.restoreFormatSelection() else { return }
                if editor.selectedRange.length == 0 { editor.typingAttributes = insertion }
                self.changeStyle(choice.change, paragraph: paragraph)
            }, for: .touchUpInside)
            popover.view.addSubview(button)
        }
        popover.popoverPresentationController?.sourceView = source
        popover.popoverPresentationController?.sourceRect = source.bounds
        popover.popoverPresentationController?.delegate = self
        iconPopover = popover; controller.present(popover, animated: true)
    }
    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle { .none }
    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle { .none }
    private func rememberFormatSelection() -> Bool {
        guard let pageID, let selectedID, let editor = fields[selectedID]?.editor else { return false }
        colorSelection = (pageID, selectedID, generation, editor.selectedRange); return true
    }
    private func restoreFormatSelection() -> Bool {
        guard let (page, id, gen, range) = colorSelection, active, page == pageID, gen == generation,
              selectedID == id, let editor = fields[id]?.editor else { return false }
        editor.selectedRange = range; return true
    }
    @objc private func chooseColor() {
        guard let controller = presentingController, let source = buttons["Farbe"], rememberFormatSelection() else { return }
        let popover = UIViewController(); popover.overrideUserInterfaceStyle = .dark
        popover.view.backgroundColor = UIColor(white: 0.035, alpha: 1)
        popover.preferredContentSize = CGSize(width: 360, height: 152)
        popover.modalPresentationStyle = .popover
        let colors: [(String, InkColor)] = [
            ("Gelb", .init(1,1,0)), ("Orange", .init(1,0.6,0)), ("Rot", .init(0.8,0.12,0.12)), ("Pink", .init(1,0,0.7)),
            ("Hellgrün", .init(0.5,0.9,0)), ("Grün", .init(0.3,0.7,0.3)), ("Violett", .init(0.7,0.2,0.9)), ("Lila", .init(0.6,0.4,0.8)),
            ("Mint", .init(0.5,1,0.8)), ("Blau", .init(0.1,0.35,0.8)), ("Hellblau", .init(0.3,0.5,0.9)), ("Lavendel", .init(0.6,0.5,1)),
            ("Schwarz", .init(0,0,0)), ("Grau", .init(0.4,0.4,0.4)), ("Weiß", .init(1,1,1)), ("Braun", .init(0.7,0.5,0.3))
        ]
        for (i, item) in colors.enumerated() {
            let button = UIButton(type: .system); button.accessibilityLabel = item.0
            button.frame = CGRect(x: 4 + (i % 8) * 44, y: 8 + (i / 8) * 44, width: 44, height: 44)
            let swatch = UIView(frame: CGRect(x: 9, y: 9, width: 26, height: 26)); swatch.isUserInteractionEnabled = false
            swatch.backgroundColor = UIColor(red: item.1.red, green: item.1.green, blue: item.1.blue, alpha: 1)
            swatch.layer.cornerRadius = 13; swatch.layer.borderWidth = 1; swatch.layer.borderColor = UIColor.white.withAlphaComponent(0.3).cgColor
            button.addSubview(swatch)
            button.addAction(UIAction { [weak self, weak popover] _ in
                guard let self, self.restoreFormatSelection() else { return }
                self.changeStyle { $0.ink = item.1; $0.automaticColor = nil }
                popover?.dismiss(animated: true)
            }, for: .touchUpInside)
            popover.view.addSubview(button)
        }
        let automatic = UIButton(type: .system); automatic.setTitle(" Automatisch", for: .normal)
        automatic.setImage(automaticSwatch().withRenderingMode(.alwaysOriginal), for: .normal)
        automatic.frame = CGRect(x: 8, y: 104, width: 168, height: 44); automatic.layer.cornerRadius = 9
        automatic.accessibilityHint = "Schwarz oder Weiß passend zum Papier, auch nach späterem Umstellen"
        if selectionStyle?.automaticColor == true { automatic.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.3) }
        automatic.addAction(UIAction { [weak self, weak popover] _ in
            guard let self, self.restoreFormatSelection() else { return }
            let light = self.selectedLight
            self.changeStyle { $0.automaticColor = true; $0.ink = nil; $0.color = light ? .white : .black }
            popover?.dismiss(animated: true)
        }, for: .touchUpInside); popover.view.addSubview(automatic)
        let custom = UIButton(type: .system); custom.setTitle("Weitere Farben …", for: .normal)
        custom.frame = CGRect(x: 184, y: 104, width: 168, height: 44)
        custom.addAction(UIAction { [weak self, weak popover] _ in
            popover?.dismiss(animated: true) { self?.chooseCustomColor() }
        }, for: .touchUpInside); popover.view.addSubview(custom)
        popover.popoverPresentationController?.sourceView = source
        popover.popoverPresentationController?.sourceRect = source.bounds
        colorPopover = popover; controller.present(popover, animated: true)
    }
    private func chooseCustomColor() {
        guard restoreFormatSelection(), let controller = presentingController else { return }
        let picker = UIColorPickerViewController(); picker.overrideUserInterfaceStyle = .dark
        picker.supportsAlpha = false; picker.delegate = self
        controller.present(picker, animated: true)
    }
    func colorPickerViewControllerDidSelectColor(_ viewController: UIColorPickerViewController) {
        guard restoreFormatSelection() else { return }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        viewController.selectedColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        changeStyle { $0.ink = InkColor(r,g,b,a); $0.automaticColor = nil }
    }
    private func chooseFont() {
        guard let controller = presentingController, rememberFormatSelection() else { return }
        let config = UIFontPickerViewController.Configuration(); config.includeFaces = true
        let picker = UIFontPickerViewController(configuration: config); picker.overrideUserInterfaceStyle = .dark
        picker.delegate = self; controller.present(picker, animated: true)
    }
    func fontPickerViewControllerDidPickFont(_ viewController: UIFontPickerViewController) {
        guard restoreFormatSelection(), let descriptor = viewController.selectedFontDescriptor else { return }
        let name = UIFont(descriptor: descriptor, size: 17).fontName
        changeStyle { $0.font = .system; $0.fontName = name }
        viewController.dismiss(animated: true)
    }
    private func editLink() {
        var responder: UIResponder? = self
        while responder != nil && !(responder is UIViewController) { responder = responder?.next }
        guard let controller = responder as? UIViewController else { return }
        // Link problems are shown as an alert.
        func warn(_ text: String) {
            let message = UIAlertController(title: "Link", message: text, preferredStyle: .alert)
            message.overrideUserInterfaceStyle = .dark
            message.addAction(UIAlertAction(title: "OK", style: .default))
            controller.present(message, animated: true)
        }
        guard let selectedID, let field = fields[selectedID], field.editor.selectedRange.length > 0 else {
            warn("Für einen Link zuerst Text markieren."); return
        }
        let expectedPage = pageID, expectedGeneration = generation
        let range = field.editor.selectedRange
        let alert = UIAlertController(title: "Link", message: "https://, http:// oder mailto:", preferredStyle: .alert)
        alert.overrideUserInterfaceStyle = .dark
        alert.addTextField { $0.text = self.selectionStyle?.link; $0.keyboardType = .URL; $0.autocapitalizationType = .none }
        alert.addAction(UIAlertAction(title: "Abbrechen", style: .cancel))
        alert.addAction(UIAlertAction(title: "Übernehmen", style: .default) { [weak self, weak field, weak alert] _ in
            guard let self, let field, self.active, self.pageID == expectedPage, self.generation == expectedGeneration else { return }
            let value = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty {
                guard let scheme = URL(string: value)?.scheme?.lowercased(), ["https", "http", "mailto"].contains(scheme), value.utf8.count <= 2048 else {
                    warn("Ungültige Link-Adresse."); return
                }
            }
            field.editor.selectedRange = range
            self.changeStyle { $0.link = value.isEmpty ? nil : value }
        })
        controller.present(alert, animated: true)
    }
    @objc private func finishEditing() { endTextEditing() }
    private func swatch(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 22, height: 22)).image { context in
            context.cgContext.setFillColor(color.cgColor); context.cgContext.fillEllipse(in: CGRect(x: 2, y: 2, width: 18, height: 18))
        }.withRenderingMode(.alwaysOriginal)
    }
    /// Half black, half white: follows the paper like the automatic pen.
    private func automaticSwatch() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 28, height: 28)).image { context in
            let rect = CGRect(x: 2, y: 2, width: 24, height: 24), cg = context.cgContext
            cg.setFillColor(UIColor.white.cgColor); cg.fillEllipse(in: rect)
            cg.saveGState(); cg.addEllipse(in: rect); cg.clip()
            cg.setFillColor(UIColor.black.cgColor); cg.fill(CGRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height))
            cg.restoreGState()
            cg.setStrokeColor(UIColor.white.withAlphaComponent(0.5).cgColor); cg.setLineWidth(1); cg.strokeEllipse(in: rect)
        }
    }
    /// Word/character counter, debounced: whole flow across pages or the selection.
    private func scheduleCounter() {
        counterRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshCounter() }
        counterRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
    private func refreshCounter() {
        guard let button = buttons["Wortzahl"], let selectedID, let box = boxes.first(where: { $0.id == selectedID }),
              let editor = fields[selectedID]?.editor else { return }
        let selection = editor.selectedRange, text = editor.text ?? ""
        let partial = selection.length > 0 && NSMaxRange(selection) <= (text as NSString).length
        let source = partial ? (text as NSString).substring(with: selection) : box.flowID.flatMap { readFlowText?($0) } ?? text
        let stats = TextStatistics(source)
        button.setTitle(stats.words == 1 ? "1 Wort" : "\(stats.words) Wörter", for: .normal)
        button.accessibilityValue = "\(stats.words) Wörter, \(stats.characters) Zeichen"
        button.menu = UIMenu(title: partial ? "Auswahl" : box.flowID == nil ? "Textfeld" : "Gesamter Text", children: [
            UIAction(title: "Wörter: \(stats.words)", attributes: .disabled) { _ in },
            UIAction(title: "Zeichen: \(stats.characters)", attributes: .disabled) { _ in },
            UIAction(title: "Zeichen ohne Leerzeichen: \(stats.charactersWithoutSpaces)", attributes: .disabled) { _ in }
        ])
    }
    func updateAccessory() {
        guard let selectedID, let box = boxes.first(where: { $0.id == selectedID }), let field = fields[selectedID] else { return }
        field.editor.accessibilityHint = neededHeight(field.editor, width: box.width) > box.height + 1
            ? "Textfeld am Seitenende · Text bleibt vollständig gespeichert." : nil
        let style = selectionStyle ?? box.style
        buttons["Textstil"]?.setTitle(TextStylePreset.matching(style).title, for: .normal)
        buttons["Schriftgröße"]?.setTitle(String(Int(style.fontSize)), for: .normal)
        buttons["Schriftgröße"]?.accessibilityValue = "\(Int(style.fontSize)) Punkt"
        buttons["Schrift"]?.setTitle(style.fontName.flatMap { UIFont(name: $0, size: 17)?.familyName } ?? (style.font == .serif ? "Serif" : style.font == .monospaced ? "Festbreite" : "System"), for: .normal)
        if style.automaticColor == true {
            buttons["Farbe"]?.setImage(automaticSwatch().withRenderingMode(.alwaysOriginal), for: .normal)
        } else if let ink = style.attributes[.foregroundColor] as? UIColor {
            let swatch = UIGraphicsImageRenderer(size: CGSize(width: 28, height: 28)).image { context in
                let rect = CGRect(x: 2, y: 2, width: 24, height: 24)
                context.cgContext.setFillColor(ink.cgColor); context.cgContext.fillEllipse(in: rect)
                context.cgContext.setStrokeColor(UIColor.white.withAlphaComponent(0.5).cgColor)
                context.cgContext.setLineWidth(1); context.cgContext.strokeEllipse(in: rect)
            }.withRenderingMode(.alwaysOriginal)
            buttons["Farbe"]?.setImage(swatch, for: .normal)
        }
        buttons["Markieren"]?.backgroundColor = style.highlighted == true ? (style.highlightColor?.uiColor ?? .systemYellow).withAlphaComponent(0.3) : .clear
        buttons["Markieren"]?.configuration?.baseForegroundColor = lastHighlight == .yellow ? .white : lastHighlight.uiColor
        buttons["Schreibmaschinen-Modus"]?.backgroundColor = Self.typewriterEnabled ? UIColor.systemBlue.withAlphaComponent(0.2) : .clear
        buttons["Schreibmaschinen-Modus"]?.accessibilityValue = Self.typewriterEnabled ? "Ein" : "Aus"
        scheduleCounter()
        let extraActive = style.strikethrough == true || (style.baseline ?? 0) != 0
        buttons["Weitere Textformate"]?.backgroundColor = extraActive ? UIColor.systemBlue.withAlphaComponent(0.2) : .clear
        let alignmentSymbol = switch style.alignment ?? .left {
        case .left: "text.alignleft"; case .center: "text.aligncenter"; case .right: "text.alignright"; case .justified: "text.justify"
        }
        buttons["Ausrichten"]?.setImage(formatIcon(alignmentSymbol), for: .normal)
        for (key, kind) in [("Checkbox", TextListEditing.Kind.checkbox), ("Aufzählung", .bullet), ("Nummerierung", .numbered)] {
            let enabled = TextListEditing.isActive(kind, in: field.editor.text ?? "", range: field.editor.selectedRange)
            buttons[key]?.isSelected = enabled
            buttons[key]?.backgroundColor = enabled ? UIColor.systemBlue.withAlphaComponent(0.2) : .clear
        }
        for (title, enabled) in [("Fett", style.bold), ("Kursiv", style.italic), ("Unterstrichen", style.underline)] {
            buttons[title]?.isSelected = enabled
            buttons[title]?.backgroundColor = enabled ? UIColor.systemBlue.withAlphaComponent(0.15) : .clear
        }
    }
}
