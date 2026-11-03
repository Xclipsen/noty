import Foundation

public enum LawJSON: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([LawJSON]), object([String: LawJSON])
    public init(from decoder: Decoder) throws {
        guard decoder.codingPath.count <= 32 else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Gesetzesdaten zu tief verschachtelt")) }
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([LawJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: LawJSON].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    public var string: String? { if case let .string(v) = self { return v }; return nil }
    public var int: Int? { if case let .number(v) = self, v.isFinite, v >= 0, v.rounded(.towardZero) == v, v < Double(Int.max) { return Int(v) }; return nil }
}
/// Why the server refused an entry for good (400, 409 without `deleted`, 413).
public struct LawPersonalRejection: Codable, Sendable, Equatable {
    public var status: Int
    public var message: String
    /// Seconds since 1970.
    public var at: Double
    public init(status: Int, message: String, at: Double) { self.status = status; self.message = message; self.at = at }
}
public struct LawPersonalItem: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var owner: String?
    public var kind: String
    public var payload: [String: LawJSON]
    public var deleted: Bool
    public var dirty: Bool
    public var revision: Int
    /// When the deletion was made, or confirmed by the server (seconds since 1970).
    public var deletedAt: Double? = nil
    /// Set while the server refuses this entry for good; it is not sent again
    /// until „Erneut versuchen“ (`LawPersonalStore.retry`).
    public var rejection: LawPersonalRejection? = nil
    /// „Nur lokal behalten“: stays on this iPad and is never sent.
    public var localOnly: Bool? = nil
    public init(id: String, owner: String?, kind: String, payload: [String: LawJSON], deleted: Bool, dirty: Bool, revision: Int,
                deletedAt: Double? = nil, rejection: LawPersonalRejection? = nil, localOnly: Bool? = nil) {
        self.id = id; self.owner = owner; self.kind = kind; self.payload = payload; self.deleted = deleted; self.dirty = dirty
        self.revision = revision; self.deletedAt = deletedAt; self.rejection = rejection; self.localOnly = localOnly
    }
    /// Identity across owners: one entry per kind and UUID.
    public var key: String { LawPersonalRef(kind: kind, id: id).key }
    public var ref: LawPersonalRef { LawPersonalRef(kind: kind, id: id) }
    public var isKeptLocal: Bool { localOnly == true }
    /// Refused for good and still waiting for „Erneut versuchen“ or „Nur lokal behalten“.
    public var isRejected: Bool { rejection != nil && !isKeptLocal && !deleted }
    /// In the outbox: changed locally, neither refused nor kept local.
    public var awaitsUpload: Bool { dirty && rejection == nil && !isKeptLocal }
}
/// A new or replaced entry for `LawPersonalStore.batch`.
public struct LawPersonalChange: Sendable, Equatable {
    public var kind: String
    public var payload: [String: LawJSON]
    public var id: String
    public init(kind: String, payload: [String: LawJSON], id: String = UUID().uuidString.lowercased()) {
        self.kind = kind; self.payload = payload; self.id = id
    }
}
/// Names one entry (`annotation`/`bookmark` and its UUID).
public struct LawPersonalRef: Sendable, Hashable {
    public var kind: String
    public var id: String
    public init(kind: String, id: String) { self.kind = kind; self.id = id }
    public init(_ item: LawPersonalItem) { self.init(kind: item.kind, id: item.id) }
    public var key: String { "\(kind):\(id.lowercased())" }
}
/// The answer to one sent entry, recorded with all others in one write.
public struct LawPushReceipt: Sendable {
    public enum Outcome: Sendable, Equatable {
        /// 2xx (or 404 for a deletion); the server's echo of the entry, if any.
        case accepted([String: LawJSON]?)
        /// Refused for good (400, 409 without `deleted`, 413).
        case rejected(status: Int, message: String)
        /// 409 `deleted`: the ID is deleted on the server for ever.
        case deletedOnServer
    }
    public var sent: LawPersonalItem
    public var outcome: Outcome
    public init(sent: LawPersonalItem, outcome: Outcome) { self.sent = sent; self.outcome = outcome }
}
/// Duplicates found in a stored file and merged on load.
public struct LawPersonalRepair: Sendable, Equatable {
    /// Entries removed because another copy of the same kind and ID won.
    public var merged: Int
    /// Exact prior bytes, next to `personal.json`.
    public var backup: URL
}
public struct LawSyncChange: Codable, Sendable {
    public var seq: Int
    public var kind: String
    public var id: String
    public var payload: [String: LawJSON]?
    public var deleted: Bool
    public init(seq: Int, kind: String, id: String, payload: [String: LawJSON]?, deleted: Bool) {
        self.seq = seq; self.kind = kind; self.id = id; self.payload = payload; self.deleted = deleted
    }
}
public struct LawSyncPage: Codable, Sendable {
    public var changes: [LawSyncChange]
    public var cursor: Int
    public var hasMore: Bool
    public init(changes: [LawSyncChange], cursor: Int, hasMore: Bool) { self.changes = changes; self.cursor = cursor; self.hasMore = hasMore }
}
struct LawPersonalState: Codable, Equatable {
    var schemaVersion = 1
    var items: [LawPersonalItem] = []
    var cursors: [String: Int] = [:]
    var lastOwner: String?
    /// Keys (`kind:id`) of pruned tombstones. Such an ID is never created,
    /// restored or pulled again; only the payload is gone.
    var forgotten: [String]? = nil

    static let kinds: Set<String> = ["annotation", "bookmark"]
    /// Everything but uniqueness, which `load` repairs.
    var isWellFormed: Bool {
        schemaVersion == 1
            && items.allSatisfy({ UUID(uuidString: $0.id) != nil && Self.kinds.contains($0.kind) && (0...1_000_000_000).contains($0.revision) })
            && cursors.values.allSatisfy({ $0 >= 0 })
    }
    var hasDuplicates: Bool { Set(items.map(\.key)).count != items.count }
    func index() -> [String: Int] {
        var result: [String: Int] = [:]
        for (i, item) in items.enumerated() where result[item.key] == nil { result[item.key] = i }
        return result
    }
    /// One entry per kind and ID, whatever its owner (B1). The highest revision
    /// wins; on a tie a deletion, then a confirmed entry, then an account's
    /// entry. A deletion of any copy is kept: a deleted ID never comes back.
    func mergingDuplicates() -> (state: LawPersonalState, merged: Int) {
        var groups: [String: [LawPersonalItem]] = [:], order: [String] = []
        for item in items {
            if groups[item.key] == nil { order.append(item.key) }
            groups[item.key, default: []].append(item)
        }
        var next = self, merged = 0
        next.items = order.map { key in
            let copies = groups[key]!
            guard copies.count > 1 else { return copies[0] }
            merged += copies.count - 1
            func rank(_ item: LawPersonalItem) -> (Int, Int, Int, Int) { (item.revision, item.deleted ? 1 : 0, item.dirty ? 0 : 1, item.owner == nil ? 0 : 1) }
            var winner = copies[0]
            for copy in copies.dropFirst() where rank(copy) > rank(winner) { winner = copy }
            for key in LawPersonalStore.localOnlyKeys where winner.payload[key] == nil {
                winner.payload[key] = copies.lazy.compactMap { $0.payload[key] }.first
            }
            let deletions = copies.filter(\.deleted)
            if !deletions.isEmpty {
                let confirmed = deletions.contains { !$0.dirty && $0.owner == winner.owner }
                if !winner.deleted { winner.dirty = !confirmed }
                winner.deleted = true; winner.rejection = nil
                winner.deletedAt = deletions.compactMap(\.deletedAt).max()
            }
            return winner
        }
        return (next, merged)
    }
}

/// Durable outbox and deletion state. A write failure leaves the prior state
/// intact in memory and on disk. Future/corrupt formats block writes, not reset.
///
/// Every public mutation is one validated, atomic write of `personal.json`
/// (or none when nothing changed): `batch` takes any number of new and
/// removed entries, `record` all answers of one push, `apply` one pulled page.
public actor LawPersonalStore {
    /// Presentation keys only this app writes (the server echoes payloads
    /// without them): kept locally when an acknowledgement or a pulled
    /// change replaces the payload, so a highlighter colour survives syncing.
    public static let localOnlyKeys = ["color"]
    /// Confirmed deletions are pruned after this long (`pruneTombstones`).
    public static let tombstoneAge: TimeInterval = 30 * 86_400
    private static func keepingLocal(_ server: [String: LawJSON], from local: [String: LawJSON]) -> [String: LawJSON] {
        var merged = server
        for key in localOnlyKeys where merged[key] == nil { merged[key] = local[key] }
        return merged
    }
    private let url: URL
    private let now: @Sendable () -> Date
    private var state: LawPersonalState?
    private var repair: LawPersonalRepair?
    /// Completed writes of `personal.json` (tests: one change set, one write).
    private(set) var writes = 0
    public init(root: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        url = root.appendingPathComponent("personal.json"); self.now = now
    }
    private var timestamp: Double { now().timeIntervalSince1970 }
    private func load() throws -> LawPersonalState {
        if let state { return state }
        guard FileManager.default.fileExists(atPath: url.path) else { return LawPersonalState() }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 128_000_000 else { throw LawError.invalid("Markierungsbestand zu groß.") }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= 128_000_000 else { throw LawError.invalid("Markierungsbestand zu groß.") }
        struct Probe: Decodable { var schemaVersion: Int? }
        let blocked = LawError.invalid("Unbekannter oder beschädigter Markierungsbestand. Dateien bleiben erhalten.")
        guard let probe = try? JSONDecoder().decode(Probe.self, from: bytes), probe.schemaVersion == 1,
              var s = try? JSONDecoder().decode(LawPersonalState.self, from: bytes), s.isWellFormed else { throw blocked }
        if s.hasDuplicates { s = try repairDuplicates(s, original: bytes) }
        state = s
        return s
    }
    /// B1: merge instead of locking the store, after keeping the exact old bytes.
    private func repairDuplicates(_ s: LawPersonalState, original: Data) throws -> LawPersonalState {
        let (next, merged) = s.mergingDuplicates()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let folder = url.deletingLastPathComponent(), stamp = formatter.string(from: now())
        var backup = folder.appendingPathComponent("personal.json.before-repair-\(stamp)"), n = 1
        while FileManager.default.fileExists(atPath: backup.path) {
            n += 1; backup = folder.appendingPathComponent("personal.json.before-repair-\(stamp)-\(n)")
        }
        try original.write(to: backup, options: .withoutOverwriting)
        guard try Data(contentsOf: backup) == original else { throw LawError.invalid("Sicherung des Markierungsbestands fehlgeschlagen. Dateien bleiben erhalten.") }
        try write(next)
        repair = LawPersonalRepair(merged: merged, backup: backup)
        return next
    }
    private func nextRevision(_ value: Int) throws -> Int {
        guard value >= 0, value < 1_000_000_000 else { throw LawError.invalid("Ungültige Markierungsrevision. Bestand bleibt erhalten.") }
        return value + 1
    }
    private func commit(_ next: LawPersonalState) throws {
        if next == state { return }
        try write(next)
    }
    private func write(_ next: LawPersonalState) throws {
        // Never write a state `load` would have to repair or refuse.
        guard next.isWellFormed, !next.hasDuplicates else { throw LawError.invalid("Ungültiger Markierungsstand wurde nicht gespeichert.") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = try JSONEncoder().encode(next)
        guard bytes.count <= 128_000_000 else { throw LawError.invalid("Markierungsspeicher voll.") }
        try bytes.write(to: url, options: .atomic)
        state = next; writes += 1
    }
    public func items() throws -> [LawPersonalItem] { try load().items }
    public func lastOwner() throws -> String? { try load().lastOwner }
    /// The duplicate repair done while loading, once.
    public func takeRepairReport() throws -> LawPersonalRepair? {
        _ = try load()
        defer { repair = nil }
        return repair
    }
    public func adoptGuests(owner: String) throws {
        var s = try load()
        // IDs are unique across owners, so adoption cannot create duplicates.
        for i in s.items.indices where s.items[i].owner == nil {
            s.items[i].owner = owner; s.items[i].dirty = true; s.items[i].revision = try nextRevision(s.items[i].revision)
        }
        s.lastOwner = owner
        try commit(s)
    }
    /// Any number of new/replaced and removed entries of one owner as one
    /// write; all or nothing. Puts are checked first: an invalid kind or ID,
    /// a deleted or pruned ID, an ID of another owner, or a key that is both
    /// put and removed rejects the whole batch. Removing an unknown, already
    /// deleted or other owner's entry changes nothing. Returns the put IDs.
    @discardableResult
    public func batch(puts: [LawPersonalChange], removes: [LawPersonalRef] = [], owner: String?) throws -> [String] {
        var s = try load()
        let forgotten = Set(s.forgotten ?? []), index = s.index()
        var putKeys = Set<String>()
        for change in puts {
            let key = LawPersonalRef(kind: change.kind, id: change.id).key
            guard LawPersonalState.kinds.contains(change.kind), UUID(uuidString: change.id) != nil, putKeys.insert(key).inserted else { throw LawError.invalid("Ungültige Markierung.") }
            if forgotten.contains(key) { throw LawError.invalid("Eine gelöschte Markierung kann nicht wiederbelebt werden.") }
            if let i = index[key] {
                if s.items[i].owner != owner { throw LawError.invalid("Diese Markierung gehört zu einem anderen Konto.") }
                if s.items[i].deleted { throw LawError.invalid("Eine gelöschte Markierung kann nicht wiederbelebt werden.") }
            }
        }
        guard putKeys.isDisjoint(with: removes.map(\.key)) else { throw LawError.invalid("Eine Markierung kann nicht zugleich angelegt und entfernt werden.") }
        for change in puts {
            let key = LawPersonalRef(kind: change.kind, id: change.id).key
            let prior = index[key]
            let item = LawPersonalItem(id: change.id, owner: owner, kind: change.kind, payload: change.payload.merging(["id": .string(change.id)]) { _, new in new },
                                       deleted: false, dirty: true, revision: try nextRevision(prior.map { s.items[$0].revision } ?? 0))
            if let prior { s.items[prior] = item } else { s.items.append(item) }
        }
        let at = timestamp
        for ref in removes {
            guard let i = index[ref.key], s.items[i].owner == owner, !s.items[i].deleted else { continue }
            s.items[i].deleted = true; s.items[i].dirty = true; s.items[i].deletedAt = at; s.items[i].rejection = nil
            s.items[i].revision = try nextRevision(s.items[i].revision)
        }
        try commit(s)
        return puts.map(\.id)
    }
    @discardableResult
    public func put(kind: String, payload: [String: LawJSON], owner: String?, id: String = UUID().uuidString.lowercased()) throws -> String {
        try batch(puts: [LawPersonalChange(kind: kind, payload: payload, id: id)], owner: owner)[0]
    }
    public func remove(id: String, owner: String?) throws {
        let refs = try load().items.filter { $0.id == id && $0.owner == owner }.map(\.ref)
        try batch(puts: [], removes: refs, owner: owner)
    }
    /// What to send for `owner`, new entries before deletions: replacing a
    /// marking (delete + create) never leaves the website without it meanwhile.
    public func pending(owner: String) throws -> [LawPersonalItem] {
        let mine = try load().items.filter { $0.owner == owner && $0.awaitsUpload }
        return mine.filter { !$0.deleted } + mine.filter(\.deleted)
    }
    public func cursor(owner: String) throws -> Int { try load().cursors[owner] ?? 0 }
    public func acknowledge(_ sent: LawPersonalItem, payload: [String: LawJSON]? = nil) throws {
        try record([LawPushReceipt(sent: sent, outcome: .accepted(payload))])
    }
    /// All answers of one push as one write. An answer for an entry changed
    /// locally since it was sent (other revision) is dropped, except a
    /// server deletion, which always wins.
    public func record(_ receipts: [LawPushReceipt]) throws {
        guard !receipts.isEmpty else { return }
        var s = try load()
        var index = s.index()
        let at = timestamp
        for receipt in receipts {
            let sent = receipt.sent
            guard let i = index[sent.key], s.items[i].owner == sent.owner else { continue }
            switch receipt.outcome {
            case .deletedOnServer:
                s.items[i].deleted = true; s.items[i].dirty = false; s.items[i].rejection = nil
                s.items[i].deletedAt = at
            case .rejected(let status, let message):
                guard s.items[i].revision == sent.revision, !s.items[i].deleted else { continue }
                s.items[i].rejection = LawPersonalRejection(status: status, message: String(message.prefix(500)), at: at)
            case .accepted(let payload):
                guard s.items[i].revision == sent.revision else { continue }
                s.items[i].dirty = false; s.items[i].rejection = nil
                if s.items[i].deleted { s.items[i].deletedAt = at }
                guard let payload, let remoteID = payload["id"]?.string, UUID(uuidString: remoteID) != nil else { continue }
                let remoteKey = LawPersonalRef(kind: sent.kind, id: remoteID).key
                if remoteKey != sent.key, let other = index[remoteKey] {
                    // The server may deduplicate a bookmark by target and choose
                    // its existing ID; another account's entry is never dropped.
                    guard s.items[other].owner == sent.owner else { s.items[i].payload = Self.keepingLocal(payload.merging(["id": .string(sent.id)]) { _, n in n }, from: s.items[i].payload); continue }
                    s.items.remove(at: other)
                    index = s.index()
                }
                guard let j = index[sent.key] else { continue }
                s.items[j].id = remoteID; s.items[j].payload = Self.keepingLocal(payload, from: s.items[j].payload)
                index = s.index()
            }
        }
        try commit(s)
    }
    public func apply(_ page: LawSyncPage, owner: String) throws {
        var s = try load()
        let cursor = s.cursors[owner] ?? 0
        guard page.cursor >= cursor, page.changes.count <= 500,
              page.changes.allSatisfy({ $0.seq > cursor && $0.seq <= page.cursor && UUID(uuidString: $0.id) != nil && LawPersonalState.kinds.contains($0.kind) && ($0.deleted || $0.payload != nil) }),
              zip(page.changes, page.changes.dropFirst()).allSatisfy({ $0.seq < $1.seq }) else { throw LawError.invalid("Ungültige Synchronisierungsantwort.") }
        let forgotten = Set(s.forgotten ?? []), at = timestamp
        var index = s.index()
        for change in page.changes {
            let key = LawPersonalRef(kind: change.kind, id: change.id).key
            if forgotten.contains(key) { continue }
            if let i = index[key] {
                if s.items[i].owner == owner {
                    // A deletion is authoritative. An old fetched creation must not
                    // undo an offline deletion or overwrite an unacknowledged edit.
                    if change.deleted {
                        if !s.items[i].deleted || s.items[i].dirty { s.items[i].deletedAt = at }
                        s.items[i].deleted = true; s.items[i].dirty = false; s.items[i].rejection = nil
                    } else if !s.items[i].dirty && !s.items[i].deleted {
                        s.items[i].payload = Self.keepingLocal(change.payload ?? [:], from: s.items[i].payload)
                    }
                } else if s.items[i].owner == nil, change.deleted, !s.items[i].deleted {
                    // A guest copy (e.g. restored) of this account's entry: the ID is dead.
                    s.items[i].deleted = true; s.items[i].deletedAt = at; s.items[i].revision = try nextRevision(s.items[i].revision)
                }
                // Another account's entry with this ID is neither duplicated nor touched.
            } else {
                s.items.append(LawPersonalItem(id: change.id, owner: owner, kind: change.kind, payload: change.payload ?? [:], deleted: change.deleted, dirty: false, revision: 0,
                                               deletedAt: change.deleted ? at : nil))
                index[key] = s.items.count - 1
            }
        }
        if page.cursor != cursor { s.cursors[owner] = page.cursor }
        try commit(s)
    }
    /// „Erneut versuchen“: sends the owner's refused (or kept local) entries
    /// again; `nil` = all of them.
    public func retry(_ refs: [LawPersonalRef]? = nil, owner: String?) throws {
        var s = try load()
        let keys = refs.map { Set($0.map(\.key)) }
        for i in s.items.indices where s.items[i].owner == owner && (s.items[i].rejection != nil || s.items[i].isKeptLocal) && (keys?.contains(s.items[i].key) ?? true) {
            s.items[i].rejection = nil; s.items[i].localOnly = nil
        }
        try commit(s)
    }
    /// „Nur lokal behalten“: never sent again; stays visible on this iPad.
    public func keepLocal(_ refs: [LawPersonalRef], owner: String?) throws {
        var s = try load()
        let keys = Set(refs.map(\.key))
        for i in s.items.indices where s.items[i].owner == owner && keys.contains(s.items[i].key) { s.items[i].localOnly = true }
        try commit(s)
    }
    /// Drops the payload of deletions that are settled (confirmed by the
    /// server, or a guest's, which is never sent) for at least `age`; their
    /// keys stay in `forgotten`, so the ID can never be created, restored or
    /// pulled again. Older deletions without a time start the clock now.
    @discardableResult
    public func pruneTombstones(age: TimeInterval = LawPersonalStore.tombstoneAge) throws -> Int {
        var s = try load()
        let at = timestamp
        var forgotten = Set(s.forgotten ?? []), pruned = 0
        s.items = s.items.compactMap { item in
            guard item.deleted else { return item }
            guard let since = item.deletedAt else { var dated = item; dated.deletedAt = at; return dated }
            guard item.owner == nil || !item.dirty, at - since >= age else { return item }
            forgotten.insert(item.key); pruned += 1
            return nil
        }
        s.forgotten = forgotten.isEmpty ? nil : forgotten.sorted()
        try commit(s)
        return pruned
    }
    public func exportData() throws -> Data { try JSONEncoder().encode(load()) }
    /// Merge an independently validated personal archive; never overwrite later
    /// local data, and never automatically send a restored other-account record.
    /// An entry whose kind and ID exist here already, under any owner, or were
    /// pruned as deleted, is skipped (B1).
    public func importData(_ data: Data) throws {
        guard data.count <= 128_000_000 else { throw LawError.invalid("Sicherungsdatei zu groß.") }
        let decoded = try JSONDecoder().decode(LawPersonalState.self, from: data)
        guard decoded.isWellFormed else { throw LawError.invalid("Ungültige Gesetzessicherung.") }
        let incoming = decoded.mergingDuplicates().state
        var s = try load()
        let index = s.index()
        var forgotten = Set(s.forgotten ?? []).union(incoming.forgotten ?? [])
        for var item in incoming.items where index[item.key] == nil && !forgotten.contains(item.key) {
            item.dirty = true; item.rejection = nil; item.revision = try nextRevision(item.revision); s.items.append(item)
        }
        // An archive never deletes here: a key still live locally stays live.
        forgotten.subtract(s.items.map(\.key))
        s.forgotten = forgotten.isEmpty ? nil : forgotten.sorted()
        try commit(s)
    }
}

public struct LawVersionMarkCount: Equatable, Sendable {
    public var versionId: String
    public var count: Int
    public init(versionId: String, count: Int) { self.versionId = versionId; self.count = count }
}
public extension Sequence where Element == LawPersonalItem {
    /// Entries of `owner` only (B12): signed in the account, signed out the guest (`nil`).
    func visible(to owner: String?) -> [LawPersonalItem] { filter { $0.owner == owner && !$0.deleted } }
    /// Markings of `law` per version, in `versionOrder` (e.g. the catalogue's
    /// versions), unknown versions after it by ID. Counts what is passed in:
    /// give it `visible(to:)` entries.
    func markCounts(law: String, versionOrder: [String] = []) -> [LawVersionMarkCount] {
        var counts: [String: Int] = [:]
        for item in self where item.kind == "annotation" && !item.deleted && item.payload["lawId"]?.string == law {
            guard let version = item.payload["versionId"]?.string else { continue }
            counts[version, default: 0] += 1
        }
        let known = versionOrder.filter { counts[$0] != nil }
        let rest = counts.keys.filter { !versionOrder.contains($0) }.sorted()
        return (known + rest).map { LawVersionMarkCount(versionId: $0, count: counts[$0]!) }
    }
}
