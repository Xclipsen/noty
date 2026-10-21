import Foundation

/// Streaming machinery shared by the archive formats (`.notylibrary`, later
/// `.notybackup` v2): magic + uint32 big-endian header length prefix, sinks and
/// sources that never hold a whole archive, incremental CRC-32 and bounded
/// file access. Formats, limits and error mapping stay with each archive type;
/// nothing here defines or changes bytes on its own.
enum RecordArchive {
    /// Magic (8 bytes) + uint32 BE length.
    static let prefixByteCount = 12

    static func lengthBytes(_ value: Int) -> Data {
        let length = UInt32(value)
        return Data([UInt8(length >> 24), UInt8((length >> 16) & 255), UInt8((length >> 8) & 255), UInt8(length & 255)])
    }

    /// The uint32 BE length at bytes 8..<12 of `prefix` (any Data slice).
    static func length(prefix: Data) -> Int {
        Int(prefix.dropFirst(8).prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
    }
}

/// Source ended before the requested count; archive readers map it to their
/// own "invalid archive" error.
struct RecordArchiveTruncated: Error {}

/// Append-only output; `replace` patches already written bytes (a reserved header).
protocol RecordArchiveSink {
    mutating func append(_ data: Data) throws
    mutating func replace(at offset: Int, with data: Data) throws
}
typealias LibraryArchiveSink = RecordArchiveSink

struct DataSink: RecordArchiveSink {
    var data = Data()
    mutating func append(_ data: Data) { self.data.append(data) }
    mutating func replace(at offset: Int, with data: Data) { self.data.replaceSubrange(offset..<offset + data.count, with: data) }
}

struct FileSink: RecordArchiveSink {
    let handle: FileHandle
    func append(_ data: Data) throws { try handle.write(contentsOf: data) }
    func replace(at offset: Int, with data: Data) throws {
        try handle.seek(toOffset: UInt64(offset)); try handle.write(contentsOf: data); _ = try handle.seekToEnd()
    }
}

protocol RecordArchiveSource {
    var size: Int { get }
    /// Exactly `count` bytes or an error; never more than requested.
    mutating func read(_ count: Int) throws -> Data
    mutating func atEnd() throws -> Bool
}
typealias LibraryArchiveSource = RecordArchiveSource

struct DataSource: RecordArchiveSource {
    let data: Data
    var offset = 0
    var size: Int { data.count }
    mutating func read(_ count: Int) throws -> Data {
        guard count <= data.count - offset else { throw RecordArchiveTruncated() }
        let start = data.startIndex + offset
        offset += count
        return Data(data[start..<start + count])
    }
    func atEnd() -> Bool { offset == data.count }
}

struct FileSource: RecordArchiveSource {
    let handle: FileHandle
    let size: Int
    func read(_ count: Int) throws -> Data {
        var result = Data(capacity: count)
        while result.count < count {
            guard let piece = try handle.read(upToCount: min(BoundedFile.block, count - result.count)), !piece.isEmpty else {
                throw RecordArchiveTruncated()
            }
            result.append(piece)
        }
        return result
    }
    func atEnd() throws -> Bool { (try handle.read(upToCount: 1))?.isEmpty ?? true }
}

/// Reads from a source and keeps the CRC-32 of every byte read so far (the
/// file CRC that binds a streaming summary to the exact archive bytes).
struct ChecksummedReader<Source: RecordArchiveSource> {
    var source: Source
    private(set) var crc = StreamingCRC32()
    init(_ source: Source) { self.source = source }
    var size: Int { source.size }
    mutating func next(_ count: Int) throws -> Data { let data = try source.read(count); crc.update(data); return data }
    mutating func atEnd() throws -> Bool { try source.atEnd() }
}

/// Releases autoreleased Foundation buffers after each record on Apple platforms.
#if canImport(ObjectiveC)
func drained<T>(_ body: () throws -> T) rethrows -> T { try autoreleasepool(invoking: body) }
#else
func drained<T>(_ body: () throws -> T) rethrows -> T { try body() }
#endif

/// Incremental CRC-32/ISO-HDLC (same values as zlib.crc32), slicing-by-8 so
/// multi-hundred-megabyte archives can be checked block by block.
struct StreamingCRC32 {
    private static let table: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 8 * 256)
        for byte in 0..<256 {
            var value = UInt32(byte)
            for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 1 ? 0xedb88320 : 0) }
            table[byte] = value
        }
        for slice in 1..<8 {
            for byte in 0..<256 {
                let previous = table[(slice - 1) * 256 + byte]
                table[slice * 256 + byte] = (previous >> 8) ^ table[Int(previous & 255)]
            }
        }
        return table
    }()
    private var state: UInt32 = 0xffffffff
    var value: UInt32 { state ^ 0xffffffff }

    mutating func update(_ data: Data) { data.withUnsafeBytes { update($0) } }
    mutating func update(_ bytes: UnsafeRawBufferPointer) {
        guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
        var crc = state, index = 0
        let count = bytes.count
        Self.table.withUnsafeBufferPointer { t in
            while index + 8 <= count {
                let one = crc ^ (UInt32(base[index]) | UInt32(base[index + 1]) << 8 | UInt32(base[index + 2]) << 16 | UInt32(base[index + 3]) << 24)
                let two = UInt32(base[index + 4]) | UInt32(base[index + 5]) << 8 | UInt32(base[index + 6]) << 16 | UInt32(base[index + 7]) << 24
                crc = t[1792 + Int(one & 255)] ^ t[1536 + Int((one >> 8) & 255)] ^ t[1280 + Int((one >> 16) & 255)] ^ t[1024 + Int(one >> 24)]
                    ^ t[768 + Int(two & 255)] ^ t[512 + Int((two >> 8) & 255)] ^ t[256 + Int((two >> 16) & 255)] ^ t[Int(two >> 24)]
                index += 8
            }
            while index < count { crc = t[Int((crc ^ UInt32(base[index])) & 255)] ^ (crc >> 8); index += 1 }
        }
        state = crc
    }
    static func checksum(_ data: Data) -> UInt32 { var crc = StreamingCRC32(); crc.update(data); return crc.value }
}

/// Exact byte count and CRC-32 of a complete archive file.
public struct LibraryArchiveFileInfo: Codable, Equatable, Sendable {
    public let byteCount: Int
    public let crc32: UInt32
    public init(byteCount: Int, crc32: UInt32) { self.byteCount = byteCount; self.crc32 = crc32 }
}

/// Bounded, block-wise file access shared by backup readers and transports:
/// no unbounded `Data(contentsOf:)` before a size check, no whole archive in memory.
public enum BoundedFile {
    static let block = 4 * 1024 * 1024

    /// Small files only (manifests, listings): the limit is checked while reading.
    public static func read(_ url: URL, limit: Int) throws -> Data {
        guard limit >= 1 else { throw BackupError.sizeLimit }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(64_000, limit + 1)), !chunk.isEmpty {
            guard chunk.count <= limit - data.count else { throw BackupError.sizeLimit }
            data.append(chunk)
        }
        return data
    }

    /// Size and CRC-32 of a regular file (no symbolic link), streamed in blocks.
    public static func checksum(_ url: URL, limit: Int = LibraryArchive.maximumBytes) throws -> LibraryArchiveFileInfo {
        try requireRegularFile(url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var crc = StreamingCRC32(), count = 0
        while let chunk = try handle.read(upToCount: block), !chunk.isEmpty {
            guard chunk.count <= limit - count else { throw LibraryArchiveError.archiveTooLarge }
            crc.update(chunk); count += chunk.count
        }
        return LibraryArchiveFileInfo(byteCount: count, crc32: crc.value)
    }

    /// Streams `source` into a newly created `destination` (never replaces an
    /// existing file) and syncs it. A partially written destination is removed.
    @discardableResult
    public static func copy(from source: URL, to destination: URL, limit: Int = LibraryArchive.maximumBytes) throws -> LibraryArchiveFileInfo {
        try requireRegularFile(source)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        try Data().write(to: destination, options: .withoutOverwriting)
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: destination) } }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var crc = StreamingCRC32(), count = 0
        while let chunk = try input.read(upToCount: block), !chunk.isEmpty {
            guard chunk.count <= limit - count else { throw LibraryArchiveError.archiveTooLarge }
            try output.write(contentsOf: chunk)
            crc.update(chunk); count += chunk.count
        }
        try output.synchronize()
        complete = true
        return LibraryArchiveFileInfo(byteCount: count, crc32: crc.value)
    }

    static func requireRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw LibraryArchiveError.invalid }
    }
}

// MARK: Format 2: record stream

/// Both archive types from format 2 on (`.notybackup`, `.notylibrary`):
///
///     magic (8) | uint32 BE header length | header JSON (≤ 64 KB)
///     { uint32 BE descriptor length | descriptor JSON (≤ 4 KB) | payload[byteCount] }*
///     end descriptor {kind:"end", records, payloadBytes}, then end of file
///
/// Header and descriptors are encoded with sorted keys (reproducible bytes).
/// Data records (`index`, `toolbar`, `notebook`) carry `byteCount` and a CRC-32
/// of their payload; an `asset` record carries `sha256` and `byteCount`, and
/// its payload must hash to exactly that name. `end` counts the records before
/// it and the sum of their payload bytes. CRC-32 and SHA-256 detect accidental
/// damage; neither protects against deliberate manipulation.
struct RecordDescriptor: Codable, Equatable {
    enum Kind: String, Codable { case index, toolbar, notebook, asset, end }
    var kind: Kind
    var id: UUID?
    var byteCount: Int?
    var crc32: UInt32?
    var sha256: String?
    var records: Int?
    var payloadBytes: Int?

    /// The exact key set of each kind; anything else is an invalid archive.
    static let keys: [Kind: Set<String>] = [
        .index: ["kind", "byteCount", "crc32"], .toolbar: ["kind", "byteCount", "crc32"],
        .notebook: ["kind", "id", "byteCount", "crc32"], .asset: ["kind", "sha256", "byteCount"],
        .end: ["kind", "records", "payloadBytes"]
    ]

    static func data(_ kind: Kind, id: UUID? = nil, payload: Data) -> RecordDescriptor {
        RecordDescriptor(kind: kind, id: id, byteCount: payload.count, crc32: StreamingCRC32.checksum(payload))
    }
    static func asset(_ reference: ImageAssetReference) -> RecordDescriptor {
        RecordDescriptor(kind: .asset, byteCount: reference.byteCount, sha256: reference.sha256)
    }

    /// The reference named by an asset record (not yet checked against limits).
    var assetReference: ImageAssetReference? {
        guard kind == .asset, let sha256, let byteCount else { return nil }
        return ImageAssetReference(sha256: sha256, byteCount: byteCount)
    }
}

/// Structure of a format-2 archive is wrong (each archive type maps it to its
/// own "invalid archive" error).
struct RecordArchiveInvalid: Error {}
/// The archive or one record would exceed a limit.
struct RecordArchiveLimitExceeded: Error {}
/// Bytes of an asset do not match its reference (size or SHA-256).
struct RecordArchiveAssetMismatch: Error { let reference: ImageAssetReference }

/// What a reader does with asset payloads.
enum RecordAssetHandling {
    /// SHA-256 and size, bytes discarded.
    case verify
    /// Verified into a new synced file `<directory>/<sha256>` (written as
    /// `<sha256>.partial-<UUID>` first, renamed only after the SHA-256 matched;
    /// an existing file is never replaced). Names come only from checked hashes.
    case extract(URL)
    /// Size only: for a second pass whose whole-file CRC the caller compares
    /// with an earlier verified pass.
    case skip
}

extension RecordArchive {
    static let maximumRecordHeaderBytes = 64_000
    static let maximumDescriptorBytes = 4_096

    static func recordEncoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys; encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// The JSON object's keys must be exactly `expected`.
    static func requireKeys(_ data: Data, _ expected: Set<String>) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], Set(object.keys) == expected else {
            throw RecordArchiveInvalid()
        }
    }

    /// Unique by hash in order of first occurrence; every reference valid and
    /// the same hash always with the same size.
    static func uniqueAssets(_ references: [ImageAssetReference]) throws -> [ImageAssetReference] {
        var sizes: [String: Int] = [:], result: [ImageAssetReference] = []
        for reference in references {
            guard reference.isValid else { throw RecordArchiveInvalid() }
            if let size = sizes[reference.sha256] { guard size == reference.byteCount else { throw RecordArchiveInvalid() }; continue }
            sizes[reference.sha256] = reference.byteCount
            result.append(reference)
        }
        return result
    }
}

/// Appends format-2 records and keeps the totals for the end record.
struct RecordWriter<Sink: RecordArchiveSink> {
    var sink: Sink
    /// Upper bound of the whole archive.
    let limit: Int
    var blockSize = BoundedFile.block
    private(set) var written = 0
    private(set) var records = 0
    private(set) var payloadBytes = 0

    init(_ sink: Sink, limit: Int) { self.sink = sink; self.limit = limit }

    private mutating func append(_ data: Data) throws {
        guard data.count <= limit - written else { throw RecordArchiveLimitExceeded() }
        try sink.append(data); written += data.count
    }

    mutating func header(magic: Data, _ header: Data) throws {
        guard (1...RecordArchive.maximumRecordHeaderBytes).contains(header.count) else { throw RecordArchiveInvalid() }
        try append(magic + RecordArchive.lengthBytes(header.count) + header)
    }

    private mutating func descriptor(_ descriptor: RecordDescriptor, payloadCount: Int) throws {
        let encoded = try RecordArchive.recordEncoder().encode(descriptor)
        guard encoded.count <= RecordArchive.maximumDescriptorBytes else { throw RecordArchiveInvalid() }
        guard 4 + encoded.count + payloadCount <= limit - written else { throw RecordArchiveLimitExceeded() }
        try append(RecordArchive.lengthBytes(encoded.count) + encoded)
    }

    /// Returns the descriptor written.
    @discardableResult
    mutating func data(_ kind: RecordDescriptor.Kind, id: UUID? = nil, payload: Data) throws -> RecordDescriptor {
        let value = RecordDescriptor.data(kind, id: id, payload: payload)
        try descriptor(value, payloadCount: payload.count)
        try append(payload)
        records += 1; payloadBytes += payload.count
        return value
    }

    /// Streams the asset in blocks and hashes it on the way; throws
    /// `RecordArchiveAssetMismatch` if size or SHA-256 differ (the caller then
    /// discards the unfinished archive).
    mutating func asset(_ reference: ImageAssetReference, from payload: ImageAssetPayload) throws {
        try descriptor(.asset(reference), payloadCount: reference.byteCount)
        var hasher = SHA256Stream(), count = 0
        func take(_ block: Data) throws {
            guard block.count <= reference.byteCount - count else { throw RecordArchiveAssetMismatch(reference: reference) }
            hasher.update(block); try append(block); count += block.count
        }
        switch payload {
        case .data(let data):
            guard data.count == reference.byteCount else { throw RecordArchiveAssetMismatch(reference: reference) }
            var offset = data.startIndex
            while offset < data.endIndex {
                let end = data.index(offset, offsetBy: min(blockSize, data.endIndex - offset))
                try take(Data(data[offset..<end])); offset = end
            }
        case .file(let url):
            try BoundedFile.requireRegularFile(url)
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while true {
                let block = try drained { try handle.read(upToCount: blockSize) ?? Data() }
                if block.isEmpty { break }
                try drained { try take(block) }
            }
        }
        guard count == reference.byteCount, hasher.finalizeHex() == reference.sha256 else { throw RecordArchiveAssetMismatch(reference: reference) }
        records += 1; payloadBytes += count
    }

    mutating func end() throws {
        try descriptor(RecordDescriptor(kind: .end, records: records, payloadBytes: payloadBytes), payloadCount: 0)
    }
}

/// Reads format-2 records from a source; every length is checked against the
/// remaining bytes before anything is read or allocated.
struct RecordReader<Source: RecordArchiveSource> {
    var input: ChecksummedReader<Source>
    var blockSize = BoundedFile.block
    private(set) var consumed = 0
    private(set) var records = 0
    private(set) var payloadBytes = 0

    init(_ source: Source) { input = ChecksummedReader(source) }
    var size: Int { input.size }
    var remaining: Int { input.size - consumed }
    var file: LibraryArchiveFileInfo { LibraryArchiveFileInfo(byteCount: consumed, crc32: input.crc.value) }

    private mutating func next(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw RecordArchiveInvalid() }
        let data = try input.next(count); consumed += count
        return data
    }

    /// Magic and length prefix, then the header JSON (≤ `maximumHeader`).
    mutating func header(magic: Data, maximumHeader: Int) throws -> Data {
        let prefix = try next(RecordArchive.prefixByteCount)
        guard prefix.starts(with: magic) else { throw RecordArchiveInvalid() }
        let length = RecordArchive.length(prefix: prefix)
        guard (1...maximumHeader).contains(length) else { throw RecordArchiveInvalid() }
        return try next(length)
    }

    mutating func descriptor() throws -> RecordDescriptor {
        let prefix = try next(4)
        let length = RecordArchive.length(prefix: Data(count: 8) + prefix)
        guard (1...RecordArchive.maximumDescriptorBytes).contains(length) else { throw RecordArchiveInvalid() }
        let data = try next(length)
        let value = try JSONDecoder().decode(RecordDescriptor.self, from: data)
        try RecordArchive.requireKeys(data, RecordDescriptor.keys[value.kind]!)
        switch value.kind {
        case .index, .toolbar, .notebook:
            guard let count = value.byteCount, count >= 1, value.crc32 != nil, (value.kind == .notebook) == (value.id != nil) else {
                throw RecordArchiveInvalid()
            }
        case .asset:
            guard let reference = value.assetReference, reference.isValid else { throw RecordArchiveInvalid() }
        case .end:
            guard let records = value.records, let bytes = value.payloadBytes, records >= 0, bytes >= 0 else { throw RecordArchiveInvalid() }
        }
        return value
    }

    /// The payload of a data record (≤ `limit`), CRC-checked.
    mutating func payload(_ descriptor: RecordDescriptor, limit: Int) throws -> Data {
        guard let count = descriptor.byteCount, let crc = descriptor.crc32, count <= limit else { throw RecordArchiveInvalid() }
        let data = try next(count)
        guard StreamingCRC32.checksum(data) == crc else { throw BackupError.checksumMismatch }
        records += 1; payloadBytes += count
        return data
    }

    /// The payload of an asset record, handled as requested.
    mutating func asset(_ reference: ImageAssetReference, _ handling: RecordAssetHandling) throws {
        guard reference.byteCount <= remaining else { throw RecordArchiveInvalid() }
        var hasher = SHA256Stream(), count = 0
        let hashing: Bool
        var output: FileHandle?, partial: URL?, target: URL?
        switch handling {
        case .verify: hashing = true
        case .skip: hashing = false
        case .extract(let directory):
            hashing = true
            let file = directory.appendingPathComponent(reference.sha256, isDirectory: false)
            let temporary = directory.appendingPathComponent("\(reference.sha256).partial-\(UUID().uuidString)", isDirectory: false)
            guard !FileManager.default.fileExists(atPath: file.path) else { throw RecordArchiveInvalid() }
            try Data().write(to: temporary, options: .withoutOverwriting)
            partial = temporary; target = file
            do { output = try FileHandle(forWritingTo: temporary) } catch { try? FileManager.default.removeItem(at: temporary); throw error }
        }
        var finished = false
        defer {
            try? output?.close()
            if !finished, let partial { try? FileManager.default.removeItem(at: partial) }
        }
        while count < reference.byteCount {
            let wanted = min(blockSize, reference.byteCount - count)
            try drained {
                let block = try next(wanted)
                if hashing { hasher.update(block) }
                try output?.write(contentsOf: block)
            }
            count += wanted
        }
        if hashing, hasher.finalizeHex() != reference.sha256 { throw BackupError.checksumMismatch }
        if let handle = output, let partial, let target {
            try handle.synchronize()
            output = nil
            try handle.close()
            try FileManager.default.moveItem(at: partial, to: target)
        }
        finished = true
        records += 1; payloadBytes += count
    }

    /// Totals must match, and nothing may follow.
    mutating func end(_ descriptor: RecordDescriptor) throws {
        guard descriptor.kind == .end, descriptor.records == records, descriptor.payloadBytes == payloadBytes,
              remaining == 0, try input.atEnd() else { throw RecordArchiveInvalid() }
    }
}
