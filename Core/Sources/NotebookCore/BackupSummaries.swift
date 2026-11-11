import Foundation

/// What one automatic backup contained (BACKUP-RESTORE-PLAN Phase 3),
/// written locally right after the archive was written and read back. The
/// backup list shows it without downloading archives from iCloud, and the
/// timeline of one notebook finds the backups that hold one of its states.
/// Derived data only: never part of an archive, deleting it loses nothing
/// but the details in the list.
public struct BackupSummary: Codable, Equatable, Sendable, Identifiable {
    public struct Notebook: Codable, Equatable, Sendable {
        public var id: UUID
        public var title: String
        /// Canonical archive chunk (`LibraryArchiveChunk`): the same CRC means
        /// the same notebook state.
        public var crc32: UInt32
        public var byteCount: Int
        public init(id: UUID, title: String, crc32: UInt32, byteCount: Int) {
            self.id = id; self.title = title; self.crc32 = crc32; self.byteCount = byteCount
        }
    }
    public var id: String { file }
    /// Archive file name (`ExternalBackupPolicy.filename`).
    public var file: String
    public var createdAt: Date
    /// Active notebooks of the backup (not its trash).
    public var notebooks: [Notebook]
    /// Changed or new since the previous summary (by CRC), oldest summary: nil.
    public var changed: [UUID]?
    /// Active in the previous backup, not in this one (deleted or trashed since).
    public var removed: [UUID]?

    public init(file: String, createdAt: Date, notebooks: [Notebook], changed: [UUID]? = nil, removed: [UUID]? = nil) {
        self.file = file; self.createdAt = createdAt; self.notebooks = notebooks; self.changed = changed; self.removed = removed
    }

    /// From the verified archive's summary: active notebooks with their chunk.
    public init(file: String, archive: LibraryArchiveSummary, previous: BackupSummary?) {
        let chunks = Dictionary(archive.notebooks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var notebooks: [Notebook] = []
        for item in archive.snapshot.items where !item.isFolder && !archive.snapshot.isTrashed(item.id) {
            guard let chunk = chunks[item.id] else { continue }
            notebooks.append(Notebook(id: item.id, title: String(item.title.prefix(200)), crc32: chunk.crc32, byteCount: chunk.byteCount))
        }
        self.init(file: file, createdAt: archive.createdAt, notebooks: notebooks)
        if let previous {
            let before = Dictionary(previous.notebooks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            changed = notebooks.filter { note in before[note.id].map { $0.crc32 != note.crc32 || $0.byteCount != note.byteCount } ?? true }.map(\.id)
            let now = Set(notebooks.map(\.id))
            removed = previous.notebooks.map(\.id).filter { !now.contains($0) }
        }
    }

    public func notebook(_ id: UUID) -> Notebook? { notebooks.first { $0.id == id } }

    /// „42 Hefte · 3 geändert (Bio, Mathe, Deutsch)“.
    public var line: String {
        var text = notebooks.count == 1 ? "1 Heft" : "\(notebooks.count) Hefte"
        guard let changed else { return text }
        let titles = changed.compactMap { id in notebooks.first { $0.id == id }?.title }
        if titles.isEmpty, (removed ?? []).isEmpty { return text + " · unverändert" }
        if !titles.isEmpty {
            let names = titles.prefix(3).joined(separator: ", ") + (titles.count > 3 ? " …" : "")
            text += " · \(titles.count) geändert (\(names))"
        }
        if let removed, !removed.isEmpty { text += " · \(removed.count) entfernt" }
        return text
    }

    var isValid: Bool {
        (1...300).contains(file.count) && !file.contains("/") && notebooks.count <= 100_000
            && notebooks.allSatisfy { (1...200).contains($0.title.count) && $0.byteCount >= 0 }
            && Set(notebooks.map(\.id)).count == notebooks.count
            && (changed?.count ?? 0) <= notebooks.count
            && createdAt.timeIntervalSince1970.isFinite
    }
}

/// The summaries of one backup series, newest first, kept locally in the app
/// (`Library/Application Support/BackupSummaries/<series>.json`).
public struct BackupSummaryIndex: Codable, Equatable, Sendable {
    public static let maximumSummaries = 120
    public var version = 1
    public var series: UUID
    public var summaries: [BackupSummary] = []

    public init(series: UUID) { self.series = series }

    /// Adds `summary` (replacing one of the same file) and drops summaries of
    /// archives no longer listed at the target (`existing`; nil keeps all).
    public mutating func record(_ summary: BackupSummary, existing: Set<String>? = nil) {
        summaries.removeAll { $0.file == summary.file }
        summaries.insert(summary, at: 0)
        summaries.sort { $0.createdAt > $1.createdAt }
        if let existing { summaries.removeAll { !existing.contains($0.file) && $0.file != summary.file } }
        if summaries.count > Self.maximumSummaries { summaries.removeLast(summaries.count - Self.maximumSummaries) }
    }

    public func summary(for file: String) -> BackupSummary? { summaries.first { $0.file == file } }

    /// The newest summary before `summary` (for „geändert seit“).
    public var newest: BackupSummary? { summaries.first }

    /// The backups holding a state of `notebook`, newest first; of several
    /// backups with the same state only the newest is listed (`sameStateCount`
    /// says how many hold it).
    public func states(of notebook: UUID) -> [(summary: BackupSummary, sameStateCount: Int)] {
        var result: [(summary: BackupSummary, sameStateCount: Int)] = []
        var lastCRC: (UInt32, Int)?
        for summary in summaries {
            guard let entry = summary.notebook(notebook) else { lastCRC = nil; continue }
            if let last = lastCRC, last == (entry.crc32, entry.byteCount), !result.isEmpty {
                result[result.count - 1].sameStateCount += 1
            } else {
                result.append((summary, 1))
            }
            lastCRC = (entry.crc32, entry.byteCount)
        }
        return result
    }

    public func validate() throws {
        guard version == 1, summaries.count <= Self.maximumSummaries, summaries.allSatisfy(\.isValid),
              Set(summaries.map(\.file)).count == summaries.count else { throw StorageError.invalidDocument }
    }

    // MARK: Storage

    public static func url(root: URL, series: UUID) -> URL {
        root.appendingPathComponent(series.uuidString.lowercased() + ".json")
    }

    /// The stored index, or an empty one (missing, damaged or another series).
    public static func load(root: URL, series: UUID) -> BackupSummaryIndex {
        let url = url(root: root, series: series)
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true,
              (values.fileSize ?? 0) <= 40_000_000, let bytes = try? Data(contentsOf: url),
              let index = try? JSONDecoder().decode(BackupSummaryIndex.self, from: bytes),
              (try? index.validate()) != nil, index.series == series else { return BackupSummaryIndex(series: series) }
        return index
    }

    public func save(root: URL) throws {
        try validate()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: Self.url(root: root, series: series), options: .atomic)
    }
}

/// Local states of a notebook that is not open (BACKUP-RESTORE-PLAN Phase 2):
/// read through a read-only revision store, so restoring from Settings never
/// becomes a second writer of the package.
public enum LocalStates {
    public static func history(package: URL) throws -> LocalHistory {
        try RevisionStore(directory: package, readOnly: true).localHistory()
    }

    /// The state `revision` as a verified `.notybackup` titled `title`, for
    /// the library's staged import (copy or „Aktuellen Stand ersetzen“).
    public static func export(package: URL, revision: UUID, title: String, to url: URL) throws {
        let activity = BackupActivity.shared.begin(); defer { activity.end() }
        let store = RevisionStore(directory: package, readOnly: true)
        let decoded = try store.localRevision(id: revision)
        var document = decoded.notebook
        document.title = try LibraryStore.validTitle(title)
        _ = try BackupArchive.write(document, assets: ChainedImageAssets([decoded.inlineAssets, store.assets]), to: url)
    }
}
