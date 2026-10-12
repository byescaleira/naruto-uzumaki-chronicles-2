import CryptoKit
import Foundation
import ImageIO
import UCFormats
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
//   uc-tool model scan   <CFC.DIG> [sheet.png]
//   uc-tool model info   <CFC.DIG> <entry> <subfile>
//   uc-tool model export <CFC.DIG> <entry> <subfile> <out-dir>   — OBJ + MTL + PNG textures + render

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

case ("model", "scan"):
    try ModelTool.scan(archive: archiveURL, sheet: arguments.count > 3 ? URL(fileURLWithPath: arguments[3]) : nil)

case ("model", "info"), ("model", "export"):
    guard arguments.count >= 5, let entryIndex = Int(arguments[3]), let subfileIndex = Int(arguments[4]) else {
        fail("usage: uc-tool model (info|export) <CFC.DIG> <entry> <subfile> [out-dir]")
    }
    let loaded = try ModelTool.load(archive: archiveURL, entry: entryIndex, subfile: subfileIndex)
    if arguments[1] == "info" {
        try ModelTool.info(loaded)
    } else {
        guard arguments.count >= 6 else { fail("usage: uc-tool model export <CFC.DIG> <entry> <subfile> <out-dir>") }
        try ModelTool.export(loaded, to: URL(fileURLWithPath: arguments[5], isDirectory: true),
                             name: String(format: "%04d_%02d", entryIndex, subfileIndex))
    }

default:
    fail("unknown command: \(arguments[0]) \(arguments[1])")
}
