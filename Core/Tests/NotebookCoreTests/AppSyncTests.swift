import Foundation
import XCTest
@testable import NotebookCore

/// Abgleich zwischen den noty-Apps: die normale noty ist nur Quelle, ihre
/// Bibliothek bleibt Byte für Byte unverändert; Spiegel entstehen als eigene Bereiche.
final class AppSyncTests: XCTestCase {
    private let fm = FileManager.default
    private func temporary() -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent("AppSync-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func tree(_ url: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let base = url.standardizedFileURL.path
        guard let files = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else { return result }
        for case let file as URL in files where (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            result[String(file.standardizedFileURL.path.dropFirst(base.count))] = try Data(contentsOf: file)
        }
        return result
    }
    private func library(_ root: URL, titles: [String]) async throws -> LibraryStore {
        let store = LibraryStore(root: root); _ = try await store.load()
        for title in titles {
            var notebook = Notebook(); notebook.title = title; notebook.pages[0].text = "\(title) · ÄÖÜ ß"
            _ = try await store.createDocument(notebook, parentID: nil)
        }
        return store
    }
    private func archive(_ store: LibraryStore, in folder: URL) async throws -> (URL, LibraryArchiveSummary) {
        let url = folder.appendingPathComponent("\(UUID().uuidString).notylibrary")
        let summary = try LibraryArchive.write(try await store.backupPlan(), to: url)
        return (url, summary)
    }

    func testOnlyTheRealBundleIDIsStableAndStableNeverMirrors() {
        let stable = "XTL-BAFXLQ964V.XTL-BAFXLQ964V.de.la.noty.prototype"
        for declared in [nil, "stable", "dev", "ai", "unsinn"] {
            XCTAssertEqual(AppSyncChannel.resolve(declared: declared, bundleID: stable), .stable)
            XCTAssertEqual(AppSyncChannel.resolve(declared: declared, bundleID: "de.la.noty.prototype"), .stable)
        }
        XCTAssertEqual(AppSyncChannel.stable.mirrors, [])
        XCTAssertEqual(AppSyncChannel.resolve(declared: "dev", bundleID: "XTL-BAFXLQ964V.de.la.noty.dev"), .dev)
        XCTAssertEqual(AppSyncChannel.resolve(declared: "ai", bundleID: "XTL-A.XTL-A.de.la.noty.ai"), .ai)
        XCTAssertEqual(AppSyncChannel.resolve(declared: "calendar", bundleID: "XTL-A.XTL-A.de.la.noty.calendar"), .calendar)
        XCTAssertNil(AppSyncChannel.resolve(declared: "calendar", bundleID: "XTL-A.de.la.noty.ai"))
        XCTAssertEqual(AppSyncChannel.calendar.mirrors, [.stable, .dev])
        XCTAssertFalse(AppSyncChannel.calendar.publishes)
        // Keine andere App gibt sich als noty aus; falsche Paare bleiben ohne Abgleich.
        XCTAssertNil(AppSyncChannel.resolve(declared: "stable", bundleID: "XTL-A.de.la.noty.dev"))
        XCTAssertNil(AppSyncChannel.resolve(declared: "ai", bundleID: "XTL-A.de.la.noty.dev"))
        XCTAssertNil(AppSyncChannel.resolve(declared: nil, bundleID: "XTL-A.de.la.noty.ai"))
        XCTAssertNil(AppSyncChannel.resolve(declared: "dev", bundleID: nil))
        XCTAssertFalse(AppSyncChannel.allCases.contains { $0.mirrors.contains($0) })
        XCTAssertFalse(AppSyncChannel.ai.publishes)
        XCTAssertEqual(ProvisionedIdentifier.groupCandidates("de.la.noty.shared", bundleID: "XTL-BAFXLQ964V.XTL-BAFXLQ964V.de.la.noty.dev"),
                       ["group.XTL-BAFXLQ964V.de.la.noty.shared", "group.de.la.noty.shared"])
    }

    func testPublishWritesManifestLastKeepsPreviousAndOnlyPrunesOwnSnapshots() async throws {
        let base = temporary(), group = base.appendingPathComponent("Group", isDirectory: true)
        try fm.createDirectory(at: group, withIntermediateDirectories: true)
        let store = try await library(base.appendingPathComponent("Noty"), titles: ["Mathe"])
        let folder = AppSyncOutbox.directory(groupRoot: group, channel: .stable)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let foreign = folder.appendingPathComponent("notiz.txt"); try Data("fremd".utf8).write(to: foreign)
        XCTAssertNil(try AppSyncOutbox.read(groupRoot: group, channel: .stable))
        var sequences: [Int] = []
        for _ in 0..<3 {
            let (url, summary) = try await archive(store, in: base)
            let snapshot = try AppSyncOutbox.publish(archive: url, summary: summary, channel: .stable, groupRoot: group)
            XCTAssertEqual(try AppSyncOutbox.read(groupRoot: group, channel: .stable), snapshot)
            XCTAssertEqual(try BoundedFile.checksum(AppSyncOutbox.archiveURL(snapshot, groupRoot: group)), summary.file)
            sequences.append(snapshot.sequence)
        }
        XCTAssertEqual(sequences, [1, 2, 3])
        // Gleicher Inhalt, andere Erstellungszeit: gleicher Schlüssel.
        let one = try await archive(store, in: base).1, two = try await archive(store, in: base).1
        XCTAssertEqual(try AppSyncSnapshot.contentKey(one), try AppSyncSnapshot.contentKey(two))
        let names = Set(try fm.contentsOfDirectory(atPath: folder.path))
        XCTAssertEqual(names, ["current.json", "snapshot-2.notylibrary", "snapshot-3.notylibrary", "notiz.txt"])
        // Spiegel-only apps legen nichts ab; eine geänderte Quelle wird abgelehnt.
        let (url, summary) = try await archive(store, in: base)
        XCTAssertThrowsError(try AppSyncOutbox.publish(archive: url, summary: summary, channel: .ai, groupRoot: group))
        try Data("verändert".utf8).write(to: url)
        XCTAssertThrowsError(try AppSyncOutbox.publish(archive: url, summary: summary, channel: .stable, groupRoot: group))
        XCTAssertEqual(try AppSyncOutbox.read(groupRoot: group, channel: .stable)?.sequence, 3)
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: folder.path).contains { $0.hasSuffix(".partial") })
    }

    func testDamagedOrForeignManifestIsRejected() throws {
        let group = temporary()
        let folder = AppSyncOutbox.directory(groupRoot: group, channel: .dev)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: folder.appendingPathComponent("current.json"))
        XCTAssertThrowsError(try AppSyncOutbox.read(groupRoot: group, channel: .dev))
        let other = AppSyncSnapshot(channel: .stable, sequence: 1, createdAt: Date(), file: .init(byteCount: 10, crc32: 1), notebooks: 1,
                                    content: String(repeating: "a", count: 64))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(other).write(to: folder.appendingPathComponent("current.json"))
        XCTAssertThrowsError(try AppSyncOutbox.read(groupRoot: group, channel: .dev))
    }

    func testMirrorDecision() {
        let area = UUID(), file = LibraryArchiveFileInfo(byteCount: 5, crc32: 7)
        let snapshot = AppSyncSnapshot(channel: .stable, sequence: 4, createdAt: Date(), file: file, notebooks: 2,
                                       content: String(repeating: "b", count: 64))
        let state = AppSyncMirrorState(sequence: 4, content: snapshot.content, area: area, importedAt: Date())
        XCTAssertEqual(AppSyncMirror.decide(nil, state: state, activeArea: nil), .upToDate)
        XCTAssertEqual(AppSyncMirror.decide(snapshot, state: nil, activeArea: nil), .importSnapshot)
        XCTAssertEqual(AppSyncMirror.decide(snapshot, state: state, activeArea: area), .upToDate)
        var older = state; older.content = String(repeating: "c", count: 64)
        XCTAssertEqual(AppSyncMirror.decide(snapshot, state: older, activeArea: area), .waitForArea)
        XCTAssertEqual(AppSyncMirror.decide(snapshot, state: older, activeArea: nil), .importSnapshot)
    }

    /// Ganzer Weg: Quelle legt ab, Spiegel übernimmt als Bereich `mirror` und
    /// ersetzt beim nächsten Stand den alten Spiegel. Die Quellbibliothek ist
    /// danach Byte für Byte unverändert.
    func testMirrorRoundTripLeavesSourceLibraryUntouched() async throws {
        let base = temporary(), group = base.appendingPathComponent("Group", isDirectory: true)
        try fm.createDirectory(at: group, withIntermediateDirectories: true)
        let sourceRoot = base.appendingPathComponent("Source/Documents/Noty", isDirectory: true)
        let source = try await library(sourceRoot, titles: ["Mathe", "Deutsch"])
        let before = try tree(sourceRoot)

        let (url, summary) = try await archive(source, in: base)
        let first = try AppSyncOutbox.publish(archive: url, summary: summary, channel: .stable, groupRoot: group)
        XCTAssertEqual(try tree(sourceRoot), before)
        let mirrorDocuments = base.appendingPathComponent("Mirror/Documents", isDirectory: true)
        let workspaces = WorkspaceStore(root: mirrorDocuments.appendingPathComponent("NotyWorkspaces", isDirectory: true))
        let prepared = try await workspaces.prepareRestore(file: AppSyncOutbox.archiveURL(first, groupRoot: group))
        let area = try await workspaces.commitRestore(prepared, title: "Spiegel von noty", kind: .mirror)
        XCTAssertEqual(area.kind, .mirror)
        let mirrored = try await LibraryStore(root: try await workspaces.directory(for: area.id)).committedSnapshot()
        XCTAssertEqual(Set(mirrored.items.map(\.title)), ["Mathe", "Deutsch"])
        XCTAssertEqual(try tree(sourceRoot), before)

        // Neuer Stand: neuer Spiegelbereich, der alte wird entfernt (nicht geöffnet).
        var notebook = Notebook(); notebook.title = "Physik"
        _ = try await source.createDocument(notebook, parentID: nil)
        let changed = try tree(sourceRoot)
        let (url2, summary2) = try await archive(source, in: base)
        let second = try AppSyncOutbox.publish(archive: url2, summary: summary2, channel: .stable, groupRoot: group)
        let prepared2 = try await workspaces.prepareRestore(file: AppSyncOutbox.archiveURL(second, groupRoot: group))
        let area2 = try await workspaces.commitRestore(prepared2, title: "Spiegel von noty", kind: .mirror)
        try await workspaces.remove(area.id, protecting: [mirrorDocuments.appendingPathComponent("Noty")])
        let listed = try await workspaces.list().workspaces
        XCTAssertEqual(listed.map(\.id), [area2.id])
        let mirrored2 = try await LibraryStore(root: try await workspaces.directory(for: area2.id)).committedSnapshot()
        XCTAssertEqual(Set(mirrored2.items.map(\.title)), ["Mathe", "Deutsch", "Physik"])

        // Ablegen und Spiegeln haben an der Quelle kein Byte verändert.
        XCTAssertEqual(try tree(sourceRoot), changed)
    }
}
