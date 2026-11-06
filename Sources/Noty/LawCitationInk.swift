// Gesetzesverweise in Handschrift (docs/PARAGRAPH-LINKS.md, P3): die Tinte
// einer Seite wird mit derselben Vision-Erkennung wie die Inhaltssuche gelesen
// (`PageTextRecognition`), die erkannten Zeilen nach Verweisen durchsucht.
// Nur bei eingeschalteter Einstellung, erst etwa 2,5 s nach dem letzten Strich,
// nie während ein Strich, Radierer oder Lasso aktiv ist, mit Hilfspriorität
// abseits des Hauptthreads und pro Tintenstand (Hash der Strichdaten) nur
// einmal. Abgeleitete Anzeige: nichts davon kommt ins Heft.
import UIKit
import Vision
import NotebookCore

/// One recognised ink line: text and word boxes in canonical page coordinates.
struct LawCitationInkLine: Sendable, Equatable {
    struct Word: Sendable, Equatable { var range: NSRange; var bounds: PageRect }
    var text: String
    var bounds: PageRect
    var words: [Word]
}

/// A citation found in ink: one rect per recognised line it spans (canonical page coordinates).
struct LawCitationInkMatch: Equatable, Sendable {
    var citation: LawCitation
    var rects: [PageRect]
}

enum LawCitationInk {
    // MARK: Recognition (off the main thread)

    nonisolated static func recognize(_ data: Data, layout: PageLayout) throws -> [LawCitationInkLine] {
        let image = try PageTextRecognition.inkImage(data, layout: layout)
        return try PageTextRecognition.observations(image).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string, ns = text as NSString
            var words: [LawCitationInkLine.Word] = []
            var location = 0
            // Whitespace-separated words, each with Vision's own box.
            while location < ns.length {
                let rest = NSRange(location: location, length: ns.length - location)
                let start = ns.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted, options: [], range: rest)
                guard start.location != NSNotFound else { break }
                let tail = NSRange(location: start.location, length: ns.length - start.location)
                let gap = ns.rangeOfCharacter(from: .whitespacesAndNewlines, options: [], range: tail)
                let end = gap.location == NSNotFound ? ns.length : gap.location
                let word = NSRange(location: start.location, length: end - start.location)
                if let range = Range(word, in: text), let box = try? candidate.boundingBox(for: range) {
                    words.append(.init(range: word, bounds: PageTextRecognition.canonical(PageRect(box.boundingBox), layout)))
                }
                location = end
            }
            return LawCitationInkLine(text: text, bounds: PageTextRecognition.canonical(PageRect(observation.boundingBox), layout), words: words)
        }
    }

    /// Identity of an ink state: hash of the stroke bytes and the page geometry.
    nonisolated static func key(_ data: Data, layout: PageLayout) -> Int {
        var hasher = Hasher()
        hasher.combine(data.count)
        data.withUnsafeBytes { hasher.combine(bytes: $0) }
        for value in [layout.canvas.width, layout.canvas.height, layout.contentOrigin.x, layout.contentOrigin.y] { hasher.combine(value) }
        return hasher.finalize()
    }

    // MARK: Scanning

    /// Citations in the recognised lines, read as one text (a bare „§ 35a“
    /// takes the law written on a line before it, as in typed text).
    nonisolated static func citations(_ lines: [LawCitationInkLine], scanner: LawCitationScanner, defaultLawID: String?) -> [LawCitationInkMatch] {
        guard !lines.isEmpty else { return [] }
        var starts: [Int] = [], offset = 0
        for line in lines { starts.append(offset); offset += (line.text as NSString).length + 1 }
        let joined = normalized(lines.map(\.text).joined(separator: "\n"), scanner: scanner, defaultLawID: defaultLawID)
        return scanner.citations(in: joined, defaultLawID: defaultLawID).compactMap { citation in
            var rects: [PageRect] = []
            for (index, line) in lines.enumerated() {
                let span = NSRange(location: starts[index], length: (line.text as NSString).length)
                let part = NSIntersectionRange(span, citation.range)
                guard part.length > 0 else { continue }
                rects.append(rect(NSRange(location: part.location - span.location, length: part.length), in: line))
            }
            return rects.isEmpty ? nil : LawCitationInkMatch(citation: citation, rects: rects)
        }
    }

    /// Box of `range` in a line: the words it touches (a partly covered word
    /// proportionally), else the proportional slice of the line box.
    nonisolated static func rect(_ range: NSRange, in line: LawCitationInkLine) -> PageRect {
        var result: CGRect?
        for word in line.words {
            let part = NSIntersectionRange(word.range, range)
            guard part.length > 0 else { continue }
            let box = slice(word.bounds, total: word.range.length, from: part.location - word.range.location, length: part.length)
            result = result.map { $0.union(box.cgRect) } ?? box.cgRect
        }
        if let result { return PageRect(result) }
        return slice(line.bounds, total: (line.text as NSString).length, from: range.location, length: range.length)
    }
    nonisolated private static func slice(_ rect: PageRect, total: Int, from: Int, length: Int) -> PageRect {
        guard total > 0, length < total else { return rect }
        let unit = rect.width / Double(total)
        return PageRect(x: rect.x + unit * Double(from), y: rect.y, width: max(unit, unit * Double(length)), height: rect.height)
    }

    /// Vision reads a handwritten „§“ often as „S“ or „$“. Such a letter
    /// becomes „§“ only where the result is exactly „§ <Nummer> <Gesetz>“
    /// with a known law written directly behind the number (no inferred
    /// law, nothing in between), and never after a number or „Abs.“/„Nr.“/
    /// „S.“/„Satz“ (there „S 1“ means Satz 1). Same length: ranges stay valid.
    nonisolated static func normalized(_ text: String, scanner: LawCitationScanner, defaultLawID: String?) -> String {
        let ns = text as NSString
        guard let candidates = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}§$])[S$](?=[ \\t]?\\d)"),
              let shape = try? NSRegularExpression(pattern: "^§[ \\t]?\\d{1,4}[ \\t]?[a-z]?[ \\t]+\\p{L}[\\p{L}\\d]*$"),
              let blocked = try? NSRegularExpression(pattern: "^(\\d+[a-z]?|[IVX]+|Abs\\.?|Absatz|Nr\\.?|S\\.?|Satz|§+)$") else { return text }
        let found = candidates.matches(in: text, range: NSRange(location: 0, length: ns.length)).prefix(20)
        guard !found.isEmpty else { return text }
        var accepted: [NSRange] = []
        for match in found {
            let range = match.range
            // The word before it on the same line must not make it a Satz.
            let line = ns.substring(to: range.location).split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
            if let previous = line.split(whereSeparator: \.isWhitespace).last {
                let word = String(previous)
                if blocked.firstMatch(in: word, range: NSRange(location: 0, length: (word as NSString).length)) != nil { continue }
            }
            let trial = ns.replacingCharacters(in: range, with: "§")
            guard let citation = scanner.citations(in: trial, defaultLawID: defaultLawID).first(where: { $0.range.location == range.location }),
                  !citation.inferredLaw,
                  shape.firstMatch(in: citation.text, range: NSRange(location: 0, length: (citation.text as NSString).length)) != nil else { continue }
            accepted.append(range)
        }
        guard !accepted.isEmpty else { return text }
        let result = NSMutableString(string: text)
        for range in accepted { result.replaceCharacters(in: range, with: "§") }
        return result as String
    }
}

/// Small thread-safe cancel flag for a queued recognition.
final class LawCitationInkCancel: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}

/// One ink recognition at a time for all sheets (Vision is heavy).
actor LawCitationInkQueue {
    static let shared = LawCitationInkQueue()
    func recognize(_ data: Data, layout: PageLayout, cancel: LawCitationInkCancel) -> [LawCitationInkLine]? {
        guard !cancel.isCancelled else { return nil }
        // An unreadable drawing counts as no text (cached: never retried for these bytes).
        return (try? LawCitationInk.recognize(data, layout: layout)) ?? []
    }
}

/// Handwriting citations of one sheet: debounced, idle-only recognition with a
/// shared cache by ink state; results in canonical page coordinates.
@MainActor
final class LawCitationInkReader {
    /// After the last stroke ended.
    static let debounce: TimeInterval = 2.5
    private static let retry: TimeInterval = 1.0
    /// Recognised lines per ink state (`LawCitationInk.key`), newest last.
    private static var cache: [Int: [LawCitationInkLine]] = [:]
    private static var cacheOrder: [Int] = []
    private static let cacheLimit = 24

    /// Results changed (new matches or cleared).
    var onChange: (() -> Void)?
    /// No stroke, erase, lasso or drag is active on the sheet.
    var isIdle: () -> Bool = { true }
    private(set) var matches: [LawCitationInkMatch] = []

    private struct Inputs: Equatable {
        var pageID: UUID
        var drawing: Data
        var layout: PageLayout
        var generation: Int
        var lawID: String?
    }
    private var inputs: Inputs?
    /// Ink state and scan inputs `matches` belong to.
    private var resultKey: (ink: Int, generation: Int, lawID: String?)?
    private var currentInk: Int?
    private var timer: DispatchWorkItem?
    private var job: Task<Void, Never>?
    private var cancelFlag: LawCitationInkCancel?
    private var token = 0
    private var scanner: LawCitationScanner?

    /// Every page configuration: schedules a recognition once the ink rests.
    func update(pageID: UUID, drawing: Data, layout: PageLayout, scanner: LawCitationScanner?, generation: Int, lawID: String?, enabled: Bool) {
        guard enabled, let scanner, !drawing.isEmpty else { clear(); return }
        let next = Inputs(pageID: pageID, drawing: drawing, layout: layout, generation: generation, lawID: lawID)
        guard next != inputs else { return }
        let previous = inputs
        inputs = next; self.scanner = scanner
        if previous?.pageID != pageID || previous?.layout != layout {
            // Another page or geometry: old boxes never stand on it.
            stop(); currentInk = nil; resultKey = nil
            if !matches.isEmpty { matches = []; onChange?() }
        }
        if previous?.drawing != drawing || currentInk == nil {
            currentInk = nil
            schedule(after: previous == nil || previous?.pageID != pageID ? 0.6 : Self.debounce)
        } else {
            // Only scanner or default law changed: scan the known lines again.
            schedule(after: 0)
        }
    }

    /// Page left, links off, sheet detached.
    func clear() {
        stop()
        inputs = nil; currentInk = nil; resultKey = nil; scanner = nil
        if !matches.isEmpty { matches = []; onChange?() }
    }
    /// Pauses work (detached sheet); `update` resumes it.
    func suspend() { stop(); inputs = nil }

    private func stop() {
        timer?.cancel(); timer = nil
        job?.cancel(); job = nil
        cancelFlag?.cancel(); cancelFlag = nil
        token += 1
    }

    private func schedule(after delay: TimeInterval) {
        timer?.cancel()
        job?.cancel(); job = nil; cancelFlag?.cancel(); cancelFlag = nil; token += 1
        let work = DispatchWorkItem { [weak self] in self?.run() }
        timer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func run() {
        timer = nil
        guard let inputs, let scanner else { return }
        guard isIdle() else { schedule(after: Self.retry); return }
        token += 1
        let token = token, cancel = LawCitationInkCancel()
        cancelFlag = cancel
        let data = inputs.drawing, layout = inputs.layout, generation = inputs.generation, lawID = inputs.lawID
        job = Task { [weak self] in
            let ink: Int
            if let known = self?.currentInk { ink = known }
            else { ink = await Task.detached(priority: .utility) { LawCitationInk.key(data, layout: layout) }.value }
            guard let self, self.token == token, !Task.isCancelled else { return }
            self.currentInk = ink
            if let key = self.resultKey, key.ink == ink, key.generation == generation, key.lawID == lawID { return }
            let lines: [LawCitationInkLine]
            if let cached = Self.cache[ink] { lines = cached }
            else {
                guard let read = await Task.detached(priority: .utility, operation: {
                    await LawCitationInkQueue.shared.recognize(data, layout: layout, cancel: cancel)
                }).value, self.token == token, !Task.isCancelled else { return }
                Self.remember(ink, read)
                lines = read
            }
            let found = await Task.detached(priority: .utility) {
                LawCitationInk.citations(lines, scanner: scanner, defaultLawID: lawID)
            }.value
            guard self.token == token, !Task.isCancelled else { return }
            self.job = nil; self.cancelFlag = nil
            self.resultKey = (ink, generation, lawID)
            if found != self.matches { self.matches = found; self.onChange?() }
        }
    }

    private static func remember(_ key: Int, _ lines: [LawCitationInkLine]) {
        if cache.updateValue(lines, forKey: key) == nil { cacheOrder.append(key) }
        else { cacheOrder.removeAll { $0 == key }; cacheOrder.append(key) }
        while cacheOrder.count > cacheLimit { cache[cacheOrder.removeFirst()] = nil }
    }
}
