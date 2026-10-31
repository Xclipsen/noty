import UIKit
import ImageIO
import NotebookCore

enum ImageImportError: LocalizedError {
    case invalid, fileTooLarge, tooManyPixels, missingClipboard, video, pageFull, pageChanged
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
        case .fileTooLarge: "Das Bild ist zu groß und ließ sich nicht ausreichend verkleinern (höchstens 250 MB als Quelle). Bitte eine kleinere Fassung wählen, z. B. in Fotos als HEIC oder JPEG sichern."
        case .tooManyPixels: "Das Bild hat mehr als 200 Megapixel, das ist für noty zu groß."
        case .pageChanged: "Die Seite hat sich währenddessen geändert. Bitte das Bild erneut einfügen."
        case .missingClipboard: "Die Zwischenablage enthält kein unterstütztes Bild. Bitte zuerst einen Screenshot oder ein Bild kopieren."
        case .video: "Die ausgewählte Datei ist ein Video. Bitte ein Foto oder Bild auswählen."
        case .pageFull: "Auf dieser Seite liegen bereits 50 Bilder, mehr sind je Seite nicht möglich. Bitte eine andere Seite verwenden."
        case .notebookFull(let used, let adding):
            "Dieses Bild (\(ImageLimits.megabytes(adding))) passt nicht mehr in das Notizbuch: Bildoriginale sind auf 500 MB je Notizbuch begrenzt, einschließlich Seitenpapierkorb; mehrfach verwendete Bilder (duplizierte Seiten, Kopien) zählen nur einmal. Belegt sind \(ImageLimits.megabytes(used)). Bitte Seiten mit Bildern im Seitenpapierkorb endgültig löschen, ein kleineres Bild wählen oder ein neues Notizbuch verwenden."
        case .unsupportedPhoto(let offered):
            "Fotos hat für dieses Objekt kein Standbild geliefert (angeboten: \(offered)). Bitte das Foto in Fotos als HEIC oder JPEG sichern oder über „Bilddatei“ einfügen."
        case .photoUnavailable(let detail):
            "Das Foto konnte nicht aus der Fotomediathek geladen werden. Liegt das Original nur in iCloud, bitte die Internetverbindung prüfen und erneut versuchen. (\(detail))"
        }
    }
}

/// Metadata and thumbnails are read without decoding a full camera raster.
/// Originals come as an `ImageAssetPayload`: ImageIO reads a package file
/// directly (`CGImageSourceCreateWithURL`) or bytes in memory.
enum ImageImport {
    static func dimensions(_ data: Data) throws -> (Int, Int) { try dimensions(.data(data)) }

    static func dimensions(_ payload: ImageAssetPayload) throws -> (Int, Int) {
        let size = try byteCount(payload)
        guard size > 0 else { throw ImageImportError.invalid }
        guard size <= ImageLimits.maximumFileBytes else { throw ImageImportError.fileTooLarge }
        guard let source = imageSource(payload),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw ImageFileFormat.detect(header(payload)) == .video ? ImageImportError.video : ImageImportError.invalid
        }
        guard (1...ImageLimits.maximumSide).contains(width), (1...ImageLimits.maximumSide).contains(height),
              Double(width) * Double(height) <= ImageLimits.maximumPixels else { throw ImageImportError.tooManyPixels }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return (5...8).contains(orientation) ? (height, width) : (width, height)
    }

    private static func imageSource(_ payload: ImageAssetPayload) -> CGImageSource? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        switch payload {
        case .data(let data): return CGImageSourceCreateWithData(data as CFData, options)
        case .file(let url): return CGImageSourceCreateWithURL(url as CFURL, options)
        }
    }

    private static func byteCount(_ payload: ImageAssetPayload) throws -> Int {
        switch payload {
        case .data(let data): return data.count
        case .file(let url):
            guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw ImageImportError.invalid }
            return size
        }
    }

    private static func header(_ payload: ImageAssetPayload) -> Data {
        switch payload {
        case .data(let data): return data.prefix(ImageFileFormat.headerLength)
        case .file(let url):
            guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
            defer { try? handle.close() }
            return (try? handle.read(upToCount: ImageFileFormat.headerLength)) ?? Data()
        }
    }

    /// The selected file, read in bounded chunks (never more than
    /// `ImageCompression.maximumSourceBytes` in memory; larger than 20 MB is
    /// compressed before insertion). A directory is a Live Photo bundle (photo plus movie, the
    /// iPhone camera default): its photo is taken, recognised by content.
    static func read(_ url: URL) throws -> Data {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            return try read(stillImage(in: url))
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: 64_000), !chunk.isEmpty {
            guard chunk.count <= ImageCompression.maximumSourceBytes - data.count else { throw ImageImportError.fileTooLarge }
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

    static func thumbnail(_ data: Data, limit: Int) throws -> CGImage { try thumbnail(.data(data), limit: limit) }

    static func thumbnail(_ payload: ImageAssetPayload, limit: Int) throws -> CGImage {
        guard let source = imageSource(payload),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: limit,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw ImageImportError.invalid }
        return image
    }

    /// Off the main actor: the new object for `data`, already staged as
    /// `reference` (decodes its metadata and a small thumbnail once).
    /// `near`: centre of the image if it fits there, otherwise as close as the bounds allow.
    static func object(_ reference: ImageAssetReference, data: Data, in bounds: PageRect, near place: PagePoint? = nil) throws -> ImageObject {
        let (width, height) = try dimensions(data)
        _ = try thumbnail(data, limit: 32)
        let scale = min(1, min(320, bounds.width * 0.7) / Double(width), bounds.height * 0.7 / Double(height))
        let w = max(1, Double(width) * scale), h = max(1, Double(height) * scale)
        let centre = place ?? PagePoint(x: bounds.x + bounds.width / 2, y: bounds.y + bounds.height / 2)
        let object = ImageObject(asset: reference, pixelWidth: width, pixelHeight: height,
            x: max(bounds.x, min(centre.x - w / 2, bounds.x + bounds.width - w)),
            y: max(bounds.y, min(centre.y - h / 2, bounds.y + bounds.height - h)), width: w, height: h)
        try object.validate()
        return object
    }
}

/// Editor, thumbnails and PDF share crop/rotation math and orientation handling.
/// Every byte of an original is read through an `ImageAssetProviding`
/// (`assets`); nil means `ImageAssetRegistry.shared` (the packages of open
/// editors and running previews). Renditions are cached by content address,
/// so duplicated images share them.
@MainActor
enum ImageRendering {
    private final class Entry {
        let image: UIImage
        init(_ image: UIImage) { self.image = image }
    }
    /// Cost: decoded pixels only. A 2048 rendition costs 12–16 MB: room for
    /// about ten photos plus their smaller renditions; a memory warning
    /// empties it (`purge`).
    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>(); cache.totalCostLimit = 160 * 1024 * 1024; cache.countLimit = 48
        return cache
    }()
    private static let renditions = [256, 512, 1024, 2048, 2400, 4096]
    private static var decoding: [NSString: [@MainActor (Error?) -> Void]] = [:]
    private struct Decoded: @unchecked Sendable { let image: CGImage? ; let error: Error? }

    /// The original's bytes. `verified`: proven to match the reference
    /// (provider-specific; inline bytes define their own reference).
    nonisolated static func payload(_ object: ImageObject, assets: ImageAssetProviding?, verified: Bool = false) throws -> ImageAssetPayload {
        let provider = assets ?? ImageAssetRegistry.shared
        return verified ? try provider.verifiedPayload(for: object.asset) : try provider.payload(for: object.asset)
    }

    private static func key(_ asset: ImageAssetReference, _ limit: Int) -> NSString { "\(asset.sha256)-\(limit)" as NSString }
    private static func store(_ cgImage: CGImage, for asset: ImageAssetReference, limit: Int) -> UIImage {
        let image = UIImage(cgImage: cgImage)
        cache.setObject(Entry(image), forKey: key(asset, limit), cost: cgImage.bytesPerRow * cgImage.height)
        return image
    }

    static func image(_ object: ImageObject, limit: Int = 2048, assets: ImageAssetProviding? = nil) throws -> UIImage {
        if let image = cached(object, limit: limit) { return image }
        return store(try ImageImport.thumbnail(payload(object, assets: assets), limit: limit), for: object.asset, limit: limit)
    }
    /// The rendition at `limit` if it is cached; never decodes.
    static func cached(_ object: ImageObject, limit: Int) -> UIImage? {
        cache.object(forKey: key(object.asset, limit))?.image
    }
    /// The closest cached rendition of any size, larger ones first among equal
    /// distance: drawn instead of the grey placeholder while decoding.
    static func anyCached(_ object: ImageObject, near limit: Int) -> UIImage? {
        renditions.sorted { abs($0 - limit) == abs($1 - limit) ? $0 > $1 : abs($0 - limit) < abs($1 - limit) }
            .lazy.compactMap { cached(object, limit: $0) }.first
    }
    /// Decodes the rendition off the main thread, then calls `done` on the
    /// main actor (error: unreadable or damaged original). Concurrent requests
    /// for the same content share one decode. The original is verified
    /// (SHA-256 once per session and package, `verifiedPayload`): opening only
    /// checks presence, so this first draw is the full check.
    static func prepare(_ object: ImageObject, limit: Int, assets: ImageAssetProviding? = nil,
                        done: @escaping @MainActor (Error?) -> Void) {
        let asset = object.asset
        let name = key(asset, limit)
        if cached(object, limit: limit) != nil { done(nil); return }
        if decoding[name] != nil { decoding[name]?.append(done); return }
        decoding[name] = [done]
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Decoded
            do { result = Decoded(image: try ImageImport.thumbnail(payload(object, assets: assets, verified: true), limit: limit), error: nil) }
            catch { result = Decoded(image: nil, error: error) }
            Task { @MainActor in
                if let image = result.image { _ = store(image, for: asset, limit: limit) }
                let waiting = decoding.removeValue(forKey: key(asset, limit)) ?? []
                waiting.forEach { $0(result.error) }
            }
        }
    }
    /// Memory warning: decoded renditions are rebuilt on demand.
    static func purge() { cache.removeAllObjects() }

    /// Dimensions and a small decode of the verified original.
    nonisolated static func validate(_ object: ImageObject, assets: ImageAssetProviding? = nil) throws {
        let source = try payload(object, assets: assets, verified: true)
        let (width, height) = try ImageImport.dimensions(source)
        guard width == object.pixelWidth, height == object.pixelHeight else { throw ImageImportError.invalid }
        _ = try ImageImport.thumbnail(source, limit: 32)
    }

    static func draw(_ object: ImageObject, context: CGContext, origin: PagePoint, limit: Int = 2048,
                     assets: ImageAssetProviding? = nil) throws {
        draw(try image(object, limit: limit, assets: assets), for: object, context: context, origin: origin)
    }

    /// Uncached decode for background rasterisation; same pixels as `image(_:limit:)`.
    nonisolated static func decoded(_ object: ImageObject, limit: Int, assets: ImageAssetProviding? = nil) throws -> UIImage {
        UIImage(cgImage: try ImageImport.thumbnail(payload(object, assets: assets), limit: limit))
    }

    /// Rendition size for one output page. A page with many photos must not
    /// hold them all at the maximum at once: from the third image on each
    /// gets what its printed size needs, which looks the same on the page.
    nonisolated static func outputLimit(_ object: ImageObject, imagesOnPage count: Int, maximum: Int, pixelsPerPoint: Double) -> Int {
        guard count > 2 else { return maximum }
        let whole = max(object.width / max(object.crop.width, 0.01), object.height / max(object.crop.height, 0.01))
        return min(maximum, max(1024, Int((whole * pixelsPerPoint).rounded(.up))))
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
