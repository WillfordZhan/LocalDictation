import AppKit

// Original “Voice to Text” mark. Audio, a conversion arrow, and a text field
// remain distinct at Dock size; all glyphs use geometry rather than fonts.
guard CommandLine.arguments.count == 2 else {
  fputs("Usage: swift generate-icon.swift output.png|output.icns\n", stderr)
  exit(1)
}
let destination = URL(fileURLWithPath: CommandLine.arguments[1])

func drawMaster() -> NSBitmapImageRep {
  let size = 1024
  let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
  func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
  }
  NSColor.clear.setFill()
  NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
  let tile = NSBezierPath(
    roundedRect: NSRect(x: 80, y: 84, width: 864, height: 864), xRadius: 202, yRadius: 202)
  NSGraphicsContext.saveGraphicsState()
  let shadow = NSShadow()
  shadow.shadowColor = color(8, 24, 25, 0.25)
  shadow.shadowBlurRadius = 24
  shadow.shadowOffset = NSSize(width: 0, height: -15)
  shadow.set()
  color(21, 40, 42).setFill()
  tile.fill()
  NSGraphicsContext.restoreGraphicsState()
  NSGradient(starting: color(45, 69, 71), ending: color(20, 36, 39))!.draw(in: tile, angle: -70)
  tile.lineWidth = 2
  color(230, 245, 235, 0.35).setStroke()
  tile.stroke()
  let ivory = color(250, 245, 224)
  let apricot = color(248, 168, 100)
  func capsule(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ fill: NSColor) {
    fill.setFill()
    NSBezierPath(
      roundedRect: NSRect(x: x, y: y, width: width, height: height),
      xRadius: min(width, height) / 2, yRadius: min(width, height) / 2
    ).fill()
  }
  // Unequal heights communicate audio at a glance; the centered quiet ends keep
  // enough air around the short conversion connector.
  capsule(207, 441, 45, 154, ivory)
  capsule(285, 352, 45, 332, ivory)
  capsule(363, 401, 45, 234, ivory)
  // A compact arrow uses a single filled contour rather than thin strokes.
  let arrow = NSBezierPath()
  arrow.move(to: NSPoint(x: 437, y: 535))
  arrow.line(to: NSPoint(x: 477, y: 535))
  arrow.line(to: NSPoint(x: 477, y: 562))
  arrow.line(to: NSPoint(x: 527, y: 518))
  arrow.line(to: NSPoint(x: 477, y: 474))
  arrow.line(to: NSPoint(x: 477, y: 501))
  arrow.line(to: NSPoint(x: 437, y: 501))
  arrow.close()
  apricot.setFill()
  arrow.fill()
  // Outlined text-entry frame. The T is a geometric glyph, with a substantial
  // cap and stem so it remains visible when the complete icon is downsampled.
  let field = NSBezierPath(
    roundedRect: NSRect(x: 569, y: 388, width: 266, height: 260), xRadius: 45, yRadius: 45)
  field.lineWidth = 34
  ivory.setStroke()
  field.stroke()
  capsule(637, 559, 130, 32, ivory)
  capsule(685, 445, 34, 138, ivory)
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
