import Foundation
import NotebookCore

// Markier-Hilfen im Modell (Paket A2, docs/LAW-REWORK.md). Alle Änderungen an
// Markierungen laufen durch genau eine Stelle: `commit(plan:)`. Heute ruft sie
// die bestehenden Einzeloperationen `save`/`remove` auf; die atomare
// Mehrfachoperation des Daten-Pakets (A1, `batch(puts, removes)`) ersetzt nur
// den Rumpf dieser Funktion.

/// A new personal item of a mark plan (an ID is assigned when stored).
struct LawMarkAddition: Equatable {
    var kind = "annotation"
    var payload: [String: LawJSON]
}

/// App-level plan: what to create and what to delete, in one undo step.
/// Creations go first (contract: send new entries before deletions).
struct LawMarkChange: Equatable {
    var removals: [LawPersonalItem] = []
    var additions: [LawMarkAddition] = []
    var isEmpty: Bool { removals.isEmpty && additions.isEmpty }
}

/// What `commit` actually changed; enough to undo it with new IDs.
struct LawMarkApplied: Equatable {
    var removed: [LawPersonalItem]
    var created: [String]
}

extension LawLibraryModel {
    /// Applies `plan` as one step. Returns what was written (nil if nothing
    /// could be written; the model shows the error).
    ///
    /// Interim implementation on `save`/`remove`: each call commits and syncs
    /// on its own. To be replaced by A1's atomic batch (one store commit, one
    /// sync, IDs chosen here).
    func commit(plan: LawMarkChange) async -> LawMarkApplied? {
        guard !plan.isEmpty else { return nil }
        var created: [String] = []
        for addition in plan.additions {
            let before = Set(items.map(\.id))
            await save(kind: addition.kind, payload: addition.payload)
            // `save` assigns the ID; find the entry it just stored.
            if let item = storedEntry(for: addition, notIn: before) { created.append(item.id) }
        }
        guard created.count == plan.additions.count else {
            // Nothing is deleted when a creation failed: the old marks stay.
            return created.isEmpty ? nil : LawMarkApplied(removed: [], created: created)
        }
        var removed: [LawPersonalItem] = []
        for item in plan.removals {
            guard let current = items.first(where: { $0.id == item.id && $0.owner == item.owner }), !current.deleted else { continue }
            await remove(current)
            if items.first(where: { $0.id == item.id && $0.owner == item.owner })?.deleted ?? true { removed.append(current) }
        }
        return LawMarkApplied(removed: removed, created: created)
    }

    /// The entry `save` just stored for `addition`. The sync inside `save` may
    /// already have replaced the payload by the server's answer (extra fields,
    /// colour kept locally), so the identifying fields decide.
    private func storedEntry(for addition: LawMarkAddition, notIn before: Set<String>) -> LawPersonalItem? {
        let fresh = items.filter { !before.contains($0.id) && $0.kind == addition.kind && !$0.deleted }
        if let exact = fresh.first(where: { Self.samePayload($0.payload, addition.payload) }) { return exact }
        let keys = ["lawId", "versionId", "kind", "page", "anchor", "sectionId", "view", "color"]
        return fresh.first { item in keys.allSatisfy { item.payload[$0] == addition.payload[$0] } }
    }
    static func samePayload(_ a: [String: LawJSON], _ b: [String: LawJSON]) -> Bool {
        var a = a, b = b
        a["id"] = nil; b["id"] = nil
        return a == b
    }

    /// Live (not deleted) annotations of one law version.
    func annotations(law: String, version: String) -> [LawPersonalItem] {
        items.filter { !$0.deleted && $0.kind == "annotation" && $0.payload["lawId"]?.string == law && $0.payload["versionId"]?.string == version }
    }
    func liveItem(_ id: String) -> LawPersonalItem? { items.first { $0.id == id && !$0.deleted } }

    /// Text marks of `section` in canonical offsets. PDF marks with a text
    /// anchor take part as fixed ranges; invalid anchors are left out.
    func markRanges(in section: LawSection, of marks: [LawPersonalItem]) -> [LawMarkRange] {
        let canonical = LawTextAnchor.canonical(section.text) as NSString
        return marks.compactMap { item in
            guard let anchor = item.textAnchor, anchor.sectionId == section.id, anchor.start >= 0, anchor.end > anchor.start, anchor.end <= canonical.length,
                  canonical.substring(with: NSRange(location: anchor.start, length: anchor.end - anchor.start)) == anchor.quote else { return nil }
            return LawMarkRange(id: item.id, sectionId: section.id, start: anchor.start, end: anchor.end, color: item.payload["color"]?.string, fixed: item.payload["kind"]?.string != "text")
        }
    }

    /// Turns a canonical plan into items: deletions are the stored entries,
    /// additions text annotations with base payload, anchor and colour.
    func change(for plan: LawMarkPlan, section: LawSection, document: LawDocument) -> LawMarkChange {
        let canonical = LawTextAnchor.canonical(section.text)
        var change = LawMarkChange()
        change.removals = plan.deletions.compactMap { liveItem($0.id) }
        for range in plan.additions {
            if range.fixed, let source = plan.deletions.first(where: { $0.fixed && $0.start == range.start && $0.end == range.end }).flatMap({ liveItem($0.id) }) {
                // Recoloured PDF mark: same entry, new colour, new ID.
                var payload = source.payload
                payload["id"] = nil
                payload["color"] = range.color.map(LawJSON.string)
                change.additions.append(LawMarkAddition(kind: source.kind, payload: payload))
                continue
            }
            guard let anchor = LawMarkEditing.anchor(for: range, canonical: canonical), let value = anchor.json else { continue }
            var payload: [String: LawJSON] = ["lawId": .string(document.id), "versionId": .string(document.version), "kind": .string("text"), "page": .number(0), "anchor": value]
            if let color = range.color { payload["color"] = .string(color) }
            change.additions.append(LawMarkAddition(payload: payload))
        }
        return change
    }
}

extension LawPersonalItem {
    var textAnchor: LawAnchor? {
        guard case let .object(a) = payload["anchor"], let section = a["sectionId"]?.string,
              let start = a["start"]?.int, let end = a["end"]?.int, let quote = a["quote"]?.string else { return nil }
        return LawAnchor(sectionId: section, start: start, end: end, quote: quote)
    }
    /// The payload to recreate this entry with a new ID (undo).
    var recreation: LawMarkAddition {
        var payload = self.payload
        payload["id"] = nil
        return LawMarkAddition(kind: kind, payload: payload)
    }
}

extension LawAnchor {
    var json: LawJSON? {
        .object(["sectionId": .string(sectionId), "start": .number(Double(start)), "end": .number(Double(end)), "quote": .string(quote)])
    }
}

extension LawPDFRect {
    var json: LawJSON { .object(["x": .number(x), "y": .number(y), "width": .number(width), "height": .number(height)]) }
    init?(json: LawJSON) {
        guard case let .object(r) = json, case let .number(x) = r["x"], case let .number(y) = r["y"],
              case let .number(w) = r["width"], case let .number(h) = r["height"] else { return nil }
        self.init(x: x, y: y, width: w, height: h)
    }
}
