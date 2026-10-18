import SwiftUI
import PDFKit
import NotebookCore

struct OpenNotebook: Identifiable {
    let id: UUID
    let directory: URL
    let title: String
    let isRestored: Bool
    var preferredPageID: UUID?
    var searchBounds: PageRect?
}

@MainActor
final class LibraryModel: ObservableObject {
    let root: URL
    private let store: LibraryStore
    @Published var snapshot = LibrarySnapshot()
    @Published var ready = false
    @Published var busy = false
    @Published var error: String?
    @Published var warning: String?
    @Published var opened: OpenNotebook?
    @Published var restoredCopies: [RestoredNotebook] = []
    @Published var backupStatus = "Noch kein Bibliotheksbackup exportiert"

    init(root: URL = URL.documentsDirectory.appendingPathComponent("Noty", isDirectory: true)) {
        self.root = root
        store = LibraryStore(root: root)
        if let date = UserDefaults.standard.object(forKey: "noty.libraryBackup.\(root.path)") as? Date {
            backupStatus = "Letzter Bibliotheksexport: \(date.formatted(date: .abbreviated, time: .shortened))"
        }
        Task { await refresh() }
    }

    var editorBackup: (() async -> Data?)?

    func libraryBackup(editorsPaused: Bool = false) async -> Data? {
        guard ready, !busy, opened == nil || editorsPaused else { return nil }
        busy = true
        defer { busy = false }
        backupStatus = "Bibliotheksbackup wird vorbereitet …"
        do {
            let bundle = try await store.backupBundle()
            // Framework validation happens before calling this a usable export.
            for document in bundle.documents { try EditorModelValidation.validate(document) }
            let bytes = try await Task.detached { try LibraryArchive.encode(bundle) }.value
            backupStatus = "Bibliotheksbackup vollständig vorbereitet"
            return bytes
        } catch {
            backupStatus = "Bibliotheksbackup fehlgeschlagen"
            self.error = error.localizedDescription
            return nil
        }
    }

    func libraryBackupExported() {
        let date = Date()
        UserDefaults.standard.set(date, forKey: "noty.libraryBackup.\(root.path)")
        backupStatus = "Bibliotheksdatei exportiert: \(date.formatted(date: .omitted, time: .shortened))"
    }

    func editorChoices() async -> [OpenNotebook] {
        var choices: [OpenNotebook] = []
        for item in snapshot.items where !item.isFolder && !snapshot.isTrashed(item.id) {
            if let directory = try? await store.documentURL(id: item.id) {
                choices.append(OpenNotebook(id: item.id, directory: directory, title: item.title,
                    isRestored: item.source == .restored))
            }
        }
        return choices
    }

    func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let result = try await store.load()
            snapshot = result.snapshot
            ready = true
            var notices: [String] = []
            if result.recovered { notices.append("Bibliotheksindex aus vorherigem Stand geladen. Zuordnungen bitte prüfen.") }
            if result.unreadableDocuments > 0 {
                notices.append("\(result.unreadableDocuments) Heftverzeichnis(se) konnten nicht gelesen werden. Dateien bleiben erhalten.")
            }
            warning = notices.isEmpty ? nil : notices.joined(separator: " ")
            let catalog = try await NotebookRepository(directory: root).restoredCopies()
            restoredCopies = catalog.notebooks.compactMap { copy -> RestoredNotebook? in
                guard let item = snapshot.items.first(where: { $0.id == copy.id }), !snapshot.isTrashed(copy.id) else { return nil }
                var result = copy; result.title = item.title; return result
            }
        } catch { self.error = error.localizedDescription }
    }

    private func change(_ action: () async throws -> LibrarySnapshot) async {
        guard ready, !busy, opened == nil else { return }
        busy = true
        defer { busy = false }
        do { snapshot = try await action() }
        catch { self.error = error.localizedDescription }
    }

    func artwork(for id: UUID, cache: PageThumbnailCache) async throws -> (NotebookAppearance?, UIImage?) {
        let document = try await store.previewDocument(id: id)
        try Task.checkCancellation()
        if document.appearance?.coverEnabled == true { return (document.appearance, nil) }
        guard let page = document.pages.first else { throw StorageError.invalidDocument }
        let pdf: PDFDocument?
        let index: Int
        if let reference = page.pdfReference {
            pdf = document.pdfSources?.first(where: { $0.id == reference.sourceID }).flatMap { PDFDocument(data: $0.data) }
            index = reference.pageIndex
        } else { pdf = document.pdf.flatMap { PDFDocument(data: $0) }; index = 0 }
        return (nil, try cache.image(page: page, source: pdf?.page(at: index)))
    }
    func createFolder(_ title: String, parent: UUID?) async {
        await change { try await store.createFolder(title: title, parentID: parent) }
    }
    func createNotebook(_ title: String, appearance: NotebookAppearance = NotebookAppearance(), parent: UUID?) async -> Bool {
        guard ready, !busy, opened == nil else { return false }
        busy = true; defer { busy = false }
        do {
            let notebook = try Notebook.blank(title: title, appearance: appearance)
            snapshot = try await store.createDocument(notebook, parentID: parent)
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func rename(_ id: UUID, title: String) async { await change { try await store.rename(id, title: title) } }
    func move(_ id: UUID, to parent: UUID?) async { await change { try await store.move(id, to: parent) } }
    func trash(_ id: UUID) async { await change { try await store.trash(id) } }
    func restore(_ id: UUID) async { await change { try await store.restore(id) } }
    func favorite(_ item: NotebookCore.LibraryItem) async { await change { try await store.setFavorite(item.id, value: !item.favorite) } }
    func reorder(_ ids: [UUID], parent: UUID?) async { await change { try await store.reorder(ids, parentID: parent) } }

    func open(_ item: NotebookCore.LibraryItem, pageID: UUID? = nil, searchBounds: PageRect? = nil) async {
        guard ready, !busy, opened == nil, !item.isFolder else { return }
        busy = true
        defer { busy = false }
        do {
            let url = try await store.documentURL(id: item.id)
            snapshot = try await store.markOpened(item.id)
            opened = OpenNotebook(id: item.id, directory: url, title: item.title,
                                  isRestored: item.source == .restored, preferredPageID: pageID, searchBounds: searchBounds)
        } catch { self.error = error.localizedDescription }
    }

    func importPDF(_ url: URL, parent: UUID?, writingArea: PageMargins? = nil) async {
        guard ready, !busy, opened == nil else { return }
        busy = true
        let access = url.startAccessingSecurityScopedResource()
        defer {
            if access { url.stopAccessingSecurityScopedResource() }
            busy = false
        }
        do {
            let data = try await Task.detached { try Self.readPDF(url) }.value
            guard let pdf = PDFDocument(data: data), !pdf.isLocked, (1...500).contains(pdf.pageCount) else {
                throw StorageError.invalidDocument
            }
            var document = Notebook()
            document.title = String(url.deletingPathExtension().lastPathComponent.prefix(120))
            document.pdf = data
            document.pages = try (0..<pdf.pageCount).map { index in
                guard let source = pdf.page(at: index)?.pageRef else { throw StorageError.invalidDocument }
                var page = Page(); page.geometry = try PDFPageGeometry(source); return page
            }
            if let writingArea {
                for page in document.pages {
                    let margins = try writingArea.scaled(from: .init(width: 1, height: 1), to: page.geometry?.displaySize ?? .a4)
                    try document.setMargins(margins, pageIDs: [page.id])
                }
            }
            snapshot = try await store.createDocument(document, parentID: parent)
        } catch { self.error = "PDF-Import fehlgeschlagen: \(error.localizedDescription)" }
    }

    func importBackup(_ url: URL, parent: UUID?) async {
        guard ready, !busy, opened == nil else { return }
        busy = true
        let access = url.startAccessingSecurityScopedResource()
        defer {
            if access { url.stopAccessingSecurityScopedResource() }
            busy = false
        }
        do {
            // Use the existing staged, independently validated restore path.
            let repository = NotebookRepository(directory: root)
            let prepared = try await repository.prepareRestore(from: url)
            try EditorModelValidation.validate(prepared.document)
            let restored = try await repository.commitRestore(prepared)
            snapshot = try await store.load().snapshot
            if let parent { snapshot = try await store.move(restored.id, to: parent) }
        } catch { self.error = "Wiederherstellung fehlgeschlagen: \(error.localizedDescription)" }
    }

    nonisolated static func readPDF(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            guard data.count + chunk.count <= 20_000_000 else {
                throw NSError(domain: "noty", code: 1, userInfo: [NSLocalizedDescriptionKey: "PDFs dürfen derzeit höchstens 20 MB groß sein."])
            }
            data.append(chunk)
        }
        return data
    }
}

struct LibraryNotebookView: View {
    @StateObject private var workspace: EditorWorkspace
    @ObservedObject var library: LibraryModel
    init(document: OpenNotebook, root: URL, library: LibraryModel) {
        self.library = library
        _workspace = StateObject(wrappedValue: EditorWorkspace(document: document, root: root))
    }
    var body: some View { EditorWorkspaceView(workspace: workspace, library: library) }
}
