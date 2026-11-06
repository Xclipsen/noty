// Erkennt Gesetzesverweise („§ 35a EStG“, „R 9.1 LStR“, „AEAO zu § 122“) in
// beliebigem Text (Textfelder, PDF-Text, später Handschrift-OCR). Abgeleitete
// Daten: nichts davon wird im Heft gespeichert (docs/PARAGRAPH-LINKS.md).
import Foundation

/// One recognised reference in a scanned string.
public struct LawCitation: Equatable, Hashable, Sendable {
    /// UTF-16 range in the scanned string (NSString/NSRange semantics), covering
    /// the whole visible citation, e.g. "§ 35a Abs. 2 EStG".
    public var range: NSRange
    /// Catalog id of the law (`LawEntry.id`).
    public var lawID: String
    /// Section key (matches `LawSection.keys`, lowercased) and optional Absatz.
    public var reference: LawReference
    /// The matched text as it appears in the source.
    public var text: String
    /// True when the law was not written next to the number but taken from
    /// context (previous citation in the same text or the default law).
    public var inferredLaw: Bool

    public init(range: NSRange, lawID: String, reference: LawReference, text: String, inferredLaw: Bool = false) {
        self.range = range; self.lawID = lawID; self.reference = reference; self.text = text; self.inferredLaw = inferredLaw
    }
    // `LawReference` is only Equatable; hashing its fields keeps it unchanged.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(range.location); hasher.combine(range.length); hasher.combine(lawID)
        hasher.combine(reference.key); hasher.combine(reference.paragraph); hasher.combine(text); hasher.combine(inferredLaw)
    }
}

/// Finds citations of laws from the catalog. Pure and synchronous; build once
/// per catalog and reuse (it precompiles its patterns).
///
/// Grundsatz: ein falscher Link ist schlimmer als keiner.
///
/// Erkannte Formen (Leerraum zwischen den Teilen darf auch Zeilenumbruch,
/// geschütztes oder schmales Leerzeichen sein, wie in PDF-Text):
/// - `§ 35a EStG`, `§35a EStG`, `§ 35 a EStG`, `§ 15 Abs. 1 S. 1 Nr. 2 Buchst. a EStG`,
///   `§ 15 I 1 Nr. 2 EStG` (römischer Absatz, danach bloße Zahl = Satz),
///   `§ 4 (1) EStG`, `§ 4 ff. EStG`, `§ 35a des EStG`, `Art. 3 Abs. 1 GG`;
///   wiederholte Angaben `Satz 1 und Satz 2`, `Abs. 1 bis Abs. 3`;
/// - vorangestelltes Gesetz: `EStG § 35a`, `LStR R 9.1`, `EStR 4.2`;
/// - Aufzählungen `§§ 4, 5 EStG`, `§§ 4 und 5`, `§§ 4–7`, auch `§ 4 und 5 EStG`
///   (je genannte Nummer ein Verweis, keine erfundenen Zwischennummern);
/// - Ketten mit i.V.m./und/oder/sowie/bzw./bis/Komma: ein nachgestelltes
///   Gesetz gilt für die vorangehenden Verweise derselben Art ohne Gesetz
///   (§ nur aus Gesetzen, Art. nur mit Art., R nur aus Verwaltungsvorschriften);
///   `… i.V.m. Abs. 3 EStG` ist ein zweiter Verweis auf denselben Paragraphen
///   und behält dessen Gesetz;
/// - Verwaltungsvorschriften: `R 9.1 Abs. 2 LStR`, `Abschnitt 1.1 UStAE`,
///   `AEAO zu § 122 (AO)`, `Nr. 2 AEAO zu § 122`, `AEAO Nr. 2 zu § 122 AO`.
///
/// Ein bloßes `§ 35a` nimmt das zuletzt mit `§` geschriebene Gesetz davor
/// (Verwaltungsvorschriften zählen nicht, `AEAO zu §` gilt als AO), sonst
/// `defaultLawID`. Ein geschriebenes, aber unbekanntes oder mehrdeutiges
/// Gesetz („§ 3 SolZG“, „§ 5 des Gesellschaftsvertrags“, „§ 15
/// Handelsgesetzbuch“) ergibt keinen Verweis und sperrt das Erschließen bis
/// zum nächsten bekannten Gesetz. `Art.` und `R`/`Abschnitt` brauchen immer
/// ein geschriebenes Gesetz.
public struct LawCitationScanner: Sendable {
    /// One way to write a law. `units` holds ASCII UTF-16, a space stands for
    /// any run of white space; `folded`: compared case-insensitively (lowercased).
    fileprivate struct Alias: Sendable { var units: [UInt16]; var folded: Bool; var id: String }
    /// Candidate aliases by their lowercased first unit.
    private let aliases: [UInt16: [Alias]]
    private let administrative: Set<String>
    private let defaultLawID: String?
    /// The law an administrative document explains (`AEAO zu § 122` → AO):
    /// context for later bare "§".
    private let explains: [String: String]

    /// `defaultLawID`: law used for a bare "§ 35a" when the text names no law before it.
    public init(entries: [LawEntry], defaultLawID: String? = nil) {
        var table: [UInt16: [Alias]] = [:]
        var seen = Set<String>()
        func add(_ name: String, folded: Bool, id: String) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            // Only ASCII names: matching works on UTF-16 units.
            guard !trimmed.isEmpty, trimmed.utf16.allSatisfy({ $0 < 0x80 }) else { return }
            let collapsed = trimmed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let units = Array((folded ? collapsed.lowercased() : collapsed).utf16)
            guard seen.insert("\(folded)|\(String(decoding: units, as: UTF16.self))|\(id)").inserted else { return }
            table[Self.lower(units[0]), default: []].append(Alias(units: units, folded: folded, id: id))
        }
        for entry in entries {
            // The abbreviation as written; long ones also in other case ("EstG",
            // "ESTG"), short ones only in capitals ("AO", not "ao" in prose).
            add(entry.abbr, folded: entry.abbr.count >= 4, id: entry.id)
            add(entry.abbr.uppercased(), folded: false, id: entry.id)
            for alias in (entry.aliases ?? []) + (entry.id == "hgb" ? ["HBG"] : []) { add(alias, folded: true, id: entry.id) }
        }
        aliases = table
        administrative = Set(entries.filter { $0.kind == "administration" }.map(\.id))
        let ids = Set(entries.map(\.id))
        explains = ids.contains("aeao") && ids.contains("ao") ? ["aeao": "ao"] : [:]
        self.defaultLawID = defaultLawID.flatMap { ids.contains($0) ? $0 : nil }
    }

    /// All citations in reading order, non-overlapping. Ambiguous or unknown
    /// laws yield no citation (never guess).
    public func citations(in text: String) -> [LawCitation] {
        Scan(scanner: self, u: Array(text.utf16)).run(text as NSString)
    }

    // MARK: - Pieces

    /// `zu`: the section in `AEAO zu § 122`; its law is the administrative one.
    fileprivate enum Kind { case section, article, admin, zu }
    fileprivate enum LawHit: Equatable { case known(String), ambiguous, unknown }
    fileprivate struct Item {
        var start: Int, end: Int, key: String, paragraph: String?, kind: Kind
        /// Law written in front of this item (law-first form).
        var law: String? = nil
        /// Law-first with an ambiguous abbreviation: a law was written, none fits.
        var blocked = false
        /// Never emitted (`§ 35 a Wort`: the number is uncertain).
        var drop = false
        /// A further number after a single `§` (`§ 4 und 5 EStG`): only with a written law.
        var extra = false
        /// `… i.V.m. Abs. 3`: same section as the item before.
        var continuation = false
    }
    fileprivate struct Group {
        var items: [Item]
        /// Law written after the group, applies to the pending items of the chain.
        var law: LawHit?
        var end: Int
        /// The law a group with another own law speaks of (`AEAO zu § 122 AO`):
        /// context for later bare citations; `.unknown` blocks that context.
        var mentioned: LawHit? = nil
    }
    fileprivate enum Context { case none, law(String), blocked }

    fileprivate struct Scan {
        let scanner: LawCitationScanner
        let u: [UInt16]
        let n: Int
        init(scanner: LawCitationScanner, u: [UInt16]) { self.scanner = scanner; self.u = u; n = u.count }

        /// The unit at `i`, 0 outside the text: every lookahead reads through this.
        func c(_ i: Int) -> UInt16 { i >= 0 && i < n ? u[i] : 0 }

        func run(_ text: NSString) -> [LawCitation] {
            var result: [LawCitation] = []
            var context = Context.none
            var i = 0
            while i < n {
                guard let first = group(at: i, previous: nil) else { i += 1; continue }
                var chain = [first], end = first.end
                while let connector = connector(skipWS(end)) {
                    let next = skipWS(connector)
                    guard let g = group(at: next, previous: chain.last?.items.last) else { break }
                    chain.append(g); end = g.end
                }
                resolve(chain, context: &context, into: &result, text: text)
                i = max(end, i + 1)
            }
            return result
        }

        func resolve(_ chain: [Group], context: inout Context, into result: inout [LawCitation], text: NSString) {
            enum Previous { case pending, law(String), none }
            var pending: [Item] = []
            var previous = Previous.none
            func remember(_ law: String) { if !scanner.administrative.contains(law) { context = .law(law) } }
            /// Whether `law` fits the kind: § and Art. only laws, R/Abschnitt and `zu §` only administrative ones.
            func fits(_ item: Item, _ law: String) -> Bool {
                switch item.kind {
                case .admin, .zu: scanner.administrative.contains(law)
                case .section, .article: !scanner.administrative.contains(law)
                }
            }
            @discardableResult
            func emit(_ item: Item, law: String, inferred: Bool) -> Bool {
                guard !item.drop, fits(item, law), !(item.kind == .article && inferred) else { return false }
                let range = NSRange(location: item.start, length: item.end - item.start)
                result.append(LawCitation(range: range, lawID: law, reference: LawReference(key: item.key, paragraph: item.paragraph),
                                          text: text.substring(with: range), inferredLaw: inferred))
                // Context for later bare "§": only a law written with a "§".
                if !inferred, item.kind == .section { remember(law) }
                return true
            }
            func bare(_ item: Item) {
                guard !item.extra else { return }
                let law: String?
                switch (item.kind, context) {
                case (_, .blocked), (.article, _), (.zu, _): law = nil
                // "R 9.1" alone only within the default document (e.g. the LStR
                // themselves); the context is never an administrative one.
                case (.admin, _), (.section, .none): law = scanner.defaultLawID
                case (.section, .law(let id)): law = id
                }
                if let law { emit(item, law: law, inferred: true) }
            }
            func flushBare() {
                for item in pending { bare(item) }
                pending = []
            }
            for g in chain {
                guard let last = g.items.last else { continue }
                if g.items.contains(where: { $0.law != nil || $0.blocked }) {
                    // Law-first: earlier items do not take this law.
                    flushBare()
                    var law: String? = nil
                    for item in g.items {
                        if let id = item.law, !item.blocked, emit(item, law: id, inferred: false) { law = id }
                    }
                    if g.items.contains(where: \.blocked) { context = .blocked }
                    switch g.mentioned {
                    case .known(let id)?: remember(id)
                    case .ambiguous?, .unknown?: context = .blocked
                    case nil: break
                    }
                    previous = law.map { .law($0) } ?? .none
                    continue
                }
                if g.items[0].continuation {
                    switch previous {
                    case .pending: break
                    case .law(let law):
                        // "§ 4 EStG i.V.m. Abs. 2": same section, same law. Another
                        // law written after it ("… Abs. 2 GG") is a contradiction.
                        switch g.law {
                        case nil: if !emit(last, law: law, inferred: true) { previous = .none }
                        case .known(law)?: if !emit(last, law: law, inferred: false) { previous = .none }
                        case .known?: previous = .none
                        case .ambiguous?, .unknown?: previous = .none; context = .blocked
                        }
                        continue
                    case .none:
                        if g.law == .unknown || g.law == .ambiguous { context = .blocked }
                        continue
                    }
                }
                pending += g.items
                switch g.law {
                case .known(let law)?:
                    // Only items of the kind the law was written to take it ("§ 2
                    // i.V.m. R 2 EStR": § 2 is not EStR); the others stay bare.
                    var emitted = false
                    for item in pending {
                        if item.kind != last.kind { bare(item) } else if emit(item, law: law, inferred: false) { emitted = true }
                    }
                    previous = emitted ? .law(law) : .none
                    pending = []
                case .ambiguous?, .unknown?:
                    pending = []; previous = .none; context = .blocked
                case nil:
                    previous = .pending
                }
            }
            flushBare()
        }

        // MARK: Groups

        /// A citation group starting at `i`, or `nil`. `previous`: the last item of
        /// the chain, for a continuation like "… i.V.m. Abs. 3".
        func group(at i: Int, previous: Item?) -> Group? {
            guard i < n else { return nil }
            if c(i) == 0xA7 { return trailingLaw(sectionGroup(at: i)) }
            guard isASCIILetter(c(i)), !isWordChar(c(i - 1)) else { return nil }
            if let previous, previous.kind != .zu, keyword(i, Words.absatz) != nil {
                let q = qualifiers(from: i, lists: true, first: false)
                if q.paragraph != nil {
                    var item = Item(start: i, end: ff(q.end), key: previous.key, paragraph: q.paragraph, kind: previous.kind)
                    item.continuation = true
                    return trailingLaw(Group(items: [item], law: nil, end: item.end))
                }
            }
            if c(i) == 0x4E, let g = numberedAdministrative(at: i) { return g }
            if let k = keyword(i, Words.article), let g = articleGroup(at: i, after: k) { return trailingLaw(g) }
            if let g = lawFirst(at: i) { return g }
            if let g = adminPrefixGroup(at: i) { return trailingLaw(g) }
            return nil
        }

        /// `§ 4`, `§§ 4, 5`, `§§ 4–7`, `§ 4 und 5` with qualifiers, without the law.
        func sectionGroup(at i: Int) -> Group? {
            var j = i + 1
            let plural = c(j) == 0xA7
            if plural { j += 1 }
            var items: [Item] = []
            while true {
                let s = skipWS(j)
                guard let num = sectionNumber(s, spaced: true) else { break }
                // In "§§" a comma starts the next section, "und" after a qualifier
                // value is still that value ("§§ 4 Abs. 1 und 2, 5").
                let q = qualifiers(from: num.end, lists: true, first: true, comma: !plural)
                let end = ff(q.end)
                var item = Item(start: items.isEmpty ? i : s, end: end, key: num.key, paragraph: q.paragraph, kind: .section)
                item.drop = num.uncertain
                item.extra = !plural && !items.isEmpty
                items.append(item)
                j = end
                guard let sep = keyword(skipWS(j), Words.itemSeparators), sectionNumber(skipWS(sep), spaced: false) != nil else { break }
                j = sep
            }
            return items.isEmpty ? nil : Group(items: items, law: nil, end: j)
        }

        /// `Art. 3 Abs. 1`; the law must follow.
        func articleGroup(at i: Int, after k: Int) -> Group? {
            let s = skipWS(k)
            guard let num = sectionNumber(s, spaced: false) else { return nil }
            let q = qualifiers(from: num.end, lists: true, first: true)
            let end = ff(q.end)
            return Group(items: [Item(start: i, end: end, key: num.key, paragraph: q.paragraph, kind: .article)], law: nil, end: end)
        }

        /// `R 9.1 Abs. 2`, `Abschnitt 1.1`, `A 1.1`; an administrative law must follow.
        func adminPrefixGroup(at i: Int) -> Group? {
            guard let k = keyword(i, Words.adminPrefix) else { return nil }
            let s = skipWS(k)
            guard s > k || c(k - 1) == 0x2E, let num = adminNumber(s, dots: 2) else { return nil }
            let q = qualifiers(from: num.end, lists: true, first: false)
            let end = ff(q.end)
            return Group(items: [Item(start: i, end: end, key: num.key, paragraph: q.paragraph, kind: .admin)], law: nil, end: end)
        }

        /// Law written first: `EStG § 35a`, `LStR R 9.1`, `EStR 4.2`,
        /// `AEAO zu § 122`, `AEAO Nr. 2 zu § 122 AO`. `start`: where the
        /// visible citation starts (before the law for `Nr. 2 AEAO zu …`).
        func lawFirst(at i: Int, start: Int? = nil, requireZu: Bool = false) -> Group? {
            guard let hit = law(at: i, allowUnknown: false) else { return nil }
            let id: String?
            switch hit.hit { case .known(let law): id = law; default: id = nil }
            let admin = id.map(scanner.administrative.contains) ?? true
            let begin = start ?? i
            var j = skipWS(hit.end)
            guard j > hit.end, j < n else { return nil }
            func finish(_ group: Group, mentioned: LawHit? = nil) -> Group {
                var g = group
                for index in g.items.indices { g.items[index].law = id; g.items[index].blocked = id == nil }
                g.items[0].start = begin
                g.mentioned = mentioned
                return g
            }
            if !requireZu, c(j) == 0xA7, let g = sectionGroup(at: j) { return finish(g) }
            if !requireZu, let k = keyword(j, Words.article), let g = articleGroup(at: j, after: k) { return finish(g) }
            guard admin else { return nil }
            // AEAO: optional "Nr. 2", then "zu § 122", optionally the law of the §.
            var numbered = false
            if !requireZu, let k = keyword(j, Words.nummer), let v = adminNumber(skipWS(k), dots: 3) { j = skipWS(v.end); numbered = true }
            if let k = keyword(j, Words.zu), skipWS(k) > k, c(skipWS(k)) == 0xA7, var g = sectionGroup(at: skipWS(k)) {
                for index in g.items.indices { g.items[index].paragraph = nil; g.items[index].kind = .zu }
                var mentioned: LawHit? = id.flatMap { scanner.explains[$0] }.map { .known($0) } ?? .unknown
                let after = skipWS(g.end)
                if after > g.end, let inner = law(at: after, allowUnknown: false) {
                    mentioned = inner.hit
                    g.end = inner.end; g.items[g.items.count - 1].end = inner.end
                }
                return finish(g, mentioned: mentioned)
            }
            guard !requireZu, !numbered else { return nil }
            if let g = adminPrefixGroup(at: j) { return finish(g) }
            // Without "R"/"Abschnitt" only "4.2" (one dot), not a year or a date.
            if let num = adminNumber(j, dots: 1), num.key.contains(".") {
                let q = qualifiers(from: num.end, lists: true, first: false)
                let end = ff(q.end)
                return finish(Group(items: [Item(start: j, end: end, key: num.key, paragraph: q.paragraph, kind: .admin)], law: nil, end: end))
            }
            return nil
        }

        /// `Nr. 2 AEAO zu § 122`.
        func numberedAdministrative(at i: Int) -> Group? {
            guard let k = keyword(i, Words.nummer), let v = adminNumber(skipWS(k), dots: 3) else { return nil }
            let j = skipWS(v.end)
            guard j > v.end else { return nil }
            return lawFirst(at: j, start: i, requireZu: true)
        }

        /// The law written after a group (`EStG`, `des EStG`), included in the
        /// last item. "des/der" with any other word, or a capitalised word right
        /// after the citation ("§ 15 Handelsgesetzbuch"), is a written but unknown law.
        func trailingLaw(_ group: Group?) -> Group? {
            guard var g = group else { return nil }
            let j = skipWS(g.end)
            var hit: (hit: LawHit, end: Int)?
            if let k = keyword(j, Words.article2), skipWS(k) > k, isLetter(c(skipWS(k))) {
                let w = skipWS(k)
                hit = law(at: w, allowUnknown: true) ?? (.unknown, wordEnd(w))
            } else {
                hit = law(at: j, allowUnknown: true)
            }
            guard let hit else { return g }
            g.law = hit.hit
            g.end = hit.end
            g.items[g.items.count - 1].end = hit.end
            return g
        }

        // MARK: Laws

        /// The law abbreviation starting at `i` (whole word, "EStG-E" is none).
        /// `allowUnknown`: any other capitalised word counts as a written but
        /// unknown law ("XYZG", "SolZG", "Handelsgesetzbuch").
        func law(at i: Int, allowUnknown: Bool) -> (hit: LawHit, end: Int)? {
            guard i < n, isLetter(c(i)), !isWordChar(c(i - 1)) else { return nil }
            var best = 0, ids = Set<String>()
            for alias in scanner.aliases[LawCitationScanner.lower(c(i))] ?? [] {
                guard let end = match(alias, at: i), !isWordChar(c(end)), !(c(end) == 0x2D && isLetter(c(end + 1))) else { continue }
                if end > best { best = end; ids = [alias.id] } else if end == best { ids.insert(alias.id) }
            }
            if best > 0 { return (ids.count == 1 ? .known(ids.first!) : .ambiguous, best) }
            guard allowUnknown, isUpper(c(i)), !Words.notLaws.contains(where: { keyword(i, $0) != nil }) else { return nil }
            return (.unknown, wordEnd(i))
        }

        /// End of the word at `i`, hyphenated parts included ("BMF-Schreiben").
        func wordEnd(_ i: Int) -> Int {
            var j = i
            while j < n, isWordChar(c(j)) || c(j) == 0x2D && isWordChar(c(j + 1)) { j += 1 }
            return j
        }

        func match(_ alias: Alias, at i: Int) -> Int? {
            var j = i
            for a in alias.units {
                if a == 0x20 {
                    guard isWS(c(j)) else { return nil }
                    j = skipWS(j); continue
                }
                guard j < n, (alias.folded ? LawCitationScanner.lower(c(j)) : c(j)) == a else { return nil }
                j += 1
            }
            return j
        }

        // MARK: Numbers and qualifiers

        /// `35a`, `4h`, `340l`: digits and up to two letters, a whole word.
        /// `spaced`: also "35 a" when a law, a qualifier or the end of the
        /// citation follows the letter; otherwise `uncertain` (nothing is linked).
        func sectionNumber(_ i: Int, spaced: Bool) -> (key: String, end: Int, uncertain: Bool)? {
            guard let d = digits(i) else { return nil }
            var j = d
            while j < n, j - d < 2, isASCIILetter(c(j)) { j += 1 }
            if j > d, !isWordChar(c(j)) { return (key(i, j), j, false) }
            guard !isWordChar(c(d)) else { return nil }
            let s = skipWS(d)
            // A lone lowercase letter, not "f." / "u." / "a.F." / "i.V.m.".
            if spaced, s > d, c(s) >= 0x61 && c(s) <= 0x7A, !isWordChar(c(s + 1)), c(s + 1) != 0x2E {
                return (key(i, d) + key(s, s + 1), s + 1, !endsCitation(skipWS(s + 1)))
            }
            return (key(i, d), d, false)
        }

        /// What may follow a complete citation: end, punctuation, a qualifier,
        /// a law (also an unknown one), a connector or the next "§".
        func endsCitation(_ f: Int) -> Bool {
            if f >= n || [0x2E, 0x2C, 0x3B, 0x3A, 0x29, 0xA7].contains(c(f)) { return true }
            if Words.qualifiers.contains(where: { keyword(f, $0.words) != nil }) || keyword(f, Words.following) != nil { return true }
            return law(at: f, allowUnknown: true) != nil || oneConnector(f) != nil
        }

        /// `9.1`, `39b.1`, `13a.2`, `55`, UStAE `4.12.10`: up to three digits,
        /// then up to `dots` groups of one or two digits (letters allowed).
        /// A longer dotted run ("1.1.2025") is a date, not a key.
        func adminNumber(_ i: Int, dots: Int) -> (key: String, end: Int)? {
            guard let d = digits(i), d - i <= 3 else { return nil }
            var j = d, groups = 0
            while j < n, j - d < 2, isLowerASCII(c(j)) { j += 1 }
            while c(j) == 0x2E, let next = digits(j + 1) {
                guard next - j - 1 <= 2, groups < dots else { return nil }
                j = next; groups += 1
                while j < n, j - next < 2, isLowerASCII(c(j)) { j += 1 }
            }
            guard !isWordChar(c(j)) else { return nil }
            return (key(i, j), j)
        }

        func digits(_ i: Int) -> Int? {
            var j = i
            while j < n, c(j) >= 0x30 && c(j) <= 0x39, j - i < 6 { j += 1 }
            return j > i ? j : nil
        }

        func key(_ from: Int, _ to: Int) -> String { String(decoding: u[from..<to], as: UTF16.self).lowercased() }

        /// Absatz, Satz, Nummer, Buchstabe … after a number; the paragraph is the
        /// first Absatz. `lists`: "Abs. 1 und 2", "Satz 1 und Satz 2", "Nr. 1 bis 3";
        /// `comma`: also "Abs. 1, 2" (not in `§§`, where a comma starts the next
        /// section). `first`: a Roman Absatz or "(1)" may follow the number directly.
        func qualifiers(from i: Int, lists: Bool, first: Bool, comma: Bool = true) -> (end: Int, paragraph: String?) {
            var end = i, paragraph: String? = nil, firstQualifier = first, afterRoman = false
            loop: while true {
                let j = skipWS(end)
                guard j < n else { break }
                if firstQualifier {
                    firstQualifier = false
                    if law(at: j, allowUnknown: false) == nil, let r = roman(j) {
                        paragraph = r.value; end = r.end; afterRoman = true
                        if lists { end = valueList(end, Words.absatz, letters: false, comma: comma) }
                        continue
                    }
                    if c(j) == 0x28, let v = sectionNumber(j + 1, spaced: false), c(v.end) == 0x29 {
                        paragraph = v.key; end = v.end + 1; continue
                    }
                }
                // "§ 15 I 1": a plain number after the Roman Absatz is the Satz.
                if afterRoman, let d = digits(j), !isWordChar(c(d)) {
                    afterRoman = false; end = d
                    if lists { end = valueList(end, Words.satz, letters: false, comma: comma) }
                    continue
                }
                afterRoman = false
                for q in Words.qualifiers {
                    guard let k = keyword(j, q.words) else { continue }
                    let v = skipWS(k)
                    if q.words == Words.absatz, let r = roman(v) {
                        if paragraph == nil { paragraph = r.value }
                        end = r.end; afterRoman = true
                        if lists { end = valueList(end, Words.absatz, letters: false, comma: comma) }
                        continue loop
                    }
                    guard let value = q.letters ? letterValue(v) : sectionNumber(v, spaced: false).map({ (key: $0.key, end: $0.end) }) else { continue }
                    if q.words == Words.absatz, paragraph == nil { paragraph = value.key }
                    end = value.end
                    if lists { end = valueList(end, q.words, letters: q.letters, comma: comma) }
                    continue loop
                }
                break
            }
            return (end, paragraph)
        }

        /// "1 und 2", "1, 2", "1 bis 3", "Satz 1 und Satz 2" after a qualifier
        /// value. "Abs." repeats only after "bis"/dash: "Abs. 1 und Abs. 3" are two
        /// citations of the chain.
        func valueList(_ i: Int, _ words: [[UInt16]], letters: Bool, comma: Bool) -> Int {
            var end = i
            while let sep = keyword(skipWS(end), comma ? Words.itemSeparators : Words.itemSeparatorsNoComma) {
                var v = skipWS(sep)
                let range = keyword(skipWS(end), Words.ranges) != nil
                if words != Words.absatz || range, let k = keyword(v, words) { v = skipWS(k) }
                let romanEnd = words == Words.absatz ? roman(v)?.end : nil
                guard let next = romanEnd ?? (letters ? letterValue(v)?.end : sectionNumber(v, spaced: false)?.end) else { break }
                end = next
            }
            return end
        }

        func letterValue(_ i: Int) -> (key: String, end: Int)? {
            var j = i
            while j < n, j - i < 2, isLowerASCII(c(j)) { j += 1 }
            guard j > i, !isWordChar(c(j)) else { return nil }
            return (key(i, j), j)
        }

        /// I … XX as a whole word.
        func roman(_ i: Int) -> (value: String, end: Int)? {
            var j = i
            while j < n, j - i < 5, c(j) == 0x49 || c(j) == 0x56 || c(j) == 0x58 { j += 1 }
            guard j > i, !isWordChar(c(j)), let index = Words.romans.firstIndex(of: Array(u[i..<j])) else { return nil }
            return (String(index + 1), j)
        }

        /// "ff." / "f." after a citation.
        func ff(_ i: Int) -> Int {
            keyword(skipWS(i), Words.following) ?? i
        }

        /// Between two citations of one chain: i.V.m., und, oder, sowie, bzw., bis,
        /// Komma … (up to two, as in ", sowie").
        func connector(_ i: Int) -> Int? {
            guard let first = oneConnector(i) else { return nil }
            return oneConnector(skipWS(first)) ?? first
        }

        func oneConnector(_ i: Int) -> Int? {
            guard i < n else { return nil }
            if let k = dottedAbbreviation(i, ["iI", "vV", "mM"]) ?? dottedAbbreviation(i, ["iI", "sS", "dDvV"]) { return k }
            if let k = keyword(i, Words.inVerbindung), skipWS(k) > k, let v = keyword(skipWS(k), Words.verbindung),
               skipWS(v) > v, let m = keyword(skipWS(v), Words.mit) { return m }
            return keyword(i, Words.connectors)
        }

        /// "i.V.m.", "i. V. m.", "iVm", "i.S.d." (letters from the sets, optional
        /// dots and spaces after a dot).
        func dottedAbbreviation(_ i: Int, _ letters: [String]) -> Int? {
            guard !isWordChar(c(i - 1)) else { return nil }
            var j = i, dots = 0
            for (index, set) in letters.enumerated() {
                guard j < n, set.utf16.contains(c(j)) else { return nil }
                j += 1
                if c(j) == 0x2E {
                    j += 1; dots += 1
                    if index < letters.count - 1 { j = skipWS(j) }
                }
            }
            // "iVm" or at least two dots ("i.V.m", "i. V. m."); "iV.m" is no connector.
            guard dots == 0 || dots >= 2 else { return nil }
            if c(j - 1) != 0x2E, isWordChar(c(j)) { return nil }
            return j
        }

        /// One of `words` at `i`; a word ending in a letter must end there.
        func keyword(_ i: Int, _ words: [[UInt16]]) -> Int? {
            guard i >= 0 else { return nil }
            for word in words where i + word.count <= n {
                var same = true
                for (k, unit) in word.enumerated() where u[i + k] != unit { same = false; break }
                guard same else { continue }
                let end = i + word.count
                if isWordChar(word[word.count - 1]), isWordChar(c(end)) { continue }
                if isWordChar(word[0]), isWordChar(c(i - 1)) { continue }
                return end
            }
            return nil
        }

        // MARK: Characters

        func skipWS(_ i: Int) -> Int {
            var j = i
            while j < n, isWS(c(j)) { j += 1 }
            return j
        }
        func isWS(_ c: UInt16) -> Bool {
            switch c {
            case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: true
            default: false
            }
        }
        func isASCIILetter(_ c: UInt16) -> Bool { c >= 0x41 && c <= 0x5A || c >= 0x61 && c <= 0x7A }
        func isLowerASCII(_ c: UInt16) -> Bool { c >= 0x61 && c <= 0x7A }
        func isUpper(_ c: UInt16) -> Bool {
            if c < 0x80 { return c >= 0x41 && c <= 0x5A }
            guard !(0xD800...0xDFFF).contains(c), let scalar = Unicode.Scalar(c) else { return false }
            return scalar.properties.isUppercase
        }
        func isLetter(_ c: UInt16) -> Bool {
            if c < 0x80 { return isASCIILetter(c) }
            guard !(0xD800...0xDFFF).contains(c), let scalar = Unicode.Scalar(c) else { return false }
            return scalar.properties.isAlphabetic
        }
        /// Letters, digits and combining marks ("AO\u{308}G" is one word).
        func isWordChar(_ c: UInt16) -> Bool {
            if c == 0 { return false }
            if c < 0x80 { return isASCIILetter(c) || c >= 0x30 && c <= 0x39 }
            guard !(0xD800...0xDFFF).contains(c), let scalar = Unicode.Scalar(c) else { return false }
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: return true
            default: return scalar.properties.isAlphabetic || scalar.properties.numericType != nil
            }
        }
    }

    fileprivate static func lower(_ c: UInt16) -> UInt16 { c >= 0x41 && c <= 0x5A ? c + 0x20 : c }

    /// Fixed words, longest first where one is a prefix of another.
    fileprivate enum Words {
        static func w(_ list: [String]) -> [[UInt16]] { list.map { Array($0.utf16) } }
        static let absatz = w(["Absätze", "Absatz", "Abs.", "Abs"])
        static let satz = w(["Sätze", "Satz", "S."])
        static let nummer = w(["Nummern", "Nummer", "Nrn.", "Nr.", "Nr"])
        static let buchstabe = w(["Doppelbuchstabe", "Doppelbuchst.", "Buchstabe", "Buchst.", "Buchst", "lit.", "lit"])
        static let halbsatz = w(["Halbsatz", "Halbs.", "Hs.", "HS", "Hs"])
        static let alternative = w(["Alternative", "Alt.", "Variante", "Var."])
        static let unterabsatz = w(["Unterabsatz", "Unterabs.", "UAbs."])
        static let qualifiers: [(words: [[UInt16]], letters: Bool)] = [
            (absatz, false), (satz, false), (nummer, false), (buchstabe, true), (halbsatz, false), (alternative, false), (unterabsatz, false),
        ]
        static let article = w(["Artikel", "Art.", "Art"])
        static let article2 = w(["des", "der"])
        static let adminPrefix = w(["Abschnitt", "Abschn.", "R", "A"])
        /// Capitalised words that start something else than a law name.
        static let notLaws = qualifiers.map(\.words) + [article, adminPrefix, w(["Rz.", "Rn.", "Tz."])]
        static let zu = w(["zu"])
        static let following = w(["ff.", "ff", "f."])
        static let ranges = w(["bis", "-", "\u{2013}", "\u{2014}"])
        static let itemSeparators = w([",", "und", "u.", "oder", "sowie", "bis", "-", "\u{2013}", "\u{2014}"])
        static let itemSeparatorsNoComma = w(["und", "u.", "oder", "bis", "-", "\u{2013}", "\u{2014}"])
        static let connectors = w([",", ";", "/", "und", "u.", "oder", "sowie", "bzw.", "bzw", "bis"])
        static let inVerbindung = w(["in"])
        static let verbindung = w(["Verbindung"])
        static let mit = w(["mit"])
        static let romans = w(["I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X",
                               "XI", "XII", "XIII", "XIV", "XV", "XVI", "XVII", "XVIII", "XIX", "XX"])
    }
}
