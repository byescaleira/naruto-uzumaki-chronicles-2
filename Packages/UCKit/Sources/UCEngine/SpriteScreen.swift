import Foundation
import UCFormats
import UCRender

/// A 2D screen: sprite objects drawn from one or more sprite files, advanced once per game
/// frame and turned into a renderer-agnostic ``SpriteFrame``.
public struct SpriteScreen: Sendable {
    public let files: [SpriteFile]
    /// Every texture of every file, uploaded once.
    public let atlas: SpriteAtlas
    /// Per file: the `TEX0` size of each texture, and its first layer in ``atlas``.
    public let textureSizes: [[SIMD2<Int>]]
    public let textureBase: [UInt32]
    public var objects: [SpriteObject] = []
    public var clearColor: SIMD3<Float> = .zero
    public private(set) var frameCount = 0

    public init(files: [SpriteFile]) {
        self.files = files
        var textures: [(width: Int, height: Int, rgba: [UInt8])] = []
        var sizes: [[SIMD2<Int>]] = []
        var bases: [UInt32] = []
        for file in files {
            bases.append(UInt32(textures.count))
            let decoded = file.textures.decode()
            sizes.append(zip(file.textures.textures, decoded).map { texture, image in
                SIMD2(image?.width ?? texture.tex0.width, image?.height ?? texture.tex0.height)
            })
            for (texture, image) in zip(file.textures.textures, decoded) {
                if let image {
                    textures.append((image.width, image.height, image.rgba))
                } else {
                    // Unsupported format: keep the slot so indices stay aligned.
                    textures.append((texture.tex0.width, texture.tex0.height, [UInt8](repeating: 0, count: texture.tex0.width * texture.tex0.height * 4)))
                }
            }
        }
        atlas = SpriteAtlas(textures: textures)
        textureSizes = sizes
        textureBase = bases
    }

    /// One game frame.
    public mutating func tick() {
        for i in objects.indices { objects[i].tick() }
        frameCount += 1
    }

    public mutating func tick(frames: Int) {
        for _ in 0 ..< max(0, frames) { tick() }
    }

    /// Objects in creation order, each in its own layer order (`FUN_00265180`).
    public var quads: [SpriteQuad] {
        var quads: [SpriteQuad] = []
        for object in objects { object.draw(textureSizes: textureSizes, into: &quads, textureBase: textureBase) }
        return quads
    }

    public func frame(canvas: SpriteCanvas = SpriteCanvas()) -> SpriteFrame {
        SpriteFrame(atlas: atlas, quads: quads, canvas: canvas, clearColor: clearColor)
    }
}

/// The title screen / main menu (BEGIN! · CONTINUE! · OPTIONS), as the title module builds it.
///
/// Recovered from `SLES_550.90`:
/// - `FUN_002d4120(n)` reads the module's resource handles at `DAT_004da940`
///   (`entry << 16 | sub-file`); handle 1 = `0x00280000`, DIG entry 40 sub-file 0.
/// - `FUN_001a9350` starts the background task `FUN_001a8c30`; in its main-menu mode it adds
///   21 layers playing animations 0–9, 0xC–0x14, 0xA and 0x15 of that file (the blue backdrop,
///   the kanji and fire, the characters, the logo and the copyright).
/// - `FUN_001aac40` creates the three menu items (`FUN_001aa070(i, 0, 0)`, names "NEW GAME",
///   "LOAD GAME", "OPTION" at `0x3523b0`); `FUN_001a9b90` gives each a highlight layer
///   (animation 0x16 anchored on 0x17, moved down 40 px per item, hidden unless selected) and a
///   label layer (animations 0x18–0x1A, held on their dim first key unless selected).
public enum TitleScreen {
    public static let entry = 40
    public static let subfile = 0

    public static let backgroundAnimations = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0xC, 0xD, 0xE, 0xF, 0x10, 0x11, 0x12, 0x13, 0x14, 0xA, 0x15]
    public static let itemLabels = [0x18, 0x19, 0x1A]
    public static let itemSpacing = 0x28
    /// "PRESS START BUTTON" (`FUN_001aa3e0` plays animation 0x1B of the same file).
    public static let pressStart = 0x1B

    public enum Phase: Sendable, Equatable {
        /// The backdrop with the blinking "PRESS START BUTTON".
        case pressStart
        /// BEGIN! · CONTINUE! · OPTIONS with one item selected.
        case menu(selection: Int)
    }

    public static func make(_ file: SpriteFile, phase: Phase = .menu(selection: 0)) -> SpriteScreen {
        var screen = SpriteScreen(files: [file])
        var background = SpriteObject()
        for (id, animation) in backgroundAnimations.enumerated() {
            background.add(id: id, animation: animation, bank: file.bank)
        }
        // Layer 0 is the full-frame backdrop (blue noise, additive fire, subtractive shade).
        background.setWidescreen(layer: 0, .mirror)
        screen.objects.append(background)
        switch phase {
        case .pressStart:
            var prompt = SpriteObject()
            prompt.add(id: 0, animation: pressStart, bank: file.bank)
            screen.objects.append(prompt)
        case .menu(let selection):
            for (index, label) in itemLabels.enumerated() {
                var item = SpriteObject()
                item.add(id: 0, animation: 0x16, anchorAnimation: 0x17, bank: file.bank)
                item.add(id: 1, animation: label, bank: file.bank)
                item.setPosition(layer: 0, SIMD2(0, index * itemSpacing))
                setSelected(&item, index == selection)
                screen.objects.append(item)
            }
        }
        return screen
    }

    /// Selected: highlight bar shown, label playing its grow-in (0.7 → 1.0, alpha 0x32 → 0x80);
    /// otherwise the bar is hidden and the label held on its dim first key (flags 0x20 / 0xC
    /// as `FUN_001a9b90` sets them).
    static func setSelected(_ item: inout SpriteObject, _ selected: Bool) {
        if selected {
            item.remove(.hidden, layer: 0)
            item.remove([.hold, .paused], layer: 1)
            item.play(layer: 1, animation: item.layers[1].animator.animation, restart: true)
        } else {
            item.insert(.hidden, layer: 0)
            item.insert([.hold, .paused], layer: 1)
        }
    }
}

/// The title flow driven by the pad: PRESS START → menu, up / down to move the selection.
/// What each item leads to (story, load, options) is not reimplemented yet.
public struct TitleMenu: Sendable {
    public private(set) var phase: TitleScreen.Phase
    public private(set) var screen: SpriteScreen
    private let file: SpriteFile
    private var previous = InputState()

    public init(file: SpriteFile, phase: TitleScreen.Phase = .pressStart) {
        self.file = file
        self.phase = phase
        screen = TitleScreen.make(file, phase: phase)
    }

    /// One game frame with this frame's pad state.
    public mutating func tick(_ input: InputState) {
        defer { previous = input }
        let pressed = input.buttons.subtracting(previous.buttons)
        switch phase {
        case .pressStart:
            if !pressed.isDisjoint(with: [.start, .cross]) {
                // The backdrop keeps running: only the overlay objects change.
                phase = .menu(selection: 0)
                var menu = TitleScreen.make(file, phase: phase)
                menu.objects[0] = screen.objects[0]
                screen = menu
            }
        case .menu(let selection):
            let down = input.leftStick.y < -0.5 && previous.leftStick.y >= -0.5
            let up = input.leftStick.y > 0.5 && previous.leftStick.y <= 0.5
            let count = TitleScreen.itemLabels.count
            if up || down {
                let next = (selection + (down ? 1 : count - 1)) % count
                TitleScreen.setSelected(&screen.objects[1 + selection], false)
                TitleScreen.setSelected(&screen.objects[1 + next], true)
                phase = .menu(selection: next)
            }
        }
        screen.tick()
    }
}

extension GameData {
    /// One sub-file of a DIG entry.
    public func subfile(entry index: Int, _ subfile: Int) throws -> [UInt8] {
        let entry = archive.entries[index]
        let data = try archive.read(entry)
        let table = DIGSubfileTable(data, count: Int(entry.subfileCount))
        guard let found = table.subfiles.first(where: { Int($0.index) == subfile }) else {
            throw SpriteFile.Failure.truncated("entry \(index) sub-file \(subfile)")
        }
        return Array(table.slice(found, of: data))
    }

    /// The title screen / main menu, decoded from the disc (``TitleScreen``).
    public func titleScreen(phase: TitleScreen.Phase = .menu(selection: 0)) throws -> SpriteScreen {
        TitleScreen.make(try titleSprites(), phase: phase)
    }

    /// The title / main-menu sprite file (DIG entry 40, sub-file 0).
    public func titleSprites() throws -> SpriteFile {
        try SpriteFile(try subfile(entry: TitleScreen.entry, TitleScreen.subfile))
    }
}
