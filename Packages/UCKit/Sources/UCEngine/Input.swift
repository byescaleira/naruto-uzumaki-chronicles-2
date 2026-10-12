import GameController

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

/// Reads the current controller (extended gamepad, Siri Remote, or keyboard).
@MainActor
final class InputSource {
    func sample() -> InputState {
        var state = InputState()
        if let pad = GCController.current?.extendedGamepad {
            let map: [(GCControllerButtonInput, InputState.Buttons)] = [
                (pad.buttonA, .cross), (pad.buttonB, .circle), (pad.buttonX, .square), (pad.buttonY, .triangle),
                (pad.leftShoulder, .l1), (pad.rightShoulder, .r1), (pad.leftTrigger, .l2), (pad.rightTrigger, .r2),
                (pad.buttonMenu, .start),
            ]
            for (button, flag) in map where button.isPressed { state.buttons.insert(flag) }
            if pad.buttonOptions?.isPressed == true { state.buttons.insert(.select) }
            state.leftStick = SIMD2(pad.leftThumbstick.xAxis.value, pad.leftThumbstick.yAxis.value)
            state.rightStick = SIMD2(pad.rightThumbstick.xAxis.value, pad.rightThumbstick.yAxis.value)
        } else if let remote = GCController.current?.microGamepad {
            if remote.buttonA.isPressed { state.buttons.insert(.cross) }
            if remote.buttonX.isPressed { state.buttons.insert(.circle) }
            state.leftStick = SIMD2(remote.dpad.xAxis.value, remote.dpad.yAxis.value)
        }
        if let keyboard = GCKeyboard.coalesced?.keyboardInput {
            let keys: [(GCKeyCode, InputState.Buttons)] = [
                (.keyK, .cross), (.keyL, .circle), (.keyJ, .square), (.keyI, .triangle),
                (.keyQ, .l1), (.keyE, .r1), (.returnOrEnter, .start), (.tab, .select),
            ]
            for (key, flag) in keys where keyboard.button(forKeyCode: key)?.isPressed == true {
                state.buttons.insert(flag)
            }
            func axis(_ negative: GCKeyCode, _ positive: GCKeyCode) -> Float {
                (keyboard.button(forKeyCode: positive)?.isPressed == true ? 1 : 0)
                    - (keyboard.button(forKeyCode: negative)?.isPressed == true ? 1 : 0)
            }
            let keyStick = SIMD2(axis(.keyA, .keyD), axis(.keyS, .keyW))
            if keyStick != .zero { state.leftStick = keyStick }
        }
        return state
    }
}
