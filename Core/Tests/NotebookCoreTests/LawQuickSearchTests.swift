import XCTest
@testable import NotebookCore

/// Quick search opens the citation forms notebooks link, and still refuses free text.
final class LawQuickSearchTests: XCTestCase {
    private func entry(_ id: String, _ abbr: String, kind: String = "law") -> LawEntry {
        LawEntry(id: id, abbr: abbr, name: abbr, category: "", kind: kind, aliases: nil, currentVersion: "v", versions: [])
    }
    private var entries: [LawEntry] {
        [entry("estg", "EStG"), entry("gg", "GG"), entry("ustg", "UStG"), entry("hgb", "HGB"),
         entry("lstr", "LStR", kind: "administration"), entry("ustae", "UStAE", kind: "administration"),
         entry("aeao", "AEAO", kind: "administration")]
    }

    func testCommonCitationFormsOpenTheProvision() {
        let cases: [(input: String, law: String, key: String, paragraph: String?)] = [
            ("§ 15 Abs. 2 EStG", "estg", "15", "2"),
            ("Art. 3 GG", "gg", "3", nil),
            ("Artikel 20 Abs. 3 GG", "gg", "20", "3"),
            ("GG Art. 3", "gg", "3", nil),
            ("§ 3 Nr. 26 EStG", "estg", "3", nil),
            ("§ 15 Abs. 2 Satz 1 Nr. 3 EStG", "estg", "15", "2"),
            ("§ 15 Abs. 1 S. 1 Nr. 2 EStG", "estg", "15", "1"),
            ("§ 4 Nr. 1 Buchst. a UStG", "ustg", "4", nil),
            ("§ 4 Nr. 8 Buchstabe a UStG", "ustg", "4", nil),
            ("§ 35a EStG.", "estg", "35a", nil),
            ("EStG § 4h Abs. 2 Satz 1.", "estg", "4h", "2"),
            ("§ 3 Nummer 26a EStG,", "estg", "3", nil),
            ("R 9.1 Abs. 2 Satz 1 LStR", "lstr", "9.1", "2"),
            ("Abschnitt 1.1 UStAE", "ustae", "1.1", nil),
        ]
        for item in cases {
            XCTAssertEqual(LawQuickTarget.parse(item.input, entries: entries),
                           LawQuickTarget(lawID: item.law, reference: LawReference(key: item.key, paragraph: item.paragraph)), item.input)
        }
    }

    func testBareReferenceTakesTheSameForms() {
        XCTAssertEqual(LawReference.parse("Art. 3"), LawReference(key: "3", paragraph: nil))
        XCTAssertEqual(LawReference.parse("3 Nr. 26"), LawReference(key: "3", paragraph: nil))
        XCTAssertEqual(LawReference.parse("§ 15 Abs. 2 Satz 1 Nr. 3"), LawReference(key: "15", paragraph: "2"))
        XCTAssertEqual(LawReference.parse("4 (2) Satz 1"), LawReference(key: "4", paragraph: "2"))
        XCTAssertEqual(LawReference.parse("35a."), LawReference(key: "35a", paragraph: nil))
        XCTAssertEqual(LawReference.parse("15.2a Abs. 3"), LawReference(key: "15.2a", paragraph: "3"))
    }

    func testFreeTextIsStillNoReference() {
        for input in ["HGB 144 rubbish", "144 rubbish HGB", "§ 3 Nr. EStG", "§ 3 Satz rubbish EStG", "§ 3 Nr. 26 und mehr EStG",
                      "Art. GG", "EStG", "Gewinn EStG", "§ 15 Abs. 2 Satz EStG", "144 HB", "."] {
            XCTAssertNil(LawQuickTarget.parse(input, entries: entries), input)
        }
        for input in ["-1", "Art.", "3 Nr.", "3 rubbish", "Satz 1", "Abs. 2", ""] {
            XCTAssertNil(LawReference.parse(input), input)
        }
    }

    func testCitationWordingFollowsTheDocument() {
        XCTAssertEqual(entry("estg", "EStG").citation(key: "35a", paragraph: "2"), "§ 35a Abs. 2 EStG")
        XCTAssertEqual(entry("gg", "GG").citation(key: "3", paragraph: nil), "Art. 3 GG")
        XCTAssertEqual(entry("gg", "GG").citation(key: "20", paragraph: "3"), "Art. 20 Abs. 3 GG")
        XCTAssertEqual(entry("lstr", "LStR", kind: "administration").citation(key: "9.1", paragraph: nil), "R 9.1 LStR")
        XCTAssertEqual(entry("ustae", "UStAE", kind: "administration").citation(key: "1.1", paragraph: "2"), "Abschnitt 1.1 Abs. 2 UStAE")
        XCTAssertEqual(entry("aeao", "AEAO", kind: "administration").citation(key: "122", paragraph: nil), "AEAO zu § 122")
        XCTAssertEqual(entry("bmf", "BMF", kind: "administration").citation(key: "4.2", paragraph: nil), "4.2 BMF")
    }
}
