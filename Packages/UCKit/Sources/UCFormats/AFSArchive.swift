import Foundation

/// CRI `AFS` container used for streamed audio (`XA/XA.AFS`, `XA/XAVOICE.AFS`).
///
/// Layout: `"AFS\0"`, `u32 count`, `count × {u32 offset, u32 size}`, then
/// `{u32 offset, u32 size}` of an optional name table of 0x30-byte records
/// (32-byte name, timestamp, size).
public struct AFSArchive: Sendable {
    public struct Entry: Sendable, Hashable {
        public let index: Int
        public let offset: UInt32
        public let size: UInt32
        public let name: String?
    }

    public enum Failure: Error {
        case notAFS
        case truncated
    }

    public let url: URL
    public let entries: [Entry]

    public init(url: URL) throws {
        self.url = url
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let head = try handle.read(upToCount: 8), head.count == 8 else { throw Failure.truncated }
        let header = ByteReader(head)
        guard header.u32(at: 0) == 0x0053_4641 else { throw Failure.notAFS }
        let count = Int(header.u32(at: 4))
        guard let table = try handle.read(upToCount: count * 8 + 8), table.count == count * 8 + 8 else {
            throw Failure.truncated
        }
        let reader = ByteReader(table)
        let nameOffset = reader.u32(at: count * 8)
        let nameSize = reader.u32(at: count * 8 + 4)

        var names: [String?] = Array(repeating: nil, count: count)
        if nameOffset != 0, Int(nameSize) >= count * 0x30 {
            try handle.seek(toOffset: UInt64(nameOffset))
            if let raw = try handle.read(upToCount: count * 0x30), raw.count == count * 0x30 {
                let nameReader = ByteReader(raw)
                for i in 0 ..< count {
                    names[i] = nameReader.cString(at: i * 0x30, maxLength: 32)
                }
            }
        }
        entries = (0 ..< count).map { i in
            Entry(index: i, offset: reader.u32(at: i * 8), size: reader.u32(at: i * 8 + 4), name: names[i])
        }
    }

    public func read(_ entry: Entry) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(entry.offset))
        guard let data = try handle.read(upToCount: Int(entry.size)), data.count == Int(entry.size) else {
            throw Failure.truncated
        }
        return data
    }
}
