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
        guard schemaVersion == nil || (1...2).contains(schemaVersion ?? 0) else { throw LawError.invalid("Dieses Gesetzesformat ist neuer als die App.") }
        guard id == entry.id, version == target.id, sections.count == target.sectionCount,
              !sections.isEmpty, Set(sections.map(\.id)).count == sections.count,
              sections.allSatisfy({ !$0.id.isEmpty && $0.text.utf8.count < 8_000_000 }) else { throw LawError.invalid("Gesetzesdatei passt nicht zum Katalog.") }
        return self
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
    public static func parse(_ input: String) -> Self? {
        let pattern = "^(?:§\\s*|Abschnitt\\s*|R\\s*|Zu\\s*§\\s*)?(\\d+[a-z]*(?:\\.\\d+[a-z]*)*)\\.?(?:\\s*(?:Abs(?:atz)?\\.?|\\()\\s*(\\d+[a-z]*)\\)?)?$"
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = re.firstMatch(in: input.trimmingCharacters(in: .whitespacesAndNewlines), range: NSRange(input.trimmingCharacters(in: .whitespacesAndNewlines).startIndex..., in: input.trimmingCharacters(in: .whitespacesAndNewlines))) else { return nil }
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines) as NSString
        return Self(key: value.substring(with: m.range(at: 1)).lowercased(), paragraph: m.range(at: 2).location == NSNotFound ? nil : value.substring(with: m.range(at: 2)).lowercased())
    }
}
public struct LawQuickTarget: Equatable, Sendable {
    public var lawID: String
    public var reference: LawReference
    public static func parse(_ input: String, entries: [LawEntry]) -> Self? {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
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
            guard try Data(contentsOf: url) == data else { throw LawError.invalid("Eine unveränderliche Gesetzesfassung wurde verändert.") }
        } else { try data.write(to: url, options: .atomic) }
    }
    public func publish(_ catalog: LawCatalog) throws {
        if FileManager.default.fileExists(atPath: catalogURL.path) { _ = try self.catalog() }
        _ = try catalog.validated()
        for entry in catalog.entries {
            guard let v = entry.versions.first(where: { $0.id == entry.currentVersion }) else { throw LawError.invalid("Fassung fehlt.") }
            _ = try document(entry, version: v)
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
    public func putPDF(_ data: Data, id: String, version: String) throws -> URL {
        guard data.count <= 150_000_000, data.starts(with: Data("%PDF-".utf8)) else { throw LawError.invalid("Ungültige PDF-Datei.") }
        let url = try pdfURL(id, version: version)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
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
public enum LawTextAnchor {
    public static func canonical(_ text: String) -> String {
        let normalized = text.precomposedStringWithCompatibilityMapping.lowercased()
        return String(String.UnicodeScalarView(normalized.unicodeScalars.filter {
            switch $0.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber, .letterNumber, .otherNumber: true
            default: false
            }
        }))
    }
    public static func originalRange(text: String, anchor: LawAnchor) -> NSRange? {
        originalRanges(text: text, anchors: [anchor]).first ?? nil
    }
    public static func originalRanges(text: String, anchors: [LawAnchor]) -> [NSRange?] {
        var mapped = "", starts: [Int] = [], ends: [Int] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .byComposedCharacterSequences) { substring, range, _, _ in
            guard let substring else { return }
            let value = canonical(substring), original = NSRange(range, in: text)
            mapped += value
            for _ in value.utf16 { starts.append(original.location); ends.append(original.location + original.length) }
        }
        guard mapped == canonical(text) else { return anchors.map { _ in nil } }
        return anchors.map { anchor in
            guard anchor.start >= 0, anchor.end > anchor.start, anchor.end <= starts.count,
                  (mapped as NSString).substring(with: NSRange(location: anchor.start, length: anchor.end - anchor.start)) == anchor.quote else { return nil }
            return NSRange(location: starts[anchor.start], length: ends[anchor.end - 1] - starts[anchor.start])
        }
    }
    public static func anchor(text: String, range: NSRange, sectionID: String) -> LawAnchor? {
        let original = text as NSString
        guard range.location != NSNotFound, range.location >= 0, range.length > 0, range.location <= original.length, range.length <= original.length - range.location else { return nil }
        let start = (canonical(original.substring(to: range.location)) as NSString).length
        let quote = canonical(original.substring(with: range))
        let length = (quote as NSString).length, full = canonical(text) as NSString
        guard !quote.isEmpty, length <= 12000, start + length <= full.length,
              full.substring(with: NSRange(location: start, length: length)) == quote else { return nil }
        return LawAnchor(sectionId: sectionID, start: start, end: start + (quote as NSString).length, quote: quote)
    }
}
public struct LawAnchor: Codable, Sendable, Hashable {
    public var sectionId: String
    public var start: Int
    public var end: Int
    public var quote: String
    public init(sectionId: String, start: Int, end: Int, quote: String) { self.sectionId = sectionId; self.start = start; self.end = end; self.quote = quote }
}
