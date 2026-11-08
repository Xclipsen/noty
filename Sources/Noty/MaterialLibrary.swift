import SwiftUI
import UIKit
import UniformTypeIdentifiers
import NotebookCore

/// Learning material of this device (docs/LERNFELDER.md): imported
/// `.notymaterial` packages under `Documents/NotyMaterials/<id>/`, for every
/// area alike, like the law collection. Source data, not user content: not in
/// library backups (the package file is the backup); what the calendar pins
/// keeps a text snapshot. One import at a time.
@MainActor
final class MaterialLibrary: ObservableObject {
    static let shared = MaterialLibrary()
    static let root = URL.documentsDirectory.appendingPathComponent("NotyMaterials", isDirectory: true)

    @Published private(set) var packages: [MaterialStore.Installed] = []
    @Published private(set) var importing = false
    /// Search form of the page texts, built in the background after loading.
    private var indexes: [String: MaterialTextIndex] = [:]
    private let store = MaterialStore(root: MaterialLibrary.root)
    private var loaded = false

    private init() {}

    func load() {
        guard !loaded else { return }
        loaded = true
        reload()
    }

    private func reload() {
        let store = store
        Task {
            let found = await Task.detached(priority: .utility) { () -> [MaterialStore.Installed] in
                store.cleanUp()
                return store.installed()
            }.value
            packages = found
            indexes = [:]
            for package in found { buildIndex(package) }
        }
    }

    private func buildIndex(_ package: MaterialStore.Installed) {
        let store = store
        Task {
            let index = await Task.detached(priority: .utility) { store.texts(of: package).map(MaterialTextIndex.init) }.value
            if let index, packages.contains(where: { $0.catalog.id == package.catalog.id }) { indexes[package.catalog.id] = index }
        }
    }

    var catalogs: [MaterialCatalog] { packages.map(\.catalog) }
    func package(_ id: String) -> MaterialStore.Installed? { packages.first { $0.catalog.id == id } }


    // MARK: Search and pins

    struct Match: Identifiable, Equatable, Sendable {
        var id: String { package + "/" + hit.id }
        let package: String
        let hit: MaterialHit
    }

    /// Off the main thread: the page texts of a package are thousands of pages.
    func search(_ query: String, field: Int? = nil, limit: Int = 40) async -> [Match] {
        load()
        let key = MaterialSearch.normalize(query)
        let work = packages.map { ($0.catalog, indexes[$0.catalog.id], pinned(for: key, package: $0.catalog.id)) }
        return await Task.detached(priority: .userInitiated) { () -> [Match] in
            var results: [Match] = []
            for (catalog, index, preferred) in work {
                results += MaterialSearch.search(query, in: catalog, index: index, preferred: preferred, field: field, limit: limit)
                    .map { Match(package: catalog.id, hit: $0) }
            }
            return Array(results.sorted { $0.hit.score > $1.hit.score }.prefix(limit))
        }.value
    }

    /// A pinned hit for `query` ranks first next time („Festhalten“ lernt).
    func learn(_ query: String, result: Match) {
        let key = MaterialSearch.normalize(query)
        guard !key.isEmpty else { return }
        var all = UserDefaults.standard.dictionary(forKey: pinsKey(result.package)) as? [String: [String]] ?? [:]
        var list = all[key] ?? []
        list.removeAll { $0 == result.hit.id }
        list.insert(result.hit.id, at: 0)
        all[key] = Array(list.prefix(5))
        if all.count > 2_000 { all.removeValue(forKey: all.keys.sorted().first!) }
        UserDefaults.standard.set(all, forKey: pinsKey(result.package))
    }

    private func pinned(for key: String, package: String) -> [String] {
        (UserDefaults.standard.dictionary(forKey: pinsKey(package)) as? [String: [String]])?[key] ?? []
    }
    private func pinsKey(_ package: String) -> String { "noty.v2.materialPins.\(package)" }

    func reference(for result: Match) -> CalendarMaterialRef? {
        guard let catalog = package(result.package)?.catalog else { return nil }
        return CalendarMaterialRef(package: result.package, key: result.hit.id, label: result.hit.title,
                                   detail: Self.detail(result.hit, in: catalog))
    }

    func result(for ref: CalendarMaterialRef) -> Match? {
        guard let catalog = package(ref.package)?.catalog, let hit = MaterialSearch.hit(forKey: ref.key, in: catalog) else { return nil }
        return Match(package: ref.package, hit: hit)
    }

    /// „LF 3 · Kapitel 4 · S. 5–9“
    static func detail(_ hit: MaterialHit, in catalog: MaterialCatalog) -> String {
        var parts = ["LF \(hit.field)"]
        if let (_, chapter) = catalog.chapter(hit.chapterKey) { parts.append(chapter.label) }
        if let pages = hit.pages { parts.append(pages.count == 1 ? "S. \(pages.lowerBound)" : "S. \(pages.lowerBound)–\(pages.upperBound)") }
        return parts.joined(separator: " · ")
    }

    func lessonLink(_ result: Match) -> URL? {
        guard let id = result.hit.lessonID else { return nil }
        return package(result.package)?.catalog.lessonLink(id)
    }

    func script(_ result: Match) -> (url: URL, title: String)? {
        guard let package = package(result.package), let (_, chapter) = package.catalog.chapter(result.hit.chapterKey),
              let script = chapter.script else { return nil }
        let url = package.scriptURL(script)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return (url, "LF \(result.hit.field) · \(chapter.label) \(chapter.title)")
    }

    // MARK: Import and removal

    /// A `.notymaterial` file opened from outside or chosen in the settings:
    /// copied in, checked completely, then installed (replacing the same id).
    func receive(_ url: URL) async {
        guard !importing else { TopAlert.show("Materialien", "Ein Materialpaket wird gerade übernommen. Bitte danach erneut öffnen."); return }
        importing = true
        defer { importing = false; IncomingBackup.removeFromInbox(url) }
        let progress = TopAlert.progress("Materialpaket wird geprüft …")
        let copy: URL
        do {
            copy = try BackupScratch.newFile("notymaterial")
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            try await Task.detached(priority: .userInitiated) {
                try CoordinatedBackupFiles().reading(url, metadataOnly: false) { source in
                    _ = try BoundedFile.copy(from: source, to: copy, limit: Int(MaterialPackageReader.maximumPackageBytes))
                }
            }.value
        } catch {
            await TopAlert.dismiss(progress)
            TopAlert.show("Materialpaket nicht lesbar", "Die Datei konnte nicht in noty kopiert werden. Es wurde nichts verändert.")
            return
        }
        defer { BackupScratch.remove(copy) }
        let store = store
        let result = await Task.detached(priority: .userInitiated) { () -> Swift.Result<MaterialStore.Installed, Error> in
            do { return .success(try store.install(copy)) } catch { return .failure(error) }
        }.value
        await TopAlert.dismiss(progress)
        switch result {
        case .success(let installed):
            indexes[installed.catalog.id] = nil
            packages = store.installed()
            buildIndex(installed)
            let catalog = installed.catalog
            let lessons = catalog.fields.reduce(0) { $0 + $1.chapters.reduce(0) { $0 + $1.lessons.count } }
            TopAlert.show("Materialien übernommen",
                          "„\(catalog.title)“: \(catalog.fields.count) Lernfelder, \(catalog.scripts.count) Skripte, \(lessons) Videolektionen. "
                          + "Im Kalender unter Einstellungen › Kalender › Lernfelder lassen sich die Lernfelder daraus übernehmen.")
        case .failure(let error):
            TopAlert.show("Materialpaket nicht übernommen", (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func remove(_ id: String) {
        let store = store
        indexes[id] = nil
        packages.removeAll { $0.catalog.id == id }
        Task {
            let failure = await Task.detached(priority: .utility) { () -> String? in
                do { try store.remove(id); return nil } catch { return error.localizedDescription }
            }.value
            if let failure { TopAlert.show("Materialien", "Das Paket konnte nicht vollständig entfernt werden: \(failure)"); reload() }
        }
    }

    static func isPackage(_ url: URL) -> Bool { url.isFileURL && url.pathExtension.lowercased() == "notymaterial" }

    /// Bytes on disk of an installed package (shown in the settings).
    nonisolated static func size(of directory: URL) -> Int64 {
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files { total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        return total
    }
}

extension UTType {
    /// `.notymaterial`: a learning-material package (docs/LERNFELDER.md).
    static let notyMaterial = UTType(exportedAs: "de.la.noty.material", conformingTo: .data)
}
