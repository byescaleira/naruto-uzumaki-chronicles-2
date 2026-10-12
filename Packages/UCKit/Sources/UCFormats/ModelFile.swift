import simd

/// Sub-files made of sections: `u32 count`, then `count × {u32 offset, u32 size}` with offsets
/// relative to the sub-file. `FUN_001bf610(file, i)` returns `file + offset` (or null when
/// `i ≥ count` or either field is 0). Character and stage files use 20 (0x14) and 23 (0x17)
/// sections; `FUN_001b7640` binds them (see re/NOTES.md, "3D models").
public struct SectionedFile: Sendable {
    /// Known section numbers, from `FUN_001b7640`.
    public enum Section: Int, Sendable {
        /// Skinned model (``ModelFile``), `FUN_0013e360`.
        case model = 0
        /// Materials and textures (``ModelTextureTable``).
        case textures = 1
        /// Motions (`"Mt"` v0x01FF), `FUN_0013daf0`.
        case motion = 2
    }

    public let bytes: [UInt8]
    /// Byte range of every section; empty when the section is absent.
    public let sections: [Range<Int>]

    public init?(_ bytes: [UInt8], maxSections: Int = 64) {
        guard bytes.count >= 4 else { return nil }
        let reader = ByteReader(bytes)
        let count = Int(reader.u32(at: 0))
        let headerEnd = 4 + count * 8
        guard (1 ... maxSections).contains(count), headerEnd <= bytes.count else { return nil }
        var sections: [Range<Int>] = []
        for i in 0 ..< count {
            let offset = Int(reader.u32(at: 4 + i * 8)), size = Int(reader.u32(at: 8 + i * 8))
            if offset == 0 || size == 0 {
                sections.append(0 ..< 0)
                continue
            }
            guard offset >= headerEnd, offset <= bytes.count, size <= bytes.count - offset else { return nil }
            sections.append(offset ..< offset + size)
        }
        self.bytes = bytes
        self.sections = sections
    }

    public func section(_ index: Int) -> ArraySlice<UInt8>? {
        guard index < sections.count, !sections[index].isEmpty else { return nil }
        return bytes[sections[index]]
    }

    public func section(_ section: Section) -> ArraySlice<UInt8>? { self.section(section.rawValue) }
}

/// Section 0 of a character/stage file: skeleton plus skinned parts drawn by the VU1 microcode
/// (`FUN_0033f978` parses the header, `FUN_0013a9c0` turns a part into a DMA chain).
///
/// Header: `{u32 partTableOffset, u32 partCount, u32 boneCount, u32 unknown}`, then `boneCount`
/// 0x40-byte bones, `boneCount` `i16` parent indices, then the part table (0x20 bytes per part).
public struct ModelFile: Sendable {
    public enum Failure: Error, Equatable {
        case truncated
        case invalidHeader
        case invalidPart(Int)
    }

    /// One "coord": the rest pose `FUN_00340d30` turns into a matrix and `FUN_00139a30` chains
    /// to its parent. The quaternion is stored for row vectors (`v · M`), so with column vectors
    /// it rotates by its conjugate (verified: every skinned vertex lands on the same point from all
    /// of its bones).
    public struct Bone: Sendable, Hashable {
        public let parent: Int?
        /// Stored `{x, y, z, w}`.
        public let rotation: SIMD4<Float>
        public let scale: SIMD3<Float>
        public let translation: SIMD3<Float>

        public init(parent: Int?, rotation: SIMD4<Float>, scale: SIMD3<Float>, translation: SIMD3<Float>) {
            self.parent = parent
            self.rotation = rotation
            self.scale = scale
            self.translation = translation
        }

        /// Local transform for column vectors: `T · R(q̄) · S`.
        public var localMatrix: simd_float4x4 {
            let q = simd_quatf(ix: -rotation.x, iy: -rotation.y, iz: -rotation.z, r: rotation.w)
            var m = simd_float4x4(q)
            m.columns.0 *= scale.x
            m.columns.1 *= scale.y
            m.columns.2 *= scale.z
            m.columns.3 = SIMD4(translation, 1)
            return m
        }
    }

    /// DMA chain step (`FUN_0013a9c0`): before sending `qwords` quadwords of the part's VIF data,
    /// the EE injects an UNPACK of runtime data selected by `kind`.
    public struct Command: Sendable, Hashable {
        public enum Kind: UInt8, Sendable {
            /// Per-draw constants (6 words) + MSCAL 0x58.
            case header = 1
            /// 4×4 matrix of bone `index` to VU address 1 (consumed by MSCAL 0x2E).
            case boneMatrix = 2
            /// 3×4 normal matrix of bone `index` (consumed by MSCAL 0x06).
            case normalMatrix = 3
            /// Material GIF packet bound to texture slot `slot` (5 quadwords).
            case material = 4
            /// Engine material packet `index` (5 quadwords, `FUN_001cfe70`).
            case engineMaterial = 5
            /// One quadword per bone from a third per-bone table.
            case boneVector = 6
            /// Same as ``material``.
            case materialAlt = 7
            /// 3 quadwords per bone from a fourth table (environment-map matrices).
            case environmentMatrix = 8
        }

        public let rawKind: UInt8
        public let slot: UInt8
        public let index: UInt16
        public let qwords: UInt16

        public var kind: Kind? { Kind(rawValue: rawKind) }
    }

    /// `{u16 material, u16 slot}`: material `material` of the texture section is uploaded and its GIF
    /// packet is what ``Command/Kind/material`` with `slot` sends (`FUN_0013a490`).
    public struct TextureBinding: Sendable, Hashable {
        public let material: Int
        public let slot: Int
    }

    public struct Part: Sendable {
        public let commands: [Command]
        /// Byte range of the part's VIF data inside the model section.
        public let vif: Range<Int>
        public let textureBindings: [TextureBinding]
        /// Bones whose matrices place the part's bounding points (culling).
        public let boundingBones: [Int]
        /// Byte at +0x16: picks one of the model's two material tables (always equal in practice).
        public let materialTable: UInt8
        /// Word at +0x1C (observed 0x80282828).
        public let color: UInt32

        public func material(forSlot slot: Int) -> Int? {
            textureBindings.first { $0.slot == slot }?.material
        }
    }

    /// The section bytes (offsets in ``Part`` are relative to them).
    public let bytes: [UInt8]
    public let bones: [Bone]
    public let parts: [Part]
    /// Header word at +0xC (meaning unknown; 10 on characters).
    public let unknown: UInt32

    public init(_ section: ArraySlice<UInt8>) throws {
        let bytes = Array(section)
        guard bytes.count >= 0x10 else { throw Failure.truncated }
        let r = ByteReader(bytes)
        let partTable = Int(r.u32(at: 0)), partCount = Int(r.u32(at: 4)), boneCount = Int(r.u32(at: 8))
        let parentTable = 0x10 + boneCount * 0x40
        guard partCount <= 1024, boneCount <= 1024, parentTable + boneCount * 2 <= bytes.count,
              partTable >= parentTable, partTable + partCount * 0x20 <= bytes.count else { throw Failure.invalidHeader }
        func float4(_ at: Int) -> SIMD4<Float> {
            SIMD4(Float(bitPattern: r.u32(at: at)), Float(bitPattern: r.u32(at: at + 4)),
                  Float(bitPattern: r.u32(at: at + 8)), Float(bitPattern: r.u32(at: at + 12)))
        }
        var bones: [Bone] = []
        for i in 0 ..< boneCount {
            let base = 0x10 + i * 0x40
            let parent = Int(Int16(bitPattern: r.u16(at: parentTable + i * 2)))
            guard parent < i else { throw Failure.invalidHeader }
            let s = float4(base + 0x10), t = float4(base + 0x30)
            bones.append(Bone(parent: parent < 0 ? nil : parent, rotation: float4(base),
                              scale: SIMD3(s.x, s.y, s.z), translation: SIMD3(t.x, t.y, t.z)))
        }
        var parts: [Part] = []
        for i in 0 ..< partCount {
            let p = partTable + i * 0x20
            var commands: [Command] = []
            var c = Int(r.u32(at: p))
            while true {
                guard c + 6 <= bytes.count else { throw Failure.invalidPart(i) }
                let kind = r.u8(at: c)
                if kind == 0 { break }
                commands.append(Command(rawKind: kind, slot: r.u8(at: c + 1), index: r.u16(at: c + 2), qwords: r.u16(at: c + 4)))
                c += 6
                guard commands.count < 65536 else { throw Failure.invalidPart(i) }
            }
            let vifStart = Int(r.u32(at: p + 4))
            let vifEnd = vifStart + commands.reduce(0) { $0 + Int($1.qwords) * 16 }
            guard vifEnd <= bytes.count else { throw Failure.invalidPart(i) }
            let boundingCount = Int(r.u16(at: p + 0x10)), boundingBones = Int(r.u32(at: p + 0xC))
            let bindingCount = Int(r.u8(at: p + 0x17)), bindings = Int(r.u32(at: p + 0x18))
            guard boundingBones + boundingCount * 4 <= bytes.count, bindings + bindingCount * 4 <= bytes.count else {
                throw Failure.invalidPart(i)
            }
            parts.append(Part(
                commands: commands,
                vif: vifStart ..< vifEnd,
                textureBindings: (0 ..< bindingCount).map {
                    TextureBinding(material: Int(r.u16(at: bindings + $0 * 4)), slot: Int(r.u16(at: bindings + $0 * 4 + 2)))
                },
                boundingBones: (0 ..< boundingCount).map { Int(r.u32(at: boundingBones + $0 * 4)) },
                materialTable: r.u8(at: p + 0x16),
                color: r.u32(at: p + 0x1C)
            ))
        }
        self.bytes = bytes
        self.bones = bones
        self.parts = parts
        unknown = r.u32(at: 0xC)
    }

    /// World matrices of the rest pose (`FUN_00139a30` without a motion).
    public func restPose() -> [simd_float4x4] {
        var world: [simd_float4x4] = []
        world.reserveCapacity(bones.count)
        for bone in bones {
            let local = bone.localMatrix
            world.append(bone.parent.map { world[$0] * local } ?? local)
        }
        return world
    }
}
