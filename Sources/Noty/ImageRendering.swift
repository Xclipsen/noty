import UIKit
import ImageIO
import NotebookCore

enum ImageImportError: LocalizedError {
    case invalid, fileTooLarge, tooManyPixels, missingClipboard, video, pageFull
    case notebookFull(used: Int, adding: Int)
    /// Photos delivered no still image; `offered`: its content types (diagnosis).
    case unsupportedPhoto(offered: String)
    /// The system could not hand over the photo (e.g. iCloud download failed).
    case photoUnavailable(String)

    init(_ problem: ImageInsertionProblem) {
        switch problem {
        case .fileTooLarge: self = .fileTooLarge
        case .pageFull: self = .pageFull
        case .notebookFull(let used, let adding): self = .notebookFull(used: used, adding: adding)
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalid: "Dieses Bild konnte nicht gelesen werden. Unterstützt sind Fotos und Bilder als HEIC/HEIF, JPEG, PNG, TIFF, GIF, WebP oder BMP."
        case .fileTooLarge: "Das Bild ist größer als 20 MB. noty übernimmt Fotos unverändert im Original und erlaubt höchstens 20 MB je Bild; ProRAW-/RAW-Fotos sind meist größer. Bitte eine kleinere Fassung wählen, z. B. in Fotos als HEIC oder JPEG sichern."
        case .tooManyPixels: "Das Bild hat mehr als 200 Megapixel. noty übernimmt Bilder unverändert im Original und erlaubt höchstens 200 Megapixel je Bild."
        case .missingClipboard: "Die Zwischenablage enthält kein unterstütztes Bild. Bitte zuerst einen Screenshot oder ein Bild kopieren."
        case .video: "Die ausgewählte Datei ist ein Video. Bitte ein Foto oder Bild auswählen."
        case .pageFull: "Auf dieser Seite liegen bereits 50 Bilder, mehr sind je Seite nicht möglich. Bitte eine andere Seite verwenden."
        case .notebookFull(let used, let adding):
            "Dieses Bild (\(ImageLimits.megabytes(adding))) passt nicht mehr in das Notizbuch: Bildoriginale sind auf 40 MB je Notizbuch begrenzt, einschließlich Seitenpapierkorb und duplizierter Seiten. Belegt sind \(ImageLimits.megabytes(used)). Bitte Seiten mit Bildern im Seitenpapierkorb endgültig löschen, ein kleineres Bild wählen oder ein neues Notizbuch verwenden."
        case .unsupportedPhoto(let offered):
            "Fotos hat für dieses Objekt kein Standbild geliefert (angeboten: \(offered)). Bitte das Foto in Fotos als HEIC oder JPEG sichern oder über „Bilddatei“ einfügen."
        case .photoUnavailable(let detail):
            "Das Foto konnte nicht aus der Fotomediathek geladen werden. Liegt das Original nur in iCloud, bitte die Internetverbindung prüfen und erneut versuchen. (\(detail))"
        }
    }
}

/// Metadata and thumbnails are read without decoding a full camera raster.
enum ImageImport {
    static func dimensions(_ data: Data) throws -> (Int, Int) {
        guard !data.isEmpty else { throw ImageImportError.invalid }
        guard data.count <= ImageLimits.maximumFileBytes else { throw ImageImportError.fileTooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw ImageFileFormat.detect(data) == .video ? ImageImportError.video : ImageImportError.invalid
        }
        guard (1...ImageLimits.maximumSide).contains(width), (1...ImageLimits.maximumSide).contains(height),
              Double(width) * Double(height) <= ImageLimits.maximumPixels else { throw ImageImportError.tooManyPixels }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return (5...8).contains(orientation) ? (height, width) : (width, height)
    }

    /// The selected file, read in bounded chunks (never more than the limit in
    /// memory). A directory is a Live Photo bundle (photo plus movie, the
    /// iPhone camera default): its photo is taken, recognised by content.
    static func read(_ url: URL) throws -> Data {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            return try read(stillImage(in: url))
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: 64_000), !chunk.isEmpty {
            guard chunk.count <= ImageLimits.maximumFileBytes - data.count else { throw ImageImportError.fileTooLarge }
            data.append(chunk)
        }
        return data
    }

    private static func stillImage(in bundle: URL) throws -> URL {
        let files = try FileManager.default.contentsOfDirectory(at: bundle, includingPropertiesForKeys: [.isRegularFileKey],
                                                               options: [.skipsHiddenFiles])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let headers = files.map { file -> Data in
            guard let handle = try? FileHandle(forReadingFrom: file) else { return Data() }
            defer { try? handle.close() }
            return (try? handle.read(upToCount: ImageFileFormat.headerLength)) ?? Data()
        }
        guard let index = ImageFileFormat.stillImageIndex(headers: headers) else {
            throw headers.contains { ImageFileFormat.detect($0) == .video } ? ImageImportError.video : ImageImportError.invalid
        }
        return files[index]
    }

    static func thumbnail(_ data: Data, limit: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: limit,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw ImageImportError.invalid }
        return image
    }

    static func object(_ data: Data, in bounds: PageRect) throws -> ImageObject {
        let (width, height) = try dimensions(data)
        _ = try thumbnail(data, limit: 32)
        let scale = min(1, min(320, bounds.width * 0.7) / Double(width), bounds.height * 0.7 / Double(height))
        let w = max(1, Double(width) * scale), h = max(1, Double(height) * scale)
        let object = ImageObject(data: data, pixelWidth: width, pixelHeight: height,
            x: bounds.x + (bounds.width - w) / 2, y: bounds.y + (bounds.height - h) / 2, width: w, height: h)
        try object.validate()
        return object
    }
}

/// Editor, thumbnails and PDF share crop/rotation math and orientation handling.
@MainActor
enum ImageRendering {
    private final class Entry {
        let bytes: Data; let image: UIImage
        init(_ bytes: Data, _ image: UIImage) { self.bytes = bytes; self.image = image }
    }
    /// Cost: decoded pixels only. The original bytes are shared with the model
    /// (copy on write); counting them as well let a single large photo exceed
    /// the limit, so it was evicted at once and decoded again on every draw.
    /// A 2048 rendition costs 12–16 MB: room for about ten photos plus their
    /// smaller renditions; a memory warning empties it (`purge`).
    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>(); cache.totalCostLimit = 160 * 1024 * 1024; cache.countLimit = 48
        return cache
    }()
    private static let renditions = [256, 512, 1024, 2048, 2400, 4096]
    private static var decoding: [NSString: [@MainActor (Error?) -> Void]] = [:]
    private struct Decoded: @unchecked Sendable { let image: CGImage? ; let error: Error? }

    private static func key(_ object: ImageObject, _ limit: Int) -> NSString { "\(object.id)-\(limit)" as NSString }
    private static func store(_ cgImage: CGImage, for object: ImageObject, limit: Int) -> UIImage {
        let image = UIImage(cgImage: cgImage)
        cache.setObject(Entry(object.data, image), forKey: key(object, limit), cost: cgImage.bytesPerRow * cgImage.height)
        return image
    }

    static func image(_ object: ImageObject, limit: Int = 2048) throws -> UIImage {
        if let image = cached(object, limit: limit) { return image }
        return store(try ImageImport.thumbnail(object.data, limit: limit), for: object, limit: limit)
    }
    /// The rendition at `limit` if it is cached; never decodes.
    static func cached(_ object: ImageObject, limit: Int) -> UIImage? {
        guard let entry = cache.object(forKey: key(object, limit)), sameBytes(entry.bytes, object.data) else { return nil }
        return entry.image
    }
    /// The closest cached rendition of any size, larger ones first among equal
    /// distance: drawn instead of the grey placeholder while decoding.
    static func anyCached(_ object: ImageObject, near limit: Int) -> UIImage? {
        renditions.sorted { abs($0 - limit) == abs($1 - limit) ? $0 > $1 : abs($0 - limit) < abs($1 - limit) }
            .lazy.compactMap { cached(object, limit: $0) }.first
    }
    /// Shared storage (the usual case: the model's own bytes) needs no byte compare.
    private static func sameBytes(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        let shared = a.withUnsafeBytes { x in b.withUnsafeBytes { y in x.baseAddress == y.baseAddress } }
        return shared || a == b
    }
    /// Decodes the rendition off the main thread, then calls `done` on the
    /// main actor (error: unreadable original). Concurrent requests share one decode.
    static func prepare(_ object: ImageObject, limit: Int, done: @escaping @MainActor (Error?) -> Void) {
        let name = key(object, limit)
        if cached(object, limit: limit) != nil { done(nil); return }
        if decoding[name] != nil { decoding[name]?.append(done); return }
        decoding[name] = [done]
        let data = object.data
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Decoded
            do { result = Decoded(image: try ImageImport.thumbnail(data, limit: limit), error: nil) }
            catch { result = Decoded(image: nil, error: error) }
            Task { @MainActor in
                if let image = result.image { _ = store(image, for: object, limit: limit) }
                let waiting = decoding.removeValue(forKey: Self.key(object, limit)) ?? []
                waiting.forEach { $0(result.error) }
            }
        }
    }
    /// Memory warning: decoded renditions are rebuilt on demand.
    static func purge() { cache.removeAllObjects() }

    nonisolated static func validate(_ object: ImageObject) throws {
        let (width, height) = try ImageImport.dimensions(object.data)
        guard width == object.pixelWidth, height == object.pixelHeight else { throw ImageImportError.invalid }
        _ = try ImageImport.thumbnail(object.data, limit: 32)
    }

    static func draw(_ object: ImageObject, context: CGContext, origin: PagePoint, limit: Int = 2048) throws {
        draw(try image(object, limit: limit), for: object, context: context, origin: origin)
    }

    /// Uncached decode for background rasterisation; same pixels as `image(_:limit:)`.
    nonisolated static func decoded(_ object: ImageObject, limit: Int) throws -> UIImage {
        UIImage(cgImage: try ImageImport.thumbnail(object.data, limit: limit))
    }

    /// Background rasterisation with an already decoded rendition.
    nonisolated static func draw(_ object: ImageObject, image: UIImage, context: CGContext, origin: PagePoint) {
        draw(image, for: object, context: context, origin: origin)
    }

    /// The shared crop/rotation transform. `image`: a rendition of `object`
    /// (nil: neutral placeholder of its frame). Safe off the main actor in a
    /// context pushed on the current thread.
    nonisolated static func draw(_ image: UIImage?, for object: ImageObject, context: CGContext, origin: PagePoint) {
        context.saveGState(); defer { context.restoreGState() }
        context.translateBy(x: origin.x + object.x + object.width / 2, y: origin.y + object.y + object.height / 2)
        context.rotate(by: object.rotation * .pi / 180)
        let frame = CGRect(x: -object.width / 2, y: -object.height / 2, width: object.width, height: object.height)
        context.clip(to: frame)
        guard let image else { context.setFillColor(gray: 0.86, alpha: 0.6); context.fill(frame); return }
        let fullWidth = object.width / object.crop.width, fullHeight = object.height / object.crop.height
        image.draw(in: CGRect(x: frame.minX - object.crop.x * fullWidth, y: frame.minY - object.crop.y * fullHeight,
                              width: fullWidth, height: fullHeight))
    }
}
