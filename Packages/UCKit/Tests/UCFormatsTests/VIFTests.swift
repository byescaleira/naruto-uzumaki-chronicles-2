import Testing
@testable import UCFormats

/// Little-endian VIF packet builder.
struct VIFPacket {
    var bytes: [UInt8] = []

    mutating func word(_ w: UInt32) {
        bytes += [UInt8(w & 0xFF), UInt8((w >> 8) & 0xFF), UInt8((w >> 16) & 0xFF), UInt8(w >> 24)]
    }

    mutating func float(_ f: Float) { word(f.bitPattern) }

    mutating func code(_ cmd: UInt8, num: Int = 0, imm: Int = 0) {
        word(UInt32(cmd) << 24 | UInt32(num & 0xFF) << 16 | UInt32(imm & 0xFFFF))
    }

    /// UNPACK of `count` vectors; `payload` is appended verbatim and padded to 32 bits.
    mutating func unpack(_ cmd: UInt8, count: Int, address: Int, unsigned: Bool = false, tops: Bool = false, payload: [UInt8]) {
        code(cmd, num: count, imm: address | (unsigned ? 0x4000 : 0) | (tops ? 0x8000 : 0))
        bytes += payload
        while bytes.count % 4 != 0 { bytes.append(0) }
    }

    mutating func stcycl(cl: Int, wl: Int) { code(0x01, imm: wl << 8 | cl) }
    mutating func mscal(_ address: Int) { code(0x14, imm: address) }

    func run(_ machine: inout VIF.Machine) throws -> [Int] {
        var calls: [Int] = []
        for instruction in try VIF.decode(bytes, range: 0 ..< bytes.count) {
            if case let .call(address?) = instruction.command { calls.append(address) } else { machine.apply(instruction.command, bytes: bytes) }
        }
        return calls
    }
}

private func floats(_ values: [Float]) -> [UInt8] {
    var p = VIFPacket()
    values.forEach { p.float($0) }
    return p.bytes
}

@Suite("VIF")
struct VIFTests {
    @Test("UNPACK sizes follow vn/vl, with V4-5 as 16-bit words")
    func formatSizes() {
        #expect(VIF.UnpackFormat(code: 0x6C).byteCount(vectors: 3) == 48)  // V4-32
        #expect(VIF.UnpackFormat(code: 0x68).byteCount(vectors: 2) == 24)  // V3-32
        #expect(VIF.UnpackFormat(code: 0x65).byteCount(vectors: 3) == 12)  // V2-16
        #expect(VIF.UnpackFormat(code: 0x62).byteCount(vectors: 5) == 8)   // S-8, padded
        #expect(VIF.UnpackFormat(code: 0x6A).byteCount(vectors: 3) == 12)  // V3-8 (9 → 12)
        #expect(VIF.UnpackFormat(code: 0x6F).byteCount(vectors: 3) == 8)   // V4-5
    }

    @Test("Decodes register commands and MSCAL")
    func decodeCommands() throws {
        var p = VIFPacket()
        p.stcycl(cl: 2, wl: 1)
        p.code(0x20); p.word(0xDEAD_BEEF)
        p.code(0x30); [1, 2, 3, 4].forEach { p.word($0) }
        p.mscal(0x18)
        p.code(0x17)
        let commands = try VIF.decode(p.bytes, range: 0 ..< p.bytes.count).map(\.command)
        #expect(commands == [.setCycle(cl: 2, wl: 1), .setMask(0xDEAD_BEEF), .setRow(SIMD4(1, 2, 3, 4)),
                             .call(address: 0x18), .call(address: nil)])
    }

    @Test("Truncated payloads are reported")
    func truncated() {
        var p = VIFPacket()
        p.code(0x6C, num: 2)
        p.bytes += floats([1, 2, 3, 4])
        #expect(throws: VIF.Failure.truncated(offset: 4)) { try VIF.decode(p.bytes, range: 0 ..< p.bytes.count) }
    }

    @Test("V4-32 and sign/zero-extended S-8 / V2-16")
    func unpackFormats() throws {
        var p = VIFPacket()
        p.unpack(0x6C, count: 1, address: 3, tops: true, payload: floats([1.5, -2, 0, 128]))
        p.unpack(0x62, count: 2, address: 5, payload: [0xFF, 0x7F])
        p.unpack(0x62, count: 1, address: 7, unsigned: true, payload: [0xFF])
        p.unpack(0x65, count: 1, address: 8, payload: [0x00, 0x80, 0x34, 0x12])
        var m = VIF.Machine()
        m.tops = 100
        _ = try p.run(&m)
        #expect(m[103].floats == SIMD4(1.5, -2, 0, 128))
        #expect(m[5] == SIMD4(repeating: UInt32(bitPattern: -1)))
        #expect(m[6] == SIMD4(repeating: 0x7F))
        #expect(m[7] == SIMD4(repeating: 0xFF))
        #expect(m[8].x == UInt32(bitPattern: -32768) && m[8].y == 0x1234 && m[8].z == 0 && m[8].w == 0)
    }

    @Test("V4-5 expands RGBA5551")
    func rgba5551() throws {
        var p = VIFPacket()
        // r = 31, g = 0, b = 16, a = 1
        let v: UInt16 = 31 | 16 << 10 | 1 << 15
        p.unpack(0x6F, count: 1, address: 0, payload: [UInt8(v & 0xFF), UInt8(v >> 8)])
        var m = VIF.Machine()
        _ = try p.run(&m)
        #expect(m[0] == SIMD4(248, 0, 128, 128))
    }

    @Test("STCYCL 2,1 interleaves two arrays (skipping write)")
    func skippingWrite() throws {
        var p = VIFPacket()
        p.stcycl(cl: 2, wl: 1)
        p.unpack(0x62, count: 3, address: 2, unsigned: true, payload: [10, 11, 12])
        p.unpack(0x6C, count: 3, address: 1, payload: floats([1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3]))
        p.mscal(0x02)
        var m = VIF.Machine()
        #expect(try p.run(&m) == [0x02])
        #expect([m[2].x, m[4].x, m[6].x] == [10, 11, 12])
        #expect([m[1].floats.x, m[3].floats.x, m[5].floats.x] == [1, 2, 3])
    }

    @Test("STCYCL with CL < WL fills from the row register")
    func fillingWrite() throws {
        var p = VIFPacket()
        p.code(0x30); [7, 7, 7, 7].forEach { p.word($0) }
        p.stcycl(cl: 1, wl: 2)
        // 4 written vectors, 2 read from the packet.
        p.unpack(0x6C, count: 4, address: 0, payload: floats([1, 1, 1, 1, 2, 2, 2, 2]))
        var m = VIF.Machine()
        _ = try p.run(&m)
        #expect(m[0].floats.x == 1 && m[2].floats.x == 2)
        #expect(m[1] == SIMD4(repeating: 7) && m[3] == SIMD4(repeating: 7))
    }

    @Test("Masked UNPACK and offset mode use the row/column registers")
    func maskAndMode() throws {
        var p = VIFPacket()
        p.code(0x30); [10, 20, 30, 40].forEach { p.word($0) }
        p.code(0x31); [5, 6, 7, 8].forEach { p.word($0) }
        // Row 0 mask: x = data, y = row, z = column, w = protected.
        p.code(0x20); p.word(0b11_10_01_00)
        p.unpack(0x7C, count: 1, address: 0, payload: [1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0, 4, 0, 0, 0])  // V4-32, masked
        p.code(0x05, imm: 1)  // offset mode
        p.unpack(0x6C, count: 1, address: 1, payload: [1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0, 4, 0, 0, 0])
        var m = VIF.Machine()
        m.memory[0] = SIMD4(0, 0, 0, 99)
        _ = try p.run(&m)
        #expect(m[0] == SIMD4(1, 20, 5, 99))
        #expect(m[1] == SIMD4(11, 22, 33, 44))
    }
}
