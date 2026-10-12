import Foundation

/// `CFC*.DIG`: the main data archive (one per language).
///
/// Recovered from `SLES_550.90`:
/// - `FUN_00127300` selects the file by language and calls `FUN_001296b0(6, 0, path)`,
///   which reads the first 6 sectors (0x3000 bytes) as the index.
/// - `FUN_001292e0` reads an entry: raw entries are read sector-aligned, compressed ones
///   are queued as I/O command 7 and expanded by ``DIGDecompressor``.
public struct DIGArchive: Sendable {
    public static let sectorSize = 0x800
    public static let indexSize = 6 * sectorSize

    public struct Entry: Sendable, Hashable {
        public let index: Int
        /// Start sector of the stored bytes.
        public let sector: UInt32
        /// Bytes stored on disc (compressed size when ``isCompressed``).
        public let storedSize: UInt32
        /// Number of sub-files in the expanded entry (see ``DIGSubfileTable``).
        public let subfileCount: UInt16
        public let isCompressed: Bool
        /// Expanded size.
        public let size: UInt32

        public var offset: UInt64 { UInt64(sector) * UInt64(DIGArchive.sectorSize) }
        public var isEmpty: Bool { storedSize == 0 && size == 0 }
    }

    public enum Failure: Error {
        case indexTruncated
        case entryOutOfBounds(Int)
    }

    /// Where the archive's bytes live: a loose file, or a range inside the `.iso`.
    public let file: DiscImage.File
    public let entries: [Entry]

    public init(file: DiscImage.File) throws {
        self.file = file
        let handle = try FileHandle(forReadingFrom: file.url)
        defer { try? handle.close() }
        try handle.seek(toOffset: file.offset)
        guard let index = try handle.read(upToCount: Self.indexSize), index.count == Self.indexSize else {
            throw Failure.indexTruncated
        }
        entries = Self.parseIndex(index)
    }

    public init(url: URL) throws {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
        try self.init(file: DiscImage.File(url: url, offset: 0, size: size))
    }

    public static func parseIndex(_ data: Data) -> [Entry] {
        let reader = ByteReader(data)
        return (0 ..< data.count / 16).map { i in
            let base = i * 16
            return Entry(
                index: i,
                sector: reader.u32(at: base),
                storedSize: reader.u32(at: base + 4),
                subfileCount: reader.u16(at: base + 8),
                isCompressed: reader.u16(at: base + 10) != 0,
                size: reader.u32(at: base + 12)
            )
        }
    }

    /// Reads and, when needed, expands one entry.
    public func read(_ entry: Entry) throws -> [UInt8] {
        let handle = try FileHandle(forReadingFrom: file.url)
        defer { try? handle.close() }
        try handle.seek(toOffset: file.offset + entry.offset)
        guard let stored = try handle.read(upToCount: Int(entry.storedSize)), stored.count == Int(entry.storedSize) else {
            throw Failure.entryOutOfBounds(entry.index)
        }
        if entry.isCompressed {
            return try DIGDecompressor.decompress(stored, size: Int(entry.size))
        }
        return [UInt8](stored.prefix(Int(entry.size)))
    }
}

/// Sub-file table at the start of an expanded DIG entry: `count` records of
/// `{u32 index, u32 size, u32 offset, u32 reserved}`.
public struct DIGSubfileTable: Sendable {
    public struct Subfile: Sendable, Hashable {
        public let index: UInt32
        public let size: UInt32
        public let offset: UInt32
    }

    public let subfiles: [Subfile]

    public init(_ bytes: [UInt8], count: Int) {
        let reader = ByteReader(bytes)
        let available = min(count, bytes.count / 16)
        subfiles = (0 ..< available).map { i in
            Subfile(
                index: reader.u32(at: i * 16),
                size: reader.u32(at: i * 16 + 4),
                offset: reader.u32(at: i * 16 + 8)
            )
        }
    }

    /// Entries are padded after their last sub-file (observed: 16-byte alignment).
    public static let tailPadding = 0x40

    /// True when every sub-file lies inside the entry and the furthest one reaches its
    /// (padded) end. Empty sub-files may share an offset with the next one.
    public func isConsistent(entrySize: Int) -> Bool {
        let ends = subfiles.map { Int($0.offset) + Int($0.size) }
        guard let end = ends.max() else { return false }
        return end <= entrySize && entrySize - end < Self.tailPadding
    }

    public func slice(_ subfile: Subfile, of bytes: [UInt8]) -> ArraySlice<UInt8> {
        bytes[Int(subfile.offset) ..< Int(subfile.offset + subfile.size)]
    }
}
