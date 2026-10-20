import Foundation

/// Original selected file bytes, never replaced by a crop or rotation. Crop is
/// normalized in the orientation-corrected image; position is in page points.
public struct ImageObject: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public let data: Data
    public let pixelWidth: Int
    public let pixelHeight: Int
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var rotation: Double
    public var crop: PageRect
    public var locked: Bool
    /// Content address of `data`, computed once and shared by every copy of
    /// this value (`data` is immutable). Not encoded, not compared.
    private let assetCache = ImageAssetCache()

    private enum CodingKeys: String, CodingKey {
        case id, data, pixelWidth, pixelHeight, x, y, width, height, rotation, crop, locked
    }

    /// The asset reference of the original. Until notebook schema 12 the bytes
    /// stay embedded in the JSON and the reference is derived from them; the
    /// first call hashes them (off the main thread where possible).
    public var asset: ImageAssetReference { assetCache.reference(for: data) }

    /// `asset` if it was already computed for this value or a copy; never hashes.
    public var cachedAsset: ImageAssetReference? { assetCache.cached }

    public init(id: UUID = UUID(), data: Data, pixelWidth: Int, pixelHeight: Int,
                x: Double = 40, y: Double = 40, width: Double = 240, height: Double = 180,
                rotation: Double = 0, crop: PageRect = .init(x: 0, y: 0, width: 1, height: 1), locked: Bool = false) {
        self.id = id; self.data = data; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.x = x; self.y = y; self.width = width; self.height = height
        self.rotation = rotation; self.crop = crop; self.locked = locked
    }

    public func validate() throws {
        guard !data.isEmpty, data.count <= ImageLimits.maximumFileBytes,
              (1...ImageLimits.maximumSide).contains(pixelWidth), (1...ImageLimits.maximumSide).contains(pixelHeight),
              Double(pixelWidth) * Double(pixelHeight) <= ImageLimits.maximumPixels,
              [x, y, width, height, rotation].allSatisfy(\.isFinite),
              abs(x) <= 14_400, abs(y) <= 14_400,
              (1...14_400).contains(width), (1...14_400).contains(height),
              (-180...180).contains(rotation), Self.validCrop(crop) else { throw StorageError.invalidDocument }
    }

    public static func validCrop(_ crop: PageRect) -> Bool {
        [crop.x, crop.y, crop.width, crop.height].allSatisfy(\.isFinite)
            && crop.x >= 0 && crop.y >= 0 && crop.width >= 0.0199999 && crop.height >= 0.0199999
            && crop.x + crop.width <= 1.0000001 && crop.y + crop.height <= 1.0000001
    }

    public var rotatedBounds: PageRect {
        let radians = rotation * .pi / 180
        let w = abs(cos(radians)) * width + abs(sin(radians)) * height
        let h = abs(sin(radians)) * width + abs(cos(radians)) * height
        return PageRect(x: x + (width - w) / 2, y: y + (height - h) / 2, width: w, height: h)
    }

    public func fits(in bounds: PageRect) -> Bool {
        let rect = rotatedBounds
        return rect.x >= bounds.x - 0.01 && rect.y >= bounds.y - 0.01
            && rect.x + rect.width <= bounds.x + bounds.width + 0.01
            && rect.y + rect.height <= bounds.y + bounds.height + 0.01
    }

    /// Keep proportions and the complete rotated object on the sheet.
    public func fitted(in bounds: PageRect) -> ImageObject {
        var result = self
        let rotated = rotatedBounds
        let scale = min(1, bounds.width / rotated.width, bounds.height / rotated.height, 14_400 / width, 14_400 / height)
        result.width *= scale; result.height *= scale
        result.x += (width - result.width) / 2; result.y += (height - result.height) / 2
        let fitted = result.rotatedBounds
        result.x += max(bounds.x - fitted.x, min(0, bounds.x + bounds.width - fitted.x - fitted.width))
        result.y += max(bounds.y - fitted.y, min(0, bounds.y + bounds.height - fitted.y - fitted.height))
        return result
    }

    public func cropped(to value: PageRect, in bounds: PageRect) throws -> ImageObject {
        guard Self.validCrop(value) else { throw StorageError.invalidDocument }
        var result = self
        result.crop = value
        result.width = max(1, width / crop.width * value.width)
        result.height = max(1, height / crop.height * value.height)
        result.x += (width - result.width) / 2; result.y += (height - result.height) / 2
        result = result.fitted(in: bounds)
        try result.validate()
        return result
    }
}

/// Lazily computed reference of immutable bytes, shared by struct copies.
/// Hashing runs outside the lock, so `cached` never waits for it.
final class ImageAssetCache: Equatable, @unchecked Sendable {
    private let lock = NSLock()
    private var value: ImageAssetReference?

    var cached: ImageAssetReference? { lock.lock(); defer { lock.unlock() }; return value }

    func reference(for data: Data) -> ImageAssetReference {
        if let cached { return cached }
        let computed = ImageAssetReference(of: data)
        lock.lock(); defer { lock.unlock() }
        if value == nil { value = computed }
        return value!
    }

    /// A cache never makes two image objects different.
    static func == (_: ImageAssetCache, _: ImageAssetCache) -> Bool { true }
}

extension Notebook {
    public mutating func replaceImages(_ images: [ImageObject], pageID: UUID) throws {
        var next = try preparedForPageEditing()
        guard let index = next.pages.firstIndex(where: { $0.id == pageID }) else { throw PageOperationError.missingPage }
        next.schemaVersion = max(5, next.schemaVersion)
        next.pages[index].images = images
        try next.validate(); self = next
    }
}

extension ImageObject {
    public static func snappedRotation(_ degrees: Double, tolerance: Double = 5) -> Double {
        let target = (degrees / 90).rounded() * 90
        return abs(degrees - target) <= tolerance ? target : degrees
    }

    public static func normalizedRotation(_ degrees: Double) -> Double {
        var angle = degrees.truncatingRemainder(dividingBy: 360)
        if angle > 180 { angle -= 360 }; if angle < -180 { angle += 360 }
        return angle
    }

    /// Magnetic entry at 8°, release at 12° prevents a flickering straight edge.
    public static func rotationSnap(_ degrees: Double, previous: Double? = nil) -> Double? {
        let angle = normalizedRotation(degrees)
        if let previous, abs(normalizedRotation(angle - previous)) <= 12 { return normalizedRotation(previous) }
        let target = (angle / 90).rounded() * 90
        return abs(angle - target) <= 8 ? target : nil
    }

    public static func nextRightAngle(after degrees: Double) -> Double {
        normalizedRotation((floor(normalizedRotation(degrees) / 90 + 0.000001) + 1) * 90)
    }
}
