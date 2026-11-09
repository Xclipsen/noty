// Tippvorschlag für Gesetzesverweise (docs/PARAGRAPH-LINKS.md, P2): wer in
// einem Textfeld „§ 35a“ ohne Gesetz tippt, bekommt über der Tastatur bis zu
// drei Gesetze angeboten. Nur abgeleitete Anzeige; liest ausschließlich
// Gesetzestexte, die schon offline auf dem iPad liegen, und lädt nie etwas.
import Foundation
import Combine
import UIKit
import NotebookCore

/// One chip: the law and the label it shows („EStG – Steuerermäßigung bei …“).
struct LawSuggestion: Equatable {
    var lawID: String
    var abbr: String
    var label: String
}

/// A bare citation right before the caret („§ 35a“, „§ 35a Abs. 2“, „§§ 4, 5“).
struct LawSuggestionTrigger: Equatable {
    /// UTF-16 range of the citation (without trailing white space).
    var range: NSRange
    /// Caret the trigger was found for.
    var caret: Int
    /// Lowercased key of the first section number („35a“).
    var key: String

    /// Cheap pattern, anchored at the caret: a § chain without a law behind
    /// it, at most one space after it. Looked at only within the last 80 units.
    private static let pattern = try! NSRegularExpression(pattern:
        "(?<![\\p{L}\\p{N}])(§§?[\\s\\u00A0]*(\\d{1,4}[\\s\\u00A0]?[a-zA-Z]?)(?![\\p{L}\\p{N}])"
        + "(?:[\\s\\u00A0]*(?:Abs\\.|Absatz|S\\.|Satz|Nr\\.|Buchst\\.|,|und|bis|oder|–|-)[\\s\\u00A0]*[0-9]{1,4}[a-zA-Z]?)*)"
        + "[ \\u00A0]?$")

    /// nil unless the text right before `caret` is a § chain. The caller still
    /// checks with the scanner that no law is written in front of it.
    static func find(in text: NSString, caret: Int) -> LawSuggestionTrigger? {
        guard caret > 0, caret <= text.length else { return nil }
        // After the caret only the end, white space or punctuation (not „§ 35aX“).
        if caret < text.length, let next = Unicode.Scalar(text.character(at: caret)),
           CharacterSet.alphanumerics.contains(next) { return nil }
        let start = max(0, caret - 80)
        let window = NSRange(location: start, length: caret - start)
        // Quick reject before the regex: no § nearby, or the last character is no digit/letter/space.
        guard text.range(of: "§", options: .backwards, range: window).location != NSNotFound,
              let last = Unicode.Scalar(text.character(at: caret - 1)),
              CharacterSet.alphanumerics.contains(last) || last == " " || last == "\u{00A0}" else { return nil }
        let slice = text.substring(with: window)
        guard let match = pattern.firstMatch(in: slice, range: NSRange(location: 0, length: (slice as NSString).length)) else { return nil }
        let chain = match.range(at: 1), number = match.range(at: 2)
        guard chain.location != NSNotFound, number.location != NSNotFound else { return nil }
        let key = (slice as NSString).substring(with: number).filter { !$0.isWhitespace && $0 != "\u{00A0}" }.lowercased()
        // A citation that ends in a connector („§ 4 und“) is still being typed.
        let body = (slice as NSString).substring(with: chain)
        guard !key.isEmpty, body.last.map({ $0.isNumber || $0.isLetter || $0 == "." }) == true else { return nil }
        return LawSuggestionTrigger(range: NSRange(location: start + chain.location, length: chain.length), caret: caret, key: key)
    }
}

/// Catalog, per-law section titles and the ranking of suggestions. One per
/// app (one scene), connected by `NotyApp`.
@MainActor
final class LawSuggestionModel: ObservableObject {
    static let shared = LawSuggestionModel()

    /// Laws of the catalog (laws first, then administrative documents).
    @Published private(set) var entries: [LawEntry] = []
    /// Bumps when a section index arrived, so a waiting suggestion refreshes.
    @Published private(set) var indexGeneration = 0

    private weak var laws: LawLibraryModel?
    private var watching: [AnyCancellable] = []
    /// Section key → title per „law|version“ of offline laws; small (no texts).
    private var titles: [String: [String: String]] = [:]
    /// „law|version“ that could not be indexed (file damaged or too large).
    private var missing: Set<String> = []
    /// Laws whose current version lies on this iPad; nil until checked (once per catalog).
    private var offline: Set<String>?
    private var checkingOffline = false
    private var offlineCheckedAt = Date.distantPast
    /// Laws waiting for their index, the ones asked for first.
    private var queue: [String] = []
    private var indexing: Task<Void, Never>?
    /// New laws queued per suggestion beyond the default and previous law.
    private static let batch = 2
    /// Pause between two laws, so readers and cards get the CPU in between.
    private static let pause: Duration = .milliseconds(400)

    func connect(_ laws: LawLibraryModel) {
        guard self.laws !== laws else { return }
        self.laws = laws
        watching = [
            laws.$catalog.receive(on: DispatchQueue.main).sink { [weak self] catalog in
                MainActor.assumeIsolated { self?.catalogChanged(catalog?.entries ?? []) }
            },
            NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.purge() } },
        ]
    }

    private func catalogChanged(_ next: [LawEntry]) {
        let old = Dictionary(entries.map { ($0.id, $0.currentVersion) }, uniquingKeysWith: { a, _ in a })
        entries = next
        // Keep indexes of unchanged versions; a new version is indexed again.
        let current = Set(next.map { "\($0.id)|\($0.currentVersion)" })
        titles = titles.filter { current.contains($0.key) }
        missing = []
        if next.contains(where: { old[$0.id] != $0.currentVersion }) || next.count != old.count {
            indexing?.cancel(); indexing = nil; queue = []; offline = nil; offlineCheckedAt = .distantPast
        }
    }

    /// Memory warning: only the work in progress stops. The finished maps are
    /// small (keys and titles) and stay, so nothing is decoded again.
    private func purge() {
        indexing?.cancel(); indexing = nil; queue = []
    }

    func entry(_ id: String) -> LawEntry? { entries.first { $0.id == id } }
    var statuteEntries: [LawEntry] { entries.filter { $0.kind != "administration" } }

    /// Section title of `key` in the offline current version of `lawID`, if indexed.
    func title(lawID: String, key: String) -> String? {
        guard let entry = entry(lawID) else { return nil }
        return titles["\(entry.id)|\(entry.currentVersion)"]?[key]
    }

    /// Up to three laws for a bare citation with section `key`: the notebook's
    /// default law, the law written last before it in the same text, then
    /// offline laws that have this section. Never downloads anything.
    func suggestions(key: String, defaultLawID: String?, previousLawID: String?) -> [LawSuggestion] {
        guard laws?.enabled == true else { return [] }
        var ids: [String] = []
        func add(_ id: String?) {
            guard let id, !ids.contains(id), let entry = entry(id), entry.kind != "administration" else { return }
            ids.append(id)
        }
        add(defaultLawID); add(previousLawID)
        // Offline laws with that section, most common first (catalog order).
        for entry in statuteEntries where ids.count < 3 {
            if titles["\(entry.id)|\(entry.currentVersion)"]?[key] != nil { add(entry.id) }
        }
        requestIndex(first: [defaultLawID, previousLawID].compactMap { $0 })
        return ids.prefix(3).compactMap { id in
            guard let entry = entry(id) else { return nil }
            let title = title(lawID: id, key: key)
            return LawSuggestion(lawID: id, abbr: entry.abbr, label: Self.label(abbr: entry.abbr, title: title ?? entry.name))
        }
    }

    static func label(abbr: String, title: String) -> String {
        let clean = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !clean.isEmpty, clean != abbr else { return abbr }
        let short = clean.count > 34 ? String(clean.prefix(32)).trimmingCharacters(in: .whitespaces) + " …" : clean
        return "\(abbr) – \(short)"
    }

    /// Lazy index: only laws whose text is already on this iPad, the asked
    /// ones (default, previous law) first, then a few more per suggestion.
    /// One law at a time at background priority, decoded from its file off
    /// the shared law store (cards and reader never wait for it), with a
    /// pause between laws.
    private func requestIndex(first: [String]) {
        // A law downloaded meanwhile is found on the next check (at most every two minutes).
        if Date().timeIntervalSince(offlineCheckedAt) > 120 { checkOffline() }
        guard let offline else { return }
        func wanted(_ id: String) -> Bool {
            guard offline.contains(id), let entry = entry(id), entry.kind != "administration" else { return false }
            let key = "\(entry.id)|\(entry.currentVersion)"
            return titles[key] == nil && !missing.contains(key)
        }
        for id in first.reversed() where wanted(id) { queue.removeAll { $0 == id }; queue.insert(id, at: 0) }
        var added = 0
        for entry in statuteEntries where added < Self.batch && wanted(entry.id) && !queue.contains(entry.id) {
            queue.append(entry.id); added += 1
        }
        runQueue()
    }

    private func checkOffline() {
        guard !checkingOffline else { return }
        checkingOffline = true; offlineCheckedAt = Date()
        let root = LawLibraryModel.root
        let list = statuteEntries.map { ($0.id, $0.currentVersion) }
        let catalog = entries.count
        Task { [weak self] in
            let present = await Task.detached(priority: .background) { () -> Set<String> in
                var found = Set<String>()
                for (id, version) in list where LawEntry.safeID(id) && LawEntry.safeID(version) {
                    if FileManager.default.fileExists(atPath: root.appendingPathComponent("laws/\(id)/\(version)/law.json").path) { found.insert(id) }
                }
                return found
            }.value
            guard let self else { return }
            self.checkingOffline = false
            guard self.entries.count == catalog else { self.offlineCheckedAt = .distantPast; return }
            self.offline = present
            self.indexGeneration &+= 1 // a waiting suggestion asks again and queues its laws
        }
    }

    private func runQueue() {
        guard indexing == nil, !queue.isEmpty else { return }
        let root = LawLibraryModel.root
        indexing = Task { [weak self] in
            while let self, !Task.isCancelled, !self.queue.isEmpty {
                let id = self.queue.removeFirst()
                guard let entry = self.entry(id), let version = entry.versions.first(where: { $0.id == entry.currentVersion }) else { continue }
                let key = "\(entry.id)|\(entry.currentVersion)"
                guard self.titles[key] == nil else { continue }
                let map = await Task.detached(priority: .background) { () -> [String: String]? in
                    Self.sectionTitles(root: root, entry: entry, version: version)
                }.value
                guard !Task.isCancelled else { return }
                if let map { self.titles[key] = map; self.indexGeneration &+= 1 } else { self.missing.insert(key) }
                try? await Task.sleep(for: Self.pause)
            }
            self?.indexing = nil
        }
    }

    /// Key → title of every section of an offline law file; nil if missing,
    /// too large or not the catalog's version. Read-only, never on the main thread.
    nonisolated private static func sectionTitles(root: URL, entry: LawEntry, version: LawVersion) -> [String: String]? {
        guard LawEntry.safeID(entry.id), LawEntry.safeID(version.id) else { return nil }
        let url = root.appendingPathComponent("laws/\(entry.id)/\(version.id)/law.json")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 64_000_000,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let document = try? JSONDecoder().decode(LawDocument.self, from: data).validated(for: entry, version: version) else { return nil }
        var result: [String: String] = [:]
        for section in document.sections {
            let title = section.title.isEmpty ? section.label : section.title
            for k in [section.id.lowercased()] + section.keys where result[k] == nil { result[k] = title }
        }
        return result
    }
}
