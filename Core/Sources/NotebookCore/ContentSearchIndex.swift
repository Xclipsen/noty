import Foundation

/// Derived content-search index. It lives in Library/Caches, never in revisions,
/// backups or the notebook package, and may be deleted at any time: every record
/// carries the fingerprint of the inputs it was recognised from.
public enum ContentSearchIndexFormat {
    /// Bump whenever recognition, raster size, bounds or fingerprint inputs change;
    /// files of other versions are discarded on load.
    public static let version = 1
    /// Same cap as the original in-memory search.
    public static let hitLimit = 50_000
}

public struct SearchLine: Codable, Equatable, Sendable {
    public var text: String
    public var kind: SearchContentKind
    /// Canonical page coordinates (no zoom; negative values address top/left margins).
    public var bounds: PageRect
    public init(text: String, kind: SearchContentKind, bounds: PageRect) { self.text = text; self.kind = kind; self.bounds = bounds }
}

/// Independently invalidated parts of a page: editing handwriting never repeats the scan OCR.
public enum SearchLayer: String, Codable, CaseIterable, Sendable { case pdfText, imageOCR, handwriting }

public struct SearchLayerRecord: Codable, Equatable, Sendable {
    public var fingerprint: String
    public var lines: [SearchLine]
    public init(fingerprint: String, lines: [SearchLine]) { self.fingerprint = fingerprint; self.lines = lines }
}

public struct SearchPageFingerprints: Equatable, Sendable {
    /// nil: the layer has no input on this page (nothing to recognise).
    public var pdfText: String?
    public var imageOCR: String?
    public var handwriting: String?
    public init(pdfText: String? = nil, imageOCR: String? = nil, handwriting: String? = nil) {
        self.pdfText = pdfText; self.imageOCR = imageOCR; self.handwriting = handwriting
    }
    public subscript(layer: SearchLayer) -> String? {
        switch layer { case .pdfText: pdfText; case .imageOCR: imageOCR; case .handwriting: handwriting }
    }
}

public struct SearchPageRecord: Codable, Equatable, Sendable {
    public var pageID: UUID
    /// Typed text is cheap and rebuilt whenever the notebook is read.
    public var text: [SearchLine]
    public var pdfText: SearchLayerRecord?
    public var imageOCR: SearchLayerRecord?
    public var handwriting: SearchLayerRecord?
    public init(pageID: UUID, text: [SearchLine] = []) { self.pageID = pageID; self.text = text }
    public subscript(layer: SearchLayer) -> SearchLayerRecord? {
        get { switch layer { case .pdfText: pdfText; case .imageOCR: imageOCR; case .handwriting: handwriting } }
        set {
            switch layer {
            case .pdfText: pdfText = newValue
            case .imageOCR: imageOCR = newValue
            case .handwriting: handwriting = newValue
            }
        }
    }
}

public struct SearchDocumentIndex: Codable, Equatable, Sendable {
    public var formatVersion = ContentSearchIndexFormat.version
    public var documentID: UUID
    /// Committed revision the pages were read from; only set once every page is
    /// complete, so an unchanged notebook can be skipped without decoding it.
    public var revisionStamp: String?
    /// Active pages in notebook order.
    public var pages: [SearchPageRecord]
    public init(documentID: UUID, revisionStamp: String? = nil, pages: [SearchPageRecord] = []) {
        self.documentID = documentID; self.revisionStamp = revisionStamp; self.pages = pages
    }
}

/// Fingerprint inputs of one active page, computed without any Apple framework.
public struct PreparedSearchPage: Equatable, Sendable {
    public let pageID: UUID
    public let fingerprints: SearchPageFingerprints
    public let text: [SearchLine]
    public let hasPDF: Bool
}

/// Deterministic, platform-independent 64-bit content digest (MurmurHash3-style
/// mixing over little-endian words). Change detection only, not a security measure.
public struct ContentFingerprint: Sendable {
    private var state: UInt64

    public init(_ tag: String) { state = 0x9E37_79B9_7F4A_7C15; add(tag) }

    public static func digest(_ data: Data) -> UInt64 {
        data.withUnsafeBytes { raw -> UInt64 in
            var hash: UInt64 = 0x51_7CC1_B727_220A ^ UInt64(raw.count)
            var offset = 0
            while offset + 8 <= raw.count {
                hash = round(hash, raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
                offset += 8
            }
            var tail: UInt64 = 0, shift: UInt64 = 0
            while offset < raw.count { tail |= UInt64(raw[offset]) << shift; shift += 8; offset += 1 }
            return finish(round(hash, tail))
        }
    }

    /// Large immutable originals (PDF sources): size plus head and tail.
    public static func sampledDigest(_ data: Data, window: Int = 256 * 1024) -> UInt64 {
        guard data.count > 2 * window else { return digest(data) }
        var result = ContentFingerprint("sample")
        result.add(data.count); result.add(digest(data.prefix(window))); result.add(digest(data.suffix(window)))
        return result.state
    }

    public mutating func add(_ value: UInt64) { state = Self.finish(Self.round(state, value)) }
    public mutating func add(_ value: Int) { add(UInt64(bitPattern: Int64(value))) }
    public mutating func add(_ value: Double) { add(value.bitPattern) }
    public mutating func add(_ value: Bool) { add(value ? 1 as UInt64 : 2) }
    public mutating func add(_ value: UUID) { add(Data(value.uuidString.utf8)) }
    public mutating func add(_ value: String) { add(Data(value.utf8)) }
    public mutating func add(_ data: Data) { add(data.count); add(Self.digest(data)) }
    public mutating func add(_ rect: PageRect) { for value in [rect.x, rect.y, rect.width, rect.height] { add(value) } }

    public var value: String { String(state, radix: 16) }

    private static func round(_ hash: UInt64, _ word: UInt64) -> UInt64 {
        var k = word &* 0x87C3_7B91_1142_53D5
        k = (k << 31) | (k >> 33)
        k = k &* 0x4CF5_AD43_2745_937F
        let mixed = hash ^ k
        return ((mixed << 27) | (mixed >> 37)) &* 5 &+ 0x52DC_E729
    }
    private static func finish(_ value: UInt64) -> UInt64 {
        var h = value
        h ^= h >> 33; h = h &* 0xFF51_AFD7_ED55_8CCD
        h ^= h >> 33; h = h &* 0xC4CE_B9FE_1A85_EC53
        return h ^ (h >> 33)
    }
}

/// Changes with every committed notebook revision: the store replaces its
/// manifest last. nil for packages without manifest (never skipped then).
public enum NotebookRevisionStamp {
    public static func read(directory: URL) -> String? {
        let url = directory.appendingPathComponent("manifest.json")
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= 256_000,
              let data = try? Data(contentsOf: url) else { return nil }
        var stamp = ContentFingerprint("revision"); stamp.add(data)
        return stamp.value
    }
}

public enum ContentSearchPlanner {
    /// Same chunking as before the index: 2 000 characters, 160 overlapping.
    public static func textLines(_ page: Page) -> [SearchLine] {
        var lines: [SearchLine] = []
        for box in page.effectiveTextBoxes where !box.text.isEmpty {
            var start = box.text.startIndex
            while start < box.text.endIndex {
                let end = box.text.index(start, offsetBy: 2_000, limitedBy: box.text.endIndex) ?? box.text.endIndex
                lines.append(SearchLine(text: String(box.text[start..<end]), kind: .text, bounds: box.rect))
                if end == box.text.endIndex { break }
                start = box.text.index(end, offsetBy: -160)
            }
        }
        return lines
    }

    /// Fingerprints of every active page. PDF originals are immutable per source
    /// ID; their digest is sampled once per notebook.
    public static func prepare(_ notebook: Notebook) -> [PreparedSearchPage] {
        var sources: [UUID: String] = [:]
        for source in notebook.pdfSources ?? [] {
            var value = ContentFingerprint("source"); value.add(source.id); value.add(source.pageCount)
            value.add(source.data.count); value.add(ContentFingerprint.sampledDigest(source.data))
            sources[source.id] = value.value
        }
        let legacy = notebook.pdf.map { data -> String in
            var value = ContentFingerprint("legacy"); value.add(data.count); value.add(ContentFingerprint.sampledDigest(data))
            return value.value
        }
        return notebook.pages.enumerated().map { index, page in
            var identity: String?
            if let reference = page.pdfReference {
                identity = sources[reference.sourceID].map { "\($0):\(reference.pageIndex)" }
            } else if let legacy { identity = "\(legacy):\(index)" }
            return PreparedSearchPage(pageID: page.id, fingerprints: fingerprints(page, pdfIdentity: identity),
                                      text: textLines(page), hasPDF: identity != nil)
        }
    }

    static func fingerprints(_ page: Page, pdfIdentity: String?) -> SearchPageFingerprints {
        // Canonical bounds depend on the page layout (crop, rotation, margins).
        func layout(_ tag: String) -> ContentFingerprint {
            var value = ContentFingerprint(tag)
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            value.add(page.geometry == nil)
            if let geometry = page.geometry, let data = try? encoder.encode(geometry) { value.add(data) }
            if let margins = page.margins {
                for side in [margins.left, margins.right, margins.top, margins.bottom] { value.add(side) }
            }
            return value
        }
        var result = SearchPageFingerprints()
        if let pdfIdentity { var value = layout("pdfText"); value.add(pdfIdentity); result.pdfText = value.value }
        let images = page.images ?? []
        if pdfIdentity != nil || !images.isEmpty {
            var value = layout("imageOCR"); value.add(pdfIdentity ?? "-")
            for image in images {
                // Content address, hashed once per image value instead of
                // re-reading the whole original for every fingerprint.
                value.add(image.id); value.add(image.asset.sha256)
                for number in [image.x, image.y, image.width, image.height, image.rotation] { value.add(number) }
                value.add(image.crop)
            }
            result.imageOCR = value.value
        }
        if !page.drawing.isEmpty { var value = layout("handwriting"); value.add(page.drawing); result.handwriting = value.value }
        return result
    }

    /// Current pages with every still-valid layer of `stored`; removed pages and
    /// layers with changed inputs are dropped. The stamp is cleared until complete.
    public static func reconcile(_ stored: SearchDocumentIndex?, documentID: UUID, pages: [PreparedSearchPage]) -> SearchDocumentIndex {
        let old = Dictionary((stored?.documentID == documentID ? stored?.pages ?? [] : []).map { ($0.pageID, $0) },
                             uniquingKeysWith: { first, _ in first })
        return SearchDocumentIndex(documentID: documentID, pages: pages.map { page in
            var record = SearchPageRecord(pageID: page.pageID, text: page.text)
            for layer in SearchLayer.allCases {
                if let fingerprint = page.fingerprints[layer], let previous = old[page.pageID]?[layer],
                   previous.fingerprint == fingerprint { record[layer] = previous }
            }
            return record
        })
    }

    public static func pending(_ page: PreparedSearchPage, _ record: SearchPageRecord) -> [SearchLayer] {
        SearchLayer.allCases.filter { layer in
            guard let fingerprint = page.fingerprints[layer] else { return false }
            return record[layer]?.fingerprint != fingerprint
        }
    }

    public static func isComplete(_ index: SearchDocumentIndex, _ pages: [PreparedSearchPage]) -> Bool {
        index.pages.count == pages.count && zip(pages, index.pages).allSatisfy { $0.pageID == $1.pageID && pending($0, $1).isEmpty }
    }

    /// Text PDFs: the exact text layer replaces image OCR of the PDF background
    /// (inserted images and handwriting are still recognised).
    public static func hasMeaningfulTextLayer(_ lines: [SearchLine]) -> Bool {
        var count = 0
        for line in lines where line.kind == .pdf {
            count += line.text.unicodeScalars.lazy.filter { CharacterSet.alphanumerics.contains($0) }.count
            if count >= 32 { return true }
        }
        return false
    }

    /// Hits of one page in display order: typed text, PDF text, scan/image OCR
    /// (lines identical to the exact PDF text are skipped), handwriting.
    public static func hits(_ record: SearchPageRecord, pageNumber: Int, documentID: UUID, title: String) -> [ContentSearchHit] {
        let exact = Set((record.pdfText?.lines ?? []).map(\.text))
        let lines = record.text + (record.pdfText?.lines ?? [])
            + (record.imageOCR?.lines ?? []).filter { !exact.contains($0.text) } + (record.handwriting?.lines ?? [])
        return lines.map { ContentSearchHit(documentID: documentID, pageID: record.pageID, pageNumber: pageNumber,
                                            title: title, text: $0.text, kind: $0.kind, bounds: $0.bounds) }
    }
}

/// One JSON file per notebook, written atomically by a single actor. Unreadable
/// files or other format versions are removed: everything here can be rebuilt.
public actor ContentSearchIndexStore {
    public let directory: URL
    private let fm = FileManager.default

    public init(directory: URL) { self.directory = directory }

    private func url(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }

    public func load(_ id: UUID) -> SearchDocumentIndex? {
        let file = url(id)
        guard let data = try? Data(contentsOf: file) else { return nil }
        struct Header: Decodable { var formatVersion: Int }
        guard (try? JSONDecoder().decode(Header.self, from: data))?.formatVersion == ContentSearchIndexFormat.version,
              let index = try? JSONDecoder().decode(SearchDocumentIndex.self, from: data), index.documentID == id else {
            try? fm.removeItem(at: file); return nil
        }
        return index
    }

    @discardableResult
    public func save(_ index: SearchDocumentIndex) -> Bool {
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(index).write(to: url(index.documentID), options: .atomic)
            return true
        } catch { return false }
    }

    public func remove(_ ids: [UUID]) { for id in ids { try? fm.removeItem(at: url(id)) } }

    /// Removes the index of every notebook that no longer exists (trashed ones are kept).
    @discardableResult
    public func prune(keeping ids: Set<UUID>) -> Int {
        guard let files = try? fm.contentsOfDirectory(atPath: directory.path) else { return 0 }
        var removed = 0
        for file in files {
            let name = file.hasSuffix(".json") ? String(file.dropLast(5)) : file
            if let id = UUID(uuidString: name), ids.contains(id), file.hasSuffix(".json") { continue }
            // Atomic-write leftovers and foreign names are derived data too.
            if (try? fm.removeItem(at: directory.appendingPathComponent(file))) != nil { removed += 1 }
        }
        return removed
    }

    public func ids() -> Set<UUID> {
        Set(((try? fm.contentsOfDirectory(atPath: directory.path)) ?? []).compactMap { file in
            file.hasSuffix(".json") ? UUID(uuidString: String(file.dropLast(5))) : nil
        })
    }
}
