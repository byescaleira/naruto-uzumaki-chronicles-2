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

    init(arguments: ArraySlice<String>) {
        var iterator = arguments.makeIterator()
        while let flag = iterator.next() {
            switch flag {
            case "--height": height = iterator.next().flatMap(Int.init) ?? height
            case "--crf": crf = iterator.next().flatMap(Int.init) ?? crf
            case "--preset": preset = iterator.next() ?? preset
            case "--audio-bitrate": audioBitRate = iterator.next() ?? audioBitRate
            case "--keep-streams": keepStreams = true
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
