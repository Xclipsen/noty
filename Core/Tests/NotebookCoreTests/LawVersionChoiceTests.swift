import XCTest
@testable import NotebookCore

/// Fassung nach Veranlagungsjahr: Stand aus den Statuszeilen des Katalogs.
/// Der echte Katalog hat derzeit je Gesetz nur eine Fassung, daher hier
/// synthetische Einträge mit mehreren Fassungen.
final class LawVersionChoiceTests: XCTestCase {
    private func version(_ id: String, _ status: [String]) -> LawVersion {
        LawVersion(id: id, status: status, dataUrl: "/data/laws/estg/\(id)/law.json", pdfUrl: nil, pages: 1, sectionCount: 1, sha256: [:])
    }
    private func entry(_ versions: [LawVersion], current: String) -> LawEntry {
        LawEntry(id: "estg", abbr: "EStG", name: "Einkommensteuergesetz", category: "Test", kind: "law", aliases: nil,
                 currentVersion: current, versions: versions)
    }
    private func day(_ d: Int, _ m: Int, _ y: Int) -> CivilDay { CivilDay(year: y, month: m, day: d) }

    // MARK: Stand lesen (echte Statuszeilen)

    func testLastChangeFromRealStatusLines() {
        let estg = version("a", ["Neugefasst durch Bek. v. 8.10.2009 I 3366, 3862;", "zuletzt geändert durch Art. 7 G v. 29.6.2026 I Nr. 197"])
        XCTAssertEqual(LawVersionChoice.lastChange(estg), day(29, 6, 2026))
        XCTAssertEqual(LawVersionChoice.lastChange(version("a", ["Zuletzt geändert durch Art. 4 G v. 4.2.2026 I Nr. 33",
                                                                 "Mittelbare Änderung durch Art. 59 Nr. 1 G v. 4.2.2026 I Nr. 33 ist berücksichtigt"])), day(4, 2, 2026))
        // Nur eine Neufassung.
        XCTAssertEqual(LawVersionChoice.lastChange(version("a", ["Neugefasst durch Bek. v. 25.8.1969 I 1317"])), day(25, 8, 1969))
        // „geändert durch“ ohne „zuletzt“ (BBiG).
        XCTAssertEqual(LawVersionChoice.lastChange(version("a", ["Neugefasst durch Bek. v. 16.4.2025 I Nr. 117; 2025 I Nr. 129;",
                                                                 "geändert durch Art. 9 G v. 28.10.2025 I Nr. 259"])), day(28, 10, 2025))
        // Textlich nachgewiesene Änderung zählt (sie steht im Text).
        XCTAssertEqual(LawVersionChoice.lastChange(version("a", ["Zuletzt geändert durch Art. 18 G v. 22.12.2025 I Nr. 349",
                                                                 "Änderung durch Art. 10 G v. 20.5.2026 I Nr. 152 textlich nachgewiesen, dokumentarisch noch nicht abschließend bearbeitet"])),
                       day(20, 5, 2026))
        // „ist nicht ausführbar“ / „nicht berücksichtigt“ zählen nicht.
        XCTAssertEqual(LawVersionChoice.lastChange(version("a", [
            "Zuletzt geändert durch Art. 6 G v. 15.7.2024 I Nr. 236",
            "Mittelbare Änderung durch Art. 5a Nr. 2 Buchst. a G v. 12.12.2025 I 1 ist nicht ausführbar, da das geänderte G v. 3.3.2026 I 2 zum Zeitpunkt des Inkrafttretens des mittelbaren Änderungsgesetzes bereits zum 1.1.2026 in Kraft getreten war",
            "Änderung durch Art. 3 G v. 1.6.2026 I Nr. 5 noch nicht berücksichtigt",
        ])), day(15, 7, 2024))
        // Fundstellen („2002 I 679“) sind kein Datum.
        XCTAssertEqual(LawVersionChoice.lastChange(version("a", ["Neugefasst durch Bek. v. 2.1.2002 I 42, 2909; 2003, 738;"])), day(2, 1, 2002))
        // UStAE: Stand mit Monatsnamen, „vom 1. Oktober 2010“ ist älter.
        XCTAssertEqual(LawVersionChoice.lastChange(version("a", ["Umsatzsteuer-Anwendungserlass vom 1. Oktober 2010", "Stand 2. Juni 2026"])), day(2, 6, 2026))
        XCTAssertEqual(LawVersionChoice.lastChange(version("a", ["Stand: 1.3.2026"])), day(1, 3, 2026))
        // Nichts Lesbares.
        XCTAssertNil(LawVersionChoice.lastChange(version("a", [])))
        XCTAssertNil(LawVersionChoice.lastChange(version("a", ["Gespeicherter Inhalt des offiziellen BMF-Handbuchs; Einzeländerungshinweise sind im Text erhalten."])))
        XCTAssertNil(LawVersionChoice.lastChange(version("a", ["zuletzt geändert durch Art. 7 G v. 31.13.2026"])))
    }

    /// BMF-Handbücher: nur das Jahr, gilt ab 1.1. dieses Veranlagungszeitraums.
    func testHandbookYears() throws {
        let lstr = try XCTUnwrap(LawVersionChoice.lastChange(version("a", ["Lohnsteuer-Richtlinien aus LStH 2026",
                                                                           "Gespeicherter Inhalt des offiziellen BMF-Handbuchs; Einzeländerungshinweise sind im Text erhalten."])))
        XCTAssertEqual(lstr, CivilDay(year: 2026, month: 1, day: 1, yearOnly: true))
        XCTAssertTrue(lstr.yearOnly)
        XCTAssertEqual(lstr.text, "2026")
        XCTAssertEqual(LawVersionChoice.lastChange(version("a", ["Einkommensteuer-Richtlinien aus EStH 2025"]))?.year, 2025)
        XCTAssertEqual(LawVersionChoice.lastChange(version("a", ["Anwendungserlass zur Abgabenordnung aus AO-Handbuch 2026"]))?.year, 2026)
        // Ein volles Datum geht dem Handbuchjahr vor.
        XCTAssertEqual(LawVersionChoice.lastChange(version("a", ["aus LStH 2026", "Stand 2. Juni 2025"])), day(2, 6, 2025))
        XCTAssertEqual(day(29, 6, 2026).text, "29.6.2026")
    }

    // MARK: Fassung zum Jahr

    func testVersionForYear() {
        let v2023 = version("v2023", ["zuletzt geändert durch Art. 1 G v. 22.12.2023 I Nr. 411"])
        let v2024 = version("v2024", ["zuletzt geändert durch Art. 3 G v. 2.12.2024 I Nr. 387"])
        let v2026 = version("v2026", ["Neugefasst durch Bek. v. 8.10.2009 I 3366;", "zuletzt geändert durch Art. 7 G v. 29.6.2026 I Nr. 197"])
        // Reihenfolge im Katalog egal.
        let law = entry([v2026, v2023, v2024], current: "v2026")
        XCTAssertEqual(LawVersionChoice.version(for: 2023, in: law)?.id, "v2023")
        XCTAssertEqual(LawVersionChoice.version(for: 2024, in: law)?.id, "v2024")
        XCTAssertEqual(LawVersionChoice.version(for: 2025, in: law)?.id, "v2024")
        XCTAssertEqual(LawVersionChoice.version(for: 2026, in: law)?.id, "v2026")
        XCTAssertEqual(LawVersionChoice.version(for: 2030, in: law)?.id, "v2026")
        // Vor der ältesten Fassung: keine passt.
        XCTAssertNil(LawVersionChoice.version(for: 2022, in: law))
        // Grenze: Änderung am 31.12. zählt zum Jahr, am 1.1. zum nächsten.
        let edge = entry([version("a", ["zuletzt geändert durch Art. 1 G v. 31.12.2024"]), version("b", ["zuletzt geändert durch Art. 1 G v. 1.1.2025"])], current: "b")
        XCTAssertEqual(LawVersionChoice.version(for: 2024, in: edge)?.id, "a")
        XCTAssertEqual(LawVersionChoice.version(for: 2025, in: edge)?.id, "b")
    }

    func testVersionForYearUndeterminable() {
        let dated = version("a", ["zuletzt geändert durch Art. 1 G v. 22.12.2023 I Nr. 411"])
        // Eine Fassung ohne lesbaren Stand: Reihenfolge unbekannt.
        XCTAssertNil(LawVersionChoice.version(for: 2026, in: entry([dated, version("b", [])], current: "b")))
        // Gleicher Stand: nur die aktuelle Fassung ist eindeutig.
        let twin = version("b", ["zuletzt geändert durch Art. 1 G v. 22.12.2023 I Nr. 411"])
        XCTAssertEqual(LawVersionChoice.version(for: 2024, in: entry([dated, twin], current: "b"))?.id, "b")
        XCTAssertNil(LawVersionChoice.version(for: 2024, in: entry([dated, twin, version("c", ["Stand 1. Juli 2026"])], current: "c")))
        // Eine einzige Fassung (wie der echte Katalog heute).
        let single = entry([version("a", ["zuletzt geändert durch Art. 7 G v. 29.6.2026 I Nr. 197"])], current: "a")
        XCTAssertEqual(LawVersionChoice.version(for: 2026, in: single)?.id, "a")
        XCTAssertNil(LawVersionChoice.version(for: 2025, in: single))
    }

    /// Handbuchjahre: LStH 2025 gilt für 2025, LStH 2026 für 2026.
    func testVersionForYearWithHandbooks() {
        let law = entry([version("h2025", ["Lohnsteuer-Richtlinien aus LStH 2025"]), version("h2026", ["Lohnsteuer-Richtlinien aus LStH 2026"])], current: "h2026")
        XCTAssertEqual(LawVersionChoice.version(for: 2025, in: law)?.id, "h2025")
        XCTAssertEqual(LawVersionChoice.version(for: 2026, in: law)?.id, "h2026")
        XCTAssertNil(LawVersionChoice.version(for: 2024, in: law))
    }

    /// Opt-in: jede Fassung des echten Katalogs hat einen lesbaren Stand.
    func testRealCatalogStatusIsReadable() throws {
        guard let path = ProcessInfo.processInfo.environment["NOTY_LAW_FIXTURE_ROOT"] else { throw XCTSkip("Realen Gesetzesbestand über scripts/check_law_workflow.sh prüfen.") }
        let url = URL(fileURLWithPath: path).appendingPathComponent("catalog.json")
        let catalog = try JSONDecoder().decode(LawCatalog.self, from: Data(contentsOf: url)).validated()
        for entry in catalog.entries {
            for v in entry.versions {
                let last = try XCTUnwrap(LawVersionChoice.lastChange(v), "\(entry.id): \(v.status)")
                XCTAssertGreaterThanOrEqual(last.year, 1949, entry.id)
                XCTAssertLessThanOrEqual(last.year, 2100, entry.id)
            }
            // Aktuelle Fassung für ein Jahr nach ihrem Stand.
            let current = try XCTUnwrap(entry.versions.first { $0.id == entry.currentVersion })
            let year = try XCTUnwrap(LawVersionChoice.lastChange(current)).year
            XCTAssertEqual(LawVersionChoice.version(for: year, in: entry)?.id, entry.currentVersion, entry.id)
        }
    }
}
