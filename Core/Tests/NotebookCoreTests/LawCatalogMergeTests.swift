import XCTest
@testable import NotebookCore

/// A new catalog takes over what the old one still knows without ever
/// listing a document twice (a duplicate ID blocks every further update).
final class LawCatalogMergeTests: XCTestCase {
    private func version(_ law: String, _ id: String) -> LawVersion {
        LawVersion(id: id, status: ["Teststand"], dataUrl: "/data/laws/\(law)/\(id)/law.json", pdfUrl: nil, pages: 1, sectionCount: 1, sha256: [:])
    }
    private func entry(_ id: String, kind: String = "law", current: String, versions: [String]? = nil) -> LawEntry {
        LawEntry(id: id, abbr: id.uppercased(), name: id, category: "Test", kind: kind, aliases: nil, currentVersion: current,
                 versions: (versions ?? [current]).map { version(id, $0) })
    }
    private func ids(_ entries: [LawEntry]?) -> [String] { (entries ?? []).map(\.id) }
    private func versions(_ catalog: LawCatalog, _ id: String) throws -> [String] {
        let matches = catalog.entries.filter { $0.id == id }
        XCTAssertEqual(matches.count, 1, "\(id) listed \(matches.count) times")
        return try XCTUnwrap(matches.first).versions.map(\.id)
    }

    func testDocumentMovedToAdministrativeIsListedOnceWithItsOldVersions() throws {
        let old = LawCatalog(laws: [entry("estg", current: "v1"), entry("aeao", current: "v1")], administrative: [], generatedAt: "old")
        let new = LawCatalog(laws: [entry("estg", current: "v2")],
                             administrative: [entry("aeao", kind: "administration", current: "v2")], generatedAt: "new")
        let merged = new.retaining(old)
        XCTAssertEqual(ids(merged.laws), ["estg"])
        XCTAssertEqual(ids(merged.administrative), ["aeao"])
        XCTAssertEqual(try versions(merged, "aeao"), ["v2", "v1"])
        XCTAssertEqual(merged.entries.first(where: { $0.id == "aeao" })?.kind, "administration")
        XCTAssertEqual(merged.entries.first(where: { $0.id == "aeao" })?.currentVersion, "v2")
        XCTAssertNoThrow(try merged.validated())
        // The next update starts from the merged catalog and stays valid.
        XCTAssertNoThrow(try new.retaining(merged).validated())
    }

    func testDocumentMovedToLawsIsListedOnceWithItsOldVersions() throws {
        let old = LawCatalog(laws: [entry("estg", current: "v1")],
                             administrative: [entry("lstr", kind: "administration", current: "v1", versions: ["v1", "v0"])], generatedAt: "old")
        let new = LawCatalog(laws: [entry("estg", current: "v1"), entry("lstr", current: "v2")], administrative: nil, generatedAt: "new")
        let merged = new.retaining(old)
        XCTAssertEqual(ids(merged.laws), ["estg", "lstr"])
        XCTAssertEqual(ids(merged.administrative), [])
        XCTAssertEqual(try versions(merged, "lstr"), ["v2", "v1", "v0"])
        XCTAssertNoThrow(try merged.validated())
    }

    func testPlainUpdateKeepsOldVersionsBehindTheNewOnes() throws {
        let old = LawCatalog(laws: [entry("estg", current: "v1")],
                             administrative: [entry("lstr", kind: "administration", current: "v1")], generatedAt: "old")
        let new = LawCatalog(laws: [entry("estg", current: "v2", versions: ["v2", "v1"])],
                             administrative: [entry("lstr", kind: "administration", current: "v2")], generatedAt: "new")
        let merged = new.retaining(old)
        XCTAssertEqual(ids(merged.laws), ["estg"])
        XCTAssertEqual(ids(merged.administrative), ["lstr"])
        XCTAssertEqual(try versions(merged, "estg"), ["v2", "v1"])
        XCTAssertEqual(try versions(merged, "lstr"), ["v2", "v1"])
        XCTAssertEqual(merged.laws.first?.currentVersion, "v2")
        XCTAssertEqual(merged.generatedAt, "new")
        XCTAssertNoThrow(try merged.validated())
    }

    func testRemovedDocumentStaysInItsOldList() throws {
        let old = LawCatalog(laws: [entry("estg", current: "v1"), entry("hgb", current: "v1")],
                             administrative: [entry("lstr", kind: "administration", current: "v1")], generatedAt: "old")
        let new = LawCatalog(laws: [entry("estg", current: "v2")], administrative: [], generatedAt: "new")
        let merged = new.retaining(old)
        XCTAssertEqual(ids(merged.laws), ["estg", "hgb"])
        XCTAssertEqual(ids(merged.administrative), ["lstr"])
        XCTAssertEqual(try versions(merged, "hgb"), ["v1"])
        XCTAssertNoThrow(try merged.validated())
    }

    func testMoveAndRemovalTogether() throws {
        let old = LawCatalog(laws: [entry("estg", current: "v1"), entry("aeao", current: "v1"), entry("hgb", current: "v1")],
                             administrative: [entry("lstr", kind: "administration", current: "v1")], generatedAt: "old")
        let new = LawCatalog(laws: [entry("lstr", current: "v2")],
                             administrative: [entry("aeao", kind: "administration", current: "v2")], generatedAt: "new")
        let merged = new.retaining(old)
        XCTAssertEqual(ids(merged.laws), ["lstr", "estg", "hgb"])
        XCTAssertEqual(ids(merged.administrative), ["aeao"])
        XCTAssertEqual(try versions(merged, "lstr"), ["v2", "v1"])
        XCTAssertEqual(try versions(merged, "aeao"), ["v2", "v1"])
        XCTAssertNoThrow(try merged.validated())
    }

    func testWithoutOldCatalogNothingChanges() throws {
        let new = LawCatalog(laws: [entry("estg", current: "v1")], administrative: nil, generatedAt: "new")
        let merged = new.retaining(nil)
        XCTAssertEqual(merged.laws, new.laws)
        XCTAssertNil(merged.administrative)
    }
}
