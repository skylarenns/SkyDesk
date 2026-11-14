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
        guard size.width >= 1, size.height >= 1, size.width <= 256, size.height <= 256 else { return }
        // 4× pixels so the iPad can draw it enlarged (its Pointer size setting) and still sharp; smaller if the
        // PNG would not fit the 40 KB message limit.
        var png: Data?
        for scale in [4.0, 3.0, 2.0] {
            if let data = Self.render(cursor, size: size, scale: scale), data.count <= 38_000 { png = data; break }
        }
        guard let png, png != last else { return }
        last = png
        let value = RemoteCursor(png: png, width: size.width / desktop.width, height: size.height / desktop.height,
                                 hotX: cursor.hotSpot.x / size.width, hotY: cursor.hotSpot.y / size.height)
        if value.isValid { onCursor?(value) }
    }
    private static func render(_ cursor: NSCursor, size: CGSize, scale: Double) -> Data? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              true else { return nil }
        // The size must be set BEFORE the context is made: the context takes its coordinate space from the rep at
        // creation, and setting it afterwards drew the arrow into the bottom-left corner only (a quarter-size pointer,
        // offset down from its hot spot: "small and not lining up", 2026-11-13).
        bitmap.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        cursor.image.draw(in: CGRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }
}
