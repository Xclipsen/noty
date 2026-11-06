// Vorschaukarte eines Gesetzesverweises im Heft (docs/PARAGRAPH-LINKS.md):
// neben dem Verweis, nie darüber, im sicheren Bereich des Arbeitsbereichs.
// Die ganze Karte ist ein Knopf und öffnet das Gesetzesfenster; Tipps
// daneben gehen weiter an die Seite (die Ebene selbst nimmt keine Berührung an).
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
        .environment(\.colorScheme, .dark)
        // Stift oder Zeiger auf der Karte halten sie offen.
        .onContinuousHover { phase in
            switch phase {
            case .active: model.cardHover(true)
            case .ended: model.cardHover(false)
            }
        }
        .onDisappear { model.cardHover(false) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Öffnet die Vorschrift in der Gesetzessammlung")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.escape) { model.dismiss() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "book.closed").font(.subheadline).foregroundStyle(Color.notyAccent).accessibilityHidden(true)
                Text(model.heading).font(.headline).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.8)
            }
            if case let .section(_, title, _) = model.content, !title.isEmpty {
                Text(title).font(.subheadline).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
            }
            if presentation.citation.inferredLaw {
                Text("Gesetz aus dem Zusammenhang erkannt").font(.caption2).foregroundStyle(.white.opacity(0.55))
            }
        }
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
        case let .section(_, _, excerpt):
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
        case let .section(_, title, excerpt):
            if !title.isEmpty { parts.append(title) }
            if !excerpt.isEmpty { parts.append(String(excerpt.prefix(300))) }
        case .loading: parts.append("Wird geladen")
        case .notOffline: parts.append("Noch nicht offline verfügbar")
        case .missing: parts.append("In der aktuellen Fassung nicht enthalten")
        case .unavailable: parts.append("Nicht mehr in der Gesetzessammlung")
        }
        if presentation.citation.inferredLaw { parts.append("Gesetz aus dem Zusammenhang erkannt") }
        return parts.joined(separator: ", ")
    }
}
