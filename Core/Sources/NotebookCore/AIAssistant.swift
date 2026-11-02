import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// App side of the bridge contract (docs/AI-ASSISTANT.md). Nothing here is part
// of a notebook, revision or backup; the assistant only reads snapshots.

// MARK: Sessions

public enum AISessionStatus: String, Codable, Sendable { case idle, running, error, interrupted }
public enum AIMessageRole: String, Codable, Sendable { case user, assistant, system }

public struct AIMessage: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var role: AIMessageRole
    public var text: String
    public var contextLabel: String?
    public var imageCount: Int?
    public init(id: String, role: AIMessageRole, text: String, contextLabel: String? = nil, imageCount: Int? = nil) {
        self.id = id; self.role = role; self.text = text; self.contextLabel = contextLabel; self.imageCount = imageCount
    }
}

public struct AISessionSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var documentId: String?
    public var title: String?
    public var status: AISessionStatus
    public var revision: Int
    /// Milliseconds since 1970.
    public var updatedAt: Double
    public var updatedDate: Date { Date(timeIntervalSince1970: updatedAt / 1000) }
}

public struct AISession: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var documentId: String?
    public var title: String?
    public var status: AISessionStatus
    public var revision: Int
    public var updatedAt: Double
    public var messages: [AIMessage]
    public var summary: AISessionSummary {
        AISessionSummary(id: id, documentId: documentId, title: title, status: status, revision: revision, updatedAt: updatedAt)
    }
    /// Whether this chat belongs to `document`; UUID spelling may differ in case.
    public func belongs(to document: UUID) -> Bool {
        documentId.flatMap(UUID.init(uuidString:)) == document
    }
    /// A late answer of the same chat must not take back a newer state.
    public func supersedes(_ current: AISession?) -> Bool {
        guard let current, current.id == id else { return true }
        return revision > current.revision
    }
    /// Which request each answer belongs to: a question carries the `requestId`
    /// as its message ID, an answer follows its question.
    public var answerRequests: [String: String] {
        var result: [String: String] = [:]
        var question: String?
        for message in messages {
            switch message.role {
            case .user: question = message.id
            case .assistant: if let question { result[message.id] = question }
            case .system: break
            }
        }
        return result
    }
}

// MARK: Info and usage

public struct AIModelInfo: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var isDefault: Bool
}

public struct AILimits: Codable, Equatable, Sendable {
    public var maxImages: Int
    public var maxImageBytes: Int
    public var maxContextChars: Int
    public var maxQuestionChars: Int
    public var dailyTurns: Int
    public var usedToday: Int
    public init(maxImages: Int, maxImageBytes: Int, maxContextChars: Int, maxQuestionChars: Int, dailyTurns: Int, usedToday: Int) {
        self.maxImages = maxImages; self.maxImageBytes = maxImageBytes; self.maxContextChars = maxContextChars
        self.maxQuestionChars = maxQuestionChars; self.dailyTurns = dailyTurns; self.usedToday = usedToday
    }
    /// The contract's limits, until the server reported its own.
    public static let contract = AILimits(maxImages: 4, maxImageBytes: 4 * 1024 * 1024, maxContextChars: 200_000,
                                          maxQuestionChars: 20_000, dailyTurns: 200, usedToday: 0)
}

public struct AIInfo: Codable, Equatable, Sendable {
    public var account: String?
    public var models: [AIModelInfo]
    public var limits: AILimits
}

/// The contract leaves the unit of `checkedAt` and `resetsAt` open: ISO 8601,
/// seconds or milliseconds since 1970 all arrive as the same date.
public struct AITimestamp: Codable, Equatable, Sendable {
    public var date: Date
    public init(date: Date) { self.date = date }
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let number = try? value.decode(Double.self) {
            date = Date(timeIntervalSince1970: number < 100_000_000_000 ? number : number / 1000)
            return
        }
        let text = try value.decode(String.self)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: text) { date = parsed; return }
        formatter.formatOptions = [.withInternetDateTime]
        guard let parsed = formatter.date(from: text) else {
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "Kein Zeitpunkt")
        }
        date = parsed
    }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode((date.timeIntervalSince1970 * 1000).rounded())
    }
}

public struct AIUsageWindow: Codable, Equatable, Sendable {
    public var usedPercent: Double
    public var windowDurationMins: Double?
    public var resetsAt: AITimestamp?
}

public struct AIUsageLimit: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String?
    public var windows: [AIUsageWindow]
}

public struct AIUsage: Codable, Equatable, Sendable {
    public var checkedAt: AITimestamp?
    public var limits: [AIUsageLimit]
}

// MARK: Turn request

public struct AITurnContext: Codable, Equatable, Sendable {
    public var label: String
    public var text: String
    public init(label: String, text: String) { self.label = label; self.text = text }
}

public struct AITurnImage: Codable, Equatable, Sendable {
    public var mimeType: String
    public var base64: String
    public var label: String
    public init(mimeType: String, base64: String, label: String) { self.mimeType = mimeType; self.base64 = base64; self.label = label }
    /// Size of the decoded image, without decoding it.
    public var byteCount: Int {
        base64.utf8.count / 4 * 3 - base64.utf8.suffix(2).filter { $0 == UInt8(ascii: "=") }.count
    }
}

public struct AITurnRequest: Codable, Equatable, Sendable {
    public var requestId: String
    public var text: String
    public var context: AITurnContext?
    public var images: [AITurnImage]?
    public var model: String?
    public var effort: String?
    /// Sending the same `requestId` again never starts a second run.
    public init(requestId: String = UUID().uuidString, text: String, context: AITurnContext? = nil, images: [AITurnImage]? = nil,
                model: String? = nil, effort: String? = nil) {
        self.requestId = requestId; self.text = text; self.context = context; self.images = images; self.model = model; self.effort = effort
    }
    /// Digest of everything that goes out except the `requestId`; the content
    /// itself is never kept for a repeat. Heavy with images: not for the main actor.
    public var contentFingerprint: String {
        var fields: [String?] = [text, context?.label, context?.text, model, effort]
        for image in images ?? [] { fields += [image.mimeType, image.label, image.base64] }
        var digest = SHA256Stream()
        for field in fields {
            // Length first: moving text between two fields changes the digest.
            digest.update(Data((field.map { "\($0.utf8.count):" } ?? "-:").utf8))
            digest.update(Data((field ?? "").utf8))
        }
        return digest.finalizeHex()
    }
    public static func isValidRequestID(_ id: String) -> Bool {
        (8...80).contains(id.utf8.count) && id.utf8.allSatisfy { AIServerAddress.isASCIIAlphanumeric($0) || $0 == UInt8(ascii: "-") }
    }
    /// What keeps this request from being sent, as a message for the user.
    /// Lengths in UTF-16 units: that is how the server counts them.
    public func violation(of limits: AILimits) -> String? {
        guard Self.isValidRequestID(requestId) else { return "Die Anfrage konnte nicht gekennzeichnet werden." }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Bitte eine Frage eingeben." }
        if text.utf16.count > limits.maxQuestionChars { return "Die Frage ist zu lang (höchstens \(limits.maxQuestionChars) Zeichen)." }
        if let context, context.text.utf16.count > limits.maxContextChars { return "Der Kontext ist zu lang (höchstens \(limits.maxContextChars) Zeichen)." }
        let images = images ?? []
        if images.count > limits.maxImages { return "Zu viele Bilder (höchstens \(limits.maxImages))." }
        if images.contains(where: { $0.byteCount > limits.maxImageBytes }) { return "Das Seitenbild ist zu groß." }
        if images.contains(where: { $0.mimeType != "image/jpeg" && $0.mimeType != "image/png" }) { return "Dieses Bildformat wird nicht unterstützt." }
        return nil
    }
}

/// A delivery without clear answer, by digest only: a repeat with the same
/// content keeps its `requestId`, so a lost reply cannot start a second run;
/// anything else is a new question.
public struct AIPendingDelivery: Equatable, Sendable {
    public let fingerprint: String
    public let requestID: String
    public init(fingerprint: String, requestID: String = UUID().uuidString) {
        self.fingerprint = fingerprint; self.requestID = requestID
    }
    public static func resolve(fingerprint: String, previous: AIPendingDelivery?) -> AIPendingDelivery {
        if let previous, previous.fingerprint == fingerprint { return previous }
        return AIPendingDelivery(fingerprint: fingerprint)
    }
}

// MARK: Account

public enum AIAccountStatus: String, Codable, Sendable { case pending, active, blocked }

/// Pure counters of one account and day; a day without use may lack them.
public struct AIUsageCounters: Codable, Equatable, Sendable {
    public var turns = 0, failedTurns = 0, images = 0
    public var inputTokens = 0, cachedInputTokens = 0, outputTokens = 0, reasoningOutputTokens = 0
    public init() {}
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func count(_ key: CodingKeys) throws -> Int { try values.decodeIfPresent(Int.self, forKey: key) ?? 0 }
        turns = try count(.turns); failedTurns = try count(.failedTurns); images = try count(.images)
        inputTokens = try count(.inputTokens); cachedInputTokens = try count(.cachedInputTokens)
        outputTokens = try count(.outputTokens); reasoningOutputTokens = try count(.reasoningOutputTokens)
    }
}

public struct AIMe: Codable, Equatable, Sendable {
    public struct User: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
    }
    public var user: User
    public var status: AIAccountStatus
    public var role: String?
    /// nil: the server's default. 0: no runs allowed.
    public var dailyLimit: Int?
    public var today: AIUsageCounters
}

/// Body of every error: `{ error, code? }`; `code` names `pending` or `blocked` on a 403.
public struct AIErrorReply: Codable, Equatable, Sendable {
    public var error: String?
    public var code: String?
}

public enum AIRequestFailure {
    /// A request given up by the app, not an answer of the server.
    public static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}

/// What the server last said about this account, apart from `/v1/me`.
public enum AIAccessRejection: Equatable, Sendable {
    case unauthorized, pending, blocked
    public init?(status: Int, code: String?) {
        switch (status, code) {
        case (401, _): self = .unauthorized
        case (403, "pending"): self = .pending
        case (403, "blocked"): self = .blocked
        default: return nil
        }
    }
}

/// Whether questions can go out, and if not, why.
public enum AIAccess: Equatable, Sendable {
    case noServer, signedOut, expired, pending, blocked, noRuns
    /// Nothing against it; `/v1/me` may just not have answered yet.
    case open

    public static func resolve(hasServer: Bool, signedIn: Bool, sessionExpired: Bool, me: AIMe?, rejection: AIAccessRejection?) -> AIAccess {
        guard signedIn else { return .signedOut }
        guard hasServer else { return .noServer }
        if sessionExpired || rejection == .unauthorized { return .expired }
        // A rejection is newer than the last `/v1/me`.
        if rejection == .blocked || me?.status == .blocked { return .blocked }
        if rejection == .pending || me?.status == .pending { return .pending }
        return me?.dailyLimit == 0 ? .noRuns : .open
    }

    public var canSend: Bool { self == .open }
    public var reason: String? {
        switch self {
        case .noServer: "Noch keine Server-Adresse eingetragen. Bitte unter Einstellungen › KI (experimentell) ergänzen."
        case .signedOut: "Der KI-Assistent braucht ein noty-Konto. Bitte unter Einstellungen › Konto anmelden."
        case .expired: "Die noty-Anmeldung gilt nicht mehr. Bitte unter Einstellungen › Konto neu anmelden."
        case .pending: "Dieses Konto wartet noch auf die Freischaltung für den KI-Assistenten."
        case .blocked: "Dieses Konto ist für den KI-Assistenten gesperrt."
        case .noRuns: "Für dieses Konto sind derzeit keine Fragen freigegeben."
        case .open: nil
        }
    }
}

/// The server the user entered. The noty session key goes to this address,
/// so nothing but plain `https://host[:port]` is accepted.
public enum AIServerAddress {
    static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }

    /// `host[:port]` of a normalised address.
    public static func authority(of address: URL) -> String {
        (address.host ?? "") + (address.port.map { ":\($0)" } ?? "")
    }

    /// The normalised address, or nil for anything else (path, query,
    /// fragment, user information, other schemes).
    public static func parse(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              components.percentEncodedUser == nil, components.percentEncodedPassword == nil,
              components.percentEncodedQuery == nil, components.percentEncodedFragment == nil,
              components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/",
              let host = components.percentEncodedHost?.lowercased(), isHostName(host) else { return nil }
        if let port = components.port, !(1...65_535).contains(port) { return nil }
        return URL(string: "https://\(host)\(components.port.map { ":\($0)" } ?? "")")
    }

    private static func isHostName(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253 else { return false }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.utf8.allSatisfy { isASCIIAlphanumeric($0) || $0 == UInt8(ascii: "-") }
        }
    }
}

/// Consent to send a notebook's content goes to one server under one account.
/// Entries without this form (older builds: the bare document ID) count for nothing.
public enum AIApproval {
    private static let version = "v2"

    /// nil without account: nobody can have agreed.
    public static func key(server: URL, account: String, document: UUID) -> String? {
        guard !account.isEmpty, let encoded = account.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        return [version, AIServerAddress.authority(of: server), encoded, document.uuidString].joined(separator: "|")
    }

    public static func valid(_ stored: [String]) -> Set<String> {
        Set(stored.filter { $0.hasPrefix(version + "|") })
    }
}

// MARK: Notebook context

/// What is known of one page: typed text plus lines recognised earlier (the
/// search index, or PDF text read just now). `missing`: layers with input on
/// this page but no valid recognition.
public struct AIContextPage: Equatable, Sendable {
    public let number: Int
    public let pageID: UUID
    public var text: [SearchLine]
    public var pdfText: [SearchLine]
    public var imageOCR: [SearchLine]
    public var handwriting: [SearchLine]
    public var missing: Set<SearchLayer>
    public var hasImages: Bool
    /// PDF text left unread because the context was full: counts as omitted.
    public private(set) var skippedAtLimit = false

    public init(number: Int, pageID: UUID, text: [SearchLine] = [], pdfText: [SearchLine] = [], imageOCR: [SearchLine] = [],
                handwriting: [SearchLine] = [], missing: Set<SearchLayer> = [], hasImages: Bool = false) {
        self.number = number; self.pageID = pageID; self.text = text; self.pdfText = pdfText; self.imageOCR = imageOCR
        self.handwriting = handwriting; self.missing = missing; self.hasImages = hasImages
    }

    /// The exact text layer, read without the search index.
    public mutating func fillPDFText(_ value: String) {
        pdfText = value.split(whereSeparator: \.isNewline).map { SearchLine(text: String($0), kind: .pdf, bounds: PageRect(x: 0, y: 0, width: 0, height: 0)) }
        missing.remove(.pdfText)
    }

    public mutating func skipAtLimit() {
        skippedAtLimit = true
        missing.remove(.pdfText)
    }

    /// Size of everything known of this page, without building its text.
    public var knownLength: Int {
        [text, pdfText, imageOCR, handwriting].reduce(0) { sum, lines in lines.reduce(sum) { $0 + $1.text.utf16.count } }
    }

    /// Content the model would not see. A missing OCR run does not matter
    /// on a PDF page whose exact text is there and that has no inserted images.
    public var needsRecognition: Bool {
        if skippedAtLimit { return false }
        if missing.contains(.handwriting) || missing.contains(.pdfText) { return true }
        guard missing.contains(.imageOCR) else { return false }
        return hasImages || !ContentSearchPlanner.hasMeaningfulTextLayer(pdfText)
    }

    /// Same order as the search hits; OCR lines equal to the exact PDF text are
    /// skipped and the 160-character overlap of long text boxes is removed.
    var body: String {
        let exact = Set(pdfText.map(\.text))
        let blocks = AIContextBuilder.typedBlocks(text) + [
            AIContextBuilder.joined(pdfText),
            AIContextBuilder.joined(imageOCR.filter { !exact.contains($0.text) }),
            AIContextBuilder.joined(handwriting),
        ]
        return blocks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

/// Finished context of one question. Everything left out is named here and
/// in a closing note of `text` itself, so neither the user nor the model
/// takes a shortened context for a complete one.
public struct AIContext: Equatable, Sendable {
    public var text: String
    /// Pages asked for.
    public var pageCount: Int
    /// Pages with text in `text`, including `truncatedPage`.
    public var includedPages: [Int]
    /// `includedPages` by stable ID.
    public var includedPageIDs: [Int: UUID] = [:]
    /// Page cut off at the limit.
    public var truncatedPage: Int?
    /// Pages with text that did not fit any more.
    public var omittedPages: [Int]
    /// Pages with handwriting, scans or images nobody recognised yet.
    public var unrecognizedPages: [Int]

    public var isEmpty: Bool { text.isEmpty }
    public var wasTruncated: Bool { truncatedPage != nil || !omittedPages.isEmpty }
    /// For the user: what did not fit (nil: nothing was shortened).
    public var truncationNotice: String? {
        var parts: [String] = []
        if let truncatedPage { parts.append("Seite \(truncatedPage) nur teilweise") }
        if !omittedPages.isEmpty {
            parts.append("\(omittedPages.count == 1 ? "1 Seite fehlt" : "\(omittedPages.count) Seiten fehlen") (\(AIContextBuilder.pageList(omittedPages)))")
        }
        return parts.isEmpty ? nil : "Gekürzt: " + parts.joined(separator: ", ") + "."
    }
}

public enum AIContextBuilder {
    public static let defaultLimit = AILimits.contract.maxContextChars
    /// `ContentSearchPlanner.textLines`: 2 000 characters, 160 overlapping.
    private static let chunkLength = 2_000
    private static let chunkOverlap = 160
    /// Kept free for the closing note.
    private static let noteReserve = 400
    /// Below this a cut page is not worth sending; it counts as missing.
    private static let shortestPart = 200

    /// The pages of a notebook snapshot with every still-valid layer of `index`
    /// (nil: no index yet). With `only`, the cost is that of the one page; the
    /// whole notebook is heavy and not for the main actor. Gives up when its
    /// task is cancelled.
    public static func pages(of notebook: Notebook, index: SearchDocumentIndex?, only pageID: UUID? = nil,
                             drawingIsEmpty: (Data) -> Bool = { $0.isEmpty }) -> [AIContextPage] {
        let offsets: [Int]
        if let pageID {
            guard let offset = notebook.pages.firstIndex(where: { $0.id == pageID }) else { return [] }
            offsets = [offset]
        } else { offsets = Array(notebook.pages.indices) }
        let identities = SearchPDFIdentities(notebook, only: pageID == nil ? nil : offsets.first.map { notebook.pages[$0] })
        let stored = ContentSearchPlanner.storedRecords(index, documentID: notebook.id, only: pageID)
        var result: [AIContextPage] = []
        result.reserveCapacity(offsets.count)
        for offset in offsets {
            if Task.isCancelled { return [] }
            let page = notebook.pages[offset]
            let prepared = ContentSearchPlanner.prepared(page, at: offset, identities)
            let record = ContentSearchPlanner.record(of: prepared, stored: stored)
            var missing = Set(ContentSearchPlanner.pending(prepared, record))
            if missing.contains(.handwriting), drawingIsEmpty(page.drawing) { missing.remove(.handwriting) }
            result.append(AIContextPage(number: offset + 1, pageID: page.id, text: ContentSearchPlanner.textLines(page),
                                        pdfText: record.pdfText?.lines ?? [], imageOCR: record.imageOCR?.lines ?? [],
                                        handwriting: record.handwriting?.lines ?? [], missing: missing, hasImages: !(page.images ?? []).isEmpty))
        }
        return result
    }

    /// `Mathe, Seite 3`; a very long title is shortened to the server's 200 units.
    public static func label(title: String, place: String) -> String {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return place }
        return prefix(name, utf16: 200 - 2 - place.utf16.count) + ", " + place
    }

    /// `limit` in UTF-16 units, as the server counts. Pages are taken in order;
    /// once one no longer fits, it is cut and all after it count as missing
    /// (no skipping ahead to small pages: the gap stays easy to name).
    public static func build(_ pages: [AIContextPage], limit: Int = defaultLimit) -> AIContext {
        let room = max(0, limit - noteReserve)
        var result = AIContext(text: "", pageCount: pages.count, includedPages: [], truncatedPage: nil, omittedPages: [],
                               unrecognizedPages: pages.filter(\.needsRecognition).map(\.number))
        var used = 0, full = false
        for page in pages {
            if page.skippedAtLimit { full = true; result.omittedPages.append(page.number); continue }
            let body = page.body
            guard !body.isEmpty else { continue }
            if full { result.omittedPages.append(page.number); continue }
            let head = (used == 0 ? "" : "\n\n") + "--- Seite \(page.number) ---\n"
            let headSize = head.utf16.count, size = body.utf16.count
            if used + headSize + size <= room {
                result.text += head + body; used += headSize + size
                result.includedPages.append(page.number)
                result.includedPageIDs[page.number] = page.pageID
                continue
            }
            full = true
            let free = room - used - headSize
            guard free >= shortestPart else { result.omittedPages.append(page.number); continue }
            result.text += head + prefix(body, utf16: free); used = result.text.utf16.count
            result.includedPages.append(page.number); result.truncatedPage = page.number
            result.includedPageIDs[page.number] = page.pageID
        }
        if !result.isEmpty, let note = closingNote(result), used + note.utf16.count <= limit { result.text += note }
        return result
    }

    private static func closingNote(_ context: AIContext) -> String? {
        var parts: [String] = []
        if let notice = context.truncationNotice { parts.append(notice) }
        if !context.unrecognizedPages.isEmpty {
            parts.append("Noch nicht erkannt und daher hier nicht enthalten: Handschrift oder Scans auf \(context.unrecognizedPages.count == 1 ? "Seite" : "den Seiten") \(pageList(context.unrecognizedPages)).")
        }
        return parts.isEmpty ? nil : "\n\n[noty: " + parts.joined(separator: " ") + "]"
    }

    /// `3, 5–9, 12`; long lists end in `…`.
    public static func pageList(_ numbers: [Int]) -> String {
        var ranges: [ClosedRange<Int>] = []
        for number in numbers.sorted() {
            if let last = ranges.last, number == last.upperBound + 1 { ranges[ranges.count - 1] = last.lowerBound...number }
            else if ranges.last?.contains(number) != true { ranges.append(number...number) }
        }
        let shown = ranges.prefix(8).map { $0.count == 1 ? "\($0.lowerBound)" : "\($0.lowerBound)–\($0.upperBound)" }
        return shown.joined(separator: ", ") + (ranges.count > shown.count ? " …" : "")
    }

    static func joined(_ lines: [SearchLine]) -> String {
        lines.map { $0.text.trimmingCharacters(in: .newlines) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// One block per text box: chunks of a long box join again without their overlap.
    static func typedBlocks(_ lines: [SearchLine]) -> [String] {
        var blocks: [String] = []
        var previous: SearchLine?
        for line in lines {
            if let previous, line.bounds == previous.bounds, previous.text.count == chunkLength,
               line.text.hasPrefix(String(previous.text.suffix(chunkOverlap))) {
                blocks[blocks.count - 1] += line.text.dropFirst(chunkOverlap)
            } else { blocks.append(line.text) }
            previous = line
        }
        return blocks
    }

    /// Whole characters only: never half an emoji at the cut.
    private static func prefix(_ text: String, utf16 limit: Int) -> String {
        var used = 0
        var end = text.startIndex
        for index in text.indices {
            used += text[index].utf16.count
            if used > limit { break }
            end = text.index(after: index)
        }
        return String(text[..<end])
    }
}

/// When PDFKit need not be asked any more: pages past the limit could not go out.
public struct AIContextBudget: Sendable {
    public let limit: Int
    public private(set) var used = 0
    public init(limit: Int) { self.limit = limit }
    public var exhausted: Bool { used >= limit }
    public mutating func add(_ page: AIContextPage) { used += page.knownLength }
}

/// PDF text read before, by source and page: PDF originals never change under
/// their source ID. Bounded by size; nothing of it is stored.
public struct AIPDFTextCache: Sendable {
    public static let defaultCapacity = 8_000_000
    private let capacity: Int
    private var texts: [String: String] = [:]
    private var used = 0

    public init(capacity: Int = defaultCapacity) { self.capacity = capacity }

    public static func key(page: Page, document: UUID) -> String {
        if let reference = page.pdfReference { return "\(reference.sourceID.uuidString):\(reference.pageIndex)" }
        return "\(document.uuidString):\(page.id.uuidString)"
    }

    public func text(for key: String) -> String? { texts[key] }

    public mutating func remember(_ text: String, for key: String) {
        let size = text.utf16.count
        guard size <= capacity, texts[key] == nil else { return }
        if used + size > capacity { texts = [:]; used = 0 }
        texts[key] = text; used += size
    }
}

// MARK: Citations

public enum AICitationPart: Equatable, Sendable {
    case text(String)
    /// `[S. N]` with `N` inside the notebook.
    case citation(page: Int, label: String)
}

/// `[S. N]`, `[S. 1, 3]` or `[S. 1 und 3]` in an answer. Only numbers in
/// `pages` become citations; everything else stays plain text.
public enum AICitation {
    public static let linkScheme = "noty-ai"

    public static func parts(in text: String, pages: Set<Int>) -> [AICitationPart] {
        var parts: [AICitationPart] = []
        var plain = ""
        var rest = text[...]
        func flush() { if !plain.isEmpty { parts.append(.text(plain)); plain = "" } }
        while let open = rest.range(of: "[S. ") {
            plain += rest[..<open.lowerBound]
            guard let list = numberList(rest[open.upperBound...]), list.numbers.contains(where: { pages.contains($0.page) }) else {
                plain += rest[open]
                rest = rest[open.upperBound...]
                continue
            }
            for (offset, entry) in list.numbers.enumerated() {
                plain += entry.separator
                let label = offset == 0 ? "S. \(entry.digits)" : String(entry.digits)
                if pages.contains(entry.page) {
                    flush()
                    parts.append(.citation(page: entry.page, label: "[\(label)]"))
                } else { plain += label }
            }
            rest = rest[list.end...]
        }
        plain += rest
        flush()
        return parts
    }

    /// Numbers of a citation from just after `[S. ` up to its `]`.
    private static func numberList(_ text: Substring) -> (numbers: [(separator: Substring, digits: Substring, page: Int)], end: Substring.Index)? {
        var numbers: [(separator: Substring, digits: Substring, page: Int)] = []
        var rest = text
        var separator = text[text.startIndex..<text.startIndex]
        while true {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, digits.count <= 6, let page = Int(digits) else { return nil }
            numbers.append((separator, digits, page))
            rest = rest[digits.endIndex...]
            if rest.first == "]" { return (numbers, rest.index(after: rest.startIndex)) }
            guard let next = [", ", ",", " und "].first(where: { rest.hasPrefix($0) }) else { return nil }
            separator = rest.prefix(next.count)
            rest = rest.dropFirst(next.count)
        }
    }

    /// Markdown of one line with every valid citation as a link: inline
    /// formatting around a citation stays intact. Code spans and escaped
    /// characters are left alone: Markdown shows them as they are, so a link
    /// target added there would appear in the text.
    public static func markdown(_ text: String, pages: Set<Int>) -> String {
        var result = ""
        var start = text.startIndex
        func linked(_ part: Substring) -> String {
            parts(in: String(part), pages: pages).map { part in
                switch part {
                case .text(let value): value
                case .citation(let page, let label): "\(label)(\(linkScheme)://page/\(page))"
                }
            }.joined()
        }
        for range in literalRanges(in: text) {
            result += linked(text[start..<range.lowerBound]) + text[range]
            start = range.upperBound
        }
        return result + linked(text[start...])
    }

    /// Backslash escapes and code spans: a span closes with a backtick run of
    /// its own length, an unclosed run is plain text.
    private static func literalRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var index = text.startIndex
        func run(at start: String.Index) -> String.Index { text[start...].prefix { $0 == "`" }.endIndex }
        while index < text.endIndex {
            let next = text.index(after: index)
            if text[index] == "\\", next < text.endIndex {
                let end = text.index(after: next)
                ranges.append(index..<end)
                index = end
            } else if text[index] == "`" {
                let open = run(at: index)
                let length = text.distance(from: index, to: open)
                var probe = open, close: String.Index?
                while probe < text.endIndex, close == nil {
                    guard text[probe] == "`" else { probe = text.index(after: probe); continue }
                    let end = run(at: probe)
                    if text.distance(from: probe, to: end) == length { close = end }
                    probe = end
                }
                if let close { ranges.append(index..<close) }
                index = close ?? open
            } else { index = next }
        }
        return ranges
    }

    /// The page number of a citation link.
    public static func page(from url: URL) -> Int? {
        guard url.scheme == linkScheme, url.host == "page", let page = Int(url.lastPathComponent), page > 0 else { return nil }
        return page
    }
}
