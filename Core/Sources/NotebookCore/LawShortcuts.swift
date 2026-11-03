import Foundation

/// Tastenkürzel der Gesetzessammlung für eine normale Hardwaretastatur
/// (docs/KEYBOARD.md, „Gesetzessammlung“; Paket B2 in docs/LAW-REWORK.md).
/// Eine Tabelle für App-Menü, UIKeyCommands und Hilfeanzeige; die Tests
/// prüfen Eindeutigkeit je Kontext, die Sperrliste und jede Überschneidung
/// mit den Kürzeln des Hefts. Die Helix-Tasten (`GESETZE`) stehen weiter in
/// `HelixKeymap`.
public enum LawShortcuts {
    /// Wo ein Kürzel gilt.
    public enum Context: String, Sendable, CaseIterable {
        /// Im geöffneten Heft, solange die Sammlung eingeschaltet ist (Menü „Gesetze“).
        case notebook
        /// Zusätzlich, solange das Gesetzesfenster den Tastaturfokus hat.
        case focus
    }

    /// Wie ein Kürzel ankommt.
    public enum Route: String, Sendable {
        /// Eintrag im App-Menü (Menüleiste, ⌘-Übersicht). Wirkt unabhängig
        /// davon, welche Ansicht gerade First Responder ist (Suchfeld,
        /// Gesetzestext, Tastenempfänger).
        case menu
        /// `UIKeyCommand` mit `discoverabilityTitle` am Tastenempfänger des
        /// Gesetzesfensters: Tasten ohne ⌘, die sonst Text wären, und ⌘Z, das
        /// im Menü mit „Bearbeiten › Widerrufen“ des Systems zusammenstieße.
        case keyCommand
    }

    /// Reihenfolge wie auf dem Mac: ⌃⌥⇧⌘.
    public enum Modifier: Int, Sendable, CaseIterable, Comparable {
        case control, option, shift, command
        public var symbol: String {
            switch self {
            case .control: "⌃"
            case .option: "⌥"
            case .shift: "⇧"
            case .command: "⌘"
            }
        }
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public enum Key: Hashable, Sendable {
        /// Kleinbuchstabe, Ziffer oder Zeichen (`+`, `-`, `` ` ``, `,`).
        case character(String)
        case escape, enter, space, delete, tab, up, down, left, right
        public var symbol: String {
            switch self {
            case .character(let value): value.uppercased()
            case .escape: "Esc"
            case .enter: "↩"
            case .space: "Leertaste"
            case .delete: "⌫"
            case .tab: "⇥"
            case .up: "↑"
            case .down: "↓"
            case .left: "←"
            case .right: "→"
            }
        }
    }

    /// Eine Tastenkombination.
    public struct Combo: Hashable, Sendable, CustomStringConvertible {
        public let key: Key
        public let modifiers: Set<Modifier>
        public init(_ key: Key, _ modifiers: Set<Modifier> = []) { self.key = key; self.modifiers = modifiers }
        public init(_ character: String, _ modifiers: Set<Modifier> = []) { self.init(.character(character), modifiers) }
        /// `⇧⌘L`, `⌥↑`, `Leertaste`.
        public var label: String { modifiers.sorted().map(\.symbol).joined() + key.symbol }
        public var description: String { label }
        public var usesCommand: Bool { modifiers.contains(.command) }
    }

    public enum Action: Hashable, Sendable {
        // Fenster (Menü „Gesetze“)
        /// Öffnen und Fokus, oder schließen, wenn es sichtbar ist.
        case toggleWindow
        /// An den Rand schieben oder vom Rand holen.
        case parkWindow
        /// Fenster zeigen, Fokus in die Schnellsuche (Fundstelle wie „144 HGB“).
        case lookup
        case dock(LawPanelEdge)
        case float
        // Gesetzfokus
        /// Eine Ebene: Auswahl/gewählte Markierung, dann Eingabefeld, dann Fenster schließen.
        case escape
        /// Im offenen Gesetz suchen (Menütitel von ⌘F wechselt).
        case find
        case hit(forward: Bool)
        /// Vorige (-1) oder nächste (1) Vorschrift.
        case section(Int)
        case scrollLines(Int)
        /// Eine Ansicht weiter (1) oder zurück (-1).
        case scrollScreens(Int)
        case edge(end: Bool)
        /// Größer (1), kleiner (-1), Standard (0).
        case font(Int)
        case bookmark, chooseLaw, contents, list, toggleView
        /// Farbe 1–5 der Markierpalette (`colorNames`).
        case color(Int)
        case lastColor
        case removeMark
        case undoMark, redoMark
    }

    public struct Shortcut: Hashable, Sendable {
        /// Eindeutig; wird in der App als `propertyList` der UIKeyCommands benutzt.
        public let id: String
        public let action: Action
        public let context: Context
        public let route: Route
        /// nil: nur als Menüeintrag ohne Kürzel.
        public let combo: Combo?
        public let title: String
        public let group: String
        /// Nur bei Textauswahl oder gewählter Markierung angeboten; sonst
        /// bleibt die Taste frei (⌫, Ziffern).
        public let requiresSelection: Bool
        /// Was die Taste im Heft ohne Gesetzfokus tut; der Fokus übernimmt sie
        /// bewusst (Konfliktauflösung, siehe Tests).
        public let displaces: String?
        /// In Menü und ⌘-Übersicht verborgen (Zweitbelegung derselben Aktion).
        public let hidden: Bool
        public var label: String { combo?.label ?? "" }
    }

    /// Namen der fünf Markierfarben in der Reihenfolge von `LawPenMode.presets`.
    public static let colorNames = ["Gelb", "Grün", "Blau", "Rosa", "Orange"]

    public static let all: [Shortcut] = {
        func row(_ id: String, _ action: Action, _ context: Context, _ route: Route, _ combo: Combo?, _ title: String, _ group: String,
                 selection: Bool = false, displaces: String? = nil, hidden: Bool = false) -> Shortcut {
            Shortcut(id: id, action: action, context: context, route: route, combo: combo, title: title, group: group,
                     requiresSelection: selection, displaces: displaces, hidden: hidden)
        }
        let window = "Fenster", find = "Suchen", move = "Lesen", view = "Ansicht", mark = "Markieren"
        var rows: [Shortcut] = [
            // Im Heft (Menü „Gesetze“), mit und ohne Fokus.
            row("window.toggle", .toggleWindow, .notebook, .menu, Combo("l", [.command, .shift]), "Gesetzessammlung öffnen/schließen", window),
            row("window.park", .parkWindow, .notebook, .menu, Combo("l", [.command, .option]), "An den Rand/Vom Rand holen", window),
            row("window.lookup", .lookup, .notebook, .menu, Combo("l", [.command]), "Fundstelle suchen", window),
            // ⌃⌘Pfeil liegt zu nah an der Fensteranordnung von iPadOS (🌐⌃Pfeil,
            // auf Tastaturen ohne 🌐 umgelegt): nur Menüeinträge.
            row("window.dock.left", .dock(.left), .notebook, .menu, nil, "Links andocken", window),
            row("window.dock.right", .dock(.right), .notebook, .menu, nil, "Rechts andocken", window),
            row("window.dock.bottom", .dock(.bottom), .notebook, .menu, nil, "Unten andocken", window),
            row("window.float", .float, .notebook, .menu, nil, "Über dem Heft schweben", window),

            // Gesetzfokus: ⌘-Kürzel im Menü, damit sie aus jedem Teil des Fensters wirken.
            row("focus.find", .find, .focus, .menu, Combo("f", [.command]), "Im Gesetz suchen", find, displaces: "Im Heft suchen"),
            row("focus.hit.next", .hit(forward: true), .focus, .menu, Combo("g", [.command]), "Nächster Treffer", find, displaces: "Gehe zu Seite"),
            row("focus.hit.previous", .hit(forward: false), .focus, .menu, Combo("g", [.command, .shift]), "Vorheriger Treffer", find),
            row("focus.top", .edge(end: false), .focus, .menu, Combo(.up, [.command]), "Anfang der Vorschrift", move, displaces: "Vorherige Seite"),
            row("focus.bottom", .edge(end: true), .focus, .menu, Combo(.down, [.command]), "Ende der Vorschrift", move, displaces: "Nächste Seite"),
            row("focus.font.larger", .font(1), .focus, .menu, Combo("+", [.command]), "Schrift größer", view, displaces: "Schrift größer (Text)"),
            row("focus.font.smaller", .font(-1), .focus, .menu, Combo("-", [.command]), "Schrift kleiner", view, displaces: "Schrift kleiner (Text)"),
            row("focus.font.reset", .font(0), .focus, .menu, Combo("0", [.command]), "Standardschrift", view),
            row("focus.bookmark", .bookmark, .focus, .menu, Combo("d", [.command]), "Lesezeichen setzen/entfernen", view, displaces: "Duplizieren"),
            row("focus.choose", .chooseLaw, .focus, .menu, Combo("t", [.command]), "Gesetz wählen", view),
            row("focus.contents", .contents, .focus, .menu, Combo("t", [.command, .shift]), "Inhaltsverzeichnis", view),
            row("focus.list", .list, .focus, .menu, Combo("b", [.command, .option]), "Lesezeichen und Markierungen", view),
            row("focus.view", .toggleView, .focus, .menu, Combo("p", [.command, .option]), "Lesetext oder PDF", view),
            row("focus.color.last", .lastColor, .focus, .menu, Combo("h", [.command, .shift]), "Mit letzter Farbe markieren", mark, selection: true, displaces: "Markieren (Text)"),

            // Gesetzfokus: Tasten ohne ⌘ und ⌘Z als UIKeyCommand am Fenster.
            row("focus.escape", .escape, .focus, .keyCommand, Combo(.escape), "Auswahl aufheben, Eingabe verlassen, schließen", move),
            row("focus.enter.next", .hit(forward: true), .focus, .keyCommand, Combo(.enter), "Nächster Treffer", find),
            row("focus.enter.previous", .hit(forward: false), .focus, .keyCommand, Combo(.enter, [.shift]), "Vorheriger Treffer", find),
            row("focus.section.previous", .section(-1), .focus, .keyCommand, Combo(.left), "Vorherige Vorschrift", move),
            row("focus.section.next", .section(1), .focus, .keyCommand, Combo(.right), "Nächste Vorschrift", move),
            row("focus.line.up", .scrollLines(-1), .focus, .keyCommand, Combo(.up), "Nach oben scrollen", move),
            row("focus.line.down", .scrollLines(1), .focus, .keyCommand, Combo(.down), "Nach unten scrollen", move),
            row("focus.screen.up", .scrollScreens(-1), .focus, .keyCommand, Combo(.up, [.option]), "Eine Ansicht zurück", move),
            row("focus.screen.down", .scrollScreens(1), .focus, .keyCommand, Combo(.down, [.option]), "Eine Ansicht weiter", move),
            row("focus.space.down", .scrollScreens(1), .focus, .keyCommand, Combo(.space), "Eine Ansicht weiter", move, hidden: true),
            row("focus.space.up", .scrollScreens(-1), .focus, .keyCommand, Combo(.space, [.shift]), "Eine Ansicht zurück", move, hidden: true),
            row("focus.remove", .removeMark, .focus, .keyCommand, Combo(.delete), "Markierung entfernen", mark, selection: true),
            row("focus.undo", .undoMark, .focus, .keyCommand, Combo("z", [.command]), "Markierung rückgängig", mark, displaces: "Rückgängig (Heft)"),
            row("focus.redo", .redoMark, .focus, .keyCommand, Combo("z", [.command, .shift]), "Markierung wiederholen", mark, displaces: "Wiederholen (Heft)"),
        ]
        for (index, name) in colorNames.enumerated() {
            let number = index + 1
            rows.append(row("focus.color.\(number)", .color(number), .focus, .keyCommand, Combo("\(number)"), "\(name) markieren", mark, selection: true))
        }
        return rows
    }()

    /// Was in einem Kontext gilt: beim Gesetzfokus auch das Menü „Gesetze“.
    public static func shortcuts(in context: Context) -> [Shortcut] {
        all.filter { context == .focus || $0.context == context }
    }
    public static func shortcut(id: String) -> Shortcut? { all.first { $0.id == id } }
    /// Die Zeile einer Kombination, die in diesem Kontext gilt.
    public static func shortcut(for combo: Combo, in context: Context) -> Shortcut? {
        shortcuts(in: context).first { $0.combo == combo }
    }

    /// Nie belegen: System, iPadOS-Fenster und App-weite Kürzel. 🌐-Kombinationen
    /// sind hier nicht darstellbar und kommen in der Tabelle nicht vor.
    public static let reserved: [(combo: Combo, reason: String)] = [
        (Combo("h", [.command]), "Home-Bildschirm"),
        (Combo(.space, [.command]), "Spotlight"),
        (Combo(.tab, [.command]), "App-Umschalter"),
        (Combo(.tab, [.command, .shift]), "App-Umschalter rückwärts"),
        (Combo("3", [.command, .shift]), "Bildschirmfoto"),
        (Combo("4", [.command, .shift]), "Bildschirmfoto (Ausschnitt)"),
        (Combo("5", [.command, .shift]), "Bildschirmaufnahme"),
        (Combo("d", [.command, .option]), "Dock"),
        (Combo("w", [.command]), "Heft schließen"),
        (Combo(",", [.command]), "Einstellungen"),
        (Combo("q", [.command]), "App beenden"),
        (Combo("m", [.command]), "Fenster minimieren"),
        (Combo("f", [.command, .control]), "Vollbild"),
        (Combo("`", [.command]), "Nächstes Fenster"),
        (Combo("p", [.command, .shift]), "Befehlspalette"),
        (Combo("/", [.command]), "Tastenübersicht"),
    ]

    /// Was das Heft bereits belegt (Menü „Heft“, Seitennavigator, Texte,
    /// Objektauswahl, Bearbeiten-Menü des Systems). Ein Kürzel im Kontext
    /// `notebook` darf keines davon treffen; im Kontext `focus` nur mit `displaces`.
    public static let notebookShortcuts: [(combo: Combo, title: String)] = [
        (Combo("f", [.command]), "Im Heft suchen"),
        (Combo("s", [.command]), "Jetzt speichern"),
        (Combo("e", [.command]), "Als PDF exportieren"),
        (Combo("e", [.command, .shift]), "Diese Seite als PDF"),
        (Combo(.up, [.command]), "Vorherige Seite"),
        (Combo(.down, [.command]), "Nächste Seite"),
        (Combo("g", [.command]), "Gehe zu Seite"),
        (Combo("z", [.command]), "Rückgängig"),
        (Combo("z", [.command, .shift]), "Wiederholen"),
        (Combo("a", [.command]), "Alles auswählen"),
        (Combo("c", [.command]), "Kopieren"),
        (Combo("x", [.command]), "Ausschneiden"),
        (Combo("v", [.command]), "Einfügen"),
        (Combo("d", [.command]), "Duplizieren"),
        (Combo("b", [.command]), "Fett"),
        (Combo("i", [.command]), "Kursiv"),
        (Combo("u", [.command]), "Unterstrichen"),
        (Combo("x", [.command, .shift]), "Durchgestrichen"),
        (Combo("1", [.command]), "Titel"),
        (Combo("2", [.command]), "Überschrift"),
        (Combo("3", [.command]), "Unterüberschrift"),
        (Combo("4", [.command]), "Text"),
        (Combo("+", [.command]), "Schrift größer"),
        (Combo("=", [.command]), "Schrift größer"),
        (Combo("-", [.command]), "Schrift kleiner"),
        (Combo("7", [.command, .shift]), "Aufzählung"),
        (Combo("8", [.command, .shift]), "Nummerierung"),
        (Combo("9", [.command, .shift]), "Checkliste"),
        (Combo("k", [.command]), "Link"),
        (Combo("h", [.command, .shift]), "Markieren"),
        (Combo(.enter, [.command]), "Seitenumbruch"),
        (Combo("n", [.command]), "Neues Heft"),
        (Combo("n", [.command, .shift]), "Neues Textdokument"),
    ]

    /// Kurze Übersicht für die Hilfe im Leser: Gruppen in Tabellenreihenfolge,
    /// je Titel eine Zeile mit allen Tasten (`⌘G, ↩`), auch den in der
    /// ⌘-Übersicht verborgenen Zweitbelegungen.
    public static func overview(in context: Context = .focus) -> [(group: String, rows: [(keys: String, title: String)])] {
        var order: [String] = [], rows: [String: [(keys: String, title: String)]] = [:]
        for shortcut in shortcuts(in: context) where shortcut.combo != nil {
            if rows[shortcut.group] == nil { order.append(shortcut.group) }
            if let index = rows[shortcut.group]?.firstIndex(where: { $0.title == shortcut.title }) {
                rows[shortcut.group]?[index].keys += ", " + shortcut.label
            } else {
                rows[shortcut.group, default: []].append((shortcut.label, shortcut.title))
            }
        }
        return order.map { ($0, rows[$0] ?? []) }
    }
}
