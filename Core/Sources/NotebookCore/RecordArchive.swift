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
