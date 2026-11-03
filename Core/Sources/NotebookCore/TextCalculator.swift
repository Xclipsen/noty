import Foundation

/// noty's own calculator, independent of the system's suggestion after „=“.
/// Two ways of writing a calculation, both started by typing „=“:
///
/// - In a line: `2+3=` becomes `2+3=5`, `2 + 3 =` becomes `2 + 3 = 5`: the
///   result is written the way the calculation is.
/// - From top to bottom: numbers below each other and „=“ alone on the next
///   line. Lines count from the top like on a calculator, a line without a
///   sign is added, a rule (`---`) is skipped, and a text in front of the
///   number is a label: `Miete 500`.
///
/// Decimal numbers, so 0,1 + 0,2 is 0,3 and not almost 0,3.
public enum TextCalculator {
    public struct Calculation: Equatable, Sendable {
        public var edit: TextListEditing.Edit
        /// The result in the text after `edit`.
        public var result: NSRange
    }

    /// What typing „=“ at `caret` (behind the sign) calculates, nil for
    /// everything that is no calculation; text then stays as typed.
    public static func calculation(in text: String, caret: Int) -> Calculation? {
        let source = text as NSString
        guard caret >= 1, caret <= source.length, source.character(at: caret - 1) == 61 else { return nil }
        let start = TextLines.start(source, caret - 1)
        var end = caret
        while end < source.length, !TextLines.isBreak(source.character(at: end)) { end += 1 }
        // Only at the end of a line: nothing is inserted into existing text.
        guard source.substring(with: NSRange(location: caret, length: end - caret))
            .trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let line = source.substring(with: NSRange(location: start, length: caret - 1 - start))
        if line.trimmingCharacters(in: .whitespaces).isEmpty { return column(source, sign: caret - 1) }
        return inline(line, lineStart: start, caret: caret)
    }

    private static func inline(_ line: String, lineStart: Int, caret: Int) -> Calculation? {
        guard let expression = expressionTail(of: line), let value = evaluate(expression), let result = format(value) else { return nil }
        let length = (line.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) as NSString).length
        let location = lineStart + length
        let spaced = location < caret - 1 || expression.contains(where: \.isWhitespace)
        let sign = spaced ? " = " : "="
        return Calculation(edit: .init(range: NSRange(location: location, length: caret - location), replacement: sign + result),
                           result: NSRange(location: location + (sign as NSString).length, length: (result as NSString).length))
    }

    /// The calculation at the end of a line: „Summe: 2+3“ is 2+3. What stands
    /// in front must be a label. If it could be part of the expression
    /// („2x + 3 + 4“, „x^2+3“, „sin(30+60)“, „10 € + 5 + 3“), nothing is
    /// calculated: no result is better than a wrong one.
    private static func expressionTail(of line: String) -> String? {
        var scalars: [Character] = []
        for character in line.reversed() {
            guard character.isASCII ? character.isNumber || " \t.,+-*/:^%()".contains(character)
                                    : "−×·÷".contains(character) else { break }
            scalars.insert(character, at: 0)
        }
        var tail = String(scalars).trimmingCharacters(in: .whitespaces)
        if scalars.count < line.count {
            let before = line[line.index(line.endIndex, offsetBy: -(scalars.count + 1))]
            if before.isLetter || before.isNumber, scalars.first?.isNumber == true { return nil }
            if !"=≈".contains(before), tail.range(of: #"^([:.,)]\s+[0-9(]|[0-9])"#, options: .regularExpression) == nil { return nil }
        }
        // „Summe: 2+3“, „a) 2+3“, then numbered labels like „3: 2+3“, „1. 2+3“, „(2) 2+3“.
        if let mark = tail.range(of: #"^[:.,)]\s+"#, options: .regularExpression) { tail.removeSubrange(mark) }
        while let label = tail.range(of: #"^\(?[0-9]+[:.)]\s+"#, options: .regularExpression) { tail.removeSubrange(label) }
        guard isCalculation(tail), evaluate(tail) != nil else { return nil }
        return tail
    }
    /// One number alone is none: „Seite 3=“, „x = 5“.
    private static func isCalculation(_ text: String) -> Bool {
        var seen = false
        for character in text {
            if character.isNumber || character == ")" { seen = true }
            else if seen, "+-−*×·/÷:^%".contains(character) { return true }
        }
        return false
    }

    private static func column(_ source: NSString, sign: Int) -> Calculation? {
        var lines: [String] = [], end = TextLines.start(source, sign)
        var running = false
        while end > 0, !running {
            let start = TextLines.start(source, end - 1)
            let line = source.substring(with: NSRange(location: start, length: end - 1 - start))
                .trimmingCharacters(in: .whitespaces)
            end = start
            if isRule(line) { continue }
            if line.isEmpty { break }
            // An earlier result carries on: „= 12“, then more lines and „=“.
            if line.first == "=" { lines.insert(String(line.dropFirst()), at: 0); running = true; continue }
            guard isColumnLine(line) else { break }
            lines.insert(line, at: 0)
        }
        guard lines.count >= 2, let value = total(lines), let result = format(value) else { return nil }
        let replacement = "= " + result
        return Calculation(edit: .init(range: NSRange(location: sign, length: 1), replacement: replacement),
                           result: NSRange(location: sign + 2, length: (result as NSString).length))
    }
    private static func isRule(_ line: String) -> Bool {
        line.count >= 2 && line.allSatisfy { "-−_=─—–".contains($0) }
    }
    private static func isColumnLine(_ line: String) -> Bool { parts(line) != nil }

    /// Top to bottom, like a calculator: 2, +3, *4 is 20.
    private static func total(_ lines: [String]) -> Decimal? {
        var result: Decimal?
        for line in lines {
            guard let (operation, value, percent) = parts(line) else { return nil }
            guard let current = result else { result = operation == "-" ? -value : value; continue }
            // „+ 10 %“ below a number adds ten percent of it, as in a line.
            let part = percent ? current * value : value
            switch operation {
            case "*": result = current * value
            case "/":
                guard value != 0 else { return nil }
                result = current / value
            case "-": result = current - part
            default: result = current + part
            }
        }
        return result
    }
    /// The sign in front of a line and its value: „- 30“, „× 2“, „12*3“, „Miete 500“.
    private static func parts(_ line: String) -> (Character, Decimal, Bool)? {
        var body = line[...]
        var operation: Character = "+"
        if let first = body.first, let sign = sign(first) { operation = sign; body = body.dropFirst() }
        let text = String(body).trimmingCharacters(in: .whitespaces)
        if let value = evaluate(text) {
            let percent = text.hasSuffix("%") && number(String(text.dropLast()).trimmingCharacters(in: .whitespaces)) != nil
            return (operation, value, percent)
        }
        // A label in front of the number.
        guard let range = text.range(of: #"\s[-−]?[0-9][0-9.,]*$"#, options: .regularExpression),
              text[text.startIndex].isLetter, isLabel(text[..<range.lowerBound]),
              let value = evaluate(String(text[range]).trimmingCharacters(in: .whitespaces)) else { return nil }
        return (operation, value, false)
    }
    /// „Miete“, „Nord-Süd“; „x +“ or „a = b“ are the beginning of an expression.
    private static func isLabel(_ text: Substring) -> Bool {
        !text.contains { "+*×·/÷^=".contains($0) } && text.last.map { !"-−".contains($0) } ?? false
    }
    private static func sign(_ character: Character) -> Character? {
        switch character {
        case "+": "+"
        case "-", "−": "-"
        case "*", "×", "·": "*"
        case "/", "÷", ":": "/"
        default: nil
        }
    }

    // MARK: Evaluating

    /// Value of a calculation, nil when it is none or has no result (division
    /// by zero, overflow). Usual precedence, parentheses, `^` with a whole
    /// exponent; `200 + 10 %` adds ten percent of 200.
    public static func evaluate(_ text: String) -> Decimal? {
        var parser = Parser(Array(text))
        guard let value = parser.sum(), parser.finished, !value.isNaN else { return nil }
        return value
    }

    /// German notation: comma, no grouping, at most ten decimals, nil beyond
    /// the size where digits would be invented.
    public static func format(_ value: Decimal) -> String? {
        guard !value.isNaN, abs(value) < Decimal(sign: .plus, exponent: 30, significand: 1) else { return nil }
        var input = value, rounded = Decimal()
        NSDecimalRound(&rounded, &input, 10, .plain)
        return "\(rounded)".replacingOccurrences(of: ".", with: ",")
    }

    /// Reads „1.234,5“, „1,5“, „3.14“, „1,234.5“.
    static func number(_ text: String) -> Decimal? {
        let comma = text.lastIndex(of: ","), dot = text.lastIndex(of: ".")
        var plain = text
        if let comma, let dot {
            let decimal = comma > dot ? Character(",") : Character(".")
            let grouping = comma > dot ? "." : ","
            plain = text.replacingOccurrences(of: grouping, with: "")
            guard plain.filter({ $0 == decimal }).count == 1 else { return nil }
            plain = plain.replacingOccurrences(of: String(decimal), with: ".")
        } else if comma != nil {
            guard text.filter({ $0 == "," }).count == 1 else { return nil }
            plain = text.replacingOccurrences(of: ",", with: ".")
        } else if dot != nil, text.range(of: #"^[1-9][0-9]{0,2}(\.[0-9]{3})+$"#, options: .regularExpression) != nil {
            plain = text.replacingOccurrences(of: ".", with: "")
        }
        guard plain.range(of: #"^[0-9]*\.?[0-9]+$"#, options: .regularExpression) != nil else { return nil }
        return Decimal(string: plain, locale: Locale(identifier: "en_US_POSIX"))
    }

    private struct Parser {
        let text: [Character]
        var index = 0
        var depth = 0
        init(_ text: [Character]) { self.text = text }

        var finished: Bool { skipped == text.count }
        private var skipped: Int {
            var position = index
            while position < text.count, text[position].isWhitespace { position += 1 }
            return position
        }
        private var next: Character? { skipped < text.count ? text[skipped] : nil }
        private mutating func advance() { index = skipped + 1 }

        mutating func sum() -> Decimal? {
            guard var value = product() else { return nil }
            while let operation = next, "+-−".contains(operation) {
                advance()
                guard let term = product() else { return nil }
                let part = lastWasPercent ? value * term : term
                value = operation == "+" ? value + part : value - part
            }
            return value
        }
        private var lastWasPercent = false
        private mutating func product() -> Decimal? {
            guard var value = unary() else { return nil }
            while let operation = next, "*×·/÷:".contains(operation) {
                advance()
                guard let factor = unary() else { return nil }
                lastWasPercent = false
                if "*×·".contains(operation) { value *= factor } else {
                    guard factor != 0 else { return nil }
                    value /= factor
                }
            }
            return value
        }
        private mutating func power() -> Decimal? {
            guard let base = percent() else { return nil }
            guard next == "^" else { return base }
            advance()
            guard let exponent = unary(), exponent == exponent.rounded(), abs(exponent) <= 1_000 else { return nil }
            lastWasPercent = false
            let whole = NSDecimalNumber(decimal: exponent).intValue
            let raised = Foundation.pow(base, abs(whole))
            guard whole < 0 else { return raised }
            return raised == 0 ? nil : 1 / raised
        }
        /// A sign binds weaker than a power: -2^2 is -4, (-2)^2 is 4.
        private mutating func unary() -> Decimal? {
            if let sign = next, "+-−".contains(sign) {
                advance()
                guard let value = unary() else { return nil }
                return sign == "+" ? value : -value
            }
            return power()
        }
        private mutating func percent() -> Decimal? {
            guard var value = atom() else { return nil }
            lastWasPercent = false
            while next == "%" { advance(); value /= 100; lastWasPercent = true }
            return value
        }
        private mutating func atom() -> Decimal? {
            if next == "(" {
                guard depth < 64 else { return nil }
                advance(); depth += 1
                let value = sum()
                depth -= 1
                guard next == ")" else { return nil }
                advance()
                return value
            }
            let start = skipped
            var end = start
            while end < text.count, text[end].isASCII, text[end].isNumber || text[end] == "." || text[end] == "," { end += 1 }
            guard end > start else { return nil }
            index = end
            return TextCalculator.number(String(text[start..<end]))
        }
    }
}

private extension Decimal {
    func rounded() -> Decimal {
        var input = self, result = Decimal()
        NSDecimalRound(&result, &input, 0, .plain)
        return result
    }
}
