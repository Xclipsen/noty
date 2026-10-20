import Foundation

/// Content address of one immutable image original in a notebook package
/// (`Assets/<sha256>`). Not yet used by the notebook format.
public struct ImageAssetReference: Codable, Hashable, Sendable {
    public let sha256: String
    public let byteCount: Int

    public init(sha256: String, byteCount: Int) { self.sha256 = sha256; self.byteCount = byteCount }

    /// Reference of exactly these bytes (not checked against the limits).
    public init(of data: Data) { self.init(sha256: SHA256.hexDigest(data), byteCount: data.count) }

    /// Hash of 64 lowercase hexadecimal characters and 1 … 20 MB, the limit per
    /// stored original (`ImageLimits.maximumFileBytes`).
    public var isValid: Bool {
        Self.isValidHash(sha256) && (1...ImageLimits.maximumFileBytes).contains(byteCount)
    }

    /// `^[0-9a-f]{64}$`; also the only accepted asset file name.
    public static func isValidHash(_ value: String) -> Bool {
        let utf8 = value.utf8
        return utf8.count == 64 && utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}
