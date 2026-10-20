import XCTest
@testable import NotebookCore

/// Opt-in full fixture roundtrip; never depends on a sibling checkout for the
/// normal unit suite. scripts/check_law_workflow.sh supplies the public data root.
final class LawRealCatalogTests: XCTestCase, @unchecked Sendable {
    func testAllRealDocumentsAndPDFsSurviveOfflineRestart() async throws {
        guard let path = ProcessInfo.processInfo.environment["NOTY_LAW_FIXTURE_ROOT"] else { throw XCTSkip("Realen Gesetzesbestand über scripts/check_law_workflow.sh prüfen.") }
        let source = URL(fileURLWithPath: path), parent = source.deletingLastPathComponent()
        let catalog = try JSONDecoder().decode(LawCatalog.self, from: Data(contentsOf: source.appendingPathComponent("catalog.json"))).validated()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noty-law-roundtrip-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = LawOfflineStore(root: root)
        for entry in catalog.entries {
            let v = try XCTUnwrap(entry.versions.first { $0.id == entry.currentVersion })
            let bytes = try Data(contentsOf: parent.appendingPathComponent(String(v.dataUrl.dropFirst())))
            let doc = try JSONDecoder().decode(LawDocument.self, from: bytes).validated(for: entry, version: v)
            let keys = doc.sections.flatMap(\.keys)
            XCTAssertEqual(Set(keys).count, keys.count, entry.abbr)
            try await store.putDocument(bytes, entry: entry, version: v)
            if let path = v.pdfUrl {
                let pdf = try Data(contentsOf: parent.appendingPathComponent(String(path.dropFirst())))
                _ = try await store.putPDF(pdf, id: entry.id, version: v.id)
                let disk = try await store.pdfData(entry.id, version: v.id)
                XCTAssertEqual(pdf, disk, "PDF-Originalbytes: \(entry.abbr)")
            }
        }
        try await store.publish(catalog)
        let restarted = LawOfflineStore(root: root)
        let loaded = try await restarted.catalog()
        let recovered = try XCTUnwrap(loaded)
        XCTAssertEqual(recovered.entries.map(\.id), catalog.entries.map(\.id))
        for entry in recovered.entries {
            let v = try XCTUnwrap(entry.versions.first { $0.id == entry.currentVersion })
            let doc = try await restarted.document(entry, version: v)
            XCTAssertEqual(doc.sections.count, v.sectionCount)
        }
        for (query, id, key) in [("144 HBG", "hgb", "144"), ("EStR 4.2", "estr", "4.2"), ("LStR 39b.1", "lstr", "39b.1"), ("122 AEAO", "aeao", "122")] {
            let target = try XCTUnwrap(LawQuickTarget.parse(query, entries: recovered.entries), query)
            XCTAssertEqual(target.lawID, id)
            let entry = try XCTUnwrap(recovered.entries.first { $0.id == id })
            let v = try XCTUnwrap(entry.versions.first { $0.id == entry.currentVersion })
            let doc = try await restarted.document(entry, version: v)
            XCTAssertNotNil(doc.sections.first { $0.keys.contains(key) }, query)
        }
    }
    /// Every word of every real section can be marked and found again: the
    /// anchor contract shared with the website holds for the actual texts.
    func testEveryRealWordAnchorsAndMapsBack() throws {
        guard let path = ProcessInfo.processInfo.environment["NOTY_LAW_FIXTURE_ROOT"] else { throw XCTSkip("Realen Gesetzesbestand über scripts/check_law_workflow.sh prüfen.") }
        let source = URL(fileURLWithPath: path), parent = source.deletingLastPathComponent()
        let catalog = try JSONDecoder().decode(LawCatalog.self, from: Data(contentsOf: source.appendingPathComponent("catalog.json"))).validated()
        let words = try NSRegularExpression(pattern: "[\\p{L}\\p{N}]+")
        var checked = 0
        for entry in catalog.entries {
            let v = try XCTUnwrap(entry.versions.first { $0.id == entry.currentVersion })
            let doc = try JSONDecoder().decode(LawDocument.self, from: Data(contentsOf: parent.appendingPathComponent(String(v.dataUrl.dropFirst()))))
            for section in doc.sections {
                let text = section.text as NSString
                let matches = words.matches(in: section.text, range: NSRange(location: 0, length: text.length))
                // First, last and a spread of words plus one multi-word span keep the run short.
                let picked = matches.isEmpty ? [] : Array(Set([0, matches.count / 3, matches.count / 2, matches.count - 1]))
                var ranges = picked.map { matches[$0].range }
                // A span of up to 40 words: well within the 4000-letter limit of the marking UI.
                if matches.count > 3 { ranges.append(NSUnionRange(matches[1].range, matches[min(matches.count - 2, 41)].range)) }
                let anchors = try ranges.map { try XCTUnwrap(LawTextAnchor.anchor(text: section.text, range: $0, sectionID: section.id), "\(entry.abbr) \(section.label)") }
                // One mapping per section, as the reader does for all its marks.
                for (range, found) in zip(ranges, LawTextAnchor.originalRanges(text: section.text, anchors: anchors)) {
                    let mapped = try XCTUnwrap(found, "\(entry.abbr) \(section.label)")
                    XCTAssertEqual(LawTextAnchor.canonical(text.substring(with: mapped)), LawTextAnchor.canonical(text.substring(with: range)), "\(entry.abbr) \(section.label)")
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 10_000)
    }
}
