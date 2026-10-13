import Foundation
import Testing
@testable import UCEngine
import UCFormats

/// The embedded game data, when this checkout has it (`scripts/fetch_game_data.sh`).
private let gameData: GameData? = {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appending(path: "../../../../GameData").standardizedFileURL
    return try? GameData(url: root)
}()

private func pad(_ buttons: InputState.Buttons = [], stick: SIMD2<Float> = .zero) -> InputState {
    var state = InputState()
    state.buttons = buttons
    state.leftStick = stick
    return state
}

@Suite("SELECT MODE wheel")
struct ModeSelectWheelTests {
    @Test("Rows sit 20 px right and 44 / 40 px down per step, fading out past two")
    func slots() {
        #expect(ModeSelectScreen.slot(0)?.offset == SIMD2(0, 0))
        #expect(ModeSelectScreen.slot(0)?.alpha == 0x80)
        #expect(ModeSelectScreen.slot(1)?.offset == SIMD2(20, 44))
        #expect(ModeSelectScreen.slot(-1)?.offset == SIMD2(-20, -44))
        #expect(ModeSelectScreen.slot(1)?.alpha == 0x70)
        #expect(ModeSelectScreen.slot(2)?.offset == SIMD2(40, 80))
        #expect(ModeSelectScreen.slot(-2)?.alpha == 0x60)
        #expect(ModeSelectScreen.slot(3)?.alpha == 0)
        #expect(ModeSelectScreen.slot(4) == nil)
    }

    @Test("Offsets wrap around the 11 items")
    func wrap() {
        #expect(ModeSelectScreen.offset(of: 10, from: 0) == -1)
        #expect(ModeSelectScreen.offset(of: 0, from: 10) == 1)
        #expect(ModeSelectScreen.offset(of: 5, from: 0) == 5)
        #expect(ModeSelectScreen.offset(of: 3, from: 9) == 5)
    }
}

@Suite("Front end flow", .enabled(if: gameData != nil, "needs the embedded game data"))
struct FrontEndTests {
    private func makeFrontEnd() throws -> FrontEnd {
        let data = try #require(gameData)
        return FrontEnd(title: try data.titleSprites(), modeSelect: try data.modeSelectSprites())
    }

    /// Ticks until the fade ends, collecting events.
    private func settle(_ frontEnd: inout FrontEnd, frames: Int = FrontEnd.fadeFrames + 2) -> [FrontEndEvent] {
        (0 ..< frames).flatMap { _ in frontEnd.tick(InputState(), voiceIdle: false) }
    }

    @Test("Boot: title music, fade-in, then PRESS START → menu on LOAD GAME")
    func title() throws {
        var frontEnd = try makeFrontEnd()
        let events = settle(&frontEnd)
        #expect(events.contains(.music(TitleScreen.music, fadeInFrames: 60)))
        #expect(!frontEnd.isFading)
        _ = frontEnd.tick(pad(.start), voiceIdle: false)
        guard case .title(let menu) = frontEnd.stage else { Issue.record("not on the title"); return }
        #expect(menu.phase == .menu(selection: TitleMenu.initialSelection))
    }

    @Test("Confirming LOAD GAME fades out, then SELECT MODE fades in with bg117; EXIT goes back")
    func modeSelectAndBack() throws {
        var frontEnd = try makeFrontEnd()
        _ = settle(&frontEnd)
        _ = frontEnd.tick(pad(.start), voiceIdle: false)
        _ = frontEnd.tick(pad(), voiceIdle: false)
        let confirm = frontEnd.tick(pad(.cross), voiceIdle: false)
        #expect(confirm.contains(.fadeOutAudio(frames: FrontEnd.fadeFrames)))
        #expect(frontEnd.isFading)
        let events = settle(&frontEnd, frames: 2 * FrontEnd.fadeFrames + 2)
        #expect(events.contains(.music(ModeSelectScreen.music, fadeInFrames: 0)))
        guard case .modeSelect(let menu) = frontEnd.stage else { Issue.record("not on SELECT MODE"); return }
        #expect(menu.item.name == "STORY MODE")

        // Up once wraps to SAVE, up again to EXIT (each move takes 5 frames).
        for _ in 0 ..< 2 {
            _ = frontEnd.tick(pad(stick: SIMD2(0, 1)), voiceIdle: false)
            _ = settle(&frontEnd, frames: ModeSelectScreen.moveFrames + 1)
        }
        guard case .modeSelect(let moved) = frontEnd.stage else { return }
        #expect(moved.selection == ModeSelectScreen.exit)
        _ = frontEnd.tick(pad(.cross), voiceIdle: false)
        _ = settle(&frontEnd, frames: 2 * FrontEnd.fadeFrames + 2)
        guard case .title(let title) = frontEnd.stage else { Issue.record("EXIT did not return to the title"); return }
        #expect(title.phase == .pressStart)
    }

    @Test("Locked modes buzz and stay; the announcer waits for a free voice channel")
    func lockedAndVoices() throws {
        let data = try #require(gameData)
        var menu = ModeSelectMenu(file: try data.modeSelectSprites())
        #expect(menu.pendingVoice == 0x70B)
        menu.voiceStarted()
        #expect(menu.pendingVoice == nil)
        menu.tick(pad(stick: SIMD2(0, -1)))
        for _ in 0 ..< ModeSelectScreen.moveFrames { menu.tick(pad()) }
        #expect(menu.item.name == "KAKASHI STORY")
        #expect(menu.pendingVoice == nil)
        menu.tick(pad(.cross))
        #expect(menu.sound == 0x82)
        #expect(menu.confirmed == nil)
    }

    @Test("Tapping a visible row turns the wheel there; tapping the selected row confirms")
    func taps() throws {
        let data = try #require(gameData)
        var menu = ModeSelectMenu(file: try data.modeSelectSprites(), selection: 4)
        let frames = menu.itemFrames
        let below = frames[5]
        menu.tap(at: SIMD2((below.x + below.z) / 2, (below.y + below.w) / 2))
        for _ in 0 ..< ModeSelectScreen.moveFrames { menu.tick(pad()) }
        #expect(menu.selection == 5)
        let selected = menu.itemFrames[5]
        menu.tap(at: SIMD2((selected.x + selected.z) / 2, (selected.y + selected.w) / 2))
        #expect(menu.confirmed == 5)
    }

    @Test("NEW GAME fades out and asks for story episode 0xF")
    func newGame() throws {
        var frontEnd = try makeFrontEnd()
        _ = settle(&frontEnd)
        _ = frontEnd.tick(pad(.start), voiceIdle: false)
        _ = frontEnd.tick(pad(), voiceIdle: false)
        _ = frontEnd.tick(pad(stick: SIMD2(0, 1)), voiceIdle: false)   // LOAD GAME → NEW GAME
        _ = frontEnd.tick(pad(), voiceIdle: false)
        _ = frontEnd.tick(pad(.cross), voiceIdle: false)
        let events = settle(&frontEnd)
        #expect(events.contains(.startStory(episode: EpisodeTable.newGame)))
    }
}
