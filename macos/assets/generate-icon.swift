import AppKit

let size = 1024
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: size, height: size).fill()
let tile = NSBezierPath(roundedRect: NSRect(x: 80, y: 86, width: 864, height: 864), xRadius: 206, yRadius: 206)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
shadow.shadowBlurRadius = 32
shadow.shadowOffset = NSSize(width: 0, height: -18)
shadow.set()
NSColor(calibratedRed: 0.1, green: 0.29, blue: 0.86, alpha: 1).setFill()
tile.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: NSColor(calibratedRed: 0.24, green: 0.52, blue: 1, alpha: 1), ending: NSColor(calibratedRed: 0.12, green: 0.27, blue: 0.88, alpha: 1))!.draw(in: tile, angle: -70)
let inner = NSBezierPath(roundedRect: NSRect(x: 230, y: 288, width: 564, height: 456), xRadius: 160, yRadius: 160)
NSColor.white.withAlphaComponent(0.14).setFill()
inner.fill()
let heights: [CGFloat] = [116, 242, 350, 242, 116]
for (i, height) in heights.enumerated() {
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: 318 + CGFloat(i) * 84, y: 517 - height / 2, width: 54, height: height), xRadius: 27, yRadius: 27).fill()
}
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
