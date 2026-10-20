import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import NotebookCore

/// Native page navigation beside the editor. The owner controls visibility and
/// width so toggling the sidebar never replaces the drawing canvas.
struct PageSidebarView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: EditorModel
    @Binding var selectedPageID: UUID?
    var onBack: () -> Void
    var onCollapse: () -> Void
    var onSelect: (() -> Void)? = nil
    var onMargins: ((UUID) -> Void)? = nil
    @StateObject private var cache = PageThumbnailCache()
    @State private var editMode: EditMode = .inactive
    @State private var showingTrash = false
    @State private var addingPage: AddRequest?
    @State private var dropTarget: UUID?
    @State private var selectedTab: SidebarTab = .pages
    @State private var filter: PageFilter = .all
    @State private var scrollRequest = 0

    private enum SidebarTab: String, CaseIterable, Identifiable {
        case pages = "Seiten", outline = "Inhalt"
        var id: Self { self }
    }
    private enum PageFilter: String, CaseIterable, Identifiable {
        case all = "Alle Seiten", bookmarks = "Lesezeichen"
        var id: Self { self }
    }
    private var visiblePages: [(index: Int, page: Page)] {
        model.notebook.pages.enumerated().compactMap { index, page in
            filter == .all || page.bookmarked == true ? (index, page) : nil
        }
    }

    private struct AddRequest: Identifiable {
        let id = UUID()
        let anchor: UUID
        let position: PageInsertionPosition
    }
    private struct Insertion {
        let anchor: UUID
        let before: Bool
    }
    private var canEdit: Bool { model.writable && !model.mutationsPaused && !model.busy }
    private var deletedCount: Int { model.notebook.deletedPages?.count ?? 0 }
    private var currentPageIndex: Int { model.notebook.pages.firstIndex { $0.id == selectedPageID } ?? min(model.pageIndex, model.notebook.pages.count - 1) }
    private var currentPage: Page { model.notebook.pages[currentPageIndex] }
    private func selectPage(_ id: UUID) { selectedPageID = id; model.selectPage(id) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Menu {
                    Button("Notizbücher", systemImage: "books.vertical", action: onBack)
                        .disabled(model.busy)
                    Button(editMode.isEditing ? "Anordnen beenden" : "Seiten anordnen", systemImage: "arrow.up.arrow.down") {
                        withAnimation(NotyMotion.panel(reduceMotion)) {
                            selectedTab = .pages; filter = .all
                            editMode = editMode.isEditing ? .inactive : .active
                        }
                    }.disabled(!canEdit)
                    Button("Seite hinzufügen", systemImage: "plus") {
                        addingPage = AddRequest(anchor: currentPage.id, position: .after)
                    }.disabled(!canEdit)
                    Button("Seitenpapierkorb (\(deletedCount))", systemImage: "trash") { showingTrash = true }
                        .disabled(!canEdit)
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
                        .notyGlass()
                }.accessibilityLabel("Seitenmenü")
                Spacer(minLength: 4)
                Text("Seiten").font(.headline)
                Spacer(minLength: 4)
                Button(action: onCollapse) {
                    Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle())
                        .notyGlass()
                }.accessibilityLabel("Seitenleiste einklappen")
            }.padding(12)
            Picker("Seitenbereich", selection: $selectedTab) {
                ForEach(SidebarTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }.pickerStyle(.segmented).padding(.horizontal, 16).padding(.bottom, 12)
            .onChange(of: selectedTab) { _, tab in if tab == .outline { editMode = .inactive } }
            if selectedTab == .pages && !editMode.isEditing {
                HStack {
                    Menu {
                        ForEach(PageFilter.allCases) { choice in
                            Button {
                                filter = choice
                            } label: {
                                if choice == filter { Label(choice.rawValue, systemImage: "checkmark") }
                                else { Text(choice.rawValue) }
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(filter.rawValue).font(.subheadline.weight(.semibold))
                            Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                        }.padding(.horizontal, 14).padding(.vertical, 9).notyGlass()
                    }
                    Spacer()
                }.padding(.horizontal, 16).padding(.bottom, 8)
            }
            if editMode.isEditing {
                HStack {
                    Text("Alle Seiten anordnen").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button("Fertig") { withAnimation(NotyMotion.panel(reduceMotion)) { editMode = .inactive } }
                }.padding(.horizontal, 16).padding(.bottom, 8)
            }
            GeometryReader { geometry in
                let count = geometry.size.width >= 260 ? 2 : 1
                let width = max(72, (geometry.size.width - 40 - CGFloat(count - 1) * 20) / CGFloat(count))
                ScrollViewReader { proxy in
                    ZStack {
                        if selectedTab == .outline {
                            outlineList
                        } else if editMode.isEditing {
                            reorderList
                        } else if filter == .bookmarks && visiblePages.isEmpty {
                            ContentUnavailableView("Keine Lesezeichen", systemImage: "bookmark",
                                                   description: Text("Markiere eine Seite über das Lesezeichensymbol in der Vorschau."))
                        } else {
                            ScrollView {
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 20, alignment: .top), count: count),
                                          alignment: .leading, spacing: 24) {
                                    ForEach(visiblePages, id: \.page.id) { entry in
                                        draggablePage(entry.page, index: entry.index)
                                            .id(entry.page.id)
                                    }
                                    insertionCard(height: width * 842 / 595)
                                }.padding(.horizontal, 20).padding(.vertical, 12)
                            }
                        }
                    }
                    .onChange(of: currentPage.id) { _, id in
                        guard selectedTab == .pages, filter == .all, !editMode.isEditing else { return }
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                    }
                    .onChange(of: scrollRequest) { _, _ in
                        withAnimation(NotyMotion.panel(reduceMotion)) { proxy.scrollTo(currentPage.id, anchor: .center) }
                    }
                }
            }
            HStack {
                Button("Seite \(currentPageIndex + 1) von \(model.notebook.pages.count)") {
                    selectedTab = .pages; filter = .all
                    scrollRequest += 1
                }.font(.caption).frame(minHeight: 44).contentShape(Rectangle()).accessibilityLabel("Zur aktuellen Seite in der Seitenleiste")
                Spacer()
                Button { showingTrash = true } label: {
                    Label("\(deletedCount)", systemImage: "trash").font(.caption).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }.accessibilityLabel("Seitenpapierkorb, \(deletedCount) Seiten").disabled(!canEdit)
            }.padding(.horizontal, 16)
        }
        .animation(NotyMotion.panel(reduceMotion), value: selectedTab)
        .animation(NotyMotion.panel(reduceMotion), value: filter)
        .background(Color(white: 0.065))
        .environment(\.colorScheme, .dark)
        .sheet(isPresented: $showingTrash) {
            PageTrashView(model: model, cache: cache)
        }
        .sheet(item: $addingPage) { request in
            AddPageSheet(position: request.position, enabled: canEdit, defaults: model.notebook.appearance,
                         onPaper: { style, color, geometry, position in
                let placement = placement(anchor: request.anchor, position: position)
                model.insertPaper(style, color: color, relativeTo: placement.anchor, before: placement.before, geometry: geometry)
                addingPage = nil
            }, onPDF: { url, margins, position in
                let placement = placement(anchor: request.anchor, position: position)
                model.insertPDF(url, relativeTo: placement.anchor, before: placement.before, writingArea: margins)
                addingPage = nil
            }, onError: { model.error = $0 })
        }
    }

    @ViewBuilder
    private var outlineList: some View {
        if model.pdfOutline.isEmpty {
            ContentUnavailableView("Kein PDF-Inhaltsverzeichnis", systemImage: "list.bullet.indent",
                                   description: Text("Die enthaltenen PDFs haben kein Inhaltsverzeichnis mit erreichbaren Seiten."))
        } else {
            List(model.pdfOutline) { item in
                NotebookOutlineRow(item: item, selectedPage: currentPage.id) { id in
                    guard canEdit else { return }
                    selectPage(id); onSelect?()
                }
                .listRowBackground(Color.clear)
            }.listStyle(.plain).scrollContentBackground(.hidden)
                .disabled(!canEdit)
        }
    }

    private var reorderList: some View {
        List {
            ForEach(Array(model.notebook.pages.enumerated()), id: \.element.id) { index, page in
                HStack(spacing: 12) {
                    PageThumbnail(page: page, source: model.sourcePage(for: page), cache: cache)
                        .frame(width: 48, height: 68)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    Text("Seite \(index + 1)").font(.subheadline)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Seite \(index + 1)\(page.id == currentPage.id ? ", aktuell" : "")\(page.bookmarked == true ? ", Lesezeichen" : "")")
                .id(page.id)
                .listRowBackground(Color.clear)
            }
            .onMove { indices, offset in
                guard canEdit else { return }
                var ids = model.notebook.pages.map(\.id)
                ids.move(fromOffsets: indices, toOffset: offset)
                model.reorderPages(ids)
            }
            .moveDisabled(!canEdit)
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .environment(\.editMode, $editMode)
    }

    @ViewBuilder
    private func draggablePage(_ page: Page, index: Int) -> some View {
        if filter == .all {
            reorderablePage(page, index: index)
        } else {
            pageRow(page, index: index)
        }
    }

    private func reorderablePage(_ page: Page, index: Int) -> some View {
        pageRow(page, index: index)
            .draggable(dragPayload(page.id))
            .dropDestination(for: String.self) { items, _ in
                guard canEdit, items.count == 1,
                      let id = draggedPage(items[0]), id != page.id,
                      let destination = model.notebook.pages.firstIndex(where: { $0.id == page.id }) else { return false }
                model.movePage(id, to: destination)
                return true
            } isTargeted: { targeted in
                if targeted { dropTarget = page.id }
                else if dropTarget == page.id { dropTarget = nil }
            }
    }

    private func insertionCard(height: CGFloat) -> some View {
        Button {
            addingPage = AddRequest(anchor: currentPage.id, position: .end)
        } label: {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.accentColor.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .overlay(Image(systemName: "plus").font(.title2).foregroundStyle(Color.accentColor))
                .frame(height: height)
                .padding(3)
        }
        .accessibilityLabel("Seite am Ende hinzufügen")
        .disabled(!canEdit)
        .dropDestination(for: String.self) { items, _ in
            guard canEdit, items.count == 1, let id = draggedPage(items[0]) else { return false }
            model.movePage(id, to: model.notebook.pages.count - 1)
            return true
        }
    }

    private func pageRow(_ page: Page, index: Int) -> some View {
        let selected = currentPage.id == page.id
        return VStack(spacing: 6) {
            Button {
                guard canEdit else { return }
                selectPage(page.id)
                onSelect?()
            } label: {
                PageThumbnail(page: page, source: model.sourcePage(for: page), cache: cache, selected: selected)
                    .aspectRatio(page.previewAspectRatio, contentMode: .fit)
                    .frame(maxHeight: 224)
                    .frame(maxWidth: .infinity)
                    .padding(3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Seite \(index + 1)\(selected ? ", aktuell" : "")\(page.bookmarked == true ? ", Lesezeichen" : "")")
            .disabled(!canEdit)
            .overlay(alignment: .topTrailing) {
                Button {
                    model.toggleBookmark(page.id)
                } label: {
                    Image(systemName: page.bookmarked == true ? "bookmark.fill" : "bookmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(page.bookmarked == true ? Color.accentColor : Color.white)
                        .frame(width: 28, height: 28).notyGlass()
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel(page.bookmarked == true ? "Lesezeichen auf Seite \(index + 1) entfernen" : "Lesezeichen auf Seite \(index + 1) setzen")
                .disabled(!canEdit).padding(7)
            }
            HStack {
                Text("\(index + 1)")
                    .font(.caption.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.accentColor : Color.primary)
                if model.cutPageID == page.id {
                    Image(systemName: "scissors").font(.caption).foregroundStyle(Color.accentColor)
                        .accessibilityLabel("Zum Verschieben vorgemerkt")
                }
                Spacer()
                Menu {
                    pageActions(page, index: index)
                } label: {
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold)).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Aktionen für Seite \(index + 1)")
                .disabled(!canEdit)
            }.padding(.horizontal, 3)
        }
        .background(dropTarget == page.id ? Color.accentColor.opacity(0.15) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .contextMenu { pageActions(page, index: index).disabled(!canEdit) }
    }

    @ViewBuilder
    private func pageActions(_ page: Page, index: Int) -> some View {
        Button("Seite hinzufügen", systemImage: "plus") {
            addingPage = AddRequest(anchor: page.id, position: .after)
        }
        Button("Ausschneiden", systemImage: "scissors") { model.copyPage(page.id, cut: true) }
        Button("Kopieren", systemImage: "doc.on.doc") { model.copyPage(page.id) }
        Button("Einfügen", systemImage: "doc.on.clipboard") { model.pastePage(after: page.id) }.disabled(model.copiedPage == nil)
        Button("Duplizieren", systemImage: "doc.on.doc") { model.duplicatePage(page.id) }
        Button("Seite leeren", systemImage: "clear", role: .destructive) { model.clearPage(page.id) }
        Button("Löschen", systemImage: "trash", role: .destructive) { model.trashPage(page.id) }
            .disabled(model.notebook.pages.count <= 1)
        Divider()
        Button(page.bookmarked == true ? "Lesezeichen entfernen" : "Lesezeichen setzen",
               systemImage: page.bookmarked == true ? "bookmark.slash" : "bookmark") { model.toggleBookmark(page.id) }
        if let onMargins, model.sourcePage(for: page) != nil {
            Button("PDF-Schreibplatz", systemImage: "arrow.up.left.and.arrow.down.right") { onMargins(page.id) }
        }
        Menu("Verschieben", systemImage: "arrow.up.arrow.down") {
            Button("An den Anfang", systemImage: "arrow.up.to.line") { model.movePage(page.id, to: 0) }
                .disabled(index == 0)
            Button("Eine Seite nach oben", systemImage: "arrow.up") { model.movePage(page.id, to: index - 1) }
                .disabled(index == 0)
            Button("Eine Seite nach unten", systemImage: "arrow.down") { model.movePage(page.id, to: index + 1) }
                .disabled(index == model.notebook.pages.count - 1)
            Button("Ans Ende", systemImage: "arrow.down.to.line") {
                model.movePage(page.id, to: model.notebook.pages.count - 1)
            }.disabled(index == model.notebook.pages.count - 1)
        }
    }

    private func placement(anchor: UUID, position: PageInsertionPosition) -> Insertion {
        Insertion(anchor: position == .end ? (model.notebook.pages.last?.id ?? anchor) : anchor,
                  before: position == .before)
    }

    private func dragPayload(_ page: UUID) -> String {
        "noty-page:\(model.notebook.id.uuidString):\(page.uuidString)"
    }
    private func draggedPage(_ payload: String) -> UUID? {
        let parts = payload.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "noty-page",
              UUID(uuidString: String(parts[1])) == model.notebook.id,
              let id = UUID(uuidString: String(parts[2])),
              model.notebook.pages.contains(where: { $0.id == id }) else { return nil }
        return id
    }
}

private struct NotebookOutlineRow: View {
    let item: NotebookOutlineItem
    let selectedPage: UUID
    let onSelect: (UUID) -> Void

    var body: some View {
        Group {
            if let children = item.children, !children.isEmpty {
                DisclosureGroup {
                    ForEach(children) { child in
                        NotebookOutlineRow(item: child, selectedPage: selectedPage, onSelect: onSelect)
                    }
                } label: { title }
            } else { title }
        }
    }

    @ViewBuilder
    private var title: some View {
        if let pageID = item.pageID {
            Button { onSelect(pageID) } label: {
                Text(item.title).font(.subheadline).multilineTextAlignment(.leading)
                    .foregroundStyle(pageID == selectedPage ? Color.accentColor : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
        } else {
            Text(item.title).font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

enum PageInsertionPosition: String, CaseIterable, Identifiable {
    case before = "Vor dieser", after = "Nach dieser", end = "Letzte Seite"
    var id: Self { self }
}

struct AddPageSheet: View {
    @State private var position: PageInsertionPosition
    @State private var paperColor: PaperColor = .white
    let enabled: Bool
    @State private var format: PaperFormat = .a4
    @State private var landscape = false
    @State private var choosingPDF = false
    @State private var writingSpace = true
    @State private var writingLeft = false
    @State private var writingFraction = 1.0
    @State private var writingPaper: PaperStyle = .blank
    @State private var writingColor: PaperColor = .dark
    let onPaper: (PaperStyle, PaperColor, PDFPageGeometry, PageInsertionPosition) -> Void
    /// Picked PDF (security-scoped temporary URL) with the chosen writing space.
    let onPDF: (URL, PageMargins?, PageInsertionPosition) -> Void
    var onError: (String) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss

    init(position: PageInsertionPosition, enabled: Bool, defaults: NotebookAppearance? = nil,
         onPaper: @escaping (PaperStyle, PaperColor, PDFPageGeometry, PageInsertionPosition) -> Void,
         onPDF: @escaping (URL, PageMargins?, PageInsertionPosition) -> Void,
         onError: @escaping (String) -> Void = { _ in }) {
        _position = State(initialValue: position)
        _paperColor = State(initialValue: defaults?.color ?? .white)
        _format = State(initialValue: defaults?.format ?? .a4)
        _landscape = State(initialValue: defaults?.landscape ?? false)
        // Writing space beside a PDF follows the notebook's standard paper.
        _writingPaper = State(initialValue: defaults?.paper ?? .blank)
        _writingColor = State(initialValue: defaults?.color ?? .dark)
        self.enabled = enabled; self.onPaper = onPaper; self.onPDF = onPDF; self.onError = onError
    }

    /// Everything on one screen: position, paper templates and PDF import.
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Position der neuen Seite", selection: $position) {
                        ForEach(PageInsertionPosition.allCases) { position in
                            Text(position.rawValue).tag(position)
                        }
                    }.pickerStyle(.segmented)
                    HStack(spacing: 12) {
                        Picker("Größe", selection: $format) { ForEach(PaperFormat.allCases, id: \.self) { Text($0.title).tag($0) } }
                            .pickerStyle(.segmented)
                        Toggle("Quer", isOn: $landscape).fixedSize()
                        Picker("Papierfarbe", selection: $paperColor) {
                            Text("Weiß").tag(PaperColor.white)
                            Text("Dunkel").tag(PaperColor.dark)
                        }.pickerStyle(.segmented).frame(maxWidth: 170)
                    }
                    HStack(alignment: .top, spacing: 12) {
                        template(.blank, title: "Blanko")
                        template(.lined, title: "Liniert")
                        template(.grid, title: "Kariert")
                    }
                    Divider().padding(.vertical, 4)
                    VStack(alignment: .leading, spacing: 10) {
                        Label("PDF einfügen", systemImage: "doc.badge.plus").font(.headline)
                        PDFWritingSpaceOptions(enabled: $writingSpace, left: $writingLeft, fraction: $writingFraction,
                                               paper: $writingPaper, color: $writingColor)
                        Button {
                            choosingPDF = true
                        } label: {
                            HStack {
                                Text("PDF aus Dateien wählen").font(.headline)
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                            }.padding(14).frame(maxWidth: .infinity, minHeight: 52)
                                // The whole row (including the gap left by the
                                // spacer and the padding) is the tap target.
                                .contentShape(RoundedRectangle(cornerRadius: 16))
                                .notyGlass()
                        }.buttonStyle(.plain)
                            .contentShape(RoundedRectangle(cornerRadius: 16))
                            .accessibilityHint("Öffnet die Dateiauswahl.")
                        Text("Die Originaldatei wird vollständig in dieses Notizbuch kopiert.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(20)
                .disabled(!enabled)
            }
            .background(Color(white: 0.065))
            .navigationTitle("Seite hinzufügen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Schließen", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                }
            }
            .fileImporter(isPresented: $choosingPDF, allowedContentTypes: [.pdf]) { result in
                switch result {
                case .success(let url):
                    onPDF(url, PDFWritingSpaceOptions.margins(enabled: writingSpace, left: writingLeft, fraction: writingFraction,
                        paper: writingPaper, color: writingColor), position)
                    dismiss()
                case .failure(let error): onError(error.localizedDescription)
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func template(_ style: PaperStyle, title: String) -> some View {
        Button {
            var settings = NotebookAppearance(); settings.format = format; settings.landscape = landscape
            onPaper(style, paperColor, settings.geometry, position)
        } label: {
            VStack(spacing: 12) {
                PaperTemplatePreview(style: style, color: paperColor)
                    .frame(maxWidth: .infinity).frame(height: 120)
                    .background(paperColor == .dark ? Color(white: 0.12) : .white)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.15)))
                Text(title).font(.subheadline).foregroundStyle(.primary)
            }.frame(maxWidth: .infinity)
        }.buttonStyle(.plain).accessibilityLabel("\(title) einfügen, \(position.rawValue)")
    }
}

private struct PaperTemplatePreview: View {
    let style: PaperStyle
    let color: PaperColor
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { ProgressView() }
        }
        .clipped().allowsHitTesting(false)
        .task(id: "\(style.rawValue)-\(color == .dark ? "dark" : "white")") {
            await Task.yield()
            guard !Task.isCancelled else { return }
            image = PDFExporter.paperPDF(style: style, size: .a4, color: color).page(at: 0)?
                .thumbnail(of: CGSize(width: 168, height: 238), for: .mediaBox)
        }
    }
}

private struct PageTrashView: View {
    @ObservedObject var model: EditorModel
    let cache: PageThumbnailCache
    @Environment(\.dismiss) private var dismiss
    private var deleted: [DeletedPage] { model.notebook.deletedPages ?? [] }
    var body: some View {
        NavigationStack {
            Group {
                if deleted.isEmpty {
                    ContentUnavailableView("Keine gelöschten Seiten", systemImage: "trash",
                                           description: Text("Gelöschte Seiten dieses Notizbuchs können hier wiederhergestellt werden."))
                } else {
                    List(deleted.sorted { $0.deletedAt > $1.deletedAt }, id: \.page.id) { entry in
                        HStack(spacing: 16) {
                            PageThumbnail(page: entry.page, source: model.sourcePage(for: entry.page), cache: cache)
                                .frame(width: 74, height: 104)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Ehemals Seite \(entry.originalIndex + 1)").font(.headline)
                                if entry.reason != nil {
                                    Text(entry.reason == .cleared ? "Vor dem Leeren gesichert" : "Gesicherter Seitenstand").font(.subheadline.weight(.semibold))
                                    Text(model.notebook.marginRestoreTarget(for: entry) != nil
                                         ? "Setzt die bestehende Seite auf diesen Stand zurück. Ihr aktueller Stand wird vorher hier im Papierkorb gesichert."
                                         : "Die ursprüngliche Seite ist nicht mehr verfügbar. Dieser Stand wird als zusätzliche Seite wiederhergestellt.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Text(entry.deletedAt, format: .dateTime.day().month().hour().minute())
                                    .font(.caption).foregroundStyle(.secondary)
                                if !entry.page.searchableText.isEmpty {
                                    Text(String(entry.page.searchableText.prefix(100))).font(.caption).lineLimit(2)
                                }
                                Button(entry.reason != nil ? "Seitenstand wiederherstellen" : "Wiederherstellen",
                                       systemImage: "arrow.uturn.backward") {
                                    model.restorePage(entry.page.id)
                                }.disabled(!model.writable || model.mutationsPaused || model.busy)
                            }
                        }.padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Seitenpapierkorb")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        }
    }
}
