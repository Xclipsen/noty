import XCTest
@testable import NotebookCore

/// Gesetzes-Überarbeitung, Paket Daten/Abgleich (docs/LAW-REWORK.md B1, B9, B10, B12, B16).
final class LawPersonalSyncTests: XCTestCase, @unchecked Sendable {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("noty-law-sync-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private final class Clock: @unchecked Sendable {
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        func advance(days: Double) { date += days * 86_400 }
    }
    private func id() -> String { UUID().uuidString.lowercased() }
    private func text(_ law: String = "hgb", _ version: String = "v1") -> [String: LawJSON] {
        ["lawId": .string(law), "versionId": .string(version), "kind": .string("text"), "page": .number(0)]
    }
    private func item(_ id: String, owner: String?, revision: Int, deleted: Bool = false, dirty: Bool = true, payload: [String: LawJSON] = [:]) -> [String: Any] {
        var p: [String: Any] = ["id": id]
        for (k, v) in payload { if case let .string(s) = v { p[k] = s } }
        var result: [String: Any] = ["id": id, "kind": "annotation", "payload": p, "deleted": deleted, "dirty": dirty, "revision": revision]
        if let owner { result["owner"] = owner }
        return result
    }

    // MARK: B1 Duplikate

    func testRestoreAfterGuestAdoptionAddsNoDuplicateAndStoreStaysUsable() async throws {
        let url = try root(); let store = LawPersonalStore(root: url)
        let guest = try await store.put(kind: "annotation", payload: text(), owner: nil)
        let backup = try await store.exportData()
        try await store.adoptGuests(owner: "A")
        try await store.importData(backup)
        try await store.adoptGuests(owner: "A")
        let items = try await store.items()
        XCTAssertEqual(items.map(\.id), [guest]); XCTAssertEqual(items[0].owner, "A")
        // Before B1 the next launch refused the whole store.
        let reloaded = try await LawPersonalStore(root: url).items()
        XCTAssertEqual(reloaded.count, 1)
    }
    func testRestoreSkipsEntryOfAnotherOwnerAndDeletedOne() async throws {
        let store = LawPersonalStore(root: try root()), other = LawPersonalStore(root: try root())
        let a = try await other.put(kind: "annotation", payload: text(), owner: nil)
        let b = try await other.put(kind: "annotation", payload: text(), owner: nil)
        let archive = try await other.exportData()
        try await store.importData(archive)
        try await store.adoptGuests(owner: "A")
        try await store.remove(id: b, owner: "A")
        try await store.importData(archive)
        let items = try await store.items()
        XCTAssertEqual(items.map(\.id), [a, b]); XCTAssertTrue(items[1].deleted)
        XCTAssertEqual(Set(items.map(\.owner)), ["A"])
    }
    func testDuplicatesInStoredFileAreMergedAfterExactBackupInsteadOfLocking() async throws {
        let url = try root(), file = url.appendingPathComponent("personal.json")
        let x = id(), y = id(), z = id()
        let state: [String: Any] = ["schemaVersion": 1, "cursors": ["A": 7], "items": [
            item(x, owner: "A", revision: 2, dirty: false, payload: ["color": .string("#FF0000")]),
            item(x, owner: nil, revision: 5, payload: ["lawId": .string("hgb")]),
            item(y, owner: "A", revision: 4, deleted: true, dirty: false),
            item(y, owner: "A", revision: 6),
            item(z, owner: "A", revision: 1)]]
        let original = try JSONSerialization.data(withJSONObject: state)
        try original.write(to: file)
        let clock = Clock()
        let store = LawPersonalStore(root: url, now: { clock.date })
        let items = try await store.items()
        XCTAssertEqual(items.map(\.id), [x, y, z])
        // Highest revision wins, the local colour of the loser is kept.
        XCTAssertNil(items[0].owner); XCTAssertEqual(items[0].revision, 5)
        XCTAssertEqual(items[0].payload["lawId"], .string("hgb")); XCTAssertEqual(items[0].payload["color"], .string("#FF0000"))
        // A confirmed deletion of any copy survives a higher live revision.
        XCTAssertTrue(items[1].deleted); XCTAssertFalse(items[1].dirty); XCTAssertEqual(items[1].revision, 6)
        let report = try await store.takeRepairReport()
        let repair = try XCTUnwrap(report)
        XCTAssertEqual(repair.merged, 2)
        XCTAssertEqual(repair.backup.lastPathComponent, "personal.json.before-repair-20270115T080000Z")
        XCTAssertEqual(try Data(contentsOf: repair.backup), original)
        let again = try await store.takeRepairReport(); XCTAssertNil(again)
        let cursor = try await LawPersonalStore(root: url).cursor(owner: "A"); XCTAssertEqual(cursor, 7)
        let reloaded = try await LawPersonalStore(root: url).items(); XCTAssertEqual(reloaded, items)
    }
    func testFutureSchemaWithDuplicatesStaysLockedAndUntouched() async throws {
        let url = try root(), file = url.appendingPathComponent("personal.json")
        let x = id()
        let original = try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "cursors": [:], "items": [item(x, owner: "A", revision: 1), item(x, owner: nil, revision: 1)]] as [String: Any])
        try original.write(to: file)
        let store = LawPersonalStore(root: url)
        do { _ = try await store.items(); XCTFail("Future schema accepted") } catch {}
        do { _ = try await store.put(kind: "bookmark", payload: [:], owner: nil); XCTFail("Future schema written") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.path), ["personal.json"])
    }
    func testIDsAreUniqueAcrossOwners() async throws {
        let store = LawPersonalStore(root: try root())
        let x = try await store.put(kind: "annotation", payload: text(), owner: "A")
        do { _ = try await store.put(kind: "annotation", payload: text(), owner: nil, id: x); XCTFail("Second owner of one ID") } catch {}
        // A pulled change for an ID held by the guest neither duplicates nor touches it.
        let g = try await store.put(kind: "annotation", payload: text(), owner: nil)
        try await store.apply(LawSyncPage(changes: [LawSyncChange(seq: 1, kind: "annotation", id: g, payload: ["id": .string(g)], deleted: false)], cursor: 1, hasMore: false), owner: "B")
        let items = try await store.items()
        XCTAssertEqual(items.count, 2); XCTAssertNil(items[1].owner)
    }

    // MARK: B16 Gebündeltes Schreiben

    func testBatchIsOneAtomicWrite() async throws {
        let url = try root(); let store = LawPersonalStore(root: url)
        let old = try await store.put(kind: "annotation", payload: text(), owner: "A")
        let before = await store.writes
        let ids = try await store.batch(puts: [LawPersonalChange(kind: "annotation", payload: text()), LawPersonalChange(kind: "annotation", payload: text()), LawPersonalChange(kind: "bookmark", payload: text())],
                                        removes: [LawPersonalRef(kind: "annotation", id: old)], owner: "A")
        let after = await store.writes
        XCTAssertEqual(after - before, 1); XCTAssertEqual(ids.count, 3)
        let items = try await store.items()
        XCTAssertEqual(items.count, 4); XCTAssertTrue(items[0].deleted)
        // One bad put rejects the whole batch: nothing changes, nothing is written.
        let bytes = try Data(contentsOf: url.appendingPathComponent("personal.json"))
        do {
            try await store.batch(puts: [LawPersonalChange(kind: "annotation", payload: text()), LawPersonalChange(kind: "annotation", payload: text(), id: old)], removes: [LawPersonalRef(kind: "annotation", id: ids[0])], owner: "A")
            XCTFail("Resurrection in a batch accepted")
        } catch {}
        do { try await store.batch(puts: [LawPersonalChange(kind: "note", payload: [:])], owner: "A"); XCTFail("Unknown kind accepted") } catch {}
        let unchanged = try await store.items()
        XCTAssertEqual(unchanged, items)
        XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent("personal.json")), bytes)
        let writes = await store.writes; XCTAssertEqual(writes, after)
        // Nothing to change: no write.
        try await store.batch(puts: [], removes: [LawPersonalRef(kind: "annotation", id: old)], owner: "A")
        let idle = await store.writes; XCTAssertEqual(idle, after)
    }
    func testFailedWriteKeepsPriorStateInMemoryAndOnDisk() async throws {
        let url = try root(), file = url.appendingPathComponent("personal.json")
        let store = LawPersonalStore(root: url)
        let x = try await store.put(kind: "annotation", payload: text(), owner: "A")
        let prior = try await store.items()
        // Replace the file by a directory: the atomic rename must fail.
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        do { try await store.batch(puts: [LawPersonalChange(kind: "annotation", payload: text())], removes: [LawPersonalRef(kind: "annotation", id: x)], owner: "A"); XCTFail("Write into a directory succeeded") } catch {}
        let after = try await store.items()
        XCTAssertEqual(after, prior)
    }
    func testPushAnswersAreOneWriteAndCreationsGoFirst() async throws {
        let store = LawPersonalStore(root: try root())
        let a = try await store.put(kind: "annotation", payload: text(), owner: "A")
        let b = try await store.put(kind: "annotation", payload: text(), owner: "A")
        try await store.batch(puts: [LawPersonalChange(kind: "annotation", payload: text())], removes: [LawPersonalRef(kind: "annotation", id: a)], owner: "A")
        let pending = try await store.pending(owner: "A")
        XCTAssertEqual(pending.map(\.deleted), [false, false, true])
        XCTAssertEqual(pending.last?.id, a); XCTAssertEqual(pending.first?.id, b)
        let before = await store.writes
        try await store.record(pending.map { LawPushReceipt(sent: $0, outcome: .accepted($0.deleted ? nil : ["id": .string($0.id), "createdAt": .number(1)])) })
        let after = await store.writes
        XCTAssertEqual(after - before, 1)
        let left = try await store.pending(owner: "A"); XCTAssertTrue(left.isEmpty)
        // An empty pull page that does not move the cursor writes nothing.
        try await store.apply(LawSyncPage(changes: [], cursor: 0, hasMore: false), owner: "A")
        let idle = await store.writes; XCTAssertEqual(idle, after)
    }
    func testConfirmedTombstonesArePrunedAfterThirtyDaysWithoutResurrection() async throws {
        let url = try root(), clock = Clock()
        let store = LawPersonalStore(root: url, now: { clock.date })
        let synced = try await store.put(kind: "annotation", payload: text(), owner: "A")
        let unsent = try await store.put(kind: "annotation", payload: text(), owner: "A")
        let guest = try await store.put(kind: "annotation", payload: text(), owner: nil)
        let archive = try await store.exportData()
        try await store.remove(id: synced, owner: "A"); try await store.remove(id: unsent, owner: "A"); try await store.remove(id: guest, owner: nil)
        let queued = try await store.pending(owner: "A")
        let deletion = try XCTUnwrap(queued.first { $0.id == synced })
        try await store.acknowledge(deletion)
        clock.advance(days: 29)
        var pruned = try await store.pruneTombstones(); XCTAssertEqual(pruned, 0)
        clock.advance(days: 2)
        pruned = try await store.pruneTombstones(); XCTAssertEqual(pruned, 2)
        let reloaded = LawPersonalStore(root: url, now: { clock.date })
        let left = try await reloaded.items()
        // An unconfirmed deletion is still to be sent; it stays.
        XCTAssertEqual(left.map(\.id), [unsent]); XCTAssertTrue(left[0].deleted)
        do { _ = try await reloaded.put(kind: "annotation", payload: text(), owner: "A", id: synced); XCTFail("Pruned ID re-created") } catch {}
        try await reloaded.importData(archive)
        try await reloaded.apply(LawSyncPage(changes: [LawSyncChange(seq: 1, kind: "annotation", id: synced, payload: ["id": .string(synced)], deleted: false)], cursor: 1, hasMore: false), owner: "A")
        let after = try await reloaded.items()
        XCTAssertEqual(after.map(\.id), [unsent])
        // The pruned keys travel with an archive.
        let fresh = LawPersonalStore(root: try root())
        let exported = try await reloaded.exportData()
        try await fresh.importData(exported); try await fresh.importData(archive)
        let restored = try await fresh.items()
        XCTAssertEqual(restored.map(\.id), [unsent])
    }
    func testTombstoneWithoutDateStartsTheClock() async throws {
        let url = try root(), clock = Clock()
        let x = id()
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "cursors": [:], "items": [item(x, owner: "A", revision: 3, deleted: true, dirty: false)]] as [String: Any])
            .write(to: url.appendingPathComponent("personal.json"))
        let store = LawPersonalStore(root: url, now: { clock.date })
        var pruned = try await store.pruneTombstones(); XCTAssertEqual(pruned, 0)
        clock.advance(days: 31)
        pruned = try await store.pruneTombstones(); XCTAssertEqual(pruned, 1)
    }

    // MARK: B9 Abgelehnte Einträge und Status

    func testPermanentRefusalIsMarkedRetriedOrKeptLocal() async throws {
        let store = LawPersonalStore(root: try root())
        let x = try await store.put(kind: "annotation", payload: text(), owner: "A")
        let y = try await store.put(kind: "annotation", payload: text(), owner: "A")
        let sent = try await store.pending(owner: "A")
        try await store.record([LawPushReceipt(sent: sent[0], outcome: .rejected(status: 400, message: "Die Textstelle passt nicht.")),
                                LawPushReceipt(sent: sent[1], outcome: .rejected(status: 413, message: "Zu groß"))])
        var items = try await store.items()
        XCTAssertEqual(items.filter(\.isRejected).map(\.id), [x, y]); XCTAssertEqual(items[0].rejection?.status, 400)
        var pending = try await store.pending(owner: "A"); XCTAssertTrue(pending.isEmpty)
        try await store.retry([LawPersonalRef(kind: "annotation", id: x)], owner: "A")
        try await store.keepLocal([LawPersonalRef(kind: "annotation", id: y)], owner: "A")
        pending = try await store.pending(owner: "A"); XCTAssertEqual(pending.map(\.id), [x])
        items = try await store.items()
        XCTAssertFalse(items[1].isRejected); XCTAssertTrue(items[1].isKeptLocal); XCTAssertFalse(items[1].deleted)
        // Another account cannot resolve them.
        try await store.retry(nil, owner: "B")
        let still = try await store.pending(owner: "A"); XCTAssertEqual(still.map(\.id), [x])
        // Removing a kept-local entry never sends a deletion.
        try await store.remove(id: y, owner: "A")
        pending = try await store.pending(owner: "A"); XCTAssertEqual(pending.map(\.id), [x])
    }
    func testDeletedOnServerWinsAndLateRefusalDoesNotHideNewerEdit() async throws {
        let store = LawPersonalStore(root: try root())
        let x = try await store.put(kind: "bookmark", payload: text(), owner: "A")
        let sent = try await store.pending(owner: "A")
        try await store.record([LawPushReceipt(sent: sent[0], outcome: .deletedOnServer)])
        let items = try await store.items()
        XCTAssertTrue(items[0].deleted); XCTAssertFalse(items[0].dirty)
        do { _ = try await store.put(kind: "bookmark", payload: text(), owner: "A", id: x); XCTFail("Server deletion undone") } catch {}
        let y = try await store.put(kind: "annotation", payload: text(), owner: "A")
        let queue = try await store.pending(owner: "A")
        let old = try XCTUnwrap(queue.first)
        _ = try await store.put(kind: "annotation", payload: text("bgb"), owner: "A", id: y)
        try await store.record([LawPushReceipt(sent: old, outcome: .rejected(status: 400, message: "alt"))])
        let pending = try await store.pending(owner: "A"); XCTAssertEqual(pending.map(\.id), [y])
    }
    func testPermanentStatusesAndGate() {
        XCTAssertTrue(LawPushFailures.isPermanent(status: 400, code: nil))
        XCTAssertTrue(LawPushFailures.isPermanent(status: 409, code: nil))
        XCTAssertTrue(LawPushFailures.isPermanent(status: 413, code: nil))
        XCTAssertFalse(LawPushFailures.isPermanent(status: 409, code: "deleted"))
        for status in [401, 404, 408, 422, 429, 500, 503] { XCTAssertFalse(LawPushFailures.isPermanent(status: status, code: nil), "\(status)") }
        var gate = LawSyncGate()
        XCTAssertTrue(gate.request()); XCTAssertFalse(gate.request()); XCTAssertFalse(gate.request())
        XCTAssertTrue(gate.finish(), "A request during the run makes it go once more")
        XCTAssertFalse(gate.finish()); XCTAssertFalse(gate.running)
        XCTAssertTrue(gate.request()); gate.stop(); XCTAssertTrue(gate.request())
    }
    func testStatusIsSynchronisedOnlyWithEmptyOutbox() {
        func status(pending: Int = 0, rejected: Int = 0, running: Bool = false, error: String? = nil, signedIn: Bool = true, expired: Bool = false, sync: Bool = true, last: Date? = Date(timeIntervalSince1970: 0)) -> LawSyncStatus {
            .derive(signedIn: signedIn, sessionExpired: expired, enabled: true, syncEnabled: sync, running: running, pending: pending, rejected: rejected, lastError: error, lastSynced: last)
        }
        let time: (Date) -> String = { _ in "12:00" }
        XCTAssertEqual(status().state, .synced); XCTAssertEqual(status().text(time: time), "Synchronisiert · 12:00")
        XCTAssertEqual(status(pending: 2).state, .pending); XCTAssertEqual(status(pending: 2).text(time: time), "2 Änderungen ausstehend")
        XCTAssertEqual(status(rejected: 1).state, .rejected); XCTAssertEqual(status(rejected: 1).text(time: time), "1 Eintrag abgelehnt")
        XCTAssertEqual(status(pending: 1, rejected: 3).text(time: time), "1 Änderung ausstehend · 3 Einträge abgelehnt")
        XCTAssertEqual(status(pending: 1, running: true).state, .syncing)
        XCTAssertEqual(status(pending: 1, error: "Offline").state, .failed("Offline"))
        XCTAssertTrue(status(pending: 1, error: "Offline").text(time: time).hasSuffix("· 1 Änderung ausstehend"))
        XCTAssertEqual(status(last: nil).state, .pending, "Never synchronised is not „Synchronisiert“")
        XCTAssertEqual(status(signedIn: false).state, .guest); XCTAssertEqual(status(signedIn: false, last: nil).text(time: time), "Nur auf diesem iPad")
        XCTAssertEqual(status(expired: true).state, .expired); XCTAssertEqual(status(sync: false).state, .paused)
        XCTAssertTrue(status(signedIn: false).isLocalOnly); XCTAssertFalse(status(pending: 1).isSynced)
    }

    // MARK: B12 Eigentümer

    func testVisibilityAndRemovalFollowTheOwner() async throws {
        let store = LawPersonalStore(root: try root())
        let a = try await store.put(kind: "annotation", payload: text(), owner: "A")
        let g = try await store.put(kind: "annotation", payload: text(), owner: nil)
        try await store.remove(id: a, owner: nil)
        try await store.batch(puts: [], removes: [LawPersonalRef(kind: "annotation", id: a)], owner: "B")
        let items = try await store.items()
        XCTAssertFalse(items[0].deleted, "Not deleted by another owner")
        XCTAssertEqual(items.visible(to: "A").map(\.id), [a])
        XCTAssertEqual(items.visible(to: nil).map(\.id), [g])
        XCTAssertTrue(items.visible(to: "B").isEmpty)
        // The guest's pending entries are never sent for an account.
        let pendingB = try await store.pending(owner: "B"); XCTAssertTrue(pendingB.isEmpty)
    }

    // MARK: B10 Fassungen und Lesestelle

    func testMarkCountsPerVersionInCatalogueOrder() {
        func mark(_ law: String, _ version: String, owner: String? = "A", deleted: Bool = false, kind: String = "annotation") -> LawPersonalItem {
            LawPersonalItem(id: id(), owner: owner, kind: kind, payload: text(law, version), deleted: deleted, dirty: false, revision: 1)
        }
        let items = [mark("hgb", "v2"), mark("hgb", "v1"), mark("hgb", "v1"), mark("hgb", "v1", deleted: true), mark("hgb", "v0", owner: "B"),
                     mark("hgb", "zz"), mark("bgb", "v1"), mark("hgb", "v1", kind: "bookmark")]
        XCTAssertEqual(items.visible(to: "A").markCounts(law: "hgb", versionOrder: ["v1", "v2", "v3"]),
                       [LawVersionMarkCount(versionId: "v1", count: 2), LawVersionMarkCount(versionId: "v2", count: 1), LawVersionMarkCount(versionId: "zz", count: 1)])
        XCTAssertEqual(items.visible(to: "B").markCounts(law: "hgb"), [LawVersionMarkCount(versionId: "v0", count: 1)])
    }
    func testReadingSpotRemembersVersionViewPageAndOffsetAndReadsLegacyKeys() throws {
        var spots = LawReadingSpots.decode(nil, legacySections: ["hgb": "s144", "bad/../x": "s1"], legacyLast: "hgb")
        XCTAssertEqual(spots.spot(law: "hgb"), LawReadingSpot(lawId: "hgb", sectionId: "s144"))
        XCTAssertNil(spots.spot(law: "bad/../x")); XCTAssertEqual(spots.last?.lawId, "hgb")
        let pdf = LawReadingSpot(lawId: "bgb", versionId: "2026-01", view: .pdf, sectionId: "s1", pdfPage: 12, offset: 0.4)
        XCTAssertTrue(spots.remember(pdf)); XCTAssertFalse(spots.remember(pdf))
        XCTAssertFalse(spots.remember(LawReadingSpot(lawId: "bgb", offset: .nan)))
        XCTAssertFalse(spots.remember(LawReadingSpot(lawId: "bgb", view: .pdf, pdfPage: 0)))
        let data = try JSONEncoder().encode(spots)
        // New data wins over the legacy section of the same law.
        let loaded = LawReadingSpots.decode(data, legacySections: ["bgb": "s9", "estg": "s2"], legacyLast: "estg")
        XCTAssertEqual(loaded.spot(law: "bgb"), pdf); XCTAssertEqual(loaded.last, pdf)
        XCTAssertEqual(loaded.spot(law: "estg")?.sectionId, "s2")
        XCTAssertEqual(LawReadingSpots.decode(Data("{\"spots\":{\"hgb\":{\"lawId\":\"bgb\",\"view\":\"text\"}}}".utf8)).spots.count, 0, "A spot under another law's key is dropped")
    }
}
