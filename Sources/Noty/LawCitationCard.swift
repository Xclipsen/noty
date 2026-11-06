// Vorschaukarte eines Gesetzesverweises im Heft (docs/PARAGRAPH-LINKS.md):
// neben dem Verweis, nie darüber, im sicheren Bereich des Arbeitsbereichs.
// Die ganze Karte ist ein Knopf und öffnet das Gesetzesfenster; darüber liegt
// getrennt „Als Zitat einfügen“. Tipps daneben gehen weiter an die Seite (die
// Ebene selbst nimmt keine Berührung an). Esc schließt die Karte.
import SwiftUI
import NotebookCore

/// Overlay of `EditorWorkspaceView`: places the card of
/// `LawCitationPreviewModel.shared` in its own coordinate space (anchors
/// arrive in window coordinates; the app has a single scene).
struct LawCitationCardLayer: View {
    /// Height of the software keyboard over the bottom of the layer.
    var keyboard: CGFloat = 0
    @ObservedObject private var model = LawCitationPreviewModel.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Room kept for the card whatever it will show (loading, note, text), so
    /// it never changes sides once its text arrives; it grows away from the
    /// citation inside this room.
    @ScaledMetric(relativeTo: .footnote) private var reservedHeight: CGFloat = 250

    static let width: CGFloat = 320
    /// Distance between the citation and the card.
    private static let gap: CGFloat = 8
    private static let margin: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            let global = geometry.frame(in: .global)
            let insets = geometry.safeAreaInsets
            let bottom = max(insets.bottom, keyboard)
            let bounds = CGRect(x: insets.leading, y: insets.top,
                                width: max(0, geometry.size.width - insets.leading - insets.trailing),
                                height: max(0, geometry.size.height - insets.top - bottom))
            let width = max(0, min(Self.width, bounds.width - 2 * Self.margin))
            let height = min(reservedHeight, max(0, bounds.height - 2 * Self.margin))
            ZStack(alignment: .topLeading) {
                if model.presentation != nil {
                    // Esc where no responder of the page takes it (the other ways
                    // go through `consumeEscape` in KeyboardRouter and LawKeyboard).
                    Button("") { _ = model.consumeEscape() }
                        .keyboardShortcut(.cancelAction).frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
                }
                if let presentation = model.presentation {
                    let anchor = presentation.anchor.offsetBy(dx: -global.minX, dy: -global.minY)
                    let place = Self.placement(anchor: anchor, size: CGSize(width: width, height: height), in: bounds)
                    // At most the reserved room: with large type the text gives
                    // up lines (header and hint stay), the card never grows over
                    // the citation.
                    LawCitationCard(model: model, presentation: presentation)
                        .frame(width: width)
                        .frame(maxHeight: height)
                        // Towards the citation: above it the card sits at the
                        // bottom of its room, below it at the top.
                        .frame(width: width, height: height, alignment: place.above ? .bottom : .top)
                        .offset(x: place.origin.x, y: place.origin.y)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: place.above ? .bottom : .top)))
                        .id(model.cardID)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .animation(NotyMotion.highlight(reduceMotion), value: model.presentation == nil ? -1 : model.cardID)
            // Rotation, split, law window, keyboard: the anchor is no longer where it was.
            .onChange(of: "\(geometry.size.width)|\(geometry.size.height)|\(global.minX)|\(global.minY)|\(keyboard)") { _, _ in
                model.dismiss()
            }
        }
    }

    /// Above the citation if there is room, else below, else beside it; never
    /// over it, always inside `bounds` (clamped along the free axis).
    static func placement(anchor: CGRect, size: CGSize, in bounds: CGRect) -> (origin: CGPoint, above: Bool) {
        let minX = bounds.minX + margin, maxX = max(minX, bounds.maxX - margin - size.width)
        let minY = bounds.minY + margin, maxY = max(minY, bounds.maxY - margin - size.height)
        let x = min(max(anchor.midX - size.width / 2, minX), maxX)
        let aboveY = anchor.minY - gap - size.height
        if aboveY >= minY { return (CGPoint(x: x, y: aboveY), true) }
        let belowY = anchor.maxY + gap
        if belowY <= maxY { return (CGPoint(x: x, y: belowY), false) }
        // Neither above nor below: beside the citation, the side with more room.
        let y = min(max(anchor.midY - size.height / 2, minY), maxY)
        let right = anchor.maxX + gap, left = anchor.minX - gap - size.width
        if right + size.width <= bounds.maxX - margin { return (CGPoint(x: right, y: y), false) }
        if left >= minX { return (CGPoint(x: left, y: y), false) }
        // Very little room (e.g. a narrow split): the larger of above/below, clamped.
        let roomAbove = anchor.minY - bounds.minY, roomBelow = bounds.maxY - anchor.maxY
        return roomAbove > roomBelow ? (CGPoint(x: x, y: max(minY, aboveY)), true) : (CGPoint(x: x, y: min(maxY, belowY)), false)
    }
}

/// The card itself: heading, title, the first lines of the section, a hint.
struct LawCitationCard: View {
    @ObservedObject var model: LawCitationPreviewModel
    let presentation: LawCitationPreviewModel.Presentation

    private var openHint: String { presentation.input == .pointerHover ? "Klicken zum Öffnen" : "Tippen zum Öffnen" }

    /// Height of the quote button; the hint row keeps this room for it.
    private static let quoteHeight: CGFloat = 44

    var body: some View {
        Button { model.openPresented() } label: {
            VStack(alignment: .leading, spacing: 6) {
                header
                bodyText
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.forward.square").accessibilityHidden(true)
                    Text(openHint)
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.55))
                .padding(.top, 2)
                // Room beside the hint for the separate quote button above it.
                .frame(minHeight: model.canQuote ? Self.quoteHeight - 10 : nil, alignment: .leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Whatever does not fit the room stays inside the card.
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .notyGlass()
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(NotyPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Öffnet die Vorschrift in der Gesetzessammlung")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.escape) { model.dismiss() }
        // A sibling above the card, not inside its button: hit by finger,
        // Pencil and pointer on its own.
        .overlay(alignment: .bottomTrailing) {
            if model.canQuote { quoteButton.padding(.trailing, 6).padding(.bottom, 6) }
        }
        .environment(\.colorScheme, .dark)
        // Stift oder Zeiger auf der Karte halten sie offen.
        .onContinuousHover { phase in
            switch phase {
            case .active: model.cardHover(true)
            case .ended: model.cardHover(false)
            }
        }
        .onDisappear { model.cardHover(false) }
    }

    private var quoteButton: some View {
        Button { model.quotePresented() } label: {
            Label("Als Zitat einfügen", systemImage: "text.quote")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.notyAccent)
                .padding(.horizontal, 10).frame(minHeight: 30)
                .background(Color.white.opacity(0.1), in: Capsule(style: .continuous))
                .frame(minHeight: Self.quoteHeight).padding(.horizontal, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(NotyPressStyle())
        .hoverEffect(.highlight)
        .accessibilityHint("Fügt den Gesetzestext mit Fundstelle unter dem Verweis als Textfeld ein")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "book.closed").font(.subheadline).foregroundStyle(Color.notyAccent).accessibilityHidden(true)
                Text(model.heading).font(.headline).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.8)
            }
            if case let .section(_, title, _, _) = model.content, !title.isEmpty {
                Text(title).font(.subheadline).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
            }
            if let note = model.versionNote {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: note.caution ? "clock.badge.exclamationmark" : "clock").accessibilityHidden(true)
                    Text(note.text)
                }
                .font(.caption2)
                .foregroundStyle(note.caution ? Color.orange.opacity(0.9) : .white.opacity(0.55))
                .lineLimit(2)
            }
            if presentation.fromHandwriting {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "pencil.and.scribble").accessibilityHidden(true)
                    Text(handwritingText)
                }
                .font(.caption2).foregroundStyle(Color.orange.opacity(0.9)).lineLimit(2)
            }
            if let inferred = inferredText {
                Text(inferred).font(.caption2).foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    private var handwritingText: String { "Aus Handschrift erkannt: \(model.heading) – stimmt das?" }
    /// A bare „§ 35a“: the notebook's default law or the law named before it.
    private var inferredText: String? {
        guard presentation.citation.inferredLaw else { return nil }
        if let law = presentation.context.defaultLawID, law == presentation.citation.lawID { return "Standardgesetz des Hefts" }
        return "Gesetz aus dem Zusammenhang erkannt"
    }

    @ViewBuilder private var bodyText: some View {
        switch model.content {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Wird geladen …").font(.footnote).foregroundStyle(.white.opacity(0.7))
            }
            .frame(minHeight: 44, alignment: .leading)
        case .notOffline:
            note("\(model.lawAbbreviation) ist noch nicht offline auf diesem iPad. Beim Öffnen wird der Text geladen.", symbol: "icloud.and.arrow.down")
        case .missing:
            note("\(model.heading) ist in der aktuellen Fassung nicht enthalten.", symbol: "exclamationmark.triangle")
        case .unavailable:
            note("Dieses Gesetz ist nicht mehr in der Gesetzessammlung.", symbol: "exclamationmark.triangle")
        case let .section(_, _, excerpt, _):
            Text(excerpt.isEmpty ? "(ohne Text)" : excerpt)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(6)
                .lineSpacing(2)
                .layoutPriority(-1)
        }
    }

    private func note(_ text: String, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(.orange).accessibilityHidden(true)
            Text(text).lineLimit(5)
        }
        .layoutPriority(-1)
        .font(.footnote).foregroundStyle(.white.opacity(0.8))
    }

    private var accessibilityText: String {
        var parts = ["Gesetzesverweis \(model.heading)"]
        switch model.content {
        case let .section(_, title, excerpt, _):
            if !title.isEmpty { parts.append(title) }
            if !excerpt.isEmpty { parts.append(String(excerpt.prefix(300))) }
        case .loading: parts.append("Wird geladen")
        case .notOffline: parts.append("Noch nicht offline verfügbar")
        case .missing: parts.append("In der aktuellen Fassung nicht enthalten")
        case .unavailable: parts.append("Nicht mehr in der Gesetzessammlung")
        }
        if let note = model.versionNote { parts.append(note.text) }
        if presentation.fromHandwriting { parts.append(handwritingText) }
        if let inferred = inferredText { parts.append(inferred) }
        return parts.joined(separator: ", ")
    }
}
