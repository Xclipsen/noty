import Foundation

public enum HelixParseResult: Equatable, Sendable {
    /// Part of a sequence: a count, a menu or a key that waits for a character.
    /// `menu`: what the which-key popup shows now, nil after a bare count.
    case pending(menu: HelixMenu?)
    /// `count` is nil unless typed: `5G` differs from `G`.
    case action(HelixAction, count: Int?, repeats: Bool)
    /// Esc dropped a started sequence; nothing else happens.
    case cancelled
    /// No such command; a started sequence is dropped.
    case unbound
}

/// Turns key tokens into `HelixKeymap` commands: counts (`12j`), menus (`gg`,
/// `<Space> t p`) and keys that take a character (`fx`, `mi(`, `mr([`). Insert
/// mode does not come here: the app only looks for Esc there.
public struct HelixParser: Sendable {
    private var count: Int?
    private var keys: [String] = []
    private var prompt: HelixPrompt?
    /// `mr`: the first of two characters.
    private var replacedPair: String?
    /// The node of the current sequence, for the which-key popup.
    public private(set) var menu: HelixMenu?
    public init() {}

    public mutating func reset() { count = nil; keys = []; prompt = nil; replacedPair = nil; menu = nil }
    public var isIdle: Bool { count == nil && keys.isEmpty }
    /// What was typed so far, for the mode indicator.
    public var display: String {
        (count.map(String.init) ?? "") + HelixKeymap.label(keys) + (replacedPair ?? "")
    }

    public mutating func feed(_ token: String, context: HelixContext) -> HelixParseResult {
        if ["<Esc>", "^[", "^c"].contains(token), !isIdle { reset(); return .cancelled }
        if let prompt { return feedCharacter(token, prompt) }
        if keys.isEmpty, token.count == 1, token.first?.isASCII == true, let digit = token.first?.wholeNumberValue, digit > 0 || count != nil {
            count = min(9_999, (count ?? 0) * 10 + digit)
            return .pending(menu: nil)
        }
        let sequence = (keys + [token]).joined(separator: " ")
        guard let row = HelixKeymap.binding(sequence, in: context) else { reset(); return .unbound }
        switch row.target {
        case .action(let action):
            defer { reset() }
            return .action(action, count: count, repeats: row.repeats)
        case .menu, .prompt:
            keys.append(token)
            if case .prompt(let waiting) = row.target { prompt = waiting }
            menu = HelixKeymap.menu(sequence, in: context)
            return .pending(menu: menu)
        }
    }

    private mutating func feedCharacter(_ token: String, _ prompt: HelixPrompt) -> HelixParseResult {
        guard let character = Self.character(token) else { reset(); return .unbound }
        if prompt == .surroundReplace {
            guard let replaced = replacedPair else {
                replacedPair = character
                menu = HelixMenu(title: "Ersetzen durch", entries: HelixPrompt.surroundAdd.choices)
                return .pending(menu: menu)
            }
            defer { reset() }
            return .action(.text(.surroundReplace(replaced == "m" ? nil : replaced, with: character)), count: count, repeats: false)
        }
        defer { reset() }
        guard let action = prompt.action(character) else { return .unbound }
        return .action(action, count: count, repeats: false)
    }

    /// The text behind a token: a plain character, Enter, Tab or Space.
    private static func character(_ token: String) -> String? {
        switch token {
        case "<CR>": return "\n"
        case "<Tab>": return "\t"
        case "<Space>": return " "
        default: return token.count == 1 ? token : nil
        }
    }
}
