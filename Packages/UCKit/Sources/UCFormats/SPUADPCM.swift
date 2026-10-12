import Foundation

/// PlayStation SPU ADPCM ("VAG" sound data), the format the PS2's SPU2 plays natively.
///
/// 16-byte frames of 28 samples: byte 0 is `filter << 4 | shift`, byte 1 the loop flags,
/// then 14 bytes of 4-bit samples, low nibble first. Each sample is
/// `(nibble << 12) >> shift` plus a second-order prediction from the previous two outputs.
public struct SPUADPCMDecoder: Sendable {
    public static let frameSize = 16
    public static let samplesPerFrame = 28

    /// Prediction coefficients (÷ 64) for filters 0…4.
    private static let coefficients: [(Int32, Int32)] = [(0, 0), (60, 0), (115, -52), (98, -55), (122, -60)]

    private var previous: Int32 = 0
    private var beforePrevious: Int32 = 0

    public init() {}

    /// Decodes one 16-byte frame starting at `start`, appending 28 samples to `output`.
    public mutating func decodeFrame(_ bytes: [UInt8], at start: Int, into output: inout [Int16]) {
        let header = bytes[start]
        // Shifts 13…15 are reserved and behave like 9; filters past 4 do not exist.
        let shift = (header & 0x0F) > 12 ? 9 : Int32(header & 0x0F)
        let (k0, k1) = Self.coefficients[min(Int(header >> 4), 4)]
        for i in 0 ..< 28 {
            let byte = bytes[start + 2 + (i >> 1)]
            let nibble = i & 1 == 0 ? byte & 0x0F : byte >> 4
            // Sign-extend the nibble into the top of a 16-bit word, then scale down.
            let raw = Int32(Int16(bitPattern: UInt16(nibble) << 12)) >> shift
            let predicted = raw + ((previous * k0 + beforePrevious * k1 + 32) >> 6)
            let sample = min(max(predicted, Int32(Int16.min)), Int32(Int16.max))
            beforePrevious = previous
            previous = sample
            output.append(Int16(sample))
        }
    }

    /// Decodes a stream of `channels` mono ADPCM streams interleaved every `interleave` bytes
    /// into interleaved 16-bit PCM. Bytes after the last complete interleave group are ignored.
    public static func decodeInterleaved(_ bytes: [UInt8], channels: Int, interleave: Int) -> [Int16] {
        precondition(channels > 0 && interleave > 0 && interleave % frameSize == 0)
        let group = channels * interleave
        let groups = bytes.count / group
        let framesPerChunk = interleave / frameSize
        var decoders = Array(repeating: SPUADPCMDecoder(), count: channels)
        var planar = Array(repeating: [Int16](), count: channels)
        for channel in 0 ..< channels {
            planar[channel].reserveCapacity(groups * framesPerChunk * samplesPerFrame)
        }
        for g in 0 ..< groups {
            for channel in 0 ..< channels {
                let base = g * group + channel * interleave
                for frame in 0 ..< framesPerChunk {
                    decoders[channel].decodeFrame(bytes, at: base + frame * frameSize, into: &planar[channel])
                }
            }
        }
        let length = planar.first?.count ?? 0
        var output = [Int16]()
        output.reserveCapacity(length * channels)
        for i in 0 ..< length {
            for channel in 0 ..< channels { output.append(planar[channel][i]) }
        }
        return output
    }
}

/// Minimal RIFF/WAVE writer for 16-bit PCM.
public enum WAVFile {
    public static func pcm16(_ samples: [Int16], channels: Int, sampleRate: Int) -> Data {
        var data = Data(capacity: 44 + samples.count * 2)
        func u32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { data.append(contentsOf: $0) } }
        let payload = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + payload)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1); u16(channels); u32(sampleRate); u32(sampleRate * channels * 2); u16(channels * 2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(payload)
        samples.withUnsafeBufferPointer { buffer in
            for sample in buffer { withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) } }
        }
        return data
    }
}
