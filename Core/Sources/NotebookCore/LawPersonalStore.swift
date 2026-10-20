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
public struct LawPersonalItem: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var owner: String?
    public var kind: String
    public var payload: [String: LawJSON]
    public var deleted: Bool
    public var dirty: Bool
    public var revision: Int
}
public struct LawSyncChange: Codable, Sendable {
    public var seq: Int
    public var kind: String
    public var id: String
    public var payload: [String: LawJSON]?
    public var deleted: Bool
}
public struct LawSyncPage: Codable, Sendable {
    public var changes: [LawSyncChange]
    public var cursor: Int
    public var hasMore: Bool
}
private struct LawPersonalState: Codable {
    var schemaVersion = 1
    var items: [LawPersonalItem] = []
    var cursors: [String: Int] = [:]
    var lastOwner: String?
}

/// Durable outbox and deletion state. A write failure leaves the prior state
/// intact in memory and on disk. Future/corrupt formats block writes, not reset.
public actor LawPersonalStore {
    /// Presentation keys only this app writes (the server echoes payloads
    /// without them): kept locally when an acknowledgement or a pulled
    /// change replaces the payload, so a highlighter colour survives syncing.
    public static let localOnlyKeys = ["color"]
    private static func keepingLocal(_ server: [String: LawJSON], from local: [String: LawJSON]) -> [String: LawJSON] {
        var merged = server
        for key in localOnlyKeys where merged[key] == nil { merged[key] = local[key] }
        return merged
    }
    private let url: URL
    private var state: LawPersonalState?
    public init(root: URL) { url = root.appendingPathComponent("personal.json") }
    private func load() throws -> LawPersonalState {
        if let state { return state }
        guard FileManager.default.fileExists(atPath: url.path) else { return LawPersonalState() }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 128_000_000 else { throw LawError.invalid("Markierungsbestand zu groß.") }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= 128_000_000 else { throw LawError.invalid("Markierungsbestand zu groß.") }
        let s = try JSONDecoder().decode(LawPersonalState.self, from: bytes)
        guard s.schemaVersion == 1, Set(s.items.map { "\($0.owner ?? "guest"):\($0.kind):\($0.id)" }).count == s.items.count,
              s.items.allSatisfy({ UUID(uuidString: $0.id) != nil && ["annotation", "bookmark"].contains($0.kind) && (0...1_000_000_000).contains($0.revision) }),
              s.cursors.values.allSatisfy({ $0 >= 0 }) else { throw LawError.invalid("Unbekannter oder beschädigter Markierungsbestand. Dateien bleiben erhalten.") }
        state = s
        return s
    }
    private func nextRevision(_ value: Int) throws -> Int {
        guard value >= 0, value < 1_000_000_000 else { throw LawError.invalid("Ungültige Markierungsrevision. Bestand bleibt erhalten.") }
        return value + 1
    }
    private func commit(_ next: LawPersonalState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = try JSONEncoder().encode(next)
        guard bytes.count <= 128_000_000 else { throw LawError.invalid("Markierungsspeicher voll.") }
        try bytes.write(to: url, options: .atomic)
        state = next
    }
    public func items() throws -> [LawPersonalItem] { try load().items }
    public func lastOwner() throws -> String? { try load().lastOwner }
    public func adoptGuests(owner: String) throws {
        var s = try load()
        for i in s.items.indices where s.items[i].owner == nil {
            s.items[i].owner = owner; s.items[i].dirty = true; s.items[i].revision = try nextRevision(s.items[i].revision)
        }
        s.lastOwner = owner
        try commit(s)
    }
    @discardableResult
    public func put(kind: String, payload: [String: LawJSON], owner: String?, id: String = UUID().uuidString.lowercased()) throws -> String {
        guard ["bookmark", "annotation"].contains(kind), UUID(uuidString: id) != nil else { throw LawError.invalid("Ungültige Markierung.") }
        var s = try load()
        let prior = s.items.firstIndex { $0.id == id && $0.kind == kind && $0.owner == owner }
        if let prior, s.items[prior].deleted { throw LawError.invalid("Eine gelöschte Markierung kann nicht wiederbelebt werden.") }
        let item = LawPersonalItem(id: id, owner: owner, kind: kind, payload: payload.merging(["id": .string(id)]) { _, new in new }, deleted: false, dirty: true, revision: try nextRevision(prior.map { s.items[$0].revision } ?? 0))
        if let prior { s.items[prior] = item } else { s.items.append(item) }
        try commit(s)
        return id
    }
    public func remove(id: String, owner: String?) throws {
        var s = try load()
        for i in s.items.indices where s.items[i].id == id && s.items[i].owner == owner {
            s.items[i].deleted = true; s.items[i].dirty = true; s.items[i].revision = try nextRevision(s.items[i].revision)
        }
        try commit(s)
    }
    public func pending(owner: String) throws -> [LawPersonalItem] { try load().items.filter { $0.owner == owner && $0.dirty } }
    public func cursor(owner: String) throws -> Int { try load().cursors[owner] ?? 0 }
    public func acknowledge(_ sent: LawPersonalItem, payload: [String: LawJSON]? = nil) throws {
        var s = try load()
        guard let i = s.items.firstIndex(where: { $0.id == sent.id && $0.owner == sent.owner && $0.kind == sent.kind }), s.items[i].revision == sent.revision else { return }
        s.items[i].dirty = false
        if let payload, let remoteID = payload["id"]?.string {
            // The server may deduplicate a bookmark by target and choose its existing ID.
            s.items[i].id = remoteID; s.items[i].payload = Self.keepingLocal(payload, from: s.items[i].payload)
            s.items = s.items.enumerated().filter { $0.offset == i || !($0.element.id == remoteID && $0.element.owner == sent.owner && $0.element.kind == sent.kind) }.map(\.element)
        }
        try commit(s)
    }
    public func apply(_ page: LawSyncPage, owner: String) throws {
        var s = try load()
        let cursor = s.cursors[owner] ?? 0
        guard page.cursor >= cursor, page.changes.count <= 500,
              page.changes.allSatisfy({ $0.seq > cursor && $0.seq <= page.cursor && UUID(uuidString: $0.id) != nil && ["annotation", "bookmark"].contains($0.kind) && ($0.deleted || $0.payload != nil) }),
              zip(page.changes, page.changes.dropFirst()).allSatisfy({ $0.seq < $1.seq }) else { throw LawError.invalid("Ungültige Synchronisierungsantwort.") }
        for change in page.changes {
            if let i = s.items.firstIndex(where: { $0.owner == owner && $0.id == change.id && $0.kind == change.kind }) {
                // A deletion is authoritative. An old fetched creation must not
                // undo an offline deletion or overwrite an unacknowledged edit.
                if change.deleted {
                    s.items[i].deleted = true; s.items[i].dirty = false
                } else if !s.items[i].dirty && !s.items[i].deleted {
                    s.items[i].payload = Self.keepingLocal(change.payload ?? [:], from: s.items[i].payload)
                }
            } else {
                s.items.append(LawPersonalItem(id: change.id, owner: owner, kind: change.kind, payload: change.payload ?? [:], deleted: change.deleted, dirty: false, revision: 0))
            }
        }
        s.cursors[owner] = page.cursor
        try commit(s)
    }
    public func exportData() throws -> Data { try JSONEncoder().encode(load()) }
    /// Merge an independently validated personal archive; never overwrite later
    /// local data, and never automatically send a restored other-account record.
    public func importData(_ data: Data) throws {
        guard data.count <= 128_000_000 else { throw LawError.invalid("Sicherungsdatei zu groß.") }
        let incoming = try JSONDecoder().decode(LawPersonalState.self, from: data)
        guard incoming.schemaVersion == 1, incoming.items.allSatisfy({ UUID(uuidString: $0.id) != nil && ["annotation", "bookmark"].contains($0.kind) && (0...1_000_000_000).contains($0.revision) }) else { throw LawError.invalid("Ungültige Gesetzessicherung.") }
        var s = try load()
        for var item in incoming.items where !s.items.contains(where: { $0.id == item.id && $0.owner == item.owner && $0.kind == item.kind }) {
            item.dirty = true; item.revision = try nextRevision(item.revision); s.items.append(item)
        }
        try commit(s)
    }
}
