import Foundation

/// Names of notebooks that enter a library area as a new entry (import of a
/// `.noty`/`.notybackup` file, copy of a local history state). The title of
/// the file is kept exactly; only when it is already used does it become
/// „Titel (1)“, „Titel (2)“ … (instead of the former „(Wiederhergestellt)“).
///
/// Scope (decided 22.10.2026): the titles of all *active* notebooks of the
/// same library area (every folder, without the library trash, without
/// folders). Library search, pins and recents show notebooks across folders,
/// so equal names in different folders are just as confusing; entries in the
/// trash are invisible and must not push a name to „(1)“: replacing an
/// existing notebook moves it to the trash and the import takes its title.
/// Comparison ignores case and Unicode normalisation („Bio“ = „bio“).
public enum NotebookTitles {
    public static let maximumLength = 120
    public static let fallback = "Unbenanntes Heft"

    /// A valid library title (`LibraryStore.validTitle`) from a file's title:
    /// control characters (line breaks) become spaces, surrounding white space
    /// is trimmed, at most 120 characters; empty becomes „Unbenanntes Heft“.
    public static func sanitized(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            scalars.append(CharacterSet.controlCharacters.contains(scalar) ? " " : scalar)
        }
        var name = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        if name.count > maximumLength { name = String(name.prefix(maximumLength)).trimmingCharacters(in: .whitespacesAndNewlines) }
        return name.isEmpty ? fallback : name
    }

    /// `raw` (sanitized) if no title in `taken` matches, otherwise the first
    /// free „Titel (n)“ with n ≥ 1. A title that already carries a number of
    /// a series („Bio (1)“ while „Bio“ exists) continues that series („Bio (2)“)
    /// instead of nesting („Bio (1) (1)“); a number that is part of the name
    /// itself („Klasse (10)“ without „Klasse“) stays. The result never exceeds
    /// 120 characters: the stem is shortened, never the number.
    public static func unique(_ raw: String, taken: some Sequence<String>) -> String {
        let title = sanitized(raw)
        let used = Set(taken.map(key))
        guard used.contains(key(title)) else { return title }
        var stem = title
        if let numbered = seriesStem(title), used.contains(key(numbered)) { stem = numbered }
        var number = 1
        while true {
            let suffix = " (\(number))"
            let head = String(stem.prefix(maximumLength - suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = (head.isEmpty ? String(fallback.prefix(maximumLength - suffix.count)) : head) + suffix
            if !used.contains(key(candidate)) { return candidate }
            number += 1
        }
    }

    static func key(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping.lowercased()
    }

    /// „Bio (12)“ → „Bio“; nil without a trailing positive number in parentheses.
    static func seriesStem(_ title: String) -> String? {
        guard title.hasSuffix(")"), let open = title.lastIndex(of: "(") else { return nil }
        let digits = title[title.index(after: open)..<title.index(before: title.endIndex)]
        guard !digits.isEmpty, digits.count <= 6, digits.allSatisfy({ $0.isASCII && $0.isNumber }), digits.first != "0" else { return nil }
        let stem = title[..<open]
        guard stem.hasSuffix(" ") else { return nil }
        let trimmed = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The shared/exported notebook file: `.notybackup` format 2 unchanged in its
/// content, only written with the extension `.noty` (UTType `de.la.noty.document`).
/// `.notybackup` files stay importable.
public enum NotyFile {
    public static let fileExtension = "noty"
    public static let legacyExtension = "notybackup"
    /// Both extensions of a single-notebook file (lower case).
    public static let notebookExtensions: Set<String> = [fileExtension, legacyExtension]
    static let maximumStemBytes = 200

    /// File name stem for `<Titel>.noty`: path separators, `:` and characters
    /// that other systems refuse (`\ ? * " < > |`) become „-“, control
    /// characters (line breaks) spaces; leading dots and surrounding white space are removed (no
    /// hidden file), at most 200 UTF-8 bytes (file systems allow 255 per
    /// name). An empty result becomes „Heft“.
    public static func fileStem(for title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?*\"<>|")
        var scalars = String.UnicodeScalarView()
        for scalar in title.unicodeScalars {
            scalars.append(CharacterSet.controlCharacters.contains(scalar) ? " " : forbidden.contains(scalar) ? "-" : scalar)
        }
        var stem = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        while stem.hasPrefix(".") { stem.removeFirst(); stem = stem.trimmingCharacters(in: .whitespacesAndNewlines) }
        while stem.utf8.count > maximumStemBytes { stem.removeLast() }
        stem = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        return stem.isEmpty ? "Heft" : stem
    }

    public static func fileName(for title: String) -> String { fileStem(for: title) + "." + fileExtension }
}

extension LibrarySnapshot {
    /// Titles of the active notebooks (not in the trash, no folders); the
    /// collision scope of `NotebookTitles.unique`. `excluding`: an entry
    /// that is about to move to the trash (replace on import).
    public func activeNotebookTitles(excluding: UUID? = nil) -> [String] {
        items.filter { !$0.isFolder && $0.id != excluding && !isTrashed($0.id) }.map(\.title)
    }

    /// The active notebook with this document ID, if any (import of a file
    /// whose notebook already exists in this area).
    public func activeNotebook(_ id: UUID) -> LibraryItem? {
        items.first { $0.id == id && !$0.isFolder && !isTrashed($0.id) }
    }
}

/// Import of a `.noty`/`.notybackup` file into a library area as a normal
/// notebook (not a restored copy, not under „Wiederhergestellte Kopien“).
public enum NotebookImport {
    public struct Result: Sendable {
        public let snapshot: LibrarySnapshot
        public let id: UUID
        public let title: String
    }

    /// After the UI validated `prepared` (PDFKit/PencilKit, images): commits
    /// the staged copy (new document identity, title exactly from the file or
    /// „Titel (n)“) as a new package `Library/Documents/<id>` of `library`,
    /// read back by the repository, then adopts it into the index. The stage
    /// belongs to `repository` (`NotebookRepository(directory: library.root)`).
    /// `replacing`: see `LibraryStore.adoptImported`; its title does not count
    /// as taken because it moves to the trash.
    public static func commit(_ prepared: PreparedRestore, repository: NotebookRepository, library: LibraryStore,
                              parentID: UUID?, replacing: UUID?) async throws -> Result {
        let current = try await library.load().snapshot
        if let replacing, current.activeNotebook(replacing) == nil { throw LibraryError.unavailable }
        let title = NotebookTitles.unique(prepared.document.title, taken: current.activeNotebookTitles(excluding: replacing))
        let documents = library.root.appendingPathComponent("Library/Documents", isDirectory: true)
        let committed = try await repository.commitRestore(prepared, title: title, into: documents)
        let snapshot = try await library.adoptImported(committed.id, title: title, parentID: parentID, replacing: replacing)
        return Result(snapshot: snapshot, id: committed.id, title: title)
    }
}
