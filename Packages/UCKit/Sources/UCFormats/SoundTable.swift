import Foundation

/// Stream table of the sound system: `CFC*.DIG` entry 567 (0x237), sub-file 0, loaded by
/// `FUN_0012b630` (asset id `0x2370000`) and read by `FUN_00129c60` to start a stream.
///
/// Header (little-endian):
///
/// | Offset | Type | Field |
/// | --- | --- | --- |
/// | 0x08 | u32 | music table offset (one record per `XA/XA.AFS` entry) |
/// | 0x10 | u16 | music count (131) |
/// | 0x12 | u16 | movie count (2: `mv01`, `mv00`) |
/// | 0x14 | u8 ×4 | sound-system setup bytes passed to `FUN_001da200` |
/// | 0x18 | u32 | movie table offset |
/// | 0x1C | u32 | voice table offset (one record per `XA/XAVOICE.AFS` entry) |
/// | 0x28 | u16 | voice count (2001) |
///
/// Records are 8 bytes: `u32 name offset (from the file start), u8 0, u8 0x10,
/// u8 volume (0…127), u8 channels`; the record index is the AFS entry index. `channels`
/// matches every voice file but is 2 for all music records (21 tracks are mono). The play call
/// sets the output level to `(volume × channelLevel + 0x40) >> 7`, channel level 0x80 by
/// default (`DAT_005215c8`), through ``CRIVolume``.
public struct SoundTable: Sendable {
    public struct Stream: Sendable, Hashable {
        public let index: Int
        public let name: String?
        public let volume: Int
        public let channels: Int
    }

    public enum Failure: Error, Equatable {
        case truncated
    }

    /// Location in `CFC*.DIG`.
    public static let entry = 567
    public static let subfile = 0

    public let music: [Stream]
    public let movies: [Stream]
    public let voices: [Stream]

    public init(_ data: some Collection<UInt8>) throws {
        let bytes = Array(data)
        guard bytes.count >= 0x2C else { throw Failure.truncated }
        let reader = ByteReader(bytes)
        func table(offset: UInt32, count: UInt16) throws -> [Stream] {
            let start = Int(offset)
            guard start + Int(count) * 8 <= bytes.count else { throw Failure.truncated }
            return (0 ..< Int(count)).map { i in
                let record = start + i * 8
                // The names are debug labels; the shipped file stops partway through them.
                let nameOffset = Int(reader.u32(at: record))
                let name = nameOffset < bytes.count ? reader.cString(at: nameOffset, maxLength: 32) : nil
                return Stream(index: i, name: name, volume: Int(reader.u8(at: record + 6)),
                              channels: Int(reader.u8(at: record + 7)))
            }
        }
        music = try table(offset: reader.u32(at: 0x08), count: reader.u16(at: 0x10))
        movies = try table(offset: reader.u32(at: 0x18), count: reader.u16(at: 0x12))
        voices = try table(offset: reader.u32(at: 0x1C), count: reader.u16(at: 0x28))
    }
}

/// The game's volume scale (`FUN_00128090`): a level 0…128 (0x80 = full) becomes an ADXT
/// output attenuation in 0.1 dB — linear to 6.4 dB, then 2×, 4× and 50× steeper, silent at 0.
public enum CRIVolume {
    /// Attenuation in tenths of a decibel (0 = full, 999 = silent).
    public static func attenuation(level: Int) -> Int {
        let a = 0x80 - level
        if a < 1 { return 0 }
        if a <= 0x40 { return a }
        if a <= 0x60 { return a * 2 - 0x40 }
        if a <= 0x70 { return a * 4 - 0x100 }
        if a < 0x80 { return a * 0x32 - 0x1520 }
        return 999
    }

    /// Linear amplitude for `level`.
    public static func gain(level: Int) -> Float {
        let tenths = attenuation(level: level)
        return tenths >= 999 ? 0 : Float(pow(10, -Double(tenths) / 200))
    }

    /// Level of a table stream at the default channel level, as `FUN_00129c60` computes it.
    public static func level(streamVolume: Int, channelLevel: Int = 0x80) -> Int {
        (streamVolume * channelLevel + 0x40) >> 7
    }
}
