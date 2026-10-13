import Foundation
import Observation
import UCAudio
import UCEngine
import UCFormats
#if DEBUG
import os
#endif

/// Drives the boot flow the original runs: intro movie, then the menus (``FrontEnd``: title,
/// SELECT MODE), playing the music and voices they ask for.
@MainActor
@Observable
final class GameSession: GameAudio {
    enum Stage {
        case intro(MoviePlayer)
        case title
    }

    private(set) var stage: Stage?
    let runtime: GameRuntime
    @ObservationIgnored private let audio = AudioSystem()
    @ObservationIgnored private var started = false

    init(runtime: GameRuntime) {
        self.runtime = runtime
    }

    func start(with data: GameData) async {
        guard !started else { return }
        started = true
        try? audio.start()
        #if DEBUG
        // `NUC2_MUTE=1`: silent test runs (simulators, automation).
        if ProcessInfo.processInfo.environment["NUC2_MUTE"] == "1" {
            for bus in AudioSystem.Bus.allCases { audio.setVolume(0, for: bus) }
        }
        #endif
        let assets = try? await Task.detached(priority: .userInitiated) { try Assets(data) }.value

        if let movie = data.disc.files["MV/MV00.MP4"]?.url {
            let player = MoviePlayer(url: movie)
            #if DEBUG
            player.isMuted = ProcessInfo.processInfo.environment["NUC2_MUTE"] == "1"
            #endif
            stage = .intro(player)
            let skip = Task { [runtime] in
                // Controllers and the keyboard skip too (the view handles taps and clicks).
                while !Task.isCancelled {
                    if !runtime.input.buttons.isDisjoint(with: [.start, .cross]) { player.skip() }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            _ = await player.play()
            skip.cancel()
        }
        guard let assets else {
            stage = .title
            return
        }
        self.assets = assets
        runtime.audio = self
        runtime.frontEnd = FrontEnd(title: assets.title, modeSelect: assets.modeSelect)
        stage = .title
        Task { [audio] in
            // Retired streams are freed on the main actor.
            while true {
                try? await Task.sleep(for: .seconds(1))
                audio.collect()
            }
        }
    }

    // MARK: Audio

    @ObservationIgnored private var assets: Assets?
    /// Bumped on every music change so a slow load never starts a stale track.
    @ObservationIgnored private var musicRequest = 0
    @ObservationIgnored private var voiceLoading = false

    var isVoiceIdle: Bool { !voiceLoading && !audio.isPlaying(.voice) }

    func handle(_ event: FrontEndEvent) {
        guard let assets else { return }
        switch event {
        case .music(let index, let fadeInFrames):
            musicRequest += 1
            let request = musicRequest
            let gain = assets.gain(music: index)
            Task {
                guard let track = await assets.load(music: index), request == musicRequest else { return }
                audio.play(track, on: .music, loops: true, gain: gain, fadeIn: .seconds(Double(fadeInFrames) / 60))
            }
        case .fadeOutAudio(let frames):
            musicRequest += 1
            let fade = Duration.seconds(Double(frames) / 60)
            audio.stop(.music, fadeOut: fade)
            audio.stop(.voice, fadeOut: fade)
        case .voice(let index):
            voiceLoading = true
            let gain = assets.gain(voice: index)
            Task {
                defer { voiceLoading = false }
                guard let track = await assets.load(voice: index) else { return }
                audio.play(track, on: .voice, loops: false, gain: gain)
                #if DEBUG
                Logger(subsystem: "com.byescaleira.nuc2", category: "audio").info(
                    "voice \(String(index, radix: 16), privacy: .public): playing \(self.audio.isPlaying(.voice)), engine \(self.audio.isRunning)")
                #endif
            }
        case .sound:
            // The SE banks (`FUN_0012b300`) are not decoded yet.
            break
        }
    }

    /// Everything the menus need, decoded off the main actor.
    private struct Assets: Sendable {
        /// Decoded (and swapped for the high-resolution copies) here, off the main actor.
        let title: SpriteSheet
        let modeSelect: SpriteSheet
        let table: SoundTable?
        let musicArchive: AFSArchive?
        let voiceArchive: AFSArchive?

        init(_ data: GameData) throws {
            title = SpriteSheet(files: [try data.titleSprites()])
            modeSelect = SpriteSheet(files: [try data.modeSelectSprites()])
            table = try? SoundTable(try data.subfile(entry: SoundTable.entry, SoundTable.subfile))
            musicArchive = try data.disc.files["XA/XA.AFS"].map { try AFSArchive(url: $0.url) }
            voiceArchive = try data.disc.files["XA/XAVOICE.AFS"].map { try AFSArchive(url: $0.url) }
        }

        private static func gain(_ stream: SoundTable.Stream?) -> Float {
            stream.map { CRIVolume.gain(level: CRIVolume.level(streamVolume: $0.volume)) } ?? 1
        }

        func gain(music index: Int) -> Float { Self.gain(table?.music.first { $0.index == index }) }
        func gain(voice index: Int) -> Float { Self.gain(table?.voices.first { $0.index == index }) }

        /// Reads and copies the stream off the main actor (music tracks are up to 17 MB).
        func load(music index: Int) async -> ADXTrack? {
            guard let archive = musicArchive else { return nil }
            return try? await Task.detached(priority: .userInitiated) { try ADXTrack(archive: archive, index: index) }.value
        }

        func load(voice index: Int) async -> ADXTrack? {
            guard let archive = voiceArchive else { return nil }
            return try? await Task.detached(priority: .userInitiated) { try ADXTrack(archive: archive, index: index) }.value
        }
    }
}
