import SwiftUI
import PDFKit
import NotebookCore

/// Search in the learning material (docs/LERNFELDER.md): topics, video
/// lessons, script pages and norms. Each result opens its video on the
/// platform (in the browser, with the user's own login) or its script page
/// here; with `onPin` it can be pinned to the lesson („Festhalten“).
struct MaterialSearchSheet: View {
    @ObservedObject private var materials = MaterialLibrary.shared
    let initialQuery: String
    /// The Lernfeld of the lesson: its hits rank higher.
    let field: Int?
    /// „Festhalten“ for the lesson; nil: search only.
    var pinned: Set<String> = []
    var onPin: ((MaterialLibrary.Match, CalendarMaterialRef) -> Void)?
    /// Opened from a notebook: script pages can go into it (`nil` page: the whole script).
    var onInsertScript: ((URL, Int?) -> Void)?
    /// Opened from a notebook: closes this sheet before a script opens beside the notebook.
    var onScriptBeside: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var searchActive = false
    @State private var script: ScriptRequest?
    @State private var results: [MaterialLibrary.Match] = []
    @State private var searchedFor = ""

    /// Without a search term and with a Lernfeld: its chapters to browse (scripts, video lessons).
    private var browsing: [(package: MaterialStore.Installed, chapter: MaterialChapter)] {
        guard let field, query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return materials.packages.flatMap { package in
            package.catalog.fields.filter { $0.number == field }.flatMap(\.chapters).map { (package, $0) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(browsing, id: \.chapter.key) { entry in
                    MaterialChapterRow(package: entry.package, chapter: entry.chapter, field: field ?? 0) { request in script = request }
                }
                ForEach(results) { result in
                    MaterialResultRow(result: result, catalog: materials.package(result.package)?.catalog,
                                      isPinned: pinned.contains(result.package + "/" + result.hit.id),
                                      onScript: { open(result) },
                                      onNorm: { query = $0 },
                                      onPin: onPin.map { pin in {
                                          guard let ref = materials.reference(for: result) else { return }
                                          materials.learn(query, result: result)
                                          pin(result, ref)
                                      } })
                }
            }
            .overlay {
                if materials.packages.isEmpty {
                    ContentUnavailableView {
                        Label("Keine Materialien", systemImage: "books.vertical")
                    } description: {
                        Text("Ein Materialpaket (.notymaterial) in der Dateien-App antippen oder unter Einstellungen › Kalender › Materialien hinzufügen.")
                    }
                } else if query.trimmingCharacters(in: .whitespaces).isEmpty, browsing.isEmpty {
                    ContentUnavailableView("Material suchen", systemImage: "magnifyingglass",
                                           description: Text("Thema, Lektion oder Paragraf, z. B. „Lieferung“, „Fahrtenbuch“ oder „§ 15 UStG“."))
                } else if results.isEmpty, searchedFor == query {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, isPresented: $searchActive, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Thema, Lektion oder §")
            // Typing pauses briefly before searching; a newer query replaces an older result.
            .task(id: query) {
                let text = query
                guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { results = []; searchedFor = text; return }
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                let found = await materials.search(text, field: field)
                guard !Task.isCancelled, text == query else { return }
                results = found; searchedFor = text
            }
            .task {
                materials.load()
                query = initialQuery
                try? await Task.sleep(for: .milliseconds(150))
                if initialQuery.isEmpty, field == nil { searchActive = true }
            }
            .navigationTitle(field.map { "Material · LF \($0)" } ?? "Material")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fertig") { dismiss() } } }
            .sheet(item: $script) { request in MaterialScriptSheet(request: request, onInsert: onInsertScript, onBeside: onScriptBeside) }
        }
        .preferredColorScheme(.dark)
    }

    private func open(_ result: MaterialLibrary.Match) {
        guard let (url, title) = materials.script(result) else { return }
        script = ScriptRequest(url: url, title: title, page: result.hit.pages?.lowerBound ?? 1)
    }
}

/// One chapter of a Lernfeld while browsing: its script, and its video lessons to unfold.
struct MaterialChapterRow: View {
    let package: MaterialStore.Installed
    let chapter: MaterialChapter
    let field: Int
    let openScript: (ScriptRequest) -> Void
    @Environment(\.openURL) private var openURL
    @State private var expanded = false

    private var scriptURL: URL? {
        guard let script = chapter.script else { return nil }
        let url = package.scriptURL(script)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    private var title: String { "LF \(field) · \(chapter.label) \(chapter.title)" }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(chapter.lessons) { lesson in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(lesson.title).font(.subheadline).lineLimit(2)
                        if let pages = lesson.pages, let first = pages.first {
                            Text(pages.count > 1 && pages[1] != first ? "Skript S. \(first)–\(pages[1])" : "Skript S. \(first)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    if let url = scriptURL, let first = lesson.pages?.first {
                        Button { openScript(ScriptRequest(url: url, title: title, page: first)) } label: { Image(systemName: "doc.richtext") }
                            .buttonStyle(.borderless).accessibilityLabel("Skript ab Seite \(first)")
                    }
                    if let link = package.catalog.lessonLink(lesson.id) {
                        Button { openURL(link) } label: { Image(systemName: "play.fill") }
                            .buttonStyle(.borderless).accessibilityLabel("Video „\(lesson.title)“")
                    }
                }
                .frame(minHeight: 40)
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(chapter.title).font(.body).lineLimit(2)
                    Text(chapter.label + (chapter.lessons.isEmpty ? "" : " · \(NotyText.count(chapter.lessons.count, "Video", "Videos"))"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let url = scriptURL {
                    Button { openScript(ScriptRequest(url: url, title: title, page: 1)) } label: { Label("Skript", systemImage: "doc.richtext") }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
    }
}

struct ScriptRequest: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let title: String
    let page: Int
}

/// One result: title, place, norms, and the actions.
struct MaterialResultRow: View {
    let result: MaterialLibrary.Match
    let catalog: MaterialCatalog?
    var isPinned = false
    let onScript: () -> Void
    var onNorm: ((String) -> Void)?
    var onPin: (() -> Void)?
    @Environment(\.openURL) private var openURL

    var body: some View {
        let hit = result.hit
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: hit.kind == .lesson ? "play.rectangle" : hit.kind == .unit ? "text.book.closed" : "doc.text")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(hit.title).font(.body.weight(.medium))
                    Text(catalog.map { MaterialLibrary.detail(hit, in: $0) + " · " + hit.chapterTitle } ?? "LF \(hit.field)")
                        .font(.caption).foregroundStyle(.secondary)
                    if let detail = hit.detail, detail != hit.title {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            if !hit.norms.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(hit.norms, id: \.self) { norm in
                            Button(norm) { onNorm?(norm) }
                                .font(.caption2).buttonStyle(.bordered).controlSize(.mini)
                                .accessibilityHint("Nach dieser Vorschrift suchen")
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                if let link = hit.lessonID.flatMap({ catalog?.lessonLink($0) }) {
                    Button {
                        openURL(link)
                    } label: {
                        Label(hit.seconds.map { "Video \(MaterialLesson(id: hit.lessonID!, title: "", seconds: $0, order: 0).duration ?? "")" } ?? "Video",
                              systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)
                }
                if hit.pages != nil {
                    Button { onScript() } label: { Label("Skript", systemImage: "doc.richtext") }.buttonStyle(.bordered)
                }
                Spacer(minLength: 0)
                if let onPin {
                    Button { onPin() } label: {
                        Label(isPinned ? "Festgehalten" : "Festhalten", systemImage: isPinned ? "pin.fill" : "pin")
                    }
                    .buttonStyle(.borderedProminent).disabled(isPinned)
                }
            }
            .font(.callout).controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}

/// A script PDF at a page (read only).
struct MaterialScriptSheet: View {
    let request: ScriptRequest
    /// From a notebook: „Ins Heft einfügen“ (page 1-based; nil: the whole script).
    var onInsert: ((URL, Int?) -> Void)? = nil
    /// Before the script opens beside the notebook: the sheets above it close.
    var onBeside: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var currentPage: Int
    @State private var pageCount = 0

    init(request: ScriptRequest, onInsert: ((URL, Int?) -> Void)? = nil, onBeside: (() -> Void)? = nil) {
        self.request = request; self.onInsert = onInsert; self.onBeside = onBeside
        _currentPage = State(initialValue: request.page)
    }

    var body: some View {
        NavigationStack {
            MaterialPDFView(url: request.url, page: request.page) { page, count in currentPage = page; pageCount = count }
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(request.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Fertig") { dismiss() } }
                    if let onInsert {
                        // Beside the open notebook, to mark and write on (its own notebook in „Skripte“).
                        if let beside = ScriptBeside.shared.open {
                            ToolbarItem(placement: .primaryAction) {
                                Button { onBeside?(); beside(request.url, request.title, currentPage); dismiss() } label: {
                                    Label("Neben dem Heft öffnen", systemImage: "rectangle.split.2x1")
                                }
                                .accessibilityHint("Zum Markieren und Schreiben, das eigene Heft bleibt unverändert")
                            }
                        }
                        ToolbarItem(placement: .primaryAction) {
                            Menu {
                                Section("Ins Heft einfügen") {
                                    Button("Diese Seite (S. \(currentPage))", systemImage: "doc.badge.plus") { onInsert(request.url, currentPage); dismiss() }
                                    Button(pageCount > 0 ? "Ganzes Skript (\(pageCount) Seiten)" : "Ganzes Skript", systemImage: "doc.on.doc") {
                                        onInsert(request.url, nil); dismiss()
                                    }
                                }
                            } label: {
                                Label("Mehr", systemImage: "ellipsis.circle")
                            }
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: request.url) { Image(systemName: "square.and.arrow.up") }
                            .accessibilityLabel("Skript teilen")
                    }
                }
        }
        .preferredColorScheme(.dark)
    }
}

struct MaterialPDFView: UIViewRepresentable {
    let url: URL
    /// 1-based.
    let page: Int
    /// The page shown (1-based) and the page count, whenever it changes.
    var onPage: ((Int, Int) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(onPage: onPage) }

    final class Coordinator: NSObject {
        let onPage: ((Int, Int) -> Void)?
        init(onPage: ((Int, Int) -> Void)?) { self.onPage = onPage }
        @objc func changed(_ note: Notification) {
            guard let view = note.object as? PDFView, let document = view.document, let page = view.currentPage else { return }
            onPage?(document.index(for: page) + 1, document.pageCount)
        }
    }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .black
        view.document = PDFDocument(url: url)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.changed(_:)),
                                               name: .PDFViewPageChanged, object: view)
        DispatchQueue.main.async {
            go(view)
            if let document = view.document, let current = view.currentPage {
                onPage?(document.index(for: current) + 1, document.pageCount)
            }
        }
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {}

    private func go(_ view: PDFView) {
        guard let document = view.document, document.pageCount > 0 else { return }
        let index = min(max(page - 1, 0), document.pageCount - 1)
        if let target = document.page(at: index) { view.go(to: target) }
    }
}

/// Settings › Kalender › Materialien: installed packages, add, remove.
struct MaterialSettingsPage: View {
    @ObservedObject private var materials = MaterialLibrary.shared
    @State private var picking = false
    @State private var removing: MaterialStore.Installed?
    @State private var searching = false

    var body: some View {
        Form {
            Section {
                ForEach(materials.packages, id: \.catalog.id) { package in
                    let catalog = package.catalog
                    VStack(alignment: .leading, spacing: 3) {
                        Text(catalog.title).font(.body.weight(.medium))
                        Text("\(catalog.fields.count) Lernfelder · \(catalog.scripts.count) Skripte · "
                             + "\(catalog.fields.reduce(0) { $0 + $1.chapters.reduce(0) { $0 + $1.lessons.count } }) Videolektionen")
                            .font(.caption).foregroundStyle(.secondary)
                        if let created = catalog.created { Text("Stand: \(String(created.prefix(10)))").font(.caption2).foregroundStyle(.secondary) }
                    }
                    .swipeActions { Button("Entfernen", role: .destructive) { removing = package } }
                    .contextMenu { Button("Entfernen", systemImage: "trash", role: .destructive) { removing = package } }
                }
                Button { picking = true } label: { Label("Materialpaket hinzufügen …", systemImage: "plus") }
                    .disabled(materials.importing)
                if !materials.packages.isEmpty {
                    Button { searching = true } label: { Label("Material durchsuchen", systemImage: "magnifyingglass") }
                }
            } header: {
                Text("Materialpakete")
            } footer: {
                Text("Skripte, Videolektionen und Paragrafen einer Lernplattform als Paket (.notymaterial). Sie liegen nur auf diesem iPad, gelten für alle Bereiche und sind nicht Teil der Bibliotheksbackups – die Paketdatei selbst ist die Sicherung. Was du an Stunden festhältst, bleibt auch ohne Paket lesbar.")
            }
        }
        .navigationTitle("Materialien")
        .task { materials.load() }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.notyMaterial]) { result in
            if case .success(let url) = result { Task { await materials.receive(url) } }
        }
        .confirmationDialog("Materialpaket entfernen?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { package in
            Button("„\(package.catalog.title)“ entfernen", role: .destructive) { materials.remove(package.catalog.id) }
        } message: { _ in
            Text("Skripte und Index werden von diesem iPad gelöscht. Hefte, Themen und festgehaltene Einträge bleiben erhalten.")
        }
        .sheet(isPresented: $searching) { MaterialSearchSheet(initialQuery: "", field: nil) }
    }
}
