import Foundation

// Kalender Stufe B3: the calendar part of a library backup (library archive
// format 3, docs/LIBRARY-BACKUP.md). It carries the confirmed calendar state
// of the area (own events with series and exceptions, deleted events, note
// links, lesson mappings, subject colours, settings, the connection record –
// which never holds secrets) and the last WebUntis offline snapshot with its
// fetch times, so restored notes keep their lesson context. Credentials,
// tokens and server addresses live only in the device keychain and are never
// part of it. Restore writes a new `Calendar/` package into the new area,
// links remapped to that area's notebooks, the connection detached (the user
// reconnects on this device; a restore never activates a source).

/// Calendar data of one archive.
public struct CalendarArchiveContent: Equatable, Sendable {
    public var state: CalendarState
    /// Offline timetable of `state.connection`; nil when none was cached.
    public var source: CalendarSourceSnapshot?

    public init(state: CalendarState, source: CalendarSourceSnapshot? = nil) {
        self.state = state; self.source = source
    }

    /// Limits of the two archive records.
    public static let maximumStateBytes = CalendarStore.maximumBytes
    public static let maximumSourceBytes = 120_000_000

    /// Exactly the keys a connection record may have: nothing a secret could hide in.
    static let connectionKeys: Set<String> = ["id", "kind", "label", "timeZone", "connectedAt", "sourceIdentity"]

    /// Structure and references: valid current-format state, every link to a
    /// notebook of the archive, the notes folder a folder of the archive, the
    /// snapshot bound to the state's connection.
    public func validate(documents: Set<UUID>, folders: Set<UUID>) throws {
        try state.validate()
        guard state.noteLinks.allSatisfy({ documents.contains($0.documentID) }),
              state.studyFields.allSatisfy({ $0.notebookID.map(documents.contains) ?? true }),
              state.settings.notesFolderID.map({ folders.contains($0) }) ?? true else { throw CalendarArchiveError.danglingReference }
        if let source {
            guard let connection = state.connection, source.connection == connection.id else { throw CalendarArchiveError.invalid }
            try source.validate()
        }
    }
}

public enum CalendarArchiveError: Error, LocalizedError, Equatable {
    case invalid, danglingReference, unsupported(Int)
    public var errorDescription: String? {
        switch self {
        case .invalid: "Die Kalenderdaten im Bibliotheksbackup sind beschädigt oder unvollständig. Es wurde nichts wiederhergestellt."
        case .danglingReference: "Eine Terminnotiz im Bibliotheksbackup verweist auf ein Heft, das nicht im Backup enthalten ist. Es wurde nichts wiederhergestellt."
        case .unsupported(let version): "Die Kalenderdaten (Format \(version)) im Bibliotheksbackup benötigen eine neuere noty-Version."
        }
    }
}

/// What a backup found in the area's `Calendar/` package.
public struct CalendarBackupCapture: Sendable, Equatable {
    public let content: CalendarArchiveContent?
    /// Links to notebooks deleted for good (no longer in the library index):
    /// not archived, every archived link has its notebook in the archive.
    public let droppedLinks: Int
    /// The newest calendar revision was unreadable; an older checked one went in.
    public let olderState: Bool
    /// A connection exists but its offline timetable was missing or unreadable.
    public let sourceMissing: Bool
}

public enum CalendarArchive {
    /// Read-only capture of the committed calendar of `areaRoot` for a
    /// library backup; `library` is the index that goes into the same
    /// archive. Nothing is written. An area without calendar package (or with
    /// nothing but defaults) gives no content: the archive stays format 2.
    /// An unreadable or newer calendar package fails the backup instead of
    /// silently leaving the calendar out.
    public static func capture(areaRoot: URL, library: LibrarySnapshot) throws -> CalendarBackupCapture {
        let directory = areaRoot.appendingPathComponent("Calendar", isDirectory: true)
        guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
            return CalendarBackupCapture(content: nil, droppedLinks: 0, olderState: false, sourceMissing: false)
        }
        let store = CalendarStore(directory: directory)
        var state = try store.load()
        let documents = Set(library.items.filter { !$0.isFolder }.map(\.id))
        let folders = Set(library.items.filter(\.isFolder).map(\.id))
        let before = state.noteLinks.count
        state.noteLinks.removeAll { !documents.contains($0.documentID) }
        // A Lernfeld whose notebook was deleted for good gets a new one at its next lesson note.
        for index in state.studyFields.indices where state.studyFields[index].notebookID.map({ !documents.contains($0) }) ?? false {
            state.studyFields[index].notebookID = nil
        }
        if let folder = state.settings.notesFolderID, !folders.contains(folder) { state.settings.notesFolderID = nil }
        var source: CalendarSourceSnapshot?
        var missing = false
        if let connection = state.connection {
            source = readCache(directory: directory, connection: connection.id)
            missing = source == nil
        }
        guard !state.isEmpty || source != nil else {
            return CalendarBackupCapture(content: nil, droppedLinks: before - state.noteLinks.count, olderState: store.recovered, sourceMissing: false)
        }
        let content = CalendarArchiveContent(state: state, source: source)
        try content.validate(documents: documents, folders: folders)
        return CalendarBackupCapture(content: content, droppedLinks: before - state.noteLinks.count, olderState: store.recovered,
                                     sourceMissing: missing)
    }

    /// The validated cache of `connection`, or nil (missing, damaged, newer).
    static func readCache(directory: URL, connection: UUID) -> CalendarSourceSnapshot? {
        let url = directory.appendingPathComponent("Cache/\(connection.uuidString).json")
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize,
              (1...CalendarArchiveContent.maximumSourceBytes).contains(size),
              let bytes = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(CalendarSourceSnapshot.self, from: bytes),
              (try? decoded.validate()) != nil, decoded.connection == connection else { return nil }
        return decoded
    }

    // MARK: Records

    static func encodeState(_ state: CalendarState) throws -> Data {
        let bytes = try CalendarStore.encoder.encode(state)
        guard bytes.count <= CalendarArchiveContent.maximumStateBytes else { throw CalendarArchiveError.invalid }
        return bytes
    }

    static func encodeSource(_ source: CalendarSourceSnapshot) throws -> Data {
        let bytes = try CalendarStore.encoder.encode(source)
        guard bytes.count <= CalendarArchiveContent.maximumSourceBytes else { throw CalendarArchiveError.invalid }
        return bytes
    }

    /// The archive carries the calendar format of the build that wrote it:
    /// the current one, or an older one (format 3 archives of B3 builds),
    /// read with the defaults of the newer fields like the package itself
    /// (`CalendarStore.decodeStored`). A newer format is refused.
    static func decodeState(_ bytes: Data) throws -> CalendarState {
        struct Header: Decodable { var formatVersion: Int }
        guard let version = try? JSONDecoder().decode(Header.self, from: bytes).formatVersion else { throw CalendarArchiveError.invalid }
        guard version <= CalendarState.currentFormat else { throw CalendarArchiveError.unsupported(version) }
        guard version >= 3 else { throw CalendarArchiveError.invalid }
        // No key beyond the known ones, also inside the connection record.
        guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(object.keys).isSubset(of: ["formatVersion", "events", "settings", "connection", "noteLinks", "lessonMappings",
                                             "deletedEvents", "homeworkDone", "studyFields", "studyRules", "lessonTopics"]) else {
            throw CalendarArchiveError.invalid
        }
        if let connection = object["connection"] {
            guard let record = connection as? [String: Any], Set(record.keys).isSubset(of: CalendarArchiveContent.connectionKeys) else {
                throw CalendarArchiveError.invalid
            }
        }
        do { return try CalendarStore.decodeStored(bytes).state }
        catch { throw CalendarArchiveError.invalid }
    }

    static func decodeSource(_ bytes: Data) throws -> CalendarSourceSnapshot {
        do {
            let source = try JSONDecoder().decode(CalendarSourceSnapshot.self, from: bytes)
            try source.validate()
            return source
        } catch CalendarStoreError.unsupportedFormat(let version) { throw CalendarArchiveError.unsupported(version) }
        catch { throw CalendarArchiveError.invalid }
    }

    // MARK: Restore

    /// The content for a new area. `documents` maps every archived notebook
    /// id to its id in the new area (a restore that keeps ids passes the
    /// identity); a link without a mapped notebook is refused, never pointed
    /// elsewhere. `folders` likewise for the notes folder. The connection gets
    /// `connection` as its new id: keychain items of the original id on this
    /// device never activate it, the user reconnects („Zugang auf diesem
    /// Gerät neu verbinden“). The account identity is kept (a B1 record gets
    /// its old connection-based key), so lesson notes find their lessons
    /// again after reconnecting the same „Freigabe“; the offline timetable is
    /// rebound to the new id with its original fetch times (shown as „Stand“).
    public static func restored(_ content: CalendarArchiveContent, documents: [UUID: UUID], folders: [UUID: UUID],
                                connection: UUID = UUID()) throws -> CalendarArchiveContent {
        var state = content.state
        for index in state.noteLinks.indices {
            guard let mapped = documents[state.noteLinks[index].documentID] else { throw CalendarArchiveError.danglingReference }
            state.noteLinks[index].documentID = mapped
        }
        for index in state.studyFields.indices {
            guard let notebook = state.studyFields[index].notebookID else { continue }
            guard let mapped = documents[notebook] else { throw CalendarArchiveError.danglingReference }
            state.studyFields[index].notebookID = mapped
        }
        if let folder = state.settings.notesFolderID {
            guard let mapped = folders[folder] else { throw CalendarArchiveError.danglingReference }
            state.settings.notesFolderID = mapped
        }
        // System calendars are a source too: off until the user connects them on this device.
        state.settings.systemCalendars?.enabled = false
        var source = content.source
        if let old = state.connection {
            let record = CalendarConnectionRecord(id: connection, kind: old.kind, label: old.label, timeZone: old.timeZone,
                                                  connectedAt: old.connectedAt, sourceIdentity: old.source)
            state.connection = record
            if var snapshot = source {
                snapshot.connection = connection
                for index in snapshot.lessons.indices { snapshot.lessons[index].key.connection = connection }
                source = snapshot
            }
        } else if source != nil { throw CalendarArchiveError.invalid }
        let result = CalendarArchiveContent(state: state, source: source)
        try result.validate(documents: Set(documents.values), folders: Set(folders.values))
        return result
    }

    /// Restore stage only (a new, unpublished area): writes the package with
    /// the ordinary calendar commit (revision, read back, manifest last) and
    /// the offline timetable, then reads both back with fresh readers.
    static func populate(_ content: CalendarArchiveContent, areaRoot: URL) throws {
        let directory = areaRoot.appendingPathComponent("Calendar", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw LibraryArchiveError.destinationExists }
        let store = CalendarStore(directory: directory)
        guard try store.load() == CalendarState() else { throw CalendarArchiveError.invalid }
        try store.save(content.state)
        if let source = content.source {
            let cache = directory.appendingPathComponent("Cache", isDirectory: true)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false)
            try encodeSource(source).write(to: cache.appendingPathComponent("\(source.connection.uuidString).json"), options: .atomic)
        }
        let reread = CalendarStore(directory: directory)
        guard try reread.load() == content.state, !reread.recovered else { throw LibraryArchiveError.incomplete }
        if let source = content.source {
            guard readCache(directory: directory, connection: source.connection) == source else { throw LibraryArchiveError.incomplete }
        }
    }
}
