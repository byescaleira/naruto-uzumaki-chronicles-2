import UCFormats

/// Sound the 2D flow asks for; the app's audio system plays it.
public enum FrontEndEvent: Sendable, Equatable {
    /// A track of `XA.AFS` on the music channel, looping, faded in over `fadeInFrames`.
    case music(Int, fadeInFrames: Int)
    /// Music and voice channels faded out over `frames` (`FUN_00129c30(channel, frames)`).
    case fadeOutAudio(frames: Int)
    /// A line of `XAVOICE.AFS` on the voice channel.
    case voice(Int)
    /// A sound effect (`FUN_0012b300` id; the SE banks are not decoded yet).
    case sound(Int)
    /// The screen is black: start story `episode` (`FUN_00137a80`; 0 = the next one of the save).
    case startStory(episode: Int)
}

/// The app side of ``FrontEndEvent``.
@MainActor
public protocol GameAudio: AnyObject {
    /// `FUN_00129980(1)`: nothing playing on the voice channel.
    var isVoiceIdle: Bool { get }
    func handle(_ event: FrontEndEvent)
}

/// The menus before gameplay: title (PRESS START → NEW GAME / LOAD GAME / OPTION) and
/// SELECT MODE, with the screen and music fades the original runs between them.
///
/// - Title confirm (`FUN_001aaa90` → `FUN_001aaa20`): fade the screen to black and both audio
///   channels out over 15 frames. NEW GAME starts the story (`FUN_001aa550` →
///   `FUN_00137a80`), LOAD GAME reads the memory card and continues to SELECT MODE, OPTION opens
///   the options screen. Story and options are not reimplemented yet: NEW GAME and LOAD GAME
///   both open SELECT MODE with a new save, OPTION only plays the confirm sound.
/// - Title start (`FUN_001aaed0`): bg093 on the music channel, a 15-frame fade-in, then
///   (`FUN_001aae30`) one random announcer line from `0x352490`.
/// - SELECT MODE EXIT (`FUN_002fc860`) asks to confirm, then returns to the title; the port
///   returns straight away.
public struct FrontEnd: Sendable {
    public enum Stage: Sendable {
        case title(TitleMenu)
        case modeSelect(ModeSelectMenu)
    }

    public private(set) var stage: Stage
    private let titleSheet: SpriteSheet
    private let modeSheet: SpriteSheet

    /// `FUN_001c4610(15, …)` / `FUN_001c4650(15)`.
    public static let fadeFrames = 15
    /// The title announcer waits for the fade-in and a short pause (~1.5 s).
    public static let announcerDelay = 90

    private enum Destination: Sendable { case title, modeSelect, story(Int) }
    private var fade: (from: Float, to: Float, elapsed: Int)?
    private var destination: Destination?
    private var announcerIn: Int?
    private var events: [FrontEndEvent] = []

    /// Starts on the title's PRESS START, fading in with bg093. Build the sheets off the main
    /// actor: they decode every texture.
    public init(title: SpriteSheet, modeSelect: SpriteSheet) {
        titleSheet = title
        modeSheet = modeSelect
        stage = .title(TitleMenu(sheet: title))
        enterTitle()
    }

    public init(title: SpriteFile, modeSelect: SpriteFile) {
        self.init(title: SpriteSheet(files: [title]), modeSelect: SpriteSheet(files: [modeSelect]))
    }

    public var screen: SpriteScreen {
        switch stage {
        case .title(let menu): menu.screen
        case .modeSelect(let menu): menu.screen
        }
    }

    /// Input is ignored while the screen fades.
    public var isFading: Bool { fade != nil }

    /// One game frame; returns the sounds to play.
    public mutating func tick(_ input: InputState, voiceIdle: Bool) -> [FrontEndEvent] {
        let input = isFading ? InputState() : input
        switch stage {
        case .title(var menu):
            menu.tick(input)
            if let item = menu.confirmed {
                menu.confirmed = nil
                events.append(.sound(0x83))
                switch item {
                // NEW GAME starts episode 0xF (`FUN_001aa550`); LOAD GAME reads the card and goes on
                // to SELECT MODE, which with no save is a new one.
                case .newGame: leave(to: .story(EpisodeTable.newGame))
                case .loadGame: leave(to: .modeSelect)
                case .option: break
                }
            }
            stage = .title(menu)
        case .modeSelect(var menu):
            menu.tick(input)
            if let sound = menu.sound {
                menu.sound = nil
                events.append(.sound(sound))
            }
            if let voice = menu.pendingVoice, voiceIdle, !isFading {
                menu.voiceStarted()
                events.append(.voice(voice))
            }
            if let index = menu.confirmed {
                menu.confirmed = nil
                if index == ModeSelectScreen.exit { leave(to: .title) }
                // STORY: the first episode not cleared yet (`FUN_002fa2a0`); a new save's is 0xF.
                if index == ModeSelectScreen.story { leave(to: .story(0)) }
            }
            stage = .modeSelect(menu)
        }
        if let frames = announcerIn {
            if frames <= 0 {
                announcerIn = nil
                if let voice = TitleScreen.announcerVoices.randomElement() { events.append(.voice(voice)) }
            } else {
                announcerIn = frames - 1
            }
        }
        advanceFade()
        defer { events.removeAll() }
        return events
    }

    /// A tap or click in canvas coordinates.
    public mutating func tap(at point: SIMD2<Float>) {
        guard !isFading else { return }
        switch stage {
        case .title(var menu):
            menu.tap(at: point)
            stage = .title(menu)
        case .modeSelect(var menu):
            menu.tap(at: point)
            stage = .modeSelect(menu)
        }
    }

    private mutating func leave(to next: Destination) {
        guard destination == nil else { return }
        destination = next
        announcerIn = nil
        fade = (1, 0, 0)
        events.append(.fadeOutAudio(frames: Self.fadeFrames))
    }

    private mutating func advanceFade() {
        guard let current = fade else { return }
        let elapsed = current.elapsed + 1
        let t = min(1, Float(elapsed) / Float(Self.fadeFrames))
        setBrightness(current.from + t * (current.to - current.from))
        guard elapsed >= Self.fadeFrames else {
            fade = (current.from, current.to, elapsed)
            return
        }
        fade = nil
        guard let next = destination else { return }
        destination = nil
        switch next {
        case .title:
            stage = .title(TitleMenu(sheet: titleSheet))
            enterTitle()
        case .modeSelect:
            stage = .modeSelect(ModeSelectMenu(sheet: modeSheet, party: ModeSelectScreen.startingParty.shuffled()))
            events.append(.music(ModeSelectScreen.music, fadeInFrames: 0))
            fadeIn()
        case .story(let episode):
            // Stays black; the app loads the episode and hands the screen to the 3D layer.
            events.append(.startStory(episode: episode))
        }
    }

    /// Back from a story scene: SELECT MODE fades in with its music.
    public mutating func returnToModeSelect() {
        destination = nil
        stage = .modeSelect(ModeSelectMenu(sheet: modeSheet, party: ModeSelectScreen.startingParty.shuffled()))
        events.append(.music(ModeSelectScreen.music, fadeInFrames: 0))
        fadeIn()
    }

    private mutating func enterTitle() {
        events.append(.music(TitleScreen.music, fadeInFrames: 60))
        announcerIn = Self.announcerDelay
        fadeIn()
    }

    private mutating func fadeIn() {
        setBrightness(0)
        fade = (0, 1, 0)
    }

    private mutating func setBrightness(_ level: Float) {
        switch stage {
        case .title(var menu):
            menu.setBrightness(level)
            stage = .title(menu)
        case .modeSelect(var menu):
            menu.setBrightness(level)
            stage = .modeSelect(menu)
        }
    }
}
