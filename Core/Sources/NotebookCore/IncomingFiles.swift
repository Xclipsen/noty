import Foundation

/// PDFs and pictures that another app hands to noty („Teilen“ → noty, „In
/// noty öffnen“). They are copied completely into an app-own incoming folder
/// first (`IncomingInbox`), outside every notebook package and library root,
/// then offered one after another (`IncomingQueue`) in the filing sheet. The
/// type is decided by the content, never by the name; the size limit is the
/// one of the normal PDF/picture import (`PDFSource.maximumBytes`).
public enum IncomingFileKind: String, Codable, Sendable {
    case pdf, image
}

public enum IncomingFileType {
    /// The same limit as „PDF oder Bild importieren“ (`LibraryModel.readPDF`).
    public static let maximumBytes = PDFSource.maximumBytes
    /// Enough for the PDF signature (some writers put a few bytes before it)
    /// and every image signature (`ImageFileFormat.headerLength`).
    public static let headerLength = 1024

    public enum Reason: Equatable, Sendable { case empty, video, unknown, tooLarge }

    public enum Decision: Equatable, Sendable {
        case pdf
        case image(ImageFileFormat)
        case unsupported(Reason)
    }

    /// `%PDF-` within the first kilobyte, like `ImagePagePDF.isPDF`.
    public static func isPDF(_ header: Data) -> Bool {
        header.prefix(headerLength).range(of: Data("%PDF-".utf8)) != nil
    }

    /// PDF first (a PDF may start with arbitrary bytes), then still images;
    /// a movie (Live Photo part, screen recording) is refused with its reason.
    public static func decide(header: Data, byteCount: Int) -> Decision {
        guard byteCount > 0, !header.isEmpty else { return .unsupported(.empty) }
        guard byteCount <= maximumBytes else { return .unsupported(.tooLarge) }
        if isPDF(header) { return .pdf }
        switch ImageFileFormat.detect(header) {
        case .video: return .unsupported(.video)
        case .some(let format): return .image(format)
        case nil: return .unsupported(.unknown)
        }
    }
}

public enum IncomingFileError: Error, LocalizedError, Equatable {
    case unsupported(IncomingFileType.Reason)
    case missing
    case notAppendable
    case notebookUnreadable
    /// Another writer (an open editor, another append) holds the package.
    case notebookInUse

    public var errorDescription: String? {
        switch self {
        case .unsupported(.empty): "Die Datei ist leer."
        case .unsupported(.video): "Videos und Live-Photo-Filme können nicht abgelegt werden, nur PDFs und Bilder."
        case .unsupported(.unknown): "Das ist weder ein PDF noch ein Bild, das noty lesen kann."
        case .unsupported(.tooLarge): "PDFs und Bilder dürfen höchstens 100 MB groß sein."
        case .missing: "Die empfangene Kopie ist nicht mehr vorhanden. Bitte die Datei erneut teilen."
        case .notAppendable: "Textdokumente nehmen keine PDF-Seiten auf. Bitte ein Heft wählen."
        case .notebookUnreadable: "Der neueste Stand dieses Hefts ist nicht lesbar. Bitte das Heft öffnen und prüfen; es wurde nichts eingefügt."
        case .notebookInUse: "Das Heft ist gerade in einer Ansicht geöffnet oder wird ergänzt. Bitte gleich noch einmal versuchen; es wurde nichts eingefügt."
        }
    }
}

/// One received file, waiting in the incoming folder until the user files or
/// discards it. `originalName` is only a display/name proposal, never a path.
public struct IncomingItem: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let originalName: String
    public let kind: IncomingFileKind
    /// `ImageFileFormat.rawValue` for pictures.
    public let imageFormat: String?
    public let byteCount: Int
    public let receivedAt: Date
    /// SHA-256 of the received bytes (lowercase hex): the same file delivered
    /// twice is recognised (`IncomingInbox.duplicate`). nil for copies an
    /// older build received.
    public var sha256: String?
    /// Where the file went, written into `item.json` right after the commit
    /// (`IncomingInbox.record`): a copy that is still there after a restart
    /// is then not offered as new again.
    public var filing: IncomingFilingRecord?

    public init(id: UUID = UUID(), originalName: String, kind: IncomingFileKind, imageFormat: String? = nil,
                byteCount: Int, receivedAt: Date, sha256: String? = nil) {
        self.id = id; self.originalName = originalName; self.kind = kind
        self.imageFormat = imageFormat; self.byteCount = byteCount; self.receivedAt = receivedAt
        self.sha256 = sha256
    }

    /// „PDF“, „Bild (HEIC)“ …
    public var typeLabel: String {
        switch kind {
        case .pdf: return "PDF"
        case .image:
            let format = imageFormat.flatMap(ImageFileFormat.init(rawValue:))
            let name: String? = switch format {
            case .heif: "HEIC"
            case .jpeg: "JPEG"
            case .some(let value): value.rawValue.uppercased()
            case nil: nil
            }
            return name.map { "Bild (\($0))" } ?? "Bild"
        }
    }
}

/// The outcome of filing one incoming file.
public struct IncomingFilingRecord: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// Committed (new notebook or appended pages).
        case filed
        /// The pages went into an open notebook whose save was not confirmed:
        /// they are in the notebook only if a later save succeeded.
        case unsaved
    }
    public var status: Status
    public var notebookID: UUID
    public var notebookTitle: String
    /// The new pages (all pages of a new notebook).
    public var pageIDs: [UUID]
    public var filedAt: Date
    /// The commit was read back and matched; false after a failed check.
    public var verified: Bool

    public init(status: Status, notebookID: UUID, notebookTitle: String, pageIDs: [UUID], filedAt: Date, verified: Bool = true) {
        self.status = status; self.notebookID = notebookID; self.notebookTitle = notebookTitle
        self.pageIDs = pageIDs; self.filedAt = filedAt; self.verified = verified
    }

    /// An `unsaved` record whose pages all stand in the committed notebook
    /// (`committedPageIDs`) was saved after all.
    public func resolved(committedPageIDs: some Sequence<UUID>) -> IncomingFilingRecord {
        guard status == .unsaved, !pageIDs.isEmpty, Set(pageIDs).isSubset(of: Set(committedPageIDs)) else { return self }
        var result = self; result.status = .filed; return result
    }
}

/// A file received again: the same bytes are waiting already or were filed
/// before (`IncomingInbox.duplicate`). Shown, never silently dropped.
public enum IncomingDuplicate: Equatable, Sendable {
    case waiting(IncomingItem)
    case filed(IncomingFiledEntry)
}

/// One entry of the inbox's list of filed files (`filed.json`).
public struct IncomingFiledEntry: Codable, Equatable, Sendable {
    public var sha256: String
    public var originalName: String
    public var notebookID: UUID
    public var notebookTitle: String
    public var pageCount: Int
    public var filedAt: Date
}

/// Texts of the filing sheet that depend on what really happened.
public enum IncomingFilingText {
    public static let undoPromise = "Rückgängig im Heft nimmt sie wieder heraus."
    public static let noUndo = "Dieses Heft hat noch das ältere Speicherformat, deshalb nimmt Rückgängig das Einfügen nicht zurück; die Seiten lassen sich in der Seitenleiste wieder löschen."

    /// `undoable`: the open editor recorded an undo step (its return value).
    public static func appendedToOpenNotebook(pages: String, place: String, title: String, undoable: Bool) -> String {
        "\(pages) \(place) von „\(title)“ eingefügt und gespeichert. " + (undoable ? undoPromise : noUndo)
    }

    /// Footer of the position choice for an open notebook.
    public static func openNotebookFooter(page: Int, of count: Int, undoable: Bool) -> String {
        "Aktuelle Seite: \(page) von \(count). Das geöffnete Heft speichert die Seiten selbst" + (undoable ? "; Rückgängig nimmt sie wieder heraus." : ". Rückgängig nimmt das Einfügen bei diesem Heft (älteres Format) nicht zurück.")
    }

    /// The editor holds the pages, its save was not confirmed. `retrying`:
    /// the editor retries by itself (`EditorModel.retryable`).
    public static func notSaved(title: String, retrying: Bool, reason: String?) -> String {
        let state = retrying
            ? "sind aber noch nicht gespeichert; noty versucht es automatisch weiter."
            : "konnten aber nicht gespeichert werden" + (reason.map { ": \($0)" } ?? ".") + " Ein erneuter Versuch hilft hier nicht von selbst."
        return "Die Seiten stehen im geöffneten Heft „\(title)“, \(state) Die empfangene Kopie bleibt erhalten; nach einem Neustart prüft noty, ob die Seiten im gespeicherten Heft stehen, und bietet sie nur dann erneut an, wenn nicht."
    }

    /// Committed, but reading the new state back did not confirm it.
    public static func committedUnverified(pages: String, title: String) -> String {
        "\(pages) wurden in „\(title)“ gespeichert, aber die anschließende Prüfung konnte den gespeicherten Stand nicht bestätigen. Bitte das Heft öffnen und prüfen. Die empfangene Kopie bleibt erhalten und ist als bereits eingefügt markiert, damit sie nicht doppelt eingefügt wird."
    }

    /// A leftover copy whose filing was already committed.
    public static func alreadyFiled(_ record: IncomingFilingRecord, date: String) -> String {
        "Diese Datei wurde am \(date) in „\(record.notebookTitle)“ abgelegt (\(record.pageIDs.count == 1 ? "1 Seite" : "\(record.pageIDs.count) Seiten")). Die Kopie im Eingang wird nicht mehr gebraucht."
    }

    public static func duplicate(_ duplicate: IncomingDuplicate, date: (Date) -> String) -> String {
        switch duplicate {
        case .waiting(let other):
            return "Dieselbe Datei liegt bereits ein weiteres Mal im Eingang („\(other.originalName)“, empfangen \(date(other.receivedAt))). Wenn sie doppelt geteilt wurde, hier „Abbrechen“ wählen."
        case .filed(let entry):
            return "Dieselbe Datei wurde bereits am \(date(entry.filedAt)) in „\(entry.notebookTitle)“ abgelegt (\(entry.pageCount == 1 ? "1 Seite" : "\(entry.pageCount) Seiten")). Erneut ablegen fügt sie ein zweites Mal ein."
        }
    }
}

/// Title proposal for an incoming file: its name without the file extension,
/// unique among the active notebooks of the area like every import
/// (`NotebookTitles.unique`: „Titel“, „Titel (1)“ …).
public enum IncomingNaming {
    /// Only real file extensions are removed: „Kapitel 3.2“ stays as it is.
    static let knownExtensions: Set<String> = ["pdf", "png", "jpg", "jpeg", "jpe", "heic", "heif", "hif", "gif",
                                               "tif", "tiff", "bmp", "webp", "avif", "dng"]

    public static func stem(of fileName: String) -> String {
        // A provider name is no path: only its last component counts.
        var name = fileName.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        if let dot = name.lastIndex(of: "."), dot != name.startIndex,
           knownExtensions.contains(name[name.index(after: dot)...].lowercased()) {
            name = String(name[..<dot])
        }
        return NotebookTitles.sanitized(name)
    }

    public static func suggestedTitle(fileName: String, taken: some Sequence<String>) -> String {
        NotebookTitles.unique(stem(of: fileName), taken: taken)
    }
}

/// Received files in arrival order; one is offered at a time. The current
/// file stays current until it is finished (filed or discarded), so a file
/// arriving meanwhile waits instead of replacing the open sheet.
public struct IncomingQueue: Equatable, Sendable {
    public private(set) var waiting: [IncomingItem] = []
    public private(set) var current: IncomingItem?
    public init() {}

    public var isEmpty: Bool { current == nil && waiting.isEmpty }

    /// False for a file that is already queued or current (re-listed at launch).
    @discardableResult
    public mutating func enqueue(_ item: IncomingItem) -> Bool {
        guard current?.id != item.id, !waiting.contains(where: { $0.id == item.id }) else { return false }
        let index = waiting.firstIndex { $0.receivedAt > item.receivedAt } ?? waiting.endIndex
        waiting.insert(item, at: index)
        return true
    }

    /// The next file to offer, nil while one is still offered or none waits.
    public mutating func next() -> IncomingItem? {
        guard current == nil, !waiting.isEmpty else { return nil }
        current = waiting.removeFirst()
        return current
    }

    /// The file is done (filed, discarded or gone).
    public mutating func finish(_ id: UUID) {
        if current?.id == id { current = nil }
        waiting.removeAll { $0.id == id }
    }

    /// The offer of the current file ended without a decision (sheet could
    /// not be shown): it comes again first.
    public mutating func postponeCurrent() {
        guard let item = current else { return }
        current = nil
        waiting.insert(item, at: 0)
    }
}

/// Where the new pages go in an existing notebook.
public enum IncomingPlacement: Equatable, Sendable {
    case end
    /// Behind this page (the current page of the open notebook).
    case after(UUID)

    public func insertionIndex(in pageIDs: [UUID]) throws -> Int {
        switch self {
        case .end: return pageIDs.count
        case .after(let id):
            guard let index = pageIDs.firstIndex(of: id) else { throw PageOperationError.missingPage }
            return index + 1
        }
    }
}

extension Notebook {
    /// The incoming PDF (a picture already became a one-page PDF) as new
    /// pages with new IDs; its bytes become a new, unchanged PDF source. The
    /// optional writing space is given in page-width fractions like the import
    /// sheet (`PDFWritingSpaceOptions`) and scaled to each page. Text documents
    /// flow their text over their pages and take no PDF pages.
    @discardableResult
    public mutating func insertIncomingPDF(_ data: Data, geometries: [PDFPageGeometry], placement: IncomingPlacement,
                                           writingArea: PageMargins?) throws -> [UUID] {
        guard !isTextDocument else { throw IncomingFileError.notAppendable }
        var next = self
        let index = try placement.insertionIndex(in: next.pages.map(\.id))
        let ids = try next.insertPDF(data, geometries: geometries, at: index)
        if let writingArea, !ids.isEmpty {
            let inserted = Set(ids)
            var assignments: [UUID: PageMargins] = [:]
            for page in next.pages where inserted.contains(page.id) {
                assignments[page.id] = try writingArea.scaled(from: .init(width: 1, height: 1), to: page.geometry?.displaySize ?? .a4)
            }
            guard assignments.count == ids.count else { throw PageOperationError.missingPage }
            try next.setMargins(assignments)
        }
        try next.validate()
        self = next
        return ids
    }
}

/// A folder choice of the filing sheet; `id == nil` is „Alle Unterlagen“.
public struct IncomingFolderRow: Identifiable, Equatable, Sendable {
    public var rowID: String { id?.uuidString ?? "root" }
    public let id: UUID?
    public let title: String
    public let depth: Int
    /// „Alle Unterlagen / Bio / Klausuren“ (the library's own notation).
    public let path: String
}

/// Target lists of the filing sheet, from the library index alone: active
/// entries only (never the trash), text documents are no append targets.
public enum IncomingTargets {
    public static let rootTitle = "Alle Unterlagen"

    public static func path(of folder: UUID?, in snapshot: LibrarySnapshot) -> String {
        var components: [String] = []
        var parent = folder
        var visited = Set<UUID>()
        while let id = parent, visited.insert(id).inserted, let item = snapshot.items.first(where: { $0.id == id }) {
            components.insert(item.title, at: 0); parent = item.parentID
        }
        return ([rootTitle] + components).joined(separator: " / ")
    }

    static func row(_ item: LibraryItem, depth: Int, in snapshot: LibrarySnapshot) -> IncomingFolderRow {
        IncomingFolderRow(id: item.id, title: item.title, depth: depth, path: path(of: item.id, in: snapshot))
    }

    /// „Alle Unterlagen“, then every active folder depth-first in the manual
    /// order of the library. `expanded == nil` shows every level.
    public static func folderTree(_ snapshot: LibrarySnapshot, expanded: Set<UUID>? = nil) -> [IncomingFolderRow] {
        var rows = [IncomingFolderRow(id: nil, title: rootTitle, depth: 0, path: rootTitle)]
        var visited = Set<UUID>()
        func walk(_ parent: UUID?, depth: Int) {
            for folder in snapshot.children(of: parent) where folder.isFolder && visited.insert(folder.id).inserted {
                rows.append(row(folder, depth: depth, in: snapshot))
                if expanded?.contains(folder.id) ?? true { walk(folder.id, depth: depth + 1) }
            }
        }
        walk(nil, depth: 1)
        return rows
    }

    /// Name search over all active folders (flat, with path).
    public static func folders(_ snapshot: LibrarySnapshot, matching query: String) -> [IncomingFolderRow] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return folderTree(snapshot) }
        var rows: [IncomingFolderRow] = []
        if rootTitle.localizedCaseInsensitiveContains(text) { rows.append(IncomingFolderRow(id: nil, title: rootTitle, depth: 0, path: rootTitle)) }
        rows += folderTree(snapshot).filter { $0.id != nil && $0.title.localizedCaseInsensitiveContains(text) }
            .map { IncomingFolderRow(id: $0.id, title: $0.title, depth: 0, path: $0.path) }
        return rows
    }

    /// Pinned folders in the library's pin order.
    public static func favoriteFolders(_ snapshot: LibrarySnapshot, pinOrder: [UUID]) -> [IncomingFolderRow] {
        LibraryPinOrder.arrange(snapshot.items.filter { $0.isFolder && $0.favorite && !snapshot.isTrashed($0.id) }, order: pinOrder)
            .map { row($0, depth: 0, in: snapshot) }
    }

    /// Folders filed into recently (`remembered`, newest first; nil is „Alle
    /// Unterlagen“), then the folders of recently opened notebooks; each once.
    public static func recentFolders(_ snapshot: LibrarySnapshot, remembered: [UUID?], limit: Int = 4) -> [IncomingFolderRow] {
        var result: [IncomingFolderRow] = []
        var seen = Set<String>()
        func add(_ id: UUID?) {
            guard result.count < limit else { return }
            if let id {
                guard let folder = snapshot.items.first(where: { $0.id == id }), folder.isFolder, !snapshot.isTrashed(id),
                      seen.insert(id.uuidString).inserted else { return }
                result.append(row(folder, depth: 0, in: snapshot))
            } else if seen.insert("root").inserted {
                result.append(IncomingFolderRow(id: nil, title: rootTitle, depth: 0, path: rootTitle))
            }
        }
        remembered.forEach(add)
        recentNotebooks(snapshot, limit: 20).map(\.parentID).forEach(add)
        return result
    }

    /// Notebooks that can take pages: active, not a folder, not a text document.
    public static func appendable(_ snapshot: LibrarySnapshot) -> [LibraryItem] {
        snapshot.items.filter { !$0.isFolder && !$0.isTextDocument && !snapshot.isTrashed($0.id) }
    }

    public static func notebooks(_ snapshot: LibrarySnapshot, matching query: String) -> [LibraryItem] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = appendable(snapshot)
        let matches = text.isEmpty ? all : all.filter { $0.title.localizedCaseInsensitiveContains(text) }
        return matches.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    public static func recentNotebooks(_ snapshot: LibrarySnapshot, limit: Int = 5) -> [LibraryItem] {
        Array(appendable(snapshot).filter { $0.lastOpened != nil }
            .sorted { ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast) }.prefix(limit))
    }

    public static func favoriteNotebooks(_ snapshot: LibrarySnapshot, pinOrder: [UUID]) -> [LibraryItem] {
        LibraryPinOrder.arrange(appendable(snapshot).filter(\.favorite), order: pinOrder)
    }

    /// Newest first, each folder once, at most `limit`.
    public static func remember(_ folder: UUID?, in list: [UUID?], limit: Int = 6) -> [UUID?] {
        Array(([folder] + list.filter { $0 != folder }).prefix(limit))
    }

    /// Settings value of `remember` (nil as „root“).
    public static func encode(_ list: [UUID?]) -> [String] { list.map { $0?.uuidString ?? "root" } }
    public static func decode(_ values: [String]) -> [UUID?] {
        values.compactMap { $0 == "root" ? .some(nil) : UUID(uuidString: $0).map { .some($0) } }
    }
}

/// The app-own incoming folder (one folder per received file: `content` and
/// `item.json`, written last). Single writer: the app's incoming handler.
/// A copy stays until the user files or discards it, also over a restart.
public final class IncomingInbox: @unchecked Sendable {
    public let directory: URL
    private let fm = FileManager.default
    private static let stagePrefix = ".stage-"

    public init(directory: URL) { self.directory = directory }

    /// A new file path for the bounded copy of a received file.
    public func newStage() throws -> URL {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(Self.stagePrefix + UUID().uuidString)
    }

    public func discardStage(_ stage: URL) {
        guard stage.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path,
              stage.lastPathComponent.hasPrefix(Self.stagePrefix) else { return }
        try? fm.removeItem(at: stage)
    }

    /// Checks the copied stage by its content and keeps it as a new item;
    /// anything that is no PDF/picture is removed again and refused.
    public func adopt(stage: URL, originalName: String, now: Date = Date()) throws -> IncomingItem {
        do {
            let values = try stage.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else { throw IncomingFileError.missing }
            let size = values.fileSize ?? 0
            let header = try BoundedFile.readPrefix(stage, count: IncomingFileType.headerLength)
            let kind: IncomingFileKind, format: String?
            switch IncomingFileType.decide(header: header, byteCount: size) {
            case .pdf: kind = .pdf; format = nil
            case .image(let value): kind = .image; format = value.rawValue
            case .unsupported(let reason): throw IncomingFileError.unsupported(reason)
            }
            let name = String(originalName.prefix(255))
            let item = IncomingItem(originalName: name, kind: kind, imageFormat: format, byteCount: size, receivedAt: now,
                                    sha256: try Self.sha256(of: stage))
            let folder = directory.appendingPathComponent(item.id.uuidString, isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: false)
            try fm.moveItem(at: stage, to: folder.appendingPathComponent("content"))
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
            try encoder.encode(item).write(to: folder.appendingPathComponent("item.json"), options: .atomic)
            return item
        } catch {
            discardStage(stage)
            throw error
        }
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256Stream()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(chunk) }
        return hasher.finalizeHex()
    }

    private var ledgerURL: URL { directory.appendingPathComponent("filed.json") }
    static let ledgerLimit = 200

    /// Notes the outcome in the item's `item.json` (atomic replacement) right
    /// after the commit; a committed filing also enters the list of filed
    /// files (`filed.json`), so a later delivery of the same bytes is
    /// recognised after the copy itself is gone.
    @discardableResult
    public func record(_ id: UUID, filing: IncomingFilingRecord) throws -> IncomingItem {
        let folder = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        let file = folder.appendingPathComponent("item.json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        var item = try decoder.decode(IncomingItem.self, from: BoundedFile.read(file, limit: 64_000))
        guard item.id == id else { throw IncomingFileError.missing }
        item.filing = filing
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(item).write(to: file, options: .atomic)
        if filing.status == .filed, let sha = item.sha256 {
            let entry = IncomingFiledEntry(sha256: sha, originalName: item.originalName, notebookID: filing.notebookID,
                                           notebookTitle: filing.notebookTitle, pageCount: filing.pageIDs.count, filedAt: filing.filedAt)
            var list = filedEntries().filter { !($0.sha256 == sha && $0.notebookID == filing.notebookID && $0.filedAt == filing.filedAt) }
            list.insert(entry, at: 0)
            try? encoder.encode(Array(list.prefix(Self.ledgerLimit))).write(to: ledgerURL, options: .atomic)
        }
        return item
    }

    /// Filed files, newest first; a missing or damaged list is empty.
    public func filedEntries() -> [IncomingFiledEntry] {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        guard let data = try? BoundedFile.read(ledgerURL, limit: 1_000_000),
              let list = try? decoder.decode([IncomingFiledEntry].self, from: data) else { return [] }
        return list
    }

    /// The same bytes waiting a second time, or filed before (newest first).
    public func duplicate(of item: IncomingItem, now: Date = Date()) -> IncomingDuplicate? {
        guard let sha = item.sha256 else { return nil }
        if let other = items(now: now).first(where: { $0.id != item.id && $0.sha256 == sha && $0.filing?.status != .filed }) {
            return .waiting(other)
        }
        if let entry = filedEntries().first(where: { $0.sha256 == sha }) { return .filed(entry) }
        return nil
    }

    public func contentURL(_ item: IncomingItem) -> URL {
        directory.appendingPathComponent(item.id.uuidString, isDirectory: true).appendingPathComponent("content")
    }

    /// Waiting files, oldest first. Unfinished stages and folders without a
    /// readable `item.json` (interrupted receipt) are removed after a day.
    public func items(now: Date = Date(), staleAfter age: TimeInterval = 24 * 3600) -> [IncomingItem] {
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        var result: [IncomingItem] = []
        for entry in entries {
            let date = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let stale = now.timeIntervalSince(date) > age
            guard let id = UUID(uuidString: entry.lastPathComponent) else {
                if entry.lastPathComponent.hasPrefix(Self.stagePrefix), stale { try? fm.removeItem(at: entry) }
                continue
            }
            let content = entry.appendingPathComponent("content")
            if let data = try? BoundedFile.read(entry.appendingPathComponent("item.json"), limit: 64_000),
               let item = try? decoder.decode(IncomingItem.self, from: data), item.id == id,
               fm.fileExists(atPath: content.path) {
                result.append(item)
            } else if stale {
                try? fm.removeItem(at: entry)
            }
        }
        return result.sorted { $0.receivedAt < $1.receivedAt }
    }

    /// Filed or discarded: the copy goes, nothing outside this folder.
    public func remove(_ id: UUID) {
        try? fm.removeItem(at: directory.appendingPathComponent(id.uuidString, isDirectory: true))
    }
}

extension LibraryStore {
    /// Appends an incoming PDF to a notebook that no editor has open (the
    /// caller makes sure of that; an open notebook goes through its editor
    /// model, its single writer). Serialized with every other library change
    /// on this actor: the package's newest revision is loaded, the pages are
    /// added with new IDs and one complete new revision is committed (manifest
    /// last) and read back. An older fallback state is refused instead of
    /// building on it; any failure leaves the committed state as it was.
    ///
    /// The package's write claim (`PackageWriteLock`) is held from before
    /// loading until after the commit, so no editor can load the old state
    /// meanwhile and commit over it later. A thrown error means nothing was
    /// committed. Once the commit succeeded nothing throws any more: a failed
    /// read-back is reported as `verified == false` (the pages are in the
    /// notebook; the caller must not offer the file as new again).
    public func appendIncomingPDF(to id: UUID, data: Data, geometries: [PDFPageGeometry], placement: IncomingPlacement,
                                  writingArea: PageMargins?) throws -> IncomingAppendResult {
        let snapshot = try committedSnapshot()
        guard let item = snapshot.items.first(where: { $0.id == id }), !item.isFolder, !snapshot.isTrashed(id) else {
            throw LibraryError.unavailable
        }
        guard !item.isTextDocument else { throw IncomingFileError.notAppendable }
        let url = try documentURL(id: id)
        guard let claim = PackageWriteLock.shared.claim(url) else { throw IncomingFileError.notebookInUse }
        defer { claim.release() }
        let store = RevisionStore(directory: url)
        var document = try store.load()
        guard !store.recovered, document.id == id else { throw IncomingFileError.notebookUnreadable }
        guard !document.isTextDocument else { throw IncomingFileError.notAppendable }
        let ids = try document.insertIncomingPDF(data, geometries: geometries, placement: placement, writingArea: writingArea)
        try store.save(document)
        // Committed. From here on only the confirmation can fail.
        let verified: Bool
        do {
            try incomingReadBackFault()
            let reopened = RevisionStore(directory: url, readOnly: true)
            verified = try reopened.load() == document && !reopened.recovered
        } catch { verified = false }
        return IncomingAppendResult(pageIDs: ids, title: item.title, verified: verified)
    }

}

public struct IncomingAppendResult: Sendable, Equatable {
    public let pageIDs: [UUID]
    public let title: String
    /// The committed state was read back and matched.
    public let verified: Bool
}

extension BoundedFile {
    /// At most `count` bytes from the start of a regular file.
    public static func readPrefix(_ url: URL, count: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: max(0, count)) ?? Data()
    }
}
