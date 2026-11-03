import Foundation

/// Why a Bereich (area) was not removed; German text for the UI.
public enum WorkspaceRemovalError: Error, Equatable, LocalizedError {
    /// „Meine Bibliothek“ (`Documents/Noty`) holds the real notes.
    case mainLibrary
    /// At least one area always remains.
    case lastArea
    /// The open area has to be left (to „Meine Bibliothek“) first.
    case activeArea
    /// Not (or no longer) a listed, readable area.
    case unavailable
    /// The folder failed the path checks (symbolic link, not directly inside
    /// `Areas`, a protected root): nothing was deleted.
    case unsafeLocation
    /// A check or the move out of `Areas` failed: nothing was deleted.
    case notRemoved
    /// The area is gone from the list, but some of its files are still on disk.
    case leftoverFiles

    public var errorDescription: String? {
        switch self {
        case .mainLibrary: "„Meine Bibliothek“ enthält die eigentlichen Hefte und kann nicht entfernt werden."
        case .lastArea: "Der letzte Bereich kann nicht entfernt werden."
        case .activeArea: "Der geöffnete Bereich kann nicht entfernt werden. Bitte zuerst zu „Meine Bibliothek“ wechseln."
        case .unavailable: "Dieser Bereich ist nicht mehr verfügbar. Bitte die Liste neu laden."
        case .unsafeLocation: "Der Ordner dieses Bereichs liegt nicht am erwarteten Ort. Aus Sicherheitsgründen wurde nichts gelöscht."
        case .notRemoved: "Der Bereich konnte nicht entfernt werden. Es wurde nichts gelöscht."
        case .leftoverFiles: "Der Bereich wurde entfernt, einige seiner Dateien aber noch nicht gelöscht. noty löscht sie beim nächsten Start."
        }
    }
}

/// What the confirmation names before an area is removed.
public struct WorkspaceRemovalSummary: Equatable, Identifiable, Sendable {
    public let workspace: TestWorkspace
    /// Notebooks of the area: every notebook of its index (trash included) plus
    /// notebook packages on disk that the index does not list yet.
    public let notebooks: Int
    /// Notebooks in the area's trash (directly or inside a deleted folder).
    public let trashedNotebooks: Int
    /// False if the area's library index could not be read; `notebooks` then
    /// only counts the packages found on disk.
    public let indexReadable: Bool
    public var id: UUID { workspace.id }
}

/// Rules for removing a Bereich. Only separate areas below
/// `NotyWorkspaces/Areas/` can ever be removed.
public enum WorkspaceRemoval {
    /// `target` nil is „Meine Bibliothek“; `areaCount` counts every area,
    /// „Meine Bibliothek“ included. Nil means the removal is allowed.
    public static func blocker(target: UUID?, active: UUID?, areaCount: Int) -> WorkspaceRemovalError? {
        guard let target else { return .mainLibrary }
        guard areaCount > 1 else { return .lastArea }
        guard target != active else { return .activeArea }
        return nil
    }

    /// The only directory a removal may delete: `<workspaceRoot>/Areas/<UUID>`
    /// with the canonical UUID name, a real directory directly inside the real
    /// `Areas` directory, no symbolic link on the way up to `workspaceRoot`, and
    /// neither equal to, inside of, nor containing a protected root (the main
    /// library). Never anything outside `workspaceRoot`.
    public static func directory(for id: UUID, workspaceRoot: URL, protecting protected: [URL]) throws -> URL {
        let base = workspaceRoot.standardizedFileURL
        let areas = base.appendingPathComponent("Areas", isDirectory: true)
        let folder = areas.appendingPathComponent(id.uuidString, isDirectory: true).standardizedFileURL
        guard folder.lastPathComponent == id.uuidString,
              folder.deletingLastPathComponent().standardizedFileURL.path == areas.path,
              folder.path.hasPrefix(base.path + "/") else { throw WorkspaceRemovalError.unsafeLocation }
        // Missing (also a dangling link): nothing to remove here.
        guard (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey])) != nil else { throw WorkspaceRemovalError.unavailable }
        do { try ContainedDirectory.require(folder, below: base) } catch { throw WorkspaceRemovalError.unsafeLocation }
        for root in protected {
            let path = root.standardizedFileURL.path
            if folder.path == path || folder.path.hasPrefix(path + "/") || path.hasPrefix(folder.path + "/") {
                throw WorkspaceRemovalError.unsafeLocation
            }
        }
        return folder
    }
}
