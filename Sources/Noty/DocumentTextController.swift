import UIKit
import NotebookCore

/// Text editor 2 on one viewport: keeps the buffer and the model together.
/// The model stays the source: every change goes through `Notebook` (undo,
/// validation, saving), the buffer follows what the model holds. Own edits are
/// already in the buffer, so only foreign ones load it anew (undo, formats).
@MainActor
final class DocumentTextController {
    let store = DocumentTextStore()
    let view: DocumentTextSurface
    /// The segments the buffer shows.
    private var synced: [TextBox]?
    private var attached: [ObjectIdentifier: Int] = [:]

    init() {
        view = DocumentTextSurface(store: store)
        view.onCommitted = { [weak self] focus in self?.committed(focus) }
    }

    func update(pages: [Page], placements: [UUID: NotebookPagePlacement], frame: CGRect, host: DocumentTextHost, active: Bool) {
        view.host = host
        if view.frame != frame { view.frame = frame }
        let slots = DocumentPageSlots.indices(in: pages)
        store.configure(slots.enumerated().map { index, page in
            DocumentPageSlot(page: pages[page], index: index, placement: placements[pages[page].id])
        })
        view.lightText = pages.first?.paperColor == .dark
        let boxes = pages.compactMap { $0.effectiveTextBoxes.first(where: { $0.flowID != nil }) }
        if boxes != synced, view.marked == nil { load(boxes) }
        view.isActive = active
        view.refreshOverlay()
    }

    private func load(_ boxes: [TextBox]) {
        guard var content = boxes.first else { return }
        for box in boxes.dropFirst() { content = content.appending(box) }
        let shown = content.resolvingAutomaticColor(light: view.lightText).attributedText
        view.baseStyle = content.style
        view.replacingAllText { store.load(shown) }
        synced = boxes
    }

    /// The buffer is ahead of the model until here. What the model holds now
    /// counts: a refused change goes back, a renumbered list comes in.
    private func committed(_ focus: TextFlowFocus?) {
        guard let flow = view.host?.flow else { return }
        let boxes = flow.segments().map(\.box)
        if focus != nil, boxes.map(\.text).joined() == store.string {
            synced = boxes
            store.logDeviations(boxes)
            return
        }
        load(boxes)
        if let focus, let offset = flow.offset(focus.boxID, focus.selection.location) {
            view.adopt(selection: NSRange(location: offset, length: focus.selection.length))
        }
    }

    /// The sheet's text layer shows its page of the shared layout; its own
    /// field of the flow stays configured (the model's boxes) but hidden.
    func attach(_ layer: TextObjectLayer, pageID: UUID) {
        let page = store.slots.firstIndex { $0.pageID == pageID }
        layer.onDocumentCaret = { [weak view, weak layer] point in
            guard let view, let layer else { return }
            view.setCaret(at: layer.convert(point, to: view))
        }
        layer.showDocumentPage(store: store, page: page, box: page.map { store.slots[$0].box })
    }
    func detach(_ layer: TextObjectLayer) {
        layer.onDocumentCaret = nil
        layer.showDocumentPage(store: nil, page: nil, box: nil)
    }
}
