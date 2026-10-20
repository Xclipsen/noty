import Foundation
import XCTest
@testable import NotebookCore

final class SHA256Tests: XCTestCase {
    private func digest(_ text: String) -> String { SHA256.hexDigest(Data(text.utf8)) }
    private func pattern(_ count: Int) -> Data { Data((0..<count).map { UInt8($0 % 251) }) }

    /// FIPS 180-4 / NIST CSRC example values.
    func testFIPSVectors() {
        XCTAssertEqual(digest(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(digest("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(digest("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(digest("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"),
                       "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1")
    }

    func testOneMillionAStreamedInUnevenPieces() {
        var hasher = SHA256()
        let piece = Data(repeating: 0x61, count: 9_973)
        var remaining = 1_000_000
        while remaining > 0 {
            let count = min(remaining, piece.count)
            hasher.update(piece.prefix(count)); remaining -= count
        }
        XCTAssertEqual(hasher.hexDigest, "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
        XCTAssertEqual(SHA256.hexDigest(Data(repeating: 0x61, count: 1_000_000)), hasher.hexDigest)
    }

    /// Reference digests (Python hashlib) of bytes `i % 251` around the padding
    /// boundary (55/56) and the block boundary (63/64/65).
    func testPaddingAndBlockBoundaries() {
        let expected: [Int: String] = [
            1: "6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d",
            55: "463eb28e72f82e0a96c0a4cc53690c571281131f672aa229e0d45ae59b598b59",
            56: "da2ae4d6b36748f2a318f23e7ab1dfdf45acdc9d049bd80e59de82a60895f562",
            57: "2fe741af801cc238602ac0ec6a7b0c3a8a87c7fc7d7f02a3fe03d1c12eac4d8f",
            63: "29af2686fd53374a36b0846694cc342177e428d1647515f078784d69cdb9e488",
            64: "fdeab9acf3710362bd2658cdc9a29e8f9c757fcf9811603a8c447cd1d9151108",
            65: "4bfd2c8b6f1eec7a2afeb48b934ee4b2694182027e6d0fc075074f2fabb31781",
            119: "da18797ed7c3a777f0847f429724a2d8cd5138e6ed2895c3fa1a6d39d18f7ec6",
            120: "f52b23db1fbb6ded89ef42a23ce0c8922c45f25c50b568a93bf1c075420bbb7c",
            127: "92ca0fa6651ee2f97b884b7246a562fa71250fedefe5ebf270d31c546bfea976",
            128: "471fb943aa23c511f6f72f8d1652d9c880cfa392ad80503120547703e56a2be5",
            129: "5099c6a56203f9687f7d33f4bfdf576d31dc91f6b695ecea38b2770c87631135",
            1000: "4e4c294b331f7a2099a379bec34b9f9fc03dc46ab465d998f4d683da53487e6d"
        ]
        for (count, value) in expected {
            XCTAssertEqual(SHA256.hexDigest(pattern(count)), value, "length \(count)")
        }
    }

    /// Every split point of messages around the boundaries, and byte-wise
    /// feeding, gives the one-shot digest.
    func testStreamingSplitsMatchOneShot() {
        for count in [55, 56, 63, 64, 65, 128, 130] {
            let data = pattern(count), whole = SHA256.hexDigest(data)
            for split in 0...count {
                var hasher = SHA256()
                hasher.update(data.prefix(split)); hasher.update(data.dropFirst(split))
                XCTAssertEqual(hasher.hexDigest, whole, "length \(count), split \(split)")
            }
            var bytewise = SHA256()
            for byte in data { bytewise.update(Data([byte])) }
            XCTAssertEqual(bytewise.hexDigest, whole, "length \(count) byte-wise")
        }
    }

    func testFinalizeDoesNotConsumeTheHasherAndEmptyUpdatesAreNeutral() {
        var hasher = SHA256()
        hasher.update(Data("ab".utf8)); hasher.update(Data())
        _ = hasher.hexDigest
        hasher.update(Data("c".utf8))
        XCTAssertEqual(hasher.hexDigest, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(hasher.finalize().count, SHA256.digestByteCount)
        // Non-zero Data slice indices.
        let sliced = (Data([9, 9]) + Data("abc".utf8)).dropFirst(2)
        XCTAssertEqual(SHA256.hexDigest(sliced), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testImageAssetReferenceValidationAndCoding() throws {
        let reference = ImageAssetReference(of: Data("abc".utf8))
        XCTAssertEqual(reference.sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(reference.byteCount, 3)
        XCTAssertTrue(reference.isValid)
        let encoded = try JSONEncoder().encode(reference)
        XCTAssertEqual(try JSONDecoder().decode(ImageAssetReference.self, from: encoded), reference)
        let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        XCTAssertEqual(Set(object.keys), ["sha256", "byteCount"])

        let hash = reference.sha256
        XCTAssertFalse(ImageAssetReference(sha256: hash.uppercased(), byteCount: 3).isValid)
        XCTAssertFalse(ImageAssetReference(sha256: String(hash.dropLast()), byteCount: 3).isValid)
        XCTAssertFalse(ImageAssetReference(sha256: hash + "0", byteCount: 3).isValid)
        XCTAssertFalse(ImageAssetReference(sha256: "../" + hash.dropFirst(3), byteCount: 3).isValid)
        XCTAssertFalse(ImageAssetReference(sha256: String(hash.dropLast()) + "g", byteCount: 3).isValid)
        XCTAssertFalse(ImageAssetReference(sha256: hash, byteCount: 0).isValid)
        XCTAssertTrue(ImageAssetReference(sha256: hash, byteCount: ImageLimits.maximumFileBytes).isValid)
        XCTAssertFalse(ImageAssetReference(sha256: hash, byteCount: ImageLimits.maximumFileBytes + 1).isValid)
        // Non-ASCII digits that Character.isHexDigit would accept.
        XCTAssertFalse(ImageAssetReference.isValidHash(String(repeating: "０", count: 64)))
    }
}
