import Foundation

/// Summary of an MPEG-1/2 video elementary stream (ISO/IEC 13818-2), from its start codes:
/// the first sequence header and its extensions, and the number of pictures and GOPs.
public struct MPEGVideoStream: Sendable, Equatable {
    /// `colour_primaries`, `transfer_characteristics`, `matrix_coefficients` (ITU-T H.273 codes;
    /// 1 = BT.709, 5 = BT.470 System B/G, 6 = SMPTE 170M).
    public struct Colour: Sendable, Equatable {
        public let primaries: Int
        public let transfer: Int
        public let matrix: Int
    }

    public var width = 0
    public var height = 0
    /// `aspect_ratio_information` (1 = square samples, 2 = 4:3, 3 = 16:9, 4 = 2.21:1).
    public var aspectRatioCode = 0
    /// `frame_rate_code` (3 = 25 fps).
    public var frameRateCode = 0
    /// Bits per second (`bit_rate_value` × 400; the MPEG-2 extension bits included).
    public var bitRate = 0
    /// MPEG-2 sequence extension present.
    public var isMPEG2 = false
    public var isProgressive = false
    /// `profile_and_level_indication` (0x48 = Main Profile @ Main Level).
    public var profileAndLevel = 0
    /// Sequence display extension `video_format` (1 = PAL), if present.
    public var videoFormat: Int?
    /// Colour description of the sequence display extension, if present.
    public var colour: Colour?
    public var sequenceHeaders = 0
    public var groupsOfPictures = 0
    public var pictures = 0
    /// Picture count by `picture_coding_type` (1 = I, 2 = P, 3 = B).
    public var picturesByType: [Int: Int] = [:]
    public var hasSequenceEnd = false

    public init() {}

    /// Frames per second for `frameRateCode` (table 6-4), or `nil` for a reserved code.
    public var frameRate: (numerator: Int, denominator: Int)? {
        switch frameRateCode {
        case 1: (24000, 1001)
        case 2: (24, 1)
        case 3: (25, 1)
        case 4: (30000, 1001)
        case 5: (30, 1)
        case 6: (50, 1)
        case 7: (60000, 1001)
        case 8: (60, 1)
        default: nil
        }
    }

    /// Duration of all pictures at the stream's frame rate.
    public var duration: Double? {
        frameRate.map { Double(pictures) * Double($0.denominator) / Double($0.numerator) }
    }

    /// Scans `bytes` for start codes. Returns `nil` when there is no sequence header.
    public static func scan(_ bytes: [UInt8]) -> MPEGVideoStream? {
        var info = MPEGVideoStream()
        var sawSequence = false
        var i = 0
        let end = bytes.count - 3
        while i < end {
            // Start code prefix 00 00 01: skip ahead quickly on non-zero bytes.
            if bytes[i + 2] > 1 { i += 3; continue }
            guard bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 else { i += 1; continue }
            let code = bytes[i + 3]
            let body = i + 4
            let available = bytes.count - body
            switch code {
            case 0x00 where available >= 2:
                info.pictures += 1
                info.picturesByType[Int(bytes[body + 1] >> 3 & 7), default: 0] += 1
            case 0xB3 where available >= 8:
                info.sequenceHeaders += 1
                if !sawSequence {
                    sawSequence = true
                    info.width = Int(bytes[body]) << 4 | Int(bytes[body + 1] >> 4)
                    info.height = Int(bytes[body + 1] & 0x0F) << 8 | Int(bytes[body + 2])
                    info.aspectRatioCode = Int(bytes[body + 3] >> 4)
                    info.frameRateCode = Int(bytes[body + 3] & 0x0F)
                    let value = Int(bytes[body + 4]) << 10 | Int(bytes[body + 5]) << 2 | Int(bytes[body + 6] >> 6)
                    info.bitRate = value * 400
                }
            case 0xB5 where available >= 6:
                let identifier = bytes[body] >> 4
                if identifier == 1, !info.isMPEG2 {
                    // Sequence extension.
                    info.isMPEG2 = true
                    info.profileAndLevel = Int(bytes[body] & 0x0F) << 4 | Int(bytes[body + 1] >> 4)
                    info.isProgressive = bytes[body + 1] & 0x08 != 0
                    let sizeExtension = Int(bytes[body + 1] & 1) << 1 | Int(bytes[body + 2] >> 7)
                    info.width |= sizeExtension << 12
                    info.height |= (Int(bytes[body + 2] >> 5) & 3) << 12
                    let rateExtension = Int(bytes[body + 2] & 0x1F) << 7 | Int(bytes[body + 3] >> 1)
                    info.bitRate += (rateExtension << 18) * 400
                } else if identifier == 2, info.videoFormat == nil {
                    // Sequence display extension.
                    info.videoFormat = Int(bytes[body] >> 1 & 7)
                    if bytes[body] & 1 != 0 {
                        info.colour = Colour(primaries: Int(bytes[body + 1]), transfer: Int(bytes[body + 2]), matrix: Int(bytes[body + 3]))
                    }
                }
            case 0xB7:
                info.hasSequenceEnd = true
            case 0xB8:
                info.groupsOfPictures += 1
            default:
                break
            }
            i = body
        }
        return sawSequence ? info : nil
    }
}
