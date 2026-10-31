import Foundation

/// A ZIP container with stored (uncompressed) entries, all a `.docx` needs.
/// noty's own archives are record files (`RecordArchive`), not ZIP; only the
/// CRC comes from there. Entries are in memory and small: text and XML.
enum ZipStore {
    /// Fixed time stamp (1980-01-01): the same content gives the same bytes.
    private static let dosDate: UInt16 = 0x0021

    static func archive(_ entries: [(name: String, data: Data)]) -> Data {
        var result = Data(), directory = Data()
        func put(_ value: UInt16, in data: inout Data) { data.append(UInt8(value & 255)); data.append(UInt8(value >> 8)) }
        func put(_ value: UInt32, in data: inout Data) {
            put(UInt16(value & 0xFFFF), in: &data); put(UInt16(value >> 16), in: &data)
        }
        /// What the local header and the central directory share.
        func common(_ entry: (name: String, data: Data), into data: inout Data) {
            put(10 as UInt16, in: &data) // version needed: stored
            put(0x0800 as UInt16, in: &data) // names are UTF-8
            put(0 as UInt16, in: &data) // method: stored
            put(0 as UInt16, in: &data); put(dosDate, in: &data)
            put(StreamingCRC32.checksum(entry.data), in: &data)
            put(UInt32(entry.data.count), in: &data); put(UInt32(entry.data.count), in: &data)
            put(UInt16(entry.name.utf8.count), in: &data); put(0 as UInt16, in: &data) // no extra field
        }
        for entry in entries {
            let offset = UInt32(result.count)
            put(0x0403_4B50 as UInt32, in: &result)
            common(entry, into: &result)
            result.append(Data(entry.name.utf8)); result.append(entry.data)

            put(0x0201_4B50 as UInt32, in: &directory)
            put(10 as UInt16, in: &directory) // made by
            common(entry, into: &directory)
            put(0 as UInt16, in: &directory); put(0 as UInt16, in: &directory); put(0 as UInt16, in: &directory) // comment, disk, internal
            put(0 as UInt32, in: &directory); put(offset, in: &directory)
            directory.append(Data(entry.name.utf8))
        }
        let start = UInt32(result.count)
        result.append(directory)
        put(0x0605_4B50 as UInt32, in: &result)
        put(0 as UInt16, in: &result); put(0 as UInt16, in: &result)
        put(UInt16(entries.count), in: &result); put(UInt16(entries.count), in: &result)
        put(UInt32(directory.count), in: &result); put(start, in: &result)
        put(0 as UInt16, in: &result) // no comment
        return result
    }
}
