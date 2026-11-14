import SwiftUI
import MetalKit
import UIKit

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
        return view
    }
    func updateUIView(_ view: DesktopMetalView, context: Context) {
        Breadcrumb.mark("swiftui:update"); defer { Breadcrumb.mark("swiftui:updated") }
        view.controlsFrame = controlsFrame
        view.setSharpening(client.sharpenText)
        view.setLocalCursorEnabled(client.localCursorActive)
        view.setPointerScale(client.pointerScale)
        view.setCursor(client.remoteCursor)
        view.updateKeyboard(wanted: client.keyboardWanted, focus: client.textFocus, fallback: client.lastTapRect)
    }
    static func dismantleUIView(_ view: DesktopMetalView, coordinator: ()) {
        view.releaseKeys(); view.isPaused = true
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

    init(mailbox: FrameMailbox, info: StreamInfo) {
        remoteSize = CGSize(width: info.width, height: info.height); targetFPS = info.fps
        localCursor = (info.features ?? 0) & StreamFeature.localCursor != 0
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        backgroundColor = .black; isMultipleTouchEnabled = true
        framebufferOnly = true
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        colorPixelFormat = .bgra8Unorm
        autoResizeDrawable = true
        preferredFramesPerSecond = info.fps
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
        addGestureRecognizer(drag)
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
        for recognizer in gestureRecognizers ?? [] { recognizer.delegate = self }
        addInteraction(UIPointerInteraction(delegate: self))
        deactivateObserver = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in self?.releaseKeys() }
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        repeatTimer?.invalidate()
        if let deactivateObserver { NotificationCenter.default.removeObserver(deactivateObserver) }
        keyboardObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }
    override var canBecomeFirstResponder: Bool { true }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let window {
            contentScaleFactor = window.screen.nativeScale
            preferredFramesPerSecond = min(targetFPS, window.screen.maximumFramesPerSecond)
            becomeFirstResponder()
        } else { releaseKeys() }
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
        heldKeys.removeAll(); modifiers = 0; dragActive = false
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
        let location = recognizer.location(in: self)
        let p = point(location)
        let leaving = recognizer.state == .ended || recognizer.state == .cancelled || recognizer.state == .failed
        moveCursor(to: p == nil || leaving ? nil : location)
        if let p { pointer(.move, at: p) }
    }
    @objc private func tapped(_ recognizer: UITapGestureRecognizer) { click(recognizer, button: 0) }
    @objc private func rightClicked(_ recognizer: UITapGestureRecognizer) { click(recognizer, button: 1) }
    private func click(_ recognizer: UITapGestureRecognizer, button: Int) {
        if !keyboard.isFirstResponder { becomeFirstResponder() }
        syncModifiers(recognizer)
        guard let p = point(recognizer.location(in: self)) else { return }
        moveCursor(to: recognizer.location(in: self))
        pointer(.down, at: p, button: button); pointer(.up, at: p, button: button)
    }
    @objc private func dragged(_ recognizer: UIPanGestureRecognizer) {
        syncModifiers(recognizer)
        let location = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            if !keyboard.isFirstResponder { becomeFirstResponder() }
            let translation = recognizer.translation(in: self)
            guard let p = point(CGPoint(x: location.x - translation.x, y: location.y - translation.y)) else { return }
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
        if recognizer.state == .began, dragActive { pointer(.up, at: lastPoint); dragActive = false }
        if let p = point(recognizer.location(in: self)) { pointer(.move, at: p) }
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
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer is UIHoverGestureRecognizer || other is UIHoverGestureRecognizer
    }
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? { .hidden() }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled: Set<UIPress> = []
        for press in presses {
            guard let key = press.key else { unhandled.insert(press); continue }
            let code = key.keyCode.rawValue
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
