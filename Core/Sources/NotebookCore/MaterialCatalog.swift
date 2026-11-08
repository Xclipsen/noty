import Foundation

/// A learning-material package (`.notymaterial`, docs/LERNFELDER.md): the
/// scripts of a learning platform as local PDFs plus a catalogue of fields
/// (Lernfelder), chapters, video lessons, topic units, page headings and
/// cited norms. Imported, never edited: it is source data like a law PDF,
/// not user content. Nothing in it is required to read a notebook; links in
/// the calendar keep a text snapshot (`CalendarMaterialRef.label`).
public struct MaterialCatalog: Codable, Equatable, Sendable {
    public static let currentFormat = 1
    public static let maximumFields = 40
    public static let maximumChapters = 400
    public static let maximumLessons = 5_000
    public static let maximumPages = 20_000

    public var format: Int
    /// Stable package identity, e.g. `steuer-azubis`: `[a-z0-9-]{1,64}`.
    public var id: String
    public var title: String
    /// Template of a video lesson link with `{id}`, e.g.
    /// `https://app.steuer-azubis.de/#/lektion/{id}`; https only.
    public var lessonURL: String?
    /// Template of a field page link with `{id}` (the platform's course id).
    public var fieldURL: String?
    /// ISO date of the capture, shown only.
    public var created: String?
    public var fields: [MaterialField]

    public init(format: Int = MaterialCatalog.currentFormat, id: String, title: String, lessonURL: String? = nil,
                fieldURL: String? = nil, created: String? = nil, fields: [MaterialField]) {
        self.format = format; self.id = id; self.title = title; self.lessonURL = lessonURL; self.fieldURL = fieldURL
        self.created = created; self.fields = fields
    }

    public func field(_ number: Int) -> MaterialField? { fields.first { $0.number == number } }

    public func chapter(_ key: String) -> (field: MaterialField, chapter: MaterialChapter)? {
        for field in fields { if let chapter = field.chapters.first(where: { $0.key == key }) { return (field, chapter) } }
        return nil
    }

    public func lesson(_ id: String) -> (field: MaterialField, chapter: MaterialChapter, lesson: MaterialLesson)? {
        let id = id.lowercased()
        for field in fields { for chapter in field.chapters {
            if let lesson = chapter.lessons.first(where: { $0.id == id }) { return (field, chapter, lesson) }
        } }
        return nil
    }

    /// The platform link of a video lesson, nil without a template.
    public func lessonLink(_ id: String) -> URL? { Self.link(lessonURL, id: id) }
    public func fieldLink(_ field: MaterialField) -> URL? { field.courseID.flatMap { Self.link(fieldURL, id: $0) } }

    static func link(_ template: String?, id: String) -> URL? {
        guard let template, MaterialCatalog.isIdentifier(id) else { return nil }
        return URL(string: template.replacingOccurrences(of: "{id}", with: id))
    }

    static func isIdentifier(_ text: String) -> Bool {
        (1...64).contains(text.count) && text.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-").contains($0)
        }
    }

    static func validTemplate(_ template: String?) -> Bool {
        guard let template else { return true }
        guard template.count <= 300, template.hasPrefix("https://"), template.contains("{id}"),
              let url = URL(string: template.replacingOccurrences(of: "{id}", with: "x")), url.host != nil else { return false }
        return true
    }

    /// A safe relative path below the package's `pdf/` folder: segments of
    /// `[A-Za-z0-9._-]`, no `.`/`..`, ending in `.pdf`.
    public static func isSafeFile(_ path: String) -> Bool {
        guard (5...300).contains(path.count), path.hasSuffix(".pdf"), !path.hasPrefix("/") else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...4).contains(segments.count) else { return false }
        return segments.allSatisfy { segment in
            !segment.isEmpty && segment != "." && segment != ".." && !segment.hasPrefix(".")
                && segment.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }

    public func validate() throws {
        guard format == Self.currentFormat else { throw MaterialError.unsupportedFormat(format) }
        guard Self.isIdentifier(id), (1...200).contains(title.count), Self.validTemplate(lessonURL), Self.validTemplate(fieldURL),
              (created?.count ?? 0) <= 40, (1...Self.maximumFields).contains(fields.count),
              Set(fields.map(\.number)).count == fields.count else { throw MaterialError.invalid("Katalog") }
        var chapters = 0, lessons = 0, pages = 0
        var chapterKeys = Set<String>(), lessonIDs = Set<String>(), files = Set<String>()
        for field in fields {
            guard (1...99).contains(field.number), (1...300).contains(field.title.count),
                  field.courseID.map(Self.isIdentifier) ?? true else { throw MaterialError.invalid("Lernfeld \(field.number)") }
            for chapter in field.chapters {
                chapters += 1
                try chapter.validate()
                guard chapterKeys.insert(chapter.key).inserted else { throw MaterialError.invalid("Kapitel \(chapter.key) doppelt") }
                if let script = chapter.script {
                    guard files.insert(script.file).inserted else { throw MaterialError.invalid("Skript \(script.file) doppelt") }
                    pages += script.pageCount
                }
                for lesson in chapter.lessons {
                    lessons += 1
                    guard lessonIDs.insert(lesson.id).inserted else { throw MaterialError.invalid("Lektion doppelt") }
                }
            }
        }
        guard chapters <= Self.maximumChapters, lessons <= Self.maximumLessons, pages <= Self.maximumPages else {
            throw MaterialError.invalid("zu groß")
        }
    }

    /// All script files in catalogue order.
    public var scripts: [MaterialScript] { fields.flatMap { $0.chapters.compactMap(\.script) } }
}

public struct MaterialField: Codable, Equatable, Sendable, Identifiable {
    public var id: Int { number }
    public var number: Int
    public var title: String
    /// The platform's identity of the field (link template `fieldURL`).
    public var courseID: String?
    public var chapters: [MaterialChapter]
    public init(number: Int, title: String, courseID: String? = nil, chapters: [MaterialChapter]) {
        self.number = number; self.title = title; self.courseID = courseID; self.chapters = chapters
    }
    /// „LF 3“
    public var shortName: String { "LF \(number)" }
}

public struct MaterialChapter: Codable, Equatable, Sendable, Identifiable {
    public var id: String { key }
    /// Stable within the package, e.g. `LF03-04` (field + position).
    public var key: String
    /// Position on the field page (0 = first), unique within the field.
    public var index: Int
    /// The platform's chapter number (0 = foreword); parts may restart it.
    public var number: Int
    public var part: Int?
    public var title: String
    public var preface: Bool
    public var script: MaterialScript?
    public var lessons: [MaterialLesson]
    /// Topic units of the script: page runs with the same running head.
    public var units: [MaterialUnit]
    /// Per script page: running head, first heading, cited norms.
    public var pages: [MaterialPage]

    public init(key: String, index: Int, number: Int, part: Int? = nil, title: String, preface: Bool = false,
                script: MaterialScript? = nil, lessons: [MaterialLesson] = [], units: [MaterialUnit] = [], pages: [MaterialPage] = []) {
        self.key = key; self.index = index; self.number = number; self.part = part; self.title = title; self.preface = preface
        self.script = script; self.lessons = lessons; self.units = units; self.pages = pages
    }

    /// „Kapitel 4“, „Vorwort“, „Teil 2 · Kapitel 3“.
    public var label: String {
        if preface { return "Vorwort" }
        return (part.map { "Teil \($0) · " } ?? "") + "Kapitel \(number)"
    }

    func validate() throws {
        let pageCount = script?.pageCount ?? 0
        func inPages(_ range: [Int]) -> Bool {
            range.count == 2 && range[0] >= 1 && range[0] <= range[1] && range[1] <= pageCount
        }
        guard (1...40).contains(key.count), key.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" }),
              (0...999).contains(index), (0...999).contains(number), (part ?? 1) >= 1, (part ?? 1) <= 99,
              (1...300).contains(title.count), lessons.count <= 500, units.count <= 2_000, pages.count <= 2_000,
              script.map({ (try? $0.validate()) != nil }) ?? true else { throw MaterialError.invalid("Kapitel \(key)") }
        for lesson in lessons {
            guard MaterialLesson.isLessonID(lesson.id), (1...300).contains(lesson.title.count), (lesson.seconds ?? 0) >= 0,
                  (lesson.seconds ?? 0) <= 86_400, lesson.pages.map(inPages) ?? true else { throw MaterialError.invalid("Lektion in \(key)") }
        }
        for unit in units {
            guard (1...300).contains(unit.title.count), inPages(unit.pages), unit.headings.count <= 200,
                  unit.headings.allSatisfy({ (1...300).contains($0.count) }), unit.norms.count <= 500,
                  unit.norms.allSatisfy({ (1...120).contains($0.count) }) else { throw MaterialError.invalid("Einheit in \(key)") }
        }
        for page in pages {
            guard (1...max(pageCount, 1)).contains(page.page), pageCount > 0, (page.head?.count ?? 0) <= 300,
                  (page.heading?.count ?? 0) <= 300, page.norms.count <= 200,
                  page.norms.allSatisfy({ (1...120).contains($0.count) }) else { throw MaterialError.invalid("Seite in \(key)") }
        }
    }
}

public struct MaterialScript: Codable, Equatable, Sendable {
    /// Relative path below the package's `pdf/` folder.
    public var file: String
    public var pageCount: Int
    public var byteCount: Int
    /// Lower-case hex SHA-256 of the PDF.
    public var sha256: String
    public init(file: String, pageCount: Int, byteCount: Int, sha256: String) {
        self.file = file; self.pageCount = pageCount; self.byteCount = byteCount; self.sha256 = sha256
    }
    func validate() throws {
        guard MaterialCatalog.isSafeFile(file), (1...5_000).contains(pageCount), (1...200_000_000).contains(byteCount),
              sha256.count == 64, sha256.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }) else {
            throw MaterialError.invalid("Skript \(file)")
        }
    }
}

public struct MaterialLesson: Codable, Equatable, Sendable, Identifiable {
    /// The platform's lesson identity (lower-case UUID).
    public var id: String
    public var title: String
    public var seconds: Int?
    public var order: Int
    /// First and last script page of the lesson, if known.
    public var pages: [Int]?
    public init(id: String, title: String, seconds: Int? = nil, order: Int, pages: [Int]? = nil) {
        self.id = id.lowercased(); self.title = title; self.seconds = seconds; self.order = order; self.pages = pages
    }
    static func isLessonID(_ text: String) -> Bool { text == text.lowercased() && UUID(uuidString: text) != nil }

    /// „10:14“
    public var duration: String? {
        guard let seconds else { return nil }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

public struct MaterialUnit: Codable, Equatable, Sendable {
    public var title: String
    /// First and last page.
    public var pages: [Int]
    public var headings: [String]
    public var norms: [String]
    public init(title: String, pages: [Int], headings: [String] = [], norms: [String] = []) {
        self.title = title; self.pages = pages; self.headings = headings; self.norms = norms
    }
}

public struct MaterialPage: Codable, Equatable, Sendable {
    public var page: Int
    public var head: String?
    public var heading: String?
    public var norms: [String]
    public init(page: Int, head: String? = nil, heading: String? = nil, norms: [String] = []) {
        self.page = page; self.head = head; self.heading = heading; self.norms = norms
    }
}

/// Optional page texts of all scripts (`text.json`): file → one string per
/// page. Only used for search; derived from the PDFs.
public struct MaterialTexts: Codable, Equatable, Sendable {
    public var format: Int
    public var pages: [String: [String]]
    public init(format: Int = 1, pages: [String: [String]]) { self.format = format; self.pages = pages }

    public func validate(against catalog: MaterialCatalog) throws {
        guard format == 1 else { throw MaterialError.unsupportedFormat(format) }
        let scripts = Dictionary(catalog.scripts.map { ($0.file, $0.pageCount) }, uniquingKeysWith: { a, _ in a })
        for (file, texts) in pages {
            guard let count = scripts[file], texts.count == count, texts.allSatisfy({ $0.utf8.count <= 200_000 }) else {
                throw MaterialError.invalid("Text \(file)")
            }
        }
    }
}

public enum MaterialError: Error, LocalizedError, Equatable {
    case unsupportedFormat(Int)
    case invalid(String)
    case missingFile(String)
    case checksumMismatch(String)
    case notAPackage

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let format): "Das Materialpaket hat ein neueres Format (\(format)). Bitte noty aktualisieren."
        case .invalid(let what): "Das Materialpaket ist ungültig (\(what)). Es wurde nichts übernommen."
        case .missingFile(let file): "Im Materialpaket fehlt „\(file)“. Es wurde nichts übernommen."
        case .checksumMismatch(let file): "„\(file)“ im Materialpaket ist beschädigt. Es wurde nichts übernommen."
        case .notAPackage: "Die Datei ist kein noty-Materialpaket."
        }
    }
}
