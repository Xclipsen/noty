import SwiftUI
import NotebookCore

/// Small rounded fact („Ausfall“, „R 204“, „Stundenplan 🔒“): symbol plus
/// text, never colour alone.
struct CalendarChip: View {
    let text: String
    var symbol: String?
    var dot: Color?
    var trailingSymbol: String?
    var tint: Color = .secondary
    /// Status: stronger fill and the tint on the text too.
    var prominent = false

    var body: some View {
        HStack(spacing: 5) {
            if let dot { Circle().fill(dot).frame(width: 8, height: 8) }
            if let symbol { Image(systemName: symbol).font(.caption.weight(.semibold)).foregroundStyle(prominent ? tint : .secondary) }
            Text(text).font(.footnote.weight(prominent ? .semibold : .regular)).foregroundStyle(prominent ? tint : .primary)
                .lineLimit(2)
            if let trailingSymbol { Image(systemName: trailingSymbol).font(.system(size: 9)).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Capsule().fill(prominent ? tint.opacity(0.16) : Color.primary.opacity(0.08)))
        .accessibilityElement(children: .combine)
    }
}

/// Left-aligned rows that wrap (chips of the event head).
struct CalendarFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + CGFloat(max(0, rows.count - 1)) * spacing
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            let needed = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.items.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}

/// Small icon + text with tight spacing for metadata rows.
struct CalendarCompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.frame(width: 16)
            configuration.title
        }
    }
}

/// „Automatisch“ plus the named subject colours.
struct CalendarColorPicker: View {
    let key: String
    @ObservedObject var model: CalendarModel

    var body: some View {
        let chosen = model.subjectColors[key]
        Picker("Fachfarbe", selection: Binding<String>(get: { chosen ?? "" }, set: { model.setSubjectColor(key, to: $0.isEmpty ? nil : $0) })) {
            Label("Automatisch (\(CalendarSubjectColor.title(CalendarSubjectColor.name(for: key, chosen: [:]))))", systemImage: "wand.and.stars").tag("")
            ForEach(CalendarSubjectColor.choosable, id: \.self) { name in
                Label {
                    Text(CalendarSubjectColor.title(name))
                } icon: {
                    Image(systemName: "circle.fill").foregroundStyle(CalendarPalette.color(named: name))
                }
                .tag(name)
            }
        }
        .pickerStyle(.inline)
    }
}
