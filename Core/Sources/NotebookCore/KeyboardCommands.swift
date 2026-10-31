import Foundation

/// The keyboard mode (docs/KEYBOARD.md): vim-like control of the whole app
/// from a hardware keyboard. This file is the pure part: which key sequence
/// means what in which context. The app turns key presses into tokens
/// (`j`, `G`, `:`, `^d`, `<CR>`, `<Esc>`) and runs the resulting actions.
public enum KeyContext: String, Sendable, CaseIterable {
    /// Library: items are focused and opened.
    case library
    /// Editor without caret: the view scrolls, tools change, objects are selected.
    case page
    /// A text with caret, not typing (vim's normal mode).
    case text
    /// A selection grows with the motions.
    case visual
}

public enum TextMotion: String, Sendable, CaseIterable {
    case left, right, up, down
    case wordForward, wordBackward, wordEnd
    case lineStart, lineFirstNonBlank, lineEnd
    case documentStart, documentEnd
    case paragraphBackward, paragraphForward
    /// Only after an operator: the word under the caret (`diw`).
    case innerWord
}

public enum TextOperator: String, Sendable, CaseIterable { case delete, change, yank }

/// Where typing starts when leaving normal mode.
public enum TextInsertEntry: String, Sendable { case here, afterCaret, lineStart, lineEnd, lineBelow, lineAbove }

public enum KeyAction: Equatable, Sendable {
    // Anywhere
    case help, palette, search, undo, redo, cancel
    // Library
    case focusItem(dx: Int, dy: Int), focusFirstItem, focusLastItem, openItem, parentFolder
    case newNotebook, newTextDocument, newFolder, renameItem, trashItem, duplicateItem, pinItem, moveItem, exportItem, shareItem
    // Editor without caret
    case scroll(x: Int, y: Int), scrollScreen(Double), page(Int), firstPage, lastPage
    case fit, zoom(Int), tool(WritingTool), write(TextInsertEntry)
    case nextObject(Int), editObject, deleteObject, copyObject, cutObject, pasteObject, duplicateObject, selectAll
    case sidebar, outline, close, bookmark, pageEntry, save
    // Text
    case move(TextMotion), insert(TextInsertEntry), operate(TextOperator, TextMotion), operateLine(TextOperator)
    case operateSelection(TextOperator), paste(before: Bool), deleteCharacter(before: Bool), joinLines
    case visual(line: Bool)
}

/// One row of the keymap; also the help overlay and the command palette.
public struct KeyBinding: Sendable {
    /// Tokens separated by a space: `g g`, `^d`, `<CR>`.
    public let keys: String
    public let action: KeyAction
    public let title: String
    public let group: String
    public let contexts: Set<KeyContext>
    /// Holding the key repeats it.
    public let repeats: Bool
    public var tokens: [String] { keys.split(separator: " ").map(String.init) }
    init(_ keys: String, _ action: KeyAction, _ title: String, _ group: String, _ contexts: Set<KeyContext>, repeats: Bool = false) {
        self.keys = keys; self.action = action; self.title = title; self.group = group
        self.contexts = contexts; self.repeats = repeats
    }
}

public enum KeyMap {
    /// Motions after an operator (`d2w`, `dgg`, `ciw`), also in normal and visual mode.
    public static let motions: [String: TextMotion] = [
        "h": .left, "l": .right, "j": .down, "k": .up, "w": .wordForward, "b": .wordBackward, "e": .wordEnd,
        "0": .lineStart, "^": .lineFirstNonBlank, "$": .lineEnd, "g g": .documentStart, "G": .documentEnd,
        "{": .paragraphBackward, "}": .paragraphForward]
    public static let operators: [String: TextOperator] = ["d": .delete, "c": .change, "y": .yank]

    public static let bindings: [KeyBinding] = {
        let anywhere: Set<KeyContext> = [.library, .page, .text, .visual]
        let library: Set<KeyContext> = [.library], page: Set<KeyContext> = [.page]
        let text: Set<KeyContext> = [.text], typing: Set<KeyContext> = [.text, .visual]
        let editor: Set<KeyContext> = [.page, .text, .visual]
        var rows: [KeyBinding] = [
            .init(":", .palette, "Befehlspalette (alle Funktionen)", "Überall", anywhere),
            .init("?", .help, "Diese Übersicht", "Überall", anywhere),
            .init("/", .search, "Suchen", "Überall", anywhere),

            .init("j", .focusItem(dx: 0, dy: 1), "Nach unten", "Bibliothek", library, repeats: true),
            .init("k", .focusItem(dx: 0, dy: -1), "Nach oben", "Bibliothek", library, repeats: true),
            .init("h", .focusItem(dx: -1, dy: 0), "Nach links", "Bibliothek", library, repeats: true),
            .init("l", .focusItem(dx: 1, dy: 0), "Nach rechts", "Bibliothek", library, repeats: true),
            .init("<Down>", .focusItem(dx: 0, dy: 1), "Nach unten", "Bibliothek", library, repeats: true),
            .init("<Up>", .focusItem(dx: 0, dy: -1), "Nach oben", "Bibliothek", library, repeats: true),
            .init("<Left>", .focusItem(dx: -1, dy: 0), "Nach links", "Bibliothek", library, repeats: true),
            .init("<Right>", .focusItem(dx: 1, dy: 0), "Nach rechts", "Bibliothek", library, repeats: true),
            .init("g g", .focusFirstItem, "Erster Eintrag", "Bibliothek", library),
            .init("G", .focusLastItem, "Letzter Eintrag", "Bibliothek", library),
            .init("<CR>", .openItem, "Öffnen", "Bibliothek", library),
            .init("o", .openItem, "Öffnen", "Bibliothek", library),
            .init("-", .parentFolder, "Übergeordneter Ordner", "Bibliothek", library),
            .init("<BS>", .parentFolder, "Übergeordneter Ordner", "Bibliothek", library),
            .init("n", .newNotebook, "Neues Heft", "Bibliothek", library),
            .init("N", .newTextDocument, "Neues Textdokument", "Bibliothek", library),
            .init("f", .newFolder, "Neuer Ordner", "Bibliothek", library),
            .init("r", .renameItem, "Umbenennen", "Bibliothek", library),
            .init("d d", .trashItem, "In den Papierkorb", "Bibliothek", library),
            .init("y y", .duplicateItem, "Duplizieren", "Bibliothek", library),
            .init("P", .pinItem, "Anheften/Lösen", "Bibliothek", library),
            .init("m", .moveItem, "Verschieben", "Bibliothek", library),
            .init("e", .exportItem, "Als PDF exportieren", "Bibliothek", library),
            .init("s", .shareItem, "Als .noty teilen", "Bibliothek", library),

            .init("j", .scroll(x: 0, y: 1), "Nach unten scrollen", "Bewegen", page, repeats: true),
            .init("k", .scroll(x: 0, y: -1), "Nach oben scrollen", "Bewegen", page, repeats: true),
            .init("h", .scroll(x: -1, y: 0), "Nach links scrollen", "Bewegen", page, repeats: true),
            .init("l", .scroll(x: 1, y: 0), "Nach rechts scrollen", "Bewegen", page, repeats: true),
            .init("<Down>", .scroll(x: 0, y: 1), "Nach unten scrollen", "Bewegen", page, repeats: true),
            .init("<Up>", .scroll(x: 0, y: -1), "Nach oben scrollen", "Bewegen", page, repeats: true),
            .init("<Left>", .scroll(x: -1, y: 0), "Nach links scrollen", "Bewegen", page, repeats: true),
            .init("<Right>", .scroll(x: 1, y: 0), "Nach rechts scrollen", "Bewegen", page, repeats: true),
            .init("^d", .scrollScreen(0.5), "Halbe Ansicht runter", "Bewegen", page, repeats: true),
            .init("^u", .scrollScreen(-0.5), "Halbe Ansicht hoch", "Bewegen", page, repeats: true),
            .init("^f", .scrollScreen(0.9), "Ganze Ansicht runter", "Bewegen", page, repeats: true),
            .init("^b", .scrollScreen(-0.9), "Ganze Ansicht hoch", "Bewegen", page, repeats: true),
            .init("<Space>", .scrollScreen(0.9), "Ganze Ansicht runter", "Bewegen", page, repeats: true),
            .init("<S-Space>", .scrollScreen(-0.9), "Ganze Ansicht hoch", "Bewegen", page, repeats: true),
            .init("J", .page(1), "Nächste Seite", "Bewegen", page, repeats: true),
            .init("K", .page(-1), "Vorherige Seite", "Bewegen", page, repeats: true),
            .init("]", .page(1), "Nächste Seite", "Bewegen", page, repeats: true),
            .init("[", .page(-1), "Vorherige Seite", "Bewegen", page, repeats: true),
            .init("g g", .firstPage, "Erste Seite (5gg: Seite 5)", "Bewegen", page),
            .init("G", .lastPage, "Letzte Seite (5G: Seite 5)", "Bewegen", page),
            .init("g p", .pageEntry, "Seite eingeben", "Bewegen", page),
            .init("z z", .fit, "Einpassen", "Ansicht", page),
            .init("+", .zoom(1), "Vergrößern", "Ansicht", page, repeats: true),
            .init("=", .zoom(1), "Vergrößern", "Ansicht", page, repeats: true),
            .init("-", .zoom(-1), "Verkleinern", "Ansicht", page, repeats: true),
            .init("g s", .sidebar, "Seitenleiste", "Ansicht", editor),
            .init("g o", .outline, "Gliederung/Inhalt", "Ansicht", editor),

            .init("t p", .tool(.pen), "Stift", "Werkzeuge", page),
            .init("t b", .tool(.pencil), "Bleistift", "Werkzeuge", page),
            .init("t m", .tool(.marker), "Marker", "Werkzeuge", page),
            .init("t e", .tool(.strokeEraser), "Radierer (Strich)", "Werkzeuge", page),
            .init("t E", .tool(.precisionEraser), "Radierer (genau)", "Werkzeuge", page),
            .init("t l", .tool(.inkSelection), "Lasso", "Werkzeuge", page),
            .init("t s", .tool(.shape), "Formen", "Werkzeuge", page),
            .init("t i", .tool(.image), "Bilder", "Werkzeuge", page),
            .init("t t", .tool(.text), "Text", "Werkzeuge", page),
            .init("t L", .tool(.laser), "Laserpointer", "Werkzeuge", page),
            .init("t r", .tool(.read), "Lesen", "Werkzeuge", page),

            .init("i", .write(.here), "Schreiben (Textdokument: Cursor, Heft: neues Feld)", "Text", page),
            .init("a", .write(.lineEnd), "Am Textende schreiben", "Text", page),

            .init("<Tab>", .nextObject(1), "Nächstes Objekt", "Objekte", page),
            .init("<S-Tab>", .nextObject(-1), "Vorheriges Objekt", "Objekte", page),
            .init("<CR>", .editObject, "Textfeld bearbeiten", "Objekte", page),
            .init("x", .deleteObject, "Auswahl löschen", "Objekte", page),
            .init("d d", .deleteObject, "Auswahl löschen", "Objekte", page),
            .init("y y", .copyObject, "Auswahl kopieren", "Objekte", page),
            .init("X", .cutObject, "Auswahl ausschneiden", "Objekte", page),
            .init("p", .pasteObject, "Einfügen", "Objekte", page),
            .init("D", .duplicateObject, "Auswahl duplizieren", "Objekte", page),
            .init("A", .selectAll, "Alles wählen (Heft: Seite, Textdokument: ganzer Text)", "Objekte", page),

            .init("m", .bookmark, "Lesezeichen", "Dokument", page),
            .init("g q", .close, "Schließen", "Dokument", page),
            .init("Z Z", .close, "Speichern und schließen", "Dokument", page),
            .init("<Esc>", .cancel, "Auswahl aufheben / Text verlassen", "Überall", editor),
            .init("^[", .cancel, "Wie Esc", "Überall", editor),
            .init("u", .undo, "Rückgängig", "Bearbeiten", [.page, .text]),
            .init("^r", .redo, "Wiederholen", "Bearbeiten", [.page, .text]),

            .init("i", .insert(.here), "Schreiben am Cursor", "Text", text),
            .init("a", .insert(.afterCaret), "Schreiben hinter dem Cursor", "Text", text),
            .init("I", .insert(.lineStart), "Schreiben am Zeilenanfang", "Text", text),
            .init("A", .insert(.lineEnd), "Schreiben am Zeilenende", "Text", text),
            .init("o", .insert(.lineBelow), "Neue Zeile darunter", "Text", text),
            .init("O", .insert(.lineAbove), "Neue Zeile darüber", "Text", text),
            .init("x", .deleteCharacter(before: false), "Zeichen löschen", "Text", text),
            .init("X", .deleteCharacter(before: true), "Zeichen davor löschen", "Text", text),
            .init("D", .operate(.delete, .lineEnd), "Bis Zeilenende löschen", "Text", text),
            .init("C", .operate(.change, .lineEnd), "Bis Zeilenende ändern", "Text", text),
            .init("S", .operateLine(.change), "Zeile ändern", "Text", text),
            .init("Y", .operateLine(.yank), "Zeile kopieren", "Text", text),
            .init("J", .joinLines, "Zeilen verbinden", "Text", text),
            .init("p", .paste(before: false), "Einfügen dahinter", "Text", text),
            .init("P", .paste(before: true), "Einfügen davor", "Text", text),
            .init("v", .visual(line: false), "Zeichenweise markieren", "Text", typing),
            .init("V", .visual(line: true), "Zeilenweise markieren", "Text", typing),
            .init("d", .operateSelection(.delete), "Markierung löschen", "Text", [.visual]),
            .init("x", .operateSelection(.delete), "Markierung löschen", "Text", [.visual]),
            .init("c", .operateSelection(.change), "Markierung ändern", "Text", [.visual]),
            .init("y", .operateSelection(.yank), "Markierung kopieren", "Text", [.visual]),
            .init("<BS>", .operateSelection(.delete), "Markierung löschen", "Text", [.visual]),
            .init("<BS>", .move(.left), "Zeichen links", "Text", text, repeats: true)
        ]
        let named: [(String, TextMotion, String, Bool)] = [
            ("h", .left, "Zeichen links", true), ("<Left>", .left, "Zeichen links", true),
            ("l", .right, "Zeichen rechts", true), ("<Right>", .right, "Zeichen rechts", true), ("<Space>", .right, "Zeichen rechts", true),
            ("j", .down, "Zeile runter", true), ("<Down>", .down, "Zeile runter", true), ("<CR>", .down, "Zeile runter", true),
            ("k", .up, "Zeile hoch", true), ("<Up>", .up, "Zeile hoch", true),
            ("w", .wordForward, "Nächstes Wort", true), ("b", .wordBackward, "Vorheriges Wort", true), ("e", .wordEnd, "Wortende", true),
            ("0", .lineStart, "Zeilenanfang", false), ("^", .lineFirstNonBlank, "Erstes Zeichen der Zeile", false), ("$", .lineEnd, "Zeilenende", false),
            ("g g", .documentStart, "Textanfang", false), ("G", .documentEnd, "Textende", false),
            ("{", .paragraphBackward, "Vorheriger Absatz", true), ("}", .paragraphForward, "Nächster Absatz", true)]
        rows += named.map { .init($0.0, .move($0.1), $0.2, "Text", typing, repeats: $0.3) }
        rows += [.init("^d", .scrollScreen(0.5), "Halbe Ansicht runter", "Text", typing, repeats: true),
                 .init("^u", .scrollScreen(-0.5), "Halbe Ansicht hoch", "Text", typing, repeats: true)]
        return rows
    }()

    private static let index: [KeyContext: [String: KeyBinding]] = {
        var result: [KeyContext: [String: KeyBinding]] = [:]
        for binding in bindings { for context in binding.contexts { result[context, default: [:]][binding.keys] = binding } }
        return result
    }()
    private static let prefixes: [KeyContext: Set<String>] = index.mapValues { rows in
        var result = Set<String>()
        for keys in rows.keys {
            let tokens = keys.split(separator: " ")
            for length in 1..<max(1, tokens.count) { result.insert(tokens[..<length].joined(separator: " ")) }
        }
        return result
    }
    static func binding(_ keys: String, in context: KeyContext) -> KeyBinding? { index[context]?[keys] }
    static func isPrefix(_ keys: String, in context: KeyContext) -> Bool { prefixes[context]?.contains(keys) == true }
}

public enum KeyParseResult: Equatable, Sendable {
    /// Part of a sequence: nothing happens yet.
    case pending
    /// `count` is 1 unless typed; `explicitCount` tells `5G` from `G`.
    case action(KeyAction, count: Int, explicitCount: Bool, repeats: Bool)
    /// No such command; a started sequence is dropped.
    case unbound
}

/// Turns key tokens into actions: counts (`12j`), sequences (`gg`), operators
/// with a motion (`d2w`, `ciw`) and doubled operators (`dd`).
public struct KeySequenceParser: Sendable {
    private var count: Int?
    private var keys: [String] = []
    private var pendingOperator: TextOperator?
    private var motionCount: Int?
    public init() {}

    public mutating func reset() { count = nil; keys = []; pendingOperator = nil; motionCount = nil }
    public var isIdle: Bool { count == nil && keys.isEmpty && pendingOperator == nil }
    /// What was typed so far, for the mode indicator.
    public var display: String {
        var result = count.map(String.init) ?? ""
        if let pendingOperator { result += ["delete": "d", "change": "c", "yank": "y"][pendingOperator.rawValue] ?? "" }
        if let motionCount { result += String(motionCount) }
        return result + keys.joined()
    }

    public mutating func feed(_ token: String, context: KeyContext) -> KeyParseResult {
        if token == "<Esc>" || token == "^[", !isIdle { reset(); return .pending }
        if let digit = token.first.flatMap({ token.count == 1 ? $0.wholeNumberValue : nil }), keys.isEmpty, extendCount(digit) { return .pending }
        if let pendingOperator { return feedMotion(token, for: pendingOperator) }
        let sequence = (keys + [token]).joined(separator: " ")
        if keys.isEmpty, context == .text, let op = KeyMap.operators[token] { pendingOperator = op; return .pending }
        if let binding = KeyMap.binding(sequence, in: context) {
            defer { reset() }
            return .action(binding.action, count: count ?? 1, explicitCount: count != nil, repeats: binding.repeats)
        }
        if KeyMap.isPrefix(sequence, in: context) { keys.append(token); return .pending }
        reset()
        return .unbound
    }

    /// A digit extends the count; `0` alone stays a command (line start).
    private mutating func extendCount(_ digit: Int) -> Bool {
        if pendingOperator != nil {
            guard digit > 0 || motionCount != nil else { return false }
            motionCount = min(9_999, (motionCount ?? 0) * 10 + digit); return true
        }
        guard digit > 0 || count != nil else { return false }
        count = min(9_999, (count ?? 0) * 10 + digit); return true
    }

    private mutating func feedMotion(_ token: String, for op: TextOperator) -> KeyParseResult {
        let total = (count ?? 1) * (motionCount ?? 1), explicit = count != nil || motionCount != nil
        if keys.isEmpty, KeyMap.operators[token] == op {
            reset(); return .action(.operateLine(op), count: total, explicitCount: explicit, repeats: false)
        }
        if keys == ["i"], token == "w" {
            reset(); return .action(.operate(op, .innerWord), count: 1, explicitCount: false, repeats: false)
        }
        let sequence = (keys + [token]).joined(separator: " ")
        if let motion = KeyMap.motions[sequence] {
            reset(); return .action(.operate(op, motion), count: total, explicitCount: explicit, repeats: false)
        }
        if keys.isEmpty, token == "g" || token == "i" { keys = [token]; return .pending }
        reset()
        return .unbound
    }
}

/// Key-downs by hardware key and press time, never by `UIPress` object: UIKit
/// may reuse that object for the next press of a key. A press the app does not
/// use walks up the responder chain and reaches several views; only that second
/// delivery of one event is refused. A key-up forgets the key, so a press time
/// that stayed the same cannot block the next press; a lost key-up (the focus
/// moved while the key was down) cannot either, the next press has a new time.
public struct KeyPressGate: Sendable {
    private var times: [Int: Double] = [:]
    private var swallowed = Set<Int>()
    public init() {}

    /// False for a second delivery of the same key-down.
    public mutating func began(key: Int, time: Double) -> Bool {
        guard times[key] != time else { return false }
        times[key] = time; swallowed.remove(key)
        return true
    }
    /// This press was used: its key-up stays away from the system too.
    public mutating func swallow(key: Int) { swallowed.insert(key) }
    /// True when the key-up belongs to a swallowed press.
    public mutating func ended(key: Int) -> Bool {
        times[key] = nil
        return swallowed.remove(key) != nil
    }
}

/// Command palette: every action by name, plus vim's `:w`, `:q`, `:wq`, `:12`.
public enum KeyPalette {
    public enum Direct: Equatable, Sendable { case save, close, page(Int) }
    public static func direct(_ query: String) -> Direct? {
        let value = query.trimmingCharacters(in: .whitespaces).lowercased()
        switch value {
        case "w": return .save
        case "q", "wq", "x": return .close
        default: return Int(value).flatMap { $0 > 0 ? .page($0) : nil }
        }
    }
    /// Fuzzy match of `query` in `title`: nil if its letters are not in that
    /// order; a smaller value is better (word starts and neighbours win).
    public static func score(_ query: String, in title: String) -> Int? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        let haystack = Array(title.lowercased())
        guard !needle.isEmpty else { return 0 }
        var score = 0, position = 0, previous = -2
        for letter in needle {
            guard let found = haystack[position...].firstIndex(of: letter) else { return nil }
            let wordStart = found == 0 || !haystack[found - 1].isLetter
            score += found == previous + 1 ? 0 : wordStart ? 1 : 3 + (found - position)
            previous = found; position = found + 1
        }
        return score
    }
}
