import Foundation

/// The game's own executable (`SLES_550.90`, ELF32 little-endian MIPS R5900), read for the tables
/// compiled into it (maps, characters, menus…) at their virtual addresses, the same addresses
/// the RE notes use. Only `PT_LOAD` segments are mapped.
public struct Executable: Sendable {
    public enum Failure: Error, Equatable {
        case notELF
        case unmapped(UInt32)
    }

    private struct Segment: Sendable {
        let address: UInt32
        let range: Range<Int>
    }

    public static let name = "SLES_550.90"

    private let bytes: [UInt8]
    private let segments: [Segment]

    public init(_ bytes: [UInt8]) throws {
        guard bytes.count >= 0x34, bytes[0 ..< 4] == [0x7F, 0x45, 0x4C, 0x46], bytes[4] == 1, bytes[5] == 1 else {
            throw Failure.notELF
        }
        let r = ByteReader(bytes)
        let table = Int(r.u32(at: 0x1C)), count = Int(r.u16(at: 0x2C)), size = Int(r.u16(at: 0x2A))
        var segments: [Segment] = []
        for i in 0 ..< count {
            let base = table + i * size
            guard base + 0x20 <= bytes.count, r.u32(at: base) == 1 else { continue }
            let offset = Int(r.u32(at: base + 4)), address = r.u32(at: base + 8), fileSize = Int(r.u32(at: base + 16))
            guard offset + fileSize <= bytes.count else { continue }
            segments.append(Segment(address: address, range: offset ..< offset + fileSize))
        }
        self.bytes = bytes
        self.segments = segments
    }

    public init(url: URL) throws {
        try self.init([UInt8](try Data(contentsOf: url, options: .mappedIfSafe)))
    }

    /// File offset of virtual address `address`, when `count` bytes from it are mapped.
    private func offset(_ address: UInt32, count: Int) throws -> Int {
        for segment in segments where address >= segment.address {
            let start = segment.range.lowerBound + Int(address - segment.address)
            if start + count <= segment.range.upperBound { return start }
        }
        throw Failure.unmapped(address)
    }

    public func bytes(at address: UInt32, count: Int) throws -> ArraySlice<UInt8> {
        let start = try offset(address, count: count)
        return bytes[start ..< start + count]
    }

    public func u32(at address: UInt32) throws -> UInt32 { ByteReader(bytes).u32(at: try offset(address, count: 4)) }
    public func i32(at address: UInt32) throws -> Int32 { Int32(bitPattern: try u32(at: address)) }
    public func u16(at address: UInt32) throws -> UInt16 { ByteReader(bytes).u16(at: try offset(address, count: 2)) }
    public func u8(at address: UInt32) throws -> UInt8 { bytes[try offset(address, count: 1)] }

    public func float(at address: UInt32) throws -> Float { Float(bitPattern: try u32(at: address)) }

    /// NUL-terminated Latin-1 string.
    public func string(at address: UInt32, maximum: Int = 256) throws -> String {
        var out: [UInt8] = []
        for i in 0 ..< maximum {
            let byte = try u8(at: address + UInt32(i))
            if byte == 0 { break }
            out.append(byte)
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// A DIG resource handle as the game passes them around: `entry << 16 | sub-file`.
public struct ResourceHandle: Sendable, Hashable, CustomStringConvertible {
    public let raw: UInt32

    public init(_ raw: UInt32) { self.raw = raw }
    public init(entry: Int, subfile: Int) { raw = UInt32(entry) << 16 | UInt32(subfile) }

    public var entry: Int { Int(raw >> 16) }
    public var subfile: Int { Int(raw & 0xFFFF) }
    public var isNone: Bool { raw == 0 || raw == 0xFFFF_FFFF }
    public var description: String { String(format: "%04d/%02d", entry, subfile) }
}

/// Data tables with the `0x105` header (`FUN_00255800` / `FUN_002558d0`): `u16 magic`, `u16 table
/// count` at +8, per table a `u32 offset` at `0x20 + 16·i`; at that offset `u16 rows`, rows start
/// 0x14 later. Row size depends on the table (the caller knows it).
public struct DataTable: Sendable {
    public enum Failure: Error, Equatable {
        case notADataTable
        case truncated
    }

    public static let magic: UInt16 = 0x105

    private let bytes: [UInt8]
    public let tables: [(offset: Int, rows: Int)]

    public init(_ bytes: [UInt8]) throws {
        let r = ByteReader(bytes)
        guard bytes.count >= 0x20, r.u16(at: 0) == Self.magic else { throw Failure.notADataTable }
        let count = Int(r.u16(at: 8))
        var tables: [(offset: Int, rows: Int)] = []
        for i in 0 ..< count {
            let at = 0x20 + 16 * i
            guard at + 4 <= bytes.count else { throw Failure.truncated }
            let offset = Int(r.u32(at: at))
            guard offset + 0x14 <= bytes.count else { throw Failure.truncated }
            tables.append((offset, Int(r.u16(at: offset))))
        }
        self.bytes = bytes
        self.tables = tables
    }

    /// Row `row` of table `table`, `size` bytes.
    public func row(_ row: Int, of table: Int = 0, size: Int) -> ArraySlice<UInt8>? {
        guard tables.indices.contains(table), (0 ..< tables[table].rows).contains(row) else { return nil }
        let start = tables[table].offset + 0x14 + row * size
        guard start + size <= bytes.count else { return nil }
        return bytes[start ..< start + size]
    }
}
