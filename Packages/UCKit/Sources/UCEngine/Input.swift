import GameController
import simd

/// One tick's worth of controller state, in PS2 DualShock 2 terms.
public struct InputState: Sendable, Equatable {
    public struct Buttons: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        public static let cross = Buttons(rawValue: 1 << 0)
        public static let circle = Buttons(rawValue: 1 << 1)
        public static let square = Buttons(rawValue: 1 << 2)
        public static let triangle = Buttons(rawValue: 1 << 3)
        public static let l1 = Buttons(rawValue: 1 << 4)
        public static let r1 = Buttons(rawValue: 1 << 5)
        public static let l2 = Buttons(rawValue: 1 << 6)
        public static let r2 = Buttons(rawValue: 1 << 7)
        public static let start = Buttons(rawValue: 1 << 8)
        public static let select = Buttons(rawValue: 1 << 9)
    }

    public var buttons: Buttons = []
    public var leftStick: SIMD2<Float> = .zero
    public var rightStick: SIMD2<Float> = .zero

    public init() {}
}

/// Reads the current controller (extended gamepad, Siri Remote, or keyboard), plus short
/// "virtual" presses from touch and clicks.
@MainActor
final class InputSource {
    /// A press injected by touch: held for a few ticks so edge-triggered menus see it.
    private var virtual = InputState()
    private var virtualTicks = 0
    static let virtualPressTicks = 4

    /// Buttons pressed since the last sample: a press shorter than one tick (a quick tap of a key
    /// or button) would otherwise fall between two samples of the held state.
    private var latched: InputState.Buttons = []

    init() {
        for controller in GCController.controllers() { configure(controller) }
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] note in
            // Posted on the main queue (`queue: .main`), so the object never leaves it.
            nonisolated(unsafe) let controller = note.object as? GCController
            MainActor.assumeIsolated { if let controller { self?.configure(controller) } }
        }
        if let keyboard = GCKeyboard.coalesced { configure(keyboard) }
        NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidConnect, object: nil, queue: .main
        ) { [weak self] note in
            nonisolated(unsafe) let keyboard = note.object as? GCKeyboard
            MainActor.assumeIsolated { if let keyboard { self?.configure(keyboard) } }
        }
    }

    private func configure(_ controller: GCController) {
        Self.configureLight(controller)
        controller.handlerQueue = .main
        if let pad = controller.extendedGamepad {
            let map = Self.buttons(pad)
            pad.valueChangedHandler = { [weak self] _, element in
                guard let button = element as? GCControllerButtonInput, button.isPressed,
                      let flag = map.first(where: { $0.0 === button })?.1 else { return }
                MainActor.assumeIsolated { _ = self?.latched.insert(flag) }
            }
        }
    }

    private func configure(_ keyboard: GCKeyboard) {
        keyboard.handlerQueue = .main
        keyboard.keyboardInput?.keyChangedHandler = { [weak self] _, _, key, pressed in
            guard pressed, let flag = Self.keys.first(where: { $0.0 == key })?.1 ?? (key == .spacebar ? .cross : nil) else { return }
            MainActor.assumeIsolated { _ = self?.latched.insert(flag) }
        }
    }

    private static func buttons(_ pad: GCExtendedGamepad) -> [(GCControllerButtonInput, InputState.Buttons)] {
        var map: [(GCControllerButtonInput, InputState.Buttons)] = [
            (pad.buttonA, .cross), (pad.buttonB, .circle), (pad.buttonX, .square), (pad.buttonY, .triangle),
            (pad.leftShoulder, .l1), (pad.rightShoulder, .r1), (pad.leftTrigger, .l2), (pad.rightTrigger, .r2),
            (pad.buttonMenu, .start),
        ]
        if let options = pad.buttonOptions { map.append((options, .select)) }
        return map
    }

    private static let keys: [(GCKeyCode, InputState.Buttons)] = [
        (.keyK, .cross), (.keyL, .circle), (.keyJ, .square), (.keyI, .triangle),
        (.keyQ, .l1), (.keyE, .r1), (.returnOrEnter, .start), (.tab, .select),
    ]

    /// Light bar in Naruto's orange (DualSense / DualShock 4; others have no light).
    nonisolated private static func configureLight(_ controller: GCController) {
        controller.light?.color = GCColor(red: 1.0, green: 0.42, blue: 0.0)
    }

    func press(_ buttons: InputState.Buttons, stick: SIMD2<Float>) {
        virtual.buttons = buttons
        virtual.leftStick = stick
        virtualTicks = Self.virtualPressTicks
    }

    func sample() -> InputState {
        var state = InputState()
        defer { virtualTicks = max(0, virtualTicks - 1) }
        if virtualTicks > 0 {
            state.buttons.formUnion(virtual.buttons)
            state.leftStick = virtual.leftStick
        }
        // A latched press shows as held for this one sample, then as released on the next.
        state.buttons.formUnion(latched)
        latched = []
        if let pad = GCController.current?.extendedGamepad {
            for (button, flag) in Self.buttons(pad) where button.isPressed { state.buttons.insert(flag) }
            let stick = SIMD2(pad.leftThumbstick.xAxis.value, pad.leftThumbstick.yAxis.value)
            let dpad = SIMD2(pad.dpad.xAxis.value, pad.dpad.yAxis.value)
            // The D-pad drives the same direction as the stick (menus read `leftStick`).
            let direction = simd_length(stick) >= simd_length(dpad) ? stick : dpad
            if direction != .zero { state.leftStick = direction }
            state.rightStick = SIMD2(pad.rightThumbstick.xAxis.value, pad.rightThumbstick.yAxis.value)
        } else if let remote = GCController.current?.microGamepad {
            if remote.buttonA.isPressed { state.buttons.insert(.cross) }
            if remote.buttonX.isPressed { state.buttons.insert(.circle) }
            let dpad = SIMD2(remote.dpad.xAxis.value, remote.dpad.yAxis.value)
            if dpad != .zero { state.leftStick = dpad }
        }
        if let keyboard = GCKeyboard.coalesced?.keyboardInput {
            for (key, flag) in Self.keys where keyboard.button(forKeyCode: key)?.isPressed == true {
                state.buttons.insert(flag)
            }
            func axis(_ negative: GCKeyCode, _ positive: GCKeyCode) -> Float {
                (keyboard.button(forKeyCode: positive)?.isPressed == true ? 1 : 0)
                    - (keyboard.button(forKeyCode: negative)?.isPressed == true ? 1 : 0)
            }
            let letters = SIMD2(axis(.keyA, .keyD), axis(.keyS, .keyW))
            let arrows = SIMD2(axis(.leftArrow, .rightArrow), axis(.downArrow, .upArrow))
            let keyStick = letters != .zero ? letters : arrows
            if keyStick != .zero { state.leftStick = keyStick }
            if keyboard.button(forKeyCode: .spacebar)?.isPressed == true { state.buttons.insert(.cross) }
        }
        return state
    }
}
