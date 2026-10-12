/// PS2 VIF1 command stream: the packets the EE DMAs to VU1 (see re/NOTES.md, "3D models").
///
/// Each command is a 32-bit code `{u16 imm, u8 num, u8 cmd}`; `cmd & 0x60 == 0x60` is UNPACK,
/// which decompresses `num` vectors into VU memory starting at `imm & 0x3FF` (in quadwords),
/// honouring the write cycle set by STCYCL and, when `cmd & 0x10`, the STMASK/STROW/STCOL
/// registers. Only what the game's packets need is executed; MPG and DIRECT payloads are skipped.
public enum VIF {
    /// Component layout of an UNPACK: `vn` = components − 1, `vl` = 32/16/8/5-bit.
    public struct UnpackFormat: Sendable, Hashable {
        public let components: Int
        public let bits: Int

        public init(code cmd: UInt8) {
            let vl = Int(cmd & 3)
            components = Int((cmd >> 2) & 3) + 1
            bits = [32, 16, 8, 5][vl]
        }

        /// Bytes of packed input for `count` vectors (V4-5 is one 16-bit word per vector);
        /// the packet resumes at the next 32-bit boundary.
        public func byteCount(vectors count: Int) -> Int {
            let bitCount = bits == 5 ? 16 * count : bits * components * count
            return (bitCount + 31) / 32 * 4
        }
    }

    public struct Unpack: Sendable, Hashable {
        public let format: UnpackFormat
        /// Destination quadword (relative to TOPS when ``addsTOPS``).
        public let address: Int
        /// Vectors written to VU memory (`num`, 0 = 256).
        public let count: Int
        /// Vectors read from the packet: all of them, except with CL < WL ("filling" writes),
        /// where only CL of every WL written vectors come from the packet.
        public let inputCount: Int
        /// 8/16-bit inputs are zero-extended instead of sign-extended.
        public let isUnsigned: Bool
        public let addsTOPS: Bool
        public let isMasked: Bool
        /// Packed input bytes in the stream.
        public let data: Range<Int>
    }

    public enum Command: Sendable, Hashable {
        case nop
        case setCycle(cl: Int, wl: Int)
        case offset(Int)
        case base(Int)
        case itop(Int)
        case setMode(Int)
        case maskPath3(Bool)
        case mark(Int)
        case flush
        /// MSCAL / MSCALF / MSCNT: start the VU1 microprogram at `address` (in 64-bit instruction
        /// units; `nil` for MSCNT, which continues from the last address).
        case call(address: Int?)
        case setMask(UInt32)
        case setRow(SIMD4<UInt32>)
        case setColumn(SIMD4<UInt32>)
        case microprogram(address: Int, data: Range<Int>)
        case direct(data: Range<Int>)
        case unpack(Unpack)
        case unknown(UInt32)
    }

    public struct Instruction: Sendable, Hashable {
        /// Byte offset of the command code in the stream.
        public let offset: Int
        public let command: Command
    }

    public enum Failure: Error, Equatable {
        case truncated(offset: Int)
    }

    /// Decodes every command in `bytes[range]` (32-bit aligned).
    public static func decode(_ bytes: [UInt8], range: Range<Int>) throws -> [Instruction] {
        var instructions: [Instruction] = []
        var p = range.lowerBound
        var cl = 1, wl = 1
        func word(_ at: Int) throws -> UInt32 {
            guard at + 4 <= range.upperBound else { throw Failure.truncated(offset: at) }
            return UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
        }
        func payload(_ start: Int, _ count: Int) throws -> Range<Int> {
            guard start + count <= range.upperBound else { throw Failure.truncated(offset: start) }
            return start ..< start + count
        }
        while p + 4 <= range.upperBound {
            let code = try word(p)
            let cmd = UInt8((code >> 24) & 0x7F)
            let num = Int((code >> 16) & 0xFF)
            let imm = Int(code & 0xFFFF)
            let start = p
            p += 4
            let command: Command
            if cmd & 0x60 == 0x60 {
                let format = UnpackFormat(code: cmd)
                let count = num == 0 ? 256 : num
                let inputCount = cl < wl ? cl * (count / wl) + min(count % wl, cl) : count
                let data = try payload(p, format.byteCount(vectors: inputCount))
                command = .unpack(Unpack(format: format, address: imm & 0x3FF, count: count, inputCount: inputCount,
                                         isUnsigned: imm & 0x4000 != 0, addsTOPS: imm & 0x8000 != 0,
                                         isMasked: cmd & 0x10 != 0, data: data))
                p = data.upperBound
            } else {
                switch cmd {
                case 0x00: command = .nop
                case 0x01:
                    cl = imm & 0xFF; wl = imm >> 8
                    command = .setCycle(cl: cl, wl: wl)
                case 0x02: command = .offset(imm & 0x3FF)
                case 0x03: command = .base(imm & 0x3FF)
                case 0x04: command = .itop(imm & 0x3FF)
                case 0x05: command = .setMode(imm & 3)
                case 0x06: command = .maskPath3(imm & 0x8000 != 0)
                case 0x07: command = .mark(imm)
                case 0x10, 0x11, 0x13: command = .flush
                case 0x14, 0x15: command = .call(address: imm)
                case 0x17: command = .call(address: nil)
                case 0x20:
                    command = .setMask(try word(p))
                    p += 4
                case 0x30, 0x31:
                    let v = SIMD4(try word(p), try word(p + 4), try word(p + 8), try word(p + 12))
                    command = cmd == 0x30 ? .setRow(v) : .setColumn(v)
                    p += 16
                case 0x4A:
                    let data = try payload(p, (num == 0 ? 256 : num) * 8)
                    command = .microprogram(address: imm, data: data)
                    p = data.upperBound
                case 0x50, 0x51:
                    let data = try payload(p, (imm == 0 ? 65536 : imm) * 16)
                    command = .direct(data: data)
                    p = data.upperBound
                default:
                    command = .unknown(code)
                }
            }
            instructions.append(Instruction(offset: start, command: command))
        }
        return instructions
    }

    /// VU1 data memory as seen through VIF1: 1024 quadwords plus the UNPACK registers.
    public struct Machine: Sendable {
        public static let quadwords = 1024
        public var memory: [SIMD4<UInt32>]
        public var cycleLength = 1
        public var writeLength = 1
        public var mode = 0
        public var mask: UInt32 = 0
        public var row = SIMD4<UInt32>(repeating: 0)
        public var column = SIMD4<UInt32>(repeating: 0)
        /// Double-buffer base used by `addsTOPS` unpacks (the game always unpacks relative to it).
        public var tops = 0

        public init() {
            memory = Array(repeating: SIMD4(repeating: 0), count: Self.quadwords)
        }

        public subscript(quadword: Int) -> SIMD4<UInt32> {
            memory[quadword & (Self.quadwords - 1)]
        }

        /// Applies a register command; returns false for commands it does not model.
        @discardableResult
        public mutating func apply(_ command: Command, bytes: [UInt8]) -> Bool {
            switch command {
            case let .setCycle(cl, wl): cycleLength = cl; writeLength = wl
            case let .setMode(m): mode = m
            case let .setMask(m): mask = m
            case let .setRow(v): row = v
            case let .setColumn(v): column = v
            case let .unpack(u): unpack(u, bytes: bytes)
            default: return false
            }
            return true
        }

        public mutating func unpack(_ u: Unpack, bytes: [UInt8]) {
            let cl = max(cycleLength, 1), wl = max(writeLength, 1)
            var input = u.data.lowerBound
            var address = u.address + (u.addsTOPS ? tops : 0)
            for written in 0 ..< u.count {
                let cyclePosition = written % wl
                let filling = cl < wl && cyclePosition >= cl
                var value = memory[address & (Self.quadwords - 1)]
                let decoded: SIMD4<UInt32>
                if filling {
                    decoded = row
                } else {
                    decoded = Self.element(u, bytes: bytes, at: &input)
                }
                let maskRow = min(cyclePosition, 3)
                for c in 0 ..< 4 {
                    let selector = u.isMasked ? Int((mask >> UInt32(maskRow * 8 + c * 2)) & 3) : (filling ? 1 : 0)
                    switch selector {
                    case 0:
                        guard c < u.format.components || u.format.components == 1 || u.format.bits == 5 else { continue }
                        switch mode {
                        case 1: value[c] = decoded[c] &+ row[c]
                        case 2: row[c] = row[c] &+ decoded[c]; value[c] = row[c]
                        default: value[c] = decoded[c]
                        }
                    case 1: value[c] = row[c]
                    case 2: value[c] = column[maskRow]
                    default: break
                    }
                }
                memory[address & (Self.quadwords - 1)] = value
                // CL ≥ WL skips CL − WL quadwords after every WL written; CL < WL writes contiguously.
                address += (cl >= wl && cyclePosition == wl - 1) ? cl - wl + 1 : 1
            }
        }

        /// Reads one packed vector and expands it to four 32-bit lanes. A scalar is broadcast to
        /// all lanes; V2/V3 leave the remaining lanes to the caller (they are not written).
        static func element(_ u: Unpack, bytes: [UInt8], at p: inout Int) -> SIMD4<UInt32> {
            var out = SIMD4<UInt32>(repeating: 0)
            if u.format.bits == 5 {
                let v = UInt32(bytes[p]) | UInt32(bytes[p + 1]) << 8
                p += 2
                return SIMD4((v & 0x1F) << 3, ((v >> 5) & 0x1F) << 3, ((v >> 10) & 0x1F) << 3, ((v >> 15) & 1) << 7)
            }
            for c in 0 ..< u.format.components {
                switch u.format.bits {
                case 32:
                    out[c] = UInt32(bytes[p]) | UInt32(bytes[p + 1]) << 8 | UInt32(bytes[p + 2]) << 16 | UInt32(bytes[p + 3]) << 24
                    p += 4
                case 16:
                    let v = UInt16(bytes[p]) | UInt16(bytes[p + 1]) << 8
                    out[c] = u.isUnsigned ? UInt32(v) : UInt32(bitPattern: Int32(Int16(bitPattern: v)))
                    p += 2
                default:
                    let v = bytes[p]
                    out[c] = u.isUnsigned ? UInt32(v) : UInt32(bitPattern: Int32(Int8(bitPattern: v)))
                    p += 1
                }
            }
            if u.format.components == 1 { out = SIMD4(repeating: out[0]) }
            return out
        }
    }
}

extension SIMD4 where Scalar == UInt32 {
    /// The lanes reinterpreted as IEEE floats (VU registers are untyped).
    public var floats: SIMD4<Float> {
        SIMD4<Float>(Float(bitPattern: x), Float(bitPattern: y), Float(bitPattern: z), Float(bitPattern: w))
    }
}
