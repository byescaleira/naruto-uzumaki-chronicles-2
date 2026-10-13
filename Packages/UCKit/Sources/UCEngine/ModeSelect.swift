import simd
import UCFormats
import UCRender

/// SELECT MODE, the hub the game returns to between modes (title module mode 1).
///
/// Recovered from `SLES_550.90`:
/// - `FUN_002fcd90` plays bg117 (`0x75`) on the music channel, fades the screen in over 15
///   frames and starts `FUN_001a9350(1)`; `FUN_002fcce0` creates the 11 items
///   (`FUN_001aa070(i, 1, 1)`, table `{name, label animation, voice, 0}` at `0x3523e0`).
/// - `FUN_001a8c30` (mode 1) builds the backdrop from `0040/01`: animations 0–5, three party
///   portraits (`FUN_001a9460`: random unlocked characters from `0x352350`, anchored on
///   animations 0x2C / 0x2B / 0x2A), the SELECT MODE title (7), the item frame (9, 10) and the
///   up / down arrows (0xB on 0xD, 0xC on 0xE).
/// - `FUN_001a9b90` / `FUN_001aa1d0` lay the items out as a wheel around the centre of
///   animation 0x19: offset `d` from the selection is drawn at `(20·d, 44·d)` for `|d| = 1` and
///   `(20·d, 40·d)` otherwise, alpha 0x80 / 0x70 / 0x60 for `|d|` = 0 / 1 / 2, 0 beyond; moves
///   take 5 frames. The selected item adds a copy of its label that scales in over 4 frames.
/// - `FUN_002fc8c0` reads the pad: up / down (with repeat) move the selection with wrap-around,
///   Cross confirms; locked modes play the buzzer and show "???" (0x30).
/// - `FUN_001a9890` plays the selected item's announcer line once the voice channel is free.
public enum ModeSelectScreen {
    public static let entry = 40
    public static let subfile = 1
    /// bg117.
    public static let music = 0x75

    public struct Item: Sendable, Equatable {
        public let name: String
        public let label: Int
        public let voice: Int
        /// Modes a new save has open; the others unlock through the story
        /// (`FUN_002f87b0`, `FUN_002f8760`, `FUN_002f8740`, `FUN_002f8720`).
        public let unlocked: Bool
    }

    public static let items: [Item] = [
        Item(name: "STORY MODE", label: 0x0F, voice: 0x70B, unlocked: true),
        Item(name: "KAKASHI STORY", label: 0x2F, voice: 0x730, unlocked: false),
        Item(name: "MISSION MODE", label: 0x10, voice: 0x70C, unlocked: false),
        Item(name: "CHALLENGE MODE", label: 0x11, voice: 0x70D, unlocked: false),
        Item(name: "LEVEL UP", label: 0x15, voice: 0x70E, unlocked: true),
        Item(name: "GINOUBAKO", label: 0x31, voice: 0x70E, unlocked: true),
        Item(name: "ITEM SHOP", label: 0x13, voice: 0x70F, unlocked: false),
        Item(name: "OPTION", label: 0x16, voice: 0x710, unlocked: true),
        Item(name: "VS MODE", label: 0x12, voice: 0x711, unlocked: true),
        Item(name: "EXIT", label: 0x18, voice: 0x712, unlocked: true),
        Item(name: "SAVE", label: 0x17, voice: 0x713, unlocked: true),
    ]
    public static let exit = 9
    public static let lockedLabel = 0x30
    public static let wheelAnchor = 0x19
    public static let moveFrames = 5

    /// Portrait animation per character slot (`0x352350`, `{character << 8, animation}`): the
    /// characters a new save has (Naruto, Kakashi, Kankuro; `FUN_002f8570`).
    public static let startingParty = [0x1F, 0x20, 0x24]
    static let portraitAnchors = [0x2C, 0x2B, 0x2A]

    /// Item `index` at offset `d` from the selection: position relative to the wheel centre
    /// and alpha (`FUN_001aa1d0`); `nil` when it is outside the five visible rows.
    public static func slot(_ d: Int) -> (offset: SIMD2<Int>, alpha: UInt8)? {
        guard abs(d) <= 3 else { return nil }
        let alpha: UInt8 = switch abs(d) {
        case 0: 0x80
        case 1: 0x70
        case 2: 0x60
        default: 0
        }
        return (SIMD2(d * 20, (abs(d) == 1 ? 44 : 40) * d), alpha)
    }

    /// Signed distance from `selection` to `index` on the wheel, in `-5 ... 5`.
    static func offset(of index: Int, from selection: Int) -> Int {
        let count = items.count
        var d = (index - selection) % count
        if d > count / 2 { d -= count } else if d < -(count / 2) { d += count }
        return d
    }

    static func makeBackdrop(_ file: SpriteFile, party: [Int]) -> SpriteObject {
        var backdrop = SpriteObject()
        for animation in 0 ... 5 { backdrop.add(id: animation, animation: animation, bank: file.bank) }
        // Layers 1 (colour wash) and 2 (clouds) span the 4:3 frame; mirror them past its edges.
        backdrop.setWidescreen(layer: 1, .mirror)
        backdrop.setWidescreen(layer: 2, .mirror)
        // Added (and so drawn) slot 2 first: slot 0 ends up in front (`FUN_002660a0` appends).
        for (slot, portrait) in party.prefix(3).enumerated().reversed() {
            backdrop.add(id: 6 + slot, animation: portrait, anchorAnimation: portraitAnchors[slot], bank: file.bank)
        }
        backdrop.add(id: 9, animation: 7, bank: file.bank)
        backdrop.add(id: 10, animation: 9, bank: file.bank)
        backdrop.add(id: 11, animation: 10, bank: file.bank)
        backdrop.add(id: 14, animation: 0xB, anchorAnimation: 0xD, bank: file.bank)
        backdrop.add(id: 15, animation: 0xC, anchorAnimation: 0xE, bank: file.bank)
        backdrop.setPriority(layer: 10, 1)
        backdrop.setPriority(layer: 11, 1)
        backdrop.setPriority(layer: 14, 3)
        backdrop.setPriority(layer: 15, 3)
        return backdrop
    }

    /// Centre of animation 0x19's first frame (`FUN_0025d530`).
    static func wheelCentre(_ bank: SpriteBank) -> SIMD2<Int> {
        let bounds = SpriteAnimator(bank: bank, animation: wheelAnchor).bounds()
        return SIMD2(bounds.x + bounds.z >> 1, bounds.y + bounds.w >> 1)
    }
}

/// SELECT MODE driven by the pad or touch. Confirming a mode reports it through ``confirmed``;
/// only EXIT leads somewhere yet (back to the title), the modes themselves are still to come.
public struct ModeSelectMenu: Sendable {
    public private(set) var selection: Int
    public private(set) var screen: SpriteScreen
    /// Set when the player confirms an unlocked item; ``FrontEnd`` reads and clears it.
    public var confirmed: Int?
    /// A sound effect the menu asked for this frame (`FUN_0012b300` ids: 0x7F move, 0x82 locked,
    /// 0x83 confirm); ``FrontEnd`` forwards and clears it.
    public var sound: Int?

    private let centre: SIMD2<Int>
    private var previous = InputState()
    /// Frames left in the current wheel move (`+0x10`); input waits for it.
    private var moving = 0
    /// Per item: where the move started, and its target.
    private var from: [(position: SIMD2<Int>, alpha: UInt8)]
    private var to: [(position: SIMD2<Int>, alpha: UInt8)]
    /// The selected label's copy scales in over 4 frames (`FUN_002637d0`).
    private var pop = 0
    private var voiced = false

    public init(file: SpriteFile, party: [Int] = ModeSelectScreen.startingParty, selection: Int = 0) {
        self.init(sheet: SpriteSheet(files: [file]), party: party, selection: selection)
    }

    public init(sheet: SpriteSheet, party: [Int] = ModeSelectScreen.startingParty, selection: Int = 0) {
        let file = sheet.files[0]
        self.selection = selection
        centre = ModeSelectScreen.wheelCentre(file.bank)
        var screen = SpriteScreen(sheet: sheet)
        screen.objects.append(ModeSelectScreen.makeBackdrop(file, party: party))
        for item in ModeSelectScreen.items {
            let label = item.unlocked ? item.label : ModeSelectScreen.lockedLabel
            var object = SpriteObject()
            object.add(id: 0, animation: label, bank: file.bank, flags: [.hold, .paused])
            object.add(id: 1, animation: label, bank: file.bank, flags: [.hidden])
            object.setPriority(layer: 1, 2)
            object.setScale(layer: 1, .zero)
            screen.objects.append(object)
        }
        self.screen = screen
        let centre = centre
        let targets = (0 ..< ModeSelectScreen.items.count).map { Self.target($0, selection, centre) }
        from = targets
        to = targets
        place(progress: 1)
        startPop()
    }

    public var item: ModeSelectScreen.Item { ModeSelectScreen.items[selection] }

    /// The announcer line to play once the voice channel is free (`FUN_001a9890`): set after
    /// the wheel settles on an unlocked item, cleared by ``voiceStarted()``.
    public var pendingVoice: Int? {
        moving == 0 && !voiced && item.unlocked ? item.voice : nil
    }

    public mutating func voiceStarted() { voiced = true }

    public mutating func tick(_ input: InputState) {
        defer { previous = input }
        let pressed = input.buttons.subtracting(previous.buttons)
        if moving > 0 {
            moving -= 1
            place(progress: Float(ModeSelectScreen.moveFrames - moving) / Float(ModeSelectScreen.moveFrames))
        } else {
            let down = input.leftStick.y < -0.5 && previous.leftStick.y >= -0.5
            let up = input.leftStick.y > 0.5 && previous.leftStick.y <= 0.5
            let count = ModeSelectScreen.items.count
            if !pressed.isDisjoint(with: [.cross, .start]) {
                confirm()
            } else if up || down {
                select((selection + (down ? 1 : count - 1)) % count)
            }
        }
        if pop > 0 {
            pop -= 1
            let scale = Float(4 - pop) / 4
            screen.objects[1 + selection].setScale(layer: 1, SIMD2(scale, scale))
        }
        screen.tick()
    }

    /// A tap at `point` (canvas coordinates): on the selected item it confirms, on another
    /// visible item it turns the wheel there, on the arrows it steps once.
    public mutating func tap(at point: SIMD2<Float>) {
        guard moving == 0 else { return }
        if let index = itemFrames.firstIndex(where: { $0.contains(point) }) {
            if index == selection { confirm() } else { select(index) }
            return
        }
        let count = ModeSelectScreen.items.count
        let frames = arrowFrames
        if frames.up.contains(point) {
            select((selection + count - 1) % count)
        } else if frames.down.contains(point) {
            select((selection + 1) % count)
        }
    }

    /// Hit areas of the visible items, `(minX, minY, maxX, maxY)`; hidden ones are empty.
    public var itemFrames: [SIMD4<Float>] {
        let rowHeight: Float = 40
        let left = Float(centre.x - 150), right = Float(centre.x + 150)
        return (0 ..< ModeSelectScreen.items.count).map { index in
            let d = ModeSelectScreen.offset(of: index, from: selection)
            guard let slot = ModeSelectScreen.slot(d), slot.alpha > 0 else { return SIMD4(0, 0, -1, -1) }
            let y = Float(centre.y + slot.offset.y)
            return SIMD4(left + Float(slot.offset.x), y - rowHeight / 2, right + Float(slot.offset.x), y + rowHeight / 2)
        }
    }

    /// The ▲ / ▼ arrows above and below the wheel, padded for fingers.
    var arrowFrames: (up: SIMD4<Float>, down: SIMD4<Float>) {
        let backdrop = screen.objects[0]
        func frame(_ layer: Int) -> SIMD4<Float> {
            guard let p = backdrop.layer(layer)?.animator.position else { return SIMD4(0, 0, -1, -1) }
            return SIMD4(p.x - 40, p.y - 24, p.x + 40, p.y + 24)
        }
        return (frame(14), frame(15))
    }

    public mutating func setBrightness(_ level: Float) { screen.brightness = level }

    private mutating func confirm() {
        guard item.unlocked else {
            sound = 0x82
            return
        }
        sound = 0x83
        confirmed = selection
    }

    private mutating func select(_ next: Int) {
        guard next != selection else { return }
        let old = selection
        from = (0 ..< ModeSelectScreen.items.count).map { index in
            let layer = screen.objects[1 + index].layer(0)
            let p = layer.map { SIMD2(Int($0.animator.position.x), Int($0.animator.position.y)) } ?? centre
            return (p, layer?.animator.color.w ?? 0)
        }
        selection = next
        let centre = centre
        to = (0 ..< ModeSelectScreen.items.count).map { Self.target($0, next, centre) }
        moving = ModeSelectScreen.moveFrames
        voiced = false
        sound = 0x7F
        screen.objects[1 + old].insert(.hidden, layer: 1)
        screen.objects[1 + old].setScale(layer: 1, .zero)
        startPop()
    }

    private mutating func startPop() {
        screen.objects[1 + selection].remove(.hidden, layer: 1)
        screen.objects[1 + selection].play(layer: 1, animation: screen.objects[1 + selection].layers[1].animator.animation, restart: true)
        screen.objects[1 + selection].setPosition(layer: 1, centre)
        pop = 4
    }

    private static func target(_ index: Int, _ selection: Int, _ centre: SIMD2<Int>) -> (position: SIMD2<Int>, alpha: UInt8) {
        let d = ModeSelectScreen.offset(of: index, from: selection)
        guard let slot = ModeSelectScreen.slot(d) else {
            // Off the wheel: parked at the nearest end, invisible.
            return (centre &+ SIMD2(d.signum() * 60, d.signum() * 120), 0)
        }
        return (centre &+ slot.offset, slot.alpha)
    }

    /// Linear move between `from` and `to` (`FUN_00263fe0` / `FUN_00263b90`).
    private mutating func place(progress t: Float) {
        for index in to.indices {
            let a = from[index], b = to[index]
            let p = SIMD2<Float>(a.position) + t * SIMD2<Float>(b.position &- a.position)
            let alpha = Float(a.alpha) + t * (Float(b.alpha) - Float(a.alpha))
            screen.objects[1 + index].setPosition(layer: 0, SIMD2(Int(p.x.rounded()), Int(p.y.rounded())))
            screen.objects[1 + index].setAlpha(layer: 0, UInt8(max(0, min(255, alpha.rounded()))))
        }
    }
}

extension GameData {
    /// The SELECT MODE sprite file (DIG entry 40, sub-file 1).
    public func modeSelectSprites() throws -> SpriteFile {
        try sprites(entry: ModeSelectScreen.entry, ModeSelectScreen.subfile)
    }
}
