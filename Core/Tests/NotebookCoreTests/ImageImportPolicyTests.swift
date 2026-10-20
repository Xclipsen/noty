import Foundation
import XCTest
@testable import NotebookCore

/// iPhone photo import: format sniffing (HEIC/Live Photo/video) and the
/// documented limits checked before decoding.
final class ImageImportPolicyTests: XCTestCase {
    private func hex(_ text: String) -> Data {
        var data = Data(); var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            data.append(UInt8(text[index..<next], radix: 16)!); index = next
        }
        return data
    }

    /// `ftyp` box with major/compatible brands, as written by HEIF/MP4 encoders.
    private func ftyp(_ major: String, _ compatible: [String], size: Int? = nil) -> Data {
        let length = size ?? 16 + 4 * compatible.count
        var data = Data([UInt8(length >> 24 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
        data.append(contentsOf: Array("ftyp".utf8)); data.append(contentsOf: Array(major.utf8))
        data.append(contentsOf: [0, 0, 0, 0])
        for brand in compatible { data.append(contentsOf: Array(brand.utf8)) }
        data.append(contentsOf: [0, 0, 0, 8] + Array("meta".utf8))
        return data
    }

    func testHEIFBrandsOfCameraPhotosAreStillImages() {
        // iPhone camera HEIC: major `heic`, Apple's structural compatible brands.
        XCTAssertEqual(ImageFileFormat.detect(ftyp("heic", ["mif1", "MiHE", "MiPr", "miaf", "MiHB", "heic"])), .heif)
        // Real libheif output (64 × 48, 10 bit): major `heix`.
        let libheif = hex("0000001c6674797068656978000000006d696631686569786d6961660000017c6d657461000000000000002168646c7200000000000000007069637400000000")
        XCTAssertEqual(ImageFileFormat.detect(libheif), .heif)
        // Generic HEIF major brand with HEVC compatible brand, image sequences.
        XCTAssertEqual(ImageFileFormat.detect(ftyp("mif1", ["mif1", "heic"])), .heif)
        XCTAssertEqual(ImageFileFormat.detect(ftyp("hevc", ["mif1", "msf1", "hevc"])), .heif)
        XCTAssertEqual(ImageFileFormat.detect(ftyp("msf1", ["msf1", "hevc"])), .heif)
        // Unknown major brand: compatible brands decide.
        XCTAssertEqual(ImageFileFormat.detect(ftyp("abcd", ["mif1", "heix"])), .heif)
        XCTAssertTrue(ImageFileFormat.heif.isStillImage)
        let avif = hex("0000001c6674797061766966000000006d696631617669666d6961660000")
        XCTAssertEqual(ImageFileFormat.detect(avif), .avif)
    }

    func testLivePhotoMovieAndOtherVideosAreNotStillImages() {
        // Real ffmpeg QuickTime (Live Photo movie part) and MPEG-4 headers.
        let mov = hex("00000014667479707174202000000200717420200000000877696465000002fa6d646174")
        let mp4 = hex("000000206674797069736f6d0000020069736f6d69736f32617663316d7034310000000866726565")
        XCTAssertEqual(ImageFileFormat.detect(mov), .video)
        XCTAssertEqual(ImageFileFormat.detect(mp4), .video)
        XCTAssertFalse(ImageFileFormat.video.isStillImage)
        // A HEIF major brand wins over video compatible brands and vice versa.
        XCTAssertEqual(ImageFileFormat.detect(ftyp("heic", ["isom", "mif1"])), .heif)
        XCTAssertEqual(ImageFileFormat.detect(ftyp("qt  ", ["qt  ", "mif1"])), .video)
    }

    func testClassicSignaturesAndUnknownOrDamagedHeaders() throws {
        XCTAssertEqual(ImageFileFormat.detect(hex("89504e470d0a1a0a0000000d49484452")), .png)
        XCTAssertEqual(ImageFileFormat.detect(hex("ffd8ffe000104a46")), .jpeg)
        XCTAssertEqual(ImageFileFormat.detect(hex("ffd8ffe1")), .jpeg)
        XCTAssertEqual(ImageFileFormat.detect(hex("474946383961400030")), .gif)
        XCTAssertEqual(ImageFileFormat.detect(hex("49492a0008480000")), .tiff)
        XCTAssertEqual(ImageFileFormat.detect(hex("4d4d002a00004808")), .tiff)
        XCTAssertEqual(ImageFileFormat.detect(hex("524946469000000057454250565038200000")), .webp)
        XCTAssertEqual(ImageFileFormat.detect(hex("424d8a240000000000008a0000007c000000400000003000000001001800")), .bmp)
        // Real fixture of the host roundtrip.
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/Bildobjekt.png")
        XCTAssertEqual(ImageFileFormat.detect(try Data(contentsOf: fixture)), .png)

        XCTAssertNil(ImageFileFormat.detect(Data()))
        XCTAssertNil(ImageFileFormat.detect(Data("PK\u{3}\u{4}zip".utf8)))
        XCTAssertNil(ImageFileFormat.detect(Data("BM short".utf8)))
        XCTAssertNil(ImageFileFormat.detect(Data("RIFF\0\0\0\0WAVE".utf8)))
        // Truncated, implausible box sizes and unknown brands (e.g. Canon CR3).
        XCTAssertNil(ImageFileFormat.detect(ftyp("heic", []).prefix(12)))
        XCTAssertNil(ImageFileFormat.detect(ftyp("heic", ["mif1"], size: 7)))
        XCTAssertNil(ImageFileFormat.detect(ftyp("heic", ["mif1"], size: 18)))
        XCTAssertNil(ImageFileFormat.detect(ftyp("crx ", ["crx ", "isoz"])))
        // Size 0: box extends to the end of the file.
        XCTAssertEqual(ImageFileFormat.detect(ftyp("abcd", ["heic"], size: 0)), .heif)
    }

    func testLivePhotoBundlePicksThePhotoByContentNotByName() {
        let movie = ftyp("qt  ", ["qt  "]), photo = ftyp("heic", ["mif1", "heic"])
        XCTAssertEqual(ImageFileFormat.stillImageIndex(headers: [movie, photo]), 1)
        XCTAssertEqual(ImageFileFormat.stillImageIndex(headers: [Data("{}".utf8), hex("ffd8ffe0"), photo]), 1)
        XCTAssertNil(ImageFileFormat.stillImageIndex(headers: [movie, Data("Info".utf8)]))
        XCTAssertNil(ImageFileFormat.stillImageIndex(headers: []))
    }

    func testInsertionLimitsCountUniqueOriginalsAndMatchValidation() throws {
        var document = Notebook.blank(title: "Fotos")
        let pageID = document.pages[0].id
        func photo(_ reference: ImageAssetReference) -> ImageObject {
            ImageObject(asset: reference, pixelWidth: 4032, pixelHeight: 3024, x: 40, y: 40, width: 240, height: 180)
        }
        XCTAssertEqual(document.uniqueImageAssetBytes, 0)
        // Import: at most 5 MB per new original (larger ones are compressed first) …
        XCTAssertNil(document.imageInsertionProblem(adding: .declared(ImageLimits.maximumImportBytes), pageID: pageID))
        XCTAssertEqual(document.imageInsertionProblem(adding: .declared(5_000_001), pageID: pageID), .fileTooLarge(bytes: 5_000_001))
        // … while stored originals up to 20 MB (older imports) stay valid.
        let old = photo(.declared(20_000_000, seed: 1))
        try document.replaceImages([old], pageID: pageID)
        XCTAssertThrowsError(try document.replaceImages([photo(.declared(20_000_001, seed: 2))], pageID: pageID))

        // Duplicated objects, pages and the page trash share one original.
        let copy = try document.duplicatePage(pageID)
        try document.trashPage(copy)
        XCTAssertEqual(document.allImages.count, 2)
        XCTAssertEqual(document.uniqueImageAssetBytes, 20_000_000, "each original counts once")
        // An original already in the notebook adds nothing.
        XCTAssertNil(document.imageInsertionProblem(adding: old.asset, pageID: pageID))
        // Fill up to 500 MB with distinct originals (declared sizes; Core does not decode).
        var images = [old]
        for seed in 0..<24 { var image = photo(.declared(20_000_000, seed: 100 + seed)); image.x = 40 + Double(seed); images.append(image) }
        try document.replaceImages(images, pageID: pageID)
        XCTAssertEqual(document.uniqueImageAssetBytes, 500_000_000)
        XCTAssertEqual(document.imageInsertionProblem(adding: .declared(1, seed: 9), pageID: pageID),
                       .notebookFull(used: 500_000_000, adding: 1))
        XCTAssertNil(document.imageInsertionProblem(adding: old.asset, pageID: pageID))
        // The early check and the stored-document validation agree at the limit.
        var rejected = document
        XCTAssertThrowsError(try rejected.replaceImages(images + [photo(.declared(1, seed: 9))], pageID: pageID))
        var duplicate = old; duplicate.id = UUID()
        var accepted = document
        XCTAssertNoThrow(try accepted.replaceImages(images + [duplicate], pageID: pageID))

        var full = Notebook.blank(title: "Voll")
        let many = (0..<ImageLimits.maximumImagesPerPage).map { _ in photo(.declared(10)) }
        try full.replaceImages(many, pageID: full.pages[0].id)
        XCTAssertEqual(full.imageInsertionProblem(adding: .declared(10, seed: 3), pageID: full.pages[0].id), .pageFull)
        XCTAssertThrowsError(try full.replaceImages(many + [photo(.declared(10))], pageID: full.pages[0].id))
    }
    func testMegabyteTextRoundsUpInGermanNotation() {
        XCTAssertEqual(ImageLimits.megabytes(0), "0,0 MB")
        XCTAssertEqual(ImageLimits.megabytes(1), "0,1 MB")
        XCTAssertEqual(ImageLimits.megabytes(12_400_000), "12,4 MB")
        XCTAssertEqual(ImageLimits.megabytes(20_000_000), "20,0 MB")
        XCTAssertEqual(ImageLimits.megabytes(20_000_001), "20,1 MB")
        XCTAssertEqual(ImageLimits.megabytes(40_000_000), "40,0 MB")
    }
}
