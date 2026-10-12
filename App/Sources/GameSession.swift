import Foundation
import Observation
import UCAudio
import UCEngine
import UCFormats
#if DEBUG
import os
#endif

/// Drives the boot flow the original runs: intro movie, then the title screen
/// (`FUN_001aaed0`: music bg093 with a fade-in, the 21-layer title, the voice announcer task).
@MainActor
@Observable
final class GameSession {
    enum Stage {
        case intro(MoviePlayer)
        case title
    }

    private(set) var stage: Stage?
    let runtime: GameRuntime
    @ObservationIgnored private let audio = AudioSystem()
    @ObservationIgnored private var started = false

    /// Title music: `FUN_001aaed0` calls `FUN_00129c60(0, 0x5d, 1, 0, 0)` (channel 0 = music).
    nonisolated static let titleMusic = 0x5D
    /// Title announcer lines (voice indices) from the table at `0x352490`, picked at random by
    /// the task `FUN_001aae30`.
    nonisolated static let announcerVoices = [0x709, 0x731, 0x732, 0x733, 0x734, 0x735, 0x736, 0x737, 0x738, 0x739, 0x73A, 0x73B]

    init(runtime: GameRuntime) {
        self.runtime = runtime
    }

    func start(with data: GameData) async {
        guard !started else { return }
        started = true
        try? audio.start()
        let assets = try? await Task.detached(priority: .userInitiated) { try Assets(data) }.value

        if let movie = data.disc.files["MV/MV00.MP4"]?.url {
            let player = MoviePlayer(url: movie)
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
        enterTitle(assets)
    }

    private func enterTitle(_ assets: Assets) {
        runtime.title = TitleMenu(file: assets.title)
        stage = .title
        if let music = assets.music {
            audio.play(music, on: .music, loops: true, gain: assets.musicGain, fadeIn: .seconds(1))
        }
        Task { [audio] in
            try? await Task.sleep(for: .seconds(1.5))
            if let voice = assets.announcer {
                audio.play(voice.track, on: .voice, loops: false, gain: voice.gain)
            }
            #if DEBUG
            try? await Task.sleep(for: .milliseconds(300))
            Logger(subsystem: "com.byescaleira.nuc2", category: "audio").info(
                "title audio: music \(audio.isPlaying(.music)), voice \(audio.isPlaying(.voice)), engine \(audio.isRunning)")
            #endif
            // Retired streams are freed on the main actor.
            while true {
                try? await Task.sleep(for: .seconds(1))
                audio.collect()
            }
        }
    }

    /// Everything the title needs, decoded off the main actor.
    private struct Assets: Sendable {
        let title: SpriteFile
        let music: ADXTrack?
        let musicGain: Float
        let announcer: (track: ADXTrack, gain: Float)?

        init(_ data: GameData) throws {
            title = try data.titleSprites()
            let table = try? SoundTable(try data.subfile(entry: SoundTable.entry, SoundTable.subfile))
            func gain(_ stream: SoundTable.Stream?) -> Float {
                stream.map { CRIVolume.gain(level: CRIVolume.level(streamVolume: $0.volume)) } ?? 1
            }
            let musicArchive = try data.disc.files["XA/XA.AFS"].map { try AFSArchive(url: $0.url) }
            let voiceArchive = try data.disc.files["XA/XAVOICE.AFS"].map { try AFSArchive(url: $0.url) }
            music = try musicArchive.map { try ADXTrack(archive: $0, index: GameSession.titleMusic) }
            musicGain = gain(table?.music.first { $0.index == GameSession.titleMusic })
            if let voiceArchive, let index = GameSession.announcerVoices.randomElement() {
                announcer = (try ADXTrack(archive: voiceArchive, index: index), gain(table?.voices.first { $0.index == index }))
            } else {
                announcer = nil
            }
        }
    }
}
