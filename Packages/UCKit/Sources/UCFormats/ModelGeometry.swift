import simd

/// Renderer-agnostic triangles of one part / material / pass.
public struct ModelMesh: Sendable {
    public struct Vertex: Sendable, Hashable {
        public var position: SIMD3<Float>
        public var normal: SIMD3<Float>
        /// GS `ST` (0…1, `t` grows downwards like the texture rows).
        public var uv: SIMD2<Float>
        /// Vertex colour, 1 = PS2 0x80 (alpha) / 0xFF (RGB); white unless MSCAL 0x24/0x28 set one.
        public var color: SIMD4<Float>
    }

    public enum Pass: Sendable, Hashable {
        /// Triangles drawn with the part's own textures.
        case base
        /// Additive environment-map overlay drawn between MSCAL 0x5C and 0x5E.
        case environment
    }

    public let part: Int
    /// Material of the texture section (``ModelTextureTable``); `nil` for untextured triangles.
    public let material: Int?
    public let pass: Pass
    /// The UVs come from the environment-map generator (sphere map of the rest-pose normals,
    /// as seen from −Z), not from the model's UV table.
    public let isEnvironmentMapped: Bool
    public var vertices: [Vertex] = []
    /// Triangle list; winding is not consistent (the GS does not cull).
    public var indices: [UInt32] = []
}

/// Builds static geometry by executing a model's VIF packets against a model of the game's VU1
/// microcode (uploaded from `0x344400` by `FUN_001c46b0`; entry points are MSCAL addresses).
///
/// The microcode keeps indexed tables in VU memory across MSCALs. Every program reads a header
/// at quadword 0 (`{count, slot, flag, flag}` as V4-8, or S-8/V2-8/V3-8) and its records after it,
/// interleaved with STCYCL 2,1 when two arrays are sent:
/// - 0x2E / 0x06 / 0x54: store the matrix the EE just injected (4×4 bone, normal, environment)
///   in matrix slot `slot` (a VU address);
/// - 0x02 / 0x04 / 0x1A / 0x1C: skinning. For each `{dest index, vector}`, add
///   `M_slot · (x, y, z, w)` to the accumulator (`flag` 0 starts a sum). `w` is the bone weight
///   and the stored `xyz` are already multiplied by it, so the homogeneous product sums directly
///   to the skinned position;
/// - 0x08 / 0x0A: commit the listed accumulator entries to the vertex table;
/// - 0x20 / 0x22: normals `{nx, ny, nz, index}` through a normal-matrix slot (0x22 accumulates);
/// - 0x12: light normals into the colour table (`{normal, colour}` pairs); 0x24 does the same
///   with an RGBA per colour, 0x28 sets RGBA only;
/// - 0x0C: texture coordinates `{s, t, index}`; 0x4E / 0x52 generate them from normals through
///   an environment slot instead (sphere map, scale from 0x50; 0x52 is modelled like 0x4E);
/// - 0x18: `n` textured triangles of `{vertex, colour, uv}` triplets; 0x4C: untextured triangles
///   of `{vertex, colour}` pairs;
/// - 0x5C / 0x5E enter and leave the environment pass; 0x14 kicks a GIF packet (render state).
public struct ModelGeometry: Sendable {
    public enum Failure: Error, Equatable {
        case missingBone(Int)
        case undefinedSlot(part: Int, slot: Int)
        case truncatedVIF(part: Int, offset: Int)
    }

    public var meshes: [ModelMesh]
    /// MSCAL addresses the interpreter does not model, with their call counts.
    public var unknownPrograms: [Int: Int]
    /// Triangles dropped because a corner referenced a vertex never committed in the part.
    public var droppedTriangles: Int

    public var triangleCount: Int { meshes.reduce(0) { $0 + $1.indices.count / 3 } }

    /// - Parameters:
    ///   - pose: world matrix per bone (defaults to ``ModelFile/restPose()``).
    ///   - passes: which passes to keep.
    public init(model: ModelFile, pose: [simd_float4x4]? = nil, passes: Set<ModelMesh.Pass> = [.base]) throws {
        let pose = pose ?? model.restPose()
        let normalPose = pose.map { m in
            simd_float3x3(columns: (SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                                    SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                                    SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))).inverse.transpose
        }
        var meshes: [ModelMesh] = []
        var unknown: [Int: Int] = [:]
        var dropped = 0
        for (partIndex, part) in model.parts.enumerated() {
            var interpreter = Interpreter(part: partIndex, pose: pose, normalPose: normalPose, passes: passes)
            var p = part.vif.lowerBound
            for command in part.commands {
                switch command.kind {
                case .boneMatrix?, .normalMatrix?, .environmentMatrix?:
                    guard Int(command.index) < pose.count else { throw Failure.missingBone(Int(command.index)) }
                    interpreter.staged = Int(command.index)
                case .material?, .materialAlt?:
                    interpreter.material = part.material(forSlot: Int(command.slot))
                default:
                    break
                }
                let end = p + Int(command.qwords) * 16
                let instructions: [VIF.Instruction]
                do {
                    instructions = try VIF.decode(model.bytes, range: p ..< end)
                } catch let VIF.Failure.truncated(offset) {
                    throw Failure.truncatedVIF(part: partIndex, offset: offset)
                }
                for instruction in instructions {
                    if case let .call(address) = instruction.command {
                        try interpreter.call(address ?? interpreter.lastProgram)
                    } else {
                        interpreter.machine.apply(instruction.command, bytes: model.bytes)
                    }
                }
                p = end
            }
            for (key, count) in interpreter.unknown { unknown[key, default: 0] += count }
            dropped += interpreter.dropped
            meshes += interpreter.finish()
        }
        self.meshes = meshes
        unknownPrograms = unknown
        droppedTriangles = dropped
    }

    struct Interpreter {
        struct MeshKey: Hashable {
            let material: Int?
            let pass: ModelMesh.Pass
            let environmentMapped: Bool
        }

        enum TexCoord {
            case explicit(SIMD2<Float>)
            /// Environment-map normal, resolved to a UV when drawn.
            case environment(SIMD3<Float>)
        }

        let part: Int
        let pose: [simd_float4x4]
        let normalPose: [simd_float3x3]
        let passes: Set<ModelMesh.Pass>
        var machine = VIF.Machine()
        var staged = 0
        var material: Int?
        var environment = false
        var environmentScale = SIMD2<Float>(0.5, 0.5)
        var lastProgram = 0
        var slots: [Int: Int] = [:]
        var accumulator: [Int: SIMD3<Float>] = [:]
        var vertices: [Int: SIMD3<Float>] = [:]
        var normals: [Int: SIMD3<Float>] = [:]
        var colours: [Int: Int] = [:]
        var colourValues: [Int: SIMD4<Float>] = [:]
        var texCoords: [Int: TexCoord] = [:]
        var meshes: [MeshKey: ModelMesh] = [:]
        var order: [MeshKey] = []
        var lookup: [MeshKey: [ModelMesh.Vertex: UInt32]] = [:]
        var unknown: [Int: Int] = [:]
        var dropped = 0

        init(part: Int, pose: [simd_float4x4], normalPose: [simd_float3x3], passes: Set<ModelMesh.Pass>) {
            self.part = part
            self.pose = pose
            self.normalPose = normalPose
            self.passes = passes
        }

        func slot(_ index: UInt32) throws -> Int {
            guard let bone = slots[Int(index)] else { throw Failure.undefinedSlot(part: part, slot: Int(index)) }
            return bone
        }

        static func rgba(_ q: SIMD4<UInt32>) -> SIMD4<Float> {
            let f = q.floats
            return SIMD4(f.x / 255, f.y / 255, f.z / 255, f.w / 128)
        }

        mutating func call(_ program: Int) throws {
            lastProgram = program
            let m = machine
            let header = m[0]
            switch program {
            case 0x2E, 0x06, 0x54:
                slots[Int(header.y)] = staged
            case 0x02, 0x04, 0x1A, 0x1C:
                let matrix = pose[try slot(header.y)]
                let accumulate = header.z != 0
                for i in 0 ..< Int(header.x) {
                    let index = Int(m[2 + 2 * i].x)
                    let p = matrix * m[1 + 2 * i].floats
                    let sum = SIMD3(p.x, p.y, p.z)
                    accumulator[index] = accumulate ? (accumulator[index] ?? .zero) + sum : sum
                }
            case 0x08, 0x0A:
                for i in 0 ..< Int(header.x) {
                    let index = Int(m[1 + i].x)
                    if let v = accumulator[index] { vertices[index] = v }
                }
            case 0x20, 0x22:
                let matrix = normalPose[try slot(header.y)]
                let accumulate = header.w != 0
                for i in 0 ..< Int(header.x) {
                    let q = m[1 + i]
                    let f = q.floats
                    let n = matrix * SIMD3(f.x, f.y, f.z)
                    normals[Int(q.w)] = accumulate ? (normals[Int(q.w)] ?? .zero) + n : n
                }
            case 0x12:
                for i in 0 ..< Int(header.x) {
                    let pair = m[1 + i]
                    colours[Int(pair.y)] = Int(pair.x)
                }
            case 0x24:
                for i in 0 ..< Int(header.x) {
                    let pair = m[2 + 2 * i]
                    colours[Int(pair.y)] = Int(pair.x)
                    colourValues[Int(pair.y)] = Self.rgba(m[1 + 2 * i])
                }
            case 0x28:
                for i in 0 ..< Int(header.x) {
                    colourValues[Int(m[2 + 2 * i].x)] = Self.rgba(m[1 + 2 * i])
                }
            case 0x0C:
                for i in 0 ..< Int(header.x) {
                    let q = m[1 + i]
                    texCoords[Int(q.z)] = .explicit(SIMD2(Float(bitPattern: q.x), Float(bitPattern: q.y)))
                }
            case 0x50:
                let f = header.floats
                environmentScale = SIMD2(f.x, f.y)
            case 0x4E, 0x52:
                let matrix = normalPose[try slot(header.y)]
                for i in 0 ..< Int(header.x) {
                    let q = m[1 + i]
                    let f = q.floats
                    let n = matrix * SIMD3(f.x, f.y, f.z)
                    texCoords[Int(q.w)] = .environment(n)
                }
            case 0x18, 0x4C:
                let pass: ModelMesh.Pass = environment ? .environment : .base
                guard passes.contains(pass) else { break }
                let textured = program == 0x18
                for t in 0 ..< Int(header.x) {
                    var corners: [ModelMesh.Vertex] = []
                    var environmentMapped = false
                    for k in 0 ..< 3 {
                        let q = m[1 + 3 * t + k]
                        guard let position = vertices[Int(q.x)] else { break }
                        let normal = normals[colours[Int(q.y)] ?? Int(q.y)] ?? .zero
                        let length = simd_length(normal)
                        var uv = SIMD2<Float>.zero
                        if textured {
                            switch texCoords[Int(q.z)] {
                            case let .explicit(st)?: uv = st
                            case let .environment(n)?:
                                let unit = simd_length(n) > 0 ? simd_normalize(n) : n
                                uv = SIMD2<Float>(0.5, 0.5) + environmentScale * SIMD2(unit.x, unit.y)
                                environmentMapped = true
                            case nil: break
                            }
                        }
                        corners.append(ModelMesh.Vertex(position: position, normal: length > 0 ? normal / length : normal, uv: uv,
                                                        color: colourValues[Int(q.y)] ?? SIMD4(repeating: 1)))
                    }
                    guard corners.count == 3 else {
                        dropped += 1
                        continue
                    }
                    emit(corners, key: MeshKey(material: textured ? material : nil, pass: pass, environmentMapped: environmentMapped))
                }
            case 0x5C:
                environment = true
            case 0x5E:
                environment = false
            case 0x14, 0x2A, 0x32, 0x58, 0x3C, 0x3E, 0x40:
                // GIF kick, colour/scale constants, per-draw header.
                break
            default:
                unknown[program, default: 0] += 1
            }
        }

        mutating func emit(_ corners: [ModelMesh.Vertex], key: MeshKey) {
            if meshes[key] == nil {
                meshes[key] = ModelMesh(part: part, material: key.material, pass: key.pass, isEnvironmentMapped: key.environmentMapped)
                order.append(key)
            }
            for corner in corners {
                if let index = lookup[key]?[corner] {
                    meshes[key]!.indices.append(index)
                } else {
                    let index = UInt32(meshes[key]!.vertices.count)
                    meshes[key]!.vertices.append(corner)
                    meshes[key]!.indices.append(index)
                    lookup[key, default: [:]][corner] = index
                }
            }
        }

        func finish() -> [ModelMesh] { order.compactMap { meshes[$0] } }
    }
}
