import XCTest
@testable import NotebookCore

/// Paragraphen-Links: Erkennung von Gesetzesverweisen in Text und PDF-Text.
/// Abkürzungen, Aliasse und Schlüsselformen wie im echten Katalog
/// (`gesetzessammlung-noty`): Gesetze mit Schlüsseln „35a“, Richtlinien
/// „9.1“/„39b.1“, AEAO „122“ (Abschnitt „AEAO zu § 122“), UStAE „1.1“.
final class LawCitationTests: XCTestCase {
    private func entry(_ id: String, _ abbr: String, kind: String = "law", aliases: [String]? = nil) -> LawEntry {
        LawEntry(id: id, abbr: abbr, name: abbr, category: "Test", kind: kind, aliases: aliases, currentVersion: "v1",
                 versions: [LawVersion(id: "v1", status: [], dataUrl: "/data/laws/\(id)/v1/law.json", pdfUrl: nil, pages: 1, sectionCount: 1, sha256: [:])])
    }
    private lazy var entries: [LawEntry] = [
        entry("ao", "AO"), entry("fgo", "FGO"), entry("estg", "EStG"), entry("estdv", "EStDV"), entry("ustg", "UStG"),
        entry("kstg", "KStG"), entry("gewstg", "GewStG"), entry("hgb", "HGB", aliases: ["HBG"]), entry("bgb", "BGB"),
        entry("gmbhg", "GmbHG", aliases: ["GmbH-Gesetz"]), entry("inso", "InsO"),
        entry("sgb4", "SGB IV", aliases: ["SGB 4"]), entry("sgb5", "SGB V", aliases: ["SGB 5"]), entry("sgb6", "SGB VI", aliases: ["SGB 6"]),
        entry("gg", "GG"),
        entry("ustae", "UStAE", kind: "administration"), entry("estr", "EStR", kind: "administration"),
        entry("lstr", "LStR", kind: "administration"), entry("aeao", "AEAO", kind: "administration"),
    ]
    private func scan(_ text: String, defaultLaw: String? = nil, extra: [LawEntry] = []) -> [LawCitation] {
        LawCitationScanner(entries: entries + extra, defaultLawID: defaultLaw).citations(in: text)
    }
    /// (text, law, key, paragraph, inferred) for compact comparisons.
    private struct Found: Equatable, CustomStringConvertible {
        var text: String, law: String, key: String, paragraph: String?, inferred: Bool
        init(_ text: String, _ law: String, _ key: String, _ paragraph: String? = nil, inferred: Bool = false) {
            self.text = text; self.law = law; self.key = key; self.paragraph = paragraph; self.inferred = inferred
        }
        var description: String { "\"\(text)\" \(law) \(key) \(paragraph ?? "-")\(inferred ? " (inferred)" : "")" }
    }
    private func found(_ text: String, defaultLaw: String? = nil, extra: [LawEntry] = []) -> [Found] {
        let result = scan(text, defaultLaw: defaultLaw, extra: extra)
        for c in result {
            // Range and text agree in UTF-16 terms.
            XCTAssertEqual((text as NSString).substring(with: c.range), c.text)
        }
        return result.map { Found($0.text, $0.lawID, $0.reference.key, $0.reference.paragraph, inferred: $0.inferredLaw) }
    }

    // MARK: Einfache Formen

    func testSimpleSectionWithAndWithoutSpace() {
        XCTAssertEqual(found("Nach § 35a EStG gilt"), [Found("§ 35a EStG", "estg", "35a")])
        XCTAssertEqual(found("Nach §35a EStG gilt"), [Found("§35a EStG", "estg", "35a")])
        XCTAssertEqual(found("§ 4h Abs. 2 EStG"), [Found("§ 4h Abs. 2 EStG", "estg", "4h", "2")])
        XCTAssertEqual(found("§ 35a Abs. 2 EStG."), [Found("§ 35a Abs. 2 EStG", "estg", "35a", "2")])
        XCTAssertEqual(found("§ 35a Absatz 2 EStG"), [Found("§ 35a Absatz 2 EStG", "estg", "35a", "2")])
        XCTAssertEqual(found("§ 340l HGB"), [Found("§ 340l HGB", "hgb", "340l")])
        // Großgeschriebener Buchstabe: Schlüssel bleibt klein wie im Katalog.
        XCTAssertEqual(found("§ 35A EStG"), [Found("§ 35A EStG", "estg", "35a")])
    }

    func testRangeCoversSatzNummerBuchstabe() {
        XCTAssertEqual(found("Gewinn i.S.d. § 15 Abs. 1 S. 1 Nr. 2 EStG ist"), [Found("§ 15 Abs. 1 S. 1 Nr. 2 EStG", "estg", "15", "1")])
        XCTAssertEqual(found("§ 15 Abs. 1 Satz 1 Nr. 2 Buchst. a EStG"), [Found("§ 15 Abs. 1 Satz 1 Nr. 2 Buchst. a EStG", "estg", "15", "1")])
        XCTAssertEqual(found("§ 3 Nr. 26 lit. a EStG"), [Found("§ 3 Nr. 26 lit. a EStG", "estg", "3")])
        XCTAssertEqual(found("§ 7 Abs. 4 Satz 1 Nr. 2 Buchstabe a Doppelbuchst. aa EStG"),
                       [Found("§ 7 Abs. 4 Satz 1 Nr. 2 Buchstabe a Doppelbuchst. aa EStG", "estg", "7", "4")])
        XCTAssertEqual(found("§ 9 Abs. 1 Satz 3 Nr. 4 Halbs. 2 EStG"), [Found("§ 9 Abs. 1 Satz 3 Nr. 4 Halbs. 2 EStG", "estg", "9", "1")])
        XCTAssertEqual(found("§ 10 Abs. 1 und 2 EStG"), [Found("§ 10 Abs. 1 und 2 EStG", "estg", "10", "1")])
        XCTAssertEqual(found("§ 3 Nr. 1 bis 3 EStG"), [Found("§ 3 Nr. 1 bis 3 EStG", "estg", "3")])
        XCTAssertEqual(found("§ 4 (1) EStG"), [Found("§ 4 (1) EStG", "estg", "4", "1")])
    }

    /// Juristische Kurzschreibweise: römischer Absatz direkt hinter der
    /// Nummer oder nach „Abs.“, eine bloße Zahl danach ist der Satz.
    func testRomanAbsatz() {
        XCTAssertEqual(found("§ 15 I EStG"), [Found("§ 15 I EStG", "estg", "15", "1")])
        XCTAssertEqual(found("§ 15 III Nr. 1 EStG"), [Found("§ 15 III Nr. 1 EStG", "estg", "15", "3")])
        XCTAssertEqual(found("§ 15 I 1 Nr. 2 EStG"), [Found("§ 15 I 1 Nr. 2 EStG", "estg", "15", "1")])
        XCTAssertEqual(found("§ 15 Abs. II EStG"), [Found("§ 15 Abs. II EStG", "estg", "15", "2")])
        XCTAssertEqual(found("§ 4 IV EStG"), [Found("§ 4 IV EStG", "estg", "4", "4")])
        // Römische Zahl als Teil der Gesetzesabkürzung bleibt Gesetz.
        XCTAssertEqual(found("§ 28a SGB IV"), [Found("§ 28a SGB IV", "sgb4", "28a")])
        XCTAssertEqual(found("§ 5 SGB V und § 1 SGB VI"), [Found("§ 5 SGB V", "sgb5", "5"), Found("§ 1 SGB VI", "sgb6", "1")])
        XCTAssertEqual(found("§ 7 IV SGB V"), [Found("§ 7 IV SGB V", "sgb5", "7", "4")])
        XCTAssertEqual(found("§ 28a SGB 4"), [Found("§ 28a SGB 4", "sgb4", "28a")])
    }

    func testArticleAndLawFirst() {
        XCTAssertEqual(found("Art. 3 Abs. 1 GG"), [Found("Art. 3 Abs. 1 GG", "gg", "3", "1")])
        XCTAssertEqual(found("Artikel 3 GG"), [Found("Artikel 3 GG", "gg", "3")])
        XCTAssertEqual(found("EStG § 35a"), [Found("EStG § 35a", "estg", "35a")])
        XCTAssertEqual(found("siehe HGB § 238 Abs. 1"), [Found("HGB § 238 Abs. 1", "hgb", "238", "1")])
        XCTAssertEqual(found("GG Art. 20"), [Found("GG Art. 20", "gg", "20")])
        // Ein Artikel ohne Gesetz wird nie geraten, auch nicht aus dem Zusammenhang.
        XCTAssertEqual(found("§ 4 EStG und Art. 3"), [Found("§ 4 EStG", "estg", "4")])
        XCTAssertEqual(found("Art. 3", defaultLaw: "estg"), [])
    }

    func testFollowingAndDes() {
        XCTAssertEqual(found("§ 4 ff. EStG"), [Found("§ 4 ff. EStG", "estg", "4")])
        XCTAssertEqual(found("§ 4 f. EStG"), [Found("§ 4 f. EStG", "estg", "4")])
        XCTAssertEqual(found("§ 35a des EStG"), [Found("§ 35a des EStG", "estg", "35a")])
    }

    func testAliasesAndCase() {
        XCTAssertEqual(found("§ 238 HBG"), [Found("§ 238 HBG", "hgb", "238")])
        XCTAssertEqual(found("§ 238 hbg"), [Found("§ 238 hbg", "hgb", "238")])
        XCTAssertEqual(found("§ 5 GmbH-Gesetz"), [Found("§ 5 GmbH-Gesetz", "gmbhg", "5")])
        XCTAssertEqual(found("§ 5 GmbHG"), [Found("§ 5 GmbHG", "gmbhg", "5")])
        // Häufige Schreibweisen langer Abkürzungen.
        XCTAssertEqual(found("§ 35a EstG"), [Found("§ 35a EstG", "estg", "35a")])
        XCTAssertEqual(found("§ 35a ESTG"), [Found("§ 35a ESTG", "estg", "35a")])
        XCTAssertEqual(found("§ 15 InsO"), [Found("§ 15 InsO", "inso", "15")])
        // Kurze Abkürzungen nur wie geschrieben oder in Großbuchstaben.
        XCTAssertEqual(found("§ 122 AO"), [Found("§ 122 AO", "ao", "122")])
        XCTAssertEqual(found("§ 122 ao"), [])
        // "AO" nur als ganzes Wort.
        XCTAssertEqual(found("§ 5 KAO"), [])
        XCTAssertEqual(found("§ 5 AOx"), [])
        XCTAssertEqual(found("§ 5 EStGB"), [])
        XCTAssertEqual(found("§ 5 EStDV"), [Found("§ 5 EStDV", "estdv", "5")])
    }

    // MARK: Aufzählungen und Ketten

    func testPluralListsOneCitationPerNumber() {
        XCTAssertEqual(found("§§ 4, 5 EStG"), [Found("§§ 4", "estg", "4"), Found("5 EStG", "estg", "5")])
        XCTAssertEqual(found("§§ 4 und 5 EStG"), [Found("§§ 4", "estg", "4"), Found("5 EStG", "estg", "5")])
        XCTAssertEqual(found("§§ 4–7 EStG"), [Found("§§ 4", "estg", "4"), Found("7 EStG", "estg", "7")])
        XCTAssertEqual(found("§§ 4 bis 7 EStG"), [Found("§§ 4", "estg", "4"), Found("7 EStG", "estg", "7")])
        XCTAssertEqual(found("§§ 4 Abs. 1, 5 Abs. 2 und 7g EStG"),
                       [Found("§§ 4 Abs. 1", "estg", "4", "1"), Found("5 Abs. 2", "estg", "5", "2"), Found("7g EStG", "estg", "7g")])
        XCTAssertEqual(found("§§ 4 ff. EStG"), [Found("§§ 4 ff. EStG", "estg", "4")])
        XCTAssertEqual(found("EStG §§ 4, 5"), [Found("EStG §§ 4", "estg", "4"), Found("5", "estg", "5")])
    }

    func testChainTakesLawWrittenAfterIt() {
        XCTAssertEqual(found("§ 10 Abs. 1 Nr. 2 i.V.m. § 10 Abs. 3 EStG"),
                       [Found("§ 10 Abs. 1 Nr. 2", "estg", "10", "1"), Found("§ 10 Abs. 3 EStG", "estg", "10", "3")])
        for connector in ["iVm", "i. V. m.", "i.V.m", "in Verbindung mit", "und", "oder", "sowie", "bzw.", ",", ", sowie"] {
            XCTAssertEqual(found("§ 9 Abs. 5 \(connector) § 4 Abs. 5 Satz 1 Nr. 7 AO").map(\.law), ["ao", "ao"], connector)
        }
        // Echte Schreibweise aus R 9.1 LStR (geschützte Leerzeichen).
        XCTAssertEqual(found("nach §\u{A0}9 Abs.\u{A0}5 i.\u{A0}V.\u{A0}m. §\u{A0}4 Abs.\u{A0}5 Satz\u{A0}1 Nr.\u{A0}7 EStG insoweit"),
                       [Found("§\u{A0}9 Abs.\u{A0}5", "estg", "9", "5"), Found("§\u{A0}4 Abs.\u{A0}5 Satz\u{A0}1 Nr.\u{A0}7 EStG", "estg", "4", "5")])
        // Das spätere Gesetz geht dem früheren Zusammenhang vor.
        XCTAssertEqual(found("§ 4 EStG. Ferner § 5 i.V.m. § 6 AO").map(\.law), ["estg", "ao", "ao"])
        // Jedes Glied mit eigenem Gesetz behält es.
        XCTAssertEqual(found("§ 4 EStG i.V.m. § 5 AO"), [Found("§ 4 EStG", "estg", "4"), Found("§ 5 AO", "ao", "5")])
    }

    /// „… i.V.m. Abs. 3 EStG“: ein zweiter Verweis auf denselben Paragraphen.
    func testChainContinuationWithAbsatz() {
        XCTAssertEqual(found("§ 10 Abs. 1 i.V.m. Abs. 3 EStG"),
                       [Found("§ 10 Abs. 1", "estg", "10", "1"), Found("Abs. 3 EStG", "estg", "10", "3")])
        XCTAssertEqual(found("§ 10 Abs. 1, Abs. 3 EStG"), [Found("§ 10 Abs. 1", "estg", "10", "1"), Found("Abs. 3 EStG", "estg", "10", "3")])
        XCTAssertEqual(found("R 9.1 Abs. 1 und Abs. 2 LStR"), [Found("R 9.1 Abs. 1", "lstr", "9.1", "1"), Found("Abs. 2 LStR", "lstr", "9.1", "2")])
        // Ohne vorangehenden Verweis ist „Abs. 3“ nichts.
        XCTAssertEqual(found("Abs. 3 EStG"), [])
    }

    // MARK: Verwaltungsvorschriften

    func testAdministrativeDocuments() {
        XCTAssertEqual(found("R 9.1 LStR"), [Found("R 9.1 LStR", "lstr", "9.1")])
        XCTAssertEqual(found("R 9.1 Abs. 2 LStR"), [Found("R 9.1 Abs. 2 LStR", "lstr", "9.1", "2")])
        XCTAssertEqual(found("R 39b.1 LStR"), [Found("R 39b.1 LStR", "lstr", "39b.1")])
        XCTAssertEqual(found("R 4.2 Abs. 1 EStR"), [Found("R 4.2 Abs. 1 EStR", "estr", "4.2", "1")])
        XCTAssertEqual(found("R 13a.2 EStR"), [Found("R 13a.2 EStR", "estr", "13a.2")])
        XCTAssertEqual(found("R 55 EStR"), [Found("R 55 EStR", "estr", "55")])
        XCTAssertEqual(found("EStR R 4.2"), [Found("EStR R 4.2", "estr", "4.2")])
        XCTAssertEqual(found("EStR 4.2"), [Found("EStR 4.2", "estr", "4.2")])
        XCTAssertEqual(found("LStR 2023"), []) // Jahr, kein Abschnitt
        XCTAssertEqual(found("Abschnitt 1.1 UStAE"), [Found("Abschnitt 1.1 UStAE", "ustae", "1.1")])
        XCTAssertEqual(found("Abschn. 3.10 Abs. 2 UStAE"), [Found("Abschn. 3.10 Abs. 2 UStAE", "ustae", "3.10", "2")])
        XCTAssertEqual(found("A 6a.5 UStAE"), [Found("A 6a.5 UStAE", "ustae", "6a.5")])
        XCTAssertEqual(found("UStAE Abschnitt 1.1"), [Found("UStAE Abschnitt 1.1", "ustae", "1.1")])
        XCTAssertEqual(found("R 9.1. Danach LStR"), [])
        // „R“ verlangt eine Verwaltungsvorschrift, nie ein Gesetz.
        XCTAssertEqual(found("R 9.1 EStG"), [])
        XCTAssertEqual(found("R 9.1", defaultLaw: "estg"), [])
        // Im Dokument selbst (z. B. PDF der LStR) gilt das Standarddokument.
        XCTAssertEqual(found("siehe R 9.4", defaultLaw: "lstr"), [Found("R 9.4", "lstr", "9.4", inferred: true)])
    }

    func testAEAO() {
        XCTAssertEqual(found("AEAO zu § 122"), [Found("AEAO zu § 122", "aeao", "122")])
        XCTAssertEqual(found("AEAO zu § 122 AO"), [Found("AEAO zu § 122 AO", "aeao", "122")])
        XCTAssertEqual(found("Nr. 2 AEAO zu § 122"), [Found("Nr. 2 AEAO zu § 122", "aeao", "122")])
        XCTAssertEqual(found("Nr. 2.1.4 AEAO zu § 122 AO"), [Found("Nr. 2.1.4 AEAO zu § 122 AO", "aeao", "122")])
        XCTAssertEqual(found("AEAO Nr. 2 zu § 122 AO"), [Found("AEAO Nr. 2 zu § 122 AO", "aeao", "122")])
        XCTAssertEqual(found("AEAO zu § 4h"), [Found("AEAO zu § 4h", "aeao", "4h")])
        // Das mitgeschriebene AO ist Zusammenhang für spätere bloße Paragraphen.
        XCTAssertEqual(found("AEAO zu § 122 AO; vgl. § 124").last, Found("§ 124", "ao", "124", inferred: true))
        // Eine Verwaltungsvorschrift ist kein Zusammenhang für Paragraphen.
        XCTAssertEqual(found("R 9.1 LStR. Siehe § 9"), [Found("R 9.1 LStR", "lstr", "9.1")])
        // Bloße Nummer vor einer Verwaltungsvorschrift ohne „zu §“: nichts.
        XCTAssertEqual(found("Nr. 2 AEAO"), [])
    }

    // MARK: Zusammenhang und Standardgesetz

    func testBareSectionTakesPreviousExplicitLaw() {
        XCTAssertEqual(found("Nach § 35a EStG … Auch § 35b gilt."),
                       [Found("§ 35a EStG", "estg", "35a"), Found("§ 35b", "estg", "35b", inferred: true)])
        XCTAssertEqual(found("§ 1 UStG. Dann § 15 HGB. Dann § 2."),
                       [Found("§ 1 UStG", "ustg", "1"), Found("§ 15 HGB", "hgb", "15"), Found("§ 2", "hgb", "2", inferred: true)])
        // Ein Gesetz erst nach dem Satz gilt nicht rückwirkend.
        XCTAssertEqual(found("§ 2 gilt. § 3 AO"), [Found("§ 3 AO", "ao", "3")])
        XCTAssertEqual(found("§ 2 gilt. § 3 AO", defaultLaw: "estg"),
                       [Found("§ 2", "estg", "2", inferred: true), Found("§ 3 AO", "ao", "3")])
        XCTAssertEqual(found("§ 35a"), [])
        XCTAssertEqual(found("§ 35a", defaultLaw: "estg"), [Found("§ 35a", "estg", "35a", inferred: true)])
        XCTAssertEqual(found("§ 35a", defaultLaw: "unbekannt"), [])
        XCTAssertEqual(found("§ 4 EStG und § 5"), [Found("§ 4 EStG", "estg", "4"), Found("§ 5", "estg", "5", inferred: true)])
        // Kleingeschriebene Wörter nach der Nummer sind kein Gesetz.
        XCTAssertEqual(found("Laut § 35a Abs. 2 kann", defaultLaw: "estg"), [Found("§ 35a Abs. 2", "estg", "35a", "2", inferred: true)])
        XCTAssertEqual(found("§ 35a Die Steuer", defaultLaw: "estg"), [Found("§ 35a", "estg", "35a", inferred: true)])
        // Law-first resets nothing before it.
        XCTAssertEqual(found("§ 3 i.V.m. AO § 5", defaultLaw: "estg"),
                       [Found("§ 3", "estg", "3", inferred: true), Found("AO § 5", "ao", "5")])
    }

    /// Ein geschriebenes, aber unbekanntes oder mehrdeutiges Gesetz: kein
    /// Verweis, und auch kein geerbtes Gesetz.
    func testNeverGuess() {
        XCTAssertEqual(found("§ 5 XYZG"), [])
        XCTAssertEqual(found("§ 4 EStG. Dann § 5 XYZG.").map(\.law), ["estg"])
        XCTAssertEqual(found("§ 5 XYZG", defaultLaw: "estg"), [])
        XCTAssertEqual(found("§ 5 i.V.m. § 6 XYZG", defaultLaw: "estg"), [])
        XCTAssertEqual(found("§ 5 BMF-Schreiben", defaultLaw: "estg"), [])
        let twins = [entry("a1", "AStG", aliases: ["Doppel"]), entry("a2", "BStG", aliases: ["Doppel"])]
        XCTAssertEqual(found("§ 5 Doppel", defaultLaw: "estg", extra: twins), [])
        XCTAssertEqual(found("Doppel § 5", defaultLaw: "estg", extra: twins), [])
        XCTAssertEqual(found("§ 5 AStG", extra: twins).map(\.law), ["a1"])
        // Zwei Einträge mit gleicher Abkürzung.
        XCTAssertEqual(found("§ 5 GG", extra: [entry("gg2", "GG")]), [])
    }

    func testNoFalsePositives() {
        for text in ["Artikel über das Steuerrecht", "Der Artikel 5", "Preis € 35", "€35,00", "Am 1.1.2025 um 10.30",
                     "Seite 5", "Kapitel 3.1", "Abschnitt 3 behandelt", "42", "R2-D2", "Abs. 3", "§", "§§", "§ abc", "Nr. 5",
                     "Kategorie R 5", "A 1.1 ist gut", "AO-Reform", "EStG", "EStG 2025", "UStG § Zahl"] {
            XCTAssertEqual(found(text, defaultLaw: nil), [], text)
        }
        XCTAssertEqual(found("Preis € 35 laut § 3 Nr. 26 EStG"), [Found("§ 3 Nr. 26 EStG", "estg", "3")])
        XCTAssertEqual(found("Am 1.1.2025 trat § 35c EStG in Kraft"), [Found("§ 35c EStG", "estg", "35c")])
    }

    // MARK: Bereiche, Zeichen, Reihenfolge

    func testUTF16RangesAfterUmlautsAndEmoji() throws {
        let text = "Übung 🧾👩‍💼 für Müller: § 35a EStG – fertig"
        let result = scan(text)
        XCTAssertEqual(result.count, 1)
        let c = try XCTUnwrap(result.first)
        XCTAssertEqual(c.range, (text as NSString).range(of: "§ 35a EStG"))
        XCTAssertEqual(c.text, "§ 35a EStG")
        XCTAssertGreaterThan(c.range.location, text.distance(from: text.startIndex, to: text.range(of: "§")!.lowerBound))
    }

    func testSpacesAndLineBreaksInsideCitation() {
        for space in ["\u{A0}", "\u{202F}", "\u{2009}", "\n", "\r\n", "  ", "\t"] {
            let text = "x §\(space)35a\(space)Abs.\(space)2\(space)EStG y"
            let result = found(text)
            XCTAssertEqual(result.map(\.key), ["35a"], space.debugDescription)
            XCTAssertEqual(result.first?.paragraph, "2", space.debugDescription)
            XCTAssertEqual(result.first?.text, "§\(space)35a\(space)Abs.\(space)2\(space)EStG", space.debugDescription)
        }
        // PDF-Zeilenumbruch mitten in einer Kette.
        XCTAssertEqual(found("gem. § 10 Abs. 1 Nr. 2 i.V.m.\n§ 10 Abs. 3\nEStG").map(\.law), ["estg", "estg"])
    }

    func testReadingOrderAndNoOverlap() {
        let text = """
        Nach § 4 Abs. 1 EStG und R 4.2 EStR sowie AEAO zu § 122, Nr. 2 AEAO zu § 124 AO.
        Weiter: §§ 5, 6 HGB, § 7 I 1 Nr. 2 EStG i.V.m. § 10 Abs. 3, außerdem Art. 3 GG und § 8.
        """
        let result = scan(text)
        XCTAssertEqual(result.map(\.lawID), ["estg", "estr", "aeao", "aeao", "hgb", "hgb", "estg", "estg", "gg", "estg"])
        XCTAssertEqual(result.map(\.inferredLaw), [false, false, false, false, false, false, false, true, false, true])
        for (a, b) in zip(result, result.dropFirst()) {
            XCTAssertLessThanOrEqual(a.range.location + a.range.length, b.range.location, "\(a.text) / \(b.text)")
        }
    }

    func testLargeTextCompletes() {
        let paragraph = "Die Aufwendungen sind nach § 9 Abs. 1 Satz 3 Nr. 4 EStG i.V.m. R 9.10 LStR abziehbar; vgl. auch §§ 4, 5 und § 35a. Preis € 35 am 1.1.2025, Seite 5. Übergröße 🧾.\n"
        let text = String(repeating: paragraph, count: 50_000 / paragraph.count + 1)
        let scanner = LawCitationScanner(entries: entries)
        let started = Date()
        let result = scanner.citations(in: text)
        let elapsed = Date().timeIntervalSince(started)
        let copies = text.components(separatedBy: "\n").count - 1
        XCTAssertEqual(result.count, copies * 5)
        print("LawCitationScanner: \((text as NSString).length) UTF-16-Einheiten in \(Int(elapsed * 1000)) ms")
    }

    /// Opt-in wie `LawRealCatalogTests` (scripts/check_law_workflow.sh): jeder
    /// erkannte Schlüssel öffnet im echten Bestand einen Abschnitt, so wie
    /// `LawReaderView.open` ihn sucht.
    func testKeysExistInRealCatalog() throws {
        guard let path = ProcessInfo.processInfo.environment["NOTY_LAW_FIXTURE_ROOT"] else { throw XCTSkip("Realen Gesetzesbestand über scripts/check_law_workflow.sh prüfen.") }
        let source = URL(fileURLWithPath: path), parent = source.deletingLastPathComponent()
        let catalog = try JSONDecoder().decode(LawCatalog.self, from: Data(contentsOf: source.appendingPathComponent("catalog.json"))).validated()
        let text = """
        § 35a EStG, § 4h Abs. 2 EStG, § 15 Abs. 1 S. 1 Nr. 2 EStG, § 15 I EStG, §§ 4, 5 EStG, § 10 Abs. 1 Nr. 2 i.V.m. § 10 Abs. 3 EStG.
        § 122 AO, § 1a UStG, § 8b KStG, § 9 GewStG, § 238 HGB, § 144 HBG, § 433 BGB, § 28a SGB IV, § 5 SGB V, § 57 StBerG.
        R 9.1 LStR, R 39b.1 LStR, R 4.2 Abs. 1 EStR, R 13a.2 EStR, AEAO zu § 122, Nr. 2 AEAO zu § 4, Abschnitt 1.1 UStAE, A 6a.5 UStAE.
        """
        let found = LawCitationScanner(entries: catalog.entries).citations(in: text)
        XCTAssertEqual(found.count, 26)
        XCTAssertFalse(found.contains { $0.inferredLaw })
        for citation in found {
            let entry = try XCTUnwrap(catalog.entries.first { $0.id == citation.lawID })
            let v = try XCTUnwrap(entry.versions.first { $0.id == entry.currentVersion })
            let doc = try JSONDecoder().decode(LawDocument.self, from: Data(contentsOf: parent.appendingPathComponent(String(v.dataUrl.dropFirst()))))
            let key = citation.reference.key
            XCTAssertNotNil(doc.sections.first { $0.id == key || $0.keys.contains(key) }, citation.text)
        }
    }
}
