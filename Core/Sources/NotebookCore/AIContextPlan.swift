import Foundation

// What of the open notebook goes with a question, decided without any UI:
// scope, budget, selection by relevance, page images, consent and exclusions.
// Nothing here is part of a notebook, revision or backup.

/// The two choices above the input field. Display state of the panel.
public enum AIContextScope: String, CaseIterable, Identifiable, Sendable {
    case notebook, page
    public var id: String { rawValue }
    public var title: String { self == .notebook ? "Ganzes Heft" : "Diese Seite" }
}

/// How thoroughly the model works. Only `effort` goes out, never a model:
/// the account's default model applies.
public enum AIAnswerMode: String, CaseIterable, Identifiable, Sendable {
    case fast, balanced, thinking
    public var id: String { rawValue }
    public var effort: String {
        switch self { case .fast: "low"; case .balanced: "medium"; case .thinking: "high" }
    }
    public var title: String {
        switch self { case .fast: "Schnell"; case .balanced: "Ausgewogen"; case .thinking: "Nachdenken" }
    }
    public var detail: String {
        switch self {
        case .fast: "Antwortet sofort"
        case .balanced: "Etwas gründlicher, kaum langsamer"
        case .thinking: "Denkt gründlicher nach, dauert länger"
        }
    }
    /// The run shows „Denkt nach …“ until the first words arrive.
    public var showsThinking: Bool { self == .thinking }
    /// Unknown or missing stored values fall back to the default.
    public init(stored: String?) { self = stored.flatMap(Self.init(rawValue:)) ?? .fast }
}

/// One consent for one server under one account: from then on the open
/// notebook goes along without asking per notebook.
public enum AIConsent {
    private static let version = "c1"

    /// nil without account: nobody can have agreed.
    public static func key(server: URL, account: String) -> String? {
        guard !account.isEmpty, let encoded = account.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        return [version, AIServerAddress.authority(of: server), encoded].joined(separator: "|")
    }

    /// Anything else stored (older per-notebook approvals) counts for nothing.
    public static func valid(_ stored: [String]) -> Set<String> {
        Set(stored.filter { $0.hasPrefix(version + "|") && $0.split(separator: "|", omittingEmptySubsequences: false).count == 3 })
    }
}

/// Notebooks the assistant must not read, by document ID, on this iPad only.
public struct AIDocumentExclusions: Equatable, Sendable {
    public private(set) var ids: Set<UUID>
    public init(stored: [String] = []) { ids = Set(stored.compactMap(UUID.init(uuidString:))) }
    public var stored: [String] { ids.map(\.uuidString).sorted() }
    public var count: Int { ids.count }
    public func contains(_ id: UUID) -> Bool { ids.contains(id) }
    public mutating func set(_ id: UUID, excluded: Bool) {
        if excluded { ids.insert(id) } else { ids.remove(id) }
    }
}

/// How much notebook text a question may take.
public enum AIContextSize {
    /// Up to here the whole notebook goes along; above it a selection.
    public static let compact = 40_000

    /// Questions about the notebook as a whole get the server's full limit.
    public static func wantsWholeNotebook(_ question: String) -> Bool {
        let text = AITextRanking.folded(question)
        if text.contains("zusammenfass") || text.contains("uberblick") || text.contains("summar") { return true }
        if text.contains("fass"), text.contains("zusammen") { return true }
        return ["ganze heft", "ganzen heft", "gesamte heft", "gesamten heft", "alle seiten", "ganzes heft"].contains { text.contains($0) }
    }

    public static func budget(for question: String, limit: Int, wholeNotebook: Bool = false) -> Int {
        wholeNotebook || wantsWholeNotebook(question) ? limit : min(limit, compact)
    }
}

/// Everything a context is planned from, taken at the moment of sending.
public struct AIContextRequest: Equatable, Sendable {
    public var scope: AIContextScope
    /// Number of the open page.
    public var current: Int
    public var question: String
    /// The user's question before this one: a follow-up often only says „und das?“.
    public var previousQuestion: String?
    /// A suggestion about the whole notebook asked for the large budget.
    public var wholeNotebook: Bool
    public var limit: Int
    public var maxImages: Int

    public init(scope: AIContextScope, current: Int, question: String, previousQuestion: String? = nil, wholeNotebook: Bool = false,
                limit: Int = AILimits.contract.maxContextChars, maxImages: Int = AILimits.contract.maxImages) {
        self.scope = scope; self.current = current; self.question = question; self.previousQuestion = previousQuestion
        self.wholeNotebook = wholeNotebook; self.limit = limit; self.maxImages = maxImages
    }

    public var budget: Int {
        scope == .page ? limit : AIContextSize.budget(for: question, limit: limit, wholeNotebook: wholeNotebook)
    }
}

/// Text plus page images of one question.
public struct AIContextPlan: Equatable, Sendable {
    /// Images per question, whatever the server allows beyond.
    public static let maxImages = 4

    public var context: AIContext
    /// Open page first, then by distance to it.
    public var imagePages: [Int]
    public var imagePageIDs: [Int: UUID]

    /// Every page an answer may cite, by stable ID.
    public var citablePages: [Int: UUID] { context.citablePageIDs.merging(imagePageIDs) { first, _ in first } }

    /// `pages`: the whole notebook, or only the open page for `.page`.
    public static func make(_ pages: [AIContextPage], request: AIContextRequest) -> AIContextPlan {
        let images = imagePages(pages, scope: request.scope, current: request.current, maxImages: request.maxImages)
        let budget = request.budget
        let query = [request.question, request.previousQuestion ?? ""].filter { !$0.isEmpty }
        let context = AIContextBuilder.build(pages, limit: request.limit, budget: budget, focus: request.current, query: query,
                                             fill: budget > AIContextSize.compact, imagePages: images)
        var ids: [Int: UUID] = [:]
        for page in pages where images.contains(page.number) { ids[page.number] = page.pageID }
        return AIContextPlan(context: context, imagePages: images, imagePageIDs: ids)
    }

    /// One page: always its complete picture as soon as anything is on it.
    /// Whole notebook: only pages whose text is missing or unusable, the open
    /// page first, at most `maxImages` (and never more than 4).
    public static func imagePages(_ pages: [AIContextPage], scope: AIContextScope, current: Int, maxImages: Int) -> [Int] {
        let room = max(0, min(Self.maxImages, maxImages))
        switch scope {
        case .page:
            guard room > 0, let page = pages.first(where: { $0.number == current }), page.hasContent else { return [] }
            return [current]
        case .notebook:
            let wanted = pages.filter(\.wantsImage).map(\.number)
            return Array(wanted.sorted { a, b in
                let da = abs(a - current), db = abs(b - current)
                return da != db ? da < db : a > b
            }.prefix(room))
        }
    }
}

/// Short description of a plan for the chip above the input field.
public enum AIContextSummary {
    public static func detail(scope: AIContextScope, plan: AIContextPlan, hasQuestion: Bool) -> String {
        let context = plan.context
        var parts: [String] = []
        switch scope {
        case .page:
            switch (context.hasPageText, !plan.imagePages.isEmpty) {
            case (true, true): parts.append("Text und Bild")
            case (false, true): parts.append("als Bild")
            case (true, false): parts.append("nur Text")
            case (false, false): parts.append("leere Seite")
            }
            if context.truncatedPage != nil { parts.append("gekürzt") }
        case .notebook:
            if context.selected {
                let pages = "\(context.includedPages.count) von \(context.textPageCount) Seiten"
                parts.append(hasQuestion ? pages + " passend zur Frage" : pages)
            } else if context.hasPageText {
                parts.append(context.includedPages.count == 1 ? "1 Seite" : "\(context.includedPages.count) Seiten")
                if context.wasTruncated { parts.append("gekürzt") }
            } else if plan.imagePages.isEmpty {
                parts.append("noch kein Text")
            }
            if !plan.imagePages.isEmpty {
                let pages = plan.imagePages.sorted()
                parts.append("\(pages.count == 1 ? "Seite" : "Seiten") \(AIContextBuilder.pageList(pages)) als Bild")
            }
        }
        return parts.joined(separator: " · ")
    }

    /// Name of the context for the server, e.g. `Mathe, ganzes Heft (14 von 48 Seiten passend zur Frage)`.
    public static func label(title: String, scope: AIContextScope, plan: AIContextPlan) -> String {
        let place: String
        switch scope {
        case .page: place = "Seite \(plan.context.includedPages.first ?? plan.imagePages.first ?? 0)"
        case .notebook:
            place = plan.context.selected
                ? "ganzes Heft (\(plan.context.includedPages.count) von \(plan.context.textPageCount) Seiten passend zur Frage)"
                : "ganzes Heft"
        }
        return AIContextBuilder.label(title: title, place: place)
    }
}

/// The empty panel's suggestions; each one sends at once unless it needs completing.
public struct AIPromptSuggestion: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let prompt: String
    /// False: the prompt goes into the input field for completing.
    public let sendsDirectly: Bool
    /// The scope this suggestion is about, whatever is chosen (nil: as chosen).
    public let scope: AIContextScope?
    /// Large budget: the question is about the notebook as a whole.
    public let wholeNotebook: Bool

    public static let all: [AIPromptSuggestion] = [
        AIPromptSuggestion(id: "explain", title: "Erkläre diese Seite", prompt: "Erkläre mir diese Seite verständlich und Schritt für Schritt.",
                           sendsDirectly: true, scope: .page, wholeNotebook: false),
        AIPromptSuggestion(id: "summary", title: "Fasse das Heft zusammen", prompt: "Fasse das ganze Heft übersichtlich zusammen.",
                           sendsDirectly: true, scope: .notebook, wholeNotebook: true),
        AIPromptSuggestion(id: "quiz", title: "Stell mir Prüfungsfragen",
                           prompt: "Stell mir drei Prüfungsfragen zu diesem Stoff, eine nach der anderen, und warte jeweils auf meine Antwort.",
                           sendsDirectly: true, scope: nil, wholeNotebook: false),
        AIPromptSuggestion(id: "solve", title: "Löse Aufgabe …", prompt: "Löse Aufgabe ",
                           sendsDirectly: false, scope: nil, wholeNotebook: false),
    ]
}

/// Background reading of pages the search index does not know yet.
public struct AIReadingProgress: Equatable, Sendable {
    public var done: Int
    public var total: Int
    public init(done: Int, total: Int) { self.done = done; self.total = total }
    /// `Heft wird gelesen … 2/3`: the page being read now.
    public var label: String { "Heft wird gelesen … \(min(done + 1, total))/\(total)" }
}

/// BM25 over page texts: German lower case, umlauts folded, stop words and
/// the most common endings dropped. Local and deterministic.
public enum AITextRanking {
    private static let k1 = 1.2, b = 0.75

    static let stopWords: Set<String> = [
        "der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "einem", "einer", "eines", "und", "oder", "aber",
        "auch", "als", "am", "an", "auf", "aus", "bei", "bis", "da", "dann", "dass", "du", "er", "es", "ich", "ihr", "im",
        "in", "ist", "mit", "nach", "nicht", "noch", "nur", "so", "sie", "sind", "um", "uns", "von", "vor", "wie", "was",
        "wer", "wo", "zu", "zum", "zur", "fur", "uber", "unter", "sich", "sein", "hat", "haben", "wird", "werden", "wurde",
        "kann", "mir", "mich", "dir", "dich", "mein", "dein", "bitte", "diese", "dieser", "dieses", "diesem", "diesen",
        "hier", "dort", "welche", "welcher", "welches", "warum", "wieso", "weshalb", "gib", "zeig", "zeige", "erklare",
        "erklar", "fass", "fasse", "zusammen", "seite", "seiten", "heft", "mal", "etwas", "kurz", "genau", "denn", "doch",
        "the", "and", "or", "of", "to", "is", "are", "for", "on", "with", "what", "how", "why", "this", "that",
    ]
    private static let endings = ["ungen", "ung", "en", "er", "es", "em", "e", "n", "s"]

    /// Lower case without diacritics, `ß` as `ss`.
    public static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
            .lowercased().replacingOccurrences(of: "ß", with: "ss")
            // Spelled-out umlauts meet the folded ones.
            .replacingOccurrences(of: "ae", with: "a").replacingOccurrences(of: "oe", with: "o").replacingOccurrences(of: "ue", with: "u")
    }

    public static func tokens(_ text: String) -> [String] {
        folded(text).split { !($0.isLetter || $0.isNumber) }.compactMap { word in
            let word = String(word)
            guard word.count >= 2, !stopWords.contains(word) else { return nil }
            return stem(word)
        }
    }

    static func stem(_ word: String) -> String {
        guard !word.allSatisfy(\.isNumber) else { return word }
        for ending in endings where word.hasSuffix(ending) && word.count - ending.count >= 4 {
            return String(word.dropLast(ending.count))
        }
        return word
    }

    /// One score per document, 0 where no query word occurs.
    public static func scores(query: String, documents: [String]) -> [Double] {
        let terms = Set(tokens(query))
        guard !terms.isEmpty, !documents.isEmpty else { return documents.map { _ in 0 } }
        let docs = documents.map { text -> [String: Int] in
            var counts: [String: Int] = [:]
            for token in tokens(text) { counts[token, default: 0] += 1 }
            return counts
        }
        let lengths = docs.map { $0.values.reduce(0, +) }
        let filled = lengths.filter { $0 > 0 }
        let average = filled.isEmpty ? 1 : Double(filled.reduce(0, +)) / Double(filled.count)
        let count = Double(docs.count)
        var idf: [String: Double] = [:]
        for term in terms {
            let frequency = Double(docs.filter { $0[term] != nil }.count)
            idf[term] = log(1 + (count - frequency + 0.5) / (frequency + 0.5))
        }
        return zip(docs, lengths).map { counts, length in
            terms.reduce(0) { sum, term in
                guard let tf = counts[term].map(Double.init) else { return sum }
                return sum + (idf[term] ?? 0) * tf * (k1 + 1) / (tf + k1 * (1 - b + b * Double(length) / average))
            }
        }
    }
}
