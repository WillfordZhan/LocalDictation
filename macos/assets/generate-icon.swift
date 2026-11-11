import AppKit

// Original “Echo” mark. One continuous contour joins listening and writing.
// Geometry stays editable; all macOS sizes are derived from the same master.
guard CommandLine.arguments.count == 2 else {
  fputs("Usage: swift generate-icon.swift output.png|output.icns\n", stderr)
  exit(1)
}
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
  NSColor(
    srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
    blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
func stroke(_ path: NSBezierPath, color c: NSColor, width: CGFloat) {
  path.lineWidth = width
  path.lineCapStyle = .round
  path.lineJoinStyle = .round
  c.setStroke()
  path.stroke()
}
func drawMaster() -> NSBitmapImageRep {
  let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
  let flip = NSAffineTransform()
  flip.translateX(by: 0, yBy: 1024)
  flip.scaleX(by: 1, yBy: -1)
  flip.concat()
  let tile = NSBezierPath(
    roundedRect: NSRect(x: 80, y: 76, width: 864, height: 864), xRadius: 200, yRadius: 200)
  NSGraphicsContext.saveGraphicsState()
  let tileShadow = NSShadow()
  tileShadow.shadowColor = color(0x142020, 0.19)
  tileShadow.shadowBlurRadius = 22
  tileShadow.shadowOffset = NSSize(width: 0, height: -14)
  tileShadow.set()
  color(0x17282B).setFill()
  tile.fill()
  NSGraphicsContext.restoreGraphicsState()
  NSGradient(starting: color(0x2F4548), ending: color(0x152327))!.draw(in: tile, angle: 90)
  tile.lineWidth = 2
  color(0xFFFFFF, 0.35).setStroke()
  tile.stroke()
  let mark = NSBezierPath()
  // A continuous handwritten l/d ligature: speech flowing into a written mark.
  mark.move(to: NSPoint(x: 326, y: 304))
  mark.line(to: NSPoint(x: 326, y: 555))
  mark.curve(
    to: NSPoint(x: 565, y: 705), controlPoint1: NSPoint(x: 326, y: 691),
    controlPoint2: NSPoint(x: 452, y: 756))
  mark.curve(
    to: NSPoint(x: 700, y: 488), controlPoint1: NSPoint(x: 660, y: 663),
    controlPoint2: NSPoint(x: 700, y: 583))
  mark.curve(
    to: NSPoint(x: 570, y: 341), controlPoint1: NSPoint(x: 700, y: 392),
    controlPoint2: NSPoint(x: 644, y: 341))
  mark.curve(
    to: NSPoint(x: 470, y: 462), controlPoint1: NSPoint(x: 498, y: 341),
    controlPoint2: NSPoint(x: 470, y: 397))
  mark.line(to: NSPoint(x: 470, y: 537))
  NSGraphicsContext.saveGraphicsState()
  let markShadow = NSShadow()
  markShadow.shadowColor = color(0x000000, 0.28)
  markShadow.shadowBlurRadius = 16
  markShadow.shadowOffset = NSSize(width: 0, height: -8)
  markShadow.set()
  stroke(mark, color: color(0xF7F2DF), width: 91)
  NSGraphicsContext.restoreGraphicsState()
  color(0xF2A66A).setFill()
  NSBezierPath(ovalIn: NSRect(x: 696, y: 263, width: 74, height: 74)).fill()
  NSGraphicsContext.restoreGraphicsState()
  return bitmap
}

func writePNG(_ master: NSBitmapImageRep, size: Int, to url: URL) throws {
  if size == 1024 {
    try master.representation(using: .png, properties: [:])!.write(to: url)
    return
  }
  let output = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: output)
  NSGraphicsContext.current?.imageInterpolation = .high
  let image = NSImage(size: NSSize(width: 1024, height: 1024))
  image.addRepresentation(master)
  image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
  NSGraphicsContext.restoreGraphicsState()
  try output.representation(using: .png, properties: [:])!.write(to: url)
}

let master = drawMaster()
switch destination.pathExtension.lowercased() {
case "png":
  try writePNG(master, size: 1024, to: destination)
case "icns":
  // Supply every macOS representation, including low-density 16px Finder icons.
  let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let iconset = temporary.appendingPathComponent("AppIcon.iconset")
  try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: temporary) }
  for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
      let suffix = scale == 2 ? "@2x" : ""
      try writePNG(
        master, size: points * scale,
        to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
  }
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
  process.arguments = ["-c", "icns", "-o", destination.path, iconset.path]
  try process.run()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
default:
  fputs("Output must use .png or .icns\n", stderr)
  exit(1)
}
