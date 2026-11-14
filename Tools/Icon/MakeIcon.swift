// Renders the SkyDesk "SD" app icon: black background, white S, aqua D.
// Usage: swift Tools/Icon/MakeIcon.swift <output.png> <pixels> <ios|mac>
import AppKit

let args = CommandLine.arguments
let output = URL(fileURLWithPath: args[1])
let size = CGFloat(Double(args[2])!)
let mac = args[3] == "mac"
let aqua = NSColor(srgbRed: 0, green: 0.9, blue: 0.85, alpha: 1)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let canvas = CGRect(x: 0, y: 0, width: size, height: size)
// iOS masks the corners itself and wants an opaque square; macOS icons carry their own rounded tile with margins.
let tile = mac ? canvas.insetBy(dx: size * 100 / 1024, dy: size * 100 / 1024) : canvas
if mac {
    NSColor.clear.setFill(); canvas.fill()
    let shadow = NSShadow(); shadow.shadowBlurRadius = size * 0.02; shadow.shadowOffset = NSSize(width: 0, height: -size * 0.01)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35); shadow.set()
    NSColor.black.setFill()
    NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225).fill()
    NSShadow().set()
} else {
    NSColor.black.setFill(); canvas.fill()
}
let fontSize = tile.width * 0.52
var font = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
if let rounded = font.fontDescriptor.withDesign(.rounded) { font = NSFont(descriptor: rounded, size: fontSize) ?? font }
let text = NSMutableAttributedString()
text.append(NSAttributedString(string: "S", attributes: [.font: font, .foregroundColor: NSColor.white, .kern: -fontSize * 0.02]))
text.append(NSAttributedString(string: "D", attributes: [.font: font, .foregroundColor: aqua]))
// Centre the ink (glyph outlines), not the line box, so the letters sit optically in the middle.
let line = CTLineCreateWithAttributedString(text)
let context = NSGraphicsContext.current!.cgContext
let ink = CTLineGetImageBounds(line, context)
context.textPosition = CGPoint(x: tile.midX - ink.midX, y: tile.midY - ink.midY)
CTLineDraw(line, context)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: output)
