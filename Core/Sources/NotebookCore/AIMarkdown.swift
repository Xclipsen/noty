import Foundation

/// Block structure of an answer. SwiftUI's `Text` drops it, so the panel lays
/// out each block itself; inline formatting stays with `AttributedString`.
public enum AIMarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    /// Consecutive lines, joined by line breaks.
    case paragraph(String)
    /// `marker`: `•` or the number as written (`1.`).
    case listItem(indent: Int, marker: String, text: String)
    case quote(String)
    case code(String)
    case table([[String]])
    case rule
}

public enum AIMarkdownBlocks {
    /// A code block still open at the end (an answer under way) is shown as code.
    public static func parse(_ text: String) -> [AIMarkdownBlock] {
        var parser = AIMarkdownLineParser()
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) { parser.feed(raw) }
        return parser.finish()
    }

    /// A table for a narrow panel: columns padded in a monospaced block,
    /// inline marks removed.
    public static func monospaced(_ rows: [[String]]) -> String {
        let plain = rows.map { $0.map(stripInline) }
        let columns = plain.map(\.count).max() ?? 0
        let widths = (0..<columns).map { column in plain.map { $0.indices.contains(column) ? $0[column].count : 0 }.max() ?? 0 }
        var lines: [String] = []
        for (offset, row) in plain.enumerated() {
            let padded = (0..<columns).map { column -> String in
                let cell = row.indices.contains(column) ? row[column] : ""
                return cell + String(repeating: " ", count: widths[column] - cell.count)
            }
            lines.append(padded.joined(separator: "  ").replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression))
            if offset == 0, plain.count > 1 { lines.append(widths.map { String(repeating: "─", count: $0) }.joined(separator: "  ")) }
        }
        return lines.joined(separator: "\n")
    }

    static func stripInline(_ text: String) -> String {
        var result = text
        for mark in ["**", "__", "`"] { result = result.replacingOccurrences(of: mark, with: "") }
        return result
    }

    static func heading(_ line: String) -> (Int, String)? {
        let level = line.prefix { $0 == "#" }.count
        guard (1...6).contains(level), line.dropFirst(level).first == " " else { return nil }
        return (level, line.dropFirst(level + 1).trimmingCharacters(in: .whitespaces))
    }

    static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        return compact.count >= 3 && (Set(compact) == ["-"] || Set(compact) == ["*"] || Set(compact) == ["_"])
    }

    static func listItem(_ line: String) -> AIMarkdownBlock? {
        let spaces = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let body = line.drop { $0 == " " || $0 == "\t" }
        let indent = spaces / 2
        for bullet in ["- ", "* ", "+ ", "• "] where body.hasPrefix(bullet) {
            return .listItem(indent: indent, marker: "•", text: String(body.dropFirst(2)).trimmingCharacters(in: .whitespaces))
        }
        let digits = body.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = body.dropFirst(digits.count)
        guard let mark = rest.first, mark == "." || mark == ")", rest.dropFirst().first == " " else { return nil }
        return .listItem(indent: indent, marker: digits + ".", text: String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces))
    }

    static func isSeparatorRow(_ line: String) -> Bool {
        let inner = line.replacingOccurrences(of: " ", with: "")
        return inner.count > 2 && inner.allSatisfy { "|-:".contains($0) } && inner.contains("-")
    }

    static func cells(_ line: String) -> [String] {
        var inner = Substring(line)
        if inner.hasPrefix("|") { inner = inner.dropFirst() }
        if inner.hasSuffix("|") { inner = inner.dropLast() }
        return inner.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

/// The block parser, one line at a time. Between two lines it is `idle` when
/// nothing is pending: no paragraph, quote or table being collected and no
/// open code block. Parsing on from an idle point gives the same blocks as a
/// fresh parser, which is what lets a growing answer keep its finished blocks.
struct AIMarkdownLineParser {
    private(set) var blocks: [AIMarkdownBlock] = []
    private var paragraph: [String] = [], quote: [String] = [], code: [String]?, table: [[String]] = []

    var isIdle: Bool { paragraph.isEmpty && quote.isEmpty && table.isEmpty && code == nil }

    private mutating func flush() {
        if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
        if !table.isEmpty { blocks.append(.table(table)); table = [] }
    }

    mutating func feed(_ raw: Substring) {
        let line = String(raw).replacingOccurrences(of: "\r", with: "")
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") {
            if let open = code { blocks.append(.code(open.joined(separator: "\n"))); code = nil } else { flush(); code = [] }
            return
        }
        if code != nil { code?.append(line); return }
        if trimmed.isEmpty { flush(); return }
        if trimmed.hasPrefix("|") {
            if !paragraph.isEmpty || !quote.isEmpty { let rows = table; table = []; flush(); table = rows }
            if !AIMarkdownBlocks.isSeparatorRow(trimmed) { table.append(AIMarkdownBlocks.cells(trimmed)) }
            return
        }
        if !table.isEmpty { flush() }
        if let (level, title) = AIMarkdownBlocks.heading(trimmed) { flush(); blocks.append(.heading(level: level, text: title)); return }
        if AIMarkdownBlocks.isRule(trimmed) { flush(); blocks.append(.rule); return }
        if trimmed.hasPrefix(">") {
            if !paragraph.isEmpty { let rows = quote; quote = []; flush(); quote = rows }
            quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)); return
        }
        if let item = AIMarkdownBlocks.listItem(line) { flush(); blocks.append(item); return }
        if !quote.isEmpty { flush() }
        paragraph.append(trimmed)
    }

    mutating func finish() -> [AIMarkdownBlock] {
        if let code { blocks.append(.code(code.joined(separator: "\n"))); self.code = nil }
        flush()
        return blocks
    }
}
