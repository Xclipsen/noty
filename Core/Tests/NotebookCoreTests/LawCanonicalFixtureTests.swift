import XCTest
@testable import NotebookCore

/// B13: the app's canonical text, offsets and anchors equal the website's and
/// the account server's code unit for code unit. Fixture made with Node from
/// `gesetzessammlung-noty` by `scripts/make_law_canonical_fixture.mjs`.
final class LawCanonicalFixtureTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Anchor: Decodable { var start: Int; var end: Int; var quote: String }
        struct Selection: Decodable { var start: Int; var end: Int; var anchor: Anchor? }
        struct Map: Decodable { var starts: [Int]; var ends: [Int] }
        struct Case: Decodable {
            var name: String; var inputUTF16: [UInt16]; var canonicalUTF16: [UInt16]
            var map: Map?; var anchors: [Selection]
        }
        struct Bridge: Decodable { var name: String; var rendered: String; var sectionText: String; var start: Int; var end: Int; var anchor: Anchor? }
        var cases: [Case]
        var bridged: [Bridge]
    }
    private func fixture() throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/law-canonical.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }
    func testCanonicalTextMapAndAnchorsEqualWebsiteAndServer() throws {
        let fixture = try fixture()
        XCTAssertGreaterThanOrEqual(fixture.cases.count, 40)
        var selections = 0
        for c in fixture.cases {
            // Built from code units: JSON decoding must not normalise the input.
            let input = String(decoding: c.inputUTF16, as: UTF16.self)
            XCTAssertEqual(Array(input.utf16), c.inputUTF16, c.name)
            XCTAssertEqual(Array(LawTextAnchor.canonical(input).utf16), c.canonicalUTF16, c.name)
            let map = LawTextAnchor.canonicalMap(input)
            XCTAssertEqual(map?.starts, c.map?.starts, c.name); XCTAssertEqual(map?.ends, c.map?.ends, c.name)
            XCTAssertEqual(map == nil, c.map == nil, c.name)
            for s in c.anchors {
                let found = LawTextAnchor.anchor(text: input, range: NSRange(location: s.start, length: s.end - s.start), sectionID: "s")
                XCTAssertEqual(found?.start, s.anchor?.start, "\(c.name) \(s.start)..<\(s.end)")
                XCTAssertEqual(found?.end, s.anchor?.end, "\(c.name) \(s.start)..<\(s.end)")
                XCTAssertEqual(found.map { Array($0.quote.utf16) }, s.anchor.map { Array($0.quote.utf16) }, "\(c.name) \(s.start)..<\(s.end)")
                if let found, let map {
                    // Back to the original: the website's map positions.
                    let range = LawTextAnchor.originalRange(text: input, anchor: found)
                    XCTAssertEqual(range, NSRange(location: map.starts[found.start], length: map.ends[found.end - 1] - map.starts[found.start]), c.name)
                }
                selections += 1
            }
        }
        XCTAssertGreaterThan(selections, 1000)
        for b in fixture.bridged {
            let found = LawTextAnchor.anchor(rendered: b.rendered, range: NSRange(location: b.start, length: b.end - b.start), sectionText: b.sectionText, sectionID: "s")
            XCTAssertEqual(found?.start, b.anchor?.start, b.name); XCTAssertEqual(found?.end, b.anchor?.end, b.name); XCTAssertEqual(found?.quote, b.anchor?.quote, b.name)
        }
    }
    func testCapitalSigmaIsFinalLikeJavaScript() {
        XCTAssertEqual(LawTextAnchor.canonical("ΟΔΟΣ"), "οδος".replacingOccurrences(of: "σ", with: "ς"))
        XCTAssertEqual(Array(LawTextAnchor.canonical("ΟΔΟΣ").unicodeScalars).last, "\u{03C2}")
        XCTAssertEqual(LawTextAnchor.canonical("Σ"), "σ")
        XCTAssertEqual(LawTextAnchor.canonical("ΑΣ.Β"), "ασβ")
        // Offsets would be uncertain: like the website, no anchor in such a text.
        XCTAssertNil(LawTextAnchor.canonicalMap("ΟΔΟΣ"))
    }
}
