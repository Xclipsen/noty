import SwiftUI
import PhotosUI
import _PhotosUI_SwiftUI
import CoreTransferable
import UniformTypeIdentifiers
import NotebookCore

/// File transfer avoids loading an unbounded Photos payload into Data first.
private struct ImportedImage: Transferable, Sendable {
    let data: Data
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            ImportedImage(data: try ImageImport.read(received.file))
        }
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
        insertImage(pageID: pageID) {
            guard let imported = try await item.loadTransferable(type: ImportedImage.self) else { throw ImageImportError.invalid }
            return imported.data
        }
    }

    func pasteImage(pageID: UUID) {
        insertImage(pageID: pageID) {
            let clipboard = UIPasteboard.general
            for type in [UTType.png, .jpeg, .heic, .tiff, .gif] {
                if let data = clipboard.data(forPasteboardType: type.identifier) { return data }
            }
            guard let data = clipboard.image?.pngData() else { throw ImageImportError.missingClipboard }
            return data
        }
    }

    private func insertImage(pageID: UUID, read: @escaping @MainActor () async throws -> Data) {
        guard writable, !busy, let target = notebook.pages.first(where: { $0.id == pageID }) else { return }
        let generation = pageContentGeneration
        busy = true
        Task {
            defer { busy = false }
            await awaitMutationAccess()
            do {
                let data = try await read()
                let object = try await Task.detached { try ImageImport.object(data, in: target.textBounds) }.value
                guard writable, generation == pageContentGeneration,
                      let current = notebook.pages.first(where: { $0.id == pageID }), current.textBounds == target.textBounds else {
                    throw PageOperationError.missingPage
                }
                updateImages((current.images ?? []) + [object], pageID: pageID)
            } catch { self.error = "Bild nicht eingefügt: \(error.localizedDescription)" }
        }
    }
}
