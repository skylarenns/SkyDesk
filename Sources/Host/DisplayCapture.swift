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
    private var received = 0
    private var captured = 0
    private var skipped = 0
    private var encodeMilliseconds: Double = 0
    private var encodedBytes = 0
    private let markIdleGaps: Bool
    private var lastCapture: UInt64?   // capture queue only
    private var idlePending = true     // capture queue only
    var onFrame: ((VideoFrame) -> Void)?
    var onFailure: ((String) -> Void)?
    let info: StreamInfo

    init(display: SCDisplay, longestEdge: Int, fps: Int, bitrate: Int, inputEnabled: Bool,
         lowLatencyRateControl: Bool, nativeDesktop: Bool = false, clientFeatures: Int = 0) throws {
        window = .streaming(fps: fps)
        markIdleGaps = clientFeatures & StreamFeature.idleGapFlags != 0
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        let native = CGSize(width: mode?.pixelWidth ?? display.width, height: mode?.pixelHeight ?? display.height)
        let size = DesktopGeometry.pixelSize(native: native, longestEdge: longestEdge)
        info = StreamInfo(width: Int(size.width), height: Int(size.height), fps: fps, bitrate: bitrate,
                          displayName: nativeDesktop ? "iPad Retina desktop" : "Display \(display.displayID)",
                          inputEnabled: inputEnabled, textInputEnabled: inputEnabled,
                          displayBlankingSupported: nativeDesktop && inputEnabled,
                          features: Self.features(client: clientFeatures, inputEnabled: inputEnabled))
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
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
    }
    private static func features(client: Int, inputEnabled: Bool) -> Int? {
        var value = client & StreamFeature.idleGapFlags != 0 ? StreamFeature.idleGapFlags | StreamFeature.clientStatsLog : 0
        // Without remote input the iPad never moves the pointer, so the video must keep showing it.
        if inputEnabled, client & StreamFeature.localCursor != 0 { value |= StreamFeature.localCursor }
        return value == 0 ? nil : value
    }
    func start() async throws { try await stream?.startCapture() }
    func stop() async {
        lock.withLock { active = false }
        try? await stream?.stopCapture()
        stream = nil
        window.reset()
    }
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
        lock.lock(); let enabled = active; captured += 1; lock.unlock()
        guard enabled else { return }
        let now = monotonicNanos()
        // Measured against every changed frame, including ones the window drops, so only a real pause counts.
        if let lastCapture, now >= lastCapture, now - lastCapture >= StreamStatistics.idleGapNanos { idlePending = true }
        lastCapture = now
        guard let sequence = window.reserve(now: now) else {
            lock.lock(); skipped += 1; lock.unlock(); return
        }
        let afterIdle = markIdleGaps && idlePending
        idlePending = false
        encoder.encode(image, sequence: sequence, captureTime: now,
                       timestamp: sampleBuffer.presentationTimeStamp, afterIdle: afterIdle) { [weak self] result in
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
                self.onFrame?(frame)
            case .failure(let error):
                self.window.acknowledge(sequence)
                self.onFailure?(error.localizedDescription)
            }
        }
    }
}
