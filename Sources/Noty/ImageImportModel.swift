import SwiftUI
import PhotosUI
import _PhotosUI_SwiftUI
import CoreTransferable
import UniformTypeIdentifiers
import NotebookCore

/// Concrete still-image encodings of the Photos library, most common first.
/// Photos taken with the iPhone camera are Live Photos by default: besides the
/// HEIC/JPEG photo they offer a bundle of photo plus movie, which a request
/// for the generic `.image` type could receive instead of the photo (a
/// directory, unreadable as an image). Screenshots never have that bundle.
/// None of these concrete types matches the bundle. File transfer avoids
/// loading an unbounded Photos payload into Data first.
private struct ImportedStillImage: Transferable, Sendable {
    let data: Data
    static let contentTypes: [UTType] = [.heic, .heif, .jpeg, .png, .tiff, .gif, .webP, .bmp, .rawImage]
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .heic, importing: load)
        FileRepresentation(importedContentType: .heif, importing: load)
        FileRepresentation(importedContentType: .jpeg, importing: load)
        FileRepresentation(importedContentType: .png, importing: load)
        FileRepresentation(importedContentType: .tiff, importing: load)
        FileRepresentation(importedContentType: .gif, importing: load)
        FileRepresentation(importedContentType: .webP, importing: load)
        FileRepresentation(importedContentType: .bmp, importing: load)
        FileRepresentation(importedContentType: .rawImage, importing: load)
    }
    @Sendable private static func load(_ received: ReceivedTransferredFile) throws -> Self {
        Self(data: try ImageImport.read(received.file))
    }
}

/// Any other image type ImageIO may decode; `ImageImport.read` takes the photo
/// out of a bundle should one arrive here.
private struct ImportedImage: Transferable, Sendable {
    let data: Data
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            ImportedImage(data: try ImageImport.read(received.file))
        }
    }
}

extension ImageImport {
    /// The original bytes of a Photos item (`preferredItemEncoding: .current`:
    /// no transcoding, HEIC stays HEIC). An iCloud original is downloaded by
    /// the system during the transfer.
    static func photo(_ item: PhotosPickerItem) async throws -> Data {
        let offered = item.supportedContentTypes
        let still = offered.contains { type in ImportedStillImage.contentTypes.contains { type.conforms(to: $0) } }
        // Build 50 on the iPad: an iPhone photo failed the concrete still-image
        // representations ("keine kompatiblen Darstellungen"). Each way is tried
        // in turn: concrete still types, any image file, then the plain bytes.
        // Our own errors (size, video) end the search at once.
        var failure: Error?
        func attempt(_ load: () async throws -> Data?) async throws -> Data? {
            do { return try await load() } catch {
                if let own = importError(error) { throw own }
                failure = failure ?? error; return nil
            }
        }
        if still, let data = try await attempt({ try await item.loadTransferable(type: ImportedStillImage.self)?.data }) { return data }
        if let data = try await attempt({ try await item.loadTransferable(type: ImportedImage.self)?.data }) { return data }
        if let data = try await attempt({ try await item.loadTransferable(type: Data.self) }) { return try stillImage(data) }
        if let failure { throw ImageImportError.photoUnavailable(failure.localizedDescription) }
        throw ImageImportError.unsupportedPhoto(offered: offered.isEmpty ? "keine Formate" : offered.map(\.identifier).joined(separator: ", "))
    }

    /// Plain bytes from Photos: only a still image within the size limit.
    private static func stillImage(_ data: Data) throws -> Data {
        guard data.count <= ImageCompression.maximumSourceBytes else { throw ImageImportError.fileTooLarge }
        switch ImageFileFormat.detect(data) {
        case .video: throw ImageImportError.video
        case .some: return data
        case nil: throw ImageImportError.invalid
        }
    }

    /// Our own reading error (size, bundle without photo), also when the
    /// transfer reports it wrapped as underlying error.
    private static func importError(_ error: Error) -> ImageImportError? {
        if let error = error as? ImageImportError { return error }
        return ((error as NSError).userInfo[NSUnderlyingErrorKey] as? Error).flatMap(importError)
    }

    /// A copied camera photo may also be offered as a much larger PNG
    /// re-encoding: the pasteboard's own order (source encoding first) decides,
    /// and the first still image within the limit wins. Nothing is re-encoded here.
    @MainActor
    static func clipboardImage(_ pasteboard: UIPasteboard) throws -> Data {
        let offered = pasteboard.types.compactMap { UTType($0) }
            .filter { $0.conforms(to: .image) && !$0.conforms(to: .livePhoto) && !$0.conforms(to: .package) }
        var tooLarge = false
        var seen = Set<String>()
        for type in offered + ImportedStillImage.contentTypes where seen.insert(type.identifier).inserted {
            guard let data = pasteboard.data(forPasteboardType: type.identifier), !data.isEmpty,
                  ImageFileFormat.detect(data) != .video else { continue }
            guard data.count <= ImageCompression.maximumSourceBytes else { tooLarge = true; continue }
            return data
        }
        if tooLarge { throw ImageImportError.fileTooLarge }
        guard let data = pasteboard.image?.pngData() else { throw ImageImportError.missingClipboard }
        return data
    }
}

@MainActor
extension EditorModel {
    func insertImageFile(_ url: URL, pageID: UUID) {
        guard writable, !busy, notebook.pages.contains(where: { $0.id == pageID }) else { return }
        let access = url.startAccessingSecurityScopedResource()
        insertImage(pageID: pageID) {
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            return try await Task.detached { try ImageImport.read(url) }.value
        }
    }

    func insertPhoto(_ item: PhotosPickerItem, pageID: UUID) {
        insertImage(pageID: pageID) { try await ImageImport.photo(item) }
    }

    func pasteImage(pageID: UUID) {
        insertImage(pageID: pageID) { try ImageImport.clipboardImage(UIPasteboard.general) }
    }

    private func insertImage(pageID: UUID, read: @escaping @MainActor () async throws -> Data) {
        guard writable, !busy, let target = notebook.pages.first(where: { $0.id == pageID }) else { return }
        let generation = pageContentGeneration
        busy = true
        Task {
            defer { busy = false }
            await awaitMutationAccess()
            do {
                let source = try await read()
                // Over 5 MB, beyond the pixel limit or larger than the notebook's
                // remaining image budget: compressed instead of refused.
                let room = ImageLimits.maximumNotebookBytes - notebook.imageOriginalBytes
                // Almost no room left: the notebook-full message below explains it better.
                let limit = room >= ImageCompression.minimumBudget ? min(ImageCompression.importTargetBytes, room) : ImageCompression.importTargetBytes
                let fitted = try await Task.detached { try ImageCompression.fitting(source, limit: limit) }.value
                let data = fitted.data
                // Limits first: a clear message instead of a failed validation.
                if let problem = notebook.imageInsertionProblem(bytes: data.count, pageID: pageID) {
                    throw ImageImportError(problem)
                }
                let object = try await Task.detached { try ImageImport.object(data, in: target.textBounds) }.value
                guard writable, generation == pageContentGeneration,
                      let current = notebook.pages.first(where: { $0.id == pageID }), current.textBounds == target.textBounds else {
                    throw PageOperationError.missingPage
                }
                updateImages((current.images ?? []) + [object], pageID: pageID)
                if let original = fitted.originalBytes {
                    fileStatus = "Bild verkleinert eingefügt (\(ImageLimits.megabytes(original)) → \(ImageLimits.megabytes(data.count)))"
                }
            } catch { self.error = "Bild nicht eingefügt: \(error.localizedDescription)" }
        }
    }
}
