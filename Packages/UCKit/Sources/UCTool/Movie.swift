import CoreMedia
import CoreVideo
import Foundation
import UCFormats

// `uc-tool movie …`: demux MV00.DSI losslessly and convert it, at package time, into a file
// AVFoundation plays natively. The app never runs ffmpeg; only this tool does.

/// Where the movie bytes are: a `.DSI` file, or `MV/MV00.DSI` inside a disc image or folder.
struct MovieSource {
    static let discPath = "MV/MV00.DSI"

    let url: URL
    let offset: UInt64
    let size: UInt64

    init(path: String) throws {
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        if isDirectory.boolValue || url.pathExtension.lowercased() == "iso" {
            let file = try DiscImage(url: url).file(Self.discPath)
            (self.url, offset, size) = (file.url, file.offset, file.size)
        } else {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            (self.url, offset, size) = (url, 0, (attributes[.size] as? NSNumber)?.uint64Value ?? 0)
        }
    }
}

/// The two elementary streams of a DSI movie.
struct DemuxedMovie {
    let movie: DSIMovie
    let video: [UInt8]
    let audio: [UInt8]
    let unknownStreams: [Int32: Int]

    init(_ source: MovieSource) throws {
        var video: [UInt8] = [], audio: [UInt8] = [], unknown: [Int32: Int] = [:]
        video.reserveCapacity(Int(source.size))
        movie = try DSIMovie.demux(url: source.url, offset: source.offset, size: source.size) { stream, bytes in
            switch stream {
            case DSIMovie.StreamID.video: video.append(contentsOf: bytes)
            case DSIMovie.StreamID.audio: audio.append(contentsOf: bytes)
            default: unknown[stream, default: 0] += bytes.count
            }
        }
        (self.video, self.audio, unknownStreams) = (video, audio, unknown)
    }

    var audioSamplesPerChannel: Int {
        audio.count / SPUADPCMDecoder.frameSize * SPUADPCMDecoder.samplesPerFrame / DSIMovie.audioChannels
    }

    var audioDuration: Double { Double(audioSamplesPerChannel) / Double(DSIMovie.audioSampleRate) }

    func pcm() -> [Int16] {
        SPUADPCMDecoder.decodeInterleaved(audio, channels: DSIMovie.audioChannels, interleave: DSIMovie.audioInterleave)
    }
}

func movieInfo(_ path: String) throws {
    let source = try MovieSource(path: path)
    let demuxed = try DemuxedMovie(source)
    let movie = demuxed.movie
    print("\(source.url.lastPathComponent): \(source.size) bytes, \(movie.blocks.count) blocks of \(hex(DSIMovie.blockSize))")
    for (stream, size) in demuxed.unknownStreams.sorted(by: { $0.key < $1.key }) {
        print("unknown stream \(hex(UInt32(bitPattern: stream))): \(size) bytes")
    }
    guard let video = MPEGVideoStream.scan(demuxed.video) else { fail("no MPEG video sequence header") }
    let rate = video.frameRate.map { "\($0.numerator)/\($0.denominator)" } ?? "?"
    print("video  \(hex(UInt32(bitPattern: DSIMovie.StreamID.video))): \(demuxed.video.count) bytes, MPEG-\(video.isMPEG2 ? 2 : 1) "
        + "\(video.width)×\(video.height) aspect code \(video.aspectRatioCode), \(rate) fps, "
        + "\(video.isProgressive ? "progressive" : "interlaced"), \(video.bitRate / 1000) kbit/s, profile/level \(hex(video.profileAndLevel))")
    if let colour = video.colour {
        print("       video_format \(video.videoFormat ?? -1), primaries \(colour.primaries), transfer \(colour.transfer), matrix \(colour.matrix)")
    }
    let types = video.picturesByType.sorted { $0.key < $1.key }.map { "\(["?", "I", "P", "B", "D"][min($0.key, 4)])=\($0.value)" }
    print("       \(video.pictures) pictures (\(types.joined(separator: " "))), \(video.groupsOfPictures) GOPs, "
        + "\(video.sequenceHeaders) sequence headers, sequence end: \(video.hasSequenceEnd)")
    print("audio  \(hex(UInt32(bitPattern: DSIMovie.StreamID.audio))): \(demuxed.audio.count) bytes, SPU ADPCM, "
        + "\(DSIMovie.audioChannels) ch interleaved every \(hex(DSIMovie.audioInterleave)), \(DSIMovie.audioSampleRate) Hz, "
        + "\(demuxed.audioSamplesPerChannel) samples per channel")
    let videoDuration = video.duration ?? 0
    print(String(format: "duration video %.3f s, audio %.3f s (audio − video = %+.3f s)",
                 videoDuration, demuxed.audioDuration, demuxed.audioDuration - videoDuration))
}

/// Settings of the package-time conversion; the defaults are what the app embeds.
struct MovieConversion {
    /// The movie is 512×448 shown full screen on a 4:3 TV (pixels 7:6 wide). 0 keeps the
    /// stored pixels and tags the 7:6 pixel aspect, which AVFoundation applies when it scales
    /// to the screen; a height resamples once, here (Lanczos), to square 4:3 pixels.
    var height = 0
    var crf = 18
    var preset = "slow"
    var audioBitRate = "192k"
    var keepStreams = false
    /// `--super-resolution`: 4× through Apple's video super-resolution scaler (temporal, frame
    /// by frame) before encoding, 512×448 → 2048×1792 with the same 7:6 pixels. What the app
    /// embeds: the TV shows it at 2160 lines instead of stretching 448.
    var superResolution = false

    init(arguments: ArraySlice<String>) {
        var iterator = arguments.makeIterator()
        while let flag = iterator.next() {
            switch flag {
            case "--height": height = iterator.next().flatMap(Int.init) ?? height
            case "--crf": crf = iterator.next().flatMap(Int.init) ?? crf
            case "--preset": preset = iterator.next() ?? preset
            case "--audio-bitrate": audioBitRate = iterator.next() ?? audioBitRate
            case "--keep-streams": keepStreams = true
            case "--super-resolution": superResolution = true
            default: fail("unknown option \(flag)")
            }
        }
    }

    /// 4:3 at `height`, rounded to even sizes for 4:2:0.
    var width: Int { (height * 4 / 3 + 1) & ~1 }

    /// The pixel aspect that shows `width`×`height` as 4:3, reduced.
    static func pixelAspect(width: Int, height: Int) -> (Int, Int) {
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let (n, d) = (4 * height, 3 * width)
        let g = max(gcd(n, d), 1)
        return (n / g, d / g)
    }
}

func movieConvert(_ path: String, to outDirectory: URL, _ settings: MovieConversion) throws {
    let source = try MovieSource(path: path)
    let name = source.url.deletingPathExtension().lastPathComponent
    try FileManager.default.createDirectory(at: outDirectory, withIntermediateDirectories: true)
    let demuxed = try DemuxedMovie(source)
    guard let video = MPEGVideoStream.scan(demuxed.video), let rate = video.frameRate else {
        fail("no MPEG video sequence header")
    }
    // Lossless intermediates: the video elementary stream as stored, the audio decoded to PCM.
    let videoURL = outDirectory.appending(path: "\(name).m2v")
    let audioURL = outDirectory.appending(path: "\(name).wav")
    try Data(demuxed.video).write(to: videoURL)
    try WAVFile.pcm16(demuxed.pcm(), channels: DSIMovie.audioChannels, sampleRate: DSIMovie.audioSampleRate).write(to: audioURL)
    print("demuxed \(videoURL.lastPathComponent) (\(demuxed.video.count) bytes, \(video.pictures) pictures) and "
        + "\(audioURL.lastPathComponent) (\(demuxed.audioSamplesPerChannel) samples × \(DSIMovie.audioChannels) ch)")

    let output = outDirectory.appending(path: "\(name).mp4")
    if settings.superResolution {
        try superResolveMovie(video: videoURL, audio: audioURL, size: (video.width, video.height), rate: rate,
                              progressive: video.isProgressive, settings: settings, to: output)
        if !settings.keepStreams {
            try FileManager.default.removeItem(at: videoURL)
            try FileManager.default.removeItem(at: audioURL)
        }
        return
    }
    // Interlaced sources would need deinterlacing (bwdif) first; MV00 is progressive.
    var filters: [String] = []
    if !video.isProgressive { filters.append("bwdif=mode=send_frame") }
    // BT.601 matrix (the stream's BT.470 B/G tag; also what the IPU's YCbCr → RGB uses) →
    // BT.709 matrix, at 10 bits so the dark gradients do not band. Primaries and transfer are
    // kept: the CG was authored on BT.709/sRGB displays and the PAL tags are nominal.
    filters.append("colorspace=space=bt709:trc=bt709:primaries=bt709:range=tv:"
        + "ispace=bt470bg:itrc=bt709:iprimaries=bt709:irange=tv:format=yuv420p10")
    let size: (width: Int, height: Int)
    if settings.height > 0 {
        size = (settings.width, settings.height)
        filters.append("scale=\(size.width):\(size.height):flags=lanczos+accurate_rnd+full_chroma_int")
        filters.append("setsar=1")
    } else {
        size = (video.width, video.height)
        let (n, d) = MovieConversion.pixelAspect(width: video.width, height: video.height)
        filters.append("setsar=\(n)/\(d)")
    }
    let arguments = [
        "-nostdin", "-y", "-hide_banner", "-loglevel", "error", "-stats",
        "-f", "mpegvideo", "-framerate", "\(rate.numerator)/\(rate.denominator)", "-i", videoURL.path,
        "-i", audioURL.path,
        "-map", "0:v:0", "-map", "1:a:0", "-map_metadata", "-1", "-map_chapters", "-1",
        "-vf", filters.joined(separator: ","),
        "-c:v", "libx265", "-preset", settings.preset, "-crf", "\(settings.crf)", "-pix_fmt", "yuv420p10le",
        "-profile:v", "main10", "-tag:v", "hvc1",
        "-x265-params", "log-level=error:colorprim=bt709:transfer=bt709:colormatrix=bt709:range=limited",
        "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", "-color_range", "tv",
        "-c:a", "aac_at", "-b:a", settings.audioBitRate,
        "-fflags", "+bitexact", "-flags:v", "+bitexact", "-flags:a", "+bitexact",
        "-movflags", "+faststart", "-brand", "mp42",
        output.path,
    ]
    try runFFmpeg(arguments)
    if !settings.keepStreams {
        try FileManager.default.removeItem(at: videoURL)
        try FileManager.default.removeItem(at: audioURL)
    }
    let bytes = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0
    print("wrote \(output.lastPathComponent): HEVC Main10 \(size.width)×\(size.height) \(rate.numerator)/\(rate.denominator) fps "
        + "+ AAC \(settings.audioBitRate), \(bytes) bytes")
}

/// Runs ffmpeg (`$FFMPEG`, else the first `ffmpeg` on `PATH`, else Homebrew's).
func runFFmpeg(_ arguments: [String]) throws {
    let environment = ProcessInfo.processInfo.environment
    let candidates = [environment["FFMPEG"]].compactMap { $0 }
        + (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/ffmpeg" }
        + ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
    guard let ffmpeg = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
        fail("ffmpeg not found (brew install ffmpeg, or set FFMPEG)")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: ffmpeg)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { fail("ffmpeg failed with status \(process.terminationStatus)") }
}

/// Decodes the MPEG-2 stream to RGB with ffmpeg, runs every frame through Apple's video
/// super-resolution scaler (in order, so it can use the previous frames), and pipes the 4×
/// frames into a second ffmpeg that encodes HEVC Main10 and muxes the audio.
func superResolveMovie(video: URL, audio: URL, size: (width: Int, height: Int), rate: (numerator: Int, denominator: Int),
                       progressive: Bool, settings: MovieConversion, to output: URL) throws {
    let scale = SuperResolution.scale
    let out = (width: size.width * scale, height: size.height * scale)
    let scaler = try SuperResolution(width: size.width, height: size.height, inputType: .video)

    // BT.601 YCbCr (the IPU's matrix) → full-range RGB, 16 bits per channel.
    var decodeFilters: [String] = []
    if !progressive { decodeFilters.append("bwdif=mode=send_frame") }
    decodeFilters.append("scale=in_color_matrix=bt601:in_range=tv:out_range=pc:flags=accurate_rnd+full_chroma_int,format=rgba64le")
    let decoder = try ffmpegProcess([
        "-nostdin", "-hide_banner", "-loglevel", "error",
        "-f", "mpegvideo", "-framerate", "\(rate.numerator)/\(rate.denominator)", "-i", video.path,
        "-vf", decodeFilters.joined(separator: ","), "-f", "rawvideo", "-pix_fmt", "rgba64le", "-",
    ], stdout: true)

    // RGB → BT.709 limited-range 10-bit 4:2:0, 7:6 pixels like the source.
    let (n, d) = MovieConversion.pixelAspect(width: size.width, height: size.height)
    let encoder = try ffmpegProcess([
        "-nostdin", "-y", "-hide_banner", "-loglevel", "error", "-stats",
        "-f", "rawvideo", "-pix_fmt", "rgba64le", "-video_size", "\(out.width)x\(out.height)",
        "-framerate", "\(rate.numerator)/\(rate.denominator)", "-color_range", "pc", "-i", "-",
        "-i", audio.path,
        "-map", "0:v:0", "-map", "1:a:0", "-map_metadata", "-1", "-map_chapters", "-1",
        "-vf", "scale=out_color_matrix=bt709:out_range=tv:flags=accurate_rnd+full_chroma_int,format=yuv420p10le,setsar=\(n)/\(d)",
        "-c:v", "libx265", "-preset", settings.preset, "-crf", "\(settings.crf)", "-pix_fmt", "yuv420p10le",
        "-profile:v", "main10", "-tag:v", "hvc1",
        "-x265-params", "log-level=error:colorprim=bt709:transfer=bt709:colormatrix=bt709:range=limited",
        "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", "-color_range", "tv",
        "-c:a", "aac_at", "-b:a", settings.audioBitRate,
        "-fflags", "+bitexact", "-flags:v", "+bitexact", "-flags:a", "+bitexact",
        "-movflags", "+faststart", "-brand", "mp42",
        output.path,
    ], stdin: true)

    let frameBytes = size.width * size.height * 8
    guard let reader = decoder.standardOutput as? Pipe, let writer = encoder.standardInput as? Pipe else { fail("ffmpeg pipes") }
    var frame = 0
    let started = Date()
    while true {
        guard let bytes = try reader.fileHandleForReading.read(upToCount: frameBytes), bytes.count == frameBytes else { break }
        let source = try SuperResolution.makeBuffer(width: size.width, height: size.height)
        copy(rgba64: bytes, into: source)
        let time = CMTime(value: CMTimeValue(frame * rate.denominator), timescale: CMTimeScale(rate.numerator))
        let upscaled = try scaler.process(source, sequential: true, time: time)
        try writer.fileHandleForWriting.write(contentsOf: rgba64(from: upscaled))
        frame += 1
        if frame % 250 == 0 {
            print(String(format: "super resolution: %d frames, %.1f fps", frame, Double(frame) / Date().timeIntervalSince(started)))
        }
    }
    try writer.fileHandleForWriting.close()
    decoder.waitUntilExit()
    encoder.waitUntilExit()
    guard decoder.terminationStatus == 0, encoder.terminationStatus == 0 else {
        fail("ffmpeg failed (decode \(decoder.terminationStatus), encode \(encoder.terminationStatus))")
    }
    let bytes = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0
    print("wrote \(output.lastPathComponent): \(frame) frames super-resolved to \(out.width)×\(out.height) (\(n):\(d) pixels), "
        + "HEVC Main10 + AAC \(settings.audioBitRate), \(bytes) bytes")
}

/// Packed `rgba64le` → `64RGBAHalf`.
private func copy(rgba64 data: Data, into buffer: CVPixelBuffer) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let base = CVPixelBufferGetBaseAddress(buffer)!
    data.withUnsafeBytes { raw in
        let source = raw.bindMemory(to: UInt16.self)
        for y in 0 ..< height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: Float16.self)
            for i in 0 ..< width * 4 { row[i] = Float16(Float(UInt16(littleEndian: source[y * width * 4 + i])) / 65535) }
        }
    }
}

/// `64RGBAHalf` → packed `rgba64le` (alpha forced opaque).
private func rgba64(from buffer: CVPixelBuffer) -> Data {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let base = CVPixelBufferGetBaseAddress(buffer)!
    var out = [UInt16](repeating: 0, count: width * height * 4)
    for y in 0 ..< height {
        let row = base.advanced(by: y * stride).assumingMemoryBound(to: Float16.self)
        for x in 0 ..< width {
            for c in 0 ..< 3 {
                out[(y * width + x) * 4 + c] = UInt16(min(65535, max(0, (Float(row[x * 4 + c]) * 65535).rounded()))).littleEndian
            }
            out[(y * width + x) * 4 + 3] = 65535
        }
    }
    return out.withUnsafeBytes { Data($0) }
}

/// ffmpeg (see ``runFFmpeg(_:)``) with piped stdout or stdin.
func ffmpegProcess(_ arguments: [String], stdout: Bool = false, stdin: Bool = false) throws -> Process {
    let environment = ProcessInfo.processInfo.environment
    let candidates = [environment["FFMPEG"]].compactMap { $0 }
        + (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/ffmpeg" }
        + ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
    guard let ffmpeg = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
        fail("ffmpeg not found (brew install ffmpeg, or set FFMPEG)")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: ffmpeg)
    process.arguments = arguments
    if stdout { process.standardOutput = Pipe() }
    if stdin { process.standardInput = Pipe() }
    try process.run()
    return process
}
