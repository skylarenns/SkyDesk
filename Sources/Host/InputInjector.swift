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
    private var scrollSteps = ScrollAccumulator()
    private var momentum: ScrollMomentum?
    private var momentumTimer: Timer?
    private var momentumLast = 0.0
    private var momentumStarted = false
    private var gestures: Set<GestureEvent.Kind> = []

    func handle(_ input: InputEvent) {
        guard input.isValid, AXIsProcessTrusted(), displayBounds.width > 0 else { return }
        let flags = Self.flags(input.modifiers)
        switch input.kind {
        case .move, .down, .up:
            if input.kind == .down { stopMomentum() }
            if input.relative == true {
                // Captured pointer: movement as distances, clicks wherever the Mac's pointer is (PointerCapture.swift).
                guard let delta = capturedMove(input) else { return }
                postPointer(input, delta: delta, flags: flags)
                return
            }
            if pointerCaptured { pointerCaptured = false; relativePointer.reset(); MetricsLog.shared.append("host  pointer released by the iPad") }
            let previous = location
            location = CGPoint(x: displayBounds.minX + input.x * max(0, displayBounds.width - 1),
                               y: displayBounds.minY + input.y * max(0, displayBounds.height - 1))
            var delta = CGPoint(x: location.x - previous.x, y: location.y - previous.y)
            // macOS moves the Dock to a screen only when the pointer pushes down against that screen's bottom
            // edge. Absolute positions never push, so a move that stays on the bottom row counts as a push.
            let bottomRow = displayBounds.maxY - 1
            if input.kind == .move, input.y >= Self.bottomEdge, previous.y >= bottomRow - 1, displayBounds.contains(previous) {
                location.y = bottomRow
                delta.y = max(delta.y, 8)
            }
            // The same for the other three edges (build 43): a move that stays on an edge is a push against it, which
            // is what a real mouse held there reports and what edge-triggered things on the Mac wait for.
            if input.kind == .move, displayBounds.contains(previous) {
                if input.x <= Self.onEdge, previous.x <= displayBounds.minX + 1 { location.x = displayBounds.minX; delta.x = min(delta.x, -8); notePush("left") }
                if input.x >= 1 - Self.onEdge, previous.x >= displayBounds.maxX - 2 { location.x = displayBounds.maxX - 1; delta.x = max(delta.x, 8); notePush("right") }
                if input.y <= Self.onEdge, previous.y <= displayBounds.minY + 1 { location.y = displayBounds.minY; delta.y = min(delta.y, -8); notePush("top") }
            }
            postPointer(input, delta: delta, flags: flags)
        case .scroll:
            if input.phase == ScrollPhase.began || input.phase == nil { stopMomentum() }
            if input.phase == ScrollPhase.began { scrollSteps.reset() }
            let step = scrollSteps.step(CGPoint(x: input.x, y: input.y))
            // Whole points only reach the Mac, but the fractions carry over (slow scrolls used to be rounded away).
            guard input.phase != nil || step.x != 0 || step.y != 0 else { return }
            postScroll(step, flags: flags, phase: input.phase.map(Self.cgPhase) ?? 0, momentumPhase: 0)
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
    /// Posts a move, press or release at `location`, reporting `delta` as the distance moved.
    private func postPointer(_ input: InputEvent, delta: CGPoint, flags: CGEventFlags) {
        var button = CGMouseButton(rawValue: UInt32(input.button)) ?? .left
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
        } else if buttons.contains(0) { type = .leftMouseDragged; button = .left }
        else if buttons.contains(1) { type = .rightMouseDragged; button = .right }
        else if buttons.contains(2) { type = .otherMouseDragged; button = .center }
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: button)
        event?.flags = flags
        event?.setIntegerValueField(.mouseEventDeltaX, value: Int64(delta.x.rounded()))
        event?.setIntegerValueField(.mouseEventDeltaY, value: Int64(delta.y.rounded()))
        if input.kind != .move { event?.setIntegerValueField(.mouseEventClickState, value: clickCount) }
        Self.post(event)
    }
    private var relativePointer = RelativePointer()
    private var pointerCaptured = false
    /// Sets `location` for a captured-pointer event and returns the distance to report; nil = nothing to post yet.
    private func capturedMove(_ input: InputEvent) -> CGPoint? {
        // Where the pointer really is: the game may hold it in place or have put it somewhere itself.
        let current = CGEvent(source: nil)?.location ?? location
        if !pointerCaptured { pointerCaptured = true; MetricsLog.shared.append("host  pointer captured by the iPad: movement arrives as distances") }
        guard input.kind == .move else { location = current; return .zero }
        guard let step = relativePointer.step(dx: input.x, dy: input.y, from: current, in: displayBounds) else { return nil }
        location = step.target
        return CGPoint(x: step.dx, y: step.dy)
    }
    /// A pinch or rotation from the iPad, replayed as the Mac trackpad gesture for the app under the pointer.
    func handle(_ gesture: GestureEvent) {
        guard gesture.isValid, AXIsProcessTrusted(), displayBounds.width > 0 else { return }
        var gesture = gesture
        if gesture.phase == ScrollPhase.began {
            stopMomentum()
            // A second "began" without an end (lost message) continues the gesture instead of restarting it.
            if !gestures.insert(gesture.kind).inserted { gesture.phase = ScrollPhase.changed }
        } else if gesture.phase == ScrollPhase.changed {
            if gestures.insert(gesture.kind).inserted { postGesture(GestureEvent(kind: gesture.kind, value: 0, phase: ScrollPhase.began)) }
        } else if gestures.remove(gesture.kind) == nil { return }
        postGesture(gesture)
    }
    private func postGesture(_ gesture: GestureEvent) {
        guard let event = GestureInjection.event(gesture, at: location) else { return }
        RemoteInputOrigin.lastGesture = monotonicNanos()
        event.post(tap: .cghidEventTap)
    }
    /// Normalised distance from the left, right or top edge within which a move counts as on that edge.
    static let onEdge = 0.0005
    private var lastPushNote = 0.0
    /// For the log, at most once every five seconds: proof that the iPad's pointer really reached an edge.
    private func notePush(_ edge: String) {
        let now = CACurrentMediaTime()
        guard now - lastPushNote >= 5 else { return }
        lastPushNote = now
        MetricsLog.shared.append("host  pointer pushed against the \(edge) edge")
    }
    /// Normalised y at or below which a pointer move counts as resting on the bottom edge (about 5 points).
    static let bottomEdge = 0.995
    /// Lift-off velocity from the iPad (points per second): glide on, generated here at 120 Hz.
    func startMomentum(velocity: CGPoint) {
        stopMomentum()
        guard let glide = ScrollMomentum(velocity: velocity) else { return }
        momentum = glide; momentumStarted = false; momentumLast = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.glide() } }
        RunLoop.main.add(timer, forMode: .common); momentumTimer = timer
    }
    private func glide() {
        let now = CACurrentMediaTime(); let dt = min(0.05, now - momentumLast); momentumLast = now
        guard var glide = momentum, let delta = glide.step(dt) else { stopMomentum(); return }
        momentum = glide
        let step = scrollSteps.step(delta)
        postScroll(step, flags: [], phase: 0, momentumPhase: momentumStarted ? 2 : 1)
        momentumStarted = true
    }
    func stopMomentum() {
        guard momentumTimer != nil else { return }
        momentumTimer?.invalidate(); momentumTimer = nil; momentum = nil
        if momentumStarted { postScroll((0, 0), flags: [], phase: 0, momentumPhase: 3) }
        momentumStarted = false
    }
    /// Continuous (trackpad-style) pixel scrolling with macOS phases, so apps scroll smoothly and rubber-band.
    private func postScroll(_ step: (x: Int32, y: Int32), flags: CGEventFlags, phase: Int64, momentumPhase: Int64) {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: step.y, wheel2: step.x, wheel3: 0)
        event?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        if phase != 0 { event?.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase) }
        if momentumPhase != 0 { event?.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase) }
        event?.location = location; event?.flags = flags; Self.post(event)
    }
    /// SkyDesk phase → CGScrollPhase (began 1, changed 2, ended 4).
    private static func cgPhase(_ phase: Int) -> Int64 { phase == ScrollPhase.began ? 1 : phase == ScrollPhase.changed ? 2 : 4 }
    func releaseAll() {
        stopMomentum()
        // An unfinished pinch or rotation would leave the Mac app waiting for its end.
        for kind in gestures { postGesture(GestureEvent(kind: kind, value: 0, phase: ScrollPhase.ended)) }
        gestures.removeAll()
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
