import Foundation

/// Abgleich zwischen den noty-Apps auf demselben iPad über einen gemeinsamen
/// App-Group-Ordner (docs/APP-SYNC.md). Einbahnstraße: Eine Quelle legt einen
/// geprüften Abzug ihrer ganzen Bibliothek ab, Spiegel-Apps übernehmen ihn als
/// eigenen Bereich. Die normale noty ist immer nur Quelle: Sie liest nie aus dem
/// gemeinsamen Ordner, und kein Abgleich schreibt je in ihre Bibliothek.
public enum AppSyncChannel: String, Codable, CaseIterable, Sendable {
    case stable, dev, ai

    public var appName: String {
        switch self {
        case .stable: "noty"
        case .dev: "noty dev"
        case .ai: "noty AI"
        }
    }

    /// Legt einen Abzug der eigenen Bibliothek im gemeinsamen Ordner ab.
    public var publishes: Bool { self != .ai }

    /// Quellen, deren Abzüge diese App als Spiegel übernimmt. Die normale noty
    /// übernimmt nie etwas: ihre Hefte ändert nur sie selbst.
    public var mirrors: [AppSyncChannel] {
        switch self {
        case .stable: []
        case .dev: [.stable]
        case .ai: [.stable, .dev]
        }
    }

    /// Die App-ID entscheidet, nicht allein die Info.plist-Angabe: Die normale
    /// noty ist immer `stable` (auch bei fehlender oder falscher Angabe), und
    /// keine andere App kann sich als `stable` ausgeben. Unbekanntes → nil, dann
    /// gibt es weder Abzug noch Spiegel.
    public static func resolve(declared: String?, bundleID: String?) -> AppSyncChannel? {
        guard let bundleID else { return nil }
        let base = ProvisionedIdentifier.base(bundleID)
        if base == "de.la.noty.prototype" { return .stable }
        switch (declared.flatMap(AppSyncChannel.init(rawValue:)), base) {
        case (.dev?, "de.la.noty.dev"): return .dev
        case (.ai?, "de.la.noty.ai"): return .ai
        default: return nil
        }
    }
}

/// xtool stellt Kennungen beim Signieren ein- oder mehrfach `XTL-<Team>.` voran,
/// App Groups als `group.XTL-<Team>.<Name>`.
public enum ProvisionedIdentifier {
    public static func base(_ identifier: String) -> String {
        var parts = identifier.split(separator: ".", omittingEmptySubsequences: false)
        while let first = parts.first, first.hasPrefix("XTL-"), parts.count > 1 { parts.removeFirst() }
        return parts.joined(separator: ".")
    }

    /// Mögliche Gruppenkennungen dieser App, die signierte zuerst.
    public static func groupCandidates(_ group: String, bundleID: String?) -> [String] {
        var result: [String] = []
        if let prefix = bundleID?.split(separator: ".").first, prefix.hasPrefix("XTL-") {
            result.append("group.\(prefix).\(group)")
        }
        result.append("group.\(group)")
        return result
    }
}

/// Inhalt von `current.json`: der zuletzt vollständig abgelegte Abzug einer Quelle.
public struct AppSyncSnapshot: Codable, Equatable, Sendable {
    public var formatVersion = 1
    public let channel: AppSyncChannel
    public let sequence: Int
    public let createdAt: Date
    public let file: LibraryArchiveFileInfo
    public let notebooks: Int
    /// Inhalt ohne Erstellungszeit (`contentKey`): gleicher Schlüssel = nichts geändert.
    public let content: String
    public var fileName: String { AppSyncOutbox.fileName(sequence) }

    /// SHA-256 über Index, Werkzeugeinstellungen und die Prüfsummen der
    /// Heftblöcke (sortierte Schlüssel, Bildoriginale per Hash referenziert).
    public static func contentKey(_ summary: LibraryArchiveSummary) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(summary.snapshot)
        data.append(0); data.append(try encoder.encode(summary.toolbar))
        for chunk in summary.notebooks { data.append(Data("\n\(chunk.id.uuidString):\(chunk.byteCount):\(chunk.crc32)".utf8)) }
        return SHA256.hexDigest(data)
    }
}

public enum AppSyncError: LocalizedError, Equatable {
    case notAllowed, invalidSnapshot, changedWhileCopying
    public var errorDescription: String? {
        switch self {
        case .notAllowed: "Diese App übernimmt keine Abzüge anderer noty-Apps."
        case .invalidSnapshot: "Der Abzug im gemeinsamen Ordner ist unvollständig oder beschädigt."
        case .changedWhileCopying: "Der Abzug wurde während des Kopierens ersetzt; nächster Versuch später."
        }
    }
}

/// Der Ordner einer Quelle: `<Gruppe>/NotySync/v1/<Kanal>/`. Nur die Quelle
/// selbst schreibt hinein. Reihenfolge wie beim Revisionscommit: Abzug als
/// `.partial` kopieren und prüfen, umbenennen, `current.json` zuletzt ersetzen.
/// Der vorige Abzug bleibt liegen, damit ein Spiegel, der gerade kopiert, nicht
/// den Boden verliert; ältere werden danach entfernt. Andere Namen nie.
public enum AppSyncOutbox {
    public static let currentName = "current.json"
    static let maximumRecord = 16_000

    public static func directory(groupRoot: URL, channel: AppSyncChannel) -> URL {
        groupRoot.appendingPathComponent("NotySync/v1/\(channel.rawValue)", isDirectory: true)
    }
    static func fileName(_ sequence: Int) -> String { "snapshot-\(sequence).notylibrary" }
    static func sequence(of name: String) -> Int? {
        guard name.hasPrefix("snapshot-"), name.hasSuffix(".notylibrary") else { return nil }
        let digits = name.dropFirst("snapshot-".count).dropLast(".notylibrary".count)
        guard !digits.isEmpty, digits.count <= 18, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(digits) else { return nil }
        return fileName(value) == name ? value : nil
    }

    /// Legt `archive` (bereits vollständig geprüft, Größe/CRC `file`) ab.
    @discardableResult
    public static func publish(archive: URL, summary: LibraryArchiveSummary, channel: AppSyncChannel,
                               groupRoot: URL, now: Date = Date()) throws -> AppSyncSnapshot {
        let file = summary.file
        guard channel.publishes else { throw AppSyncError.notAllowed }
        let fm = FileManager.default
        let folder = directory(groupRoot: groupRoot, channel: channel)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try ContainedDirectory.require(folder, below: groupRoot)
        let previous = try? read(groupRoot: groupRoot, channel: channel)
        let sequence = max((previous?.sequence ?? 0) + 1, existingSequences(folder).max().map { $0 + 1 } ?? 1)
        let partial = folder.appendingPathComponent(fileName(sequence) + ".partial")
        try? fm.removeItem(at: partial)
        let copied = try BoundedFile.copy(from: archive, to: partial)
        guard copied == file, try BoundedFile.checksum(partial) == file else {
            try? fm.removeItem(at: partial)
            throw AppSyncError.changedWhileCopying
        }
        let final = folder.appendingPathComponent(fileName(sequence))
        try fm.moveItem(at: partial, to: final)
        let snapshot = AppSyncSnapshot(channel: channel, sequence: sequence, createdAt: Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down)), file: file,
                                      notebooks: summary.notebooks.count, content: try AppSyncSnapshot.contentKey(summary))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(to: folder.appendingPathComponent(currentName), options: .atomic)
        prune(folder, keeping: [sequence, previous?.sequence].compactMap { $0 })
        return snapshot
    }

    private static func existingSequences(_ folder: URL) -> [Int] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).compactMap { name in
            sequence(of: name.hasSuffix(".partial") ? String(name.dropLast(".partial".count)) : name)
        }
    }

    /// Nur eigene `snapshot-<n>.notylibrary[.partial]`, nie fremde Namen oder Ordner.
    private static func prune(_ folder: URL, keeping: [Int]) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] {
            let isPartial = name.hasSuffix(".partial")
            guard let value = sequence(of: isPartial ? String(name.dropLast(".partial".count)) : name),
                  isPartial || !keeping.contains(value) else { continue }
            let url = folder.appendingPathComponent(name)
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            try? fm.removeItem(at: url)
        }
    }

    /// Der zuletzt abgelegte Abzug einer Quelle, nil wenn es noch keinen gibt.
    public static func read(groupRoot: URL, channel: AppSyncChannel) throws -> AppSyncSnapshot? {
        let folder = directory(groupRoot: groupRoot, channel: channel)
        let url = folder.appendingPathComponent(currentName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try ContainedDirectory.require(folder, below: groupRoot)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(AppSyncSnapshot.self, from: BoundedFile.read(url, limit: maximumRecord)),
              snapshot.formatVersion == 1, snapshot.channel == channel, snapshot.sequence > 0, snapshot.notebooks >= 0,
              snapshot.file.byteCount > 0, snapshot.file.byteCount <= LibraryArchive.maximumBytes,
              snapshot.content.count == 64, snapshot.content.allSatisfy({ $0.isHexDigit }) else {
            throw AppSyncError.invalidSnapshot
        }
        return snapshot
    }

    public static func archiveURL(_ snapshot: AppSyncSnapshot, groupRoot: URL) -> URL {
        directory(groupRoot: groupRoot, channel: snapshot.channel).appendingPathComponent(snapshot.fileName)
    }
}

/// Was ein Spiegel sich je Quelle merkt (in der Spiegel-App, nie im gemeinsamen Ordner).
public struct AppSyncMirrorState: Codable, Equatable, Sendable {
    public var sequence: Int
    public var content: String
    public var area: UUID
    public var importedAt: Date
    /// Ältere Spiegelbereiche, deren Entfernen noch aussteht (z. B. weil sie offen waren).
    public var stale: [UUID]
    public init(sequence: Int, content: String, area: UUID, importedAt: Date, stale: [UUID] = []) {
        self.sequence = sequence; self.content = content; self.area = area; self.importedAt = importedAt; self.stale = stale
    }
}

public enum AppSyncMirrorDecision: Equatable, Sendable {
    case upToDate
    /// Der aktuelle Spiegelbereich ist geöffnet; erst nach dem Verlassen ersetzen.
    case waitForArea
    case importSnapshot
}

public enum AppSyncMirror {
    public static func decide(_ snapshot: AppSyncSnapshot?, state: AppSyncMirrorState?, activeArea: UUID?) -> AppSyncMirrorDecision {
        guard let snapshot else { return .upToDate }
        if let state, state.content == snapshot.content { return .upToDate }
        if let state, state.area == activeArea { return .waitForArea }
        return .importSnapshot
    }
}
