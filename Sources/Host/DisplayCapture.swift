import AppKit
import ScreenCaptureKit
import CoreMedia

final class DisplayCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    let window: FrameWindow
    private let queue = DispatchQueue(label: "skydesk.capture", qos: .userInteractive)
    private var stream: SCStream?
    private let encoder: HEVCEncoder
    private let lock = NSLock()
    private var active = true
    private var paused = false
    private var configuration = SCStreamConfiguration()
    private var keyframeNeeded = false
    private var received = 0
    private var captured = 0
    private var skipped = 0
    private var encodeMilliseconds: Double = 0
    private var encodedBytes = 0
    private let markIdleGaps: Bool
    private var lastCapture: UInt64?   // capture queue only
    private var idlePending = true     // capture queue only
    private var latestImage: CVPixelBuffer?  // capture queue only
    var onFrame: ((VideoFrame) -> Void)?
    var onFailure: ((String) -> Void)?
    let info: StreamInfo

    init(display: SCDisplay, longestEdge: Int, fps: Int, bitrate: Int, inputEnabled: Bool,
         lowLatencyRateControl: Bool, nativeDesktop: Bool = false, clientFeatures: Int = 0, hostName: String? = nil,
         clipboard: Bool = false, files: Bool = false, audio: Bool = false) throws {
        window = .streaming(fps: fps)
        markIdleGaps = clientFeatures & StreamFeature.idleGapFlags != 0
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        let native = CGSize(width: mode?.pixelWidth ?? display.width, height: mode?.pixelHeight ?? display.height)
        let size = DesktopGeometry.pixelSize(native: native, longestEdge: longestEdge)
        info = StreamInfo(width: Int(size.width), height: Int(size.height), fps: fps, bitrate: bitrate,
                          displayName: nativeDesktop ? "iPad Retina desktop" : "Display \(display.displayID)",
                          inputEnabled: inputEnabled, textInputEnabled: inputEnabled,
                          displayBlankingSupported: nativeDesktop && inputEnabled,
                          features: Self.features(client: clientFeatures, inputEnabled: inputEnabled, clipboard: clipboard, files: files, audio: audio), hostName: hostName)
        try info.validate()
        encoder = try HEVCEncoder(width: info.width, height: info.height, fps: fps, bitrate: bitrate,
                                  lowLatencyRateControl: lowLatencyRateControl)
        super.init()
        let configuration = SCStreamConfiguration()
        configuration.width = info.width; configuration.height = info.height
        configuration.captureResolution = .best
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        // Surfaces stay retained until their encode finishes (measured p99 ≈ 16 ms, first frame ≈ 35 ms).
        // Three surfaces only cover 16.7 ms at 120 Hz, so ScreenCaptureKit ran dry and skipped frames.
        configuration.queueDepth = 8
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
        // With a local pointer on the iPad, a second, delayed one in the video would only trail behind it.
        configuration.showsCursor = (info.features ?? 0) & StreamFeature.localCursor == 0
        configuration.capturesAudio = false
        configuration.scalesToFit = true
        let filter = SCContentFilter(display: display, excludingWindows: [])
        self.configuration = configuration
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
    }
    private static func features(client: Int, inputEnabled: Bool, clipboard: Bool, files: Bool, audio: Bool) -> Int? {
        var value = client & StreamFeature.idleGapFlags != 0 ? StreamFeature.idleGapFlags | StreamFeature.clientStatsLog : 0
        // Without remote input the iPad never moves the pointer, so the video must keep showing it.
        if inputEnabled, client & StreamFeature.localCursor != 0 { value |= StreamFeature.localCursor }
        if client & StreamFeature.pauseVideo != 0 { value |= StreamFeature.pauseVideo }
        if inputEnabled, client & StreamFeature.liveCursorToggle != 0 { value |= StreamFeature.liveCursorToggle }
        if inputEnabled, client & StreamFeature.scrollMomentum != 0 { value |= StreamFeature.scrollMomentum }
        if inputEnabled, client & StreamFeature.gestures != 0 { value |= StreamFeature.gestures }
        if client & StreamFeature.remoteUpdate != 0 { value |= StreamFeature.remoteUpdate }
        if clipboard, client & StreamFeature.clipboardSync != 0 { value |= StreamFeature.clipboardSync }
        if files, client & StreamFeature.fileTransfer != 0 { value |= StreamFeature.fileTransfer }
        if audio, client & StreamFeature.audio != 0 { value |= StreamFeature.audio }
        return value == 0 ? nil : value
    }
    func start() async throws { try await stream?.startCapture() }
    func stop() async {
        lock.withLock { active = false }
        try? await stream?.stopCapture()
        stream = nil
        window.reset()
    }
    /// While paused nothing is encoded or sent; the first frame after resuming is a keyframe for a fresh decoder.
    func setPaused(_ value: Bool) {
        lock.withLock {
            guard paused != value else { return }
            paused = value
            if !value { keyframeNeeded = true }
        }
        window.reset()
        if !value { queue.async { [weak self] in self?.resendLatest() } }
    }
    /// Live switch between the Mac drawing its pointer into the video and the iPad drawing it locally.
    @MainActor func setShowsCursor(_ show: Bool) async throws {
        guard configuration.showsCursor != show, let stream else { return }
        configuration.showsCursor = show
        try await stream.updateConfiguration(configuration)
    }
    var isPaused: Bool { lock.withLock { paused } }
    /// Applied on the capture queue, in order with the frames being encoded.
    func setBitrate(_ bitrate: Int) { queue.async { [weak self] in self?.encoder.setBitrate(bitrate) } }
    func statistics() -> (captured: Int, frames: Int, skipped: Int, encodeMS: Double, bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        let value = (captured, received, skipped, encodeMilliseconds, encodedBytes)
        captured = 0; received = 0; skipped = 0; encodedBytes = 0
        return value
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { onFailure?(error.localizedDescription) }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: rawStatus) == .complete,
              let image = sampleBuffer.imageBuffer else { return }
        // Kept so a resume can resend the current screen even if it never changes again.
        latestImage = image
        lock.lock(); let enabled = active && !paused; captured += 1; lock.unlock()
        guard enabled else { return }
        let now = monotonicNanos()
        // Measured against every changed frame, including ones the window drops, so only a real pause counts.
        if let lastCapture, now >= lastCapture, now - lastCapture >= StreamStatistics.idleGapNanos { idlePending = true }
        lastCapture = now
        submit(image, now: now, timestamp: sampleBuffer.presentationTimeStamp)
    }
    /// Capture queue only.
    private func submit(_ image: CVPixelBuffer, now: UInt64, timestamp: CMTime) {
        guard let sequence = window.reserve(now: now) else {
            lock.lock(); skipped += 1; lock.unlock(); return
        }
        let afterIdle = markIdleGaps && idlePending
        idlePending = false
        let forceKeyframe: Bool = lock.withLock { let value = keyframeNeeded; keyframeNeeded = false; return value }
        encoder.encode(image, sequence: sequence, captureTime: now,
                       timestamp: timestamp, afterIdle: afterIdle, forceKeyframe: forceKeyframe) { [weak self] result in
            guard let self else { return }
            self.lock.lock(); let enabled = self.active; self.lock.unlock()
            guard enabled else { return }
            switch result {
            case .success(let frame):
                self.lock.lock()
                self.received += 1
                self.encodedBytes += frame.bytes.count
                self.encodeMilliseconds = Double(frame.encodeTime - now) / 1_000_000
                self.lock.unlock()
                self.window.markSent(frame.sequence, bytes: frame.bytes.count)
                self.onFrame?(frame)
            case .failure(let error):
                self.window.acknowledge(sequence)
                self.onFailure?(error.localizedDescription)
            }
        }
    }
    /// Capture queue only: re-encodes the newest screen image as a keyframe.
    private func resendLatest() {
        guard let image = latestImage, lock.withLock({ active && !paused }) else { return }
        submit(image, now: monotonicNanos(), timestamp: CMClockGetTime(CMClockGetHostTimeClock()))
    }
}
