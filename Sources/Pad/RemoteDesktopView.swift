import SwiftUI
import MetalKit
import UIKit
import GameController

/// The window's root controller: asked to have iPadOS hide the pointer and hold it still (captured pointer).
protocol PointerLocking: AnyObject { var pointerLockWanted: Bool { get set } }

struct RemoteDesktopView: UIViewRepresentable {
    @ObservedObject var client: ClientModel
    let info: StreamInfo
    var controlsFrame: CGRect = .zero
    func makeUIView(context: Context) -> DesktopMetalView {
        let view = DesktopMetalView(mailbox: client.mailbox, info: info)
        view.sendInput = { [weak client] in client?.input($0) }
        view.releaseRemoteInput = { [weak client] in client?.releaseInput() }
        view.reportError = { [weak client] in client?.notice = $0 }
        view.sendText = { [weak client] in client?.sendText($0) }
        view.deleteText = { [weak client] in client?.deleteText() }
        view.keyboardDismissed = { [weak client] in client?.keyboardWanted = false }
        view.sendMomentum = { [weak client] in client?.scrollMomentum($0) }
        view.sendGesture = { [weak client] in client?.gesture($0) }
        client.drawNote = { [weak view] in view?.drawNote ?? "" }
        view.desktopSwipe = { [weak client] in client?.desktopSwipe($0) }
        view.toggleCapture = { [weak client] in client?.toggleGameMouse() }
        return view
    }
    func updateUIView(_ view: DesktopMetalView, context: Context) {
        Breadcrumb.mark("swiftui:update"); defer { Breadcrumb.mark("swiftui:updated") }
        view.controlsFrame = controlsFrame
        view.setSharpening(client.sharpenText)
        view.presentOnArrival = client.presentOnArrival
        view.setLocalCursorEnabled(client.localCursorActive)
        view.setPointerScale(client.pointerScale)
        view.setCursor(client.remoteCursor)
        view.setPointerCapture(client.pointerCaptured, speed: client.capturedPointerSpeed)
        view.updateKeyboard(wanted: client.keyboardWanted, focus: client.textFocus, fallback: client.lastTapRect)
    }
    static func dismantleUIView(_ view: DesktopMetalView, coordinator: ()) {
        view.setPointerCapture(false, speed: 1)
        view.releaseKeys(); view.stopDisplayLink()
        // Same rule as updateKeyboard: no responder change while SwiftUI is updating.
        DispatchQueue.main.async { view.endKeyboard() }
    }
}

final class DesktopMetalView: MTKView, UIGestureRecognizerDelegate, UIPointerInteractionDelegate {
    var sendInput: ((InputEvent) -> Void)?
    var releaseRemoteInput: (() -> Void)?
    var reportError: ((String) -> Void)?
    var sendText: ((String) -> Void)?
    var deleteText: (() -> Void)?
    var keyboardDismissed: (() -> Void)?
    /// Lift-off velocity of a scroll, in points per second.
    var sendMomentum: ((CGPoint) -> Void)?
    var sendGesture: ((GestureEvent) -> Void)?
    var desktopSwipe: ((ClientModel.DesktopSwipe) -> Void)?
    /// Control-Option-G was pressed: capture the pointer, or give it back.
    var toggleCapture: (() -> Void)?
    private var captured = false
    private var captureSpeed = 1.0
    private var coalescer = DeltaCoalescer()
    private var flushWork: DispatchWorkItem?
    private var mouseObservers: [NSObjectProtocol] = []
    private var lastDeviceMove: CFTimeInterval = 0
    private var lastHover: CGPoint?
    private var deviceButtons: Set<Int> = []
    /// Scrolling may reach the app from the gesture recognisers, from the mouse itself, or from both at once;
    /// whichever reports first during a capture keeps it, so nothing scrolls twice.
    private enum ScrollOwner { case undecided, gestures, device }
    private var scrollOwner = ScrollOwner.undecided
    private weak var dragRecognizer: UIPanGestureRecognizer?
    private var dragFromPointer = false
    /// Where the finger or pointer went down for the drag now being recognised (build 56). The pan recogniser
    /// starts only after some movement, and the start worked out from its translation came out about one
    /// character along in text (user report 2026-11-16: "always a character off" when selecting).
    private var dragTouchDown: CGPoint?
    /// For the log: how far the old estimate of the start was from the real one, last drag and how many drags.
    private var dragStartError = 0.0, dragStarts = 0
    private var swallowedKeys: Set<Int> = []
    private var gestureSteps = GestureSteps()
    private var activeGestures: Set<GestureEvent.Kind> = []
    var controlsFrame: CGRect = .zero
    private let keyboard = RemoteKeyboardProxy()
    private var keyboardObservers: [NSObjectProtocol] = []
    private var keyboardHeight: CGFloat = 0
    private var focusRect: CGRect?
    private var focusID: UInt64 = 0
    private var keyboardWanted = false
    /// Drawn here, under the user's hand, so pointer movement does not wait for the video round trip.
    private let cursorView = UIImageView()
    private var localCursor: Bool
    private var cursor: RemoteCursor?
    private var cursorHotSpot = CGPoint(x: 5.0 / 28, y: 5.0 / 40)
    private var cursorLocation: CGPoint?
    private let keyboardChange = DeferredAction()
    private var renderer: FrameRenderer?
    private let remoteSize: CGSize
    private let targetFPS: Int
    private var lastPoint = CGPoint(x: 0.5, y: 0.5)
    private var modifiers: UInt = 0
    private var dragActive = false
    private var repeatTimer: Timer?
    private var repeatKey: Int?
    private var heldKeys: Set<Int> = []
    private var deactivateObserver: NSObjectProtocol?
    /// Draw a frame the moment it arrives when it can still make the next screen refresh (build 35).
    var presentOnArrival = true
    private let mailbox: FrameMailbox
    private var displayLink: CADisplayLink?
    private var pacer = ArrivalPacer()

    init(mailbox: FrameMailbox, info: StreamInfo) {
        self.mailbox = mailbox
        remoteSize = CGSize(width: info.width, height: info.height); targetFPS = info.fps
        localCursor = (info.features ?? 0) & StreamFeature.localCursor != 0
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        backgroundColor = .black; isMultipleTouchEnabled = true
        framebufferOnly = true
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        colorPixelFormat = .bgra8Unorm
        autoResizeDrawable = true
        // Drawn by this view's own display link (and on frame arrival), not by MTKView's timer.
        isPaused = true; enableSetNeedsDisplay = false
        if let layer = layer as? CAMetalLayer { layer.maximumDrawableCount = 3; layer.allowsNextDrawableTimeout = true }
        if let device {
            do { renderer = try FrameRenderer(device: device, mailbox: mailbox); delegate = renderer }
            catch { DispatchQueue.main.async { [weak self] in self?.reportError?(error.localizedDescription) } }
        } else { DispatchQueue.main.async { [weak self] in self?.reportError?("Metal is unavailable on this device.") } }
        addSubview(keyboard)
        // Always present (hidden) so the pointer can be switched on and off during a session.
        cursorView.isUserInteractionEnabled = false; cursorView.isHidden = true
        cursorView.image = Self.arrowImage; cursorView.bounds.size = CGSize(width: 28, height: 40)
        cursorView.layer.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "hidden": NSNull()]
        addSubview(cursorView)
        keyboard.committedText = { [weak self] in self?.sendText?($0) }
        keyboard.deleteRemote = { [weak self] in self?.deleteText?() }
        keyboard.hardwareBegan = { [weak self] in self?.pressesBegan($0, with: $1) }
        keyboard.hardwareEnded = { [weak self] in self?.pressesEnded($0, with: $1) }
        keyboardObservers.append(NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification,
            object: nil, queue: .main) { [weak self] notification in
                guard let self, let screenFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                let local = self.convert(screenFrame, from: nil)
                let overlap = self.bounds.intersection(local)
                self.keyboardHeight = overlap.isNull ? 0 : overlap.height
                self.updateViewport()
            })
        keyboardObservers.append(NotificationCenter.default.addObserver(forName: UIResponder.keyboardDidHideNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.keyboardHeight = 0; self.updateViewport()
                self.keyboardDismissed?()
            })

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        addGestureRecognizer(hover)
        let drag = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        drag.maximumNumberOfTouches = 1
        addGestureRecognizer(drag); dragRecognizer = drag
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.require(toFail: drag)
        addGestureRecognizer(tap)
        let secondary = UITapGestureRecognizer(target: self, action: #selector(rightClicked(_:)))
        secondary.buttonMaskRequired = .secondary
        secondary.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        addGestureRecognizer(secondary)
        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(rightClicked(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        addGestureRecognizer(twoFingerTap)
        let touchScroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        touchScroll.minimumNumberOfTouches = 2; touchScroll.maximumNumberOfTouches = 2
        touchScroll.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        addGestureRecognizer(touchScroll)
        let trackpadScroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        trackpadScroll.allowedTouchTypes = []; trackpadScroll.allowedScrollTypesMask = .all
        addGestureRecognizer(trackpadScroll)
        // Pinch and rotate, from the trackpad (the pointer stays where it is) or with two fingers on the screen.
        let both = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.allowedTouchTypes = both
        addGestureRecognizer(pinch)
        let rotation = UIRotationGestureRecognizer(target: self, action: #selector(rotated(_:)))
        rotation.allowedTouchTypes = both
        addGestureRecognizer(rotation)
        // Three fingers on the screen: Mission Control, app windows and desktops. (iPadOS keeps three-finger
        // swipes on the trackpad for itself, so those never reach an app.)
        for direction in [UISwipeGestureRecognizer.Direction.up, .down, .left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(threeFingerSwiped(_:)))
            swipe.direction = direction; swipe.numberOfTouchesRequired = 3
            swipe.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            addGestureRecognizer(swipe)
        }
        for recognizer in gestureRecognizers ?? [] { recognizer.delegate = self }
        addInteraction(UIPointerInteraction(delegate: self))
        deactivateObserver = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in self?.releaseKeys() }
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        repeatTimer?.invalidate(); edgePushTimer?.invalidate(); flushWork?.cancel()
        mouseObservers.forEach { NotificationCenter.default.removeObserver($0) }
        displayLink?.invalidate(); mailbox.onArrival(nil)
        if let deactivateObserver { NotificationCenter.default.removeObserver(deactivateObserver) }
        keyboardObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }
    override var canBecomeFirstResponder: Bool { true }
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let window {
            contentScaleFactor = window.screen.nativeScale
            startDisplayLink(rate: min(targetFPS, window.screen.maximumFramesPerSecond))
            becomeFirstResponder()
            (window.rootViewController as? PointerLocking)?.pointerLockWanted = captured
        } else { stopDisplayLink(); releaseKeys() }
    }
    private func startDisplayLink(rate: Int) {
        displayLink?.invalidate()
        let link = CADisplayLink(target: DisplayLinkTarget(self), selector: #selector(DisplayLinkTarget.tick(_:)))
        // Exactly the stream's rate, not a range: given 80–120, iPadOS chose the slow end and every frame waited
        // longer for its turn (build 35: local display 19 ms instead of 16.4).
        let fastest = Float(max(30, rate))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: fastest, maximum: fastest, preferred: fastest)
        link.add(to: .main, forMode: .common)
        displayLink = link
        mailbox.onArrival { [weak self] in DispatchQueue.main.async { self?.frameArrived() } }
    }
    func stopDisplayLink() {
        displayLink?.invalidate(); displayLink = nil
        mailbox.onArrival(nil)
    }
    /// Every screen refresh: draw whatever is waiting (a new frame, or a redraw after a layout change).
    fileprivate func displayTick(_ link: CADisplayLink) {
        let interval = link.targetTimestamp - link.timestamp
        if interval > 0 { refreshHz = refreshHz == 0 ? 1 / interval : refreshHz * 0.9 + 0.1 / interval }
        pacer.tick(target: link.targetTimestamp, interval: interval)
        let before = renderer?.submitted
        draw()
        if renderer?.submitted != before { pacer.drew() }
    }
    private var refreshHz = 0.0
    /// For the diagnostic log: the display link's real rate, and how drawing on arrival is going.
    var drawNote: String {
        String(format: "hz=%.0f early=%d/%d margin=%.1f dragfix=%.1f/%d", refreshHz, pacer.hits, pacer.misses, pacer.margin * 1_000,
               dragStartError, dragStarts)
    }
    /// A frame finished decoding. If nothing has been drawn for the coming refresh and there is still time to
    /// make it, draw now; otherwise the next tick takes it, as before.
    private func frameArrived() {
        guard presentOnArrival, displayLink != nil, let renderer, pacer.mayDrawOnArrival(now: CACurrentMediaTime()) else { return }
        let expected = pacer.nextRefresh
        let before = renderer.submitted
        renderer.presentedOnce = { [weak self] presented in
            DispatchQueue.main.async { self?.pacer.arrivalResult(expected: expected, presented: presented) }
        }
        draw()
        if renderer.submitted != before { pacer.drew() } else { renderer.presentedOnce = nil }
    }
    override func resignFirstResponder() -> Bool { releaseKeys(); return super.resignFirstResponder() }
    override func layoutSubviews() { Breadcrumb.mark("layout"); super.layoutSubviews(); updateViewport(); placeCursor(); Breadcrumb.mark("layout:end") }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if controlsFrame.contains(convert(point, to: nil)) { return nil }
        return super.hitTest(point, with: event)
    }
    func updateKeyboard(wanted: Bool, focus: RemoteTextFocus, fallback: CGRect?) {
        focusRect = focus.rect ?? fallback
        if focus.id != focusID { keyboard.resetComposition(); focusID = focus.id }
        if keyboard.isSecureTextEntry != focus.secure { keyboard.isSecureTextEntry = focus.secure }
        keyboardWanted = wanted
        // Called from a SwiftUI view update: the responder change itself must wait for the update to finish.
        keyboardChange.schedule { [weak self] in self?.applyKeyboard() }
        updateViewport()
    }
    private func applyKeyboard() {
        Breadcrumb.mark("keyboard:apply"); defer { Breadcrumb.mark("keyboard:applied") }
        guard window != nil else { return }
        if keyboardWanted, !keyboard.isFirstResponder { keyboard.becomeFirstResponder() }
        if !keyboardWanted, keyboard.isFirstResponder { keyboard.resignFirstResponder(); becomeFirstResponder() }
    }
    /// Only shows or hides a subview: safe inside a SwiftUI update (no responder change).
    private var pointerScale: CGFloat = 1
    /// Enlarges the drawn pointer around its tip (hot spot), so clicks still land where it points.
    func setPointerScale(_ scale: Double) {
        let value = CGFloat(max(0.5, min(3, scale)))
        guard value != pointerScale else { return }
        pointerScale = value
        if localCursor { placeCursor() }
    }
    func setLocalCursorEnabled(_ enabled: Bool) {
        guard enabled != localCursor else { return }
        localCursor = enabled
        if enabled { placeCursor() } else { cursorView.isHidden = true }
    }
    func setCursor(_ value: RemoteCursor?) {
        guard value != cursor else { return }
        cursor = value
        if let value, let image = UIImage(data: value.png) {
            cursorView.image = image; cursorHotSpot = CGPoint(x: value.hotX, y: value.hotY)
        }
        if localCursor { placeCursor() }
    }
    /// `location` is in this view's coordinates; nil hides the pointer (it left the desktop).
    private func moveCursor(to location: CGPoint?) {
        cursorLocation = location
        if localCursor { placeCursor() }
    }
    private func placeCursor() {
        guard localCursor else { return }
        guard let location = cursorLocation else { cursorView.isHidden = true; return }
        let frame = DesktopGeometry.keyboardAdjustedFit(content: remoteSize, in: bounds, keyboardHeight: keyboardHeight, focus: focusRect)
        var size = CGSize(width: 28, height: 40)
        if let cursor { size = CGSize(width: cursor.width * frame.width, height: cursor.height * frame.height) }
        size = CGSize(width: size.width * pointerScale, height: size.height * pointerScale)
        guard size.width >= 1, size.height >= 1 else { cursorView.isHidden = true; return }
        cursorView.frame = CGRect(x: location.x - cursorHotSpot.x * size.width, y: location.y - cursorHotSpot.y * size.height,
                                  width: size.width, height: size.height)
        cursorView.isHidden = false
    }
    /// Stand-in until the Mac sends its real pointer image.
    private static let arrowImage: UIImage = UIGraphicsImageRenderer(size: CGSize(width: 28, height: 40)).image { _ in
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 5, y: 5)); path.addLine(to: CGPoint(x: 5, y: 28)); path.addLine(to: CGPoint(x: 10.5, y: 23))
        path.addLine(to: CGPoint(x: 14.5, y: 32)); path.addLine(to: CGPoint(x: 18, y: 30.5)); path.addLine(to: CGPoint(x: 14, y: 21.5))
        path.addLine(to: CGPoint(x: 21.5, y: 21.5)); path.close()
        UIColor.white.setStroke(); path.lineWidth = 2.5; path.lineJoinStyle = .round; path.stroke()
        UIColor.black.setFill(); path.fill()
    }
    func endKeyboard() { keyboard.resignFirstResponder() }
    func setSharpening(_ enabled: Bool) { renderer?.setSharpening(enabled) }
    private func updateViewport() {
        renderer?.setViewport(keyboardFraction: bounds.height > 0 ? keyboardHeight / bounds.height : 0, focus: focusRect)
    }
    func releaseKeys() {
        repeatTimer?.invalidate(); repeatTimer = nil; repeatKey = nil
        heldKeys.removeAll(); modifiers = 0; dragActive = false; deviceButtons.removeAll()
        activeGestures.removeAll()
        pushAgainstEdge(nil)
        releaseRemoteInput?()
    }
    private func point(_ location: CGPoint) -> CGPoint? {
        guard !controlsFrame.contains(convert(location, to: nil)) else { return nil }
        let frame = DesktopGeometry.keyboardAdjustedFit(content: remoteSize, in: bounds, keyboardHeight: keyboardHeight, focus: focusRect)
        return DesktopGeometry.normalized(location, in: frame)
    }
    /// Pointer events report the real modifier keys; trust them over what earlier key events left behind.
    private func syncModifiers(_ recognizer: UIGestureRecognizer) {
        let actual = Self.flags(recognizer.modifierFlags)
        for code in ModifierSync.stale(held: heldKeys, actual: actual) {
            heldKeys.remove(code)
            sendInput?(InputEvent(kind: .key, keyCode: code, isDown: false, modifiers: actual))
        }
        modifiers = actual
    }
    private func pointer(_ kind: InputEvent.Kind, at point: CGPoint, button: Int = 0) {
        lastPoint = point
        sendInput?(InputEvent(kind: kind, x: point.x, y: point.y, button: button, modifiers: modifiers))
    }
    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        syncModifiers(recognizer)
        var location = recognizer.location(in: self)
        let leaving = recognizer.state == .ended || recognizer.state == .cancelled || recognizer.state == .failed
        if captured {
            // Until iPadOS holds the pointer (or with a pointing device that does not report its own movement),
            // movement is taken from how far the pointer itself went.
            defer { lastHover = leaving ? nil : location }
            guard CACurrentMediaTime() - lastDeviceMove > 0.5, let last = lastHover, !leaving else { return }
            capturedMove(dx: location.x - last.x, dy: location.y - last.y)
            return
        }
        // Near an edge of the Mac desktop the pointer counts as on it; a pointer that leaves the picture close to
        // an edge went out through that edge. (Not under the toolbar, which is not part of the desktop.)
        var onEdge = false
        if !controlsFrame.contains(convert(location, to: nil)) {
            let frame = DesktopGeometry.keyboardAdjustedFit(content: remoteSize, in: bounds, keyboardHeight: keyboardHeight, focus: focusRect)
            if frame.insetBy(dx: leaving ? -24 : 0, dy: leaving ? -24 : 0).contains(location) {
                let clamped = CGPoint(x: min(max(location.x, frame.minX), frame.maxX - 0.01), y: min(max(location.y, frame.minY), frame.maxY - 0.01))
                (location, onEdge) = PointerEdges.snapped(clamped, in: frame)
            }
        }
        let p = point(location)
        moveCursor(to: p == nil || leaving ? nil : location)
        if let p { pointer(.move, at: p) }
        pushAgainstEdge(onEdge ? p : nil)
    }
    /// Where a press at `location` lands: the same place the pointer was shown while it hovered there. Near an edge
    /// of the Mac desktop the hovering pointer is put exactly on the edge (build 43), so the Mac shows what is on
    /// the edge, such as the arrows for resizing a window that reaches it. Until build 51 the press itself went to
    /// the true position a few points further in, which is inside the window: the Mac's pointer hopped off the
    /// edge as the button went down and the drag moved whatever was there instead of resizing (2026-11-16).
    private func pressLocation(_ location: CGPoint) -> CGPoint {
        guard !controlsFrame.contains(convert(location, to: nil)) else { return location }
        let frame = DesktopGeometry.keyboardAdjustedFit(content: remoteSize, in: bounds, keyboardHeight: keyboardHeight, focus: focusRect)
        guard frame.contains(location) else { return location }
        return PointerEdges.snapped(location, in: frame).point
    }
    private var edgePush: (point: CGPoint, left: Int)?
    private var edgePushTimer: Timer?
    /// A real mouse held against a screen edge keeps reporting movement; the iPad's pointer goes quiet. While the
    /// pointer rests on an edge the same move is sent a few more times, and the Mac replays each as a push.
    private func pushAgainstEdge(_ point: CGPoint?) {
        guard let point else { edgePush = nil; edgePushTimer?.invalidate(); edgePushTimer = nil; return }
        edgePush = (point, PointerEdges.pushes)
        guard edgePushTimer == nil else { return }
        let timer = Timer(timeInterval: PointerEdges.pushInterval, repeats: true) { [weak self] _ in
            guard let self, let push = self.edgePush, push.left > 0, !self.dragActive else { self?.pushAgainstEdge(nil); return }
            self.edgePush = (push.point, push.left - 1)
            self.pointer(.move, at: push.point)
        }
        RunLoop.main.add(timer, forMode: .common); edgePushTimer = timer
    }
    @objc private func tapped(_ recognizer: UITapGestureRecognizer) { click(recognizer, button: 0) }
    @objc private func rightClicked(_ recognizer: UITapGestureRecognizer) { click(recognizer, button: 1) }
    private func click(_ recognizer: UITapGestureRecognizer, button: Int) {
        if !keyboard.isFirstResponder { becomeFirstResponder() }
        syncModifiers(recognizer)
        if captured { capturedButton(button, down: true); capturedButton(button, down: false); return }
        let location = pressLocation(recognizer.location(in: self))
        guard let p = point(location) else { return }
        moveCursor(to: location)
        pointer(.down, at: p, button: button); pointer(.up, at: p, button: button)
    }
    @objc private func dragged(_ recognizer: UIPanGestureRecognizer) {
        syncModifiers(recognizer)
        if captured { capturedDrag(recognizer); return }
        let location = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            if !keyboard.isFirstResponder { becomeFirstResponder() }
            let translation = recognizer.translation(in: self)
            let estimate = CGPoint(x: location.x - translation.x, y: location.y - translation.y)
            let start = dragTouchDown ?? estimate
            dragTouchDown = nil
            dragStartError = hypot(start.x - estimate.x, start.y - estimate.y); dragStarts += 1
            // The press happened where the drag began, and counts as on an edge exactly when the hovering pointer did.
            guard let p = point(pressLocation(start)) else { return }
            pushAgainstEdge(nil)
            dragActive = true; pointer(.down, at: p)
        case .changed:
            if dragActive, let p = point(location) { moveCursor(to: location); pointer(.move, at: p) }
        case .ended, .cancelled, .failed:
            if dragActive { pointer(.up, at: point(location) ?? lastPoint); dragActive = false }
        default: break
        }
    }
    @objc private func scrolled(_ recognizer: UIPanGestureRecognizer) {
        syncModifiers(recognizer)
        if captured {
            if scrollOwner == .undecided { scrollOwner = .gestures }
            guard scrollOwner == .gestures else { return }
            if recognizer.state == .began, dragActive { capturedButton(0, down: false); dragActive = false }
        } else {
            if recognizer.state == .began, dragActive { pointer(.up, at: lastPoint); dragActive = false }
            if let p = point(recognizer.location(in: self)) { pointer(.move, at: p) }
        }
        let delta = recognizer.translation(in: self)
        recognizer.setTranslation(.zero, in: self)
        let phase: Int
        switch recognizer.state {
        case .began: phase = ScrollPhase.began
        case .changed: phase = ScrollPhase.changed
        default: phase = ScrollPhase.ended
        }
        // Began and ended are always sent (they frame the gesture for Mac apps); changes only when something moved.
        if delta != .zero || phase != ScrollPhase.changed {
            sendInput?(InputEvent(kind: .scroll, x: max(-2000, min(2000, delta.x)),
                                 y: max(-2000, min(2000, delta.y)), modifiers: modifiers, phase: phase))
        }
        if recognizer.state == .ended { sendMomentum?(recognizer.velocity(in: self)) }
    }
    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        transform(recognizer, kind: .magnify) { gestureSteps.magnification(scale: Double(recognizer.scale)) }
    }
    @objc private func rotated(_ recognizer: UIRotationGestureRecognizer) {
        transform(recognizer, kind: .rotate) { gestureSteps.degrees(radians: Double(recognizer.rotation)) }
    }
    /// Began and ended always frame the gesture for the Mac app; steps in between only when something changed.
    private func transform(_ recognizer: UIGestureRecognizer, kind: GestureEvent.Kind, step: () -> Double?) {
        syncModifiers(recognizer)
        switch recognizer.state {
        case .began:
            if dragActive { pointer(.up, at: lastPoint); dragActive = false }
            if activeGestures.isEmpty { gestureSteps.reset() }
            let location = recognizer.location(in: self)
            // The Mac zooms whatever is under its pointer: for fingers on the screen, that is between them.
            if let p = point(location) { moveCursor(to: location); pointer(.move, at: p) }
            activeGestures.insert(kind)
            sendGesture?(GestureEvent(kind: kind, value: step() ?? 0, phase: ScrollPhase.began))
        case .changed:
            guard activeGestures.contains(kind), let value = step(), value != 0 else { return }
            sendGesture?(GestureEvent(kind: kind, value: value, phase: ScrollPhase.changed))
        case .ended, .cancelled, .failed:
            guard activeGestures.remove(kind) != nil else { return }
            sendGesture?(GestureEvent(kind: kind, value: 0, phase: ScrollPhase.ended))
        default: break
        }
    }
    @objc private func threeFingerSwiped(_ recognizer: UISwipeGestureRecognizer) {
        guard recognizer.state == .ended, point(recognizer.location(in: self)) != nil else { return }
        if dragActive { pointer(.up, at: lastPoint); dragActive = false }
        switch recognizer.direction {
        case .up: desktopSwipe?(.up)
        case .down: desktopSwipe?(.down)
        case .left: desktopSwipe?(.left)
        case .right: desktopSwipe?(.right)
        default: break
        }
    }
    // MARK: Captured pointer (games)

    /// iPadOS hides the pointer and holds it still only for a full-screen app in front, and says when it has.
    private var pointerLocked: Bool { window?.windowScene?.pointerLockState?.isLocked == true }
    func setPointerCapture(_ on: Bool, speed: Double) {
        captureSpeed = max(0.1, min(10, speed))
        guard on != captured else { return }
        captured = on
        (window?.rootViewController as? PointerLocking)?.pointerLockWanted = on
        pushAgainstEdge(nil); lastHover = nil; scrollOwner = .undecided
        flushWork?.cancel(); flushWork = nil; coalescer.reset()
        if on {
            if dragActive { pointer(.up, at: lastPoint); dragActive = false }
            moveCursor(to: nil)
            for mouse in GCMouse.mice() { attach(mouse) }
            mouseObservers.append(NotificationCenter.default.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { [weak self] note in
                if let mouse = note.object as? GCMouse { self?.attach(mouse) }
            })
        } else {
            mouseObservers.forEach { NotificationCenter.default.removeObserver($0) }; mouseObservers = []
            for mouse in GCMouse.mice() { detach(mouse) }
            for button in deviceButtons.sorted() { capturedButton(button, down: false) }
            deviceButtons.removeAll()
            if dragActive { capturedButton(0, down: false); dragActive = false }
        }
    }
    /// A mouse or trackpad reports its own movement and buttons here while the pointer is captured.
    private func attach(_ mouse: GCMouse) {
        guard captured, let input = mouse.mouseInput else { return }
        mouse.handlerQueue = .main
        input.mouseMovedHandler = { [weak self] _, dx, dy in
            guard let self, self.captured else { return }
            self.lastDeviceMove = CACurrentMediaTime()
            // The mouse counts upwards as positive; the Mac's screen counts downwards.
            self.capturedMove(dx: Double(dx), dy: -Double(dy))
        }
        input.leftButton.pressedChangedHandler = { [weak self] _, _, pressed in self?.deviceButton(0, pressed) }
        input.rightButton?.pressedChangedHandler = { [weak self] _, _, pressed in self?.deviceButton(1, pressed) }
        input.middleButton?.pressedChangedHandler = { [weak self] _, _, pressed in self?.deviceButton(2, pressed) }
        input.scroll.valueChangedHandler = { [weak self] _, x, y in self?.deviceScroll(x: Double(x), y: Double(y)) }
    }
    private func detach(_ mouse: GCMouse) {
        guard let input = mouse.mouseInput else { return }
        input.mouseMovedHandler = nil; input.leftButton.pressedChangedHandler = nil
        input.rightButton?.pressedChangedHandler = nil; input.middleButton?.pressedChangedHandler = nil
        input.scroll.valueChangedHandler = nil
    }
    private func capturedMove(dx: Double, dy: Double) {
        guard captured, dx != 0 || dy != 0 else { return }
        switch coalescer.add(dx: dx * captureSpeed, dy: dy * captureSpeed, now: monotonicNanos()) {
        case .send(let x, let y):
            flushWork?.cancel(); flushWork = nil
            sendInput?(InputEvent(kind: .move, x: x, y: y, modifiers: modifiers, relative: true))
            flushCaptured()
        case .wait(let nanoseconds):
            guard flushWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in self?.flushWork = nil; self?.flushCaptured() }
            flushWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds)), execute: work)
        }
    }
    /// Sends whatever movement is being held back; a click calls this first so it lands after the movement.
    private func flushCaptured() {
        while let part = coalescer.flush(now: monotonicNanos()) {
            sendInput?(InputEvent(kind: .move, x: part.dx, y: part.dy, modifiers: modifiers, relative: true))
        }
    }
    private func capturedButton(_ button: Int, down: Bool) {
        flushWork?.cancel(); flushWork = nil; flushCaptured()
        sendInput?(InputEvent(kind: down ? .down : .up, button: button, modifiers: modifiers, relative: true))
    }
    private func deviceButton(_ button: Int, _ pressed: Bool) {
        guard captured, pressed != deviceButtons.contains(button) else { return }
        // Clicks come from the mouse itself only while iPadOS holds the pointer; otherwise the recognisers have
        // them, and taking both would click twice. A release is always passed on.
        if pressed {
            guard pointerLocked else { return }
            if !keyboard.isFirstResponder { becomeFirstResponder() }
            deviceButtons.insert(button)
        } else { deviceButtons.remove(button) }
        capturedButton(button, down: pressed)
    }
    private func deviceScroll(x: Double, y: Double) {
        guard captured, x != 0 || y != 0 else { return }
        if scrollOwner == .undecided { scrollOwner = .device }
        guard scrollOwner == .device else { return }
        sendInput?(InputEvent(kind: .scroll, x: max(-2_000, min(2_000, x * 10)), y: max(-2_000, min(2_000, -y * 10)), modifiers: modifiers))
    }
    private func capturedDrag(_ recognizer: UIPanGestureRecognizer) {
        let moved = recognizer.translation(in: self)
        recognizer.setTranslation(.zero, in: self)
        // A mouse that reports its own movement is already being followed; a finger is followed from here.
        let follow = !dragFromPointer || CACurrentMediaTime() - lastDeviceMove > 0.5
        switch recognizer.state {
        case .began:
            if !keyboard.isFirstResponder { becomeFirstResponder() }
            // A held mouse button drags. A finger on the glass only steers, as on a trackpad; a tap clicks.
            if dragFromPointer { dragActive = true; capturedButton(0, down: true) }
            if follow { capturedMove(dx: moved.x, dy: moved.y) }
        case .changed:
            if follow { capturedMove(dx: moved.x, dy: moved.y) }
        case .ended, .cancelled, .failed:
            if dragActive { capturedButton(0, down: false); dragActive = false }
        default: break
        }
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        let fromPointer = touch.type == .indirectPointer
        // Held by iPadOS, the mouse reports its own buttons (deviceButton); these would be the same clicks again.
        if captured, pointerLocked, fromPointer { return false }
        if gestureRecognizer === dragRecognizer { dragFromPointer = fromPointer; dragTouchDown = touch.location(in: self) }
        return true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        if gestureRecognizer is UIHoverGestureRecognizer || other is UIHoverGestureRecognizer { return true }
        // Zooming and turning with the same two fingers, as on a Mac.
        let transforms = { (r: UIGestureRecognizer) in r is UIPinchGestureRecognizer || r is UIRotationGestureRecognizer }
        return transforms(gestureRecognizer) && transforms(other)
    }
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? { .hidden() }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled: Set<UIPress> = []
        for press in presses {
            guard let key = press.key else { unhandled.insert(press); continue }
            let code = key.keyCode.rawValue
            // Control-Option-G captures the pointer or gives it back; the G itself never reaches the Mac.
            if code == 10, key.modifierFlags.intersection([.control, .alternate, .command, .shift]) == [.control, .alternate] {
                swallowedKeys.insert(code); toggleCapture?(); continue
            }
            modifiers = Self.flags(key.modifierFlags)
            heldKeys.insert(code)
            sendInput?(InputEvent(kind: .key, keyCode: code, isDown: true, modifiers: modifiers))
            if code < 224 && code != 57 { startRepeating(code) }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        endPresses(presses)
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) { endPresses(presses) }
    private func endPresses(_ presses: Set<UIPress>) {
        for press in presses {
            guard let key = press.key else { continue }
            let code = key.keyCode.rawValue
            if swallowedKeys.remove(code) != nil { continue }
            modifiers = Self.flags(key.modifierFlags)
            heldKeys.remove(code)
            sendInput?(InputEvent(kind: .key, keyCode: code, isDown: false, modifiers: modifiers))
            if repeatKey == code { repeatTimer?.invalidate(); repeatTimer = nil; repeatKey = nil }
        }
    }
    private func startRepeating(_ code: Int) {
        repeatTimer?.invalidate(); repeatKey = code
        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            guard let self, self.heldKeys.contains(code) else { return }
            self.sendInput?(InputEvent(kind: .key, keyCode: code, isDown: true, modifiers: self.modifiers))
        }
        timer.fireDate = Date().addingTimeInterval(0.4)
        RunLoop.main.add(timer, forMode: .common); repeatTimer = timer
    }
    private static func flags(_ value: UIKeyModifierFlags) -> UInt {
        var flags: UInt = 0
        if value.contains(.shift) { flags |= 1 }; if value.contains(.control) { flags |= 2 }
        if value.contains(.alternate) { flags |= 4 }; if value.contains(.command) { flags |= 8 }
        if value.contains(.alphaShift) { flags |= 16 }
        return flags
    }
}

/// A display link keeps its target alive; this stand-in lets the view go away.
private final class DisplayLinkTarget {
    private weak var view: DesktopMetalView?
    init(_ view: DesktopMetalView) { self.view = view }
    @objc func tick(_ link: CADisplayLink) {
        guard let view else { link.invalidate(); return }
        view.displayTick(link)
    }
}
