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
/// - Gesetze als Abkürzung (`EStG`, Aliasse) oder mit ihrem Katalognamen samt
///   Beugung: `des Einkommensteuergesetzes`, `der Abgabenordnung`, `des
///   Bürgerlichen Gesetzbuchs`, `des Sechsten Buches Sozialgesetzbuch`,
///   `Einkommensteuergesetz (EStG)` (die Klammer muss dasselbe Gesetz nennen);
///   nur ganze Namen, nie Teile („Muster-Abgabenordnung“, „Einführungsgesetz zur
///   Abgabenordnung“ sind unbekannte Gesetze);
/// - ein Gesetz nach einer Klammer gilt ohne die Klammer für die Verweise davor
///   und darin (`§ 1 Absatz 2 (… § 1 Absatz 1 Satz 2) des Außensteuergesetzes`);
/// - Verwaltungsvorschriften: `R 9.1 Abs. 2 LStR`, `Abschnitt 1.1 UStAE`,
///   `AEAO zu § 122 (AO)`, `Nr. 2 AEAO zu § 122`, `AEAO Nr. 2 zu § 122 AO`.
///
/// Ein bloßes `§ 35a` nimmt das zuletzt mit `§` geschriebene Gesetz davor
/// (Verwaltungsvorschriften zählen nicht, `AEAO zu §` gilt als AO), sonst
/// `defaultLawID`. Ein geschriebenes, aber unbekanntes oder mehrdeutiges
/// Gesetz („§ 3 SolZG“, „§ 5 des Gesellschaftsvertrags“, „§ 15 Die Steuer“)
/// ergibt keinen Verweis und sperrt das Erschließen bis zum nächsten bekannten
/// Gesetz. `Art.` und `R`/`Abschnitt` brauchen immer ein geschriebenes Gesetz.
/// `Artikel 1 § 3` (Paragraph eines Artikels, Mantelgesetz) ergibt nie einen
/// Verweis, auch nicht für die folgenden Glieder der Kette.
/// Ebenso nie verlinkt: bestimmte frühere Fassungen („EStG 1987“, „a.F.“, „in
/// der am 31. Dezember 2008 geltenden Fassung“, nicht aber „in der jeweils
/// geltenden Fassung“), Aktenzeichen („V R 38/00“), gesperrt gesetzte
/// PDF-Überschriften („§ 2 5 b A b s“), „zu § 122a“/„vor §§ 169“ ohne Gesetz
/// (AEAO-Abschnitte), „(Mustersatzung, § 5)“ und unvollständige Angaben
/// („§ 138 Abs. Nr. 2“).
///
/// Im Text eines Gesetzes selbst (`lawText`, Leser) meint ein bloßes `§ 10`
/// nach Gesetzgebungstechnik immer dieses Gesetz, auch nach „§ 233a der
/// Abgabenordnung“; der Zusammenhang gilt dort nicht. Im AEAO meint es die AO.
/// „dieses Gesetzes“ ist dort das eigene Gesetz. Ausnahme: in einem Satz über
/// Vorschriften oder Teile eines anderen Gesetzes („… geltenden Vorschriften
/// des Einkommensteuergesetzes mit Ausnahme des § 44“, „der Siebente Teil der
/// Abgabenordnung“) bleiben bloße Paragraphen ohne Link.
public struct LawCitationScanner: Sendable {
    /// One way to write a law. `units` holds UTF-16 (ASCII when `folded`), a
    /// space stands for any run of white space; `folded`: compared
    /// case-insensitively (lowercased).
    /// `name`: a catalog name (or its declension), not an abbreviation.
    fileprivate struct Alias: Sendable { var units: [UInt16]; var folded: Bool; var id: String; var name = false }
    /// Candidate aliases by their lowercased first unit.
    private let aliases: [UInt16: [Alias]]
    private let administrative: Set<String>
    private let defaultLawID: String?
    private let ids: Set<String>
    /// The law an administrative document explains (`AEAO zu § 122` → AO):
    /// context for later bare "§".
    private let explains: [String: String]

    /// `defaultLawID`: law used for a bare "§ 35a" when the text names no law before it.
    public init(entries: [LawEntry], defaultLawID: String? = nil) {
        var table: [UInt16: [Alias]] = [:]
        var seen = Set<String>()
        func add(_ name: String, folded: Bool, id: String, isName: Bool = false) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            // Folded only ASCII: case folding works on ASCII UTF-16 units.
            guard !trimmed.isEmpty, !folded || trimmed.utf16.allSatisfy({ $0 < 0x80 }) else { return }
            let collapsed = trimmed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let units = Array((folded ? collapsed.lowercased() : collapsed).utf16)
            // By units: String equality would merge decomposed and composed umlauts.
            guard seen.insert("\(folded)|\(units)|\(id)").inserted else { return }
            table[Self.lower(units[0]), default: []].append(Alias(units: units, folded: folded, id: id, name: isName))
        }
        for entry in entries {
            // The abbreviation as written; long ones also in other case ("EstG",
            // "ESTG"), short ones only in capitals ("AO", not "ao" in prose).
            add(entry.abbr, folded: entry.abbr.count >= 4, id: entry.id)
            add(entry.abbr.uppercased(), folded: false, id: entry.id)
            for alias in (entry.aliases ?? []) + (entry.id == "hgb" ? ["HBG"] : []) { add(alias, folded: true, id: entry.id) }
            // Full names exactly as written (case, umlauts; also decomposed as
            // in PDF text). The same form for two entries makes it ambiguous.
            for form in Self.nameForms(entry.name) where form != entry.abbr {
                add(form, folded: false, id: entry.id, isName: true)
                add(form.decomposedStringWithCanonicalMapping, folded: false, id: entry.id, isName: true)
            }
        }
        aliases = table
        administrative = Set(entries.filter { $0.kind == "administration" }.map(\.id))
        let ids = Set(entries.map(\.id))
        self.ids = ids
        explains = ids.contains("aeao") && ids.contains("ao") ? ["aeao": "ao"] : [:]
        self.defaultLawID = defaultLawID.flatMap { ids.contains($0) ? $0 : nil }
    }

    /// A catalog name and its declined forms („Einkommensteuergesetz“ →
    /// „Einkommensteuergesetzes“, „Bürgerliches Gesetzbuch“ → „Bürgerlichen
    /// Gesetzbuchs“, „Sozialgesetzbuch – Viertes Buch“ → „Vierten Buches
    /// Sozialgesetzbuch“). Empty for names that are no safe designator (short,
    /// lowercase, with brackets or commas).
    static func nameForms(_ raw: String) -> [String] {
        let words = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        let name = words.joined(separator: " ")
        guard name.count >= 8, let first = name.unicodeScalars.first, first.properties.isUppercase,
              !name.contains(where: { "(),;:/\"„“".contains($0) }) else { return [] }
        func inflect(_ w: String) -> [String] {
            let l = w.lowercased()
            if l.hasSuffix("gesetz") || l.hasSuffix("erlass") { return [w, w + "es"] }
            if l.hasSuffix("buch") { return [w, w + "s", w + "es", w + "e"] }
            return [w] // …ordnung, …verordnung, …richtlinien: unchanged
        }
        let dashes = ["\u{2013}", "-", "\u{2014}"]
        // „Sozialgesetzbuch – Viertes Buch“.
        if words.count == 4, words[0] == "Sozialgesetzbuch", dashes.contains(words[1]), words[3] == "Buch", words[2].hasSuffix("es") {
            let ordinal = words[2], stem = String(ordinal.dropLast(2))
            var forms = dashes.map { "Sozialgesetzbuch \($0) \(ordinal) Buch" }
            forms += ["\(ordinal) Buch Sozialgesetzbuch", "\(ordinal) Buch des Sozialgesetzbuchs", "\(ordinal) Buch des Sozialgesetzbuches"]
            for book in ["Buch", "Buches", "Buchs"] {
                forms += ["\(stem)en \(book) Sozialgesetzbuch", "\(stem)en \(book) des Sozialgesetzbuchs", "\(stem)en \(book) des Sozialgesetzbuches"]
            }
            return forms
        }
        if words.count == 1 { return inflect(name) }
        // „Bürgerliches Gesetzbuch“: adjective and noun.
        if words.count == 2, words[0].hasSuffix("es"), words[1].unicodeScalars.first?.properties.isUppercase == true {
            return [name] + inflect(words[1]).map { "\(words[0].dropLast(2))en \($0)" }
        }
        // „Erbschaftsteuer- und Schenkungsteuergesetz“: the last word is declined.
        if words[0].hasSuffix("-") { return inflect(words[words.count - 1]).map { (words.dropLast() + [$0]).joined(separator: " ") } }
        // „Anwendungserlass zur Abgabenordnung“, „Gesetz betreffend …“: the first word.
        return inflect(words[0]).map { ([$0] + words.dropFirst()).joined(separator: " ") }
    }

    /// All citations in reading order, non-overlapping. Ambiguous or unknown
    /// laws yield no citation (never guess). Uses the init's `defaultLawID`.
    public func citations(in text: String) -> [LawCitation] {
        citations(in: text, defaultLawID: nil)
    }

    /// Same as `citations(in:)` with a per-call default law (a notebook's
    /// „Standardgesetz“, or the law a reader shows); `nil` uses the init one.
    /// An id that is not in the catalog counts as no default.
    ///
    /// `lawText`: `text` is the text of the default law itself (reader). A
    /// bare „§ 10“ then always means that law (for the AEAO: the AO), never an
    /// earlier other law of the same text; administrative defaults without an
    /// explained law keep the normal rules.
    public func citations(in text: String, defaultLawID: String?, lawText: Bool = false) -> [LawCitation] {
        let fallback = defaultLawID.flatMap { ids.contains($0) ? $0 : nil } ?? self.defaultLawID
        var own: String? = nil
        if lawText, let law = fallback {
            own = administrative.contains(law) ? explains[law] : law
        }
        return Scan(scanner: self, u: Array(text.utf16), defaultLaw: fallback, ownLaw: own, lawText: lawText).run(text as NSString)
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
        /// "zu § 122a", "vor §§ 169 bis 171": a section of another document
        /// (AEAO), only with a written law.
        var noInfer = false
    }
    fileprivate struct Group {
        var items: [Item]
        /// Law written after the group, applies to the pending items of the chain.
        var law: LawHit?
        var end: Int
        /// The law a group with another own law speaks of (`AEAO zu § 122 AO`):
        /// context for later bare citations; `.unknown` blocks that context.
        var mentioned: LawHit? = nil
        /// `Artikel 1 § 3`: a section of an article (Mantelgesetz). Never linked,
        /// and the rest of the chain is no longer certain.
        var nested = false
    }
    fileprivate enum Context { case none, law(String), blocked }

    fileprivate struct Scan {
        let scanner: LawCitationScanner
        let u: [UInt16]
        let n: Int
        /// Law for a bare „§“ without context, and for a bare „R“.
        let defaultLaw: String?
        /// In a law's own text: the law every bare „§“ means.
        let ownLaw: String?
        let lawText: Bool
        /// In a law's own text: sentences that speak of another law's
        /// provisions ("… geltenden Vorschriften des Einkommensteuergesetzes mit
        /// Ausnahme des § 44"); a bare "§" there is not certainly the own law.
        var foreignSentences: [Range<Int>] = []
        init(scanner: LawCitationScanner, u: [UInt16], defaultLaw: String?, ownLaw: String?, lawText: Bool) {
            self.scanner = scanner; self.u = u; n = u.count
            self.defaultLaw = defaultLaw; self.ownLaw = ownLaw; self.lawText = lawText
            if ownLaw != nil { foreignSentences = findForeignSentences() }
        }

        func findForeignSentences() -> [Range<Int>] {
            var result: [Range<Int>] = []
            var i = 0
            while i < n {
                guard isUpper(c(i)), !isWordChar(c(i - 1)) else { i += 1; continue }
                let k = wordEnd(i)
                func ends(_ suffix: [UInt16]) -> Bool {
                    k - i >= suffix.count && zip(u[(k - suffix.count)..<k], suffix).allSatisfy { LawCitationScanner.lower($0) == $1 }
                }
                guard k - i >= 4, skipWS(k) > k, Words.provisionSuffixes.contains(where: ends)
                        || Words.provisionInitials.contains(c(i)) && Words.provisions.contains(String(decoding: u[i..<k], as: UTF16.self)) else {
                    i = max(i + 1, k); continue
                }
                // "Abschnitt XI des Einkommensteuergesetzes", "Teil 2 der …"
                var t = skipWS(k)
                if let r = roman(t) { t = skipWS(r.end) } else if let d = adminNumber(t, dots: 2) { t = skipWS(d.end) }
                guard let a = keyword(t, Words.articles), skipWS(a) > a, let hit = law(at: skipWS(a), allowUnknown: true) else { i = k; continue }
                switch hit.hit {
                case .known(let id) where id == ownLaw: i = k; continue
                case .unknown:
                    let word = String(decoding: u[skipWS(a)..<hit.end], as: UTF16.self).lowercased()
                    guard ["gesetz", "gesetzes", "ordnung", "buch", "buchs", "buches"].contains(where: word.hasSuffix) else { i = k; continue }
                default: break
                }
                var s = i, e = hit.end
                while s > 0, !sentenceBoundary(s) { s -= 1 }
                while e < n, !sentenceBoundary(e) { e += 1 }
                result.append(s..<e)
                i = max(e, i + 1)
            }
            return result
        }

        /// A sentence starts at `i`: after ". " with a sentence number ("2Als",
        /// "2 Als"), an Absatz "(2)", a capitalised word, or a line break.
        func sentenceBoundary(_ i: Int) -> Bool {
            if c(i) == 0x0A || c(i) == 0x0D { return true }
            // "…, 5. (weggefallen) 6. in den Fällen": an item of an enumeration.
            if let d = digits(i), c(d) == 0x2E, isWS(c(d + 1)), isWS(c(i - 1)) {
                var p = i - 1
                while p > 0, isWS(c(p)) { p -= 1 }
                if [0x2C, 0x3B, 0x29].contains(c(p)) { return true }
            }
            guard c(i) == 0x28 || isWordChar(c(i)), isWS(c(i - 1)) || c(i - 1) == 0x2E else { return false }
            var p = i - 1
            while p > 0, isWS(c(p)) { p -= 1 }
            guard c(p) == 0x2E || c(p) == 0x3A else { return c(i) == 0x28 && c(p) == 0 }
            // "Abs. 2", "Nr. 3", "31. Dezember": no sentence end before a number
            // unless a capitalised word is glued to it ("2Als").
            if let d = digits(i) { return isUpper(c(d)) || c(skipWS(d)) == 0x29 }
            if c(i) == 0x28 { return digits(i + 1) != nil }
            guard isUpper(c(i)) else { return false }
            // A capitalised word after a word of at least four letters ("Gesetzes. Für").
            var w = p
            while w > 0, isLetter(c(w - 1)) { w -= 1 }
            return p - w >= 4
        }

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
                    let next = skipWS(connector.end)
                    guard let g = group(at: next, previous: chain.last?.items.last, ivm: connector.ivm) else { break }
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
                guard !item.extra, !item.noInfer else { return }
                if item.kind == .section, foreignSentences.contains(where: { $0.contains(item.start) }) { return }
                let law: String?
                switch (item.kind, context) {
                case (.article, _), (.zu, _): law = nil
                // In a law's own text a bare "§" is that law, whatever came before.
                case (.section, _) where ownLaw != nil: law = ownLaw
                // "R 9.1" alone only within the default document (e.g. the LStR
                // themselves); the context is never an administrative one.
                case (.admin, _) where lawText: law = defaultLaw
                case (_, .blocked): law = nil
                case (.admin, _), (.section, .none): law = defaultLaw
                case (.section, .law(let id)): law = id
                }
                if let law { emit(item, law: law, inferred: true) }
            }
            func flushBare() {
                for item in pending { bare(item) }
                pending = []
            }
            var nested = false, afterZu = false
            for g in chain {
                guard let last = g.items.last else { continue }
                if g.nested {
                    // "Artikel 1 § 3, § 5": nothing of this chain is certain any more,
                    // not even what came before ("§ 4 und Artikel 1 § 3 …").
                    nested = true; pending = []; previous = .none; context = .blocked
                    continue
                }
                let lawFirst = g.items.contains(where: { $0.law != nil || $0.blocked })
                if nested, !lawFirst { continue }
                if lawFirst {
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
                    if g.items.contains(where: { $0.kind == .zu }) { afterZu = true }
                    continue
                }
                // "AEAO zu § 140 und § 146": the second is AEAO as well, not the AO.
                if afterZu, g.law == nil { continue }
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
        /// `ivm`: the connector before was "i.V.m." ("… i.V.m. Satz 3 AO" is
        /// the same section; after "und"/"," only an Absatz continues it).
        func group(at i: Int, previous: Item?, ivm: Bool = false) -> Group? {
            guard i < n else { return nil }
            if c(i) == 0xA7 {
                guard var g = trailingLaw(sectionGroup(at: i)) else { return nil }
                // "(Mustersatzung, § 5)": the section of that document.
                if g.law == nil, documentBefore(i) { g.law = .unknown }
                return g
            }
            guard isASCIILetter(c(i)), !isWordChar(c(i - 1)) else { return nil }
            if let previous, previous.kind != .zu,
               keyword(i, Words.absatz) != nil || ivm && Words.qualifiers.contains(where: { keyword(i, $0.words) != nil }) {
                let q = qualifiers(from: i, lists: true, first: false)
                if q.paragraph != nil || q.end > i && keyword(i, Words.absatz) == nil {
                    var item = Item(start: i, end: ff(q.end), key: previous.key, paragraph: q.paragraph ?? previous.paragraph, kind: previous.kind)
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
            let foreignSection = wordBefore(i).map(Words.zuVor.contains) ?? false
            while true {
                let s = skipWS(j)
                guard let num = sectionNumber(s, spaced: true) else { break }
                // In "§§" a comma starts the next section, "und" after a qualifier
                // value is still that value ("§§ 4 Abs. 1 und 2, 5").
                let q = qualifiers(from: num.end, lists: true, first: true, comma: !plural)
                let end = ff(q.end)
                var item = Item(start: items.isEmpty ? i : s, end: end, key: num.key, paragraph: q.paragraph, kind: .section)
                item.drop = num.uncertain || letterSpaced(s)
                item.noInfer = foreignSection
                item.extra = !plural && !items.isEmpty
                // "§§ 40a Abs. 1, 2a und 3, § 40b": after a qualifier, a lower number
                // is a further value of it, not the next section.
                if plural, q.end > num.end { item.end = lowerValues(after: item.end, than: num.key); j = item.end }
                items.append(item)
                if !plural || q.end == num.end { j = end }
                guard var sep = keyword(skipWS(j), Words.itemSeparators) else { break }
                // "§§ 37a, 37b und des 40a"
                if let a = keyword(skipWS(sep), Words.articles), skipWS(a) > a { sep = a }
                guard sectionNumber(skipWS(sep), spaced: false) != nil, !enumerator(skipWS(sep)) else { break }
                j = sep
            }
            return items.isEmpty ? nil : Group(items: items, law: nil, end: j)
        }

        /// "…, 2. die für …": the number of a list item, not a value.
        func enumerator(_ i: Int) -> Bool {
            guard let d = digits(i), c(d) == 0x2E else { return false }
            let w = skipWS(d + 1)
            return w > d + 1 && isLetter(c(w)) && !isUpper(c(w))
        }

        /// "§ 2 5 b A b s . 3 U S t G" (letter-spaced heading in PDF text): a
        /// one-character number followed by three one-character words.
        func letterSpaced(_ i: Int) -> Bool {
            guard isWordChar(c(i)), !isWordChar(c(i + 1)) else { return false }
            var p = i + 1
            for _ in 0..<3 {
                let q = skipWS(p)
                guard q > p, isWordChar(c(q)), !isWordChar(c(q + 1)) else { return false }
                p = q + 1
            }
            return true
        }

        /// Values after `i` (", 2a und 3") whose number is lower than `key`.
        func lowerValues(after i: Int, than key: String) -> Int {
            func order(_ k: String) -> (Int, String) {
                let digits = k.prefix { $0.isNumber }
                return (Int(digits) ?? 0, String(k.dropFirst(digits.count)))
            }
            var end = i
            while let sep = keyword(skipWS(end), Words.itemSeparators), let v = sectionNumber(skipWS(sep), spaced: false),
                  !enumerator(skipWS(sep)), order(v.key) < order(key) || order(v.key) == order(key) {
                end = v.end
            }
            return end
        }

        /// `Art. 3 Abs. 1`; the law must follow.
        func articleGroup(at i: Int, after k: Int) -> Group? {
            let s = skipWS(k)
            guard let num = sectionNumber(s, spaced: false) else { return nil }
            let q = qualifiers(from: num.end, lists: true, first: true)
            let end = ff(q.end)
            var g = Group(items: [Item(start: i, end: end, key: num.key, paragraph: q.paragraph, kind: .article)], law: nil, end: end)
            // "Artikel 97 § 1 EGAO": the section belongs to the article, not to a law.
            if c(skipWS(end)) == 0xA7, let inner = sectionGroup(at: skipWS(end)) {
                g.items[0].end = inner.end
                g.items[0].drop = true
                g.end = inner.end
                g.nested = true
            }
            return g
        }

        /// `R 9.1 Abs. 2`, `Abschnitt 1.1`, `A 1.1`; an administrative law must follow.
        func adminPrefixGroup(at i: Int) -> Group? {
            guard let k = keyword(i, Words.adminPrefix) else { return nil }
            let s = skipWS(k)
            guard s > k || c(k - 1) == 0x2E, let num = adminNumber(s, dots: 2) else { return nil }
            // A court file number, not a guideline: "BFH, V R 38/00", "VIII R 17/97".
            if c(num.end) == 0x2F { return nil }
            // "StRK FGO § 69 R 171": a card number after a number.
            if let s = wordStart(before: i), Words.romans.contains(Array(u[s..<wordEnd(s)])) || keyword(s, Words.senates) != nil || digits(s) != nil { return nil }
            let q = qualifiers(from: num.end, lists: true, first: false)
            let end = ff(q.end)
            return Group(items: [Item(start: i, end: end, key: num.key, paragraph: q.paragraph, kind: .admin)], law: nil, end: end)
        }

        /// Law written first: `EStG § 35a`, `LStR R 9.1`, `EStR 4.2`,
        /// `AEAO zu § 122`, `AEAO Nr. 2 zu § 122 AO`. `start`: where the
        /// visible citation starts (before the law for `Nr. 2 AEAO zu …`).
        func lawFirst(at i: Int, start: Int? = nil, requireZu: Bool = false) -> Group? {
            guard let hit = law(at: i, allowUnknown: false) else { return nil }
            // A name after "zum"/"zur"/"des" … is part of another title
            // ("Einführungsgesetz zum Handelsgesetzbuch Art. 3").
            if hit.name, let w = wordBefore(i), Words.beforeTitle.contains(w) { return nil }
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
        ///
        /// A law after a bracket belongs to the citations before it, without
        /// widening the range: "§ 1 Absatz 2 (… i.V.m. § 1 Absatz 1 Satz 2) des
        /// Außensteuergesetzes" is AStG twice. A specific old version ("EStG
        /// 1987", "a.F.", "in der am 31. Dezember 2008 geltenden Fassung") is
        /// not the text the reader shows: the chain gets no link.
        func trailingLaw(_ group: Group?) -> Group? {
            guard var g = group else { return nil }
            let j = skipWS(g.end)
            if let hit = thisLaw(j) ?? articleLaw(j) ?? law(at: j, allowUnknown: true).map({ ($0.hit, $0.end) }) {
                g.law = hit.0
                g.end = hit.1
                g.items[g.items.count - 1].end = hit.1
                if year(skipWS(hit.1)) != nil { g.law = .unknown }
            } else if c(j) == 0x2C, let hit = articleLaw(skipWS(j + 1)) {
                // "… in Verbindung mit § 5 Absatz 1, des Einkommensteuergesetzes"
                g.law = hit.0
            } else if c(j) == 0x29, let hit = articleLaw(skipWS(j + 1)) {
                // "… mit § 1 Absatz 1 Satz 2) des Außensteuergesetzes"
                g.law = hit.0
            } else if c(j) == 0x28, let close = closingBracket(j), let hit = articleLaw(skipWS(close + 1)) {
                // "§ 1 Absatz 2 (gegebenenfalls …) des Außensteuergesetzes"
                g.law = hit.0
            }
            if oldVersion(skipWS(g.end)) { g.law = .unknown }
            // "§ 14 Abs. 3 Satz 1 5. VermBG": a numbered law name.
            if g.law == nil, let d = digits(skipWS(g.end)), d - skipWS(g.end) <= 2, c(d) == 0x2E, skipWS(d + 1) > d + 1, isUpper(c(skipWS(d + 1))) {
                g.law = .unknown
            }
            // "§ 138 Abs. Nr. 2 HGB": a qualifier without its value, unclear.
            if g.law == nil, Words.qualifiers.contains(where: { keyword(skipWS(g.end), $0.words) != nil }) { g.law = .unknown }
            return g
        }

        /// "dieses Gesetzes": the own law in a law's text, else an unknown
        /// document ("dieses Vertragsmusters").
        func thisLaw(_ j: Int) -> (LawHit, Int)? {
            guard let k = keyword(j, Words.this), skipWS(k) > k, isUpper(c(skipWS(k))) else { return nil }
            let w = skipWS(k)
            if let own = ownLaw, keyword(w, Words.ownDesignators) != nil { return (.known(own), wordEnd(w)) }
            return (.unknown, wordEnd(w))
        }

        /// "des EStG", "der Abgabenordnung", "des Gesellschaftsvertrags" (unknown).
        func articleLaw(_ j: Int) -> (LawHit, Int)? {
            guard let k = keyword(j, Words.article2), skipWS(k) > k, isLetter(c(skipWS(k))) else { return nil }
            let w = skipWS(k)
            if let hit = law(at: w, allowUnknown: true) {
                return (year(skipWS(hit.end)) != nil ? .unknown : hit.hit, hit.end)
            }
            return (.unknown, wordEnd(w))
        }

        /// The ")" closing the bracket at `i`, within 200 units and not nested.
        func closingBracket(_ i: Int) -> Int? {
            var j = i + 1
            while j < n, j - i < 200 {
                if c(j) == 0x29 { return j }
                if c(j) == 0x28 || c(j) == 0xA { return nil }
                j += 1
            }
            return nil
        }

        /// A year right after a law: "EStG 1987", "Einkommensteuergesetzes 2002".
        func year(_ i: Int) -> Int? {
            guard let d = digits(i), d - i == 4, !isWordChar(c(d)), c(d) != 0x2E || !isWordChar(c(d + 1)) else { return nil }
            let value = Int(key(i, d)) ?? 0
            return (1900...2199).contains(value) ? value : nil
        }

        /// "a.F.", "a. F.", "aF", or "in der … Fassung" (not "in der jeweils
        /// geltenden Fassung") at `i`.
        func oldVersion(_ i: Int) -> Bool {
            if dottedAbbreviation(i, ["aA", "fF"]) != nil { return true }
            guard let k = keyword(i, Words.inVerbindung), skipWS(k) > k, let d = keyword(skipWS(k), Words.der) else { return false }
            var j = d
            for _ in 0..<10 {
                let w = skipWS(j)
                guard w > j, w < n else { return false }
                if keyword(w, Words.fassung) != nil { return true }
                if keyword(w, Words.currentVersion) != nil { return false }
                let e = wordEnd(w)
                guard e > w else { return false }
                j = c(e) == 0x2E ? e + 1 : e // "31. Dezember"
            }
            return false
        }

        // MARK: Laws

        /// The law abbreviation starting at `i` (whole word, "EStG-E" is none).
        /// `allowUnknown`: any other capitalised word counts as a written but
        /// unknown law ("XYZG", "SolZG", "Handelsgesetzbuch").
        /// `name`: written as a catalog name, not an abbreviation.
        /// `bracket`: a "(EStG)" after the law is read as part of it. The law
        /// inside that bracket takes none of its own, so the lookahead never
        /// nests: "AO (AO (AO (…" costs the same at every start and needs no
        /// stack, however long the text is.
        func law(at i: Int, allowUnknown: Bool, bracket: Bool = true) -> (hit: LawHit, end: Int, name: Bool)? {
            guard i < n, isLetter(c(i)), !isWordChar(c(i - 1)) else { return nil }
            // "Muster-AO", "Muster-Abgabenordnung": the law is only part of a word.
            if c(i - 1) == 0x2D, isWordChar(c(i - 2)) {
                return allowUnknown ? (.unknown, wordEnd(i), false) : nil
            }
            var best = 0, ids = Set<String>(), name = false
            for alias in scanner.aliases[LawCitationScanner.lower(c(i))] ?? [] {
                guard let end = match(alias, at: i), !isWordChar(c(end)), !(c(end) == 0x2D && isLetter(c(end + 1))) else { continue }
                if end > best { best = end; ids = [alias.id]; name = alias.name } else if end == best { ids.insert(alias.id); name = name || alias.name }
            }
            if best > 0 {
                var hit: LawHit = ids.count == 1 ? .known(ids.first!) : .ambiguous
                // "Einkommensteuergesetz (EStG)": the bracket must name the same law.
                let p = skipWS(best)
                if bracket, c(p) == 0x28, let inner = law(at: p + 1, allowUnknown: false, bracket: false), c(inner.end) == 0x29 {
                    if inner.hit != hit { hit = .ambiguous }
                    best = inner.end + 1
                }
                return (hit, best, name)
            }
            guard allowUnknown, isUpper(c(i)), !Words.notLaws.contains(where: { keyword(i, $0) != nil }) else { return nil }
            return (.unknown, wordEnd(i), false)
        }

        /// The word ending right before `i` (after white space), if any.
        func wordBefore(_ i: Int) -> [UInt16]? {
            wordStart(before: i).map { Array(u[$0..<wordEnd($0)]) }
        }

        /// Start of the word before `i` (separated by white space).
        func wordStart(before i: Int) -> Int? {
            var e = i
            while e > 0, isWS(c(e - 1)) { e -= 1 }
            guard e < i else { return nil }
            var s = e
            while s > 0, isWordChar(c(s - 1)) { s -= 1 }
            return s < e ? s : nil
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
            // "§§ 17ff.": the following sections, not a key "17ff".
            if j - d == 2, c(d) == 0x66, c(d + 1) == 0x66, !isWordChar(c(j)) { return (key(i, d), d, false) }
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
                // "Nummer 1 bis 3 und Satz 2 des …": a further qualifier of the same
                // citation ("und Absatz 3" is the next citation of the chain).
                var at = j
                if end > i, let sep = keyword(j, comma ? Words.itemSeparators : Words.itemSeparatorsNoComma),
                   Words.qualifiers.contains(where: { $0.words != Words.absatz && keyword(skipWS(sep), $0.words) != nil }) || ordinalPart(skipWS(sep)) != nil {
                    at = skipWS(sep)
                }
                // "Satz 1 zweiter Halbsatz", "Satz 6, 1. Alternative".
                if at == j || end > i, let p = ordinalPart(at) { end = p; continue }
                for q in Words.qualifiers {
                    guard let k = keyword(at, q.words) else { continue }
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
                guard let next = romanEnd ?? (letters ? letterValue(v)?.end : sectionNumber(v, spaced: false)?.end), !enumerator(v) else { break }
                // "Satz 6, 1. Alternative": the "1." belongs to the Alternative.
                if c(next) == 0x2E, keyword(skipWS(next + 1), Words.ordinalParts) != nil { break }
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
            if let k = keyword(skipWS(i), Words.following) { return k }
            // Glued to the number: "§§ 17ff."
            if c(i) == 0x66, c(i + 1) == 0x66, !isWordChar(c(i + 2)) { return c(i + 2) == 0x2E ? i + 3 : i + 2 }
            return i
        }

        /// Between two citations of one chain: i.V.m., und, oder, sowie, bzw., bis,
        /// Komma … (up to four pieces, as in ", sowie" or ", auch in Verbindung
        /// mit"; fillers like "auch" only together with a real connector).
        func connector(_ i: Int) -> (end: Int, ivm: Bool)? {
            var j = i, end: Int? = nil, real = false, ivm = false
            for _ in 0..<4 {
                if let k = oneConnector(j) {
                    real = true; end = k
                    if keyword(j, Words.connectors) == nil { ivm = true }
                } else if let k = keyword(j, Words.fillers) { end = k } else if let k = provisionsFiller(j) { end = k }
                // "… Nummer 1b oder 1c (geringfügig Beschäftigte) oder nach § 172": an explanation.
                else if c(j) == 0x28, let close = closingBracket(j), !u[j..<close].contains(0xA7) { end = close + 1 } else { break }
                j = skipWS(end!)
            }
            guard real, let end else { return nil }
            return (end, ivm)
        }

        /// "die Bußgeldvorschriften der" between two citations of one chain.
        func provisionsFiller(_ i: Int) -> Int? {
            guard let a = keyword(i, Words.articles + Words.w(["die"])), skipWS(a) > a else { return nil }
            let w = skipWS(a), e = wordEnd(w)
            guard e > w, String(decoding: u[w..<e], as: UTF16.self).lowercased().hasSuffix("vorschriften"),
                  skipWS(e) > e, let b = keyword(skipWS(e), Words.articles) else { return nil }
            return b
        }

        /// "(Mustersatzung, § 5)" before the "§" at `i`: an unknown capitalised
        /// word in a bracket, then a comma.
        func documentBefore(_ i: Int) -> Bool {
            var e = i
            while e > 0, isWS(c(e - 1)) { e -= 1 }
            guard c(e - 1) == 0x2C else { return false }
            e -= 1
            while e > 0, isWS(c(e - 1)) { e -= 1 }
            var s = e
            while s > 0, isWordChar(c(s - 1)) || c(s - 1) == 0x2D && isWordChar(c(s - 2)) { s -= 1 }
            guard s < e, isUpper(c(s)), c(s - 1) == 0x28, law(at: s, allowUnknown: false) == nil else { return false }
            return !Words.notLaws.contains(where: { keyword(s, $0) != nil })
        }

        /// "zweiter Halbsatz", "1. Alternative" at `i`: its end.
        func ordinalPart(_ i: Int) -> Int? {
            if let o = keyword(i, Words.ordinals), skipWS(o) > o, let p = keyword(skipWS(o), Words.ordinalParts) { return p }
            if let d = digits(i), d - i <= 2, c(d) == 0x2E, skipWS(d + 1) > d + 1, let p = keyword(skipWS(d + 1), Words.ordinalParts) { return p }
            return nil
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
        /// Hyphen, non-breaking hyphen, minus, en and em dash.
        static let dashes = ["-", "\u{2010}", "\u{2011}", "\u{2212}", "\u{2013}", "\u{2014}"]
        static let ranges = w(["bis"] + dashes)
        static let itemSeparators = w([",", "und/oder", "und", "u.", "oder", "sowie", "bzw.", "bzw", "bis"] + dashes)
        static let itemSeparatorsNoComma = w(["und/oder", "und", "u.", "oder", "bzw.", "bzw", "bis"] + dashes)
        static let connectors = w([",", ";", "/", "und/oder", "und", "u.", "oder", "sowie", "bzw.", "bzw", "bis"])
        static let inVerbindung = w(["in"])
        static let verbindung = w(["Verbindung"])
        static let mit = w(["mit"])
        static let der = w(["der"])
        static let fillers = w(["auch", "jeweils", "gegebenenfalls", "ggf.", "mit", "nach", "gemäß", "gem.", "laut", "lt."] + ["des", "der", "den", "dem"])
        static let articles = w(["des", "der", "den", "dem"])
        static let zuVor = Set(w(["zu", "Zu", "vor", "Vor"]))
        static let senates = w(["GrS"])
        /// "… geltenden Vorschriften des …", "der Siebente Teil der Abgabenordnung".
        static let provisions: Set<String> = ["Vorschriften", "Vorschrift", "Bestimmungen", "Bestimmung", "Regelungen", "Regelung",
                                              "Teil", "Teils", "Teile", "Abschnitt", "Abschnitts", "Abschnitte", "Unterabschnitt", "Kapitel", "Kapitels"]
        static let provisionInitials = Set("VBRTAUK".utf16)
        static let provisionSuffixes = w(["vorschriften", "vorschrift", "bestimmungen"])
        static let this = w(["dieses", "dieser", "diesem"])
        static let ownDesignators = w(["Gesetzes", "Gesetz", "Gesetzbuchs", "Gesetzbuches", "Gesetzbuch", "Buches", "Buchs", "Buch", "Verordnung", "Ordnung"])
        static let fassung = w(["Fassung"])
        static let currentVersion = w(["jeweils", "jeweiligen", "jeweilig", "aktuellen", "derzeit", "heute"])
        /// "Satz 1 zweiter Halbsatz", "Nummer 2 erste Alternative".
        static let ordinals = w(["erster", "zweiter", "dritter", "vierter", "letzter", "erste", "zweite", "dritte", "vierte", "letzte"])
        static let ordinalParts = w(["Halbsatz", "Halbs.", "Teilsatz", "Alternative", "Alt.", "Variante", "Var."])
        /// Words before a law name that make it part of another title.
        static let beforeTitle = Set(w(["zum", "zur", "zu", "des", "der", "dem", "den", "eines", "einer", "betreffend", "über", "für", "vom", "von"]))
        static let romans = w(["I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X",
                               "XI", "XII", "XIII", "XIV", "XV", "XVI", "XVII", "XVIII", "XIX", "XX"])
    }
}
