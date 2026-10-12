import CryptoKit
import Foundation
import ImageIO
import Metal
import UCEngine
import UCFormats
import UCRender
import UniformTypeIdentifiers

// uc-tool — inspect and extract Naruto: Uzumaki Chronicles 2 data from the user's own disc.
//
//   uc-tool dig list    <CFC.DIG>
//   uc-tool dig verify  <CFC.DIG>
//   uc-tool dig extract <CFC.DIG> <out-dir> [entry...]
//   uc-tool afs list    <file.AFS>
//   uc-tool afs extract <file.AFS> <out-dir>
//   uc-tool disc info   <disc.iso | disc-folder>
//   uc-tool tex extract <disc.iso | disc-folder> <out-dir> <entry> <subfile> [archive=CFC_UK.DIG]
//   uc-tool pack        <disc.iso> <out-dir>   — the files the app embeds (GameData/)
//   uc-tool sprite info     <CFC.DIG> <entry> <subfile>
//   uc-tool sprite textures <CFC.DIG> <entry> <subfile> <out-dir>
//   uc-tool sprite scan     <CFC.DIG>
//   uc-tool sprite anims    <CFC.DIG> <entry> <subfile> <out-dir>   — every animation alone, 512×448
//   uc-tool screen render   <CFC.DIG> <screen> <out.png> [WxH] [--frames N] [--backend metal4|classic]
//                           screens: title (PRESS START), menu, menu:<0-2> (BEGIN! / CONTINUE! / OPTIONS),
//                                    file:<entry>/<sub-file>[:<hex animation>,…] (any sprite file, e.g. file:57/0)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// What the app embeds from the disc (English text and voices). Bump `format` whenever the
/// selection or a conversion step changes, so CI fetches a matching package.
enum GamePack {
    static let format = 1
    static let files = ["SYSTEM.CNF", "CFC_UK.DIG", "XA/XA.AFS", "XA/XAVOICE.AFS", "MV/MV00.DSI"]
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 3 else {
    fail("usage: uc-tool (dig|afs) (list|verify|extract) <archive> [out-dir] [entry...]")
}
let archiveURL = URL(fileURLWithPath: arguments[arguments[0] == "pack" ? 1 : 2])

func hex(_ value: some BinaryInteger) -> String { "0x" + String(value, radix: 16) }

func writePNG(_ texture: DecodedTexture, to url: URL) throws {
    let provider = CGDataProvider(data: Data(texture.rgba) as CFData)!
    let image = CGImage(width: texture.width, height: texture.height, bitsPerComponent: 8, bitsPerPixel: 32,
                        bytesPerRow: texture.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("cannot write \(url.path)") }
}

/// `[WxH] [--frames N] [--backend metal4|classic]`
struct Options {
    var size = SIMD2(1920, 1080)
    var frames = 0
    var backend = SpriteSnapshot.Backend.metal4

    init(_ arguments: ArraySlice<String>) {
        var rest = arguments.makeIterator()
        while let argument = rest.next() {
            switch argument {
            case "--frames": frames = rest.next().flatMap(Int.init) ?? 0
            case "--backend": backend = rest.next().flatMap(SpriteSnapshot.Backend.init(rawValue:)) ?? .metal4
            default:
                let parts = argument.split(separator: "x").compactMap { Int($0) }
                if parts.count == 2 { size = SIMD2(parts[0], parts[1]) }
            }
        }
    }
}

/// App/Shaders/Sprite.metal, compiled at run time (the app compiles it into default.metallib).
@MainActor
func spriteLibrary(_ device: any MTLDevice) throws -> any MTLLibrary {
    let path = ProcessInfo.processInfo.environment["NUC2_SHADERS"].map { URL(fileURLWithPath: $0) }
        ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../../App/Shaders")
    let source = try String(contentsOf: path.appending(path: "Sprite.metal"), encoding: .utf8)
    return try device.makeLibrary(source: source, options: nil)
}

/// Renders a sprite frame off-screen and writes it as an sRGB PNG (linear scene clamped to SDR white).
@MainActor
func renderPNG(_ frame: SpriteFrame, size: SIMD2<Int>, backend: SpriteSnapshot.Backend, to url: URL) throws {
    guard let device = MTLCreateSystemDefaultDevice() else { fail("no Metal device") }
    let pixels = try SpriteSnapshot.render(frame, width: size.x, height: size.y, device: device, library: try spriteLibrary(device), backend: backend)
    func encode(_ c: Float) -> UInt8 {
        let v = min(max(c, 0), 1)
        let s = v <= 0.0031308 ? v * 12.92 : 1.055 * powf(v, 1 / 2.4) - 0.055
        return UInt8(min(255, max(0, (s * 255).rounded())))
    }
    var rgba = [UInt8](repeating: 255, count: size.x * size.y * 4)
    for i in 0 ..< size.x * size.y {
        rgba[i * 4] = encode(pixels[i * 4]); rgba[i * 4 + 1] = encode(pixels[i * 4 + 1]); rgba[i * 4 + 2] = encode(pixels[i * 4 + 2])
    }
    try writePNG(DecodedTexture(width: size.x, height: size.y, rgba: rgba), to: url)
}

/// One sub-file of a DIG entry.
func subfileBytes(_ archive: DIGArchive, _ entryIndex: Int, _ subfileIndex: Int) throws -> [UInt8] {
    guard archive.entries.indices.contains(entryIndex) else { fail("no entry \(entryIndex)") }
    let entry = archive.entries[entryIndex]
    let data = try archive.read(entry)
    let table = DIGSubfileTable(data, count: Int(entry.subfileCount))
    guard let subfile = table.subfiles.first(where: { Int($0.index) == subfileIndex }) else { fail("no sub-file \(subfileIndex)") }
    return Array(table.slice(subfile, of: data))
}

switch (arguments[0], arguments[1]) {
case ("dig", "list"):
    let archive = try DIGArchive(url: archiveURL)
    for entry in archive.entries where !entry.isEmpty {
        print("\(entry.index)\tsector=\(hex(entry.sector))\tstored=\(entry.storedSize)\tsize=\(entry.size)\tsubfiles=\(entry.subfileCount)\t\(entry.isCompressed ? "lz" : "raw")")
    }

case ("dig", "verify"):
    let archive = try DIGArchive(url: archiveURL)
    var ok = 0, bad = 0, bytes = 0
    let clock = ContinuousClock.now
    for entry in archive.entries where !entry.isEmpty {
        do {
            let data = try archive.read(entry)
            bytes += data.count
            let table = DIGSubfileTable(data, count: Int(entry.subfileCount))
            if entry.subfileCount == 0 || table.isConsistent(entrySize: data.count) {
                ok += 1
            } else {
                bad += 1
                print("entry \(entry.index): sub-file table inconsistent (\(entry.subfileCount) sub-files, \(data.count) bytes)")
            }
        } catch {
            bad += 1
            print("entry \(entry.index): \(error)")
        }
    }
    print("verified \(ok) entries, \(bad) failures, \(bytes / 1_048_576) MiB expanded in \(ContinuousClock.now - clock)")
    if bad > 0 { exit(2) }

case ("dig", "extract"):
    guard arguments.count >= 4 else { fail("usage: uc-tool dig extract <CFC.DIG> <out-dir> [entry...]") }
    let archive = try DIGArchive(url: archiveURL)
    let out = URL(fileURLWithPath: arguments[3], isDirectory: true)
    let wanted = Set(arguments.dropFirst(4).compactMap(Int.init))
    for entry in archive.entries where !entry.isEmpty && (wanted.isEmpty || wanted.contains(entry.index)) {
        let data = try archive.read(entry)
        let dir = out.appending(path: String(format: "%04d", entry.index), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(data).write(to: dir.appending(path: "entry.bin"))
        let table = DIGSubfileTable(data, count: Int(entry.subfileCount))
        if table.isConsistent(entrySize: data.count) {
            for subfile in table.subfiles {
                let name = String(format: "%02d.bin", subfile.index)
                try Data(table.slice(subfile, of: data)).write(to: dir.appending(path: name))
            }
        }
        print("extracted entry \(entry.index) (\(data.count) bytes, \(table.subfiles.count) sub-files)")
    }

case ("afs", "list"):
    let archive = try AFSArchive(url: archiveURL)
    for entry in archive.entries {
        print("\(entry.index)\toffset=\(hex(entry.offset))\tsize=\(entry.size)\t\(entry.name ?? "-")")
    }

case ("afs", "extract"):
    guard arguments.count >= 4 else { fail("usage: uc-tool afs extract <file.AFS> <out-dir>") }
    let archive = try AFSArchive(url: archiveURL)
    let out = URL(fileURLWithPath: arguments[3], isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    for entry in archive.entries {
        let name = entry.name.flatMap { $0.isEmpty ? nil : $0 } ?? String(format: "%05d.adx", entry.index)
        try archive.read(entry).write(to: out.appending(path: name))
    }
    print("extracted \(archive.entries.count) files")

case ("disc", "info"):
    let disc = try DiscImage(url: archiveURL)
    try disc.validate()
    print("\(DiscImage.expectedExecutable) — \(disc.files.count) files")
    for path in disc.files.keys.sorted() where path.hasSuffix(".DIG") {
        let archive = try DIGArchive(file: try disc.file(path))
        print("\(path)\t\(archive.entries.filter { !$0.isEmpty }.count) entries")
    }

case ("tex", "extract"):
    guard arguments.count >= 6, let entryIndex = Int(arguments[4]), let subfileIndex = Int(arguments[5]) else {
        fail("usage: uc-tool tex extract <disc> <out-dir> <entry> <subfile> [archive]")
    }
    let disc = try DiscImage(url: archiveURL)
    let archive = try DIGArchive(file: try disc.file(arguments.count > 6 ? arguments[6] : "CFC_UK.DIG"))
    let entry = archive.entries[entryIndex]
    let data = try archive.read(entry)
    let table = DIGSubfileTable(data, count: Int(entry.subfileCount))
    guard let subfile = table.subfiles.first(where: { Int($0.index) == subfileIndex }) else { fail("no sub-file \(subfileIndex)") }
    let out = URL(fileURLWithPath: arguments[3], isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let textures = TextureSet.decode(Array(table.slice(subfile, of: data)))
    for (n, texture) in textures.enumerated() {
        try writePNG(texture, to: out.appending(path: String(format: "%04d_%02d_%03d.png", entryIndex, subfileIndex, n)))
    }
    print("decoded \(textures.count) textures")

case ("sprite", "info"), ("sprite", "textures"):
    guard arguments.count >= 5, let entryIndex = Int(arguments[3]), let subfileIndex = Int(arguments[4]) else {
        fail("usage: uc-tool sprite (info|textures) <CFC.DIG> <entry> <subfile> [out-dir]")
    }
    let archive = try DIGArchive(url: archiveURL)
    let file = try SpriteFile(try subfileBytes(archive, entryIndex, subfileIndex))
    if arguments[1] == "info" {
        let bank = file.bank
        print("frames \(bank.frames.count) animations \(bank.animations.count) keys \(bank.keys.count) pieces \(bank.pieces.count)")
        for (i, texture) in file.textures.textures.enumerated() {
            let t = texture.tex0
            print("texture \(i): psm \(hex(t.psm)) \(t.width)×\(t.height) tbw \(t.tbw) levels \(texture.levels) clut \(texture.clut.map(String.init) ?? "-")")
        }
    } else {
        guard arguments.count >= 6 else { fail("usage: uc-tool sprite textures <CFC.DIG> <entry> <subfile> <out-dir>") }
        let out = URL(fileURLWithPath: arguments[5], isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for (n, texture) in file.textures.decode().enumerated() {
            guard let texture else { continue }
            try writePNG(texture, to: out.appending(path: String(format: "%04d_%02d_t%02d.png", entryIndex, subfileIndex, n)))
        }
    }

case ("sprite", "scan"):
    // Every sub-file that parses as a sprite file, with its pixel formats.
    let archive = try DIGArchive(url: archiveURL)
    for entry in archive.entries where !entry.isEmpty {
        let data = try archive.read(entry)
        let table = DIGSubfileTable(data, count: Int(entry.subfileCount))
        guard table.isConsistent(entrySize: data.count) else { continue }
        for subfile in table.subfiles {
            let bytes = Array(table.slice(subfile, of: data))
            guard SpriteFile.looksLikeSpriteFile(bytes) else { continue }
            do {
                let file = try SpriteFile(bytes)
                let formats = Set(file.textures.textures.map { hex($0.tex0.psm) }).sorted().joined(separator: ",")
                print("\(entry.index)/\(subfile.index)\tanimations \(file.bank.animations.count)\ttextures \(file.textures.textures.count)\tpsm \(formats)")
            } catch {
                print("\(entry.index)/\(subfile.index)\terror \(error)")
            }
        }
    }

case ("screen", "render"):
    guard arguments.count >= 5 else {
        fail("usage: uc-tool screen render <CFC.DIG> <screen> <out.png> [WxH] [--frames N] [--backend metal4|classic]")
    }
    let options = Options(arguments.dropFirst(5))
    let archive = try DIGArchive(url: archiveURL)
    let name = arguments[3].split(separator: ":")
    var screen: SpriteScreen
    switch name.first {
    case "title":
        screen = TitleScreen.make(try SpriteFile(try subfileBytes(archive, TitleScreen.entry, TitleScreen.subfile)), phase: .pressStart)
    case "menu":
        let selection = name.count > 1 ? Int(name[1]) ?? 0 : 0
        screen = TitleScreen.make(try SpriteFile(try subfileBytes(archive, TitleScreen.entry, TitleScreen.subfile)), phase: .menu(selection: selection))
    case "file":
        // file:<entry>/<sub-file>[:<hex animation>,…] — one layer per animation (default: animation 0).
        let path = name.count > 1 ? name[1].split(separator: "/").compactMap { Int($0) } : []
        guard path.count == 2 else { fail("usage: file:<entry>/<sub-file>[:<hex animation>,…]") }
        let file = try SpriteFile(try subfileBytes(archive, path[0], path[1]))
        let animations = name.count > 2 ? name[2].split(separator: ",").compactMap { Int($0, radix: 16) } : [0]
        screen = SpriteScreen(files: [file])
        var object = SpriteObject()
        for (id, animation) in animations.enumerated() { object.add(id: id, animation: animation, bank: file.bank) }
        screen.objects = [object]
    default:
        fail("unknown screen \(arguments[3]) (title, menu, menu:<0-2>, file:<entry>/<sub-file>[:<hex animation>,…])")
    }
    screen.tick(frames: options.frames)
    try renderPNG(screen.frame(), size: options.size, backend: options.backend, to: URL(fileURLWithPath: arguments[4]))
    print("rendered \(arguments[3]) after \(options.frames) frames: \(screen.quads.count) quads, \(screen.atlas.layers.count) textures → \(arguments[4])")

case ("sprite", "anims"):
    guard arguments.count >= 6, let entryIndex = Int(arguments[3]), let subfileIndex = Int(arguments[4]) else {
        fail("usage: uc-tool sprite anims <CFC.DIG> <entry> <subfile> <out-dir> [--frames N]")
    }
    let options = Options(arguments.dropFirst(6))
    let archive = try DIGArchive(url: archiveURL)
    let file = try SpriteFile(try subfileBytes(archive, entryIndex, subfileIndex))
    let out = URL(fileURLWithPath: arguments[5], isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    for animation in file.bank.animations.indices {
        var screen = SpriteScreen(files: [file])
        var object = SpriteObject()
        object.add(id: 0, animation: animation, bank: file.bank)
        screen.objects = [object]
        screen.clearColor = SIMD3(0.05, 0.05, 0.05)
        screen.tick(frames: options.frames)
        try renderPNG(screen.frame(canvas: SpriteCanvas(pixelAspect: 1)), size: SIMD2(512, 448), backend: options.backend,
                      to: out.appending(path: String(format: "%04d_%02d_a%02x.png", entryIndex, subfileIndex, animation)))
    }
    print("rendered \(file.bank.animations.count) animations")

case ("pack", _):
    // `uc-tool pack <disc.iso> <out-dir>`: arguments[1] is the disc, arguments[2] the output.
    let disc = try DiscImage(url: URL(fileURLWithPath: arguments[1]))
    try disc.validate()
    let out = URL(fileURLWithPath: arguments[2], isDirectory: true)
    var manifest: [[String: Any]] = []
    for path in GamePack.files {
        let file = try disc.file(path)
        let target = out.appending(path: path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let writer = try FileHandle(forWritingTo: target)
        let reader = try FileHandle(forReadingFrom: file.url)
        try reader.seek(toOffset: file.offset)
        var hash = SHA256()
        var remaining = file.size
        while remaining > 0 {
            let chunk = try reader.read(upToCount: Int(min(remaining, 8 << 20))) ?? Data()
            guard !chunk.isEmpty else { fail("short read in \(path)") }
            hash.update(data: chunk)
            try writer.write(contentsOf: chunk)
            remaining -= UInt64(chunk.count)
        }
        try writer.close(); try reader.close()
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        manifest.append(["path": path, "size": file.size, "sha256": digest])
        print("\(path)\t\(file.size)\t\(digest)")
    }
    let json = try JSONSerialization.data(withJSONObject: ["format": GamePack.format, "source": DiscImage.expectedExecutable, "files": manifest],
                                          options: [.prettyPrinted, .sortedKeys])
    try json.write(to: out.appending(path: "manifest.json"))

default:
    fail("unknown command: \(arguments[0]) \(arguments[1])")
}
