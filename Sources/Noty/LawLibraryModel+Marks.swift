import Foundation
import NotebookCore

// Markier-Hilfen im Modell (Paket A2, docs/LAW-REWORK.md). Alle Änderungen an
// Markierungen laufen durch genau eine Stelle: `commit(plan:)`, die einen Plan
// als einen atomaren Schreibvorgang des Daten-Pakets schreibt
// (`LawLibraryModel.commit(puts:removes:)`, Store `batch`).

/// A new personal item of a mark plan. The ID is chosen here (the caller),
/// never looked up afterwards: deleted IDs stay blocked on the server, so
/// every creation, also undo and recolouring, gets a fresh UUID.
struct LawMarkAddition: Equatable {
    var kind = "annotation"
    var payload: [String: LawJSON]
    var id = LawMarkEditing.newID()
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
    /// Applies `plan` as one step: one store write, one sync afterwards, no
    /// intermediate state. Returns what was written, nil when nothing could
    /// be written (the model shows the error and the old marks stay complete).
    func commit(plan: LawMarkChange) async -> LawMarkApplied? {
        guard !plan.isEmpty else { return nil }
        // Only live entries of the current owner can be removed (`items`).
        let removed = plan.removals.compactMap { item in items.first { $0.id == item.id && $0.kind == item.kind } }
        let puts = plan.additions.map { LawPersonalChange(kind: $0.kind, payload: $0.payload, id: $0.id) }
        guard !puts.isEmpty || !removed.isEmpty else { return nil }
        guard await commit(puts: puts, removes: removed.map(\.ref)) else { return nil }
        return LawMarkApplied(removed: removed, created: plan.additions.map(\.id))
    }

    /// The current owner's live annotations of one law version.
    func annotations(law: String, version: String) -> [LawPersonalItem] {
        visibleItems(kind: "annotation", law: law, version: version)
    }
    func liveItem(_ id: String) -> LawPersonalItem? { items.first { $0.id == id && !$0.deleted } }

    /// Text marks of `section` in canonical offsets. PDF marks with a text
    /// anchor take part as fixed ranges; invalid anchors are left out.
    func markRanges(in section: LawSection, of marks: [LawPersonalItem]) -> [LawMarkRange] {
        let canonical = LawTextAnchor.canonical(section.text) as NSString
        return marks.compactMap { item in
            guard let anchor = item.textAnchor, anchor.sectionId == section.id, anchor.start >= 0, anchor.end > anchor.start, anchor.end <= canonical.length,
                  canonical.substring(with: NSRange(location: anchor.start, length: anchor.end - anchor.start)).utf16.elementsEqual(anchor.quote.utf16) else { return nil }
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
                // Recoloured PDF mark: same entry, new colour, the plan's new ID.
                var payload = source.payload
                payload["id"] = nil
                payload["color"] = range.color.map(LawJSON.string)
                change.additions.append(LawMarkAddition(kind: source.kind, payload: payload, id: range.id))
                continue
            }
            guard let anchor = LawMarkEditing.anchor(for: range, canonical: canonical), let value = anchor.json else { continue }
            var payload: [String: LawJSON] = ["lawId": .string(document.id), "versionId": .string(document.version), "kind": .string("text"), "page": .number(0), "anchor": value]
            if let color = range.color { payload["color"] = .string(color) }
            change.additions.append(LawMarkAddition(payload: payload, id: range.id))
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
