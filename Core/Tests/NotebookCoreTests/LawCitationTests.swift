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
        XCTAssertEqual(found("§§ 4 Abs. 1, 5 Abs. 2, 7g EStG"),
                       [Found("§§ 4 Abs. 1", "estg", "4", "1"), Found("5 Abs. 2", "estg", "5", "2"), Found("7g EStG", "estg", "7g")])
        // „und“ nach einer Absatzangabe bleibt Absatz (lieber 7g nicht verlinkt als falsch).
        XCTAssertEqual(found("§§ 4 Abs. 1, 5 Abs. 2 und 7g EStG"),
                       [Found("§§ 4 Abs. 1", "estg", "4", "1"), Found("5 Abs. 2 und 7g EStG", "estg", "5", "2")])
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
        // Ein großgeschriebenes Wort direkt nach der Nummer gilt als (unbekanntes) Gesetz.
        XCTAssertEqual(found("§ 35a Die Steuer", defaultLaw: "estg"), [])
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

    // MARK: Befunde der Prüfung (Regressionen)

    /// 1: Lesen hinter dem Textende stürzte ab.
    func testTextEndNeverCrashes() {
        for text in ["AEAO zu ", "AEAO zu", "Nr. 2 AEAO zu \n", "Nr. 2 AEAO zu", "AEAO Nr. 2 zu ", "AEAO Nr. 2", "§", "§§", "§ 4 Abs.",
                     "§ 4 (1", "§ 4 (", "R 9.", "R 9.1.", "§ 35 a", "§ 4 i.", "§ 4 i.V", "§ 4 i.V.m.", "EStG §", "Art.", "§ 4 und",
                     "§ 4 des", "§ 4 der ", "§ 4 EStG-", "§ 4 Abs. 1 bis Abs.", "LStR 1.", "Abschnitt", "A", "R", "Nr.", "§ 4 in Verbindung"] {
            _ = scan(text, defaultLaw: "estg")
        }
    }

    /// 1: Zufallstexte aus den Bausteinen der Erkennung: kein Absturz, Bereiche
    /// im Text, geordnet, ohne Überlappung.
    func testFuzzedFragments() {
        let parts = ["§", "§§", " ", "\n", "\u{A0}", "1", "4", "35", "a", " a", "9.1", ".", ",", "Abs.", "Abs", "I", "II", "Satz", "S.", "Nr.",
                     "zu", "AEAO", "AO", "EStG", "LStR", "R", "A", "Art.", "GG", "und", "bis", "i.V.m.", "iVm", "des", "der", "Vertrag",
                     "XYZG", "(", ")", "-", "–", "ff.", "f.", "Buchst.", "lit.", "ö", "\u{308}", "🧾", "Abschnitt", "in", "Verbindung", "mit"]
        var generator = SystemRandomNumberGenerator()
        let scanner = LawCitationScanner(entries: entries, defaultLawID: "estg")
        for _ in 0..<20_000 {
            let count = Int.random(in: 1...12, using: &generator)
            let text = (0..<count).map { _ in parts.randomElement(using: &generator)! }.joined()
            let length = (text as NSString).length
            var last = 0
            for c in scanner.citations(in: text) {
                XCTAssertGreaterThanOrEqual(c.range.location, last, text)
                XCTAssertLessThanOrEqual(c.range.location + c.range.length, length, text)
                XCTAssertGreaterThan(c.range.length, 0, text)
                last = c.range.location + c.range.length
            }
        }
    }

    /// 2: Ein nachgestelltes Gesetz gilt nur für Verweise derselben Art.
    func testTrailingLawOnlyForSameKind() {
        XCTAssertEqual(found("§ 2 i.V.m. R 2 EStR"), [Found("R 2 EStR", "estr", "2")])
        XCTAssertEqual(found("§ 2 i.V.m. R 2 EStR", defaultLaw: "estg"), [Found("§ 2", "estg", "2", inferred: true), Found("R 2 EStR", "estr", "2")])
        XCTAssertEqual(found("§ 19 und R 19.3 LStR"), [Found("R 19.3 LStR", "lstr", "19.3")])
        XCTAssertEqual(found("§ 4 und Art. 3 GG"), [Found("Art. 3 GG", "gg", "3")])
        XCTAssertEqual(found("Art. 3 und § 4 EStG"), [Found("§ 4 EStG", "estg", "4")])
        // § und Art. nur aus Gesetzen, R nur aus Verwaltungsvorschriften.
        XCTAssertEqual(found("§ 4 LStR"), [])
        XCTAssertEqual(found("AEAO § 122"), [])
        XCTAssertEqual(found("Art. 3 LStR"), [])
    }

    /// 3: Wiederholte Angaben halten den Verweis zusammen.
    func testRepeatedQualifierKeepsLaw() {
        XCTAssertEqual(found("§ 1 AO. Siehe § 4 Abs. 1 Satz 1 und Satz 2 EStG"),
                       [Found("§ 1 AO", "ao", "1"), Found("§ 4 Abs. 1 Satz 1 und Satz 2 EStG", "estg", "4", "1")])
        XCTAssertEqual(found("§ 1 AO. § 9 Abs. 1 Satz 3 Nr. 4 und Nr. 5 EStG").last, Found("§ 9 Abs. 1 Satz 3 Nr. 4 und Nr. 5 EStG", "estg", "9", "1"))
        XCTAssertEqual(found("§ 1 AO. § 4 Abs. 1 bis Abs. 3 EStG").last, Found("§ 4 Abs. 1 bis Abs. 3 EStG", "estg", "4", "1"))
        XCTAssertEqual(found("§ 4 Abs. I bis III EStG"), [Found("§ 4 Abs. I bis III EStG", "estg", "4", "1")])
        XCTAssertEqual(found("§ 15 I und II EStG"), [Found("§ 15 I und II EStG", "estg", "15", "1")])
    }

    /// 4: Weitere Nummern nach einem einzelnen § nehmen das Gesetz mit.
    func testSingleSectionWithFurtherNumbers() {
        XCTAssertEqual(found("§ 1 AO. § 4 und 5 EStG"), [Found("§ 1 AO", "ao", "1"), Found("§ 4", "estg", "4"), Found("5 EStG", "estg", "5")])
        XCTAssertEqual(found("§ 1 AO. § 4, 5 EStG").map(\.law), ["ao", "estg", "estg"])
        XCTAssertEqual(found("§ 1 AO. § 4 bis § 7 EStG"),
                       [Found("§ 1 AO", "ao", "1"), Found("§ 4", "estg", "4"), Found("§ 7 EStG", "estg", "7")])
        // Ohne geschriebenes Gesetz nur die erste Nummer („5 Personen“ ist keine).
        XCTAssertEqual(found("nach § 4, 5 personen", defaultLaw: "estg"), [Found("§ 4", "estg", "4", inferred: true)])
    }

    /// 5: „des Gesellschaftsvertrags“, „der Satzung“, ausgeschriebene Namen.
    func testOtherDocumentsAreNotInherited() {
        for text in ["§ 4 EStG. § 5 des Gesellschaftsvertrags", "§ 4 EStG. § 7 der Satzung", "§ 4 EStG. § 15 Handelsgesetzbuch",
                     "§ 4 EStG. § 5 Abs. 2 der neuen Satzung"] {
            XCTAssertEqual(found(text).map(\.text), ["§ 4 EStG"], text)
        }
        XCTAssertEqual(found("§ 4 EStG; Abs. 2 des Vertrags"), [Found("§ 4 EStG", "estg", "4")])
        XCTAssertEqual(found("§ 5 des Gesellschaftsvertrags", defaultLaw: "estg"), [])
    }

    /// 6: Nach einem unbekannten Gesetz wird bis zum nächsten bekannten nichts erschlossen.
    func testUnknownLawBlocksInference() {
        XCTAssertEqual(found("§ 1 EStG. Nach § 3 SolZG gilt. § 4 regelt"), [Found("§ 1 EStG", "estg", "1")])
        XCTAssertEqual(found("§ 3 SolZG. § 4 regelt", defaultLaw: "estg"), [])
        XCTAssertEqual(found("§ 3 SolZG. § 4 AO. § 5"),
                       [Found("§ 4 AO", "ao", "4"), Found("§ 5", "ao", "5", inferred: true)])
        let twins = [entry("a1", "AStG", aliases: ["Doppel"]), entry("a2", "BStG", aliases: ["Doppel"])]
        XCTAssertEqual(found("§ 1 EStG. § 2 Doppel. § 3", extra: twins).map(\.text), ["§ 1 EStG"])
    }

    /// 7: „§ 35 a EStG“ mit abgesetztem Buchstaben.
    func testSpacedLetter() {
        XCTAssertEqual(found("§ 1 AO. § 35 a EStG").last, Found("§ 35 a EStG", "estg", "35a"))
        XCTAssertEqual(found("§ 35 a Abs. 2 EStG"), [Found("§ 35 a Abs. 2 EStG", "estg", "35a", "2")])
        XCTAssertEqual(found("§ 35 a", defaultLaw: "estg"), [Found("§ 35 a", "estg", "35a", inferred: true)])
        XCTAssertEqual(found("§ 35 a und § 36 EStG").map(\.key), ["35a", "36"])
        // Unsicher: nichts.
        XCTAssertEqual(found("§ 35 a b EStG"), [])
        XCTAssertEqual(found("§ 35 a wird", defaultLaw: "estg"), [])
        // „f.“, „a.F.“ und „i.V.m.“ sind keine Buchstaben der Nummer.
        XCTAssertEqual(found("§ 4 f. EStG").first?.key, "4")
        XCTAssertEqual(found("§ 4 a.F. EStG", defaultLaw: "estg").first?.key, "4")
        XCTAssertEqual(found("§ 4 i.V.m. § 5 EStG").map(\.key), ["4", "5"])
    }

    /// 8: In „§§“ ist „und 2“ nach einer Absatzangabe ein Absatz, kein Paragraph.
    func testPluralAbsatzList() {
        XCTAssertEqual(found("§§ 4 Abs. 1 und 2, 5 EStG"),
                       [Found("§§ 4 Abs. 1 und 2", "estg", "4", "1"), Found("5 EStG", "estg", "5")])
    }

    /// 9: „AEAO zu §“ spricht von der AO.
    func testAEAOSetsContextToAO() {
        XCTAssertEqual(found("§ 4 EStG. Nr. 2 AEAO zu § 122 und § 124").last, Found("§ 124", "ao", "124", inferred: true))
        XCTAssertEqual(found("§ 4 EStG. AEAO zu § 122. § 124").last, Found("§ 124", "ao", "124", inferred: true))
        // Ohne AO im Katalog: gesperrt statt EStG.
        let withoutAO = entries.filter { $0.id != "ao" }
        XCTAssertEqual(LawCitationScanner(entries: withoutAO).citations(in: "§ 4 EStG. AEAO zu § 122. § 124").map(\.lawID), ["estg", "aeao"])
    }

    /// 10: Bindestrich mit Buchstaben gehört zum Wort.
    func testHyphenatedWordsAreNotTheLaw() {
        XCTAssertEqual(found("§ 4 EStG-E"), [])
        XCTAssertEqual(found("§ 4 AO-Kommentar"), [])
        XCTAssertEqual(found("§ 4 EStG-E", defaultLaw: "estg"), [])
        XCTAssertEqual(found("§ 4 EStG - neu"), [Found("§ 4 EStG", "estg", "4")])
    }

    /// 11: Datumsartige Schlüssel. Echte Schlüssel: LStR/EStR „9.1“, „39b.1“;
    /// UStAE auch „4.12.10“, „4.11b.1“ (höchstens zwei Punkte, Gruppen ≤ 2 Ziffern).
    func testDateLikeKeysAreRejected() {
        XCTAssertEqual(found("LStR 1.1.2025"), [])
        XCTAssertEqual(found("LStR 1.1.25"), [])
        XCTAssertEqual(found("R 1.1.2025 LStR"), [])
        XCTAssertEqual(found("Abschnitt 1.1.2025 UStAE"), [])
        XCTAssertEqual(found("EStR 2025.1"), [])
        XCTAssertEqual(found("Abschnitt 4.12.10 UStAE"), [Found("Abschnitt 4.12.10 UStAE", "ustae", "4.12.10")])
        XCTAssertEqual(found("A 4.11b.1 UStAE"), [Found("A 4.11b.1 UStAE", "ustae", "4.11b.1")])
        XCTAssertEqual(found("LStR 39b.1"), [Found("LStR 39b.1", "lstr", "39b.1")])
    }

    /// 12: Zerlegte Umlaute gehören zum Wort.
    func testCombiningMarksAreWordCharacters() {
        XCTAssertEqual(found("§ 5 AO\u{308}G"), [])
        XCTAssertEqual(found("§ 5 AO\u{308}G", defaultLaw: "estg"), [])
        XCTAssertEqual(found("Gru\u{308}nde § 5 AO").map(\.law), ["ao"])
    }

    /// 13: Eine Fortsetzung „Abs. 2“ behält das Gesetz ihres Paragraphen.
    func testContinuationKeepsItsLaw() {
        XCTAssertEqual(found("§ 4 EStG i.V.m. Abs. 2 GG"), [Found("§ 4 EStG", "estg", "4")])
        XCTAssertEqual(found("§ 4 EStG i.V.m. Abs. 2 EStG"), [Found("§ 4 EStG", "estg", "4"), Found("Abs. 2 EStG", "estg", "4", "2")])
        XCTAssertEqual(found("§ 4 EStG i.V.m. Abs. 2"), [Found("§ 4 EStG", "estg", "4"), Found("Abs. 2", "estg", "4", "2", inferred: true)])
        XCTAssertEqual(found("R 9.1 LStR und Abs. 2"), [Found("R 9.1 LStR", "lstr", "9.1"), Found("Abs. 2", "lstr", "9.1", "2", inferred: true)])
    }
}
