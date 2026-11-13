import AppKit

/// Reports the Mac's current pointer image so the iPad can draw the pointer itself, with no stream delay.
@MainActor
final class CursorMonitor {
    var onCursor: ((RemoteCursor) -> Void)?
    private var timer: Timer?
    private var last: Data?
    private let desktop: CGSize
    /// `desktop` is the streamed display's size in points; the cursor is described as a fraction of it.
    init(desktop: CGSize) { self.desktop = desktop }
    func start() {
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
        poll()
    }
    func stop() { timer?.invalidate(); timer = nil }
    private func poll() {
        guard desktop.width > 0, desktop.height > 0, let cursor = NSCursor.currentSystem else { return }
        let size = cursor.image.size
        guard size.width >= 1, size.height >= 1, size.width <= 256, size.height <= 256,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        cursor.image.draw(in: CGRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]), png != last else { return }
        last = png
        let value = RemoteCursor(png: png, width: size.width / desktop.width, height: size.height / desktop.height,
                                 hotX: cursor.hotSpot.x / size.width, hotY: cursor.hotSpot.y / size.height)
        if value.isValid { onCursor?(value) }
    }
}
