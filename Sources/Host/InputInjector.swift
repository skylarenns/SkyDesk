import AppKit
import ApplicationServices

@MainActor
final class InputInjector {
    var displayBounds: CGRect = .zero
    private var keys: Set<CGKeyCode> = []
    private var buttons: Set<Int> = []
    private var location: CGPoint = .zero
    private var lastClickTime: CFTimeInterval = 0
    private var lastClickLocation: CGPoint = .zero
    private var clickCount: Int64 = 1

    func handle(_ input: InputEvent) {
        guard input.isValid, AXIsProcessTrusted(), displayBounds.width > 0 else { return }
        let flags = Self.flags(input.modifiers)
        switch input.kind {
        case .move, .down, .up:
            location = CGPoint(x: displayBounds.minX + input.x * max(0, displayBounds.width - 1),
                               y: displayBounds.minY + input.y * max(0, displayBounds.height - 1))
            let button = CGMouseButton(rawValue: UInt32(input.button)) ?? .left
            var type: CGEventType = .mouseMoved
            if input.kind == .down {
                buttons.insert(input.button)
                type = input.button == 0 ? .leftMouseDown : input.button == 1 ? .rightMouseDown : .otherMouseDown
                let now = CACurrentMediaTime()
                if now - lastClickTime < NSEvent.doubleClickInterval,
                   hypot(location.x - lastClickLocation.x, location.y - lastClickLocation.y) < 6 {
                    clickCount = min(3, clickCount + 1)
                } else { clickCount = 1 }
                lastClickTime = now; lastClickLocation = location
            } else if input.kind == .up {
                buttons.remove(input.button)
                type = input.button == 0 ? .leftMouseUp : input.button == 1 ? .rightMouseUp : .otherMouseUp
            } else if buttons.contains(0) { type = .leftMouseDragged }
            else if buttons.contains(1) { type = .rightMouseDragged }
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: button)
            event?.flags = flags
            if input.kind != .move { event?.setIntegerValueField(.mouseEventClickState, value: clickCount) }
            Self.post(event)
        case .scroll:
            let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                wheel1: Int32(input.y.rounded()), wheel2: Int32(input.x.rounded()), wheel3: 0)
            event?.location = location; event?.flags = flags; Self.post(event)
        case .key:
            guard let code = Self.keyMap[input.keyCode] else { return }
            let repeated = input.isDown && keys.contains(code)
            if input.isDown { keys.insert(code) } else { keys.remove(code) }
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: input.isDown)
            event?.flags = flags
            event?.setIntegerValueField(.keyboardEventAutorepeat, value: repeated ? 1 : 0)
            Self.post(event)
        }
    }
    func releaseAll() {
        for code in keys {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
            event?.flags = []; Self.post(event)
        }
        for button in buttons {
            let event = CGEvent(mouseEventSource: nil, mouseType: button == 0 ? .leftMouseUp : button == 1 ? .rightMouseUp : .otherMouseUp,
                               mouseCursorPosition: location, mouseButton: CGMouseButton(rawValue: UInt32(button)) ?? .left)
            event?.flags = []; Self.post(event)
        }
        keys.removeAll(); buttons.removeAll()
    }
    func insertText(_ text: String) {
        guard AXIsProcessTrusted(), text.utf8.count <= 8192, displayBounds.width > 0 else { return }
        if text == "\n" || text == "\r" {
            handle(InputEvent(kind: .key, keyCode: 40, isDown: true))
            handle(InputEvent(kind: .key, keyCode: 40, isDown: false)); return
        }
        var chunk: [UniChar] = []
        func post() {
            guard !chunk.isEmpty else { return }
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                event?.flags = []
                chunk.withUnsafeBufferPointer { buffer in
                    event?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
                }
                Self.post(event)
            }
            chunk.removeAll(keepingCapacity: true)
        }
        for scalar in text.unicodeScalars {
            let units = Array(String(scalar).utf16)
            if chunk.count + units.count > 20 { post() }
            chunk.append(contentsOf: units)
        }
        post()
    }
    private static func post(_ event: CGEvent?) {
        guard let event else { return }
        RemoteInputOrigin.mark(event)
        event.post(tap: .cghidEventTap)
    }
    private static func flags(_ value: UInt) -> CGEventFlags {
        var flags: CGEventFlags = []
        if value & 1 != 0 { flags.insert(.maskShift) }
        if value & 2 != 0 { flags.insert(.maskControl) }
        if value & 4 != 0 { flags.insert(.maskAlternate) }
        if value & 8 != 0 { flags.insert(.maskCommand) }
        if value & 16 != 0 { flags.insert(.maskAlphaShift) }
        return flags
    }
    // USB HID keyboard usages map to physical Apple key positions, preserving the Mac's layout.
    static let keyMap: [Int: CGKeyCode] = [
        4:0, 5:11, 6:8, 7:2, 8:14, 9:3, 10:5, 11:4, 12:34, 13:38, 14:40, 15:37,
        16:46, 17:45, 18:31, 19:35, 20:12, 21:15, 22:1, 23:17, 24:32, 25:9, 26:13, 27:7, 28:16, 29:6,
        30:18, 31:19, 32:20, 33:21, 34:23, 35:22, 36:26, 37:28, 38:25, 39:29,
        40:36, 41:53, 42:51, 43:48, 44:49, 45:27, 46:24, 47:33, 48:30, 49:42, 50:10,
        51:41, 52:39, 53:50, 54:43, 55:47, 56:44, 57:57,
        58:122, 59:120, 60:99, 61:118, 62:96, 63:97, 64:98, 65:100, 66:101, 67:109, 68:103, 69:111,
        73:114, 74:115, 75:116, 76:117, 77:119, 78:121, 79:124, 80:123, 81:125, 82:126,
        83:71, 84:75, 85:67, 86:78, 87:69, 88:76, 89:83, 90:84, 91:85, 92:86, 93:87,
        94:88, 95:89, 96:91, 97:92, 98:82, 99:65, 100:10, 103:81,
        224:59, 225:56, 226:58, 227:55, 228:62, 229:60, 230:61, 231:54
    ]
}
