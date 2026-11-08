import Foundation

/// One search result in a material package: a video lesson (with its script
/// pages), a topic unit of a script, or single script pages found by text.
public struct MaterialHit: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case lesson, unit, page }
    /// Stable key, also stored by „Festhalten“ (`CalendarMaterialRef.key`):
    /// `lesson:<id>`, `unit:<chapter>:<first page>`, `page:<chapter>:<page>`.
    public var id: String
    public var kind: Kind
    public var field: Int
    public var chapterKey: String
    public var chapterTitle: String
    public var title: String
    /// First and last script page.
    public var pages: ClosedRange<Int>?
    public var lessonID: String?
    public var seconds: Int?
    public var norms: [String]
    /// Heading or text around the match, shown below the title.
    public var detail: String?
    public var score: Int

    /// „LF 3 · Kapitel 4 Die Lieferung“
    public func location(in catalog: MaterialCatalog) -> String {
        guard let (_, chapter) = catalog.chapter(chapterKey) else { return "LF \(field)" }
        return "LF \(field) · \(chapter.label) \(chapter.title)"
    }
}

/// Page texts reduced once to search form (`MaterialSearch.normalize`).
public struct MaterialTextIndex: Sendable {
    public let pages: [String: [String]]
    public init(_ texts: MaterialTexts) {
        pages = texts.pages.mapValues { $0.map(MaterialSearch.normalize) }
    }
}

public enum MaterialSearch {
    /// Lower case, umlauts and ß folded, everything but letters and digits a space.
    public static func normalize(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for character in text.lowercased() {
            switch character {
            case "ä": out += "a"
            case "ö": out += "o"
            case "ü": out += "u"
            case "ß": out += "ss"
            case "é", "è", "ê": out += "e"
            default:
                if character.isLetter || character.isNumber { out.append(character) } else { out += " " }
            }
        }
        return out.split(separator: " ").joined(separator: " ")
    }

    static func tokens(_ text: String) -> [String] {
        normalize(text).split(separator: " ").map(String.init).filter { $0.count >= 2 || $0.first?.isNumber == true }
    }

    /// Every token occurs as the start of a word (or inside a long compound
    /// word for tokens of 4+ letters: „lieferung“ in „werklieferung“).
    static func matches(_ tokens: [String], in normalized: String) -> Bool {
        guard !tokens.isEmpty else { return false }
        let words = normalized.split(separator: " ")
        return tokens.allSatisfy { token in
            words.contains { $0.hasPrefix(token) || (token.count >= 4 && $0.contains(token)) }
        }
    }

    // MARK: Norms

    /// A cited norm reduced to what identifies it: number („24a“, „3.10“)
    /// and law („estg“, „sgb v“, „ustae“). Paragraph details (Abs., Nr.) are
    /// kept apart, so „§ 3 UStG“ finds „§ 3 Abs. 1 UStG“.
    public struct Norm: Hashable, Sendable {
        public var number: String
        public var law: String
    }

    public static func norm(_ text: String) -> Norm? {
        let spaced = text.replacingOccurrences(of: "§", with: " § ")
        let parts = spaced.split(whereSeparator: { $0 == " " || $0 == "," || $0 == ";" || $0 == "(" || $0 == ")" }).map(String.init)
        guard let numberIndex = parts.firstIndex(where: { $0.first?.isNumber == true }) else { return nil }
        let number = parts[numberIndex].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".:"))
        var law: String?
        var index = parts.count - 1
        while index > numberIndex {
            let part = parts[index]
            let letters = part.filter(\.isLetter)
            if letters.count == part.count, part.count >= 2, part.contains(where: \.isUppercase) || part == part.lowercased() {
                if ["abs", "satz", "nr", "buchst", "ff", "s", "lit", "alt", "abschn", "a"].contains(part.lowercased().trimmingCharacters(in: .punctuationCharacters)) {
                    index -= 1; continue
                }
                law = part.lowercased()
                // „SGB V“: a roman numeral after the code.
                if index + 1 < parts.count, Set(parts[index + 1]).isSubset(of: Set("IVX")), !parts[index + 1].isEmpty {
                    law = law! + " " + parts[index + 1].lowercased()
                }
                break
            }
            if Set(part).isSubset(of: Set("IVX")), index - 1 > numberIndex, parts[index - 1].lowercased() == "sgb" {
                law = "sgb " + part.lowercased(); break
            }
            index -= 1
        }
        guard let law, !number.isEmpty else { return nil }
        return Norm(number: number, law: law)
    }

    /// The norm a query asks for: needs „§“/„Abschn.“ or a law the package cites.
    static func normQuery(_ query: String, laws: Set<String>) -> Norm? {
        guard let norm = norm(query) else { return nil }
        if query.contains("§") || query.lowercased().contains("abschn") || laws.contains(norm.law) { return norm }
        return nil
    }

    // MARK: Search

    /// Results for `query`, best first. `preferred` holds the hit keys the
    /// user pinned for this normalized query before (they come first);
    /// `field` ranks hits of that Lernfeld higher without hiding the others.
    public static func search(_ query: String, in catalog: MaterialCatalog, texts: MaterialTexts?,
                              preferred: [String] = [], field: Int? = nil, limit: Int = 40) -> [MaterialHit] {
        search(query, in: catalog, index: texts.map(MaterialTextIndex.init), preferred: preferred, field: field, limit: limit)
    }

    public static func search(_ query: String, in catalog: MaterialCatalog, index: MaterialTextIndex? = nil,
                              preferred: [String] = [], field: Int? = nil, limit: Int = 40) -> [MaterialHit] {
        let tokens = tokens(query)
        let laws = Set(catalog.fields.flatMap { $0.chapters.flatMap { $0.units.flatMap(\.norms) + $0.pages.flatMap(\.norms) } }
            .compactMap { norm($0)?.law })
        let normQuery = normQuery(query, laws: laws)
        guard !tokens.isEmpty || normQuery != nil else { return [] }
        func normMatch(_ norms: [String]) -> [String] {
            guard let normQuery else { return [] }
            return norms.filter { norm($0) == normQuery }
        }

        var hits: [String: MaterialHit] = [:]
        func add(_ hit: MaterialHit) {
            if var existing = hits[hit.id] {
                existing.score = max(existing.score, hit.score)
                if existing.detail == nil { existing.detail = hit.detail }
                hits[hit.id] = existing
            } else { hits[hit.id] = hit }
        }

        for f in catalog.fields {
            let fieldBonus = f.number == field ? 6 : 0
            for chapter in f.chapters {
                let chapterText = normalize(chapter.title)
                let chapterMatch = matches(tokens, in: chapterText)
                // Lessons: title, or chapter title for the chapter's first lesson.
                for lesson in chapter.lessons {
                    var score = 0
                    if matches(tokens, in: normalize(lesson.title)) { score = normalize(lesson.title) == tokens.joined(separator: " ") ? 30 : 20 }
                    else if chapterMatch, lesson.order == chapter.lessons.map(\.order).min() { score = 10 }
                    let lessonNorms = lessonPages(lesson, in: chapter).flatMap(\.norms)
                    let normHits = normMatch(lessonNorms)
                    if !normHits.isEmpty { score = max(score, 14) }
                    guard score > 0 else { continue }
                    add(MaterialHit(id: "lesson:\(lesson.id)", kind: .lesson, field: f.number, chapterKey: chapter.key,
                                    chapterTitle: chapter.title, title: lesson.title, pages: range(lesson.pages), lessonID: lesson.id,
                                    seconds: lesson.seconds, norms: unique(normHits.isEmpty ? lessonNorms : normHits).prefix(6).map { $0 },
                                    detail: nil, score: score + fieldBonus))
                }
                // Topic units: title, headings, norms.
                for unit in chapter.units {
                    var score = 0, detail: String?
                    if matches(tokens, in: normalize(unit.title)) { score = 18 }
                    if let heading = unit.headings.first(where: { matches(tokens, in: normalize($0)) }) {
                        score = max(score, 12); detail = heading
                    }
                    let normHits = normMatch(unit.norms)
                    if !normHits.isEmpty { score = max(score, 16); detail = detail ?? normHits.first }
                    if chapterMatch { score = max(score, 6) }
                    guard score > 0 else { continue }
                    add(MaterialHit(id: "unit:\(chapter.key):\(unit.pages[0])", kind: .unit, field: f.number, chapterKey: chapter.key,
                                    chapterTitle: chapter.title, title: unit.title, pages: range(unit.pages), lessonID: lesson(at: unit.pages[0], in: chapter)?.id,
                                    seconds: nil, norms: unique(normHits.isEmpty ? unit.norms : normHits).prefix(6).map { $0 },
                                    detail: detail, score: score + fieldBonus))
                }
                // Single pages: headings and norms, then the page text.
                var pageHits = 0
                for page in chapter.pages {
                    var score = 0, detail: String?
                    if let heading = page.heading, matches(tokens, in: normalize(heading)) { score = 11; detail = heading }
                    let normHits = normMatch(page.norms)
                    if !normHits.isEmpty { score = max(score, 13); detail = detail ?? page.heading }
                    if score == 0, let text = index?.pages[chapter.script?.file ?? ""]?[safe: page.page - 1],
                       matches(tokens, in: text) {
                        score = 4; detail = page.heading ?? page.head
                    }
                    guard score > 0, pageHits < 8 else { continue }
                    pageHits += 1
                    add(MaterialHit(id: "page:\(chapter.key):\(page.page)", kind: .page, field: f.number, chapterKey: chapter.key,
                                    chapterTitle: chapter.title, title: page.head ?? chapter.title, pages: page.page...page.page,
                                    lessonID: lesson(at: page.page, in: chapter)?.id, seconds: nil,
                                    norms: unique(normHits.isEmpty ? page.norms : normHits).prefix(6).map { $0 }, detail: detail,
                                    score: score + fieldBonus))
                }
            }
        }

        // A page inside a unit hit says nothing new.
        let units = hits.values.filter { $0.kind == .unit }
        for (key, hit) in hits where hit.kind == .page {
            if let page = hit.pages?.lowerBound,
               units.contains(where: { $0.chapterKey == hit.chapterKey && ($0.pages?.contains(page) ?? false) && $0.score >= hit.score }) {
                hits[key] = nil
            }
        }
        for (rank, key) in preferred.enumerated() { hits[key]?.score += 1_000 - rank }
        return hits.values.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.field != $1.field { return $0.field < $1.field }
            if $0.chapterKey != $1.chapterKey { return $0.chapterKey < $1.chapterKey }
            return ($0.pages?.lowerBound ?? 0) < ($1.pages?.lowerBound ?? 0)
        }.prefix(limit).map { $0 }
    }

    /// The hit a stored key names, whatever the query (for pinned material).
    public static func hit(forKey key: String, in catalog: MaterialCatalog) -> MaterialHit? {
        let parts = key.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }
        switch parts[0] {
        case "lesson":
            guard let (field, chapter, lesson) = catalog.lesson(parts[1]) else { return nil }
            return MaterialHit(id: key, kind: .lesson, field: field.number, chapterKey: chapter.key, chapterTitle: chapter.title,
                               title: lesson.title, pages: range(lesson.pages), lessonID: lesson.id, seconds: lesson.seconds,
                               norms: unique(lessonPages(lesson, in: chapter).flatMap(\.norms)).prefix(6).map { $0 }, detail: nil, score: 0)
        case "unit", "page":
            guard parts.count == 3, let page = Int(parts[2]), let (field, chapter) = catalog.chapter(parts[1]) else { return nil }
            if parts[0] == "unit", let unit = chapter.units.first(where: { $0.pages.first == page }) {
                return MaterialHit(id: key, kind: .unit, field: field.number, chapterKey: chapter.key, chapterTitle: chapter.title,
                                   title: unit.title, pages: range(unit.pages), lessonID: lesson(at: page, in: chapter)?.id, seconds: nil,
                                   norms: unique(unit.norms).prefix(6).map { $0 }, detail: unit.headings.first, score: 0)
            }
            guard let info = chapter.pages.first(where: { $0.page == page }) ?? (page <= (chapter.script?.pageCount ?? 0) ? MaterialPage(page: page) : nil) else { return nil }
            return MaterialHit(id: key, kind: .page, field: field.number, chapterKey: chapter.key, chapterTitle: chapter.title,
                               title: info.head ?? chapter.title, pages: page...page, lessonID: lesson(at: page, in: chapter)?.id, seconds: nil,
                               norms: unique(info.norms).prefix(6).map { $0 }, detail: info.heading, score: 0)
        default: return nil
        }
    }

    static func range(_ pages: [Int]?) -> ClosedRange<Int>? {
        guard let pages, pages.count == 2, pages[0] <= pages[1] else { return nil }
        return pages[0]...pages[1]
    }

    static func lessonPages(_ lesson: MaterialLesson, in chapter: MaterialChapter) -> [MaterialPage] {
        guard let range = range(lesson.pages) else { return [] }
        return chapter.pages.filter { range.contains($0.page) }
    }

    /// The video lesson whose script pages contain `page`.
    static func lesson(at page: Int, in chapter: MaterialChapter) -> MaterialLesson? {
        chapter.lessons.first { range($0.pages)?.contains(page) ?? false }
    }

    static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
