import Foundation

/// iCloud-Ablage (docs/ICLOUD.md): every notebook of the main library is
/// archived on its own into a folder – the app's iCloud container – whenever
/// its committed state changed, with older states kept by `VaultRetention`.
///
/// Layout below `<container>/Noty/v1/`:
/// - `Versions/<NOTEBOOK-UUID>/<unix>-<uuid>.noty`: immutable `.notybackup`
///   format 2 files (the checked `.noty` share format, originals included).
/// - `Devices/<DEVICE-UUID>.json`: `VaultHead`, written only by that device
///   (one install), so two devices never write the same file.
///
/// The library is only read (committed revisions, read-only stores); a
/// restore takes the normal checked import path. Nothing here deletes a file
/// that is not an own version of the same notebook, and the newest version of
/// a notebook is never deleted.
public enum VaultLayout {
    public static func root(container: URL) -> URL {
        container.appendingPathComponent("Noty", isDirectory: true).appendingPathComponent("v1", isDirectory: true)
    }
    static func versions(_ root: URL, _ notebook: UUID) -> URL {
        root.appendingPathComponent("Versions", isDirectory: true).appendingPathComponent(notebook.uuidString, isDirectory: true)
    }
    static func devices(_ root: URL) -> URL { root.appendingPathComponent("Devices", isDirectory: true) }
    /// For upload-state checks in the app; `file` must be a version name.
    public static func versionURL(root: URL, notebook: UUID, file: String) -> URL? {
        isVersionName(file) ? versions(root, notebook).appendingPathComponent(file) : nil
    }
    public static func headURL(root: URL, device: UUID) -> URL { head(root, device) }
    static func head(_ root: URL, _ device: UUID) -> URL { devices(root).appendingPathComponent(device.uuidString + ".json") }

    static func versionName(at date: Date) -> String {
        String(Int64(date.timeIntervalSince1970)) + "-" + UUID().uuidString.lowercased() + ".noty"
    }
    /// `<unix>-<lowercase uuid>.noty`, nothing else (no paths, no dots).
    static func isVersionName(_ name: String) -> Bool {
        guard name.hasSuffix(".noty") else { return false }
        let body = name.dropLast(5)
        guard let dash = body.firstIndex(of: "-"), let time = Int64(body[..<dash]), (1...4_102_444_800).contains(time) else { return false }
        let id = String(body[body.index(after: dash)...])
        return UUID(uuidString: id) != nil && id == id.lowercased()
    }
}

public struct VaultVersion: Codable, Equatable, Sendable {
    public var file: String
    public var savedAt: Date
    public var pageCount: Int
    public var byteCount: Int
    public var crc32: UInt32
    /// CRC-32 of the package's `manifest.json` that was archived: every
    /// commit replaces the manifest, so an equal value means nothing changed.
    public var source: UInt32
}

public struct VaultNotebook: Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var isTextDocument: Bool
    /// Newest first.
    public var versions: [VaultVersion]
}

/// What one device has put into the vault, replaced after every upload.
public struct VaultHead: Codable, Equatable, Sendable {
    public var formatVersion = 1
    public var device: UUID
    public var deviceName: String
    public var updatedAt: Date
    /// The library index of the last run: folders, titles, trash.
    public var library: LibrarySnapshot
    public var notebooks: [VaultNotebook]

    public init(device: UUID, deviceName: String, updatedAt: Date, library: LibrarySnapshot = LibrarySnapshot(), notebooks: [VaultNotebook] = []) {
        self.device = device; self.deviceName = deviceName; self.updatedAt = updatedAt
        self.library = library; self.notebooks = notebooks
    }

    public func validate() throws {
        guard formatVersion == 1 else { throw VaultError.unsupported(formatVersion) }
        try library.validate()
        guard deviceName.count <= 200, Set(notebooks.map(\.id)).count == notebooks.count else { throw VaultError.invalid }
        for notebook in notebooks {
            guard (1...NotebookTitles.maximumLength).contains(notebook.title.count), !notebook.versions.isEmpty,
                  Set(notebook.versions.map(\.file)).count == notebook.versions.count else { throw VaultError.invalid }
            for version in notebook.versions {
                guard VaultLayout.isVersionName(version.file), version.pageCount >= 1,
                      (1...BackupArchive.maximumFileBytes).contains(version.byteCount) else { throw VaultError.invalid }
            }
        }
    }

    static func decode(_ data: Data) throws -> VaultHead {
        struct Probe: Decodable { var formatVersion: Int }
        // Default date coding (seconds since 2001 as a number) keeps the
        // index dates exact, like the library index itself.
        let decoder = JSONDecoder()
        let probe = try decoder.decode(Probe.self, from: data)
        guard probe.formatVersion == 1 else { throw VaultError.unsupported(probe.formatVersion) }
        let head = try decoder.decode(VaultHead.self, from: data)
        try head.validate()
        return head
    }
    func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try encoder.encode(self)
    }
}

public enum VaultError: Error, LocalizedError, Equatable {
    case invalid, unsupported(Int), changedMeanwhile, olderStateOnly, verificationFailed, missing
    public var errorDescription: String? {
        switch self {
        case .invalid: "Die iCloud-Ablage enthält einen ungültigen Eintrag."
        case .unsupported(let version): "Die iCloud-Ablage hat Format \(version) und braucht eine neuere noty-Version."
        case .changedMeanwhile: "Das Heft wurde währenddessen gespeichert; es wird beim nächsten Durchgang gesichert."
        case .olderStateOnly: "Der neueste Stand des Hefts ist nicht lesbar; es wird nicht in iCloud gesichert."
        case .verificationFailed: "Die Datei in iCloud stimmt nicht mit dem geprüften Stand überein."
        case .missing: "Dieser Stand ist in iCloud nicht (mehr) vorhanden."
        }
    }
}

/// Which older states of one notebook stay (user decision 08.11.2026 for
/// backups: 7 days, 4 weeks, 6 months): the three newest, the newest of each
/// of the last 7 days, of each of the last 4 weeks and of each of the last 6
/// months. The newest is never given up.
public enum VaultRetention {
    /// `dates` newest first; returns the indices to remove.
    public static func obsolete(_ dates: [Date], now: Date = Date(), calendar: Calendar = .current) -> [Int] {
        var keep = Set(dates.indices.prefix(3))
        func newestPer(_ component: Calendar.Component, within count: Int, unit: Calendar.Component) {
            guard let start = calendar.date(byAdding: unit, value: -count, to: now) else { return }
            var seen = Set<DateComponents>()
            for (index, date) in dates.enumerated() where date >= start {
                let key: DateComponents
                switch component {
                case .day: key = calendar.dateComponents([.year, .month, .day], from: date)
                case .weekOfYear: key = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
                default: key = calendar.dateComponents([.year, .month], from: date)
                }
                if seen.insert(key).inserted { keep.insert(index) }
            }
        }
        newestPer(.day, within: 7, unit: .day)
        newestPer(.weekOfYear, within: 4, unit: .weekOfYear)
        newestPer(.month, within: 6, unit: .month)
        return dates.indices.filter { !keep.contains($0) }
    }
}

/// One active notebook of the library and the CRC-32 of its package manifest.
public struct VaultCandidate: Sendable {
    public let item: LibraryItem
    public let stamp: UInt32
}

public struct VaultRunReport: Equatable, Sendable {
    public var uploaded: [String] = []
    public var unchanged = 0
    /// Changed, but the last version is younger than the minimum interval.
    public var waiting = 0
    public var failed: [String] = []
    public var removedVersions = 0
}

extension LibraryBackupPlan {
    /// Active notebooks with the CRC-32 of their current `manifest.json`;
    /// packages without a readable manifest are left out (reported by the
    /// library itself).
    public func vaultCandidates() -> [VaultCandidate] {
        documents.filter { !snapshot.isTrashed($0.id) }.compactMap { item in
            manifestStamp(item).map { VaultCandidate(item: item, stamp: $0) }
        }
    }

    func manifestStamp(_ item: LibraryItem) -> UInt32? {
        guard let package = packages[item.id],
              let bytes = try? BoundedFile.read(package.appendingPathComponent("manifest.json"), limit: 1_000_000) else { return nil }
        return StreamingCRC32.checksum(bytes)
    }

    /// The committed state under the index title as a verified `.notybackup`
    /// format 2 at `url` (a new local file). An unreadable newest revision is
    /// not archived in an older state: the vault would then hold a state
    /// the user never saw as current.
    func vaultArchive(_ item: LibraryItem, to url: URL) throws -> (file: LibraryArchiveFileInfo, pages: Int, text: Bool) {
        let state = try readableNotebook(item)
        guard !state.olderState else { throw VaultError.olderStateOnly }
        var document = state.document
        document.title = item.title
        let written = try BackupArchive.write(document, assets: state.assets, to: url)
        return (written.file, document.pages.count, document.isTextDocument)
    }
}

public enum NotebookVault {
    /// One pass over the main library: each active notebook whose manifest
    /// changed since its newest version (and whose newest version is at
    /// least `minimumInterval` old) is archived, copied into
    /// `Versions/<id>/` and read back; the head is written after every
    /// upload. `VaultRetention` prunes the older versions of every active
    /// notebook on each pass, also without an upload (unchanged, waiting or
    /// failed), so a notebook that is no longer edited does not keep all its
    /// versions; notebooks that left the library keep theirs. `scratch`: an
    /// existing local folder for the intermediate archives.
    public static func run(plan: LibraryBackupPlan, root: URL, head existing: VaultHead?, device: UUID, deviceName: String,
                           scratch: URL, minimumInterval: TimeInterval, now: Date = Date(), calendar: Calendar = .current,
                           coordination: BackupFileCoordinating = DirectBackupFiles()) throws -> (VaultHead, VaultRunReport) {
        let activity = BackupActivity.shared.begin(); defer { activity.end() }
        var head = existing ?? VaultHead(device: device, deviceName: deviceName, updatedAt: now)
        guard head.device == device else { throw VaultError.invalid }
        head.deviceName = String(deviceName.prefix(200))
        head.library = plan.snapshot
        var report = VaultRunReport()
        var headChanged = existing == nil
        for candidate in plan.vaultCandidates() {
            if Task.isCancelled { break }
            let item = candidate.item
            var index = head.notebooks.firstIndex { $0.id == item.id }
            if let found = index, head.notebooks[found].title != item.title || head.notebooks[found].isTextDocument != item.isTextDocument {
                head.notebooks[found].title = item.title; head.notebooks[found].isTextDocument = item.isTextDocument; headChanged = true
            }
            // Retention without an upload; the final head write records it.
            func pruneExisting() {
                guard let found = head.notebooks.firstIndex(where: { $0.id == item.id }) else { return }
                let removed = prune(&head.notebooks[found], root: root, now: now, calendar: calendar, coordination: coordination)
                if removed > 0 { report.removedVersions += removed; headChanged = true }
            }
            if let found = index, let latest = head.notebooks[found].versions.first {
                if latest.source == candidate.stamp { report.unchanged += 1; pruneExisting(); continue }
                if now.timeIntervalSince(latest.savedAt) < minimumInterval, now >= latest.savedAt { report.waiting += 1; pruneExisting(); continue }
            }
            var pruned = false
            let local = scratch.appendingPathComponent(UUID().uuidString + ".notybackup")
            defer { try? FileManager.default.removeItem(at: local) }
            do {
                let archived = try plan.vaultArchive(item, to: local)
                // A commit in between: the archive may be newer than the stamp.
                guard plan.manifestStamp(item) == candidate.stamp else { throw VaultError.changedMeanwhile }
                let name = VaultLayout.versionName(at: now)
                let folder = VaultLayout.versions(root, item.id)
                try coordination.writing(folder) { url in try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
                try place(local, file: archived.file, at: folder.appendingPathComponent(name), coordination: coordination)
                let version = VaultVersion(file: name, savedAt: now, pageCount: archived.pages, byteCount: archived.file.byteCount,
                                           crc32: archived.file.crc32, source: candidate.stamp)
                if index == nil {
                    head.notebooks.append(VaultNotebook(id: item.id, title: item.title, isTextDocument: archived.text, versions: []))
                    index = head.notebooks.count - 1
                }
                head.notebooks[index!].versions.insert(version, at: 0)
                report.uploaded.append(item.title)
                report.removedVersions += prune(&head.notebooks[index!], root: root, now: now, calendar: calendar, coordination: coordination)
                pruned = true
                head.updatedAt = now
                // The version is in place: if writing the head fails now, the
                // final write below records it.
                headChanged = true
                try writeHead(head, root: root, coordination: coordination)
                headChanged = false
            } catch {
                report.failed.append(item.title)
                if !pruned { pruneExisting() }
            }
        }
        if headChanged || head.library != existing?.library {
            head.updatedAt = now
            try writeHead(head, root: root, coordination: coordination)
        }
        return (head, report)
    }

    /// Removes versions `VaultRetention` gives up; an entry leaves the head
    /// only once its file is gone. Returns the number removed.
    static func prune(_ notebook: inout VaultNotebook, root: URL, now: Date, calendar: Calendar,
                      coordination: BackupFileCoordinating) -> Int {
        let obsolete = Set(VaultRetention.obsolete(notebook.versions.map(\.savedAt), now: now, calendar: calendar))
        guard !obsolete.isEmpty else { return 0 }
        let folder = VaultLayout.versions(root, notebook.id)
        var kept: [VaultVersion] = [], removed = 0
        for (index, version) in notebook.versions.enumerated() {
            guard obsolete.contains(index), index > 0, VaultLayout.isVersionName(version.file),
                  removeVersion(folder.appendingPathComponent(version.file), coordination: coordination) else {
                kept.append(version); continue
            }
            removed += 1
        }
        notebook.versions = kept
        return removed
    }

    /// The device's own head as stored in the vault; nil if there is none.
    /// A head of a newer format throws (the caller stops instead of
    /// overwriting it with fewer data).
    public static func readHead(root: URL, device: UUID, coordination: BackupFileCoordinating = DirectBackupFiles()) throws -> VaultHead? {
        let url = VaultLayout.head(root, device)
        var data: Data?
        try coordination.reading(url, metadataOnly: false) { url in
            if FileManager.default.fileExists(atPath: url.path) { data = try BoundedFile.read(url, limit: 16_000_000) }
        }
        guard let data else { return nil }
        let head = try VaultHead.decode(data)
        guard head.device == device else { throw VaultError.invalid }
        return head
    }

    /// Every device's head (also of earlier installs). Unreadable or newer
    /// ones are counted, not used.
    public static func heads(root: URL, coordination: BackupFileCoordinating = DirectBackupFiles()) throws -> (heads: [VaultHead], unreadable: Int) {
        var names: [String] = []
        let folder = VaultLayout.devices(root)
        try coordination.reading(folder, metadataOnly: true) { url in
            names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        }
        var ids = Set<UUID>()
        for raw in names {
            let name = ExternalBackupFolder.placeholderTarget(raw) ?? raw
            guard name.hasSuffix(".json"), let id = UUID(uuidString: String(name.dropLast(5))), name == id.uuidString + ".json" else { continue }
            ids.insert(id)
        }
        var heads: [VaultHead] = [], unreadable = 0
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            do { if let head = try readHead(root: root, device: id, coordination: coordination) { heads.append(head) } }
            catch { unreadable += 1 }
        }
        return (heads, unreadable)
    }

    /// Copies one version into the new local file `destination` (a
    /// placeholder is downloaded by the coordinated read) and checks size and
    /// CRC against the head; the import then verifies the archive itself.
    public static func copyVersion(root: URL, notebook: UUID, version: VaultVersion, to destination: URL,
                                   coordination: BackupFileCoordinating = DirectBackupFiles()) throws {
        guard VaultLayout.isVersionName(version.file) else { throw VaultError.invalid }
        let url = VaultLayout.versions(root, notebook).appendingPathComponent(version.file)
        var info: LibraryArchiveFileInfo?
        try coordination.reading(url, metadataOnly: false) { url in
            guard FileManager.default.fileExists(atPath: url.path) else { throw VaultError.missing }
            info = try BoundedFile.copy(from: url, to: destination, limit: BackupArchive.maximumFileBytes)
        }
        guard info == LibraryArchiveFileInfo(byteCount: version.byteCount, crc32: version.crc32) else {
            try? FileManager.default.removeItem(at: destination)
            throw VaultError.verificationFailed
        }
    }

    // MARK: Files

    /// `<final>.partial` written and read back, renamed, final read back; a
    /// failure leaves no file that could count as a version.
    static func place(_ source: URL, file: LibraryArchiveFileInfo, at final: URL, coordination: BackupFileCoordinating) throws {
        let fm = FileManager.default
        let partial = final.deletingLastPathComponent().appendingPathComponent(final.lastPathComponent + ".partial")
        guard !fm.fileExists(atPath: final.path), !fm.fileExists(atPath: partial.path) else { throw LibraryArchiveError.destinationExists }
        var created = false
        do {
            try coordination.writing(partial) { url in
                let copied = try BoundedFile.copy(from: source, to: url, limit: BackupArchive.maximumFileBytes); created = true
                guard copied == file else { throw VaultError.verificationFailed }
            }
            try coordination.reading(partial, metadataOnly: false) { url in
                guard try BoundedFile.checksum(url) == file else { throw VaultError.verificationFailed }
            }
            try coordination.moving(partial, to: final) { from, to in try fm.moveItem(at: from, to: to) }
        } catch {
            if created { _ = removeVersion(partial, coordination: coordination, allowPartial: true) }
            throw error
        }
        do {
            try coordination.reading(final, metadataOnly: false) { url in
                guard try BoundedFile.checksum(url) == file else { throw VaultError.verificationFailed }
            }
        } catch {
            _ = removeVersion(final, coordination: coordination)
            throw VaultError.verificationFailed
        }
    }

    /// Only a regular file with a version name (or its `.partial`), never a
    /// link or folder; a missing file counts as removed.
    @discardableResult
    static func removeVersion(_ url: URL, coordination: BackupFileCoordinating, allowPartial: Bool = false) -> Bool {
        let name = url.lastPathComponent
        let base = allowPartial && name.hasSuffix(".partial") ? String(name.dropLast(8)) : name
        guard VaultLayout.isVersionName(base) else { return false }
        var removed = false
        try? coordination.deleting(url) { url in
            let fm = FileManager.default
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
                removed = !fm.fileExists(atPath: url.path); return
            }
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return }
            try fm.removeItem(at: url); removed = true
        }
        return removed
    }

    static func writeHead(_ head: VaultHead, root: URL, coordination: BackupFileCoordinating) throws {
        try head.validate()
        let data = try head.encoded()
        let folder = VaultLayout.devices(root)
        try coordination.writing(folder) { url in try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        try coordination.writing(VaultLayout.head(root, head.device)) { url in try data.write(to: url, options: .atomic) }
    }
}

/// The vault's notebooks for the restore list: the versions of all devices
/// merged per notebook, newest first, with folder and today's state.
public struct VaultCatalogEntry: Identifiable, Equatable, Sendable {
    public enum Today: Equatable, Sendable { case active, trashed, deleted }
    public struct Version: Identifiable, Equatable, Sendable {
        public var id: String { version.file }
        public let version: VaultVersion
        public let deviceName: String
    }
    public let id: UUID
    public let title: String
    public let isTextDocument: Bool
    public let folderPath: [String]
    public let parentID: UUID?
    public let versions: [Version]
    public let today: Today
    public let currentTitle: String?

    public static func catalog(heads: [VaultHead], current: LibrarySnapshot) -> [VaultCatalogEntry] {
        var byID: [UUID: (newest: VaultHead, notebook: VaultNotebook, versions: [Version])] = [:]
        for head in heads {
            for notebook in head.notebooks {
                let versions = notebook.versions.map { Version(version: $0, deviceName: head.deviceName) }
                if var entry = byID[notebook.id] {
                    entry.versions += versions
                    if head.updatedAt > entry.newest.updatedAt { entry.newest = head; entry.notebook = notebook }
                    byID[notebook.id] = entry
                } else { byID[notebook.id] = (head, notebook, versions) }
            }
        }
        return byID.values.map { entry in
            let item = entry.newest.library.items.first { $0.id == entry.notebook.id && !$0.isFolder }
            let today = current.items.first { $0.id == entry.notebook.id && !$0.isFolder }
            let state: Today = today == nil ? .deleted : (current.isTrashed(entry.notebook.id) ? .trashed : .active)
            return VaultCatalogEntry(id: entry.notebook.id, title: entry.notebook.title, isTextDocument: entry.notebook.isTextDocument,
                                     folderPath: item.map { LibraryBackupBrowser.folderPath(of: $0, in: entry.newest.library) } ?? [],
                                     parentID: item?.parentID,
                                     versions: entry.versions.sorted { $0.version.savedAt > $1.version.savedAt },
                                     today: state, currentTitle: today?.title)
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// The folder of the vault's index if it exists today, else the top level.
    public func destination(in current: LibrarySnapshot) -> UUID? {
        guard let parentID, current.items.contains(where: { $0.id == parentID && $0.isFolder }), !current.isTrashed(parentID) else { return nil }
        return parentID
    }
}
