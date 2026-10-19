import XCTest
@testable import NotebookCore

final class LibraryDropLayoutTests: XCTestCase {
    private func row(_ id: UUID, y: Double, folder: Bool = false, opens: Bool = false) -> LibraryDropFrame {
        LibraryDropFrame(id: id, minX: 0, minY: y, maxX: 200, maxY: y + 40, isFolder: folder, opensBelow: opens)
    }
    private func tile(_ id: UUID, x: Double, y: Double, folder: Bool = false) -> LibraryDropFrame {
        LibraryDropFrame(id: id, minX: x, minY: y, maxX: x + 100, maxY: y + 140, isFolder: folder)
    }

    func testListTargetUsesRowHalvesAndFolderQuarters() {
        let (a, f, b) = (UUID(), UUID(), UUID())
        let rows = [row(a, y: 0), row(f, y: 44, folder: true), row(b, y: 88)]
        XCTAssertEqual(LibraryDropLayout.listTarget(y: 5, rows: rows, positional: true), .before(a))
        XCTAssertEqual(LibraryDropLayout.listTarget(y: 30, rows: rows, positional: true), .after(a))
        XCTAssertEqual(LibraryDropLayout.listTarget(y: 46, rows: rows, positional: true), .before(f))
        XCTAssertEqual(LibraryDropLayout.listTarget(y: 64, rows: rows, positional: true), .into(f))
        XCTAssertEqual(LibraryDropLayout.listTarget(y: 82, rows: rows, positional: true), .after(f))
        // Gap between rows and beyond the ends: nearest row.
        XCTAssertEqual(LibraryDropLayout.listTarget(y: 42, rows: rows, positional: true), .after(a))
        XCTAssertEqual(LibraryDropLayout.listTarget(y: 500, rows: rows, positional: true), .after(b))
        XCTAssertEqual(LibraryDropLayout.listTarget(y: -20, rows: rows, positional: true), .before(a))
        // Expanded folder: lower quarter is the start of its contents.
        let open = [row(f, y: 0, folder: true, opens: true)]
        XCTAssertEqual(LibraryDropLayout.listTarget(y: 38, rows: open, positional: true), .intoStart(f))
        // Sorted by name/date: only into folders.
        XCTAssertEqual(LibraryDropLayout.listTarget(y: 46, rows: rows, positional: false), .into(f))
        XCTAssertNil(LibraryDropLayout.listTarget(y: 5, rows: rows, positional: false))
        XCTAssertNil(LibraryDropLayout.listTarget(y: 5, rows: [], positional: true))
    }

    func testGridTargetDistinguishesFolderCenterEdgesAndGaps() {
        let (a, f, b, c) = (UUID(), UUID(), UUID(), UUID())
        // Row 1: a, f (folder), b; row 2: c.
        let tiles = [tile(a, x: 0, y: 0), tile(f, x: 132, y: 0, folder: true), tile(b, x: 264, y: 0), tile(c, x: 0, y: 172)]
        XCTAssertEqual(LibraryDropLayout.gridTarget(x: 10, y: 50, tiles: tiles, positional: true), .before(a))
        XCTAssertEqual(LibraryDropLayout.gridTarget(x: 90, y: 50, tiles: tiles, positional: true), .after(a))
        XCTAssertEqual(LibraryDropLayout.gridTarget(x: 182, y: 50, tiles: tiles, positional: true), .into(f))
        XCTAssertEqual(LibraryDropLayout.gridTarget(x: 140, y: 50, tiles: tiles, positional: true), .before(f))
        XCTAssertEqual(LibraryDropLayout.gridTarget(x: 228, y: 50, tiles: tiles, positional: true), .after(f))
        // Gap between a and f: the closer tile edge in that row.
        XCTAssertEqual(LibraryDropLayout.gridTarget(x: 116, y: 50, tiles: tiles, positional: true), .before(f))
        // Right of the last tile in row 1 / below everything.
        XCTAssertEqual(LibraryDropLayout.gridTarget(x: 390, y: 50, tiles: tiles, positional: true), .after(b))
        XCTAssertEqual(LibraryDropLayout.gridTarget(x: 300, y: 400, tiles: tiles, positional: true), .after(c))
        // Vertical gap between rows picks the nearer row.
        XCTAssertEqual(LibraryDropLayout.gridTarget(x: 10, y: 150, tiles: tiles, positional: true), .before(a))
        XCTAssertEqual(LibraryDropLayout.gridTarget(x: 10, y: 166, tiles: tiles, positional: true), .before(c))
        // Without manual order only folders accept drops, on their whole tile.
        XCTAssertEqual(LibraryDropLayout.gridTarget(x: 140, y: 50, tiles: tiles, positional: false), .into(f))
        XCTAssertNil(LibraryDropLayout.gridTarget(x: 10, y: 50, tiles: tiles, positional: false))
        XCTAssertNil(LibraryDropLayout.gridTarget(x: 116, y: 50, tiles: tiles, positional: false))
    }

    private func snapshot() -> (LibrarySnapshot, a: UUID, b: UUID, c: UUID, folder: UUID, inner: UUID, child: UUID) {
        var value = LibrarySnapshot()
        let folder = LibraryItem(title: "Ordner")
        let inner = LibraryItem(title: "Innen", parentID: folder.id)
        let child = LibraryItem(title: "Kind", parentID: folder.id, source: .library)
        let a = LibraryItem(title: "A", source: .library), b = LibraryItem(title: "B", source: .library)
        let c = LibraryItem(title: "C", source: .library)
        value.items = [a, folder, b, inner, child, c]
        return (value, a.id, b.id, c.id, folder.id, inner.id, child.id)
    }

    func testPlacementResolvesNeighboursAndRejectsNoOpsAndCycles() {
        let (value, a, b, c, folder, inner, child) = snapshot()
        // Top level order: a, folder, b, c.
        XCTAssertEqual(value.placement(of: c, at: .before(a)), LibraryPlacement(parentID: nil, beforeID: a))
        XCTAssertEqual(value.placement(of: a, at: .after(b)), LibraryPlacement(parentID: nil, beforeID: c))
        XCTAssertEqual(value.placement(of: a, at: .after(c)), LibraryPlacement(parentID: nil, beforeID: nil))
        XCTAssertEqual(value.placement(of: c, at: .after(child)), LibraryPlacement(parentID: folder, beforeID: nil))
        XCTAssertEqual(value.placement(of: c, at: .intoStart(folder)), LibraryPlacement(parentID: folder, beforeID: inner))
        XCTAssertEqual(value.placement(of: a, at: .into(folder)), LibraryPlacement(parentID: folder, beforeID: nil))
        XCTAssertEqual(value.placement(of: child, at: .into(nil)), LibraryPlacement(parentID: nil, beforeID: nil))
        // No-ops: same place, own folder, itself.
        XCTAssertNil(value.placement(of: a, at: .before(folder)))
        XCTAssertNil(value.placement(of: b, at: .after(folder)))
        XCTAssertNil(value.placement(of: c, at: .after(b)))
        XCTAssertNil(value.placement(of: child, at: .into(folder)))
        XCTAssertNil(value.placement(of: a, at: .into(nil)))
        XCTAssertNil(value.placement(of: a, at: .before(a)))
        XCTAssertNil(value.placement(of: inner, at: .intoStart(folder)))
        // Cycles and non-folder targets.
        XCTAssertNil(value.placement(of: folder, at: .into(inner)))
        XCTAssertNil(value.placement(of: folder, at: .before(child)))
        XCTAssertNil(value.placement(of: folder, at: .into(folder)))
        XCTAssertNil(value.placement(of: a, at: .into(b)))
        XCTAssertNil(value.placement(of: UUID(), at: .into(nil)))
    }

    func testPlacementIgnoresTrashedEntries() {
        let fixture = snapshot()
        var value = fixture.0
        let (a, b, c, folder) = (fixture.a, fixture.b, fixture.c, fixture.folder)
        let index = value.items.firstIndex { $0.id == c }!
        value.items[index].deletedAt = Date()
        XCTAssertEqual(value.placement(of: a, at: .after(b)), LibraryPlacement(parentID: nil, beforeID: nil))
        XCTAssertNil(value.placement(of: c, at: .into(folder)))
        XCTAssertNil(value.placement(of: a, at: .before(c)))
    }

    func testPlacementMatchesStorePlace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noty-drop-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root); _ = try await store.load()
        let a = try await store.createFolder(title: "A", parentID: nil).items[0].id
        let b = try await store.createFolder(title: "B", parentID: nil).items[1].id
        var value = try await store.createFolder(title: "C", parentID: nil)
        let c = value.items[2].id
        for (id, target, expected) in [(c, LibraryDropTarget.before(a), [c, a, b]), (c, .after(a), [a, c, b]), (a, .after(b), [c, b, a])] {
            let placement = try XCTUnwrap(value.placement(of: id, at: target))
            value = try await store.place(id, in: placement.parentID, before: placement.beforeID)
            XCTAssertEqual(value.children(of: nil).map(\.id), expected)
        }
        let placement = try XCTUnwrap(value.placement(of: c, at: .into(b)))
        value = try await store.place(c, in: placement.parentID, before: placement.beforeID)
        XCTAssertEqual(value.children(of: b).map(\.id), [c])
        let fresh = try await LibraryStore(root: root).load()
        XCTAssertEqual(fresh.snapshot, value)
    }

    func testPinOrderArrangesAndPlacesByStableIDs() {
        let items = (0..<4).map { LibraryItem(title: "P\($0)", source: .library) }
        let ids = items.map(\.id)
        // Unknown and missing IDs: stored ones first, others in index order.
        XCTAssertEqual(LibraryPinOrder.arrange(items, order: [ids[2], UUID(), ids[0]]).map(\.id), [ids[2], ids[0], ids[1], ids[3]])
        XCTAssertEqual(LibraryPinOrder.arrange(items, order: []).map(\.id), ids)
        XCTAssertEqual(LibraryPinOrder.placing(ids[3], before: ids[1], in: ids), [ids[0], ids[3], ids[1], ids[2]])
        XCTAssertEqual(LibraryPinOrder.placing(ids[0], before: nil, in: ids), [ids[1], ids[2], ids[3], ids[0]])
        let fresh = UUID()
        XCTAssertEqual(LibraryPinOrder.placing(fresh, at: .after(ids[0]), in: ids), [ids[0], fresh, ids[1], ids[2], ids[3]])
        XCTAssertEqual(LibraryPinOrder.placing(ids[0], at: .after(ids[2]), in: ids), [ids[1], ids[2], ids[0], ids[3]])
        XCTAssertEqual(LibraryPinOrder.placing(ids[0], at: .after(ids[3]), in: ids), [ids[1], ids[2], ids[3], ids[0]])
        XCTAssertNil(LibraryPinOrder.placing(ids[0], at: .before(ids[0]), in: ids))
        XCTAssertNil(LibraryPinOrder.placing(ids[0], at: .into(ids[1]), in: ids))
    }
}
