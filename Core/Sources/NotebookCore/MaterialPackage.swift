import Foundation

/// Reads a `.notymaterial` file: a ZIP with stored (uncompressed) entries
/// `catalog.json`, optional `text.json` and `pdf/<script>` for every script
/// of the catalogue. Anything else (compression, ZIP64, encryption, other
/// names, sizes beyond the limits, a script whose SHA-256 differs) refuses
/// the whole package; nothing is installed partially.
public struct MaterialPackageReader {
    public static let maximumEntries = 2_000
    public static let maximumCatalogBytes = 20_000_000
    public static let maximumTextBytes = 80_000_000
    public static let maximumPackageBytes: UInt64 = 2_000_000_000

    struct Entry { var name: String; var offset: UInt64; var size: UInt64; var crc: UInt32 }

    let url: URL
    let entries: [String: Entry]

    public init(url: URL) throws {
        self.url = url
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        guard length >= 22, length <= Self.maximumPackageBytes else { throw MaterialError.notAPackage }
        // End of central directory: in the last 22 + 65535 bytes.
        let tail = min(length, 22 + 65_535)
        try handle.seek(toOffset: length - tail)
        let end = try handle.read(upToCount: Int(tail)) ?? Data()
        guard let eocd = Self.lastIndex(of: [0x50, 0x4B, 0x05, 0x06], in: end) else { throw MaterialError.notAPackage }
        let count = Int(Self.u16(end, eocd + 10)), size = UInt64(Self.u32(end, eocd + 12)), start = UInt64(Self.u32(end, eocd + 16))
        guard Self.u16(end, eocd + 4) == 0, Self.u16(end, eocd + 6) == 0, count <= Self.maximumEntries,
              count != 0xFFFF, start != 0xFFFF_FFFF, start + size <= length else { throw MaterialError.notAPackage }
        try handle.seek(toOffset: start)
        let directory = try handle.read(upToCount: Int(size)) ?? Data()
        guard directory.count == Int(size) else { throw MaterialError.notAPackage }
        var entries: [String: Entry] = [:], cursor = 0
        for _ in 0..<count {
            guard cursor + 46 <= directory.count, Self.u32(directory, cursor) == 0x0201_4B50 else { throw MaterialError.notAPackage }
            let flags = Self.u16(directory, cursor + 8), method = Self.u16(directory, cursor + 10)
            let crc = Self.u32(directory, cursor + 16)
            let compressed = UInt64(Self.u32(directory, cursor + 20)), plain = UInt64(Self.u32(directory, cursor + 24))
            let nameLength = Int(Self.u16(directory, cursor + 28)), extra = Int(Self.u16(directory, cursor + 30))
            let comment = Int(Self.u16(directory, cursor + 32))
            let local = UInt64(Self.u32(directory, cursor + 42))
            guard cursor + 46 + nameLength + extra + comment <= directory.count else { throw MaterialError.notAPackage }
            let nameData = directory.subdata(in: (cursor + 46)..<(cursor + 46 + nameLength))
            cursor += 46 + nameLength + extra + comment
            guard let name = String(data: nameData, encoding: .utf8) else { throw MaterialError.notAPackage }
            if name.hasSuffix("/") { continue } // directory entry
            guard flags & 0x1 == 0 else { throw MaterialError.invalid("verschlüsselt") }
            guard method == 0, compressed == plain, compressed != 0xFFFF_FFFF, local != 0xFFFF_FFFF else {
                throw MaterialError.invalid("komprimierter Eintrag \(name)")
            }
            guard name == "catalog.json" || name == "text.json"
                    || (name.hasPrefix("pdf/") && MaterialCatalog.isSafeFile(String(name.dropFirst(4)))) else {
                throw MaterialError.invalid("unerwarteter Eintrag \(name)")
            }
            // Data starts after the local header with its own name/extra lengths.
            try handle.seek(toOffset: local)
            let header = try handle.read(upToCount: 30) ?? Data()
            guard header.count == 30, Self.u32(header, 0) == 0x0403_4B50 else { throw MaterialError.notAPackage }
            let dataStart = local + 30 + UInt64(Self.u16(header, 26)) + UInt64(Self.u16(header, 28))
            guard dataStart + compressed <= start, entries[name] == nil else { throw MaterialError.notAPackage }
            entries[name] = Entry(name: name, offset: dataStart, size: compressed, crc: crc)
        }
        self.entries = entries
    }

    func data(_ name: String, limit: Int) throws -> Data {
        guard let entry = entries[name] else { throw MaterialError.missingFile(name) }
        guard entry.size <= UInt64(limit) else { throw MaterialError.invalid("\(name) zu groß") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: entry.offset)
        let data = try handle.read(upToCount: Int(entry.size)) ?? Data()
        guard data.count == Int(entry.size), StreamingCRC32.checksum(data) == entry.crc else { throw MaterialError.checksumMismatch(name) }
        return data
    }

    /// Copies an entry to `destination`, checking its length and SHA-256.
    func extract(_ name: String, to destination: URL, sha256: String, byteCount: Int) throws {
        guard let entry = entries[name] else { throw MaterialError.missingFile(name) }
        guard entry.size == UInt64(byteCount) else { throw MaterialError.checksumMismatch(name) }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        try input.seek(toOffset: entry.offset)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var hasher = SHA256Stream(), remaining = entry.size
        while remaining > 0 {
            let chunk = try input.read(upToCount: Int(min(remaining, 1 << 20))) ?? Data()
            guard !chunk.isEmpty else { throw MaterialError.checksumMismatch(name) }
            hasher.update(chunk); try output.write(contentsOf: chunk)
            remaining -= UInt64(chunk.count)
        }
        try output.synchronize()
        guard hasher.finalizeHex() == sha256 else { throw MaterialError.checksumMismatch(name) }
    }

    public func catalog() throws -> MaterialCatalog {
        let bytes = try data("catalog.json", limit: Self.maximumCatalogBytes)
        struct Header: Decodable { var format: Int }
        guard let header = try? JSONDecoder().decode(Header.self, from: bytes) else { throw MaterialError.notAPackage }
        guard header.format <= MaterialCatalog.currentFormat else { throw MaterialError.unsupportedFormat(header.format) }
        let catalog: MaterialCatalog
        do { catalog = try JSONDecoder().decode(MaterialCatalog.self, from: bytes) } catch { throw MaterialError.invalid("Katalog") }
        try catalog.validate()
        return catalog
    }

    public func texts(for catalog: MaterialCatalog) throws -> MaterialTexts? {
        guard entries["text.json"] != nil else { return nil }
        let texts: MaterialTexts
        do { texts = try JSONDecoder().decode(MaterialTexts.self, from: try data("text.json", limit: Self.maximumTextBytes)) }
        catch let error as MaterialError { throw error }
        catch { throw MaterialError.invalid("Texte") }
        try texts.validate(against: catalog)
        return texts
    }

    static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return UInt16(data[base]) | UInt16(data[base + 1]) << 8
    }
    static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(u16(data, offset)) | UInt32(u16(data, offset + 2)) << 16
    }
    static func lastIndex(of pattern: [UInt8], in data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard bytes.count >= pattern.count + 18 else { return nil }
        var index = bytes.count - 22
        while index >= 0 {
            if Array(bytes[index..<(index + 4)]) == pattern { return index }
            index -= 1
        }
        return nil
    }
}

/// Installed material packages: `<root>/<package id>/catalog.json`,
/// `text.json`, `pdf/…`. One package per id; installing again replaces it
/// only after the new one is complete and checked (staging + rename).
public struct MaterialStore: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }

    public struct Installed: Equatable, Sendable {
        public var catalog: MaterialCatalog
        public var directory: URL
        public func scriptURL(_ script: MaterialScript) -> URL {
            directory.appendingPathComponent("pdf", isDirectory: true).appendingPathComponent(script.file)
        }
    }

    public func installed() -> [Installed] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.sorted().compactMap { name in
            guard MaterialCatalog.isIdentifier(name) else { return nil }
            let directory = root.appendingPathComponent(name, isDirectory: true)
            guard let bytes = try? Data(contentsOf: directory.appendingPathComponent("catalog.json")),
                  let catalog = try? JSONDecoder().decode(MaterialCatalog.self, from: bytes),
                  (try? catalog.validate()) != nil, catalog.id == name else { return nil }
            return Installed(catalog: catalog, directory: directory)
        }
    }

    public func texts(of installed: Installed) -> MaterialTexts? {
        guard let bytes = try? Data(contentsOf: installed.directory.appendingPathComponent("text.json")),
              let texts = try? JSONDecoder().decode(MaterialTexts.self, from: bytes),
              (try? texts.validate(against: installed.catalog)) != nil else { return nil }
        return texts
    }

    /// Checks the whole package, copies it into a staging folder and only
    /// then replaces an installed package of the same id.
    @discardableResult
    public func install(_ package: URL) throws -> Installed {
        let fm = FileManager.default
        let reader = try MaterialPackageReader(url: package)
        let catalog = try reader.catalog()
        let texts = try reader.texts(for: catalog)
        let expected = Set(catalog.scripts.map { "pdf/" + $0.file })
        let present = Set(reader.entries.keys.filter { $0.hasPrefix("pdf/") })
        if let missing = expected.subtracting(present).sorted().first { throw MaterialError.missingFile(missing) }
        if let extra = present.subtracting(expected).sorted().first { throw MaterialError.invalid("unerwarteter Eintrag \(extra)") }

        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let stage = root.appendingPathComponent(".stage-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        do {
            for script in catalog.scripts {
                let target = stage.appendingPathComponent("pdf", isDirectory: true).appendingPathComponent(script.file)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try reader.extract("pdf/" + script.file, to: target, sha256: script.sha256, byteCount: script.byteCount)
            }
            try JSONEncoder().encode(catalog).write(to: stage.appendingPathComponent("catalog.json"), options: .atomic)
            if let texts { try JSONEncoder().encode(texts).write(to: stage.appendingPathComponent("text.json"), options: .atomic) }
            // Read back what will be used.
            guard let check = try? JSONDecoder().decode(MaterialCatalog.self, from: Data(contentsOf: stage.appendingPathComponent("catalog.json"))),
                  check == catalog else { throw MaterialError.invalid("Zurücklesen") }

            let target = root.appendingPathComponent(catalog.id, isDirectory: true)
            var old: URL?
            if fm.fileExists(atPath: target.path) {
                let moved = root.appendingPathComponent(".old-\(UUID().uuidString)", isDirectory: true)
                try fm.moveItem(at: target, to: moved)
                old = moved
            }
            do { try fm.moveItem(at: stage, to: target) }
            catch {
                if let old { try? fm.moveItem(at: old, to: target) }
                throw error
            }
            if let old { try? fm.removeItem(at: old) }
            return Installed(catalog: catalog, directory: target)
        } catch {
            try? fm.removeItem(at: stage)
            throw error
        }
    }

    public func remove(_ id: String) throws {
        guard MaterialCatalog.isIdentifier(id) else { return }
        let target = root.appendingPathComponent(id, isDirectory: true)
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
    }

    /// Leftovers of an interrupted install older than `age` (a running
    /// install is younger). A replaced package whose new one never arrived
    /// (interrupted between both renames) is put back, not deleted.
    public func cleanUp(olderThan age: TimeInterval = 3_600, now: Date = Date()) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        for name in names where name.hasPrefix(".stage-") || name.hasPrefix(".old-") {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            guard now.timeIntervalSince(modified) > age else { continue }
            if name.hasPrefix(".old-"), let bytes = try? Data(contentsOf: folder.appendingPathComponent("catalog.json")),
               let catalog = try? JSONDecoder().decode(MaterialCatalog.self, from: bytes), MaterialCatalog.isIdentifier(catalog.id) {
                let target = root.appendingPathComponent(catalog.id, isDirectory: true)
                if !fm.fileExists(atPath: target.path) { try? fm.moveItem(at: folder, to: target); continue }
            }
            try? fm.removeItem(at: folder)
        }
    }
}
