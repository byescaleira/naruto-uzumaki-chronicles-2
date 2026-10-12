import Foundation

/// Little-endian reads over contiguous bytes (the PS2 EE is little-endian).
struct ByteReader {
    private let bytes: [UInt8]

    init(_ data: Data) { bytes = [UInt8](data) }
    init(_ bytes: [UInt8]) { self.bytes = bytes }

    func u8(at offset: Int) -> UInt8 { bytes[offset] }

    func u16(at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    func u32(at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    func cString(at offset: Int, maxLength: Int) -> String {
        let end = min(offset + maxLength, bytes.count)
        let raw = bytes[offset ..< end].prefix { $0 != 0 }
        return String(decoding: raw, as: UTF8.self)
    }
}
