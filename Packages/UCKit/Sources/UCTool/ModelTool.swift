import Foundation
import simd
import UCFormats

/// `uc-tool model …`: decode a character/stage sub-file (see re/NOTES.md, "3D models").
enum ModelTool {
    struct Loaded {
        let file: SectionedFile
        let model: ModelFile
        let textures: ModelTextureTable?
    }

    static func load(archive url: URL, entry: Int, subfile: Int) throws -> Loaded {
        let archive = try DIGArchive(url: url)
        guard entry < archive.entries.count else { fail("no entry \(entry)") }
        let data = try archive.read(archive.entries[entry])
        let table = DIGSubfileTable(data, count: Int(archive.entries[entry].subfileCount))
        guard let sub = table.subfiles.first(where: { Int($0.index) == subfile }) else { fail("no sub-file \(subfile)") }
        guard let file = SectionedFile(Array(table.slice(sub, of: data))), let section = file.section(.model) else {
            fail("entry \(entry) sub-file \(subfile) is not a sectioned model file")
        }
        let model = try ModelFile(section)
        let textures = try file.section(.textures).map { try ModelTextureTable($0) }
        return Loaded(file: file, model: model, textures: textures)
    }

    /// Tries every sub-file of the archive as a sectioned model file; with `sheet`, also writes a
    /// contact sheet of front views (8 per row, in listing order).
    static func scan(archive url: URL, sheet: URL?) throws {
        let archive = try DIGArchive(url: url)
        var models = 0, failures = 0
        var unknown: [Int: Int] = [:]
        var thumbnails: [RenderedImage] = []
        for entry in archive.entries where !entry.isEmpty && entry.subfileCount > 0 {
            let data = try archive.read(entry)
            let table = DIGSubfileTable(data, count: Int(entry.subfileCount))
            guard table.isConsistent(entrySize: data.count) else { continue }
            for sub in table.subfiles where sub.size >= 0x40 {
                let bytes = Array(table.slice(sub, of: data))
                guard let count = bytes.first, count == 0x14 || count == 0x17,
                      let file = SectionedFile(bytes), let section = file.section(.model), section.count >= 0x40 else { continue }
                let label = String(format: "%04d/%02d", entry.index, sub.index)
                do {
                    let model = try ModelFile(section)
                    let geometry = try ModelGeometry(model: model)
                    let table = try file.section(.textures).map { try ModelTextureTable($0) }
                    let materials = table?.materials.count ?? 0
                    if sheet != nil {
                        var textures: [Int: DecodedTexture] = [:]
                        for m in Set(geometry.meshes.compactMap(\.material)) { textures[m] = table?.decodeTexture(m) }
                        thumbnails.append(renderViews(geometry, textures: textures, materials: table?.materials ?? [],
                                                      views: [(0, 0)], size: 192))
                    }
                    for (k, v) in geometry.unknownPrograms { unknown[k, default: 0] += v }
                    models += 1
                    print("\(label)\tsections=\(count)\tbones=\(model.bones.count)\tparts=\(model.parts.count)\ttris=\(geometry.triangleCount)\tdropped=\(geometry.droppedTriangles)\tmaterials=\(materials)")
                } catch {
                    failures += 1
                    print("\(label)\tnot a model: \(error)")
                }
            }
        }
        print("models: \(models), rejected: \(failures), unmodelled VU1 programs: "
            + unknown.sorted { $0.key < $1.key }.map { "\(hex($0.key))×\($0.value)" }.joined(separator: " "))
        if let sheet, !thumbnails.isEmpty {
            let columns = 8, cell = thumbnails[0].width
            let rows = (thumbnails.count + columns - 1) / columns
            var rgba = [UInt8](repeating: 0, count: columns * cell * rows * cell * 4)
            for (n, image) in thumbnails.enumerated() {
                let ox = (n % columns) * cell, oy = (n / columns) * cell
                for y in 0 ..< cell {
                    let s = y * cell * 4, d = ((oy + y) * columns * cell + ox) * 4
                    rgba.replaceSubrange(d ..< d + cell * 4, with: image.rgba[s ..< s + cell * 4])
                }
            }
            try RenderedImage(width: columns * cell, height: rows * cell, rgba: rgba).writePNG(to: sheet)
        }
    }

    static func info(_ loaded: Loaded) throws {
        let model = loaded.model
        print("sections: " + loaded.file.sections.enumerated().filter { !$0.element.isEmpty }
            .map { "\($0.offset):\(hex($0.element.lowerBound))+\(hex($0.element.count))" }.joined(separator: " "))
        print("bones: \(model.bones.count)  parts: \(model.parts.count)")
        for (i, bone) in model.bones.enumerated() {
            let t = bone.translation
            print(String(format: "  bone %2d parent %3d  t=(%.3f %.3f %.3f)", i, bone.parent ?? -1, t.x, t.y, t.z))
        }
        let geometry = try ModelGeometry(model: model, passes: [.base, .environment])
        for (i, part) in model.parts.enumerated() {
            let meshes = geometry.meshes.filter { $0.part == i }
            let summary = meshes.map { "\($0.pass == .base ? "base" : "env") mat \($0.material.map(String.init) ?? "-"): \($0.indices.count / 3) tris" }
            print("  part \(i): \(part.commands.count) DMA steps, \(part.vif.count / 16) qw, textures \(part.textureBindings.map { "\($0.material)@\($0.slot)" }), \(summary.joined(separator: ", "))")
        }
        if let textures = loaded.textures {
            print("materials: \(textures.materials.count)  uploads: \(textures.uploads.count)")
            for (i, m) in textures.materials.enumerated() {
                print("  material \(i): psm \(hex(m.psm)) \(m.width)×\(m.height) tcc \(m.usesTextureAlpha ? 1 : 0) tfx \(m.function) wrap \(m.wrapS)/\(m.wrapT)")
            }
        }
        let bounds = Bounds(geometry.meshes)
        print(String(format: "triangles: %d  bounds min (%.2f %.2f %.2f) max (%.2f %.2f %.2f)", geometry.triangleCount,
                     bounds.min.x, bounds.min.y, bounds.min.z, bounds.max.x, bounds.max.y, bounds.max.z))
        if !geometry.unknownPrograms.isEmpty {
            print("unmodelled VU1 programs: " + geometry.unknownPrograms.sorted { $0.key < $1.key }.map { "\(hex($0.key))×\($0.value)" }.joined(separator: " "))
        }
    }

    /// Writes `model.obj`, `model.mtl`, one PNG per material and `render.png` (4 views).
    static func export(_ loaded: Loaded, to out: URL, name: String) throws {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let geometry = try ModelGeometry(model: loaded.model)
        var textures: [Int: DecodedTexture] = [:]
        var mtl = ""
        for material in Set(geometry.meshes.compactMap(\.material)).sorted() {
            guard let texture = loaded.textures?.decodeTexture(material) else { continue }
            textures[material] = texture
            let file = String(format: "%@_tex%02d.png", name, material)
            try writePNG(texture, to: out.appending(path: file))
            mtl += "newmtl mat\(material)\nKd 1 1 1\nmap_Kd \(file)\n"
            if loaded.textures?.materials[material].usesTextureAlpha == true { mtl += "map_d -imfchan m \(file)\n" }
            mtl += "\n"
        }
        mtl += "newmtl untextured\nKd 0.8 0.8 0.8\n"
        try Data(mtl.utf8).write(to: out.appending(path: "\(name).mtl"))

        var obj = "# \(name): \(geometry.triangleCount) triangles\nmtllib \(name).mtl\n"
        var base = 1
        for (i, mesh) in geometry.meshes.enumerated() {
            obj += "o part\(mesh.part)_\(i)\nusemtl \(mesh.material.map { textures[$0] != nil ? "mat\($0)" : "untextured" } ?? "untextured")\n"
            for v in mesh.vertices {
                obj += String(format: "v %.5f %.5f %.5f\nvt %.5f %.5f\nvn %.4f %.4f %.4f\n", v.position.x, v.position.y, v.position.z,
                              v.uv.x, 1 - v.uv.y, v.normal.x, v.normal.y, v.normal.z)
            }
            for t in stride(from: 0, to: mesh.indices.count, by: 3) {
                let a = Int(mesh.indices[t]) + base, b = Int(mesh.indices[t + 1]) + base, c = Int(mesh.indices[t + 2]) + base
                obj += "f \(a)/\(a)/\(a) \(b)/\(b)/\(b) \(c)/\(c)/\(c)\n"
            }
            base += mesh.vertices.count
        }
        try Data(obj.utf8).write(to: out.appending(path: "\(name).obj"))

        let views: [(yaw: Float, pitch: Float)] = [(0, 0), (.pi / 2, 0), (.pi, 0), (-.pi / 4, 0.35)]
        let image = renderViews(geometry, textures: textures, materials: loaded.textures?.materials ?? [], views: views, size: 512)
        try image.writePNG(to: out.appending(path: "\(name)_render.png"))
        print("wrote \(geometry.meshes.count) meshes, \(geometry.triangleCount) triangles, \(textures.count) textures to \(out.path)")
    }
}

struct Bounds {
    var min = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
    var max = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

    init(_ meshes: [ModelMesh]) {
        for mesh in meshes {
            for v in mesh.vertices {
                min = simd_min(min, v.position)
                max = simd_max(max, v.position)
            }
        }
    }

    var center: SIMD3<Float> { (min + max) / 2 }
    var size: SIMD3<Float> { max - min }
}
