import SwiftUI
import UIKit
import Combine
import ImageIO
import OSLog
import NotebookCore

/// PDFs and pictures shared to noty („Teilen“ → noty dev/noty, „In noty
/// öffnen“, AirDrop). Each file is copied completely into the app-own
/// incoming folder at once (security-scoped access and a coordinated read
/// only for that copy, the provider path is never kept), checked by its
/// content, then offered one after another in the filing sheet above
/// whatever is on screen: library, open notebook or a dialog. Nothing is
/// written into a notebook or the library before the user files it there.
/// The copy stays until it was filed or discarded, also over a restart.
@MainActor
enum IncomingFiling {
    nonisolated static let inbox = IncomingInbox(directory: URL.applicationSupportDirectory
        .appendingPathComponent("NotyIncoming", isDirectory: true))
    private static var queue = IncomingQueue()
    private static weak var library: LibraryModel?
    private static weak var workspaces: WorkspaceAppModel?
    private static var defaults: @MainActor () -> NotebookAppearance? = { nil }
    private static var listedLeftovers = false
    private static var presenting = false
    private static var receiving: Task<Void, Never>?

    /// Everything but the noty file types goes here; the content decides.
    static func handles(_ url: URL) -> Bool {
        let kind = url.pathExtension.lowercased()
        return url.isFileURL && kind != "notylibrary" && kind != "notymaterial" && !NotyFile.notebookExtensions.contains(kind)
    }

    /// The library of the current area (re-attached after an area switch).
    /// The first attach also offers copies an earlier run left waiting.
    static func attach(library: LibraryModel, workspaces: WorkspaceAppModel, defaults: @escaping @MainActor () -> NotebookAppearance?) {
        self.library = library; self.workspaces = workspaces; self.defaults = defaults
        if !listedLeftovers {
            listedLeftovers = true
            Task {
                let leftovers = await Task.detached(priority: .utility) { inbox.items() }.value
                for item in leftovers { queue.enqueue(item) }
                pump()
            }
        } else { pump() }
    }

    /// Copies at once, one file after the other (the provider's access may
    /// end soon); the offer follows when the library is ready.
    static func receive(_ url: URL) async {
        let previous = receiving
        let next = Task { @MainActor in
            await previous?.value
            await copyIn(url)
        }
        receiving = next
        await next.value
    }

    private static func copyIn(_ url: URL) async {
        let name = url.lastPathComponent
        do {
            let stage = try inbox.newStage()
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let item = try await Task.detached(priority: .userInitiated) { () throws -> IncomingItem in
                do {
                    // A coordinated read makes the file provider download an iCloud file first.
                    try CoordinatedBackupFiles().reading(url, metadataOnly: false) { source in
                        _ = try BoundedFile.copy(from: source, to: stage, limit: IncomingFileType.maximumBytes)
                    }
                } catch LibraryArchiveError.archiveTooLarge {
                    inbox.discardStage(stage); throw IncomingFileError.unsupported(.tooLarge)
                } catch { inbox.discardStage(stage); throw error }
                return try inbox.adopt(stage: stage, originalName: name)
            }.value
            IncomingBackup.removeFromInbox(url)
            queue.enqueue(item)
            pump()
        } catch let error as IncomingFileError {
            IncomingBackup.removeFromInbox(url)
            TopAlert.show("Datei nicht übernommen", "„\(name)“: " + (error.errorDescription ?? "") + " Es wurde nichts verändert.")
        } catch {
            TopAlert.show("Datei nicht lesbar", "„\(name)“ konnte nicht in noty kopiert werden. Es wurde nichts verändert. Bitte erneut teilen.")
        }
    }

    /// Offers the next waiting file once nothing else is offered. On a cold
    /// launch the library loads first and may reopen the last notebook as a
    /// full-screen cover: the sheet is presented above that, not under it.
    private static func pump() {
        guard !presenting, !queue.isEmpty else { return }
        presenting = true
        Task {
            var waited = 0
            while library?.ready != true, waited < 150 { try? await Task.sleep(for: .milliseconds(100)); waited += 1 }
            // A launch may still reopen the last notebook (library busy, then
            // the cover appears and attaches its workspace): present above it.
            waited = 0
            while let library, library.busy && !library.backgroundBusy || library.opened != nil && library.workspace == nil, waited < 50 {
                try? await Task.sleep(for: .milliseconds(100)); waited += 1
            }
            try? await Task.sleep(for: .milliseconds(800))
            guard let library, library.ready, let item = queue.next() else { presenting = false; return }
            let model = IncomingFilingModel(item: item, url: inbox.contentURL(item), library: library,
                                            areaTitle: workspaces?.title ?? "Meine Bibliothek", defaults: defaults())
            let host = UIHostingController(rootView: IncomingFilingView(model: model).modifier(AccentTint()))
            host.modalPresentationStyle = .formSheet
            host.isModalInPresentation = true
            host.overrideUserInterfaceStyle = .dark
            host.preferredContentSize = CGSize(width: 620, height: 780)
            model.close = { [weak host] keepCopy, then in
                let done = {
                    if !keepCopy { Task.detached(priority: .utility) { inbox.remove(item.id) } }
                    queue.finish(item.id)
                    presenting = false
                    Task { @MainActor in
                        await then?()
                        pump()
                    }
                }
                if let host, host.presentingViewController != nil { host.dismiss(animated: true) { done() } } else { done() }
            }
            guard await present(host) else {
                // Nothing to present on (scene in the background): offered again later.
                queue.postponeCurrent()
                presenting = false
                Task { try? await Task.sleep(for: .seconds(2)); pump() }
                return
            }
        }
    }

    /// `present` fails silently above a controller that is just going away;
    /// tried a few times like `TopAlert`.
    private static func present(_ host: UIViewController) async -> Bool {
        for _ in 0..<10 {
            if let top = TopAlert.top, !top.isBeingDismissed {
                top.present(host, animated: true)
                try? await Task.sleep(for: .milliseconds(350))
                if host.presentingViewController != nil { return true }
            } else { try? await Task.sleep(for: .milliseconds(350)) }
        }
        return false
    }
}

enum IncomingFilingError: LocalizedError {
    case libraryBusy, editorBusy
    /// The pages are in the open editor, its save was not confirmed.
    /// `retrying`: the editor retries by itself; `reason`: a permanent error.
    case notSaved(pageIDs: [UUID], retrying: Bool, reason: String?)
    var errorDescription: String? {
        switch self {
        case .libraryBusy: "Die Bibliothek ist gerade beschäftigt. Bitte gleich noch einmal versuchen."
        case .editorBusy: "Das Heft ist gerade beschäftigt (Speichern, Import oder Schließen). Bitte gleich noch einmal versuchen."
        case .notSaved(_, let retrying, let reason):
            retrying ? "Die Seiten sind im geöffneten Heft, aber noch nicht gespeichert; noty versucht es automatisch weiter."
                : "Die Seiten sind im geöffneten Heft, konnten aber nicht gespeichert werden" + (reason.map { ": \($0)" } ?? ".")
        }
    }
}

/// The checked PDF of an incoming file (a picture becomes a one-page PDF on
/// the way of the normal import, `ImagePagePDF`). A PDF keeps its exact bytes.
struct IncomingPDF: Sendable {
    let data: Data
    let geometries: [PDFPageGeometry]

    static func load(_ url: URL) async throws -> IncomingPDF {
        try await withImportTimeLimit {
            try await Task.detached(priority: .userInitiated) { () throws -> IncomingPDF in
                guard FileManager.default.fileExists(atPath: url.path) else { throw IncomingFileError.missing }
                let (data, geometries) = try PDFImportCheck.pages(of: LibraryModel.readPDF(url))
                return IncomingPDF(data: data, geometries: geometries)
            }.value
        }
    }
}

/// Header of the sheet: thumbnail and what the file is, read off the UI actor.
struct IncomingPreview: @unchecked Sendable {
    var image: CGImage?
    var details: String
    var problem: String?

    nonisolated static func read(_ url: URL, item: IncomingItem) -> IncomingPreview {
        let size = ByteCountFormatter.string(fromByteCount: Int64(item.byteCount), countStyle: .file)
        switch item.kind {
        case .pdf:
            guard let pdf = CGPDFDocument(url as CFURL) else {
                return IncomingPreview(details: size, problem: StorageError.unreadablePDF.localizedDescription)
            }
            guard pdf.isUnlocked || pdf.unlockWithPassword("") else {
                return IncomingPreview(details: size, problem: StorageError.lockedPDF.localizedDescription)
            }
            let count = pdf.numberOfPages
            let details = NotyText.count(count, "Seite", "Seiten") + " · " + size
            guard count > 0 else { return IncomingPreview(details: details, problem: StorageError.unreadablePDF.localizedDescription) }
            let problem = count > 500 ? StorageError.tooManyPDFPages(count).localizedDescription : nil
            return IncomingPreview(image: pdf.page(at: 1).flatMap(thumbnail), details: details, problem: problem)
        case .image:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
                return IncomingPreview(details: size, problem: ImageImportError.invalid.localizedDescription)
            }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            var details = "1 Seite · " + size
            if let width = properties?[kCGImagePropertyPixelWidth] as? Int, let height = properties?[kCGImagePropertyPixelHeight] as? Int {
                let rotated = [5, 6, 7, 8].contains(properties?[kCGImagePropertyOrientation] as? Int ?? 1)
                details = "\(rotated ? height : width) × \(rotated ? width : height) Pixel · " + size
            }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: 360]
            return IncomingPreview(image: CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary), details: details)
        }
    }

    private nonisolated static func thumbnail(_ page: CGPDFPage) -> CGImage? {
        let box = page.getBoxRect(.cropBox)
        let rotated = page.rotationAngle % 180 != 0
        let width = rotated ? box.height : box.width, height = rotated ? box.width : box.height
        guard width > 0, height > 0 else { return nil }
        let scale = 360 / max(width, height)
        let target = CGRect(x: 0, y: 0, width: max(1, (width * scale).rounded()), height: max(1, (height * scale).rounded()))
        guard let context = CGContext(data: nil, width: Int(target.width), height: Int(target.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(target)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: target, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        return context.makeImage()
    }
}

@MainActor
final class IncomingFilingModel: ObservableObject {
    enum Mode: Hashable { case newNotebook, append }
    enum Position: Hashable { case end, afterCurrent }
    struct Done {
        let title: String
        let message: String
        let openLabel: String?
        let open: (@MainActor () async -> Void)?
        let keepCopy: Bool
        /// A leftover copy that was filed before: it may still be filed again on purpose.
        var offersRefiling = false
    }

    let item: IncomingItem
    let url: URL
    let library: LibraryModel
    let areaTitle: String
    @Published var title: String
    @Published var mode = Mode.newNotebook
    @Published var folder: UUID?
    @Published var notebook: UUID?
    @Published var position = Position.end
    @Published var search = ""
    @Published var expanded: Set<UUID>
    @Published var error: String?
    @Published var working: String?
    @Published var done: Done?
    @Published var preview: IncomingPreview?
    /// The same file again (waiting twice, or filed before), or an earlier
    /// attempt whose pages were not saved: shown prominently, never dropped.
    @Published var notice: String?
    @Published var extraSpace = true
    @Published var left = false
    @Published var fraction = 1.0
    @Published var paper: PaperStyle
    @Published var color: PaperColor
    /// Ends the offer: dismisses the sheet, removes the copy unless kept,
    /// then runs the follow-up („Öffnen“) and offers the next file.
    var close: (_ keepCopy: Bool, _ then: (@MainActor () async -> Void)?) -> Void = { _, _ in }
    private let recentKey: String
    /// The lists follow the library (a folder created, a background refresh).
    private var libraryChanges: AnyCancellable?

    init(item: IncomingItem, url: URL, library: LibraryModel, areaTitle: String, defaults: NotebookAppearance?) {
        self.item = item; self.url = url; self.library = library; self.areaTitle = areaTitle
        title = IncomingNaming.suggestedTitle(fileName: item.originalName, taken: library.snapshot.activeNotebookTitles())
        paper = defaults?.paper ?? .blank
        color = defaults?.color ?? .dark
        expanded = library.expandedFolders
        recentKey = StableSettingsKey.key("incomingFolders", scope: StableDefaults.scope(library.root))
        // An open notebook is the likely target of „An Heft anhängen“.
        notebook = library.workspace.flatMap { workspace in
            let id = workspace.activePane == 1 ? workspace.secondaryID ?? workspace.primaryDocument.id : workspace.primaryDocument.id
            return IncomingTargets.appendable(library.snapshot).contains { $0.id == id } ? id : nil
        }
        if notebook != nil { position = .afterCurrent }
        libraryChanges = library.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var snapshot: LibrarySnapshot { library.snapshot }
    var rememberedFolders: [UUID?] { IncomingTargets.decode(UserDefaults.standard.stringArray(forKey: recentKey) ?? []) }

    /// Notebooks open in either view, active view first.
    var openNotebooks: [NotebookCore.LibraryItem] {
        guard let workspace = library.workspace else { return [] }
        var ids = [workspace.primaryDocument.id]
        if let second = workspace.secondaryID, second != ids[0] { workspace.activePane == 1 ? ids.insert(second, at: 0) : ids.append(second) }
        let appendable = IncomingTargets.appendable(snapshot)
        return ids.compactMap { id in appendable.first { $0.id == id } }
    }
    /// The open model of the chosen notebook, if either view holds it.
    var openModel: EditorModel? {
        guard let notebook, let workspace = library.workspace, workspace.holds(notebook) else { return nil }
        return workspace.model(for: notebook)
    }
    var canFile: Bool {
        guard working == nil, done == nil, preview?.problem == nil else { return false }
        switch mode {
        case .newNotebook: return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .append: return notebook.map { id in IncomingTargets.appendable(snapshot).contains { $0.id == id } } ?? false
        }
    }
    private var writingArea: PageMargins? {
        PDFWritingSpaceOptions.margins(enabled: extraSpace, left: left, fraction: fraction, paper: paper, color: color)
    }

    func loadPreview() async {
        let url = url, item = item
        preview = await Task.detached(priority: .userInitiated) { IncomingPreview.read(url, item: item) }.value
    }

    /// Before the choice: a copy whose filing was committed (noted in its
    /// `item.json`) is shown as already filed, not as new; one whose pages
    /// went into an open notebook without a confirmed save counts as filed
    /// once those pages stand in the committed notebook. A second delivery
    /// of the same bytes is pointed out.
    func checkEarlierFiling() async {
        let item = item
        var record = item.filing
        if let current = record, current.status == .unsaved,
           let committed = try? await library.committedNotebook(current.notebookID).0 {
            let resolved = current.resolved(committedPageIDs: committed.pages.map(\.id))
            if resolved.status == .filed {
                record = resolved
                do { _ = try await Task.detached(priority: .utility) { try IncomingFiling.inbox.record(item.id, filing: resolved) }.value }
                catch { Self.log.error("Ablagevermerk in item.json fehlgeschlagen: \(error.localizedDescription, privacy: .public)") }
            }
        }
        if let record, record.status == .filed {
            done = Done(title: "Bereits abgelegt", message: IncomingFilingText.alreadyFiled(record, date: NotyText.statusDate(record.filedAt)),
                        openLabel: nil, open: nil, keepCopy: false, offersRefiling: true)
            return
        }
        if let record, record.status == .unsaved {
            notice = "Ein früherer Versuch hat diese Datei in „\(record.notebookTitle)“ eingefügt, aber nicht gespeichert; im gespeicherten Heft stehen die Seiten nicht. Sie kann jetzt erneut abgelegt werden."
        }
        let duplicate = await Task.detached(priority: .utility) { IncomingFiling.inbox.duplicate(of: item) }.value
        if let duplicate {
            let text = IncomingFilingText.duplicate(duplicate, date: NotyText.statusDate)
            notice = notice.map { $0 + "\n" + text } ?? text
        }
    }

    /// „Trotzdem erneut ablegen“ for a copy that was filed before.
    func refile() {
        guard done?.offersRefiling == true, !answered else { return }
        done = nil
    }

    /// Noted in `item.json` right after the commit, before the copy is
    /// removed: after a crash in between the copy is not offered as new.
    private func noteFiling(_ status: IncomingFilingRecord.Status, notebook: UUID, title: String, pageIDs: [UUID], verified: Bool = true) async {
        let record = IncomingFilingRecord(status: status, notebookID: notebook, notebookTitle: title, pageIDs: pageIDs,
                                          filedAt: Date(), verified: verified)
        let id = item.id
        do { _ = try await Task.detached(priority: .userInitiated) { try IncomingFiling.inbox.record(id, filing: record) }.value }
        catch {
            // The filing itself is committed and stays; only the crash guard is
            // missing (a crash before the copy goes would offer it again).
            Self.log.error("Ablagevermerk in item.json fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
        }
    }
    private static let log = Logger(subsystem: "de.la.noty", category: "incoming-filing")

    /// One answer per offer (a second tap during the dismissal is no second one).
    private var answered = false
    func discard() { guard working == nil, !answered else { return }; answered = true; close(false, nil) }
    func finish() { guard let done, !answered else { return }; answered = true; close(done.keepCopy, nil) }
    func openResult() { guard let done, !answered else { return }; answered = true; close(done.keepCopy, done.open) }

    func createFolder(_ name: String) async {
        guard working == nil else { return }
        working = "Ordner wird angelegt …"; error = nil
        defer { working = nil }
        do {
            let parent = folder
            folder = try await library.createIncomingFolder(name, parent: parent)
            if let parent { expanded.insert(parent) }
            search = ""
        } catch { self.error = "Ordner nicht angelegt: \(error.localizedDescription)" }
    }

    func file() async {
        guard canFile else { return }
        working = mode == .newNotebook ? "Heft wird angelegt …" : "Seiten werden angehängt …"; error = nil
        defer { working = nil }
        do {
            let pdf = try await IncomingPDF.load(url)
            switch mode {
            case .newNotebook: try await fileAsNotebook(pdf)
            case .append: try await append(pdf)
            }
        } catch IncomingFilingError.notSaved(let pageIDs, let retrying, let reason) {
            let target = snapshot.items.first { $0.id == notebook }?.title ?? "Heft"
            if let notebook { await noteFiling(.unsaved, notebook: notebook, title: target, pageIDs: pageIDs) }
            done = Done(title: "Noch nicht gespeichert", message: IncomingFilingText.notSaved(title: target, retrying: retrying, reason: reason),
                        openLabel: nil, open: nil, keepCopy: true)
        } catch {
            // Every error that reaches here was thrown before a commit.
            self.error = "Nicht abgelegt: \(error.localizedDescription) Heft und Bibliothek sind unverändert, die empfangene Kopie bleibt erhalten."
        }
    }

    private func fileAsNotebook(_ pdf: IncomingPDF) async throws {
        let (entry, pageIDs) = try await library.fileIncomingNotebook(pdf, title: title, parent: folder, writingArea: writingArea)
        await noteFiling(.filed, notebook: entry.id, title: entry.title, pageIDs: pageIDs)
        UserDefaults.standard.set(IncomingTargets.encode(IncomingTargets.remember(folder, in: rememberedFolders)), forKey: recentKey)
        let place = IncomingTargets.path(of: folder, in: snapshot)
        let library = library
        let open: (@MainActor () async -> Void)?, label: String?
        if let workspace = library.workspace {
            label = "In zweiter Ansicht öffnen"
            open = { [weak workspace] in
                if let workspace, let document = await library.openDocument(entry.id) { await workspace.openSecondary(document) }
            }
        } else if library.opened == nil {
            label = "Öffnen"
            open = { if let item = library.snapshot.items.first(where: { $0.id == entry.id }) { await library.open(item) } }
        } else { label = nil; open = nil }
        done = Done(title: "Als Heft abgelegt", message: "„\(entry.title)“ liegt jetzt in \(place) · \(NotyText.count(pdf.geometries.count, "Seite", "Seiten")).",
                    openLabel: label, open: open, keepCopy: false)
    }

    private func append(_ pdf: IncomingPDF) async throws {
        guard let id = notebook, let target = IncomingTargets.appendable(snapshot).first(where: { $0.id == id }) else {
            throw LibraryError.unavailable
        }
        let pages = NotyText.count(pdf.geometries.count, "Seite", "Seiten")
        let library = library
        if let workspace = library.workspace, workspace.holds(id) {
            // Open in a view: its editor model is the only writer (undo, autosave).
            guard !workspace.closing, let model = workspace.model(for: id) else { throw IncomingFilingError.editorBusy }
            let placement: IncomingPlacement = position == .afterCurrent ? .after(model.page.id) : .end
            let (ids, undoable) = try await model.insertIncomingPDF(pdf.data, geometries: pdf.geometries, placement: placement, writingArea: writingArea)
            await noteFiling(.filed, notebook: id, title: target.title, pageIDs: ids)
            let place = position == .afterCurrent ? "hinter der aktuellen Seite" : "am Ende"
            // Undo is promised only when the editor really recorded a step.
            done = Done(title: "Angehängt", message: IncomingFilingText.appendedToOpenNotebook(pages: pages, place: place, title: target.title, undoable: undoable),
                        openLabel: "Zur ersten neuen Seite", open: { [weak workspace, weak model] in
                            guard let workspace, let model, let first = ids.first else { return }
                            if workspace.secondary === model && workspace.primary !== model { workspace.activePane = 1 }
                            else if workspace.primary === model { workspace.activePane = 0 }
                            model.showPage(first)
                        }, keepCopy: false)
        } else {
            let result = try await library.appendIncoming(pdf, to: id, writingArea: writingArea)
            let ids = result.pageIDs
            // Committed: from here on the pages are in the notebook.
            await noteFiling(.filed, notebook: id, title: target.title, pageIDs: ids, verified: result.verified)
            let open: (@MainActor () async -> Void)?, label: String?
            if let workspace = library.workspace {
                label = "In zweiter Ansicht öffnen"
                open = { [weak workspace] in
                    guard let workspace, var document = await library.openDocument(id) else { return }
                    document.preferredPageID = ids.first
                    await workspace.openSecondary(document)
                }
            } else if library.opened == nil {
                label = "Öffnen"
                open = { if let item = library.snapshot.items.first(where: { $0.id == id }) { await library.open(item, pageID: ids.first) } }
            } else { label = nil; open = nil }
            if result.verified {
                done = Done(title: "Angehängt", message: "\(pages) am Ende von „\(target.title)“ eingefügt und gespeichert.",
                            openLabel: label, open: open, keepCopy: false)
            } else {
                done = Done(title: "Angehängt – bitte prüfen", message: IncomingFilingText.committedUnverified(pages: pages, title: target.title),
                            openLabel: label, open: open, keepCopy: true)
            }
        }
    }
}

/// The filing sheet: dark, built like the library lists, only for filing.
struct IncomingFilingView: View {
    @ObservedObject var model: IncomingFilingModel
    @State private var naming = false
    @State private var folderName = ""

    var body: some View {
        NavigationStack {
            Group {
                if let done = model.done { doneView(done) } else { chooser }
            }
            .navigationTitle(model.done == nil ? "Ablegen" : "Abgelegt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.done == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        // Bewusst ohne Esc: Abbrechen verwirft die einzige Kopie auf dem iPad.
                        Button("Abbrechen", role: .cancel) { model.discard() }.disabled(model.working != nil)
                            .help("Verwirft die empfangene Kopie. Hefte und Bibliothek bleiben unverändert.")
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await model.checkEarlierFiling() }
        .task { await model.loadPreview() }
        .alert("Neuer Ordner", isPresented: $naming) {
            TextField("Name", text: $folderName)
            Button("Abbrechen", role: .cancel) { }
            Button("Anlegen") { let name = folderName; Task { await model.createFolder(name) } }
                .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: { Text("Wird in „\(model.folder.flatMap { id in model.snapshot.items.first { $0.id == id }?.title } ?? IncomingTargets.rootTitle)“ angelegt.") }
    }

    private var chooser: some View {
        List {
            if let notice = model.notice {
                Section {
                    Label(notice, systemImage: "doc.on.doc.fill").foregroundStyle(.orange).font(.callout.weight(.medium))
                }
            }
            header
            Section {
                Picker("Ablage", selection: $model.mode) {
                    Text("Als neues Heft").tag(IncomingFilingModel.Mode.newNotebook)
                    Text("An Heft anhängen").tag(IncomingFilingModel.Mode.append)
                }.pickerStyle(.segmented)
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(model.mode == .newNotebook ? "Ordner suchen" : "Heft suchen", text: $model.search)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if !model.search.isEmpty {
                        Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).accessibilityLabel("Suche leeren")
                    }
                }
            } footer: { Text("Bereich: \(model.areaTitle)") }
            if model.mode == .newNotebook { folderSections } else { notebookSections }
            Section {
                PDFWritingSpaceOptions(enabled: $model.extraSpace, left: $model.left, fraction: $model.fraction,
                                       paper: $model.paper, color: $model.color)
            } header: { Text("Schreibplatz") } footer: {
                Text(model.item.kind == .image
                     ? "Das Bild wird eine eigene Seite (Fotos höchstens 4096 Pixel), wie beim Import. 100 % entspricht einer normalen Seitenbreite."
                     : "Das PDF bleibt unverändert als Quelle erhalten; neue Seiten bekommen eigene IDs. 100 % entspricht einer normalen Seitenbreite.")
            }
            if let error = model.error {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            }
        }
        .listStyle(.insetGrouped)
        .disabled(model.working != nil)
        .safeAreaInset(edge: .bottom) { actionBar }
    }

    private var header: some View {
        Section {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06))
                    if let image = model.preview?.image {
                        Image(decorative: image, scale: 1).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 4)).padding(4)
                    } else if model.preview == nil { ProgressView() }
                    else { Image(systemName: model.item.kind == .pdf ? "doc.richtext" : "photo").font(.title).foregroundStyle(.secondary) }
                }
                .frame(width: 84, height: 112)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Name", text: $model.title).font(.headline)
                        .disabled(model.mode == .append)
                        .accessibilityLabel("Name des neuen Hefts")
                    Text([model.item.typeLabel, model.preview?.details].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("„\(model.item.originalName)“").font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    if let problem = model.preview?.problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: Folders

    @ViewBuilder private var folderSections: some View {
        let snapshot = model.snapshot
        if model.search.isEmpty {
            let pinned = IncomingTargets.favoriteFolders(snapshot, pinOrder: model.library.pinOrder)
            if !pinned.isEmpty {
                Section("Angeheftet") { ForEach(pinned, id: \.rowID) { folderRow($0, showsPath: true) } }
            }
            let recent = IncomingTargets.recentFolders(snapshot, remembered: model.rememberedFolders)
            if !recent.isEmpty {
                Section("Zuletzt verwendet") { ForEach(recent, id: \.rowID) { folderRow($0, showsPath: true) } }
            }
            Section {
                ForEach(IncomingTargets.folderTree(snapshot, expanded: model.expanded), id: \.rowID) { folderRow($0, showsPath: false) }
                newFolderButton
            } header: { Text("Ordner") }
        } else {
            let hits = IncomingTargets.folders(snapshot, matching: model.search)
            Section("Treffer") {
                ForEach(hits, id: \.rowID) { folderRow($0, showsPath: true) }
                if hits.isEmpty { Text("Kein Ordner mit diesem Namen.").foregroundStyle(.secondary) }
                newFolderButton
            }
        }
    }

    private var newFolderButton: some View {
        Button { folderName = model.search; naming = true } label: { Label("Neuer Ordner …", systemImage: "folder.badge.plus") }
    }

    private func folderRow(_ row: IncomingFolderRow, showsPath: Bool) -> some View {
        let nested = row.id.map { id in model.snapshot.children(of: id).contains(where: \.isFolder) } ?? false
        return HStack(spacing: 8) {
            if !showsPath && row.depth > 0 {
                Color.clear.frame(width: CGFloat(row.depth - 1) * 18, height: 1)
                Button {
                    guard let id = row.id else { return }
                    if model.expanded.contains(id) { model.expanded.remove(id) } else { model.expanded.insert(id) }
                } label: {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(row.id.map(model.expanded.contains) == true ? 90 : 0))
                        .frame(width: 18).opacity(nested ? 1 : 0)
                }
                .buttonStyle(.plain).disabled(!nested)
                .accessibilityLabel(row.id.map(model.expanded.contains) == true ? "Zuklappen" : "Aufklappen")
            }
            Button { model.folder = row.id } label: {
                HStack {
                    Image(systemName: row.id == nil ? "tray.full" : "folder").foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).foregroundStyle(.primary)
                        if showsPath, row.id != nil { Text(row.path).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer()
                    if model.folder == row.id {
                        Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityLabel("Gewählt")
                    }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
    }

    // MARK: Notebooks

    @ViewBuilder private var notebookSections: some View {
        let snapshot = model.snapshot
        if model.search.isEmpty {
            let open = model.openNotebooks
            if !open.isEmpty { Section("Geöffnet") { ForEach(open) { notebookRow($0) } } }
            let pinned = IncomingTargets.favoriteNotebooks(snapshot, pinOrder: model.library.pinOrder)
            if !pinned.isEmpty { Section("Angeheftet") { ForEach(pinned) { notebookRow($0) } } }
            let recent = IncomingTargets.recentNotebooks(snapshot)
            if !recent.isEmpty { Section("Zuletzt verwendet") { ForEach(recent) { notebookRow($0) } } }
        }
        let all = IncomingTargets.notebooks(snapshot, matching: model.search)
        Section(model.search.isEmpty ? "Alle Hefte" : "Treffer") {
            ForEach(all) { notebookRow($0) }
            if all.isEmpty { Text(model.search.isEmpty ? "Noch keine Hefte." : "Kein Heft mit diesem Namen.").foregroundStyle(.secondary) }
        }
        if model.notebook != nil {
            Section {
                Picker("Position", selection: $model.position) {
                    Text("Ans Ende").tag(IncomingFilingModel.Position.end)
                    Text("Hinter aktuelle Seite").tag(IncomingFilingModel.Position.afterCurrent)
                }
                .pickerStyle(.segmented)
                .disabled(model.openModel == nil)
            } header: { Text("Position") } footer: {
                if let open = model.openModel, open.notebook.pages.indices.contains(open.pageIndex) {
                    Text(IncomingFilingText.openNotebookFooter(page: open.pageIndex + 1, of: open.notebook.pages.count,
                                                                undoable: open.notebook.pageOperationsAreUndoable))
                } else {
                    Text("„Hinter aktuelle Seite“ gibt es nur für ein geöffnetes Heft.")
                }
            }
            .onChange(of: model.notebook, initial: true) { _, _ in if model.openModel == nil { model.position = .end } }
        }
    }

    private func notebookRow(_ item: NotebookCore.LibraryItem) -> some View {
        Button { model.notebook = item.id } label: {
            HStack {
                Image(systemName: item.librarySymbol(filled: false)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).foregroundStyle(.primary)
                    Text(IncomingTargets.path(of: item.parentID, in: model.snapshot)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if model.notebook == item.id { Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityLabel("Gewählt") }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    // MARK: Actions

    private var actionBar: some View {
        VStack(spacing: 6) {
            if let working = model.working {
                HStack(spacing: 8) { ProgressView(); Text(working).foregroundStyle(.secondary) }
            }
            Button {
                Task { await model.file() }
            } label: {
                Text(model.mode == .newNotebook ? "Als neues Heft ablegen" : "An Heft anhängen")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canFile)
            .keyboardShortcut(.defaultAction)
            Text(model.mode == .newNotebook
                 ? "Ziel: \(IncomingTargets.path(of: model.folder, in: model.snapshot))"
                 : model.notebook.flatMap { id in model.snapshot.items.first { $0.id == id } }.map { "Ziel: „\($0.title)“" } ?? "Bitte ein Heft wählen.")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.bar)
    }

    private func doneView(_ done: IncomingFilingModel.Done) -> some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: done.keepCopy ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 52)).foregroundStyle(done.keepCopy ? .orange : .green)
                .accessibilityHidden(true)
            Text(done.title).font(.title2.weight(.semibold))
            Text(done.message).multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal, 32)
            HStack(spacing: 12) {
                if let label = done.openLabel {
                    Button(label) { model.openResult() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
                if done.offersRefiling {
                    Button("Trotzdem erneut ablegen") { model.refile() }.buttonStyle(.bordered)
                        .help("Fügt die Datei ein zweites Mal ein.")
                }
                Button(done.offersRefiling ? "Kopie entfernen" : "Fertig") { model.finish() }.buttonStyle(.bordered)
                    .keyboardShortcut(done.offersRefiling ? nil : .cancelAction)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
