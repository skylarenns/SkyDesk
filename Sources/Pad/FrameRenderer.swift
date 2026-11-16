import Foundation
import MetalKit

struct DecodedImage {
    let pixels: CVPixelBuffer
    let sequence: UInt64
    let receivedAt: UInt64
    var afterIdle = false
    /// Mac capture→encoded milliseconds for this frame (Mac clock), for the total estimate.
    var macMS: Double? = nil
    /// When the Mac captured it (Mac clock): only compared with other frames' capture times.
    var captureTime: UInt64? = nil
}

final class FrameMailbox {
    let statistics = StreamStatistics()
    private let lock = NSLock()
    private var latest: DecodedImage?
    private var highestSequence: UInt64 = 0
    private var arrival: (() -> Void)?
    /// Called (on the decoding thread) each time a newer frame is ready to draw.
    func onArrival(_ handler: (() -> Void)?) { lock.lock(); arrival = handler; lock.unlock() }
    func put(_ image: DecodedImage, bytes: Int, decodeMS: Double) {
        statistics.recordReceived(bytes: bytes, decodeMS: decodeMS)
        lock.lock()
        guard image.sequence > highestSequence else { lock.unlock(); return }
        highestSequence = image.sequence
        var image = image
        // A replaced frame never reaches the screen, so the pause it ended belongs to its successor.
        if latest?.afterIdle == true { image.afterIdle = true }
        latest = image
        let notify = arrival
        lock.unlock()
        notify?()
    }
    func take() -> DecodedImage? {
        lock.lock(); defer { lock.unlock() }
        let value = latest; latest = nil; return value
    }
    /// `time` shares the monotonic clock of `receivedAt` (mach absolute time).
    func didPresent(_ image: DecodedImage, at time: UInt64 = monotonicNanos()) {
        statistics.recordPresented(at: time, receivedAt: image.receivedAt, afterIdle: image.afterIdle, macMS: image.macMS,
                                   captureTime: image.captureTime)
    }
}

final class FrameRenderer: NSObject, MTKViewDelegate {
    private let mailbox: FrameMailbox
    private let commandQueue: MTLCommandQueue
    private let renderer: YUVMetalRenderer
    private var current: DecodedImage?
    private var submittedSequence: UInt64?
    private var needsRedraw = false
    private var sharpenText = true
    private var keyboardFraction: CGFloat = 0
    private var focusRect: CGRect?
    private let inFlight = DispatchSemaphore(value: 2)
    /// GPU time spent on this renderer's command buffers so far, in seconds (build 60). Written on Metal's
    /// completion thread, read on the main thread.
    private let gpuLock = NSLock()
    private var gpuTotal = 0.0
    var gpuSeconds: Double { gpuLock.withLock { gpuTotal } }
    /// Counts frames handed to the display; the view compares it before and after a draw.
    private(set) var submitted = 0
    /// Set just before a draw to learn when that frame reaches the screen (host clock, seconds). Used once.
    var presentedOnce: ((Double) -> Void)?

    init(device: MTLDevice, mailbox: FrameMailbox) throws {
        guard let queue = device.makeCommandQueue() else { throw DeskError.invalid("Metal command queue unavailable.") }
        commandQueue = queue; self.mailbox = mailbox
        renderer = try YUVMetalRenderer(device: device)
        super.init()
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { needsRedraw = true }
    func setSharpening(_ enabled: Bool) {
        if sharpenText != enabled { sharpenText = enabled; needsRedraw = true }
    }
    func setViewport(keyboardFraction: CGFloat, focus: CGRect?) {
        if self.keyboardFraction != keyboardFraction || focusRect != focus {
            self.keyboardFraction = keyboardFraction; focusRect = focus; needsRedraw = true
        }
    }
    func draw(in view: MTKView) {
        // Nothing new to show: return before touching a drawable, so an idle or busy GPU never stalls the main thread.
        guard inFlight.wait(timeout: .now()) == .success else { return }
        Breadcrumb.mark("draw:take")
        guard let fresh = mailbox.take() ?? (needsRedraw ? current : nil) else {
            inFlight.signal(); Breadcrumb.mark("draw:nothing"); return
        }
        current = fresh
        Breadcrumb.mark("draw:drawable"); defer { Breadcrumb.mark("draw:end") }
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = commandQueue.makeCommandBuffer() else {
            needsRedraw = true; inFlight.signal(); return
        }
        Breadcrumb.mark("draw:encode")
        let bounds = CGRect(origin: .zero, size: view.drawableSize)
        let content = CGSize(width: CVPixelBufferGetWidth(fresh.pixels), height: CVPixelBufferGetHeight(fresh.pixels))
        let fit = DesktopGeometry.keyboardAdjustedFit(content: content, in: bounds,
                                                      keyboardHeight: bounds.height * keyboardFraction, focus: focusRect)
        guard renderer.encode(fresh.pixels, pass: pass, commandBuffer: command, destination: fit,
                              sharpen: sharpenText ? 0.12 : 0) else {
            needsRedraw = true; inFlight.signal(); return
        }
        let isNew = fresh.sequence != submittedSequence
        submittedSequence = fresh.sequence; needsRedraw = false
        submitted &+= 1
        let observer = presentedOnce; presentedOnce = nil
        #if !targetEnvironment(simulator)
        if let observer { drawable.addPresentedHandler { drawable in if drawable.presentedTime > 0 { observer(drawable.presentedTime) } } }
        #endif
        if isNew {
            #if targetEnvironment(simulator)
            // The simulator SDK has no drawable presentation callback.
            command.addCompletedHandler { [mailbox] _ in mailbox.didPresent(fresh) }
            #else
            drawable.addPresentedHandler { [mailbox] drawable in
                // presentedTime is the host-clock scan-out time in seconds; zero means the frame was never shown.
                if drawable.presentedTime > 0 { mailbox.didPresent(fresh, at: UInt64(drawable.presentedTime * 1_000_000_000)) }
            }
            #endif
        }
        command.addCompletedHandler { [inFlight, weak self] buffer in
            let busy = buffer.gpuEndTime - buffer.gpuStartTime
            if busy > 0, busy < 1, let self { self.gpuLock.withLock { self.gpuTotal += busy } }
            inFlight.signal()
        }
        Breadcrumb.mark("draw:commit")
        command.present(drawable)
        command.commit()
    }
}
