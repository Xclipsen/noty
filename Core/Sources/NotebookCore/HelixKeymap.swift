import Foundation

/// The keyboard mode's one key table (docs/KEYBOARD.md): the parser, the key
/// overview, the command palette and the which-key popup all read `bindings`.
/// Tokens as the app hands them over: `j`, `G`, `:`, `^d`, `<A-;>`, `<CR>`,
/// `<Esc>`, `<Space>`, `<S-Tab>`.
public enum HelixContext: String, Sendable, CaseIterable {
    case library
    /// Editor without text cursor.
    case page
    /// A text in NOR or SEL; which of them only the engine has to know.
    case text
}

/// What a command means to the app; `text` goes to `TextEngine.perform`.
public enum HelixAction: Equatable, Sendable {
    // Anywhere
    case help, palette, search, undo, redo, escape
    case searchAll, sidebar, outline, bookmark, close
    case export(HelixExport)
    // Library
    case focusItem(dx: Int, dy: Int), focusFirstItem, focusLastItem, openItem, parentFolder
    case newNotebook, newTextDocument, newFolder, renameItem, trashItem, duplicateItem, pinItem, moveItem
    // Page. A typed count on `firstPage`, `lastPage` or `gotoPage` means that page.
    case scroll(x: Int, y: Int), scrollScreen(Double), page(Int), firstPage, lastPage, gotoPage
    case fit, zoom(Int), tool(WritingTool)
    /// Edit the selected field, otherwise write.
    case write
    case nextObject(Int), deleteObject, copyObject, pasteObject, duplicateObject, selectAll
    // Text
    case text(TextEngine.Command)
    /// Asks for a query, then `TextEngine.search`.
    case searchPrompt(backward: Bool)
    /// Asks for a pattern, then `TextEngine.selectMatches`.
    case selectPrompt
}

public enum HelixExport: String, Sendable, CaseIterable { case pdf, pagePDF, markdown, plainText, noty }

/// A key that waits for a character (`f`, `r`, `mi`).
public enum HelixPrompt: String, Sendable, CaseIterable {
    case findForward, tillForward, findBackward, tillBackward, replace
    case inside, around, surroundAdd, surroundDelete, surroundReplace

    public var title: String {
        switch self {
        case .findForward: "Bis einschließlich Zeichen"
        case .tillForward: "Bis vor Zeichen"
        case .findBackward: "Zurück bis einschließlich Zeichen"
        case .tillBackward: "Zurück bis nach Zeichen"
        case .replace: "Ersetzen durch Zeichen"
        case .inside: "Innerhalb von"
        case .around: "Mitsamt"
        case .surroundAdd: "Umschließen mit"
        case .surroundDelete: "Umschließung entfernen"
        case .surroundReplace: "Umschließung ersetzen"
        }
    }

    private static let pairs: [HelixMenu.Entry] = [
        .init(key: "(", title: "Runde Klammern"), .init(key: "[", title: "Eckige Klammern"), .init(key: "{", title: "Geschweifte Klammern"),
        .init(key: "<", title: "Spitze Klammern"), .init(key: "\"", title: "Anführungszeichen"), .init(key: "'", title: "Einfache Anführungszeichen"),
        .init(key: "`", title: "Backticks")]
    private static let closest = HelixMenu.Entry(key: "m", title: "Nächstes Klammerpaar")
    /// What the which-key popup suggests; any other punctuation works, too.
    public var choices: [HelixMenu.Entry] {
        switch self {
        case .inside, .around:
            [.init(key: "w", title: "Wort"), .init(key: "W", title: "Langes Wort"), .init(key: "p", title: "Absatz"), Self.closest] + Self.pairs
        case .surroundAdd: Self.pairs
        case .surroundDelete, .surroundReplace: [Self.closest] + Self.pairs
        default: []
        }
    }

    /// The command for a typed character; nil if it means nothing here.
    public func action(_ character: String) -> HelixAction? {
        func object(_ around: Bool) -> HelixAction? {
            let kind: TextEngine.TextObject
            switch character {
            case "w": kind = .word
            case "W": kind = .longWord
            case "p": kind = .paragraph
            case "m": kind = .closestPair
            default:
                guard let first = character.first, !(first.isASCII && (first.isLetter || first.isNumber)) else { return nil }
                kind = .pair(character)
            }
            return .text(.selectObject(kind, around: around))
        }
        switch self {
        case .findForward: return .text(.find(character, forward: true, inclusive: true))
        case .tillForward: return .text(.find(character, forward: true, inclusive: false))
        case .findBackward: return .text(.find(character, forward: false, inclusive: true))
        case .tillBackward: return .text(.find(character, forward: false, inclusive: false))
        case .replace: return .text(.replace(character))
        case .inside: return object(false)
        case .around: return object(true)
        case .surroundAdd: return .text(.surroundAdd(character))
        case .surroundDelete: return .text(.surroundDelete(character == "m" ? nil : character))
        case .surroundReplace: return nil // two characters, see `HelixParser`
        }
    }
}

/// The next keys of a menu node, for the which-key popup.
public struct HelixMenu: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        /// Token; `HelixKeymap.label` shows it.
        public let key: String
        public let title: String
        public let isMenu: Bool
        public init(key: String, title: String, isMenu: Bool = false) { self.key = key; self.title = title; self.isMenu = isMenu }
    }
    public let title: String
    public let entries: [Entry]
    public init(title: String, entries: [Entry]) { self.title = title; self.entries = entries }
}

/// One row of the table.
public struct HelixBinding: Sendable {
    public enum Target: Equatable, Sendable {
        case action(HelixAction)
        /// A menu node: further rows start with these keys.
        case menu
        case prompt(HelixPrompt)
    }
    /// Tokens separated by a space: `g g`, `^d`, `<Space> t p`.
    public let keys: String
    public let target: Target
    public let title: String
    public let group: String
    public let contexts: Set<HelixContext>
    /// Holding the key repeats it; never on destructive actions.
    public let repeats: Bool
    public var tokens: [String] { keys.split(separator: " ").map(String.init) }
    public var action: HelixAction? { if case .action(let action) = target { return action }; return nil }
    /// As it reads on the keyboard: `gg`, `⌃d`, `Space tp`.
    public var label: String { HelixKeymap.label(tokens) }

    init(_ keys: String, _ target: Target, _ title: String, _ group: String, _ contexts: Set<HelixContext>, repeats: Bool = false) {
        self.keys = keys; self.target = target; self.title = title; self.group = group
        self.contexts = contexts; self.repeats = repeats
    }
}

public enum HelixKeymap {
    public static let bindings: [HelixBinding] = {
        let all: Set<HelixContext> = [.library, .page, .text], editor: Set<HelixContext> = [.page, .text]
        let library: Set<HelixContext> = [.library], page: Set<HelixContext> = [.page], text: Set<HelixContext> = [.text]
        func act(_ keys: String, _ action: HelixAction, _ title: String, _ group: String, _ contexts: Set<HelixContext>, repeats: Bool = false) -> HelixBinding {
            HelixBinding(keys, .action(action), title, group, contexts, repeats: repeats)
        }
        func edit(_ keys: String, _ command: TextEngine.Command, _ title: String, _ group: String, repeats: Bool = false) -> HelixBinding {
            act(keys, .text(command), title, group, text, repeats: repeats)
        }
        func menu(_ keys: String, _ title: String, _ contexts: Set<HelixContext>) -> HelixBinding {
            HelixBinding(keys, .menu, title, "Menüs", contexts)
        }
        func prompt(_ keys: String, _ prompt: HelixPrompt) -> HelixBinding {
            HelixBinding(keys, .prompt(prompt), prompt.title, "Text", text)
        }

        var rows: [HelixBinding] = [
            act(":", .palette, "Befehle", "Überall", all),
            act("?", .help, "Tastenübersicht", "Überall", [.library, .page]),
            act("/", .search, "Suchen", "Überall", [.library, .page]),
            act("u", .undo, "Rückgängig", "Überall", editor),
            act("U", .redo, "Wiederholen", "Überall", editor),
            act("<Esc>", .escape, "Eine Ebene zurück", "Überall", editor),
            act("^[", .escape, "Eine Ebene zurück (wie Esc)", "Überall", editor),
            act("^c", .escape, "Eine Ebene zurück (wie Esc)", "Überall", editor),

            menu("g", "Gehe zu", all),
            menu("z", "Ansicht", editor),
            menu("m", "Auswählen und umschließen", text),
            menu("t", "Werkzeug", page),
            menu("<Space>", "Menü", all),
            menu("<Space> t", "Werkzeuge", editor),
            menu("<Space> e", "Export und Teilen", all),

            act("<Space> s", .sidebar, "Seitenleiste", "Menü", editor),
            act("<Space> o", .outline, "Gliederung", "Menü", editor),
            act("<Space> m", .bookmark, "Lesezeichen", "Menü", editor),
            act("<Space> f", .searchAll, "Alle Hefte suchen", "Menü", all),
            act("<Space> q", .close, "Schließen", "Menü", editor),
            act("<Space> ?", .palette, "Befehlspalette", "Menü", all),
            act("<Space> h", .help, "Tastenübersicht", "Menü", all),
            act("<Space> e p", .export(.pdf), "Als PDF exportieren", "Export und Teilen", all),
            act("<Space> e c", .export(.pagePDF), "Diese Seite als PDF", "Export und Teilen", editor),
            act("<Space> e m", .export(.markdown), "Als Markdown teilen", "Export und Teilen", all),
            act("<Space> e t", .export(.plainText), "Als Text teilen", "Export und Teilen", all),
            act("<Space> e n", .export(.noty), "Als .noty teilen", "Export und Teilen", all),

            act("z z", .fit, "Einpassen", "Ansicht", editor),
            act("z +", .zoom(1), "Vergrößern", "Ansicht", editor, repeats: true),
            act("z -", .zoom(-1), "Verkleinern", "Ansicht", editor, repeats: true),

            // Library
            act("g g", .focusFirstItem, "Erster Eintrag", "Bibliothek", library),
            act("g e", .focusLastItem, "Letzter Eintrag", "Bibliothek", library),
            act("<CR>", .openItem, "Öffnen", "Bibliothek", library),
            act("o", .openItem, "Öffnen", "Bibliothek", library),
            act("-", .parentFolder, "Eine Ebene hoch", "Bibliothek", library),
            act("<BS>", .parentFolder, "Eine Ebene hoch", "Bibliothek", library),
            act("n", .newNotebook, "Neues Heft", "Bibliothek", library),
            act("N", .newTextDocument, "Neues Textdokument", "Bibliothek", library),
            act("f", .newFolder, "Neuer Ordner", "Bibliothek", library),
            act("r", .renameItem, "Umbenennen", "Bibliothek", library),
            act("d", .trashItem, "In den Papierkorb", "Bibliothek", library),
            act("y", .duplicateItem, "Duplizieren", "Bibliothek", library),
            act("P", .pinItem, "Anheften/Lösen", "Bibliothek", library),
            act("m", .moveItem, "Verschieben", "Bibliothek", library),

            // Page
            act("^d", .scrollScreen(0.5), "Halbe Ansicht runter", "Bewegen", page, repeats: true),
            act("^u", .scrollScreen(-0.5), "Halbe Ansicht hoch", "Bewegen", page, repeats: true),
            act("^f", .scrollScreen(0.9), "Ganze Ansicht runter", "Bewegen", page, repeats: true),
            act("^b", .scrollScreen(-0.9), "Ganze Ansicht hoch", "Bewegen", page, repeats: true),
            act("g g", .firstPage, "Erste Seite", "Gehe zu", page),
            act("g e", .lastPage, "Letzte Seite", "Gehe zu", page),
            act("g n", .page(1), "Nächste Seite", "Gehe zu", page, repeats: true),
            act("g p", .page(-1), "Vorherige Seite", "Gehe zu", page, repeats: true),
            act("G", .gotoPage, "Zur Seite (5G: Seite 5)", "Gehe zu", page),
            act("+", .zoom(1), "Vergrößern", "Ansicht", page, repeats: true),
            act("=", .zoom(1), "Vergrößern", "Ansicht", page, repeats: true),
            act("-", .zoom(-1), "Verkleinern", "Ansicht", page, repeats: true),
            act("<CR>", .write, "Feld bearbeiten oder schreiben", "Objekte", page),
            act("i", .write, "Feld bearbeiten oder schreiben", "Objekte", page),
            act("<Tab>", .nextObject(1), "Nächstes Objekt", "Objekte", page),
            act("<S-Tab>", .nextObject(-1), "Vorheriges Objekt", "Objekte", page),
            act("d", .deleteObject, "Auswahl löschen", "Objekte", page),
            act("y", .copyObject, "Auswahl kopieren", "Objekte", page),
            act("p", .pasteObject, "Einfügen", "Objekte", page),
            act("%", .selectAll, "Alles wählen", "Objekte", page),
            act("D", .duplicateObject, "Auswahl duplizieren", "Objekte", page),

            // Text: motions, in SEL they extend
            edit("w", .word(.nextStart, long: false), "Nächstes Wort", "Bewegen", repeats: true),
            edit("b", .word(.previousStart, long: false), "Vorheriges Wort", "Bewegen", repeats: true),
            edit("e", .word(.nextEnd, long: false), "Wortende", "Bewegen", repeats: true),
            edit("W", .word(.nextStart, long: true), "Nächstes langes Wort", "Bewegen", repeats: true),
            edit("B", .word(.previousStart, long: true), "Vorheriges langes Wort", "Bewegen", repeats: true),
            edit("E", .word(.nextEnd, long: true), "Ende des langen Worts", "Bewegen", repeats: true),
            prompt("f", .findForward), prompt("t", .tillForward), prompt("F", .findBackward), prompt("T", .tillBackward),
            edit("^d", .screen(0.5), "Halbe Ansicht runter", "Bewegen", repeats: true),
            edit("^u", .screen(-0.5), "Halbe Ansicht hoch", "Bewegen", repeats: true),
            edit("^f", .screen(1), "Ganze Ansicht runter", "Bewegen", repeats: true),
            edit("^b", .screen(-1), "Ganze Ansicht hoch", "Bewegen", repeats: true),
            edit("g g", .gotoFileStart, "Textanfang", "Gehe zu"),
            edit("g e", .gotoLastLine, "Letzte Zeile", "Gehe zu"),
            edit("g h", .gotoLineStart, "Zeilenanfang", "Gehe zu"),
            edit("g l", .gotoLineEnd, "Zeilenende", "Gehe zu"),
            edit("g s", .gotoFirstNonBlank, "Erstes Zeichen der Zeile", "Gehe zu"),
            edit("G", .gotoLine, "Zur Zeile (5G: Zeile 5)", "Gehe zu"),

            // Text: selections
            edit("%", .selectAll, "Alles wählen", "Auswahl"),
            edit("x", .extendLine, "Zeile wählen, wiederholt erweitern", "Auswahl", repeats: true),
            edit("X", .extendToLineBounds, "Auf ganze Zeilen erweitern", "Auswahl"),
            edit(";", .collapse, "Auswahl zusammenziehen", "Auswahl"),
            edit("<A-;>", .flip, "Auswahl umdrehen", "Auswahl"),
            edit(",", .keepPrimary, "Nur Hauptauswahl", "Auswahl"),
            edit("C", .copyToNextLine, "Auswahl in die nächste Zeile kopieren", "Auswahl", repeats: true),
            act("s", .selectPrompt, "Treffer in der Auswahl wählen", "Auswahl", text),
            edit("v", .toggleSelect, "Auswahlmodus", "Auswahl"),

            // Text: edits
            edit("d", .delete, "Auswahl löschen", "Ändern"),
            edit("c", .change, "Auswahl ändern", "Ändern"),
            edit("y", .yank, "Auswahl kopieren", "Ändern"),
            edit("p", .paste(before: false), "Einfügen dahinter", "Ändern"),
            edit("P", .paste(before: true), "Einfügen davor", "Ändern"),
            edit("R", .replaceWithRegister, "Durch Kopiertes ersetzen", "Ändern"),
            prompt("r", .replace),
            edit("~", .switchCase, "Groß/klein tauschen", "Ändern"),
            edit("`", .lowercase, "Kleinschreiben", "Ändern"),
            edit("J", .joinLines, "Zeilen verbinden", "Ändern"),
            edit(">", .indent, "Einrücken", "Ändern"),
            edit("<", .unindent, "Ausrücken", "Ändern"),

            // Text: writing
            edit("i", .insert(.before), "Schreiben vor der Auswahl", "Schreiben"),
            edit("a", .insert(.after), "Schreiben hinter der Auswahl", "Schreiben"),
            edit("I", .insert(.lineStart), "Schreiben am Zeilenanfang", "Schreiben"),
            edit("A", .insert(.lineEnd), "Schreiben am Zeilenende", "Schreiben"),
            edit("o", .insert(.lineBelow), "Neue Zeile darunter", "Schreiben"),
            edit("O", .insert(.lineAbove), "Neue Zeile darüber", "Schreiben"),

            // Text: search
            act("/", .searchPrompt(backward: false), "Im Text suchen", "Suchen", text),
            act("?", .searchPrompt(backward: true), "Im Text rückwärts suchen", "Suchen", text),
            edit("n", .searchNext, "Nächster Treffer", "Suchen", repeats: true),
            edit("N", .searchPrevious, "Vorheriger Treffer", "Suchen", repeats: true),
            edit("*", .searchSelection, "Auswahl als Suchbegriff", "Suchen"),

            // Text: the `m` menu
            edit("m m", .matchBracket, "Passende Klammer", "Auswählen und umschließen"),
            prompt("m i", .inside), prompt("m a", .around),
            prompt("m s", .surroundAdd), prompt("m d", .surroundDelete), prompt("m r", .surroundReplace)
        ]

        // `hjkl` and the arrows in every context.
        let directions: [(String, String, TextEngine.Direction, Int, Int, String)] = [
            ("h", "<Left>", .left, -1, 0, "links"), ("j", "<Down>", .down, 0, 1, "unten"),
            ("k", "<Up>", .up, 0, -1, "oben"), ("l", "<Right>", .right, 1, 0, "rechts")]
        for (letter, arrow, direction, x, y, name) in directions {
            for key in [letter, arrow] {
                rows.append(act(key, .focusItem(dx: x, dy: y), "Nach \(name)", "Bibliothek", library, repeats: true))
                rows.append(act(key, .scroll(x: x, y: y), "Nach \(name)", "Bewegen", page, repeats: true))
                rows.append(edit(key, .move(direction), "Nach \(name)", "Bewegen", repeats: true))
            }
        }
        // The same tools under `t` (page only: in a text `t` is a motion) and `Space t`.
        let tools: [(String, WritingTool, String)] = [
            ("p", .pen, "Stift"), ("b", .pencil, "Bleistift"), ("m", .marker, "Marker"), ("e", .strokeEraser, "Radierer (Strich)"),
            ("E", .precisionEraser, "Radierer (genau)"), ("l", .inkSelection, "Lasso"), ("s", .shape, "Formen"), ("i", .image, "Bilder"),
            ("t", .text, "Text"), ("L", .laser, "Laserpointer"), ("r", .read, "Lesen")]
        for (key, tool, title) in tools {
            rows.append(act("t \(key)", .tool(tool), title, "Werkzeuge", page))
            rows.append(act("<Space> t \(key)", .tool(tool), title, "Werkzeuge", editor))
        }
        return rows
    }()

    private static let index: [HelixContext: [String: HelixBinding]] = {
        var result: [HelixContext: [String: HelixBinding]] = [:]
        for binding in bindings { for context in binding.contexts { result[context, default: [:]][binding.keys] = binding } }
        return result
    }()

    public static func binding(_ keys: String, in context: HelixContext) -> HelixBinding? { index[context]?[keys] }

    /// The rows of a context in table order.
    public static func rows(in context: HelixContext) -> [HelixBinding] { bindings.filter { $0.contexts.contains(context) } }

    /// The next keys behind a menu or waiting key; nil for anything else.
    public static func menu(_ keys: String, in context: HelixContext) -> HelixMenu? {
        guard let node = binding(keys, in: context) else { return nil }
        if case .prompt(let prompt) = node.target { return HelixMenu(title: prompt.title, entries: prompt.choices) }
        guard node.target == .menu else { return nil }
        let depth = node.tokens.count + 1
        let entries = rows(in: context).filter { $0.tokens.count == depth && Array($0.tokens.dropLast()) == node.tokens }.map {
            HelixMenu.Entry(key: $0.tokens[depth - 1], title: $0.title, isMenu: $0.action == nil)
        }
        return HelixMenu(title: node.title, entries: entries)
    }

    /// Every runnable command by name, for the palette.
    public static func commands(in context: HelixContext) -> [HelixBinding] {
        var seen = Set<String>()
        return rows(in: context).filter { row in
            guard let action = row.action, action != .palette, action != .escape else { return false }
            return seen.insert(row.title).inserted
        }
    }

    /// The overview: groups in table order, each title once.
    public static func groups(in context: HelixContext) -> [(name: String, rows: [HelixBinding])] {
        var order: [String] = [], rows: [String: [HelixBinding]] = [:], seen = Set<String>()
        for row in Self.rows(in: context) where row.target != .menu && seen.insert(row.group + row.title).inserted {
            if rows[row.group] == nil { order.append(row.group) }
            rows[row.group, default: []].append(row)
        }
        return order.map { ($0, rows[$0] ?? []) }
    }

    /// A token as it reads on the keyboard.
    public static func label(_ token: String) -> String {
        switch token {
        case "<Space>": return "Space"
        case "<CR>": return "Enter"
        case "<Esc>": return "Esc"
        case "<Tab>": return "Tab"
        case "<S-Tab>": return "⇧Tab"
        case "<BS>": return "⌫"
        case "<Left>": return "←"
        case "<Right>": return "→"
        case "<Up>": return "↑"
        case "<Down>": return "↓"
        default: break
        }
        if token.hasPrefix("<A-"), token.hasSuffix(">") { return "⌥" + token.dropFirst(3).dropLast() }
        if token.count == 2, token.hasPrefix("^") { return "⌃" + token.dropFirst() }
        return token
    }
    /// Tokens side by side, a named first key set apart: `gg`, `Space tp`.
    public static func label(_ tokens: [String]) -> String {
        guard let first = tokens.first else { return "" }
        let rest = tokens.dropFirst().map(label).joined()
        return label(first) + (label(first).count > 1 && !rest.isEmpty ? " " : "") + rest
    }
}
