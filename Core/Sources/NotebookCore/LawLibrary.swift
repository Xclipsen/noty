import Foundation

public enum LawError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
}

public struct LawCatalog: Codable, Sendable {
    public var schemaVersion: Int? = nil
    public var laws: [LawEntry]
    public var administrative: [LawEntry]?
    public var generatedAt: String
    public var entries: [LawEntry] { laws + (administrative ?? []) }
    public func validated() throws -> Self {
        guard schemaVersion == nil || schemaVersion == 1 else { throw LawError.invalid("Dieses Gesetzeskatalogformat ist neuer als die App. Bestehende Daten bleiben erhalten.") }
        guard entries.count <= 500, Set(entries.map(\.id)).count == entries.count else { throw LawError.invalid("Ungültiger Gesetzeskatalog.") }
        for law in entries {
            guard LawEntry.safeID(law.id), !law.versions.isEmpty, law.versions.count <= 1000,
                  Set(law.versions.map(\.id)).count == law.versions.count,
                  law.versions.contains(where: { $0.id == law.currentVersion }) else { throw LawError.invalid("Ungültige Gesetzesfassung.") }
            for v in law.versions {
                guard LawEntry.safeID(v.id), v.sectionCount > 0, v.sectionCount <= 100_000,
                      v.dataUrl == "/data/laws/\(law.id)/\(v.id)/law.json",
                      v.pdfUrl == nil || v.pdfUrl == "/data/laws/\(law.id)/\(v.id)/law.pdf" else { throw LawError.invalid("Unsicherer Gesetzespfad.") }
            }
        }
        return self
    }
}
public extension LawCatalog {
    /// This new catalog with what `old` still knows, so old markings remain
    /// navigable: versions the new catalog no longer lists stay with their
    /// entry, and an entry that is gone stays in its old list.
    ///
    /// Both lists count as one: a document that moved between `laws` and
    /// `administrative` is listed once, where the new catalog has it, with
    /// its old versions. Kept twice, its ID would fail `validated()` and with
    /// it every further update.
    func retaining(_ old: LawCatalog?) -> LawCatalog {
        guard let old else { return self }
        var previous: [String: LawEntry] = [:]
        for entry in old.entries where previous[entry.id] == nil { previous[entry.id] = entry }
        var listed = Set(entries.map(\.id))
        func merged(_ entries: [LawEntry], old: [LawEntry]) -> [LawEntry] {
            var result = entries.map { entry in
                var e = entry
                if let before = previous[e.id] { e.versions += before.versions.filter { v in !e.versions.contains(where: { $0.id == v.id }) } }
                return e
            }
            for entry in old where listed.insert(entry.id).inserted { result.append(entry) }
            return result
        }
        var next = self
        next.laws = merged(laws, old: old.laws)
        next.administrative = merged(administrative ?? [], old: old.administrative ?? [])
        return next
    }
}
public struct LawEntry: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var abbr: String
    public var name: String
    public var category: String
    public var kind: String
    public var aliases: [String]?
    public var currentVersion: String
    public var versions: [LawVersion]
    public static func safeID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 100 && value.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil
    }
}
public struct LawVersion: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var status: [String]
    public var dataUrl: String
    public var pdfUrl: String?
    public var pages: Int
    public var sectionCount: Int
    public var sha256: [String: String]
}
public struct LawDocument: Codable, Sendable {
    public var schemaVersion: Int? = nil
    public var id: String
    public var abbr: String
    public var name: String
    public var kind: String
    public var version: String
    public var status: [String]
    public var sourceUrl: String
    public var sections: [LawSection]
    public var textNote: String?
    public func validated(for entry: LawEntry, version target: LawVersion) throws -> Self {
        try Self.checkHeader(schemaVersion: schemaVersion, id: id, version: version, sectionIDs: sections.map(\.id), for: entry, version: target)
        guard sections.allSatisfy({ $0.text.utf8.count < 8_000_000 }) else { throw LawError.invalid("Gesetzesdatei passt nicht zum Katalog.") }
        var checked = self
        // A PDF page below 1 (or a non-finite top) is no position: the section
        // then has none, like one the server sent without it.
        for index in checked.sections.indices where checked.sections[index].pdf.map({ $0.page < 1 || !$0.top.isFinite }) == true {
            checked.sections[index].pdf = nil
        }
        return checked
    }
    /// The catalogue rules of `validated(for:version:)` apart from the section
    /// texts; shared with `LawDocumentHeader` so both stay the same.
    static func checkHeader(schemaVersion: Int?, id: String, version: String, sectionIDs: [String],
                            for entry: LawEntry, version target: LawVersion) throws {
        guard schemaVersion == nil || (1...2).contains(schemaVersion ?? 0) else { throw LawError.invalid("Dieses Gesetzesformat ist neuer als die App.") }
        guard id == entry.id, version == target.id, sectionIDs.count == target.sectionCount,
              !sectionIDs.isEmpty, Set(sectionIDs).count == sectionIDs.count,
              sectionIDs.allSatisfy({ !$0.isEmpty }) else { throw LawError.invalid("Gesetzesdatei passt nicht zum Katalog.") }
    }
}
/// Only what `hasDocument` checks against the current catalogue: no section
/// texts, notes or HTML are materialized.
struct LawDocumentHeader: Decodable {
    struct Section: Decodable { var id: String }
    var schemaVersion: Int?
    var id: String
    var version: String
    var sections: [Section]
    func check(for entry: LawEntry, version target: LawVersion) throws {
        try LawDocument.checkHeader(schemaVersion: schemaVersion, id: id, version: version, sectionIDs: sections.map(\.id),
                                    for: entry, version: target)
    }
}
public struct LawSection: Codable, Sendable, Identifiable {
    public struct PDFPosition: Codable, Sendable { public var page: Int; public var top: Double }
    public var id: String
    public var label: String
    public var keys: [String]
    public var title: String
    public var text: String
    public var html: String?
    public var notes: String
    public var pdf: PDFPosition?
}

public struct LawReference: Equatable, Sendable {
    public var key: String
    public var paragraph: String?
    /// Compiled once: quick search parses every alias split of each query.
    /// „§“, „Art.“, „Abschnitt“, „R“ or „Zu §“, the number, an Absatz and any
    /// finer qualifiers („Satz 1 Nr. 3 Buchst. a“). The reference has no field
    /// for those: they are accepted and lead to the Absatz or the provision.
    private static let pattern = try? NSRegularExpression(
        pattern: "^(?:§\\s*|Art(?:ikel|\\.)?\\s*|Abschnitt\\s*|R\\s*|Zu\\s*§\\s*)?(\\d+[a-z]*(?:\\.\\d+[a-z]*)*)\\.?(?:\\s*(?:Abs(?:atz)?\\.?|\\()\\s*(\\d+[a-z]*)\\)?)?"
            + "(?:\\s*,?\\s*(?:Satz|S\\.|Nr\\.?|Nummer|Buchst\\.?|Buchstabe|lit\\.?|Halbsatz|Hs\\.?|Alt\\.?|Alternative)\\s*(?:\\d+[a-z]*|[a-z]{1,2})\\.?)*$",
        options: .caseInsensitive)
    public static func parse(_ input: String) -> Self? {
        let text = cleaned(input)
        guard let re = pattern, let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let value = text as NSString
        return Self(key: value.substring(with: m.range(at: 1)).lowercased(), paragraph: m.range(at: 2).location == NSNotFound ? nil : value.substring(with: m.range(at: 2)).lowercased())
    }
    /// The input without surrounding white space and the punctuation closing a
    /// sentence („§ 35a EStG.“ copied from a text).
    static func cleaned(_ input: String) -> String {
        var value = Substring(input.trimmingCharacters(in: .whitespacesAndNewlines))
        while let last = value.last, ".,;:!?".contains(last) { value = value.dropLast() }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
public extension LawEntry {
    /// Documents cited by article instead of „§“.
    private static let articleLaws: Set<String> = ["gg", "euv", "aeuv", "grch", "emrk", "egbgb", "eghgb"]
    /// „§ 35a Abs. 2 EStG“, „Art. 3 GG“, „R 9.1 LStR“, „Abschnitt 1.1 UStAE“,
    /// „AEAO zu § 122“: how a provision of this document is written when its
    /// own label is not at hand (it is missing in the version shown).
    func citation(key: String, paragraph: String?) -> String {
        let absatz = paragraph.map { " Abs. \($0)" } ?? ""
        guard kind == "administration" else {
            return (Self.articleLaws.contains(id.lowercased()) ? "Art. " : "§ ") + key + absatz + " " + abbr
        }
        switch id.lowercased() {
        case "aeao": return "\(abbr) zu § \(key)"
        case "ustae": return "Abschnitt \(key)\(absatz) \(abbr)"
        // Richtlinien („LStR“, „EStR“) are cited with „R“, anything else by its number alone.
        default: return (abbr.hasSuffix("R") ? "R " : "") + key + absatz + " " + abbr
        }
    }
}
public struct LawQuickTarget: Equatable, Sendable {
    public var lawID: String
    public var reference: LawReference
    public static func parse(_ input: String, entries: [LawEntry]) -> Self? {
        let query = LawReference.cleaned(input)
        var matches: [Self] = []
        for entry in entries {
            for alias in [entry.abbr, entry.id] + (entry.aliases ?? []) + (entry.id == "hgb" ? ["HBG"] : []) {
                let escaped = NSRegularExpression.escapedPattern(for: alias).replacingOccurrences(of: " ", with: "\\s+")
                for pattern in ["^\(escaped)\\s+(.+)$", "^(.+?)\\s+\(escaped)$"] {
                    guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                          let match = re.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)),
                          let range = Range(match.range(at: 1), in: query), let ref = LawReference.parse(String(query[range])) else { continue }
                    let target = Self(lawID: entry.id, reference: ref)
                    if !matches.contains(target) { matches.append(target) }
                }
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }
}

/// What one refused entry means for the rest of a sync push. One refused entry
/// only skips that entry. A permanent refusal (`isPermanent`) is marked in the
/// store and waits for „Erneut versuchen“/„Nur lokal behalten“; any other 4xx
/// is sent again next time. Temporary server trouble may be one bad entry too,
/// but three in a row stop the push instead of hammering a broken server.
public struct LawPushFailures: Sendable {
    public enum Step: Equatable, Sendable { case next, stop }
    public private(set) var refused = 0
    private var serverFailures = 0
    public init() {}
    public mutating func record(status: Int) -> Step {
        refused += 1
        guard status >= 500 || status == 408 || status == 429 else { return .next }
        serverFailures += 1
        return serverFailures >= 3 ? .stop : .next
    }
    /// 400, 409 (except `deleted`, which means the ID is deleted on the
    /// server for ever) and 413: sending the same entry again cannot succeed.
    public static func isPermanent(status: Int, code: String?) -> Bool {
        status == 400 || status == 413 || (status == 409 && code != "deleted")
    }
}

/// One sync run at a time (B9): a request during a run is not dropped but
/// makes that run go once more when it ends.
public struct LawSyncGate: Sendable {
    public private(set) var running = false
    public private(set) var requested = false
    public init() {}
    /// `true`: start a run now. `false`: a run is going; it runs once more.
    public mutating func request() -> Bool {
        if running { requested = true; return false }
        running = true
        return true
    }
    /// After each run. `true`: requested meanwhile, run again (still running).
    public mutating func finish() -> Bool {
        if requested { requested = false; return true }
        running = false
        return false
    }
    /// Stops without another run (e.g. signed out); a later `request` starts afresh.
    public mutating func stop() { running = false; requested = false }
}

/// The personal sync state for display (B9). „Synchronisiert“ only with an
/// empty outbox; refused entries are counted apart and keep the state from
/// reading as synchronised.
public struct LawSyncStatus: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// Not signed in: everything stays on this iPad.
        case guest
        /// Signed in, but the collection or the sync switch is off.
        case paused
        /// Signed in, the session has expired.
        case expired
        case syncing
        /// The last run failed (offline, server); the text says why.
        case failed(String)
        /// Entries wait to be sent (`pending` > 0).
        case pending
        /// Nothing waits, but `rejected` entries need a decision.
        case rejected
        /// Outbox empty, nothing refused.
        case synced
    }
    public var state: State
    /// The owner's entries waiting to be sent (refused and kept-local ones excluded).
    public var pending: Int
    /// Refused for good, waiting for „Erneut versuchen“ or „Nur lokal behalten“.
    public var rejected: Int
    public var lastSynced: Date?
    public init(state: State, pending: Int = 0, rejected: Int = 0, lastSynced: Date? = nil) {
        self.state = state; self.pending = pending; self.rejected = rejected; self.lastSynced = lastSynced
    }
    public static func derive(signedIn: Bool, sessionExpired: Bool, enabled: Bool, syncEnabled: Bool, running: Bool,
                              pending: Int, rejected: Int, lastError: String?, lastSynced: Date?) -> Self {
        let state: State
        if !signedIn { state = .guest }
        else if sessionExpired { state = .expired }
        else if !enabled || !syncEnabled { state = .paused }
        else if running { state = .syncing }
        else if let lastError { state = .failed(lastError) }
        else if pending > 0 { state = .pending }
        else if rejected > 0 { state = .rejected }
        else if lastSynced == nil { state = .pending }
        else { state = .synced }
        return Self(state: state, pending: pending, rejected: rejected, lastSynced: lastSynced)
    }
    /// Nothing leaves this iPad now (guest, paused, expired).
    public var isLocalOnly: Bool { [.guest, .paused, .expired].contains(state) }
    public var isSynced: Bool { state == .synced }
    /// German one-line description („Abgleich“ throughout); `time` formats
    /// `lastSynced`. A failure says what it means for the user, never a
    /// server message or HTTP code.
    public func text(time: (Date) -> String) -> String {
        let waiting = pending == 1 ? "1 Änderung wartet" : "\(pending) Änderungen warten"
        let refused = rejected == 1 ? "1 Eintrag abgelehnt" : "\(rejected) Einträge abgelehnt"
        var parts: [String]
        switch state {
        case .guest: parts = ["Nur auf diesem iPad"]
        case .paused: parts = ["Abgleich ist aus · Einschalten unter Einstellungen › Gesetzessammlung"]
        case .expired: parts = ["Anmeldung abgelaufen · Unter Einstellungen › Konto erneut anmelden"]
        case .syncing: parts = ["Wird abgeglichen …"]
        case .failed: parts = ["Keine Verbindung – Änderungen bleiben auf diesem iPad und werden später gesendet"]
        case .pending: parts = [pending > 0 ? waiting : "Noch nicht abgeglichen"]
        case .rejected: parts = [refused]
        case .synced: parts = ["Abgeglichen" + (lastSynced.map { " · \(time($0))" } ?? "")]
        }
        if state != .guest {
            if pending > 0, state != .pending { parts.append(waiting) }
            if rejected > 0, state != .rejected { parts.append(refused) }
        }
        return parts.joined(separator: " · ")
    }
}

/// Where the reader was in one law (B10): version, text or PDF, section,
/// PDF page and offset. Stored per law by `LawReadingSpots`.
public struct LawReadingSpot: Codable, Equatable, Sendable {
    public enum View: String, Codable, Sendable { case text, pdf }
    public var lawId: String
    /// `nil`: the current version.
    public var versionId: String?
    public var view: View
    public var sectionId: String?
    /// PDF page, 1-based (`view == .pdf`).
    public var pdfPage: Int?
    /// Reader-defined offset (finite): text, points from the top of the
    /// section; PDF, 0…1 of the page height from its top.
    public var offset: Double?
    public init(lawId: String, versionId: String? = nil, view: View = .text, sectionId: String? = nil, pdfPage: Int? = nil, offset: Double? = nil) {
        self.lawId = lawId; self.versionId = versionId; self.view = view; self.sectionId = sectionId; self.pdfPage = pdfPage; self.offset = offset
    }
    public var isValid: Bool {
        LawEntry.safeID(lawId) && (versionId.map(LawEntry.safeID) ?? true) && (sectionId.map { !$0.isEmpty && $0.count <= 200 } ?? true)
            && (pdfPage.map { (1...100_000).contains($0) } ?? true) && (offset.map(\.isFinite) ?? true)
    }
}
public struct LawReadingSpots: Codable, Equatable, Sendable {
    public private(set) var spots: [String: LawReadingSpot] = [:]
    public private(set) var lastLawId: String?
    public static let limit = 1000
    public init() {}
    /// Stored JSON, else the older section-only keys (`noty.laws.readingSections`,
    /// `noty.laws.lastLaw`). Invalid entries are dropped, never trusted.
    public static func decode(_ data: Data?, legacySections: [String: String]? = nil, legacyLast: String? = nil) -> Self {
        var result = Self()
        if let data, data.count <= 2_000_000, let stored = try? JSONDecoder().decode(Self.self, from: data) {
            for (law, spot) in stored.spots where spot.lawId == law && spot.isValid && result.spots.count < limit { result.spots[law] = spot }
            result.lastLawId = stored.lastLawId.flatMap { result.spots[$0] == nil ? nil : $0 }
        }
        for (law, section) in legacySections ?? [:] where result.spots[law] == nil && result.spots.count < limit {
            let spot = LawReadingSpot(lawId: law, sectionId: section)
            if spot.isValid { result.spots[law] = spot }
        }
        if result.lastLawId == nil, let legacyLast, result.spots[legacyLast] != nil { result.lastLawId = legacyLast }
        return result
    }
    public func spot(law: String) -> LawReadingSpot? { spots[law] }
    public var last: LawReadingSpot? { lastLawId.flatMap { spots[$0] } }
    /// `false` when nothing changed or the spot is invalid.
    @discardableResult
    public mutating func remember(_ spot: LawReadingSpot) -> Bool {
        guard spot.isValid, spots[spot.lawId] != spot || lastLawId != spot.lawId else { return false }
        if spots[spot.lawId] == nil, spots.count >= Self.limit, let drop = spots.keys.first(where: { $0 != lastLawId }) { spots[drop] = nil }
        spots[spot.lawId] = spot; lastLawId = spot.lawId
        return true
    }
}

/// One serial owner for the separate law store. Immutable data files are written
/// before the catalog is atomically replaced; a failed download keeps the old catalog.
public actor LawOfflineStore {
    public let root: URL
    public init(root: URL) { self.root = root }
    private var catalogURL: URL { root.appendingPathComponent("catalog.json") }
    public func catalog() throws -> LawCatalog? {
        guard FileManager.default.fileExists(atPath: catalogURL.path) else { return nil }
        guard (try catalogURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 8_000_000 else { throw LawError.invalid("Gesetzeskatalog zu groß.") }
        return try JSONDecoder().decode(LawCatalog.self, from: Data(contentsOf: catalogURL)).validated()
    }
    public func document(_ entry: LawEntry, version: LawVersion) throws -> LawDocument {
        let url = try documentURL(entry.id, version: version.id)
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 64_000_000 else { throw LawError.invalid("Gesetzesdatei zu groß.") }
        return try JSONDecoder().decode(LawDocument.self, from: Data(contentsOf: url)).validated(for: entry, version: version)
    }
    /// Whether this version is usable offline, without fully decoding it
    /// when possible: a stored file whose SHA-256 equals the catalogue's
    /// `json` hash is byte for byte the download `putDocument` checked and
    /// wrote unchanged, so only the catalogue rules that can change since
    /// (format version, identity, section count and IDs) are checked again on
    /// a light decode (`LawDocumentHeader`, no section texts). Without a hash,
    /// or on any mismatch, the full validation decides; a file failing either
    /// is not usable, so it is downloaded again or the update fails as before.
    /// Reading (`document`) always validates fully.
    public func hasDocument(_ entry: LawEntry, version: LawVersion) -> Bool {
        guard let url = try? documentURL(entry.id, version: version.id),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 64_000_000 else { return false }
        if let sha = version.sha256["json"], sha.count == 64,
           let data = try? Data(contentsOf: url, options: .alwaysMapped),
           SHA256.hexDigest(data) == sha {
            return (try? JSONDecoder().decode(LawDocumentHeader.self, from: data).check(for: entry, version: version)) != nil
        }
        return (try? document(entry, version: version)) != nil
    }
    public func documentURL(_ id: String, version: String) throws -> URL {
        guard LawEntry.safeID(id), LawEntry.safeID(version) else { throw LawError.invalid("Ungültige Gesetzeskennung.") }
        return root.appendingPathComponent("laws/\(id)/\(version)/law.json")
    }
    public func putDocument(_ data: Data, entry: LawEntry, version: LawVersion) throws {
        guard data.count <= 64_000_000 else { throw LawError.invalid("Gesetzesdatei zu groß.") }
        _ = try JSONDecoder().decode(LawDocument.self, from: data).validated(for: entry, version: version)
        let url = try documentURL(entry.id, version: version.id)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            let stored = try Data(contentsOf: url)
            if stored == data { return }
            // A valid stored version is immutable. One that no longer validates
            // (damaged, or the catalogue says otherwise) would stay unreadable
            // for ever; the checked download replaces it.
            let usable = (try? JSONDecoder().decode(LawDocument.self, from: stored).validated(for: entry, version: version)) != nil
            guard !usable else { throw LawError.invalid("Eine unveränderliche Gesetzesfassung wurde verändert.") }
        }
        try data.write(to: url, options: .atomic)
    }
    public func publish(_ catalog: LawCatalog) throws {
        if FileManager.default.fileExists(atPath: catalogURL.path) { _ = try self.catalog() }
        _ = try catalog.validated()
        for entry in catalog.entries {
            guard let v = entry.versions.first(where: { $0.id == entry.currentVersion }) else { throw LawError.invalid("Fassung fehlt.") }
            // Hash-identical files: header rules only (texts were checked when written).
            if !hasDocument(entry, version: v) { _ = try document(entry, version: v) }
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(catalog).write(to: catalogURL, options: .atomic)
    }
    public func pdfURL(_ id: String, version: String) throws -> URL { try documentURL(id, version: version).deletingLastPathComponent().appendingPathComponent("law.pdf") }
    public func pdfData(_ id: String, version: String) throws -> Data {
        let url = try pdfURL(id, version: version)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 150_000_000 else { throw LawError.invalid("Gespeicherte PDF-Datei zu groß.") }
        return try Data(contentsOf: url)
    }
    /// `replacingDamaged`: the caller found the stored file unusable and checked `data`.
    public func putPDF(_ data: Data, id: String, version: String, replacingDamaged: Bool = false) throws -> URL {
        guard data.count <= 150_000_000, data.starts(with: Data("%PDF-".utf8)) else { throw LawError.invalid("Ungültige PDF-Datei.") }
        let url = try pdfURL(id, version: version)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !replacingDamaged, FileManager.default.fileExists(atPath: url.path) {
            guard try Data(contentsOf: url) == data else { throw LawError.invalid("Die gespeicherte PDF-Fassung wurde verändert.") }
        } else { try data.write(to: url, options: .atomic) }
        return url
    }
    public func byteCount() -> Int64 {
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        return files.compactMap { $0 as? URL }.reduce(Int64(0)) { total, url in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true else { return total }
            return total + Int64(values.fileSize ?? 0)
        }
    }
}

/// The website's canonical anchors count UTF-16 code units after NFKC/lowercase
/// and removal of every non-letter/non-number, including combining marks.
///
/// Mirrors `canonicalText`, `canonicalMap` and `anchorFromSelection` of the
/// website (`lib/annotations.ts`) and `canonical` of the account server
/// exactly, code unit for code unit (fixture: `Core/Tests/Fixtures/law-canonical.json`,
/// made by `scripts/make_law_canonical_fixture.mjs`):
/// - lowercase like JavaScript `toLowerCase()`: full Unicode mappings without
///   locale, capital sigma becomes final `ς` by the Final_Sigma context rule;
/// - mapping clusters like `/\P{M}\p{M}*|\p{M}+/gu` (a base plus its marks),
///   not Swift's grapheme clusters;
/// - comparisons on UTF-16 code units, not Swift's canonical equivalence.
public enum LawTextAnchor {
    public static func canonical(_ text: String) -> String {
        let lowered = lowercasedLikeJavaScript(text.precomposedStringWithCompatibilityMapping)
        return String(String.UnicodeScalarView(lowered.unicodeScalars.filter(isLetterOrNumber)))
    }
    static func isLetterOrNumber(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber, .letterNumber, .otherNumber: true
        default: false
        }
    }
    static func isMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: true
        default: false
        }
    }
    /// `String.prototype.toLowerCase()`: context-free full mappings plus the
    /// one unconditional context rule, Final_Sigma (Unicode 3.13).
    public static func lowercasedLikeJavaScript(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var result = String.UnicodeScalarView()
        for (index, scalar) in scalars.enumerated() {
            if scalar.value == 0x03A3 {
                result.append(finalSigma(scalars, at: index) ? "\u{03C2}" : "\u{03C3}")
            } else {
                result.append(contentsOf: scalar.properties.lowercaseMapping.unicodeScalars)
            }
        }
        return String(result)
    }
    private static func finalSigma(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        var before = index - 1
        while before >= 0, scalars[before].properties.isCaseIgnorable { before -= 1 }
        guard before >= 0, scalars[before].properties.isCased else { return false }
        var after = index + 1
        while after < scalars.count, scalars[after].properties.isCaseIgnorable { after += 1 }
        return !(after < scalars.count && scalars[after].properties.isCased)
    }
    /// The canonical text with, for each of its UTF-16 code units, the
    /// original UTF-16 range it came from; `nil` where context-sensitive
    /// lowercasing makes offsets uncertain (website `canonicalMap`).
    public struct Map: Equatable, Sendable {
        public var text: String
        public var units: [UInt16]
        public var starts: [Int]
        public var ends: [Int]
    }
    public static func canonicalMap(_ source: String) -> Map? {
        var units: [UInt16] = [], starts: [Int] = [], ends: [Int] = []
        var cluster = String.UnicodeScalarView(), clusterStart = 0, offset = 0
        func flush() {
            guard !cluster.isEmpty else { return }
            defer { cluster = String.UnicodeScalarView() }
            // Fast path, identical result: a lone ASCII scalar is unchanged by
            // NFKC and kept (lowercased) only as letter or digit.
            if cluster.count == 1, let only = cluster.first, only.isASCII {
                var value = UInt16(only.value)
                switch value {
                case 0x41...0x5A: value += 0x20
                case 0x61...0x7A, 0x30...0x39: break
                default: return
                }
                units.append(value); starts.append(clusterStart); ends.append(offset)
                return
            }
            for unit in canonical(String(cluster)).utf16 { units.append(unit); starts.append(clusterStart); ends.append(offset) }
        }
        for scalar in source.unicodeScalars {
            // A new cluster starts at every non-mark; leading marks stay together.
            if !isMark(scalar) { flush(); clusterStart = offset }
            else if cluster.isEmpty { clusterStart = offset }
            cluster.append(scalar)
            offset += scalar.utf16.count
        }
        flush()
        let text = canonical(source)
        guard Array(text.utf16) == units else { return nil }
        return Map(text: text, units: units, starts: starts, ends: ends)
    }
    public static func originalRange(text: String, anchor: LawAnchor) -> NSRange? {
        originalRanges(text: text, anchors: [anchor]).first ?? nil
    }
    /// The original range of each anchor in `text`; `nil` when the quote no
    /// longer matches exactly or offsets are uncertain.
    public static func originalRanges(text: String, anchors: [LawAnchor]) -> [NSRange?] {
        guard let map = canonicalMap(text) else { return anchors.map { _ in nil } }
        return anchors.map { anchor in
            guard anchor.start >= 0, anchor.end > anchor.start, anchor.end <= map.units.count,
                  map.units[anchor.start..<anchor.end].elementsEqual(anchor.quote.utf16) else { return nil }
            return NSRange(location: map.starts[anchor.start], length: map.ends[anchor.end - 1] - map.starts[anchor.start])
        }
    }
    /// Anchor for a selection in `text`, which is also the section's stored text.
    public static func anchor(text: String, range: NSRange, sectionID: String) -> LawAnchor? {
        anchor(rendered: text, range: range, sectionText: text, sectionID: sectionID)
    }
    /// Website `anchorFromSelection`: a selection in the rendered text covers
    /// every canonical unit whose source overlaps it. When the rendered text
    /// differs from the section's stored text (tables, image alternatives),
    /// only a unique exact quote bridges the difference.
    public static func anchor(rendered: String, range: NSRange, sectionText: String, sectionID: String) -> LawAnchor? {
        let length = (rendered as NSString).length
        guard range.location != NSNotFound, range.location >= 0, range.length > 0, range.location <= length,
              range.length <= length - range.location, let map = canonicalMap(rendered) else { return nil }
        let end = range.location + range.length
        guard let from = map.ends.firstIndex(where: { $0 > range.location }) else { return nil }
        var to = from
        while to < map.starts.count, map.starts[to] < end { to += 1 }
        guard to > from, to - from <= 12000 else { return nil }
        let quoteUnits = Array(map.units[from..<to])
        let quote = String(decoding: quoteUnits, as: UTF16.self)
        let section = Array(canonical(sectionText).utf16)
        if section == map.units { return LawAnchor(sectionId: sectionID, start: from, end: to, quote: quote) }
        guard let start = uniqueIndex(of: quoteUnits, in: section) else { return nil }
        return LawAnchor(sectionId: sectionID, start: start, end: start + quoteUnits.count, quote: quote)
    }
    /// Website `uniqueIndex` on UTF-16 code units.
    static func uniqueIndex(of quote: [UInt16], in text: [UInt16]) -> Int? {
        guard !quote.isEmpty, quote.count <= text.count else { return nil }
        var found: Int?
        for start in 0...(text.count - quote.count) where text[start] == quote[0] && text[start..<(start + quote.count)].elementsEqual(quote) {
            if found != nil { return nil }
            found = start
        }
        return found
    }
}
public struct LawAnchor: Codable, Sendable, Hashable {
    public var sectionId: String
    public var start: Int
    public var end: Int
    public var quote: String
    public init(sectionId: String, start: Int, end: Int, quote: String) { self.sectionId = sectionId; self.start = start; self.end = end; self.quote = quote }
}
