import CryptoKit
import Foundation
import ImageIO
import Metal
import UCAudio
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
//   uc-tool adx info    <file.AFS>
//   uc-tool adx decode  <file.AFS> <index> <out.wav> [loops=0]
//   uc-tool adx verify  <file.AFS>
//   uc-tool adx table   <CFC.DIG>   — stream volumes (entry 567)
//   uc-tool adx mix     <file.AFS> <index> <out.wav> <seconds>   — offline, through UCAudio
//   uc-tool adx play    <file.AFS> <index> [seconds=15] [volume=1]
//   uc-tool disc info   <disc.iso | disc-folder>
//   uc-tool tex extract <disc.iso | disc-folder> <out-dir> <entry> <subfile> [archive=CFC_UK.DIG]
//   uc-tool movie info    <MV00.DSI | disc.iso | disc-folder>
//   uc-tool movie convert <MV00.DSI | disc.iso | disc-folder> <out-dir> [--height 0 | 1080] [--crf 18] [--keep-streams]
//   uc-tool pack        <disc.iso> <out-dir>   — the files the app embeds (GameData/)
//   uc-tool model scan   <CFC.DIG> [sheet.png]
//   uc-tool model info   <CFC.DIG> <entry> <subfile>
//   uc-tool model export <CFC.DIG> <entry> <subfile> <out-dir>   — OBJ + MTL + PNG textures + render
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
    /// 2: the intro movie ships converted (HEVC Main10 + AAC, `MV/MV00.mp4`) instead of `MV/MV00.DSI`.
    static let format = 2
    static let files = ["SYSTEM.CNF", "CFC_UK.DIG", "XA/XA.AFS", "XA/XAVOICE.AFS"]
    static let movie = "MV/MV00.DSI"

    /// Copies `file` to `target` and returns its SHA-256 (hex).
    static func copy(_ file: DiscImage.File, to target: URL) throws -> String {
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let writer = try FileHandle(forWritingTo: target)
        let reader = try FileHandle(forReadingFrom: file.url)
        defer { try? writer.close(); try? reader.close() }
        try reader.seek(toOffset: file.offset)
        var hash = SHA256()
        var remaining = file.size
        while remaining > 0 {
            let chunk = try reader.read(upToCount: Int(min(remaining, 8 << 20))) ?? Data()
            guard !chunk.isEmpty else { fail("short read in \(target.lastPathComponent)") }
            hash.update(data: chunk)
            try writer.write(contentsOf: chunk)
            remaining -= UInt64(chunk.count)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 3 else {
    fail("usage: uc-tool (dig|afs|adx|disc|tex|pack) <command> <archive> [arguments...]")
}
let archiveURL = URL(fileURLWithPath: arguments[arguments[0] == "pack" ? 1 : 2])

func hex(_ value: some BinaryInteger) -> String { "0x" + String(value, radix: 16) }

/// 16-bit PCM RIFF/WAVE of interleaved samples.
func wav(_ samples: [Int16], channels: Int, rate: Int) -> Data {
    var data = Data(capacity: 44 + samples.count * 2)
    func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { data.append(contentsOf: $0) } }
    func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { data.append(contentsOf: $0) } }
    data.append(contentsOf: Array("RIFF".utf8)); u32(36 + samples.count * 2)
    data.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(channels)
    u32(rate); u32(rate * channels * 2); u16(channels * 2); u16(16)
    data.append(contentsOf: Array("data".utf8)); u32(samples.count * 2)
    samples.withUnsafeBytes { data.append(contentsOf: $0) }
    return data
}

/// Decodes `count` sample frames of an ADX stream through ``ADXCursor`` (following the loop).
func render(_ stream: Data, header: ADXHeader, count: Int, loops: Bool) -> [Int16] {
    var cursor = ADXCursor(header: header, loops: loops)
    var cache = [Int16](repeating: 0, count: cursor.cacheCount)
    var out = [Int16]()
    out.reserveCapacity(count * header.channelCount)
    stream.withUnsafeBytes { raw in
        cache.withUnsafeMutableBufferPointer { cache in
            _ = cursor.read(raw, count: count, cache: cache.baseAddress!) { run, n in
                out.append(contentsOf: UnsafeBufferPointer(start: run, count: n * header.channelCount))
            }
        }
    }
    return out
}

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

case ("adx", "info"):
    // One line per entry: codec, layout, length, loop; then a summary of the codecs found.
    let archive = try AFSArchive(url: archiveURL)
    var codecs: [String: Int] = [:]
    var looped = 0, misaligned = 0
    for entry in archive.entries {
        let name = entry.name ?? "-"
        guard let header = try? ADXHeader(archive.read(entry, prefix: ADXHeader.maximumHeaderSize)) else {
            codecs["not ADX", default: 0] += 1
            print("\(entry.index)\t\(name)\tnot ADX\tsize=\(entry.size)")
            continue
        }
        let codec = "\(header.encoding) v\(header.version) \(header.bitsPerSample)-bit/\(header.frameSize)B"
            + (header.isEncrypted ? " encrypted" : "")
        codecs[codec, default: 0] += 1
        // Bytes the declared sample count needs; the encoder appends an end-of-stream frame.
        let frames = (header.sampleCount + header.samplesPerFrame - 1) / header.samplesPerFrame
        let needed = header.dataOffset + frames * header.frameSize * header.channelCount
        var loop = "-"
        if let l = header.loop {
            looped += 1
            let block = header.frameSize * header.channelCount
            let aligned = l.startByte == header.dataOffset + l.start / header.samplesPerFrame * block
            if !aligned { misaligned += 1 }
            loop = "\(l.start)…\(l.end)" + (aligned ? "" : " (start byte \(l.startByte) off-frame)")
        }
        print("\(entry.index)\t\(name)\t\(codec)\t\(header.channelCount)ch\t\(header.sampleRate)Hz\t"
              + "\(header.sampleCount)\t\(String(format: "%.2f", header.duration))s\tloop=\(loop)\t"
              + "data=\(needed <= Int(entry.size) ? "ok" : "short by \(needed - Int(entry.size))")")
    }
    for (codec, count) in codecs.sorted(by: { $0.value > $1.value }) { print("# \(count)× \(codec)") }
    print("# \(archive.entries.count) entries, \(looped) looped, \(misaligned) loop starts off-frame")

case ("adx", "decode"):
    guard arguments.count >= 5, let index = Int(arguments[3]) else {
        fail("usage: uc-tool adx decode <file.AFS> <index> <out.wav> [loops=0]")
    }
    let archive = try AFSArchive(url: archiveURL)
    guard archive.entries.indices.contains(index) else { fail("no entry \(index)") }
    let stream = try archive.read(archive.entries[index])
    let extraLoops = arguments.count > 5 ? Int(arguments[5]) ?? 0 : 0
    let clock = ContinuousClock.now
    var (header, samples) = try ADXDecoder.decode(stream)
    let elapsed = ContinuousClock.now - clock
    if extraLoops > 0, let loop = header.loop {
        samples = render(stream, header: header, count: loop.end + extraLoops * (loop.end - loop.start), loops: true)
    }
    var sum = 0.0, peak = 0, clipped = 0
    for s in samples {
        let v = Int(s)
        sum += Double(v * v)
        peak = max(peak, abs(v))
        if v >= 32767 || v <= -32768 { clipped += 1 }
    }
    let rms = samples.isEmpty ? 0 : (sum / Double(samples.count)).squareRoot()
    try wav(samples, channels: header.channelCount, rate: header.sampleRate).write(to: URL(fileURLWithPath: arguments[4]))
    let frames = samples.count / header.channelCount
    print("entry \(index): \(header.channelCount)ch \(header.sampleRate)Hz, \(frames) samples "
          + "(\(String(format: "%.2f", Double(frames) / Double(header.sampleRate)))s, header \(header.sampleCount)), "
          + "decoded in \(elapsed); RMS \(String(format: "%.1f", rms)) (\(String(format: "%.1f", 20 * log10(max(rms, 1) / 32768))) dBFS), "
          + "peak \(peak), \(clipped) clipped")
    if let loop = header.loop { print("loop \(loop.start)…\(loop.end)\(extraLoops > 0 ? " rendered \(extraLoops) extra pass(es)" : "")") }

case ("adx", "verify"):
    // Decodes every entry: the data must reach the header's sample count; reports level,
    // clipping and the jump at each loop seam against the stream's typical sample step.
    let archive = try AFSArchive(url: archiveURL)
    let clock = ContinuousClock.now
    var decodedSamples = 0, failures = 0
    for entry in archive.entries {
        guard let stream = try? archive.read(entry), let header = try? ADXHeader(stream), header.isDecodable else {
            failures += 1
            print("\(entry.index)\tnot decodable")
            continue
        }
        let samples = render(stream, header: header, count: header.sampleCount, loops: false)
        let channels = header.channelCount
        decodedSamples += samples.count
        var sum = 0.0, clipped = 0
        for s in samples {
            sum += Double(Int(s) * Int(s))
            if s == .max || s == .min { clipped += 1 }
        }
        let rms = (sum / Double(max(samples.count, 1))).squareRoot()
        var seam = "-"
        if let loop = header.loop, loop.end >= 2 {
            // Linear-prediction error of the jump (x[end-1], x[end-2] → x[start]) and the
            // share of the track's own samples that are at least as unpredictable.
            func x(_ i: Int, _ c: Int) -> Int { Int(samples[i * channels + c]) }
            var worst = 0.0
            for c in 0 ..< channels {
                let error = abs(x(loop.start, c) - (2 * x(loop.end - 1, c) - x(loop.end - 2, c)))
                var rarer = 0
                for i in 2 ..< samples.count / channels where abs(x(i, c) - (2 * x(i - 1, c) - x(i - 2, c))) >= error {
                    rarer += 1
                }
                worst = max(worst, 100 - 100 * Double(rarer) / Double(samples.count / channels))
            }
            seam = String(format: "p%.1f", worst)
        }
        let complete = samples.count == header.sampleCount * channels
        if !complete { failures += 1 }
        print("\(entry.index)\t\(complete ? "ok" : "SHORT \(samples.count / channels)/\(header.sampleCount)")\t"
              + "rms=\(String(format: "%.0f", rms))\tclipped=\(clipped)\tseam=\(seam)")
    }
    let elapsed = ContinuousClock.now - clock
    print("# \(archive.entries.count - failures) ok, \(failures) failures, \(decodedSamples) samples in \(elapsed)")
    if failures > 0 { exit(2) }

case ("adx", "table"):
    // The stream table (DIG entry 567): per-stream volume and channels, as the play call uses them.
    let archive = try DIGArchive(url: archiveURL)
    let entry = archive.entries[SoundTable.entry]
    let data = try archive.read(entry)
    let subfiles = DIGSubfileTable(data, count: Int(entry.subfileCount))
    guard let subfile = subfiles.subfiles.first(where: { Int($0.index) == SoundTable.subfile }) else { fail("no stream table") }
    let table = try SoundTable(subfiles.slice(subfile, of: data))
    for (kind, streams) in [("music", table.music), ("movie", table.movies), ("voice", table.voices)] {
        for stream in streams {
            let level = CRIVolume.level(streamVolume: stream.volume)
            print("\(kind)\t\(stream.index)\t\(stream.name ?? "-")\tvolume=\(stream.volume)\t\(stream.channels)ch\t"
                  + "\(String(format: "%.1f", -Double(CRIVolume.attenuation(level: level)) / 10)) dB")
        }
    }

case ("adx", "mix"):
    // Renders the playback path (AudioSystem's music bus, AVAudioEngine offline) and checks
    // it against the cursor's own loop-following decode.
    guard arguments.count >= 6, let index = Int(arguments[3]), let seconds = Double(arguments[5]) else {
        fail("usage: uc-tool adx mix <file.AFS> <index> <out.wav> <seconds>")
    }
    let archive = try AFSArchive(url: archiveURL)
    let stream = try archive.read(archive.entries[index])
    let track = try ADXTrack(stream)
    let system = try AudioSystem.offline()
    try system.start()
    system.play(track, on: .music)
    let total = Int(seconds * AudioSystem.sampleRate)
    var mixed: [Int16] = []
    mixed.reserveCapacity(total * 2)
    var peakError: Float = 0
    let reference = render(stream, header: track.header, count: total, loops: true)
    let channels = track.header.channelCount
    let clock = ContinuousClock.now
    while mixed.count < total * 2 {
        let buffer = try system.renderOffline(frames: min(4096, total - mixed.count / 2))
        let left = buffer.floatChannelData![0], right = buffer.floatChannelData![1]
        for i in 0 ..< Int(buffer.frameLength) {
            let frame = mixed.count / 2
            for (c, value) in [left[i], right[i]].enumerated() where frame < reference.count / channels {
                let expected = Float(reference[frame * channels + min(c, channels - 1)]) / 32768
                peakError = max(peakError, abs(value - expected))
            }
            mixed.append(Int16(max(-32768, min(32767, (left[i] * 32768).rounded()))))
            mixed.append(Int16(max(-32768, min(32767, (right[i] * 32768).rounded()))))
        }
    }
    let elapsed = ContinuousClock.now - clock
    try wav(mixed, channels: 2, rate: Int(AudioSystem.sampleRate)).write(to: URL(fileURLWithPath: arguments[4]))
    print("mixed \(String(format: "%.1f", seconds))s in \(elapsed); peak difference to the decoder \(peakError) "
          + "(\(String(format: "%.1f", 20 * log10(max(peakError, 1e-9)))) dBFS)")

case ("adx", "play"):
    guard arguments.count >= 4, let index = Int(arguments[3]) else {
        fail("usage: uc-tool adx play <file.AFS> <index> [seconds=15] [volume=1]")
    }
    let archive = try AFSArchive(url: archiveURL)
    let track = try ADXTrack(archive: archive, index: index)
    let seconds = arguments.count > 4 ? Double(arguments[4]) ?? 15 : 15
    let system = AudioSystem()
    system.setVolume(arguments.count > 5 ? Float(arguments[5]) ?? 1 : 1, for: .music)
    try system.start()
    system.play(track, on: .music, fadeIn: .milliseconds(500))
    print("playing entry \(index) (\(String(format: "%.1f", track.header.duration))s, loop \(track.header.loop.map { "\($0.start)…\($0.end)" } ?? "none"))")
    RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    print("still playing: \(system.isPlaying(.music))")
    system.stop(.music, fadeOut: .seconds(1))
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.2))

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

case ("movie", "info"):
    try movieInfo(arguments[2])

case ("movie", "convert"):
    guard arguments.count >= 4 else { fail("usage: uc-tool movie convert <MV00.DSI | disc> <out-dir> [options]") }
    try movieConvert(arguments[2], to: URL(fileURLWithPath: arguments[3], isDirectory: true),
                     MovieConversion(arguments: arguments.dropFirst(4)))

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
    case "modes":
        // modes[:<selection>] — SELECT MODE after its intro frames.
        let selection = name.count > 1 ? Int(name[1]) ?? 0 : 0
        var menu = ModeSelectMenu(file: try SpriteFile(try subfileBytes(archive, ModeSelectScreen.entry, ModeSelectScreen.subfile)),
                                  selection: selection)
        for _ in 0 ..< max(8, Options(arguments.dropFirst(5)).frames) { menu.tick(InputState()) }
        screen = menu.screen
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
        fail("unknown screen \(arguments[3]) (title, menu, menu:<0-2>, modes, modes:<0-10>, file:<entry>/<sub-file>[:<hex animation>,…])")
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
        let digest = try GamePack.copy(file, to: out.appending(path: path))
        manifest.append(["path": path, "size": file.size, "sha256": digest])
        print("\(path)\t\(file.size)\t\(digest)")
    }
    // The intro movie: converted once here (ffmpeg, package time only) to HEVC + AAC.
    let staging = FileManager.default.temporaryDirectory.appending(path: "nuc2-pack-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: staging) }
    let dsi = staging.appending(path: "MV00.DSI")
    _ = try GamePack.copy(try disc.file(GamePack.movie), to: dsi)
    try movieConvert(dsi.path, to: out.appending(path: "MV", directoryHint: .isDirectory), MovieConversion(arguments: []))
    let mp4 = out.appending(path: "MV/MV00.mp4")
    let size = (try FileManager.default.attributesOfItem(atPath: mp4.path)[.size] as? NSNumber)?.uint64Value ?? 0
    let digest = SHA256.hash(data: try Data(contentsOf: mp4, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
    manifest.append(["path": "MV/MV00.mp4", "size": size, "sha256": digest])
    print("MV/MV00.mp4\t\(size)\t\(digest)")
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
