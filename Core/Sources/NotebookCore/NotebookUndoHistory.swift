import Foundation

/// One chronological undo/redo history for the whole notebook (all pages and
/// all content layers). Steps name pages by stable ID and carry the exact
/// expected page state. A step whose pages no longer match — page deleted,
/// cleared, restored, replaced or edited outside this history — is dropped
/// instead of overwriting newer content. Positions are never used.
public struct NotebookUndoHistory: Sendable {
    /// `.pages`: page-level operations (paper style/defaults, whole-notebook
    /// restyle, add, delete to the page trash, restore, duplicate, paste,
    /// move/reorder, PDF insertion, clearing, bookmarks, writing margins).
    public enum Kind: Equatable, Sendable { case ink, text, images, objects, transfer, textFlow, pages }

    /// Consecutive records with the same key within `window` seconds merge
    /// into one step (one eraser gesture, one image drag, a typing burst).
    public struct Coalescing: Equatable, Sendable {
        public let key: String
        public let window: TimeInterval
        public init(key: String, window: TimeInterval) { self.key = key; self.window = window }
    }

    /// Result of an undo/redo: the complete candidate notebook and the page
    /// that should be revealed.
    public struct Outcome: Sendable {
        public let notebook: Notebook
        public let pageID: UUID
        public let focus: TextFlowFocus?
        public let kind: Kind
    }

    struct Step: Sendable {
        let kind: Kind
        /// `expected` = state before the change, `replacement` = state after it.
        var changes: [PageContentReplacement]
        /// Text-flow edits that added or removed pages keep complete snapshots.
        var snapshot: Snapshot?
        /// Page operations keep only what they changed (by stable page ID).
        var structure: PageStructureChange?
        var beforeFocus: TextFlowFocus?
        var afterFocus: TextFlowFocus?
        let undoPageID: UUID
        let redoPageID: UUID
        let coalescing: Coalescing?
        var updated: Date
        var cost: Int
    }
    struct Snapshot: Sendable { var before: Notebook; var after: Notebook }

    public static let maximumSteps = 100
    public static let maximumCost = 80_000_000

    private var undoSteps: [Step] = []
    private var redoSteps: [Step] = []
    /// Coalescing only continues the step that was recorded last.
    private var canCoalesce = false

    public init() {}

    public var canUndo: Bool { !undoSteps.isEmpty }
    public var canRedo: Bool { !redoSteps.isEmpty }
    public var undoCount: Int { undoSteps.count }
    public var redoCount: Int { redoSteps.count }

    public mutating func removeAll() { undoSteps = []; redoSteps = []; canCoalesce = false }
    /// The next record starts its own step (e.g. an automatic list conversion
    /// stays separately undoable from the typing that triggered it).
    public mutating func separateNextStep() { canCoalesce = false }

    /// Page-content change on one or more pages. `undoPageID`/`redoPageID`
    /// default to the first/last changed page (a transfer lists source first).
    public mutating func record(_ kind: Kind, changes: [PageContentReplacement],
                                beforeFocus: TextFlowFocus? = nil, afterFocus: TextFlowFocus? = nil,
                                coalescing: Coalescing? = nil, now: Date = Date()) {
        let changes = changes.filter { $0.expected != $0.replacement }
        guard let first = changes.first, let last = changes.last else { return }
        add(Step(kind: kind, changes: changes, snapshot: nil, structure: nil, beforeFocus: beforeFocus, afterFocus: afterFocus,
                 undoPageID: beforeFocus?.pageID ?? first.pageID, redoPageID: afterFocus?.pageID ?? last.pageID,
                 coalescing: coalescing, updated: now, cost: Self.cost(changes)))
    }

    /// Whole-notebook change (text flow). Kept as page-content changes when the
    /// page list is unchanged, otherwise as complete snapshots.
    public mutating func record(_ kind: Kind, before: Notebook, after: Notebook,
                                beforeFocus: TextFlowFocus? = nil, afterFocus: TextFlowFocus? = nil,
                                coalescing: Coalescing? = nil, now: Date = Date()) {
        guard before != after else { return }
        let ids = before.pages.map(\.id)
        if ids == after.pages.map(\.id), before.deletedPages == after.deletedPages {
            let changes = zip(before.pages, after.pages).map {
                PageContentReplacement(pageID: $0.id, expected: PageContent(page: $0), replacement: PageContent(page: $1))
            }.filter { $0.expected != $0.replacement }
            guard !changes.isEmpty else { return }
            record(kind, changes: changes, beforeFocus: beforeFocus, afterFocus: afterFocus, coalescing: coalescing, now: now)
            return
        }
        let page = afterFocus?.pageID ?? beforeFocus?.pageID ?? after.pages.first?.id ?? UUID()
        let changed = after.pages.filter { page in before.pages.first { $0.id == page.id } != page }
        add(Step(kind: kind, changes: [], snapshot: Snapshot(before: before, after: after), structure: nil,
                 beforeFocus: beforeFocus, afterFocus: afterFocus,
                 undoPageID: beforeFocus?.pageID ?? page, redoPageID: page, coalescing: coalescing, updated: now,
                 cost: 1_000_000 + changed.reduce(0) { $0 + $1.drawing.count }))
    }

    /// Page operation (`.pages`): one step that restores the exact earlier page
    /// list, page trash, PDF sources and notebook paper default. Only pages and
    /// trash entries the operation touched are compared and replaced, by stable
    /// ID; pages created meanwhile outside the history (the materialised writing
    /// draft) keep their place next to their neighbours. `undoPageID`/`redoPageID`
    /// are the pages to reveal. Returns false when the change cannot be expressed
    /// safely (a legacy pre-page-editing notebook would need its format lowered):
    /// the caller then prunes stale steps instead.
    @discardableResult
    public mutating func recordPages(before: Notebook, after: Notebook, undoPageID: UUID, redoPageID: UUID,
                                     now: Date = Date()) -> Bool {
        guard before != after else { return true }
        guard let change = PageStructureChange(before: before, after: after) else { return false }
        guard !change.isEmpty else { return true }
        add(Step(kind: .pages, changes: [], snapshot: nil, structure: change, beforeFocus: nil, afterFocus: nil,
                 undoPageID: undoPageID, redoPageID: redoPageID, coalescing: nil, updated: now, cost: change.cost))
        canCoalesce = false
        return true
    }

    /// Reverts the newest still applicable step. Stale steps on top are dropped.
    public mutating func undo(_ notebook: Notebook) -> Outcome? { move(notebook, redo: false) }
    /// Re-applies the newest undone step that still matches.
    public mutating func redo(_ notebook: Notebook) -> Outcome? { move(notebook, redo: true) }

    /// Drops stale steps from the top of both stacks (after page operations),
    /// so the undo/redo buttons reflect what can actually be applied.
    public mutating func prune(_ notebook: Notebook) {
        while let step = undoSteps.last, (try? Self.apply(step, to: notebook, redo: false)) == nil { undoSteps.removeLast() }
        while let step = redoSteps.last, (try? Self.apply(step, to: notebook, redo: true)) == nil { redoSteps.removeLast() }
        canCoalesce = false
    }

    private mutating func move(_ notebook: Notebook, redo: Bool) -> Outcome? {
        canCoalesce = false
        while let step = redo ? redoSteps.popLast() : undoSteps.popLast() {
            guard let result = try? Self.apply(step, to: notebook, redo: redo) else { continue }
            if redo { undoSteps.append(step) } else { redoSteps.append(step) }
            return Outcome(notebook: result, pageID: redo ? step.redoPageID : step.undoPageID,
                           focus: redo ? step.afterFocus : step.beforeFocus, kind: step.kind)
        }
        return nil
    }

    private mutating func add(_ step: Step) {
        redoSteps = []
        if canCoalesce, let key = step.coalescing, let top = undoSteps.last, top.kind == step.kind,
           top.coalescing == key, step.updated.timeIntervalSince(top.updated) <= key.window,
           let merged = Self.merge(top, step) {
            // A gesture that ended where it started (cancelled drag) leaves no step.
            if merged.changes.isEmpty && merged.snapshot == nil { undoSteps.removeLast(); canCoalesce = false; return }
            undoSteps[undoSteps.count - 1] = merged
        } else {
            undoSteps.append(step)
        }
        canCoalesce = true
        var total = undoSteps.reduce(0) { $0 + $1.cost }
        while undoSteps.count > Self.maximumSteps || (total > Self.maximumCost && undoSteps.count > 1) {
            total -= undoSteps.removeFirst().cost
        }
    }

    /// Merges only an unbroken chain: every page of `next` must start exactly
    /// where `top` left it.
    private static func merge(_ top: Step, _ next: Step) -> Step? {
        guard top.structure == nil, next.structure == nil else { return nil }
        var merged = top
        merged.updated = next.updated
        merged.afterFocus = next.afterFocus ?? top.afterFocus
        if let a = top.snapshot, let b = next.snapshot {
            guard a.after == b.before else { return nil }
            merged.snapshot = a.before == b.after ? nil : Snapshot(before: a.before, after: b.after)
            merged.cost = max(top.cost, next.cost)
            return merged
        }
        guard top.snapshot == nil, next.snapshot == nil else { return nil }
        for change in next.changes {
            if let index = merged.changes.firstIndex(where: { $0.pageID == change.pageID }) {
                guard merged.changes[index].replacement == change.expected else { return nil }
                merged.changes[index] = PageContentReplacement(pageID: change.pageID,
                    expected: merged.changes[index].expected, replacement: change.replacement)
            } else {
                merged.changes.append(change)
            }
        }
        merged.changes.removeAll { $0.expected == $0.replacement }
        merged.cost = cost(merged.changes)
        return merged
    }

    private static func cost(_ changes: [PageContentReplacement]) -> Int {
        changes.reduce(0) { total, change in
            var value = change.expected.drawing.count + change.replacement.drawing.count + 256
            if change.expected.images != change.replacement.images {
                // Only originals that left the page are kept alive by the history.
                let kept = Set(change.replacement.images.map(\.id))
                value += change.expected.images.filter { !kept.contains($0.id) }.reduce(0) { $0 + $1.data.count }
            }
            return total + value
        }
    }

    /// Applies one step in either direction. Throws when any page is missing
    /// or differs from the state the step expects.
    static func apply(_ step: Step, to notebook: Notebook, redo: Bool) throws -> Notebook {
        if let structure = step.structure { return try structure.apply(to: notebook, redo: redo) }
        if let snapshot = step.snapshot {
            // A migration committed meanwhile must not be undone: compare and
            // restore content, never lower the schema.
            var expected = redo ? snapshot.before : snapshot.after
            expected.schemaVersion = notebook.schemaVersion
            guard notebook == expected else { throw CrossPageTransferError.conflict }
            var result = redo ? snapshot.after : snapshot.before
            result.schemaVersion = max(result.schemaVersion, notebook.schemaVersion)
            try result.validate()
            return result
        }
        return try apply(redo ? step.changes : step.changes.map(\.inverted), to: notebook)
    }

    /// Uses the same write path as the original edit, so restoring ink never
    /// changes the schema and text/image/object changes keep their validation.
    public static func apply(_ changes: [PageContentReplacement], to notebook: Notebook) throws -> Notebook {
        guard !changes.isEmpty, Set(changes.map(\.pageID)).count == changes.count else { throw StorageError.invalidDocument }
        for change in changes {
            guard let page = notebook.pages.first(where: { $0.id == change.pageID }) else { throw PageOperationError.missingPage }
            guard PageContent(page: page) == change.expected else { throw CrossPageTransferError.conflict }
        }
        var result = notebook
        let drawingOnly = changes.allSatisfy {
            $0.expected.textBoxes == $0.replacement.textBoxes && $0.expected.images == $0.replacement.images
                && $0.expected.shapes == $0.replacement.shapes
        }
        if drawingOnly {
            for change in changes {
                guard let index = result.pages.firstIndex(where: { $0.id == change.pageID }) else { throw PageOperationError.missingPage }
                result.pages[index].drawing = change.replacement.drawing
            }
            return result
        }
        if changes.count == 1, let change = changes.first {
            let e = change.expected, r = change.replacement
            if e.drawing == r.drawing && e.images == r.images && e.shapes == r.shapes {
                try result.replaceTextBoxes(r.textBoxes, pageID: change.pageID); return result
            }
            if e.drawing == r.drawing && e.textBoxes == r.textBoxes && e.shapes == r.shapes {
                try result.replaceImages(r.images, pageID: change.pageID); return result
            }
        }
        try result.replaceContents(changes)
        return result
    }
}

/// What one page operation changed, by stable ID. `before`/`after` hold only
/// the touched pages and trash entries (absent key = not present on that side)
/// plus the complete active and trash order of each side.
struct PageStructureChange: Sendable {
    struct Side: Sendable {
        var order: [UUID]
        var pages: [UUID: Page]
        var trashOrder: [UUID]
        var trash: [UUID: DeletedPage]
        var appearance: NotebookAppearance?
        /// PDF sources only this side has (e.g. added by a PDF import).
        var sources: [PDFSource]
        var schemaVersion: Int
    }
    var before: Side
    var after: Side
    var pageIDs: Set<UUID>
    var trashIDs: Set<UUID>
    var appearanceChanged: Bool

    /// nil when `before` still uses the legacy single-PDF representation (no
    /// page-editing structure): undoing would have to lower the format.
    init?(before old: Notebook, after new: Notebook) {
        guard old.id == new.id, old.pdfSources != nil, new.pdfSources != nil, old.pdf == nil, new.pdf == nil else { return nil }
        let oldPages = Dictionary(old.pages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let newPages = Dictionary(new.pages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let oldTrash = Dictionary((old.deletedPages ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let newTrash = Dictionary((new.deletedPages ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let touchedPages = Set(oldPages.keys).union(newPages.keys).filter { !Self.same(oldPages[$0], newPages[$0]) }
        let touchedTrash = Set(oldTrash.keys).union(newTrash.keys).filter { !Self.same(oldTrash[$0], newTrash[$0]) }
        let oldSources = old.pdfSources ?? [], newSources = new.pdfSources ?? []
        func side(_ notebook: Notebook, pages: [UUID: Page], trash: [UUID: DeletedPage], sources: [PDFSource], other: [PDFSource]) -> Side {
            Side(order: notebook.pages.map(\.id), pages: pages.filter { touchedPages.contains($0.key) },
                 trashOrder: (notebook.deletedPages ?? []).map(\.id), trash: trash.filter { touchedTrash.contains($0.key) },
                 appearance: notebook.appearance, sources: sources.filter { source in !other.contains(source) },
                 schemaVersion: notebook.schemaVersion)
        }
        pageIDs = touchedPages
        trashIDs = touchedTrash
        appearanceChanged = old.appearance != new.appearance
        before = side(old, pages: oldPages, trash: oldTrash, sources: oldSources, other: newSources)
        after = side(new, pages: newPages, trash: newTrash, sources: newSources, other: oldSources)
    }

    /// Text editing migrates every page's legacy text representation
    /// (`textBoxes` nil → effective boxes) without changing content; that must
    /// not make page steps stale, nor may undo bring the old representation back.
    static func normalized(_ page: Page) -> Page {
        var result = page; result.textBoxes = page.effectiveTextBoxes; result.text = ""; return result
    }
    static func normalized(_ entry: DeletedPage) -> DeletedPage {
        DeletedPage(page: normalized(entry.page), originalIndex: entry.originalIndex, deletedAt: entry.deletedAt,
                    nextPageID: entry.nextPageID, previousPageID: entry.previousPageID, reason: entry.reason)
    }
    static func same(_ a: Page?, _ b: Page?) -> Bool { a == b || a.map(normalized) == b.map(normalized) }
    static func same(_ a: DeletedPage?, _ b: DeletedPage?) -> Bool { a == b || a.map(normalized) == b.map(normalized) }

    var isEmpty: Bool {
        pageIDs.isEmpty && trashIDs.isEmpty && !appearanceChanged && before.order == after.order
            && before.trashOrder == after.trashOrder && before.sources.isEmpty && after.sources.isEmpty
    }

    /// Bytes the history may keep alive (conservative: shared buffers counted).
    var cost: Int {
        func size(_ page: Page) -> Int { page.drawing.count + (page.images ?? []).reduce(0) { $0 + $1.data.count } + 512 }
        let sides = [before, after]
        return 4_096 + sides.reduce(0) { total, side in
            total + side.pages.values.reduce(0) { $0 + size($1) } + side.trash.values.reduce(0) { $0 + size($1.page) }
                + side.sources.reduce(0) { $0 + $1.data.count } + (side.order.count + side.trashOrder.count) * 16
        }
    }

    /// Checks that every touched page and trash entry is exactly in the state
    /// this side left it, then installs the other side. Throws (step is stale)
    /// otherwise; untouched pages are neither compared nor changed.
    func apply(to notebook: Notebook, redo: Bool) throws -> Notebook {
        let from = redo ? before : after, to = redo ? after : before
        guard notebook.pdfSources != nil, notebook.pdf == nil else { throw CrossPageTransferError.conflict }
        let trash = notebook.deletedPages ?? []
        for id in pageIDs {
            guard Self.same(notebook.pages.first(where: { $0.id == id }), from.pages[id]) else { throw CrossPageTransferError.conflict }
        }
        for id in trashIDs {
            guard Self.same(trash.first(where: { $0.id == id }), from.trash[id]) else { throw CrossPageTransferError.conflict }
        }
        if appearanceChanged { guard notebook.appearance == from.appearance else { throw CrossPageTransferError.conflict } }

        // Once text editing migrated the notebook, restored pages use the new representation.
        let migrated = (notebook.pages + trash.map(\.page)).contains { $0.textBoxes != nil }
        var result = notebook
        let currentPages = Dictionary(notebook.pages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        result.pages = try Self.merge(target: to.order, current: notebook.pages.map(\.id), touched: pageIDs).map { id in
            if pageIDs.contains(id) {
                guard let page = to.pages[id] else { throw CrossPageTransferError.conflict }
                return migrated ? Self.normalized(page) : page
            }
            // An untouched page of the target order that disappeared meanwhile: stale.
            guard let page = currentPages[id] else { throw PageOperationError.missingPage }
            return page
        }
        let currentTrash = Dictionary(trash.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        result.deletedPages = try Self.merge(target: to.trashOrder, current: trash.map(\.id), touched: trashIDs).map { id in
            if trashIDs.contains(id) {
                guard let entry = to.trash[id] else { throw CrossPageTransferError.conflict }
                return migrated ? Self.normalized(entry) : entry
            }
            guard let entry = currentTrash[id] else { throw PageOperationError.missingPage }
            return entry
        }
        if appearanceChanged { result.appearance = to.appearance }
        // Sources: re-add what the target side had; drop what only the other
        // side added once nothing references it any more. Never replace bytes.
        var sources = notebook.pdfSources ?? []
        for source in to.sources {
            if let existing = sources.first(where: { $0.id == source.id }) {
                guard existing == source else { throw CrossPageTransferError.conflict }
            } else { sources.append(source) }
        }
        let referenced = Set((result.pages + (result.deletedPages ?? []).map(\.page)).compactMap { $0.pdfReference?.sourceID })
        let removable = Set(from.sources.map(\.id)).subtracting(to.sources.map(\.id))
        sources.removeAll { removable.contains($0.id) && !referenced.contains($0.id) }
        result.pdfSources = sources
        // Never lower the format (a migration may have been committed meanwhile).
        result.schemaVersion = max(notebook.schemaVersion, to.schemaVersion)
        try result.validate()
        return result
    }

    /// Target order for the touched items; items present now but unknown to the
    /// target side (created outside the history) stay after the same preceding
    /// target item they currently follow. Touched items absent on the target
    /// side are removed.
    static func merge(target: [UUID], current: [UUID], touched: Set<UUID>) throws -> [UUID] {
        let targetSet = Set(target)
        guard targetSet.count == target.count else { throw StorageError.invalidDocument }
        var anchored: [UUID?: [UUID]] = [:]
        var anchor: UUID?
        for id in current {
            if targetSet.contains(id) { anchor = id; continue }
            if touched.contains(id) { continue }
            anchored[anchor, default: []].append(id)
        }
        var result = anchored[UUID?.none] ?? []
        for id in target { result.append(id); result += anchored[id] ?? [] }
        return result
    }
}

/// Page selection after the selected page disappeared (deleted here or in
/// another pane): the closest earlier page that still exists, otherwise the
/// closest later one.
public enum PageRemovalFocus {
    public static func focus(removed: UUID, before old: [UUID], after new: [UUID]) -> UUID? {
        guard !new.isEmpty else { return nil }
        let remaining = Set(new)
        if remaining.contains(removed) { return removed }
        guard let index = old.firstIndex(of: removed) else { return nil }
        if let previous = old[..<index].last(where: { remaining.contains($0) }) { return previous }
        return old[(index + 1)...].first { remaining.contains($0) }
    }
}
