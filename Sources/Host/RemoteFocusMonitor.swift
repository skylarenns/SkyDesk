import AppKit
import ApplicationServices

/// Reads only focused-element role and geometry, never text or password contents.
final class RemoteFocusMonitor {
    private let queue = DispatchQueue(label: "skydesk.text-focus", qos: .userInitiated)
    private var bounds: CGRect
    private var timer: DispatchSourceTimer?
    private var previous: RemoteTextFocus?
    var onFocus: ((RemoteTextFocus) -> Void)?

    init(bounds: CGRect) { self.bounds = bounds }
    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.refresh(force: false) }
        self.timer = timer; timer.resume()
    }
    func updateBounds(_ bounds: CGRect) {
        queue.async { [weak self] in
            guard let self, self.bounds != bounds else { return }
            self.bounds = bounds; self.previous = nil; self.refresh(force: true)
        }
    }
    func checkAfterClick() {
        queue.asyncAfter(deadline: .now() + .milliseconds(60)) { [weak self] in self?.refresh(force: true) }
    }
    func stop() { timer?.cancel(); timer = nil }
    deinit { timer?.cancel() }

    private func refresh(force: Bool) {
        let focus = readFocus()
        if force || focus != previous { previous = focus; onFocus?(focus) }
    }
    private func readFocus() -> RemoteTextFocus {
        guard AXIsProcessTrusted(), bounds.width > 0, bounds.height > 0 else { return .none }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.08)
        guard let raw = attribute(system, kAXFocusedUIElementAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return .none }
        let element = unsafeBitCast(raw, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.08)
        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        guard [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role),
              (attribute(element, kAXEnabledAttribute) as? Bool) != false else { return .none }
        let subrole = attribute(element, kAXSubroleAttribute) as? String ?? ""
        var rect: CGRect?
        if let range = attribute(element, kAXSelectedTextRangeAttribute) {
            var value: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                          range, &value) == .success,
               let value, CFGetTypeID(value) == AXValueGetTypeID() {
                let ax = unsafeBitCast(value, to: AXValue.self)
                var caret = CGRect.zero
                if AXValueGetType(ax) == .cgRect, AXValueGetValue(ax, .cgRect, &caret), caret.height > 0 { rect = caret }
            }
        }
        if rect == nil, let position = attribute(element, kAXPositionAttribute),
           let size = attribute(element, kAXSizeAttribute),
           CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() {
            var point = CGPoint.zero; var extent = CGSize.zero
            let p = unsafeBitCast(position, to: AXValue.self), s = unsafeBitCast(size, to: AXValue.self)
            if AXValueGetType(p) == .cgPoint, AXValueGetType(s) == .cgSize,
               AXValueGetValue(p, .cgPoint, &point), AXValueGetValue(s, .cgSize, &extent) {
                rect = CGRect(origin: point, size: extent)
            }
        }
        guard var rect, rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite else { return .none }
        rect.size.width = max(1, rect.width)
        rect = rect.intersection(bounds)
        guard !rect.isNull, rect.height > 0 else { return .none }
        let normalized = CGRect(x: (rect.minX - bounds.minX) / bounds.width, y: (rect.minY - bounds.minY) / bounds.height,
                                width: rect.width / bounds.width, height: rect.height / bounds.height)
        var pid: pid_t = 0; AXUIElementGetPid(element, &pid)
        let id = (UInt64(UInt32(bitPattern: pid)) << 32) ^ UInt64(CFHash(element))
        return RemoteTextFocus(id: id, rect: normalized, secure: subrole == kAXSecureTextFieldSubrole)
    }
    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}
