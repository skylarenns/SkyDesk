import AppKit
import QuartzCore

/// Calls back once per refresh of the display the iPad shows, in step with it (build 63). Scrolling used a
/// 120 Hz Timer, which drifts against the display and waits behind anything else on the main thread. The display
/// link starts on demand and stops as soon as the callback says there is nothing left to do.
@MainActor
final class DisplayTicker: NSObject {
    private let onTick: (Double) -> Bool
    private var link: CADisplayLink?
    private var timer: Timer?
    private var ticked = false
    /// Set once the display link was seen not to fire: a 120 Hz timer is used from then on.
    private var linkFailed = false
    /// The screen to follow; the main screen if this gives none.
    var screen: () -> NSScreen? = { nil }
    init(_ onTick: @escaping (Double) -> Bool) { self.onTick = onTick }
    var running: Bool { link != nil || timer != nil }
    func start() {
        guard !running else { return }
        guard !linkFailed, let screen = screen() ?? NSScreen.main else { startTimer(); return }
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        let fastest = Float(max(60, screen.maximumFramesPerSecond))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: fastest, maximum: fastest, preferred: fastest)
        link.add(to: .main, forMode: .common)
        self.link = link; ticked = false
        // Scrolling must never wait on a display link that does not fire (a display going away, say).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.link === link, !self.ticked else { return }
                self.linkFailed = true
                MetricsLog.shared.append("host  display link did not fire; scrolling paced by a 120 Hz timer instead")
                link.invalidate(); self.link = nil
                self.startTimer()
            }
        }
    }
    private func startTimer() {
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if let self, !self.onTick(CACurrentMediaTime()) { self.stop() } }
        }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    func stop() { link?.invalidate(); link = nil; timer?.invalidate(); timer = nil }
    @objc private func tick(_ link: CADisplayLink) {
        ticked = true
        if !onTick(link.targetTimestamp) { stop() }
    }
}
