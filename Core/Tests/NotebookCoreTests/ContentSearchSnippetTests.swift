import Foundation
import XCTest
@testable import NotebookCore

final class ContentSearchSnippetTests: XCTestCase {
    private func hit(_ text: String) -> ContentSearchHit {
        ContentSearchHit(documentID: UUID(), pageID: UUID(), pageNumber: 1, title: "Heft", text: text,
                         kind: .text, bounds: .init(x: 0, y: 0, width: 10, height: 10))
    }

    /// 2 000 characters of words, with `term` inserted at about `offset`.
    private func longText(term: String, at offset: Int) -> String {
        var words = ""
        while words.count < 2_100 { words += "Wort\(words.count % 97) " }
        let filler = Array(words)
        let head = String(filler.prefix(offset)), tail = String(filler.dropFirst(offset))
        return String((head + term + " " + tail).prefix(2_000))
    }

    func testMatchAtStartKeepsTheBeginningWithoutLeadingEllipsis() {
        let snippet = hit(longText(term: "Steuerbescheid", at: 0)).snippet(for: "steuerbescheid")
        XCTAssertFalse(snippet.text.hasPrefix("…"))
        XCTAssertTrue(snippet.text.hasSuffix("…"))
        XCTAssertEqual(snippet.match.map { String(snippet.text[$0]) }, "Steuerbescheid")
        XCTAssertLessThan(snippet.text.count, 120)
    }

    func testMatchInTheMiddleIsShownWithContextOnWordBoundaries() {
        let text = longText(term: "Einspruchsfrist", at: 1_500)
        XCTAssertTrue(hit(text).matches("einspruchsfrist"))
        let snippet = hit(text).snippet(for: "einspruchsfrist", radius: 40)
        XCTAssertTrue(snippet.text.hasPrefix("…"))
        XCTAssertTrue(snippet.text.hasSuffix("…"))
        XCTAssertEqual(snippet.parts.match, "Einspruchsfrist")
        XCTAssertLessThanOrEqual(snippet.text.count, 40 * 2 + "Einspruchsfrist".count + 2)
        // Word boundaries: the context starts and ends with whole words of the source.
        let inner = snippet.text.dropFirst().dropLast()
        XCTAssertTrue(text.contains(inner))
        let words = Set(text.split(separator: " "))
        XCTAssertTrue(words.contains(inner.split(separator: " ").first!))
        XCTAssertTrue(words.contains(inner.split(separator: " ").last!))
    }

    func testMatchAtTheEndHasNoTrailingEllipsis() {
        let text = String(longText(term: "", at: 0).prefix(1_980)) + " Schlusswort"
        let snippet = hit(text).snippet(for: "SCHLUSSWORT")
        XCTAssertTrue(snippet.text.hasPrefix("…"))
        XCTAssertFalse(snippet.text.hasSuffix("…"))
        XCTAssertEqual(snippet.parts.match, "Schlusswort")
        XCTAssertEqual(snippet.parts.after, "")
    }

    func testDiacriticAndCaseInsensitiveLikeMatches() {
        let text = longText(term: "Prüfungsordnung", at: 900)
        XCTAssertTrue(hit(text).matches("PRUFUNGSORDNUNG"))
        let snippet = hit(text).snippet(for: "PRUFUNGSORDNUNG")
        XCTAssertEqual(snippet.parts.match, "Prüfungsordnung")
    }

    func testPhraseIsPreferredOverTheEarliestSingleTerm() {
        let text = "Recht am Anfang. " + String(repeating: "Füllwort ", count: 60) + "öffentliches Recht am Ende"
        let snippet = hit(text).snippet(for: "Öffentliches recht")
        XCTAssertEqual(snippet.parts.match, "öffentliches Recht")
        // Without the phrase: the earliest of the terms.
        XCTAssertEqual(hit(text).snippet(for: "Ende Recht").parts.match, "Recht")
        XCTAssertFalse(hit(text).snippet(for: "Ende Recht").text.hasPrefix("…"))
    }

    func testLineBreaksBecomeSpacesAndShortTextStaysWhole() {
        let snippet = hit("Erste Zeile\nzweite Zeile mit Treffer\r\ndritte").snippet(for: "treffer")
        XCTAssertEqual(snippet.text, "Erste Zeile zweite Zeile mit Treffer dritte")
        XCTAssertEqual(snippet.parts.match, "Treffer")
    }

    func testWithoutMatchShowsTheStart() {
        let text = longText(term: "", at: 0)
        let snippet = hit(text).snippet(for: "fehlt", radius: 30)
        XCTAssertNil(snippet.match)
        XCTAssertTrue(text.hasPrefix(snippet.text.dropLast()))
        XCTAssertTrue(snippet.text.hasSuffix("…"))
        XCTAssertEqual(hit("kurz").snippet(for: "  ").text, "kurz")
    }

    func testGraphemesAroundTheMatchStayIntact() {
        let text = String(repeating: "👩🏽‍💻 ", count: 50) + "Informatik " + String(repeating: "🇩🇪 ", count: 50)
        let snippet = hit(text).snippet(for: "informatik", radius: 10)
        XCTAssertEqual(snippet.parts.match, "Informatik")
        XCTAssertTrue(snippet.text.dropFirst().dropLast().split(separator: " ").allSatisfy { $0 == "👩🏽‍💻" || $0 == "🇩🇪" || $0 == "Informatik" })
    }
}
