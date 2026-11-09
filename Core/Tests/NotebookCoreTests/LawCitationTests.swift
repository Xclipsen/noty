import XCTest
@testable import NotebookCore

/// Paragraphen-Links: Erkennung von Gesetzesverweisen in Text und PDF-Text.
/// Abkürzungen, Aliasse und Schlüsselformen wie im echten Katalog
/// (`gesetzessammlung-noty`): Gesetze mit Schlüsseln „35a“, Richtlinien
/// „9.1“/„39b.1“, AEAO „122“ (Abschnitt „AEAO zu § 122“), UStAE „1.1“.
final class LawCitationTests: XCTestCase {
    private func entry(_ id: String, _ abbr: String, kind: String = "law", aliases: [String]? = nil, name: String? = nil) -> LawEntry {
        LawEntry(id: id, abbr: abbr, name: name ?? abbr, category: "Test", kind: kind, aliases: aliases, currentVersion: "v1",
                 versions: [LawVersion(id: "v1", status: [], dataUrl: "/data/laws/\(id)/v1/law.json", pdfUrl: nil, pages: 1, sectionCount: 1, sha256: [:])])
    }
    /// Names as in the real catalog (`catalog.json`).
    private lazy var entries: [LawEntry] = [
        entry("ao", "AO", name: "Abgabenordnung"), entry("fgo", "FGO", name: "Finanzgerichtsordnung"),
        entry("estg", "EStG", name: "Einkommensteuergesetz"), entry("estdv", "EStDV", name: "Einkommensteuer-Durchführungsverordnung"),
        entry("ustg", "UStG", name: "Umsatzsteuergesetz"), entry("kstg", "KStG", name: "Körperschaftsteuergesetz"),
        entry("gewstg", "GewStG", name: "Gewerbesteuergesetz"), entry("hgb", "HGB", aliases: ["HBG"], name: "Handelsgesetzbuch"),
        entry("bgb", "BGB", name: "Bürgerliches Gesetzbuch"),
        entry("gmbhg", "GmbHG", aliases: ["GmbH-Gesetz"], name: "Gesetz betreffend die Gesellschaften mit beschränkter Haftung"),
        entry("inso", "InsO", name: "Insolvenzordnung"), entry("erbstg", "ErbStG", name: "Erbschaftsteuer- und Schenkungsteuergesetz"),
        entry("stbvv", "StBVV", name: "Steuerberatervergütungsverordnung"),
        entry("sgb4", "SGB IV", aliases: ["SGB 4"], name: "Sozialgesetzbuch – Viertes Buch"),
        entry("sgb5", "SGB V", aliases: ["SGB 5"], name: "Sozialgesetzbuch – Fünftes Buch"),
        entry("sgb6", "SGB VI", aliases: ["SGB 6"], name: "Sozialgesetzbuch – Sechstes Buch"),
        entry("gg", "GG"),
        entry("ustae", "UStAE", kind: "administration", name: "Umsatzsteuer-Anwendungserlass"),
        entry("estr", "EStR", kind: "administration", name: "Einkommensteuer-Richtlinien"),
        entry("lstr", "LStR", kind: "administration", name: "Lohnsteuer-Richtlinien"),
        entry("aeao", "AEAO", kind: "administration", name: "Anwendungserlass zur Abgabenordnung"),
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
        compact(scan(text, defaultLaw: defaultLaw, extra: extra), text)
    }
    /// A law's own text in the reader (`lawText`), with `law` as the default.
    private func inLaw(_ law: String, _ text: String) -> [Found] {
        compact(LawCitationScanner(entries: entries).citations(in: text, defaultLawID: law, lawText: true), text)
    }
    private func compact(_ result: [LawCitation], _ text: String) -> [Found] {
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
        // Gesetzestext im Leser (mit Namen, Sätzen über fremde Vorschriften).
        let lawParagraph = "(1) 1Nach § 10 Absatz 1 Nummer 2 in Verbindung mit § 233a der Abgabenordnung gelten die Vorschriften des Handelsgesetzbuchs. 2Die §§ 4 bis 7 bleiben unberührt; § 15 Abs. 1 Satz 1 Nr. 2 gilt.\n"
        let lawText = String(repeating: lawParagraph, count: 50_000 / lawParagraph.count + 1)
        let lawStarted = Date()
        let lawResult = scanner.citations(in: lawText, defaultLawID: "estg", lawText: true)
        let lawElapsed = Date().timeIntervalSince(lawStarted)
        XCTAssertEqual(lawResult.count, (lawText.components(separatedBy: "\n").count - 1) * 5)
        print("LawCitationScanner (Gesetzestext): \((lawText as NSString).length) UTF-16-Einheiten in \(Int(lawElapsed * 1000)) ms")
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
                     "XYZG", "(", ")", "-", "–", "ff.", "f.", "Buchst.", "lit.", "ö", "\u{308}", "🧾", "Abschnitt", "in", "Verbindung", "mit",
                     // P2: Namen, Fassungen, Artikel-Paragraphen, Aktenzeichen, Listen.
                     "Abgabenordnung", "des Einkommensteuergesetzes", "Sechsten Buches Sozialgesetzbuch", "(EStG)", "dieses Gesetzes",
                     "Vorschriften", "Teil", "in der", "Fassung", "a.F.", "1987", "vor", "Artikel", "ff", "1.", "Halbsatz", "erste",
                     "V", "/", "und/oder", "bzw.", "auch", "nach", "\u{2010}", "Zu", "dieses", "Muster-", "2Die", ";"]
        var generator = SystemRandomNumberGenerator()
        let scanner = LawCitationScanner(entries: entries, defaultLawID: "estg")
        for round in 0..<30_000 {
            let count = Int.random(in: 1...12, using: &generator)
            let text = (0..<count).map { _ in parts.randomElement(using: &generator)! }.joined(separator: round % 3 == 0 ? " " : "")
            let length = (text as NSString).length
            var last = 0
            let lawText = round % 2 == 0
            for c in lawText ? scanner.citations(in: text, defaultLawID: round % 4 == 0 ? "aeao" : "estg", lawText: true) : scanner.citations(in: text) {
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
        for text in ["§ 4 EStG. § 5 des Gesellschaftsvertrags", "§ 4 EStG. § 7 der Satzung", "§ 4 EStG. § 15 Investmentsteuergesetz",
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
        // „a.F.“ (alte Fassung) ist nicht der Text, den der Leser zeigt: kein Link.
        XCTAssertEqual(found("§ 4 a.F. EStG", defaultLaw: "estg"), [])
        XCTAssertEqual(found("§ 4 i.V.m. § 5 EStG").map(\.key), ["4", "5"])
    }

    /// 8: In „§§“ ist „und 2“ nach einer Absatzangabe ein Absatz, kein Paragraph.
    func testPluralAbsatzList() {
        XCTAssertEqual(found("§§ 4 Abs. 1 und 2, 5 EStG"),
                       [Found("§§ 4 Abs. 1 und 2", "estg", "4", "1"), Found("5 EStG", "estg", "5")])
    }

    /// 9: „AEAO zu §“ spricht von der AO.
    func testAEAOSetsContextToAO() {
        // „AEAO zu § 122 und § 124“: das zweite ist eher AEAO zu § 124 – unsicher, kein Link.
        XCTAssertEqual(found("§ 4 EStG. Nr. 2 AEAO zu § 122 und § 124").map(\.key), ["4", "122"])
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

    // MARK: P2: Standardgesetz, Querverweise im Gesetzestext, Gesetzesnamen

    /// Standardgesetz je Aufruf (Heft) statt aus dem init; nil nimmt das des init.
    func testPerCallDefaultLaw() {
        let plain = LawCitationScanner(entries: entries)
        let withDefault = LawCitationScanner(entries: entries, defaultLawID: "estg")
        XCTAssertEqual(plain.citations(in: "§ 35a", defaultLawID: "estg").map(\.lawID), ["estg"])
        XCTAssertEqual(plain.citations(in: "§ 35a", defaultLawID: nil), [])
        XCTAssertEqual(plain.citations(in: "§ 35a", defaultLawID: "unbekannt"), [])
        XCTAssertEqual(withDefault.citations(in: "§ 35a", defaultLawID: nil).map(\.lawID), ["estg"])
        XCTAssertEqual(withDefault.citations(in: "§ 35a", defaultLawID: "ao").map(\.lawID), ["ao"])
        XCTAssertEqual(withDefault.citations(in: "§ 35a", defaultLawID: "unbekannt").map(\.lawID), ["estg"])
        XCTAssertEqual(withDefault.citations(in: "§ 35a"), withDefault.citations(in: "§ 35a", defaultLawID: nil))
        // Im Heft gilt weiter der Zusammenhang vor dem Standardgesetz.
        XCTAssertEqual(plain.citations(in: "§ 4 AO. Dann § 5", defaultLawID: "estg").map(\.lawID), ["ao", "ao"])
        // Ein R ohne Gesetz nur mit einer Verwaltungsvorschrift als Standard.
        XCTAssertEqual(plain.citations(in: "R 9.1", defaultLawID: "lstr").map(\.lawID), ["lstr"])
        XCTAssertEqual(plain.citations(in: "R 9.1", defaultLawID: "estg"), [])
    }

    /// Querverweise im Text eines Gesetzes (echte Sätze aus EStG, AO, KStG, StBVV).
    func testCrossReferencesInLawText() {
        XCTAssertEqual(inLaw("estg", "nach § 10 Absatz 1 Nummer 2 abziehbar"),
                       [Found("§ 10 Absatz 1 Nummer 2", "estg", "10", "1", inferred: true)])
        XCTAssertEqual(inLaw("estg", "Grundfreibetrag nach § 32a Absatz 1 Satz 2 Nummer 1 nicht übersteigen"),
                       [Found("§ 32a Absatz 1 Satz 2 Nummer 1", "estg", "32a", "1", inferred: true)])
        XCTAssertEqual(inLaw("estg", "§ 33 der Abgabenordnung"), [Found("§ 33 der Abgabenordnung", "ao", "33")])
        XCTAssertEqual(inLaw("estg", "Gewinn im Sinne des § 15 Abs. 1 Satz 1 Nr. 2"),
                       [Found("§ 15 Abs. 1 Satz 1 Nr. 2", "estg", "15", "1", inferred: true)])
        XCTAssertEqual(inLaw("estg", "bestimmt sich nach den §§ 13 bis 24."), [Found("§§ 13", "estg", "13", inferred: true), Found("24", "estg", "24", inferred: true)])
        XCTAssertEqual(inLaw("estg", "2§ 22a Absatz 2 gilt entsprechend."), [Found("§ 22a Absatz 2", "estg", "22a", "2", inferred: true)])
        XCTAssertEqual(inLaw("estg", "§ 6b mit Ausnahme des § 6b Absatz 4 Nummer 1 ist entsprechend anzuwenden").map(\.key), ["6b", "6b"])
        XCTAssertEqual(inLaw("estg", "die zentrale Stelle (§ 81) zu übermitteln").map(\.key), ["81"])
        // Ein anderes Gesetz davor ändert nichts: ein bloßes § ist das eigene Gesetz.
        let text = "Steuern nach § 235 der Abgabenordnung und Zinsen nach § 233a der Abgabenordnung sowie Verluste nach § 10d"
        XCTAssertEqual(inLaw("estg", text).map(\.law), ["ao", "ao", "estg"])
        XCTAssertEqual(found(text).map(\.law), ["ao", "ao", "ao"]) // im Heft: Zusammenhang
        // Ketten nehmen das nachgestellte Gesetz.
        XCTAssertEqual(inLaw("estg", "Körperschaft im Sinne des § 14 oder § 17 des Körperschaftsteuergesetzes").map(\.law), ["kstg", "kstg"])
        XCTAssertEqual(inLaw("stbvv", "nach § 4 Absatz 1, auch in Verbindung mit § 5 Absatz 1, des Einkommensteuergesetzes aus der Summe").map(\.law),
                       ["estg", "estg"])
        XCTAssertEqual(inLaw("estg", "Rentenversicherung nach § 107 des Sechsten Buches Sozialgesetzbuch"),
                       [Found("§ 107 des Sechsten Buches Sozialgesetzbuch", "sgb6", "107")])
        XCTAssertEqual(inLaw("estg", "die Vorschriften des § 5 Absatz 2 Nummer 2 zweiter Halbsatz des Körperschaftsteuergesetzes").map(\.law), ["kstg"])
        // „und Satz 2“ gehört zum Verweis, das Gesetz danach auch (SGB X ist nicht im Katalog).
        XCTAssertEqual(inLaw("sgb5", "§ 80 Absatz 1 Satz 1 Nummer 1 bis 3 und Satz 2 des Zehnten Buches Sozialgesetzbuch"), [])
        // Ein Gesetz nach einer Klammer gilt für die Verweise davor und darin.
        XCTAssertEqual(inLaw("estg", "Person im Sinne des § 1 Absatz 2 (gegebenenfalls in Verbindung mit § 1 Absatz 1 Satz 2) des Außensteuergesetzes nahesteht"), [])
        XCTAssertEqual(inLaw("estg", "im Sinne des § 1 Absatz 2 (siehe auch § 4) des Körperschaftsteuergesetzes").map(\.law), ["kstg", "kstg"])
        XCTAssertEqual(inLaw("estg", "nach § 21 des Beamtenversorgungsgesetzes"), [])
        XCTAssertEqual(inLaw("estg", "nach § 5 dieses Gesetzes"), [Found("§ 5 dieses Gesetzes", "estg", "5")])
        XCTAssertEqual(found("nach § 5 dieses Gesetzes", defaultLaw: "estg"), [])
        XCTAssertEqual(inLaw("ustae", "Nach § 1 dieses Vertragsmusters"), [])
    }

    /// Paragraphen eines Artikels (Mantel- und Einführungsgesetze) sind nie das eigene Gesetz.
    func testArticleSectionsInLawText() {
        XCTAssertEqual(inLaw("ao", "Artikel 97 § 1 des Einführungsgesetzes zur Abgabenordnung"), [])
        XCTAssertEqual(inLaw("estg", "Artikel 1 § 3 Satz 1 Nr. 2, § 5 Abs. 1 Satz 1 Nr. 1"), [])
        XCTAssertEqual(inLaw("bgb", "Artikel 229 § 6 Abs. 4 des Einführungsgesetzes zum Bürgerlichen Gesetzbuche"), [])
        XCTAssertEqual(found("Art. 97 § 1 EStG. Dann § 4", defaultLaw: "estg"), [])
    }

    /// Bestimmte frühere Fassungen zeigt der Leser nicht: kein Link.
    func testOldVersionsAreNotLinked() {
        XCTAssertEqual(inLaw("estg", "§ 52 Absatz 4 Satz 1 in der am 31. Dezember 2008 geltenden Fassung"), [])
        XCTAssertEqual(inLaw("estg", "§ 7 Absatz 5 in der bis zum 31. Dezember 2005 geltenden Fassung ist weiter anzuwenden"), [])
        XCTAssertEqual(inLaw("estg", "§ 13 Absatz 2 Nummer 2 des Einkommensteuergesetzes in der Fassung der Bekanntmachung vom 19. Oktober 2002"), [])
        XCTAssertEqual(inLaw("estg", "§ 51 Absatz 1 Nummer 2 Buchstabe x des Einkommensteuergesetzes 1987"), [])
        XCTAssertEqual(found("§ 4 EStG a.F."), [])
        XCTAssertEqual(found("§ 4 EStG 2002"), [])
        XCTAssertEqual(found("§ 4 EStG a. F. und § 5 AO").map(\.text), ["§ 5 AO"])
        // Dynamische Verweisung: die jeweils geltende Fassung ist die aktuelle.
        XCTAssertEqual(inLaw("estg", "§ 3 Nummer 40 in der jeweils geltenden Fassung").map(\.key), ["3"])
        XCTAssertEqual(inLaw("estg", "§ 3 Nummer 40 in der Regel").map(\.key), ["3"])
    }

    /// Verwaltungsvorschriften im Leser: Aktenzeichen, AEAO-Abschnitte, Aufzählungen.
    func testAdministrativeTextsInReader() {
        // BFH-Aktenzeichen sind keine Richtlinien.
        XCTAssertEqual(inLaw("ustae", "BFH-Urteil vom 17.05.2001 – V R 38/00, BStBl II 2003 S. 434"), [])
        XCTAssertEqual(inLaw("aeao", "BFH-Urteile vom 22.9.1992, VII R 73-74/91, BFH/NV 1993 S. 215"), [])
        XCTAssertEqual(inLaw("aeao", "BFH vom 6.7.1999, VIII R 17/97 und GrS 1/98"), [])
        XCTAssertEqual(inLaw("aeao", "StRK FGO § 69 R 171"), [Found("FGO § 69", "fgo", "69")])
        XCTAssertEqual(inLaw("lstr", "(>R 3.12 und 3.26)").map(\.key), ["3.12"])
        // Im AEAO ist ein bloßes § die AO, „zu §“/„vor §§“ aber ein AEAO-Abschnitt.
        XCTAssertEqual(inLaw("aeao", "Hierauf sind Zinsen nach § 233a anzurechnen"), [Found("§ 233a", "ao", "233a", inferred: true)])
        XCTAssertEqual(inLaw("aeao", "vgl. AEAO zu § 140 und § 146, Nr. 1.1"), [Found("AEAO zu § 140", "aeao", "140")])
        XCTAssertEqual(inLaw("aeao", "(vgl. AEAO vor §§ 169 bis 171, Nr. 6)"), [])
        XCTAssertEqual(inLaw("aeao", "Zu § 58 Nr. 9:"), [])
        XCTAssertEqual(inLaw("aeao", "muss (Mustersatzung, § 5). Als Empfänger"), [])
        XCTAssertEqual(inLaw("aeao", "(§ 66 Abs. 1 i. V. m. mit § 64 Abs. 1 FGO)").map(\.law), ["fgo", "fgo"])
        XCTAssertEqual(inLaw("aeao", "(vgl. § 208 Abs. 1 Satz 1 Nr. 2 und Nr. 3 i. V. m. Satz 3 AO)"),
                       [Found("§ 208 Abs. 1 Satz 1 Nr. 2 und Nr. 3", "ao", "208", "1"), Found("Satz 3 AO", "ao", "208", "1")])
        XCTAssertEqual(inLaw("aeao", "nach §§ 129 \u{2010} 147 InsO").map(\.law), ["inso", "inso"])
        XCTAssertEqual(inLaw("aeao", "(§ 233a Abs. 5 Satz 1 1. Halbsatz AO)"), [Found("§ 233a Abs. 5 Satz 1 1. Halbsatz AO", "ao", "233a", "5")])
        XCTAssertEqual(inLaw("aeao", "§ 215 erste Alternative BGB wird"), [Found("§ 215 erste Alternative BGB", "bgb", "215")])
        // Numerierte Gesetzesnamen („5. VermBG“) sind unbekannte Gesetze.
        XCTAssertEqual(inLaw("aeao", "Arbeitnehmer-Sparzulage (§ 14 Abs. 3 Satz 1 5. VermBG)"), [])
        // Gesperrte PDF-Überschriften („§ 2 5 b A b s . 3 U S t G“).
        XCTAssertEqual(inLaw("ustae", "d e s § 2 5 b A b s . 3 U S t G (7) 1"), [])
        XCTAssertEqual(found("n a c h § 1 1 5 S G B V", defaultLaw: "estg"), [])
        // In Richtlinien folgt ein bloßes § weiter dem Zusammenhang.
        XCTAssertEqual(inLaw("lstr", "(§ 1882 BGB); ggf. ist § 3 Nr. 26a bzw. 26b EStG anzuwenden").map(\.law), ["bgb", "estg"])
        XCTAssertEqual(inLaw("lstr", "§ 1 BGB. Die Voraussetzungen des § 8 Abs. 3 und des § 40 Abs. 1 EStG").map(\.law), ["bgb", "estg", "estg"])
        XCTAssertEqual(inLaw("ustae", "§ 1 UStDV. Leistung nach § 11 Abs. 1 und 2 und/oder 3 Nr. 3 und 4 UStG").map(\.law), ["ustg"])
    }

    /// Aufzählungen in Gesetzen: Listennummern und Absätze nach „§§ … Abs.“.
    func testListsInLawText() {
        XCTAssertEqual(inLaw("ao", "3. Firma (§§ 17ff. des Handelsgesetzbuchs) oder Name"), [Found("§§ 17ff. des Handelsgesetzbuchs", "hgb", "17")])
        XCTAssertEqual(found("§ 4ff. EStG"), [Found("§ 4ff. EStG", "estg", "4")])
        XCTAssertEqual(found("§ 4f EStG"), [Found("§ 4f EStG", "estg", "4f")]) // § 4f gibt es
        XCTAssertEqual(inLaw("estg", "die Strafvorschriften des § 370 Absatz 1 bis 4, der §§ 371, 375 Absatz 1 und des § 376 sowie die Bußgeldvorschriften der §§ 378, 379 Absatz 1 und 4 und der §§ 383 und 384 der Abgabenordnung entsprechend").map(\.law),
                       Array(repeating: "ao", count: 8))
        XCTAssertEqual(inLaw("estg", "Beiträge nach § 168 Absatz 1 Nummer 1b oder 1c (geringfügig versicherungspflichtig Beschäftigte) oder nach § 172 Absatz 3 oder 3a (versicherungsfrei) des Sechsten Buches Sozialgesetzbuch").map(\.law),
                       ["sgb6", "sgb6"])
        XCTAssertEqual(inLaw("estg", "entsprechend: 1. die §§ 41, 41a, 42e, 42f und 42g, 2. die für Steuervergütungen").map(\.key),
                       ["41", "41a", "42e", "42f", "42g"])
        XCTAssertEqual(found("(§§ 37a, 37b, 40, 40a Abs. 1, 2a und 3, § 40b EStG)"),
                       [Found("§§ 37a", "estg", "37a"), Found("37b", "estg", "37b"), Found("40", "estg", "40"),
                        Found("40a Abs. 1, 2a und 3", "estg", "40a", "1"), Found("§ 40b EStG", "estg", "40b")])
        XCTAssertEqual(found("§§ 10 Abs. 1, 10a EStG").map(\.key), ["10", "10a"])
        XCTAssertEqual(found("§§ 37a, 37b und des 40a EStG").map(\.key), ["37a", "37b", "40a"])
    }

    /// Sätze über Vorschriften eines anderen Gesetzes: bloße § darin sind unsicher.
    func testForeignProvisionSentences() {
        XCTAssertEqual(inLaw("ustg", "(6) Auf das Verfahren sind die §§ 30, 80 und 87a und der Zweite Abschnitt des Dritten Teils und der Siebente Teil der Abgabenordnung sowie die Finanzgerichtsordnung anzuwenden. (7) § 18 Absatz 4f ist anzuwenden.").map(\.key),
                       ["18"])
        XCTAssertEqual(inLaw("ao", "(8) Nicht anzuwenden auf 1. Datenübermittlungspflichten nach § 51a Absatz 2c oder Abschnitt XI des Einkommensteuergesetzes, 2. Datenübermittlungen"), [])
        let text = "3Die für den Steuerabzug von Kapitalerträgen im Sinne des § 43 Abs. 1 Satz 1 Nummer 1 und 1a geltenden Vorschriften des Einkommensteuergesetzes mit Ausnahme des § 44 Absatz 2 sind entsprechend anzuwenden. 4Der Steuersatz nach § 5 gilt."
        XCTAssertEqual(inLaw("kstg", text), [Found("§ 5", "kstg", "5", inferred: true)])
        XCTAssertEqual(inLaw("estg", "2. die Vorschriften der Abgabenordnung mit Ausnahme des § 163 der Abgabenordnung und die Strafvorschriften des § 370 Absatz 1 bis 4").map(\.key),
                       ["163"])
        // Die eigenen Vorschriften sperren nichts.
        XCTAssertEqual(inLaw("ao", "die Vorschriften der Abgabenordnung, insbesondere § 30").map(\.key), ["30"])
    }

    /// Regel 5 (großgeschriebenes Wort sperrt) trifft typische Gesetzesformen nicht.
    func testCapitalisedWordRuleInLawText() {
        XCTAssertEqual(inLaw("estg", "nach § 4 Absatz 1 oder nach § 5 zu ermitteln").map(\.key), ["4", "5"])
        XCTAssertEqual(inLaw("estg", "§ 16 Absatz 3b entsprechend").map(\.paragraph), ["3b"])
        XCTAssertEqual(inLaw("estg", "§ 10 Absatz 1 Nummer 2 Buchstabe b Doppelbuchstabe aa").map(\.key), ["10"])
        XCTAssertEqual(inLaw("estg", "§ 15 Abs. 1 Satz 1 Nr. 2 Satz 2 Halbsatz 1 und Absatz 3").map(\.key), ["15", "15"])
        // Überschrift „§ 35a Steuerermäßigung …“: kein (falscher) Link.
        XCTAssertEqual(inLaw("estg", "§ 35a Steuerermäßigung bei Aufwendungen"), [])
    }

    /// Ein ganzer Abschnittstext: jeder Treffer stimmt (Auszug EStG § 10d, § 4h).
    func testWholeSectionText() {
        let text = """
        (1) 1Negative Einkünfte, die bei der Ermittlung des Gesamtbetrags der Einkünfte nicht ausgeglichen werden, sind bis zu einem Betrag von 10 000 000 Euro vom Gesamtbetrag der Einkünfte des unmittelbar vorangegangenen Veranlagungszeitraums vorrangig vor Sonderausgaben, außergewöhnlichen Belastungen und sonstigen Abzugsbeträgen abzuziehen (Verlustrücktrag). 2Soweit ein Ausgleich der negativen Einkünfte nach Satz 1 nicht möglich ist, sind diese vom Gesamtbetrag der Einkünfte des zweiten dem Veranlagungszeitraum vorangegangenen Veranlagungszeitraums abzuziehen. 3Dabei wird der Gesamtbetrag der Einkünfte des unmittelbar vorangegangenen Veranlagungszeitraums und des zweiten dem Veranlagungszeitraum vorangegangenen Veranlagungszeitraums um die Begünstigungsbeträge nach § 34a Absatz 3 Satz 1 gemindert. 4Ist für den unmittelbar vorangegangenen Veranlagungszeitraum oder den zweiten dem Veranlagungszeitraum vorangegangenen Veranlagungszeitraum bereits ein Steuerbescheid erlassen worden, so ist er insoweit zu ändern, als der Verlustrücktrag zu gewähren oder zu berichtigen ist. 5Das gilt auch dann, wenn der Steuerbescheid unanfechtbar geworden ist; die Festsetzungsfrist endet insoweit nicht, bevor die Festsetzungsfrist für den Veranlagungszeitraum abgelaufen ist, in dem die negativen Einkünfte nicht ausgeglichen werden.
        (4) 1Der am Schluss eines Veranlagungszeitraums verbleibende Verlustvortrag ist gesondert festzustellen. 4Bei der Feststellung des verbleibenden Verlustvortrags sind die Besteuerungsgrundlagen so zu berücksichtigen, wie sie den Steuerfestsetzungen zugrunde gelegt worden sind; § 171 Absatz 10, § 175 Absatz 1 Satz 1 Nummer 1 und § 351 Absatz 2 der Abgabenordnung sowie § 42 der Finanzgerichtsordnung gelten entsprechend. 6Die Besteuerungsgrundlagen dürfen bei der Feststellung nur insoweit berücksichtigt werden, als die Aufhebung, Änderung oder Berichtigung der Steuerbescheide ausschließlich mangels Auswirkung auf die Höhe der festzusetzenden Steuer unterbleibt; § 181 Absatz 5 der Abgabenordnung ist nur anzuwenden, wenn die zuständige Finanzbehörde die Feststellung des Verlustvortrags pflichtwidrig unterlassen hat.
        """
        XCTAssertEqual(inLaw("estg", text).map { "\($0.law) \($0.key)" },
                       ["estg 34a", "ao 171", "ao 175", "ao 351", "fgo 42", "ao 181"])
    }

    // MARK: Gesetzesnamen

    func testFullLawNames() {
        XCTAssertEqual(found("§ 35a des Einkommensteuergesetzes"), [Found("§ 35a des Einkommensteuergesetzes", "estg", "35a")])
        XCTAssertEqual(found("§ 35a Einkommensteuergesetz"), [Found("§ 35a Einkommensteuergesetz", "estg", "35a")])
        XCTAssertEqual(found("§ 33 der Abgabenordnung"), [Found("§ 33 der Abgabenordnung", "ao", "33")])
        XCTAssertEqual(found("§ 3 Abs. 6 Umsatzsteuergesetz"), [Found("§ 3 Abs. 6 Umsatzsteuergesetz", "ustg", "3", "6")])
        XCTAssertEqual(found("§ 238 des Handelsgesetzbuchs").map(\.law), ["hgb"])
        XCTAssertEqual(found("§ 238 des Handelsgesetzbuches").map(\.law), ["hgb"])
        XCTAssertEqual(found("§ 433 des Bürgerlichen Gesetzbuchs").map(\.law), ["bgb"])
        XCTAssertEqual(found("§ 433 Bürgerliches Gesetzbuch").map(\.law), ["bgb"])
        XCTAssertEqual(found("§ 433 des Bu\u{308}rgerlichen Gesetzbuchs").map(\.law), ["bgb"]) // zerlegt wie in PDF-Text
        XCTAssertEqual(found("§ 8b des Körperschaftsteuergesetzes").map(\.law), ["kstg"])
        XCTAssertEqual(found("§ 13a des Erbschaftsteuer- und Schenkungsteuergesetzes").map(\.law), ["erbstg"])
        XCTAssertEqual(found("§ 5 des Gesetzes betreffend die Gesellschaften mit beschränkter Haftung").map(\.law), ["gmbhg"])
        XCTAssertEqual(found("§ 7 des Vierten Buches Sozialgesetzbuch").map(\.law), ["sgb4"])
        XCTAssertEqual(found("§ 5 Sozialgesetzbuch – Fünftes Buch").map(\.law), ["sgb5"])
        XCTAssertEqual(found("§ 5 Fünftes Buch Sozialgesetzbuch").map(\.law), ["sgb5"])
        XCTAssertEqual(found("R 9.1 der Lohnsteuer-Richtlinien"), [Found("R 9.1 der Lohnsteuer-Richtlinien", "lstr", "9.1")])
        XCTAssertEqual(found("Abschnitt 1.1 des Umsatzsteuer-Anwendungserlasses").map(\.law), ["ustae"])
        XCTAssertEqual(found("Anwendungserlass zur Abgabenordnung zu § 122").map(\.law), ["aeao"])
        // Mit Abkürzung in Klammern: dieselbe ist Teil des Verweises, eine andere sperrt.
        XCTAssertEqual(found("§ 15 Abs. 1 Einkommensteuergesetz (EStG) gilt"),
                       [Found("§ 15 Abs. 1 Einkommensteuergesetz (EStG)", "estg", "15", "1")])
        XCTAssertEqual(found("§ 15 Einkommensteuergesetz (AO)"), [])
        XCTAssertEqual(found("§ 15 EStG (Einkommensteuergesetz)").map(\.text), ["§ 15 EStG (Einkommensteuergesetz)"])
        XCTAssertEqual(found("§ 4 EStG (1)").map(\.text), ["§ 4 EStG"])
        // Vorangestellt.
        XCTAssertEqual(found("Abgabenordnung § 122"), [Found("Abgabenordnung § 122", "ao", "122")])
        XCTAssertEqual(found("Einkommensteuergesetz (EStG) § 35a"), [Found("Einkommensteuergesetz (EStG) § 35a", "estg", "35a")])
        // Name setzt den Zusammenhang.
        XCTAssertEqual(found("§ 4 der Abgabenordnung. Dann § 5").last, Found("§ 5", "ao", "5", inferred: true))
    }

    /// Nur ganze Namen, nie Teile; unbekannte Namen sperren weiter.
    func testLawNamesNeverPartial() {
        XCTAssertEqual(found("§ 5 Muster-Abgabenordnung"), [])
        XCTAssertEqual(found("§ 5 Muster-AO"), [])
        XCTAssertEqual(found("§ 5 Abgabenordnungen"), [])
        XCTAssertEqual(found("§ 5 Einkommensteuergesetzbuch"), [])
        XCTAssertEqual(found("§ 5 einkommensteuergesetz"), [])
        XCTAssertEqual(found("§ 5 Abgabenordnung-Kommentar"), [])
        XCTAssertEqual(found("§ 4 EStG. § 15 Investmentsteuergesetz. § 16").map(\.text), ["§ 4 EStG"])
        XCTAssertEqual(found("Einführungsgesetz zur Abgabenordnung § 5"), [])
        XCTAssertEqual(found("Einführungsgesetz zum Handelsgesetzbuch Art. 3"), [])
        XCTAssertEqual(found("Art. 97 § 1 des Einführungsgesetzes zur Abgabenordnung"), [])
        XCTAssertEqual(found("§ 4 Sozialgesetzbuch"), []) // welches Buch?
        // Gleicher Name bei zwei Einträgen: mehrdeutig.
        let twins = [entry("x1", "XAG", name: "Doppelgesetz"), entry("x2", "XBG", name: "Doppelgesetz")]
        XCTAssertEqual(found("§ 5 Doppelgesetz", extra: twins), [])
        XCTAssertEqual(found("§ 5 des Doppelgesetzes", defaultLaw: "estg", extra: twins), [])
    }

    func testNameForms() {
        XCTAssertEqual(LawCitationScanner.nameForms("Einkommensteuergesetz"), ["Einkommensteuergesetz", "Einkommensteuergesetzes"])
        XCTAssertEqual(LawCitationScanner.nameForms("Abgabenordnung"), ["Abgabenordnung"])
        XCTAssertEqual(LawCitationScanner.nameForms("Lohnsteuer-Richtlinien"), ["Lohnsteuer-Richtlinien"])
        XCTAssertTrue(LawCitationScanner.nameForms("Bürgerliches Gesetzbuch").contains("Bürgerlichen Gesetzbuchs"))
        XCTAssertTrue(LawCitationScanner.nameForms("Sozialgesetzbuch – Sechstes Buch").contains("Sechsten Buches Sozialgesetzbuch"))
        XCTAssertTrue(LawCitationScanner.nameForms("Anwendungserlass zur Abgabenordnung").contains("Anwendungserlasses zur Abgabenordnung"))
        XCTAssertEqual(LawCitationScanner.nameForms("AO"), [])
        XCTAssertEqual(LawCitationScanner.nameForms("Gesetz (alt)"), [])
        XCTAssertEqual(LawCitationScanner.nameForms("einkommensteuergesetz"), [])
    }

    /// Beispiel des Nutzers: „§ 3 (6) UStG“.
    func testUserExampleParagraphInBrackets() {
        for text in ["§ 3 (6) UStG", "§ 3 Abs. 6 UStG", "§ 3 VI UStG", "§ 3 Absatz 6 UStG", "§ 3 (6) des Umsatzsteuergesetzes"] {
            let result = found(text)
            XCTAssertEqual(result.map(\.law), ["ustg"], text)
            XCTAssertEqual(result.first?.key, "3", text)
            XCTAssertEqual(result.first?.paragraph, "6", text)
            XCTAssertEqual(result.first?.text, text, text)
        }
        XCTAssertEqual(found("§ 3 (6) Satz 1 UStG").first?.paragraph, "6")
    }

    /// Ganze echte Gesetzestexte im Lesemodus: jeder Treffer öffnet im Ziel-
    /// gesetz einen Abschnitt (opt-in über NOTY_LAW_FIXTURE_ROOT).
    func testLawTextLinksExistInRealCatalog() throws {
        guard let path = ProcessInfo.processInfo.environment["NOTY_LAW_FIXTURE_ROOT"] else { throw XCTSkip("Realen Gesetzesbestand über scripts/check_law_workflow.sh prüfen.") }
        let source = URL(fileURLWithPath: path), parent = source.deletingLastPathComponent()
        let catalog = try JSONDecoder().decode(LawCatalog.self, from: Data(contentsOf: source.appendingPathComponent("catalog.json"))).validated()
        let scanner = LawCitationScanner(entries: catalog.entries)
        var documents: [String: LawDocument] = [:]
        func document(_ id: String) throws -> LawDocument {
            if let doc = documents[id] { return doc }
            let entry = try XCTUnwrap(catalog.entries.first { $0.id == id })
            let v = try XCTUnwrap(entry.versions.first { $0.id == entry.currentVersion })
            let doc = try JSONDecoder().decode(LawDocument.self, from: Data(contentsOf: parent.appendingPathComponent(String(v.dataUrl.dropFirst()))))
            documents[id] = doc
            return doc
        }
        var total = 0, missing: [String] = []
        for id in ["estg", "ao", "ustg", "kstg"] {
            for section in try document(id).sections {
                for c in scanner.citations(in: section.text, defaultLawID: id, lawText: true) where c.lawID == id || ["estg", "ao", "ustg", "kstg", "hgb"].contains(c.lawID) {
                    total += 1
                    let key = c.reference.key
                    if try !document(c.lawID).sections.contains(where: { $0.id == key || $0.keys.contains(key) }) { missing.append("\(id) \(section.label): \(c.text) → \(c.lawID) \(key)") }
                }
            }
        }
        print("LawCitationScanner (Gesetzestexte): \(total) Verweise, \(missing.count) ohne Abschnitt")
        XCTAssertGreaterThan(total, 4000)
        // Bekannt: im Bestand fehlende, aufgehobene §§ 2b, 24c EStG; zwei Sätze, deren
        // Bezug nur der Inhalt klärt (EStG § 96 „gelten die §§ 385 bis 408, für das
        // Bußgeldverfahren … der Abgabenordnung“, AO § 146 „§ 146b …, § 147 … und
        // § 27b … des Umsatzsteuergesetzes“). Alles andere ist eine Regression.
        let known = ["→ estg 2b", "→ estg 24c", "estg § 96: ", "ao § 146: "]
        let unexpected = missing.filter { line in !known.contains { line.contains($0) } }
        XCTAssertEqual(unexpected, [], unexpected.prefix(60).joined(separator: "\n"))
    }
}
