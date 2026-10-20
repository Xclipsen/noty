import Foundation
import NotebookCore

/// Process-wide resolver of image originals by content address. Correct
/// because content addressing makes the same hash the same bytes in every
/// package. Holds weak references to the `NotebookAssets` of open editors
/// (their repository's writable instance, including pending imports) and of
/// read-only previews/exports while they run; the first instance that has an
/// asset serves it. Default provider of `ImageRendering`, so the UIKit layers
/// need no explicit source; background paths pass theirs explicitly.
///
/// `pinClipboard` keeps the packages of objects copied with the selection
/// tool alive while they are on the in-app clipboard, so pasting into another
/// notebook can still stage their originals there.
final class ImageAssetRegistry: ImageAssetProviding, @unchecked Sendable {
    static let shared = ImageAssetRegistry()

    private final class Weak { weak var assets: NotebookAssets?; init(_ assets: NotebookAssets) { self.assets = assets } }
    private let lock = NSLock()
    private var entries: [Weak] = []
    private var pinned: [NotebookAssets] = []

    func register(_ assets: NotebookAssets) {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { $0.assets == nil || $0.assets === assets }
        entries.append(Weak(assets))
    }

    /// Keeps the instances that hold `references` alive (replacing an
    /// earlier pin); an empty list releases the pin.
    func pinClipboard(_ references: [ImageAssetReference]) {
        let holders = references.isEmpty ? [] : live.filter { assets in references.contains { assets.isAvailable($0) } }
        lock.lock(); pinned = holders; lock.unlock()
    }

    /// Newest registration first, then pinned instances.
    private var live: [NotebookAssets] {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { $0.assets == nil }
        var result = entries.reversed().compactMap(\.assets)
        for assets in pinned where !result.contains(where: { $0 === assets }) { result.append(assets) }
        return result
    }

    func payload(for reference: ImageAssetReference) throws -> ImageAssetPayload {
        try ChainedImageAssets(live).payload(for: reference)
    }

    func verifiedPayload(for reference: ImageAssetReference) throws -> ImageAssetPayload {
        try ChainedImageAssets(live).verifiedPayload(for: reference)
    }

    /// The bytes of `reference` from any registered package, verified against
    /// the reference; nil if no package has it. Reads at most 20 MB.
    func data(for reference: ImageAssetReference) -> Data? {
        switch try? verifiedPayload(for: reference) {
        case .data(let data)?: return data
        case .file(let url)?:
            guard let data = try? BoundedFile.read(url, limit: ImageLimits.maximumFileBytes),
                  ImageAssetReference(of: data) == reference else { return nil }
            return data
        case nil: return nil
        }
    }
}
