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
/// Erkannte Formen (Leerraum zwischen den Teilen darf auch Zeilenumbruch,
/// geschütztes oder schmales Leerzeichen sein, wie in PDF-Text):
/// - `§ 35a EStG`, `§35a EStG`, `§ 15 Abs. 1 S. 1 Nr. 2 Buchst. a EStG`,
///   `§ 15 I 1 Nr. 2 EStG` (römischer Absatz, danach bloße Zahl = Satz),
///   `§ 4 (1) EStG`, `§ 4 ff. EStG`, `§ 35a des EStG`, `Art. 3 Abs. 1 GG`;
/// - vorangestelltes Gesetz: `EStG § 35a`, `LStR R 9.1`, `EStR 4.2`;
/// - Aufzählungen `§§ 4, 5 EStG`, `§§ 4 und 5`, `§§ 4–7` (je genannte Nummer
///   ein Verweis, keine erfundenen Zwischennummern);
/// - Ketten mit i.V.m./und/oder/sowie/bzw./Komma: ein nachgestelltes Gesetz
///   gilt für die vorangehenden Verweise ohne Gesetz, `… i.V.m. Abs. 3 EStG`
///   ist ein zweiter Verweis auf denselben Paragraphen;
/// - Verwaltungsvorschriften: `R 9.1 Abs. 2 LStR`, `Abschnitt 1.1 UStAE`,
///   `AEAO zu § 122 (AO)`, `Nr. 2 AEAO zu § 122`, `AEAO Nr. 2 zu § 122 AO`.
///
/// Ein bloßes `§ 35a` nimmt das zuletzt ausdrücklich genannte Gesetz davor
/// (Verwaltungsvorschriften zählen dafür nicht), sonst `defaultLawID`.
/// `Art.` und `R`/`Abschnitt` brauchen immer ein geschriebenes Gesetz.
/// Unbekannte oder mehrdeutige Abkürzungen ergeben keinen Verweis und erben
/// auch kein anderes Gesetz.
public struct LawCitationScanner: Sendable {
    /// One way to write a law. `units` holds ASCII UTF-16, a space stands for
    /// any run of white space; `folded`: compared case-insensitively (lowercased).
    fileprivate struct Alias: Sendable { var units: [UInt16]; var folded: Bool; var id: String }
    /// Candidate aliases by their lowercased first unit.
    private let aliases: [UInt16: [Alias]]
    private let administrative: Set<String>
    private let defaultLawID: String?

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
        self.defaultLawID = defaultLawID.flatMap { id in entries.contains { $0.id == id } ? id : nil }
    }

    /// All citations in reading order, non-overlapping. Ambiguous or unknown
    /// laws yield no citation (never guess).
    public func citations(in text: String) -> [LawCitation] {
        Scan(scanner: self, u: Array(text.utf16)).run(text as NSString)
    }

    // MARK: - Pieces

    fileprivate enum Kind { case section, article, admin }
    fileprivate enum LawHit: Equatable { case known(String), ambiguous, unknown }
    fileprivate struct Item {
        var start: Int, end: Int, key: String, paragraph: String?, kind: Kind
        /// Law written in front of this item (law-first form).
        var law: String? = nil
        /// Law-first with an ambiguous abbreviation: a law was written, none fits.
        var blocked = false
    }
    fileprivate struct Group {
        var items: [Item]
        /// Law written after the group, applies to the pending items of the chain.
        var law: LawHit?
        var end: Int
        /// A law written inside a group whose own law is another one
        /// (`AEAO zu § 122 AO`): it is the context for later bare citations.
        var mentioned: String? = nil
    }

    fileprivate struct Scan {
        let scanner: LawCitationScanner
        let u: [UInt16]
        var n: Int { u.count }
        init(scanner: LawCitationScanner, u: [UInt16]) { self.scanner = scanner; self.u = u }

        func run(_ text: NSString) -> [LawCitation] {
            var result: [LawCitation] = []
            var context: String? = nil
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

        func resolve(_ chain: [Group], context: inout String?, into result: inout [LawCitation], text: NSString) {
            var pending: [Item] = []
            func emit(_ item: Item, law: String, inferred: Bool) {
                switch item.kind {
                case .admin: guard scanner.administrative.contains(law) else { return }
                case .article: guard !inferred else { return }
                case .section: break
                }
                let range = NSRange(location: item.start, length: item.end - item.start)
                result.append(LawCitation(range: range, lawID: law, reference: LawReference(key: item.key, paragraph: item.paragraph),
                                          text: text.substring(with: range), inferredLaw: inferred))
                // Context for later bare "§": only a law written with a "§".
                if !inferred, item.kind == .section { remember(law) }
            }
            func remember(_ law: String) { if !scanner.administrative.contains(law) { context = law } }
            func flushBare() {
                for item in pending {
                    // "R 9.1" alone only within the default document (e.g. the LStR
                    // themselves); the context is never an administrative one.
                    let law = item.kind == .admin ? scanner.defaultLawID : context ?? scanner.defaultLawID
                    if let law { emit(item, law: law, inferred: true) }
                }
                pending = []
            }
            for g in chain {
                if g.items.contains(where: { $0.law != nil || $0.blocked }) {
                    // Law-first: earlier items do not take this law.
                    flushBare()
                    for item in g.items where !item.blocked {
                        if let law = item.law { emit(item, law: law, inferred: false) }
                    }
                    if let mentioned = g.mentioned { remember(mentioned) }
                    continue
                }
                pending += g.items
                switch g.law {
                case .known(let law)?:
                    for item in pending { emit(item, law: law, inferred: false) }
                    pending = []
                case .ambiguous?, .unknown?: pending = []
                case nil: break
                }
            }
            flushBare()
        }

        // MARK: Groups

        /// A citation group starting at `i`, or `nil`. `previous`: the last item of
        /// the chain, for a continuation like "… i.V.m. Abs. 3".
        func group(at i: Int, previous: Item?) -> Group? {
            guard i < n else { return nil }
            if u[i] == 0xA7 { return trailingLaw(sectionGroup(at: i)) }
            guard isASCIILetter(u[i]), i == 0 || !isWordChar(u[i - 1]) else { return nil }
            if let previous, keyword(i, Words.absatz) != nil {
                let q = qualifiers(from: i, lists: true, first: false)
                if q.paragraph != nil {
                    let item = Item(start: i, end: ff(q.end), key: previous.key, paragraph: q.paragraph, kind: previous.kind)
                    return trailingLaw(Group(items: [item], law: nil, end: item.end))
                }
            }
            if u[i] == 0x4E, let g = numberedAdministrative(at: i) { return g }
            if let k = keyword(i, Words.article), let g = articleGroup(at: i, after: k) { return trailingLaw(g) }
            if let g = lawFirst(at: i) { return g }
            if let g = adminPrefixGroup(at: i) { return trailingLaw(g) }
            return nil
        }

        /// `§ 4`, `§§ 4, 5`, `§§ 4–7` with qualifiers, without the law.
        func sectionGroup(at i: Int) -> Group? {
            var j = i + 1
            let plural = j < n && u[j] == 0xA7
            if plural { j += 1 }
            var items: [Item] = []
            while true {
                let s = skipWS(j)
                guard let num = sectionNumber(s) else { break }
                let q = qualifiers(from: num.end, lists: !plural, first: true)
                let end = ff(q.end)
                items.append(Item(start: items.isEmpty ? i : s, end: end, key: num.key, paragraph: q.paragraph, kind: .section))
                j = end
                guard plural, let sep = itemSeparator(skipWS(j)), sectionNumber(skipWS(sep)) != nil else { break }
                j = sep
            }
            return items.isEmpty ? nil : Group(items: items, law: nil, end: j)
        }

        /// `Art. 3 Abs. 1`; the law must follow.
        func articleGroup(at i: Int, after k: Int) -> Group? {
            let s = skipWS(k)
            guard let num = sectionNumber(s) else { return nil }
            let q = qualifiers(from: num.end, lists: true, first: true)
            let end = ff(q.end)
            return Group(items: [Item(start: i, end: end, key: num.key, paragraph: q.paragraph, kind: .article)], law: nil, end: end)
        }

        /// `R 9.1 Abs. 2`, `Abschnitt 1.1`, `A 1.1`; an administrative law must follow.
        func adminPrefixGroup(at i: Int) -> Group? {
            guard let k = keyword(i, Words.adminPrefix) else { return nil }
            let s = skipWS(k)
            guard s > k || u[k - 1] == 0x2E, let num = adminNumber(s) else { return nil }
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
            func finish(_ group: Group, mentioned: String? = nil) -> Group {
                var g = group
                for index in g.items.indices { g.items[index].law = id; g.items[index].blocked = id == nil }
                g.items[0].start = begin
                g.mentioned = mentioned
                return g
            }
            if !requireZu, u[j] == 0xA7, let g = sectionGroup(at: j) { return finish(g) }
            if !requireZu, let k = keyword(j, Words.article), let g = articleGroup(at: j, after: k) { return finish(g) }
            guard admin else { return nil }
            // AEAO: optional "Nr. 2", then "zu § 122", optionally the law of the §.
            var numbered = false
            if !requireZu, let k = keyword(j, Words.nummer), let v = adminNumber(skipWS(k)) { j = skipWS(v.end); numbered = true }
            if let k = keyword(j, Words.zu), skipWS(k) > k, u[skipWS(k)] == 0xA7, var g = sectionGroup(at: skipWS(k)) {
                for index in g.items.indices { g.items[index].paragraph = nil }
                var mentioned: String? = nil
                let after = skipWS(g.end)
                if after > g.end, let inner = law(at: after, allowUnknown: false) {
                    if case .known(let other) = inner.hit { mentioned = other }
                    g.end = inner.end; g.items[g.items.count - 1].end = inner.end
                }
                return finish(g, mentioned: mentioned)
            }
            guard !requireZu, !numbered else { return nil }
            if let g = adminPrefixGroup(at: j) { return finish(g) }
            // Without "R"/"Abschnitt" only a dotted number ("EStR 4.2"), not a year.
            if let num = adminNumber(j), num.key.contains(".") {
                let q = qualifiers(from: num.end, lists: true, first: false)
                let end = ff(q.end)
                return finish(Group(items: [Item(start: j, end: end, key: num.key, paragraph: q.paragraph, kind: .admin)], law: nil, end: end))
            }
            return nil
        }

        /// `Nr. 2 AEAO zu § 122`.
        func numberedAdministrative(at i: Int) -> Group? {
            guard let k = keyword(i, Words.nummer), let v = adminNumber(skipWS(k)) else { return nil }
            let j = skipWS(v.end)
            guard j > v.end else { return nil }
            return lawFirst(at: j, start: i, requireZu: true)
        }

        /// The law written after a group (`EStG`, `des EStG`), included in the last item.
        func trailingLaw(_ group: Group?) -> Group? {
            guard var g = group else { return nil }
            var j = skipWS(g.end)
            if let k = keyword(j, Words.article2), skipWS(k) > k, law(at: skipWS(k), allowUnknown: true) != nil { j = skipWS(k) }
            guard let hit = law(at: j, allowUnknown: true) else { return g }
            g.law = hit.hit
            g.end = hit.end
            g.items[g.items.count - 1].end = hit.end
            return g
        }

        // MARK: Laws

        /// The law abbreviation starting at `i` (whole word). `allowUnknown`: a
        /// word that looks like an abbreviation ("XYZG", two capitals) counts as
        /// a written but unknown law.
        func law(at i: Int, allowUnknown: Bool) -> (hit: LawHit, end: Int)? {
            guard i < n, isLetter(u[i]), i == 0 || !isWordChar(u[i - 1]) else { return nil }
            var best = 0, ids = Set<String>()
            for alias in scanner.aliases[LawCitationScanner.lower(u[i])] ?? [] {
                guard let end = match(alias, at: i), end == n || !isWordChar(u[end]) else { continue }
                if end > best { best = end; ids = [alias.id] } else if end == best { ids.insert(alias.id) }
            }
            if best > 0 { return (ids.count == 1 ? .known(ids.first!) : .ambiguous, best) }
            guard allowUnknown else { return nil }
            var j = i, capitals = 0
            while j < n, isWordChar(u[j]) || u[j] == 0x2D && j + 1 < n && isWordChar(u[j + 1]) {
                if u[j] >= 0x41 && u[j] <= 0x5A || u[j] == 0xC4 || u[j] == 0xD6 || u[j] == 0xDC { capitals += 1 }
                j += 1
            }
            let upperFirst = u[i] >= 0x41 && u[i] <= 0x5A
            return upperFirst && capitals >= 2 && j - i <= 20 ? (.unknown, j) : nil
        }

        func match(_ alias: Alias, at i: Int) -> Int? {
            var j = i
            for a in alias.units {
                if a == 0x20 {
                    guard j < n, isWS(u[j]) else { return nil }
                    j = skipWS(j); continue
                }
                guard j < n, (alias.folded ? LawCitationScanner.lower(u[j]) : u[j]) == a else { return nil }
                j += 1
            }
            return j
        }

        // MARK: Numbers and qualifiers

        /// `35a`, `4h`, `340l`: digits and up to two letters, a whole word.
        func sectionNumber(_ i: Int) -> (key: String, end: Int)? {
            guard let d = digits(i) else { return nil }
            var j = d
            while j < n, j - d < 2, isASCIILetter(u[j]) { j += 1 }
            if j > d, j == n || !isWordChar(u[j]) { return (key(i, j), j) }
            guard d == n || !isWordChar(u[d]) else { return nil }
            return (key(i, d), d)
        }

        /// `9.1`, `39b.1`, `13a.2`, `55`.
        func adminNumber(_ i: Int) -> (key: String, end: Int)? {
            guard var j = digits(i) else { return nil }
            while true {
                var k = j
                while k < n, k - j < 2, isASCIILetter(u[k]) { k += 1 }
                if k < n - 1, u[k] == 0x2E, let next = digits(k + 1) { j = next; continue }
                if k == n || !isWordChar(u[k]) { j = k; break }
                if j == n || !isWordChar(u[j]) { break }
                return nil
            }
            return (key(i, j), j)
        }

        func digits(_ i: Int) -> Int? {
            var j = i
            while j < n, u[j] >= 0x30 && u[j] <= 0x39, j - i < 6 { j += 1 }
            return j > i ? j : nil
        }

        func key(_ from: Int, _ to: Int) -> String { String(decoding: u[from..<to], as: UTF16.self).lowercased() }

        /// Absatz, Satz, Nummer, Buchstabe … after a number; the paragraph is the
        /// first Absatz. `lists`: "Abs. 1 und 2", "Nr. 1 bis 3" (not in `§§`,
        /// where a comma starts the next section). `first`: a Roman Absatz or
        /// "(1)" may follow the number directly.
        func qualifiers(from i: Int, lists: Bool, first: Bool) -> (end: Int, paragraph: String?) {
            var end = i, paragraph: String? = nil, firstQualifier = first, afterRoman = false
            loop: while true {
                let j = skipWS(end)
                guard j < n else { break }
                if firstQualifier {
                    firstQualifier = false
                    if law(at: j, allowUnknown: false) == nil, let r = roman(j) {
                        paragraph = r.value; end = r.end; afterRoman = true; continue
                    }
                    if u[j] == 0x28, let v = sectionNumber(j + 1), v.end < n, u[v.end] == 0x29 {
                        paragraph = v.key; end = v.end + 1; continue
                    }
                }
                // "§ 15 I 1": a plain number after the Roman Absatz is the Satz.
                if afterRoman, let d = digits(j), d == n || !isWordChar(u[d]) {
                    afterRoman = false; end = d
                    if lists { end = valueList(end, letters: false) }
                    continue
                }
                afterRoman = false
                for (words, letters) in [(Words.absatz, false), (Words.satz, false), (Words.nummer, false), (Words.buchstabe, true),
                                         (Words.halbsatz, false), (Words.alternative, false), (Words.unterabsatz, false)] {
                    guard let k = keyword(j, words) else { continue }
                    let v = skipWS(k)
                    if words == Words.absatz, let r = roman(v) {
                        if paragraph == nil { paragraph = r.value }
                        end = r.end; afterRoman = true; continue loop
                    }
                    guard let value = letters ? letterValue(v) : sectionNumber(v) else { continue }
                    if words == Words.absatz, paragraph == nil { paragraph = value.key }
                    end = value.end
                    if lists { end = valueList(end, letters: letters) }
                    continue loop
                }
                break
            }
            return (end, paragraph)
        }

        /// "1 und 2", "1, 2", "1 bis 3" after a qualifier value.
        func valueList(_ i: Int, letters: Bool) -> Int {
            var end = i
            while let sep = itemSeparator(skipWS(end)) {
                let v = skipWS(sep)
                guard let value = letters ? letterValue(v) : sectionNumber(v) else { break }
                end = value.end
            }
            return end
        }

        func letterValue(_ i: Int) -> (key: String, end: Int)? {
            var j = i
            while j < n, j - i < 2, u[j] >= 0x61 && u[j] <= 0x7A { j += 1 }
            guard j > i, j == n || !isWordChar(u[j]) else { return nil }
            return (key(i, j), j)
        }

        /// I … XX as a whole word.
        func roman(_ i: Int) -> (value: String, end: Int)? {
            var j = i
            while j < n, j - i < 5, u[j] == 0x49 || u[j] == 0x56 || u[j] == 0x58 { j += 1 }
            guard j > i, j == n || !isWordChar(u[j]), let index = Words.romans.firstIndex(of: Array(u[i..<j])) else { return nil }
            return (String(index + 1), j)
        }

        /// "ff." / "f." after a citation.
        func ff(_ i: Int) -> Int {
            let j = skipWS(i)
            return keyword(j, Words.following) ?? i
        }

        /// Between the sections of `§§`.
        func itemSeparator(_ i: Int) -> Int? { keyword(i, Words.itemSeparators) }

        /// Between two citations of one chain: i.V.m., und, oder, sowie, bzw., Komma …
        /// (up to two, as in ", sowie").
        func connector(_ i: Int) -> Int? {
            guard let first = oneConnector(i) else { return nil }
            return oneConnector(skipWS(first)) ?? first
        }

        func oneConnector(_ i: Int) -> Int? {
            guard i < n else { return nil }
            if let k = dottedAbbreviation(i, ["iI", "vV", "mM"]) ?? dottedAbbreviation(i, ["iI", "sS", "dDvV"]) { return k }
            if let k = keyword(i, Words.inVerbindung), let v = keyword(skipWS(k), Words.verbindung), let m = keyword(skipWS(v), Words.mit),
               skipWS(k) > k, skipWS(v) > v { return m }
            return keyword(i, Words.connectors)
        }

        /// "i.V.m.", "i. V. m.", "iVm", "i.S.d." (letters from the sets, optional
        /// dots and spaces after a dot).
        func dottedAbbreviation(_ i: Int, _ letters: [String]) -> Int? {
            guard i == 0 || !isWordChar(u[i - 1]) else { return nil }
            var j = i, dots = 0
            for (index, set) in letters.enumerated() {
                guard j < n, set.utf16.contains(u[j]) else { return nil }
                j += 1
                if j < n, u[j] == 0x2E {
                    j += 1; dots += 1
                    if index < letters.count - 1 { j = skipWS(j) }
                }
            }
            // "iVm" or at least two dots ("i.V.m", "i. V. m."); "iV.m" is no connector.
            guard dots == 0 || dots >= 2 else { return nil }
            if u[j - 1] != 0x2E, j < n, isWordChar(u[j]) { return nil }
            return j
        }

        /// One of `words` at `i`; a word ending in a letter must end there.
        func keyword(_ i: Int, _ words: [[UInt16]]) -> Int? {
            for word in words where i + word.count <= n {
                var same = true
                for (k, c) in word.enumerated() where u[i + k] != c { same = false; break }
                guard same else { continue }
                let end = i + word.count
                if isWordChar(word[word.count - 1]), end < n, isWordChar(u[end]) { continue }
                if isWordChar(word[0]), i > 0, isWordChar(u[i - 1]) { continue }
                return end
            }
            return nil
        }

        // MARK: Characters

        func skipWS(_ i: Int) -> Int {
            var j = i
            while j < n, isWS(u[j]) { j += 1 }
            return j
        }
        func isWS(_ c: UInt16) -> Bool {
            switch c {
            case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: true
            default: false
            }
        }
        func isASCIILetter(_ c: UInt16) -> Bool { c >= 0x41 && c <= 0x5A || c >= 0x61 && c <= 0x7A }
        func isLetter(_ c: UInt16) -> Bool {
            if c < 0x80 { return isASCIILetter(c) }
            guard !(0xD800...0xDFFF).contains(c), let scalar = Unicode.Scalar(c) else { return false }
            return scalar.properties.isAlphabetic
        }
        func isWordChar(_ c: UInt16) -> Bool {
            if c < 0x80 { return isASCIILetter(c) || c >= 0x30 && c <= 0x39 }
            guard !(0xD800...0xDFFF).contains(c), let scalar = Unicode.Scalar(c) else { return false }
            return scalar.properties.isAlphabetic || scalar.properties.numericType != nil
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
        static let article = w(["Artikel", "Art.", "Art"])
        static let article2 = w(["des", "der"])
        static let adminPrefix = w(["Abschnitt", "Abschn.", "R", "A"])
        static let zu = w(["zu"])
        static let following = w(["ff.", "ff", "f."])
        static let itemSeparators = w([",", "und", "u.", "oder", "sowie", "bis", "-", "\u{2013}", "\u{2014}", "/"])
        static let connectors = w([",", ";", "/", "und", "u.", "oder", "sowie", "bzw.", "bzw"])
        static let inVerbindung = w(["in"])
        static let verbindung = w(["Verbindung"])
        static let mit = w(["mit"])
        static let romans = w(["I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X",
                               "XI", "XII", "XIII", "XIV", "XV", "XVI", "XVII", "XVIII", "XIX", "XX"])
    }
}
