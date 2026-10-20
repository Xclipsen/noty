import UIKit
import ImageIO
import NotebookCore

enum ImageImportError: LocalizedError {
    case invalid, sizeLimit, missingClipboard
    var errorDescription: String? {
        switch self {
        case .invalid: "Dieses Bild konnte nicht gelesen werden. Bitte eine PNG-, JPEG- oder HEIC-Datei auswählen."
        case .sizeLimit: "Ein Bild darf höchstens 20 MB und 200 Megapixel haben. Ein Heft unterstützt 40 MB Bildoriginale einschließlich Seitenpapierkorb."
        case .missingClipboard: "Die Zwischenablage enthält kein unterstütztes Bild. Bitte zuerst einen Screenshot oder ein Bild kopieren."
        }
    }
}

/// Metadata and thumbnails are read without decoding a full camera raster.
enum ImageImport {
    static func dimensions(_ data: Data) throws -> (Int, Int) {
        guard !data.isEmpty, data.count <= 20_000_000 else { throw ImageImportError.sizeLimit }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw ImageImportError.invalid }
        guard (1...100_000).contains(width), (1...100_000).contains(height),
              Double(width) * Double(height) <= 200_000_000 else { throw ImageImportError.sizeLimit }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return (5...8).contains(orientation) ? (height, width) : (width, height)
    }

    static func read(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: 64_000), !chunk.isEmpty {
            guard chunk.count <= 20_000_000 - data.count else { throw ImageImportError.sizeLimit }
            data.append(chunk)
        }
        return data
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
    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>(); cache.totalCostLimit = 48 * 1024 * 1024; cache.countLimit = 16
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
        guard let entry = cache.object(forKey: key(object, limit)), entry.bytes == object.data else { return nil }
        return entry.image
    }
    /// The closest cached rendition of any size (placeholder while decoding).
    static func anyCached(_ object: ImageObject, near limit: Int) -> UIImage? {
        renditions.sorted { abs($0 - limit) < abs($1 - limit) }.lazy.compactMap { cached(object, limit: $0) }.first
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
    /// `image`: a rendition of `object` (nil: neutral placeholder of its frame).
    static func draw(_ image: UIImage?, for object: ImageObject, context: CGContext, origin: PagePoint) {
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
