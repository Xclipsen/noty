import Foundation

/// Documented image limits (IMAGES.md). Stored-document validation
/// (`ImageObject.validate`, `Notebook.validate`) and the independent Python
/// verifier use the same values; import checks them early for a clear message.
public enum ImageLimits {
    /// One stored original (asset); older imports up to this size stay valid.
    public static let maximumFileBytes = 20_000_000
    /// One newly imported original; larger images are compressed first
    /// (`ImageCompression`). Nutzer zu Build 52.
    public static let maximumImportBytes = 5_000_000
    public static let maximumPixels = 200_000_000.0
    public static let maximumSide = 100_000
    /// Unique image originals of one notebook (each hash once) over active
    /// pages and the page trash; duplicated pages or objects cost nothing.
    public static let maximumNotebookBytes = 500_000_000
    /// Stored schema 5–11 only: embedded originals summed per object
    /// (duplicates counted), the limit up to Build 53.
    public static let legacyMaximumNotebookBytes = 40_000_000
    public static let maximumImagesPerPage = 50

    /// "12,4 MB" (decimal megabytes like the limits), rounded up so a value
    /// above a limit never reads as the limit itself.
    public static func megabytes(_ bytes: Int) -> String {
        let tenths = (max(0, bytes) + 99_999) / 100_000
        return "\(tenths / 10),\(tenths % 10) MB"
    }
}

/// Container format of an image original from its first bytes. Import uses it
/// to take the photo (not the movie) out of a Live Photo bundle and to reject a
/// video with a clear message. Stored documents are deliberately not limited
/// to these formats: earlier imports accepted everything ImageIO decodes, and a
/// stricter check would lock such notebooks.
public enum ImageFileFormat: String, Equatable, Sendable, CaseIterable {
    case png, jpeg, gif, tiff, bmp, webp
    /// HEIF still image or image sequence (HEIC from the iPhone camera).
    case heif
    case avif
    /// QuickTime/MPEG-4 movie, e.g. the motion part of a Live Photo.
    case video

    /// Enough for every signature including an `ftyp` box with 10 brands.
    public static let headerLength = 64

    public var isStillImage: Bool { self != .video }

    /// HEIF brands (ISO/IEC 23008-12): HEVC images/sequences and the
    /// structural `mif1`/`msf1` brands that Apple writes as compatible brands.
    static let heifBrands: Set<String> = ["heic", "heix", "heim", "heis", "hevc", "hevx", "hevm", "hevs", "mif1", "mif2", "msf1"]
    static let avifBrands: Set<String> = ["avif", "avis"]
    static let videoBrands: Set<String> = ["qt  ", "isom", "iso2", "iso3", "iso4", "iso5", "iso6", "mp41", "mp42",
                                          "M4V ", "M4VH", "M4VP", "avc1", "3gp4", "3gp5", "3gp6", "3g2a", "dash", "MSNV", "f4v "]

    public static func detect(_ data: Data) -> ImageFileFormat? {
        let bytes = [UInt8](data.prefix(headerLength))
        func has(_ signature: [UInt8], at offset: Int = 0) -> Bool {
            bytes.count >= offset + signature.count && Array(bytes[offset..<(offset + signature.count)]) == signature
        }
        func has(_ text: String, at offset: Int = 0) -> Bool { has(Array(text.utf8), at: offset) }
        if has([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if has([0xFF, 0xD8, 0xFF]) { return .jpeg }
        if has("GIF87a") || has("GIF89a") { return .gif }
        // TIFF; DNG (ProRAW) uses the same header and is decoded by ImageIO too.
        if has([0x49, 0x49, 0x2A, 0x00]) || has([0x4D, 0x4D, 0x00, 0x2A]) { return .tiff }
        if has("RIFF") && has("WEBP", at: 8) { return .webp }
        if has("BM") && has([0, 0, 0, 0], at: 6) && bytes.count >= 26 { return .bmp }
        return isoMediaFormat(bytes)
    }

    /// ISO base media file (HEIF, AVIF, MOV, MP4): `ftyp` box with major and
    /// compatible brands. The major brand decides; compatible brands only if
    /// the major one is unknown.
    private static func isoMediaFormat(_ bytes: [UInt8]) -> ImageFileFormat? {
        guard bytes.count >= 16, Array(bytes[4..<8]) == Array("ftyp".utf8) else { return nil }
        let size = bytes[0..<4].reduce(0) { $0 << 8 | Int($1) }
        // 0: box extends to the end of the file; 1 (64-bit size) does not occur for `ftyp`.
        guard size == 0 || (16...4096).contains(size), size % 4 == 0 else { return nil }
        let end = size == 0 ? bytes.count : min(size, bytes.count)
        let brand = { (offset: Int) in String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self) }
        let major = brand(8)
        let compatible = stride(from: 16, to: end - 3, by: 4).map(brand)
        for brands in [[major], compatible] {
            if brands.contains(where: avifBrands.contains) { return .avif }
            if brands.contains(where: heifBrands.contains) { return .heif }
            if brands.contains(where: videoBrands.contains) { return .video }
        }
        return nil
    }

    /// Index of the photo among the files of a bundle (Live Photo: photo plus
    /// movie), decided by content and not by name; nil if there is none.
    public static func stillImageIndex(headers: [Data]) -> Int? {
        headers.firstIndex { detect($0)?.isStillImage == true }
    }
}

/// Why an image of this size cannot be added; checked before decoding so the
/// message can name the limit instead of a generic validation failure.
public enum ImageInsertionProblem: Equatable, Sendable {
    case fileTooLarge(bytes: Int)
    case pageFull
    case notebookFull(used: Int, adding: Int)
}

extension Notebook {
    /// Bytes of the unique image originals counted against the notebook
    /// limit: active pages and the page trash, each hash once.
    public var uniqueImageAssetBytes: Int {
        var seen = Set<String>()
        return allImages.reduce(0) { total, image in seen.insert(image.asset.sha256).inserted ? total + image.asset.byteCount : total }
    }

    /// Whether the imported original `reference` may be added to `pageID`.
    /// An original already in the notebook (same hash) adds no bytes.
    public func imageInsertionProblem(adding reference: ImageAssetReference, pageID: UUID) -> ImageInsertionProblem? {
        let present = allImages.contains { $0.asset.sha256 == reference.sha256 }
        guard present || reference.byteCount <= ImageLimits.maximumImportBytes else { return .fileTooLarge(bytes: reference.byteCount) }
        if let page = pages.first(where: { $0.id == pageID }),
           (page.images?.count ?? 0) >= ImageLimits.maximumImagesPerPage { return .pageFull }
        let used = uniqueImageAssetBytes
        let adding = present ? 0 : reference.byteCount
        guard used + adding <= ImageLimits.maximumNotebookBytes else { return .notebookFull(used: used, adding: adding) }
        return nil
    }
}
