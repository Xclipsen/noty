import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// One sealed file per device in `<data>/devices/<id>.sealed`. Writes go to
/// a temporary file in the same directory (0600, fsync), then `rename`,
/// then fsync of the directory: a crash leaves the old or the new file,
/// never a mix. Only the running service writes (one process, one actor).
public struct DeviceStore: Sendable {
    public let directory: String
    let keyring: DataKeyring

    public init(dataDirectory: String, keyring: DataKeyring) throws {
        directory = dataDirectory + "/devices"
        self.keyring = keyring
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory) {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } else if !isDirectory.boolValue { throw PushError.storage("devices ist keine Ablage") }
    }

    static func isValidID(_ id: String) -> Bool {
        UUID(uuidString: id) != nil && id == id.lowercased()
    }

    func path(_ id: String) -> String { directory + "/" + id + ".sealed" }

    /// All readable devices. Unreadable files are reported and skipped (never deleted).
    public func loadAll() -> (records: [DeviceRecord], problems: [String]) {
        var records: [DeviceRecord] = []
        var problems: [String] = []
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        for name in names.sorted() where name.hasSuffix(".sealed") {
            let id = String(name.dropLast(".sealed".count))
            guard Self.isValidID(id) else { continue }
            do { records.append(try load(id)) } catch { problems.append("\(Log.device(id)): \(error)") }
        }
        return (records, problems)
    }

    public func load(_ id: String) throws -> DeviceRecord {
        guard Self.isValidID(id) else { throw PushError.storage("ungültige Geräte-ID") }
        let sealed = try Data(contentsOf: URL(fileURLWithPath: path(id)))
        guard sealed.count <= 32_000_000 else { throw PushError.storage("Gerätedatei zu groß") }
        let plain = try keyring.open(sealed, context: "device/" + id)
        let decoder = JSONDecoder()
        let record = try decoder.decode(DeviceRecord.self, from: plain)
        guard record.id == id else { throw PushError.storage("Geräte-ID passt nicht zur Datei") }
        return try record.validated()
    }

    public func save(_ record: DeviceRecord) throws {
        guard Self.isValidID(record.id) else { throw PushError.storage("ungültige Geräte-ID") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let sealed = try keyring.seal(try encoder.encode(record), context: "device/" + record.id)
        try Self.atomicWrite(sealed, to: path(record.id), directory: directory)
    }

    public func delete(_ id: String) throws {
        guard Self.isValidID(id) else { throw PushError.storage("ungültige Geräte-ID") }
        if unlink(path(id)) != 0 && errno != ENOENT { throw PushError.storage("Löschen fehlgeschlagen (\(errno))") }
        Self.syncDirectory(directory)
    }

    static func atomicWrite(_ data: Data, to destination: String, directory: String) throws {
        let temporary = directory + "/.tmp-" + UUID().uuidString.lowercased()
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw PushError.storage("Anlegen fehlgeschlagen (\(errno))") }
        var ok = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 { if errno == EINTR { continue }; return false }
                offset += written
            }
            return true
        }
        ok = ok && fsync(fd) == 0
        close(fd)
        guard ok, rename(temporary, destination) == 0 else {
            unlink(temporary)
            throw PushError.storage("Schreiben fehlgeschlagen (\(errno))")
        }
        syncDirectory(directory)
    }

    static func syncDirectory(_ directory: String) {
        let fd = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if fd >= 0 { _ = fsync(fd); close(fd) }
    }

    /// Leftover temporary files of an interrupted write.
    public func removeTemporaryFiles() {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] where name.hasPrefix(".tmp-") {
            unlink(directory + "/" + name)
        }
    }
}
