import XCTest
@testable import NotebookCore

final class LawLibraryTests: XCTestCase, @unchecked Sendable {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("noty-law-test-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func entry(_ id: String = "hgb", abbr: String = "HGB", version: String = "v1") -> LawEntry {
        LawEntry(id: id, abbr: abbr, name: "Gesetz", category: "Test", kind: "law", aliases: id == "hgb" ? ["HBG"] : nil, currentVersion: version,
            versions: [LawVersion(id: version, status: ["Teststand"], dataUrl: "/data/laws/\(id)/\(version)/law.json", pdfUrl: "/data/laws/\(id)/\(version)/law.pdf", pages: 1, sectionCount: 1, sha256: [:])])
    }
    private func bytes(_ entry: LawEntry) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["id": entry.id, "abbr": entry.abbr, "name": entry.name, "kind": entry.kind, "version": entry.currentVersion, "status": ["Test"], "sourceUrl": "https://example.test/law", "sections": [["id": "s144", "keys": ["144"], "label": "§ 144", "title": "Test", "text": "(1) Vorschrift", "notes": ""]]])
    }
    func testQuickSearchBothOrdersAndAliasesAndSuffixes() {
        let entries = [entry(), entry("sgb4", abbr: "SGB IV"), entry("estg", abbr: "EStG")]
        for q in ["144 HGB", "HGB 144", "144 hbg", "§ 144 HGB"] {
            XCTAssertEqual(LawQuickTarget.parse(q, entries: entries), LawQuickTarget(lawID: "hgb", reference: LawReference(key: "144", paragraph: nil)), q)
        }
        XCTAssertEqual(LawQuickTarget.parse("EStG 4h Abs. 2", entries: entries)?.reference, LawReference(key: "4h", paragraph: "2"))
        XCTAssertEqual(LawQuickTarget.parse("28 SGB IV", entries: entries)?.lawID, "sgb4")
        XCTAssertEqual(LawReference.parse("15.2a Abs. 3"), LawReference(key: "15.2a", paragraph: "3"))
        XCTAssertNil(LawQuickTarget.parse("144 HB", entries: entries))
        XCTAssertNil(LawQuickTarget.parse("HGB 144 rubbish", entries: entries))
        XCTAssertNil(LawReference.parse("-1"))
    }
    func testOfflinePublicationKeepsPriorCatalogWhenNewDocumentMissing() async throws {
        let store = LawOfflineStore(root: try root())
        let old = entry(), next = entry(version: "v2")
        try await store.putDocument(bytes(old), entry: old, version: old.versions[0])
        try await store.publish(LawCatalog(laws: [old], generatedAt: "test"))
        do { try await store.publish(LawCatalog(laws: [next], generatedAt: "new")); XCTFail("Missing file published") } catch {}
        let loaded = try await store.catalog()
        XCTAssertEqual(loaded?.laws[0].currentVersion, "v1")
        let doc = try await store.document(old, version: old.versions[0]); XCTAssertEqual(doc.sections[0].id, "s144")
        var altered = try JSONDecoder().decode(LawDocument.self, from: bytes(old)); altered.sections[0].text = "Changed"
        do { try await store.putDocument(JSONEncoder().encode(altered), entry: old, version: old.versions[0]); XCTFail("Immutable version overwritten") } catch {}
        let unchanged = try await store.document(old, version: old.versions[0]); XCTAssertEqual(unchanged.sections[0].text, "(1) Vorschrift")
    }
    func testCatalogRejectsTraversalAndDuplicateAndWrongIdentity() async throws {
        var future = LawCatalog(laws: [entry()], generatedAt: "test"); future.schemaVersion = 99
        XCTAssertThrowsError(try future.validated())
        var e = entry(); e.versions[0].dataUrl = "/data/../../private.json"
        XCTAssertThrowsError(try LawCatalog(laws: [e], generatedAt: "test").validated())
        XCTAssertThrowsError(try LawCatalog(laws: [entry(), entry()], generatedAt: "test").validated())
        let store = LawOfflineStore(root: try root())
        do { _ = try await store.documentURL("../secret", version: "v1"); XCTFail("Traversal accepted") } catch {}
        do { try await store.putDocument(bytes(entry("bgb")), entry: entry(), version: entry().versions[0]); XCTFail("Wrong identity accepted") } catch {}
    }
    func testGuestAdoptionSurvivesRestartWithoutCrossAccountUpload() async throws {
        let url = try root(); let store = LawPersonalStore(root: url)
        let guestID = try await store.put(kind: "bookmark", payload: ["lawId": .string("hgb")], owner: nil)
        try await store.adoptGuests(owner: "A")
        try await store.adoptGuests(owner: "B")
        let restarted = LawPersonalStore(root: url)
        let a = try await restarted.pending(owner: "A"), b = try await restarted.pending(owner: "B")
        XCTAssertEqual(a.map(\.id), [guestID]); XCTAssertTrue(b.isEmpty)
        let owner = try await restarted.lastOwner(); XCTAssertEqual(owner, "B")
    }
    func testLateAcknowledgementCannotLoseOfflineDeletion() async throws {
        let store = LawPersonalStore(root: try root())
        let id = try await store.put(kind: "annotation", payload: [:], owner: "A")
        let firstPending = try await store.pending(owner: "A")
        let sent = try XCTUnwrap(firstPending.first)
        try await store.remove(id: id, owner: "A")
        try await store.acknowledge(sent)
        let pending = try await store.pending(owner: "A")
        XCTAssertEqual(pending.count, 1); XCTAssertTrue(pending[0].deleted)
        let creation = LawSyncChange(seq: 1, kind: "annotation", id: id, payload: ["id": .string(id)], deleted: false)
        try await store.apply(LawSyncPage(changes: [creation], cursor: 1, hasMore: false), owner: "A")
        let still = try await store.items(); XCTAssertTrue(still[0].deleted); XCTAssertTrue(still[0].dirty)
    }
    func testServerTombstonePreventsResurrectionAndCursorIsDurable() async throws {
        let url = try root(); let store = LawPersonalStore(root: url)
        let id = try await store.put(kind: "annotation", payload: [:], owner: "A")
        try await store.apply(LawSyncPage(changes: [LawSyncChange(seq: 4, kind: "annotation", id: id, payload: nil, deleted: true)], cursor: 4, hasMore: false), owner: "A")
        let loaded = LawPersonalStore(root: url)
        let pending = try await loaded.pending(owner: "A"), cursor = try await loaded.cursor(owner: "A")
        XCTAssertTrue(pending.isEmpty); XCTAssertEqual(cursor, 4)
        do { _ = try await loaded.put(kind: "annotation", payload: [:], owner: "A", id: id); XCTFail("Resurrection accepted") } catch {}
        do { try await loaded.apply(LawSyncPage(changes: [], cursor: 3, hasMore: false), owner: "A"); XCTFail("Cursor regressed") } catch {}
    }
    func testFutureCatalogCannotBeReplacedByOlderDownload() async throws {
        let url = try root(), file = url.appendingPathComponent("catalog.json")
        var future = LawCatalog(laws: [entry()], generatedAt: "test"); future.schemaVersion = 99
        let original = try JSONEncoder().encode(future); try original.write(to: file)
        let store = LawOfflineStore(root: url), e = entry()
        try await store.putDocument(bytes(e), entry: e, version: e.versions[0])
        do { try await store.publish(LawCatalog(laws: [e], generatedAt: "older")); XCTFail("Future catalog overwritten") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
    func testFuturePersonalFormatBlocksWritesWithoutChangingBytes() async throws {
        let url = try root(), file = url.appendingPathComponent("personal.json")
        let original = Data("{\"schemaVersion\":999,\"items\":[],\"cursors\":{}}".utf8)
        try original.write(to: file)
        let store = LawPersonalStore(root: url)
        do { _ = try await store.put(kind: "bookmark", payload: [:], owner: nil); XCTFail("Future format overwritten") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
    func testCanonicalTextAndOriginalRangeHandleLigaturesEmojiAndAccents() throws {
        let text = "😀 A\u{0308} ﬃ 𝟙!"
        XCTAssertEqual(LawTextAnchor.canonical(text), "äffi1")
        let source = text as NSString, r = source.range(of: "A\u{0308} ﬃ")
        let a = try XCTUnwrap(LawTextAnchor.anchor(text: text, range: r, sectionID: "s"))
        XCTAssertEqual(a.quote, "äffi"); XCTAssertEqual(a.start, 0)
        XCTAssertEqual(LawTextAnchor.originalRange(text: text, anchor: a), r)
        XCTAssertNil(LawTextAnchor.anchor(text: text, range: NSRange(location: Int.max, length: 1), sectionID: "s"))
    }
    func testMalformedRevisionArchiveDoesNotBrickPersonalStore() async throws {
        let store = LawPersonalStore(root: try root())
        let bad: [String: Any] = ["schemaVersion": 1, "items": [["id": UUID().uuidString, "kind": "bookmark", "payload": [:], "dirty": true, "deleted": false, "revision": Int.max]], "cursors": [:]]
        do { try await store.importData(JSONSerialization.data(withJSONObject: bad)); XCTFail("Overflowing revision accepted") } catch {}
        _ = try await store.put(kind: "bookmark", payload: [:], owner: nil)
        let items = try await store.items(); XCTAssertEqual(items.count, 1)
    }
    func testDeepJSONAndFractionalOffsetsAreRejected() {
        let bytes = Data((String(repeating: "[", count: 80) + "0" + String(repeating: "]", count: 80)).utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(LawJSON.self, from: bytes))
        XCTAssertNil(LawJSON.number(1.5).int)
    }
    func testPersonalArchiveRestoresGuestsAndKeepsExistingDeletion() async throws {
        let store = LawPersonalStore(root: try root()), restored = LawPersonalStore(root: try root())
        let id = try await store.put(kind: "bookmark", payload: [:], owner: nil)
        let data = try await store.exportData(); try await restored.importData(data)
        try await restored.remove(id: id, owner: nil); try await restored.importData(data)
        let items = try await restored.items(); XCTAssertEqual(items.count, 1); XCTAssertTrue(items[0].deleted)
    }
}
