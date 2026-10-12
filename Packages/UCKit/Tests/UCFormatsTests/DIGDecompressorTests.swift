import Testing
@testable import UCFormats

/// Packs 9-bit codes LSB-first exactly as `FUN_001308c0` consumes them.
private func pack(_ codes: [UInt16]) -> [UInt8] {
    var bytes: [UInt8] = []
    var accumulator: UInt32 = 0
    var bits = 0
    for code in codes {
        accumulator |= UInt32(code & 0x1FF) << UInt32(bits)
        bits += 9
        while bits >= 8 {
            bytes.append(UInt8(truncatingIfNeeded: accumulator))
            accumulator >>= 8
            bits -= 8
        }
    }
    if bits > 0 { bytes.append(UInt8(truncatingIfNeeded: accumulator)) }
    return bytes
}

private func literal(_ byte: UInt8) -> UInt16 { 0x100 | UInt16(byte) }
private func copy(slot: Int, length: Int) -> UInt16 { UInt16(slot << 3 | (length - 1)) }

@Suite("DIG decompressor")
struct DIGDecompressorTests {
    @Test("Literals pass through")
    func literals() throws {
        let text = Array("NARUTO".utf8)
        let output = try DIGDecompressor.decompress(pack(text.map(literal)), size: text.count)
        #expect(output == text)
    }

    @Test("Copies resolve through the context history")
    func contextCopy() throws {
        // "ab" then "ab" again: after "a" (context 0) and "b" (context 'a'), the history for
        // context 'b' is empty, so emit "a" literally, then copy "b" from context 'a' slot 0
        // (position 1, where the code that wrote "b" started).
        let codes = [literal(0x61), literal(0x62), literal(0x61), copy(slot: 0, length: 1)]
        let output = try DIGDecompressor.decompress(pack(codes), size: 4)
        #expect(output == Array("abab".utf8))
    }

    @Test("Overlapping copies repeat bytes")
    func overlappingCopy() throws {
        // The second "x" is coded under context 'x', recording position 1 in its slot 0;
        // the copy then reads from position 1 while writing from position 2.
        let codes = [literal(0x78), literal(0x78), copy(slot: 0, length: 6)]
        let output = try DIGDecompressor.decompress(pack(codes), size: 8)
        #expect(output == Array(repeating: 0x78, count: 8))
    }

    @Test("Bit position restarts at every 0x9000-byte chunk")
    func chunkRealignment() throws {
        // 0x9000 bytes hold exactly 0x9000 * 8 / 9 codes.
        let perChunk = DIGDecompressor.chunkSize * 8 / 9
        let codes = (0 ..< perChunk + 3).map { literal(UInt8(truncatingIfNeeded: $0 % 7 + 1)) }
        let first = pack(Array(codes.prefix(perChunk)))
        #expect(first.count == DIGDecompressor.chunkSize)
        let stream = first + pack(Array(codes.suffix(3)))
        let output = try DIGDecompressor.decompress(stream, size: codes.count)
        #expect(output == codes.map { UInt8(truncatingIfNeeded: $0) })
    }

    @Test("Short streams report truncation")
    func truncation() {
        // Eight codes fill exactly 9 bytes, so no padding bits decode as an extra code.
        let codes = (1 ... 8).map { literal(UInt8($0)) }
        #expect(throws: DIGDecompressor.Failure.truncatedOutput(expected: 12, produced: 8)) {
            try DIGDecompressor.decompress(pack(codes), size: 12)
        }
    }
}
