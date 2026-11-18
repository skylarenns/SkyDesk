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
    private var momentumLast = 0.0
    private var momentumStarted = false
    private var gestures: Set<GestureEvent.Kind> = []

    func handle(_ input: InputEvent) {
        guard input.isValid, AXIsProcessTrusted(), displayBounds.width > 0 else { return }
        lastInputTime = CACurrentMediaTime()
        let flags = Self.flags(sanitized(input))
        switch input.kind {
        case .move, .down, .up:
            if input.kind == .down { stopMomentum() }
            // For the automatic capture: was the pointer found where the last movements put it?
            let actual = input.kind == .move && onPointerHeld != nil ? CGEvent(source: nil)?.location : nil
            if let actual { noteHold(moved: true, followed: following.followed(actual: actual), actual: actual) }
            defer { if let actual { following.sent(target: location, from: actual) } }
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
                if input.x <= Self.onEdge, previous.x <= displayBounds.minX + 1 { location.x = displayBounds.minX; delta.x = min(delta.x, -8); notePush("left", input) }
                if input.x >= 1 - Self.onEdge, previous.x >= displayBounds.maxX - 2 { location.x = displayBounds.maxX - 1; delta.x = max(delta.x, 8); notePush("right", input) }
                if input.y <= Self.onEdge, previous.y <= displayBounds.minY + 1 { location.y = displayBounds.minY; delta.y = min(delta.y, -8); notePush("top", input) }
            }
            postPointer(input, delta: delta, flags: flags)
        case .scroll:
            if input.phase == ScrollPhase.began || input.phase == nil { stopMomentum() }
            if input.phase == ScrollPhase.began { scrollSteps.reset() }
            noteScrollArrival()
            if paceScrolling, let phase = input.phase {
                pacedScroll(CGPoint(x: input.x, y: input.y), phase: phase, flags: flags)
                return
            }
            let step = scrollSteps.step(CGPoint(x: input.x, y: input.y))
            // Whole points only reach the Mac, but the fractions carry over (slow scrolls used to be rounded away).
            guard input.phase != nil || step.x != 0 || step.y != 0 else { return }
            postScroll(step, flags: flags, phase: input.phase.map(Self.cgPhase) ?? 0, momentumPhase: 0)
        case .key:
            guard let code = Self.keyMap[input.keyCode] else { return }
            let repeated = input.isDown && keys.contains(code)
            if input.isDown { keys.insert(code) } else { keys.remove(code) }
            if Self.commandKeys.contains(code) { MetricsLog.shared.append("host  ⌘ key " + (input.isDown ? (repeated ? "down again" : "down") : "up") + " from the iPad") }
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: input.isDown)
            // After the key itself is counted, so a modifier's own press carries its flag and its release does not.
            event?.flags = Self.flags(sanitized(input))
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
    /// An app on the Mac took the mouse (true) or gave it back; nil while the iPad does not want to be told.
    var onPointerHeld: ((Bool) -> Void)? {
        didSet { if onPointerHeld == nil { holdTimer?.invalidate(); holdTimer = nil; hold = PointerHoldDetector(); following.reset() } }
    }
    private var hold = PointerHoldDetector()
    private var following = PointerFollowing()
    private var holdTimer: Timer?
    private func noteHold(moved: Bool, followed: Bool? = nil, actual: CGPoint? = nil) {
        guard let onPointerHeld else { return }
        let hidden = !SkyDeskPointerIsVisible()
        guard let held = hold.note(hidden: hidden, moved: moved, followed: followed, actual: actual, now: CACurrentMediaTime()) else { return }
        let evidence = actual.map { String(format: " at %.0f,%.0f, readings within %.1f pt", $0.x, $0.y, hold.lastWander) } ?? ""
        MetricsLog.shared.append("host  " + (held ? "an app has taken the mouse (pointer hidden and held in place\(evidence))"
                                                  : "the app gave the mouse back (" + (hidden ? "the pointer goes where it is put again" : "pointer showing") + ")"))
        holdTimer?.invalidate(); holdTimer = nil
        if held {
            // Giving it back shows as the pointer reappearing, which may happen while nothing moves.
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.noteHold(moved: false) } }
            RunLoop.main.add(timer, forMode: .common); holdTimer = timer
        }
        onPointerHeld(held)
    }
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
    private func notePush(_ edge: String, _ input: InputEvent) {
        let now = CACurrentMediaTime()
        guard now - lastPushNote >= 5 else { return }
        lastPushNote = now
        MetricsLog.shared.append(String(format: "host  pointer pushed against the %@ edge (at %.3f, %.3f of the desktop)", edge, input.x, input.y))
    }
    /// Normalised y at or below which a pointer move counts as resting on the bottom edge (about 5 points).
    static let bottomEdge = 0.995
    /// Lift-off velocity from the iPad (points per second): glide on, generated here at 120 Hz.
    func startMomentum(velocity: CGPoint) {
        stopMomentum()
        noteGlide(start: velocity)
        guard let glide = ScrollMomentum(velocity: velocity) else { noteGlideEnd(); return }
        momentum = glide; momentumStarted = false; momentumLast = CACurrentMediaTime()
        // With paced scrolling the glide waits until the fingers' last movement has gone out and their end posted.
        if !fingerScrolling { glideRunning = true }
        ticker.start()
    }
    private func glide(now: Double) {
        let dt = min(0.05, max(0, now - momentumLast)); momentumLast = max(momentumLast, now)
        guard var glide = momentum, let delta = glide.step(dt) else { stopMomentum(); return }
        momentum = glide
        guard delta != .zero else { return }
        let step = scrollSteps.step(delta)
        postScroll(step, flags: [], phase: 0, momentumPhase: momentumStarted ? 2 : 1)
        momentumStarted = true
    }
    func stopMomentum() {
        guard momentum != nil || glideRunning else { return }
        momentum = nil; glideRunning = false
        if momentumStarted { postScroll((0, 0), flags: [], phase: 0, momentumPhase: 3) }
        momentumStarted = false
        noteGlideEnd()
    }

    // MARK: Paced scrolling (build 63)

    /// Scroll movement goes out in even portions, one per display refresh (ScrollPacer). Host setting.
    var paceScrolling = true
    private var pacer = ScrollPacer()
    private var fingerScrolling = false, fingerEnding = false
    private var pacedFlags: CGEventFlags = []
    private var glideRunning = false
    private lazy var ticker: DisplayTicker = {
        let ticker = DisplayTicker { [weak self] now in self?.refresh(now: now) ?? false }
        ticker.screen = { [weak self] in
            guard let bounds = self?.displayBounds else { return nil }
            return NSScreen.screens.first { screen in
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDisplayBounds($0.uint32Value) == bounds } ?? false
            }
        }
        return ticker
    }()
    private func pacedScroll(_ delta: CGPoint, phase: Int, flags: CGEventFlags) {
        pacedFlags = flags
        if phase == ScrollPhase.began {
            // A gesture still letting out its last movement ends first, so apps never see two at once.
            if fingerScrolling { finishFinger() }
            pacer.reset(); fingerScrolling = true; fingerEnding = false
            postScroll((0, 0), flags: flags, phase: 1, momentumPhase: 0)
        } else if !fingerScrolling { return }
        pacer.add(delta)
        if phase == ScrollPhase.ended { fingerEnding = true }
        ticker.start()
    }
    /// One display refresh. Returns whether there is more to do (otherwise the ticker stops).
    private func refresh(now: Double) -> Bool {
        if fingerScrolling {
            let out = pacer.next()
            let step = scrollSteps.step(out)
            if step.x != 0 || step.y != 0 { postScroll(step, flags: pacedFlags, phase: 2, momentumPhase: 0); notePacedStep() }
            if fingerEnding && pacer.isEmpty { finishFinger(); return true }
        }
        if glideRunning { glide(now: now) }
        else if !fingerScrolling, momentum != nil { glideRunning = true; momentumLast = now }
        return fingerScrolling ? !pacer.isEmpty || fingerEnding : glideRunning
    }
    private func finishFinger() {
        let rest = scrollSteps.step(pacer.next(ending: true))
        if rest.x != 0 || rest.y != 0 { postScroll(rest, flags: pacedFlags, phase: 2, momentumPhase: 0) }
        postScroll((0, 0), flags: pacedFlags, phase: 4, momentumPhase: 0)
        fingerScrolling = false; fingerEnding = false; pacer.reset()
        // The glide's first step comes on the next refresh, a whole refresh after this one.
        if momentum != nil { glideRunning = true; momentumLast = CACurrentMediaTime() }
    }

    // MARK: Scroll log (build 63)

    private var scrollIn = 0, scrollOut = 0, scrollGapMax = 0.0, lastScrollArrival = 0.0, scrollSecond = 0.0
    private var glideStart: (speed: Double, at: Double)?
    private func noteScrollArrival() {
        let now = CACurrentMediaTime()
        if lastScrollArrival > 0, now - lastScrollArrival < 0.2 { scrollGapMax = max(scrollGapMax, now - lastScrollArrival) }
        lastScrollArrival = now; scrollIn += 1
        flushScrollLog(now: now)
    }
    private func notePacedStep() { scrollOut += 1 }
    /// At most once a second while scrolling: how many movements came in, the longest gap between two of them
    /// inside a gesture, and how many even steps went out.
    private func flushScrollLog(now: Double) {
        if scrollSecond == 0 { scrollSecond = now; return }
        guard now - scrollSecond >= 1 else { return }
        MetricsLog.shared.append(String(format: "host  scroll: %d movements in, longest gap %.1f ms, %d steps out%@",
                                        scrollIn, scrollGapMax * 1_000, scrollOut, paceScrolling ? " (paced)" : " (as they came)"))
        scrollSecond = now; scrollIn = 0; scrollOut = 0; scrollGapMax = 0
    }
    private func noteGlide(start velocity: CGPoint) { glideStart = (hypot(velocity.x, velocity.y), CACurrentMediaTime()) }
    private func noteGlideEnd() {
        guard let start = glideStart else { return }
        glideStart = nil
        MetricsLog.shared.append(String(format: "host  glide from %.0f pt/s lasted %.2f s%@", start.speed, CACurrentMediaTime() - start.at,
                                        start.speed < 60 ? " (too slow to glide)" : ""))
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
        if fingerScrolling { finishFinger() }
        stopMomentum(); ticker.stop()
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
    // MARK: Modifier honesty (build 67)

    /// Mac key codes of each modifier's left and right keys, by SkyDesk modifier bit.
    static let modifierCodes: [(bit: UInt, codes: Set<CGKeyCode>)] = [(1, [56, 60]), (2, [59, 62]), (4, [58, 61]), (8, [55, 54])]
    static let commandKeys: Set<CGKeyCode> = [55, 54]
    private var lastFlagNote = 0.0
    /// A modifier counts only while its key is held here (user report 2026-11-18: ⌘ stuck again with the iPad's own
    /// check finding nothing held). The iPad's flags follow its own idea of the modifiers, which can lag behind
    /// the keys; every real modifier press arrives as a key, so a flag without its key is dropped. Caps Lock is a
    /// toggle with no held key and passes through.
    private func sanitized(_ input: InputEvent) -> UInt {
        var allowed: UInt = 16
        for (bit, codes) in Self.modifierCodes where !keys.isDisjoint(with: codes) { allowed |= bit }
        let dropped = input.modifiers & ~allowed
        if dropped != 0 {
            let now = CACurrentMediaTime()
            if now - lastFlagNote >= 2 {
                lastFlagNote = now
                let what = input.kind == .key ? "key \(input.keyCode) " + (input.isDown ? "down" : "up") : input.kind.rawValue
                MetricsLog.shared.append("host  iPad sent modifiers \(input.modifiers) on a \(what) with no such key held; dropped \(dropped)")
            }
        }
        return input.modifiers & allowed
    }
    private var macCommandSince: Double?
    /// Once a second: does macOS itself think ⌘ is down while SkyDesk holds no ⌘ key? Logged, and released after
    /// three seconds of that while the iPad is the one being used (a ⌘ held on the Mac's own keyboard is left alone
    /// unless the iPad has been sending input meanwhile).
    func checkModifiers(padActive: Bool) {
        let macCommand = CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand)
        let ours = !keys.isDisjoint(with: Self.commandKeys)
        guard macCommand, !ours else { macCommandSince = nil; return }
        let now = CACurrentMediaTime()
        if macCommandSince == nil {
            macCommandSince = now
            MetricsLog.shared.append("host  macOS reports ⌘ down, but SkyDesk holds no ⌘ key" + (padActive ? " (iPad in use)" : ""))
        }
        guard padActive, let since = macCommandSince, now - since >= 3 else { return }
        macCommandSince = nil
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 55, keyDown: false)
        event?.flags = []; Self.post(event)
        MetricsLog.shared.append("host  released a stuck ⌘ (macOS still had it down after 3 s)")
    }
    var lastInputTime = 0.0

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
