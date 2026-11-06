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
}

/// Finds citations of laws from the catalog. Pure and synchronous; build once
/// per catalog and reuse (it precompiles its patterns).
public struct LawCitationScanner: Sendable {
    /// `defaultLawID`: law used for a bare "§ 35a" when the text names no law before it.
    public init(entries: [LawEntry], defaultLawID: String? = nil) {
        // TODO(Core-Agent): implement
    }

    /// All citations in reading order, non-overlapping. Ambiguous or unknown
    /// laws yield no citation (never guess).
    public func citations(in text: String) -> [LawCitation] {
        [] // TODO(Core-Agent): implement
    }
}
