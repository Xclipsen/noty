import SwiftUI
import UniformTypeIdentifiers
import NotebookCore

/// Apple-framework checks of one notebook without UI objects, safe off the UI
/// actor: PDFs through CoreGraphics (the documents PDFKit wraps; same page
/// count, lock and geometry rules as NotebookPDFCatalog), then PencilKit
/// drawings and images like EditorModelValidation.
enum BackupValidation {
    nonisolated static func validate(_ document: Notebook) throws {
        try document.validate()
        func parse(_ data: Data) throws -> CGPDFDocument {
            guard let provider = CGDataProvider(data: data as CFData), let pdf = CGPDFDocument(provider), pdf.isUnlocked else {
                throw StorageError.invalidDocument
            }
            return pdf
        }
        var sources: [UUID: CGPDFDocument] = [:]
        for source in document.pdfSources ?? [] {
            let pdf = try parse(source.data)
            guard pdf.numberOfPages == source.pageCount else { throw StorageError.invalidDocument }
            sources[source.id] = pdf
        }
        let legacy = try document.pdf.map(parse)
        if let legacy, legacy.numberOfPages != document.pages.count { throw StorageError.invalidDocument }
        if document.pdfSources == nil, document.pdf == nil,
           document.pages.count != 1 || document.pages[0].geometry != nil { throw StorageError.invalidDocument }
        let legacyIndices = Dictionary(uniqueKeysWithValues: document.pages.enumerated().map { ($0.element.id, $0.offset) })
        for page in document.pages + (document.deletedPages ?? []).map(\.page) {
            var source: CGPDFPage?
            if let reference = page.pdfReference {
                if reference.pageIndex >= 0 { source = sources[reference.sourceID]?.page(at: reference.pageIndex + 1) }
            } else if let index = legacyIndices[page.id] { source = legacy?.page(at: index + 1) }
            if page.pdfReference != nil || document.pdf != nil { guard source != nil else { throw StorageError.invalidDocument } }
            _ = try PageLayout(page: page, source: source)
        }
        try EditorModelValidation.validateContent(document)
    }
}

/// NSFileCoordinator for the chosen (iCloud Drive) folder: listing reads only
/// available metadata, reads download placeholders, writes/moves/deletes are
/// announced to the file provider.
struct CoordinatedBackupFiles: BackupFileCoordinating {
    private func finish(_ coordination: NSError?, _ failure: Error?) throws {
        if let failure { throw failure }
        if let coordination { throw coordination }
    }
    func reading(_ url: URL, metadataOnly: Bool, _ body: (URL) throws -> Void) throws {
        var coordination: NSError?, failure: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: metadataOnly ? .immediatelyAvailableMetadataOnly : [], error: &coordination) { url in
            do { try body(url) } catch { failure = error }
        }
        try finish(coordination, failure)
    }
    func writing(_ url: URL, _ body: (URL) throws -> Void) throws {
        var coordination: NSError?, failure: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordination) { url in
            do { try body(url) } catch { failure = error }
        }
        try finish(coordination, failure)
    }
    func moving(_ source: URL, to destination: URL, _ body: (URL, URL) throws -> Void) throws {
        var coordination: NSError?, failure: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: source, options: .forMoving, writingItemAt: destination, options: .forReplacing,
                               error: &coordination) { from, to in
            do { try body(from, to); coordinator.item(at: from, didMoveTo: to) } catch { failure = error }
        }
        try finish(coordination, failure)
    }
    func deleting(_ url: URL, _ body: (URL) throws -> Void) throws {
        var coordination: NSError?, failure: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordination) { url in
            do { try body(url) } catch { failure = error }
        }
        try finish(coordination, failure)
    }
}

/// The backup did not run (editor busy, saving, another backup): not a failure.
struct BackupPostponed: LocalizedError {
    let reason: String
    var errorDescription: String? { "Backup verschoben: \(reason). Bitte gleich noch einmal versuchen." }
}

/// Result of committing the open editors right before a backup.
enum BackupCommit: Equatable {
    case committed
    /// Input or a save is running: retry with the next minute.
    case busy
    /// A save failed (or nothing can be saved): retrying needs a longer pause.
    case failed
}

/// A verified archive file in the app's temporary directory; removed after use.
struct PreparedLibraryArchive: Sendable {
    let url: URL
    let summary: LibraryArchiveSummary
    /// Notebooks archived in their newest readable older state (newer revision damaged).
    var olderStates: [String] = []
    var warning: String? { ExternalBackupPolicy.olderStateWarning(olderStates) }
}

/// Temporary archive files: never inside a library or workspace tree, so an
/// archive can never end up inside the next backup.
enum BackupScratch {
    nonisolated static var directory: URL { FileManager.default.temporaryDirectory.appendingPathComponent("NotyBackupArchives", isDirectory: true) }
    nonisolated static func newFile(_ suffix: String = "notylibrary") throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString + "." + suffix)
    }
    nonisolated static func remove(_ url: URL) {
        guard url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path else { return }
        try? FileManager.default.removeItem(at: url)
    }
    /// Leftovers of interrupted runs, e.g. after the app was terminated mid-backup.
    nonisolated static func removeStale(olderThan age: TimeInterval = 24 * 3600) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for entry in entries {
            let date = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(date) > age { try? fm.removeItem(at: entry) }
        }
    }
}

/// File-backed export: the system writes from the archive file (memory-mapped
/// by FileWrapper), the archive is never loaded into memory as a whole.
struct LibraryArchiveFile: FileDocument {
    static var readableContentTypes: [UTType] { [.notyLibrary] }
    let url: URL
    init(url: URL) { self.url = url }
    init(configuration: ReadConfiguration) throws { throw CocoaError(.featureUnsupported) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { try FileWrapper(url: url, options: []) }
}
