import SwiftUI
import NotebookCore

extension LawReaderView {
    /// Bookmarks and marks of all laws (sheet of the reader).
    var markList: some View {
        LawMarkListView(currentLaw: selectedID, currentVersion: document?.version, currentSection: sectionID,
                        open: { item in openListItem(item) }, done: { showBookmarks = false })
    }
    /// Opens the place of a bookmark or mark (law, version, section, PDF page).
    func openListItem(_ item: LawPersonalItem) {
        guard let id = item.payload["lawId"]?.string, let entry = laws.entries.first(where: { $0.id == id }) else { return }
        var target = item.payload["sectionId"]?.string
        if let anchor = item.textAnchor { target = anchor.sectionId }
        let version = item.payload["versionId"]?.string
        let pdfPage = item.payload["view"]?.string == "pdf" || (item.payload["kind"]?.string).map { $0 != "text" } == true ? item.payload["page"]?.int : nil
        showBookmarks = false
        Task {
            await open(entry, version: version, target: target)
            if let page = pdfPage, page > 0, let doc = document, doc.id == entry.id, doc.version == version {
                let request = requestID
                do { let url = try await laws.pdf(entry, version: doc.version); guard requestID == request else { return }; pdfURL = url; pdfTarget = page; viewPDF = true }
                catch { loadError = error.localizedDescription }
            }
        }
    }
}

/// Bookmarks and marks grouped by law and version, then by provision; each
/// row shows the original text (not the canonical key), the mark colour and
/// the PDF page. Swipe or context menu deletes with undo.
struct LawMarkListView: View {
    @EnvironmentObject private var laws: LawLibraryModel
    @EnvironmentObject private var controller: LawMarkController
    var currentLaw: String
    var currentVersion: String?
    var currentSection: String
    var open: (LawPersonalItem) -> Void
    var done: () -> Void
    @State private var documents: [String: LawDocument] = [:]
    @State private var failed: Set<String> = []
    @State private var query = ""

    struct Row: Identifiable {
        var item: LawPersonalItem
        var excerpt: String
        var detail: String
        var order: (Int, Int)
        var id: String { item.id }
    }
    struct SectionGroup: Identifiable {
        var id: String
        var title: String
        var rows: [Row]
        var current: Bool
        var order: Int
    }
    struct VersionGroup: Identifiable {
        var id: String
        var title: String
        var subtitle: String
        var sections: [SectionGroup]
    }

    private var entries: [LawPersonalItem] {
        laws.items.filter { !$0.deleted && ($0.kind == "bookmark" || $0.kind == "annotation") }
    }
    private func key(_ item: LawPersonalItem) -> String {
        "\(item.payload["lawId"]?.string ?? ""):\(item.payload["versionId"]?.string ?? "")"
    }
    private var groups: [VersionGroup] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var result: [VersionGroup] = []
        for (groupKey, items) in Dictionary(grouping: entries, by: key) {
            let law = items[0].payload["lawId"]?.string ?? "", version = items[0].payload["versionId"]?.string ?? ""
            let entry = laws.entries.first { $0.id == law }
            let doc = documents[groupKey]
            var sections: [String: (title: String, order: Int, rows: [Row])] = [:]
            for item in items {
                let (sectionID, row) = describe(item, doc: doc)
                let section = doc?.sections.first { $0.id == sectionID }
                let title = section.map { "\($0.label) \($0.title)".trimmingCharacters(in: .whitespaces) } ?? (sectionID.isEmpty ? "PDF" : sectionID)
                if !needle.isEmpty, !"\(entry?.abbr ?? law) \(title) \(row.excerpt) \(row.detail)".lowercased().contains(needle) { continue }
                let order = section.flatMap { s in doc?.sections.firstIndex { $0.id == s.id } } ?? Int.max
                sections[sectionID, default: (title, order, [])].rows.append(row)
            }
            guard !sections.isEmpty else { continue }
            let versionInfo = entry?.versions.first { $0.id == version }
            let older = entry.map { $0.currentVersion != version } ?? false
            result.append(VersionGroup(
                id: groupKey,
                title: entry.map { "\($0.abbr) · \($0.name)" } ?? law.uppercased(),
                subtitle: (versionInfo?.status.last ?? doc?.status.last ?? version) + (older ? " · ältere Fassung" : ""),
                sections: sections.map { id, value in
                    SectionGroup(id: "\(groupKey)|\(id)", title: value.title, rows: value.rows.sorted { $0.order < $1.order },
                                 current: law == currentLaw && version == currentVersion && id == currentSection, order: value.order)
                }.sorted { ($0.order, $0.title) < ($1.order, $1.title) }))
        }
        return result.sorted { ($0.id.hasPrefix(currentLaw + ":") ? 0 : 1, $0.title, $0.subtitle) < ($1.id.hasPrefix(currentLaw + ":") ? 0 : 1, $1.title, $1.subtitle) }
    }
    /// Section and readable row of an entry.
    private func describe(_ item: LawPersonalItem, doc: LawDocument?) -> (String, Row) {
        let kind = item.payload["kind"]?.string
        let page = item.payload["page"]?.int ?? 0
        var details: [String] = []
        if item.kind == "bookmark" {
            let section = item.payload["sectionId"]?.string ?? ""
            let pdf = item.payload["view"]?.string == "pdf"
            details.append(pdf ? "Lesezeichen · PDF-Seite \(page)" : "Lesezeichen")
            if item.dirty { details.append("Lokal gespeichert") }
            let label = item.payload["label"]?.string ?? doc?.sections.first { $0.id == section }.map { "\($0.label) \($0.title)" } ?? "Lesezeichen"
            return (section, Row(item: item, excerpt: label, detail: details.joined(separator: " · "), order: (-1, page)))
        }
        if kind != "text", page > 0 { details.append("PDF-Seite \(page)") } else { details.append("Lesetext") }
        if item.dirty { details.append("Lokal gespeichert") }
        if let anchor = item.textAnchor {
            let excerpt = doc?.sections.first { $0.id == anchor.sectionId }.flatMap { section in
                LawTextAnchor.originalRange(text: section.text, anchor: anchor).map { Self.excerpt((section.text as NSString).substring(with: $0)) }
            }
            return (anchor.sectionId, Row(item: item, excerpt: excerpt ?? (documents[key(item)] == nil && !failed.contains(key(item)) ? "…" : "Textstelle nicht mehr eindeutig"),
                                          detail: details.joined(separator: " · "), order: (0, anchor.start)))
        }
        // PDF mark without text anchor: the provision starting on or before its page.
        let section = doc?.sections.last { ($0.pdf?.page ?? .max) <= page }?.id ?? ""
        let excerpt = kind == "pdf" ? "Freihandmarkierung im PDF" : "Textstelle im PDF"
        return (section, Row(item: item, excerpt: excerpt, detail: details.joined(separator: " · "), order: (1, page)))
    }
    static func excerpt(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > 220 ? String(flat.prefix(220)) + " …" : flat
    }

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView("Noch keine Lesezeichen oder Markierungen", systemImage: "bookmark",
                                           description: Text("Text auswählen und eine Farbe tippen, mit dem Textmarker über den Text streichen oder oben das Lesezeichen setzen."))
                } else if groups.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List {
                        ForEach(groups) { group in
                            Section {
                                ForEach(group.sections) { section in
                                    Text(section.title).font(.caption.weight(.semibold)).foregroundStyle(section.current ? Color.notyAccent : .secondary)
                                        .lineLimit(1).listRowSeparator(.hidden).padding(.top, 4)
                                        .accessibilityAddTraits(.isHeader)
                                    ForEach(section.rows) { row in rowView(row, current: section.current) }
                                }
                            } header: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(group.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                    Text(group.subtitle).font(.caption).foregroundStyle(.secondary)
                                }.textCase(nil)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "In Lesezeichen und Markierungen suchen")
            .navigationTitle("Lesezeichen & Markierungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig", action: done) } }
            .overlay(alignment: .bottom) { LawMarkToastView(controller: controller).padding(.bottom, 16) }
            .task(id: Set(entries.map(key))) { await loadDocuments() }
        }
    }
    private func rowView(_ row: Row, current: Bool) -> some View {
        let item = row.item
        let go = { open(item) }
        return Button(action: go) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Group {
                    if item.kind == "bookmark" {
                        Image(systemName: "bookmark.fill").font(.system(size: 13)).foregroundStyle(.secondary)
                    } else {
                        Circle().fill(Color(lawMarkColor(item.payload["color"]?.string))).frame(width: 12, height: 12)
                            .overlay(Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 0.5))
                    }
                }.frame(width: 16).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.excerpt).lineLimit(3).foregroundStyle(.primary)
                    Text(row.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(current ? Color.notyAccent.opacity(0.08) : Color.clear)
        .keyOption(.action(go))
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { controller.removeItems([item]) } label: { Label("Entfernen", systemImage: "trash") }
        }
        .contextMenu {
            Button(action: go) { Label("Öffnen", systemImage: "arrow.forward") }
            Button(role: .destructive) { controller.removeItems([item]) } label: { Label("Entfernen", systemImage: "trash") }
        }
        .accessibilityLabel(item.kind == "bookmark" ? "Lesezeichen: \(row.excerpt)" : "Markierung: \(row.excerpt)")
        .accessibilityHint(row.detail)
        .accessibilityAction(named: "Entfernen") { controller.removeItems([item]) }
    }
    /// Loads the law versions the entries refer to (offline store) for the
    /// original text and provision names.
    private func loadDocuments() async {
        for item in entries {
            let key = key(item)
            guard documents[key] == nil, !failed.contains(key), let law = item.payload["lawId"]?.string,
                  let entry = laws.entries.first(where: { $0.id == law }) else { continue }
            do { documents[key] = try await laws.document(entry, version: item.payload["versionId"]?.string) }
            catch { failed.insert(key) }
        }
    }
}
