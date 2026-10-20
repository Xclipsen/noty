import Foundation

/// Streaming SHA-256 (FIPS 180-4) in plain Swift: Core stays platform
/// independent (no CryptoKit) and has no package dependency. Identifies image
/// assets by content and detects accidental corruption; like CRC-32 it is no
/// protection against deliberate tampering of files in an open package.
///
/// Files that also import CryptoKit must write `NotebookCore.SHA256`.
public struct SHA256: Sendable {
    public static let digestByteCount = 32
    public static let blockByteCount = 64

    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]

    private var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
    /// Bytes of an incomplete block, always fewer than 64.
    private var pending: [UInt8] = []
    /// Total message length in bytes.
    private var length: UInt64 = 0

    public init() { pending.reserveCapacity(Self.blockByteCount) }

    public mutating func update(_ data: Data) { data.withUnsafeBytes { update($0) } }

    public mutating func update(_ bytes: UnsafeRawBufferPointer) {
        guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count > 0 else { return }
        let count = bytes.count
        length &+= UInt64(count)
        var index = 0
        if !pending.isEmpty {
            let take = min(Self.blockByteCount - pending.count, count)
            pending.append(contentsOf: UnsafeBufferPointer(start: base, count: take))
            index = take
            guard pending.count == Self.blockByteCount else { return }
            pending.withUnsafeBufferPointer { compress($0.baseAddress!) }
            pending.removeAll(keepingCapacity: true)
        }
        while count - index >= Self.blockByteCount {
            compress(base + index)
            index += Self.blockByteCount
        }
        if index < count { pending.append(contentsOf: UnsafeBufferPointer(start: base + index, count: count - index)) }
    }

    /// The digest of everything passed so far; the hasher itself is unchanged
    /// and may continue (padding is applied to a copy).
    public func finalize() -> [UInt8] {
        var copy = self
        let bits = length &* 8
        var tail: [UInt8] = [0x80]
        let used = (pending.count + 1) % Self.blockByteCount
        tail.append(contentsOf: repeatElement(0, count: (56 - used + Self.blockByteCount) % Self.blockByteCount))
        for shift in stride(from: 56, through: 0, by: -8) { tail.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift))) }
        tail.withUnsafeBytes { copy.update($0) }
        precondition(copy.pending.isEmpty)
        var digest: [UInt8] = []
        digest.reserveCapacity(Self.digestByteCount)
        for word in copy.h { digest.append(contentsOf: [UInt8(word >> 24), UInt8((word >> 16) & 255), UInt8((word >> 8) & 255), UInt8(word & 255)]) }
        return digest
    }

    /// 64 lowercase hexadecimal characters (the asset file name).
    public var hexDigest: String { Self.hex(finalize()) }

    public static func hexDigest(_ data: Data) -> String { var hasher = SHA256(); hasher.update(data); return hasher.hexDigest }

    static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var characters: [UInt8] = []
        characters.reserveCapacity(bytes.count * 2)
        for byte in bytes { characters.append(digits[Int(byte >> 4)]); characters.append(digits[Int(byte & 15)]) }
        return String(decoding: characters, as: UTF8.self)
    }

    private mutating func compress(_ block: UnsafePointer<UInt8>) {
        withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 64) { w in
            for t in 0..<16 {
                w[t] = UInt32(block[4 * t]) << 24 | UInt32(block[4 * t + 1]) << 16 | UInt32(block[4 * t + 2]) << 8 | UInt32(block[4 * t + 3])
            }
            for t in 16..<64 {
                let s0 = w[t - 15].rotatedRight(7) ^ w[t - 15].rotatedRight(18) ^ (w[t - 15] >> 3)
                let s1 = w[t - 2].rotatedRight(17) ^ w[t - 2].rotatedRight(19) ^ (w[t - 2] >> 10)
                w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            Self.k.withUnsafeBufferPointer { k in
                for t in 0..<64 {
                    let s1 = e.rotatedRight(6) ^ e.rotatedRight(11) ^ e.rotatedRight(25)
                    let choice = (e & f) ^ (~e & g)
                    let temp1 = hh &+ s1 &+ choice &+ k[t] &+ w[t]
                    let s0 = a.rotatedRight(2) ^ a.rotatedRight(13) ^ a.rotatedRight(22)
                    let majority = (a & b) ^ (a & c) ^ (b & c)
                    let temp2 = s0 &+ majority
                    hh = g; g = f; f = e; e = d &+ temp1
                    d = c; c = b; b = a; a = temp1 &+ temp2
                }
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d; h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
        }
    }
}

private extension UInt32 {
    @inline(__always) func rotatedRight(_ count: UInt32) -> UInt32 { (self >> count) | (self << (32 - count)) }
}
