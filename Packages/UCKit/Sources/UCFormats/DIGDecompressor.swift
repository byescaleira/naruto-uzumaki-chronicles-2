import Foundation

/// Decompressor for compressed `CFC*.DIG` entries.
///
/// Recovered from `SLES_550.90` (PAL) with REA + Ghidra (R5900):
/// - `FUN_00130bc0` case 7 streams the stored bytes in 0x9000-byte chunks and resets
///   the 256 history counters at `0x540400` before the first chunk.
/// - `FUN_001308c0` decodes one chunk.
///
/// The stream is a sequence of 9-bit codes packed LSB-first; each code consumes one byte
/// plus one bit, and the bit position restarts at zero for every chunk (0x9000 = 9 × 4096,
/// so chunk boundaries always fall on a group of eight codes).
///
/// - bit 8 set: literal byte `code & 0xFF`.
/// - bit 8 clear: copy `(code & 7) + 1` bytes from `history[context][(code >> 3) & 31]`.
///
/// After every code, the output position where the code started is pushed into a 32-slot
/// ring indexed by the context, and the context becomes the last byte written.
public enum DIGDecompressor {
    public static let chunkSize = 0x9000

    public enum Failure: Error, Equatable {
        case truncatedOutput(expected: Int, produced: Int)
    }

    public static func decompress(_ source: some Collection<UInt8> & ContiguousBytes, size: Int) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: size)
        let produced = source.withUnsafeBytes { input in
            output.withUnsafeMutableBufferPointer { out in
                decode(UnsafeRawBufferPointer(input), into: out)
            }
        }
        guard produced == size else {
            throw Failure.truncatedOutput(expected: size, produced: produced)
        }
        return output
    }

    /// Decodes into a caller-owned buffer and returns the number of bytes produced.
    public static func decode(_ input: UnsafeRawBufferPointer, into out: UnsafeMutableBufferPointer<UInt8>) -> Int {
        let size = out.count
        guard size > 0 else { return 0 }
        // history[context * 32 + slot] = output position; counters[context] = next slot.
        var history = [Int32](repeating: 0, count: 256 * 32)
        var counters = [UInt8](repeating: 0, count: 256)
        var context = 0
        var o = 0

        history.withUnsafeMutableBufferPointer { history in
            counters.withUnsafeMutableBufferPointer { counters in
                var chunkStart = 0
                while chunkStart < input.count, o < size {
                    let chunkEnd = min(chunkStart + chunkSize, input.count)
                    var p = chunkStart
                    var bit = 0
                    while p < chunkEnd, o < size {
                        let start = o
                        let lo = UInt32(input[p])
                        let hi = p + 1 < input.count ? UInt32(input[p + 1]) : 0
                        let code = (lo | hi << 8) >> UInt32(bit)
                        bit += 1
                        p += 1
                        if bit > 7 {
                            p += 1
                            bit = 0
                        }
                        if code & 0x100 != 0 {
                            out[o] = UInt8(truncatingIfNeeded: code)
                            o += 1
                        } else {
                            var s = Int(history[context &* 32 &+ Int((code >> 3) & 0x1F)])
                            let end = min(o + Int(code & 7) + 1, size)
                            while o < end {
                                out[o] = out[s]
                                o += 1
                                s += 1
                            }
                        }
                        let slot = Int(counters[context])
                        history[context &* 32 &+ slot] = Int32(start)
                        counters[context] = UInt8((slot + 1) & 0x1F)
                        context = Int(out[o - 1])
                    }
                    chunkStart = chunkEnd
                }
            }
        }
        return o
    }
}
