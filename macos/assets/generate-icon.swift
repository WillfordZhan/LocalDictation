import AppKit

// Original voice-to-text artwork. Coordinates run top-to-bottom.
// Fixed seeds preserve the approved particle composition when assets are regenerated.
func ink(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
  NSColor(
    srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
    blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
func fill(_ path: NSBezierPath, _ color: NSColor) {
  color.setFill()
  path.fill()
}
func line(_ path: NSBezierPath, _ color: NSColor, _ width: CGFloat) {
  path.lineWidth = width
  path.lineCapStyle = .round
  path.lineJoinStyle = .round
  color.setStroke()
  path.stroke()
}
func roundRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath
{ NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r) }
func grad(
  _ path: NSBezierPath, _ colors: [NSColor], _ a: NSPoint = NSPoint(x: 180, y: 180),
  _ b: NSPoint = NSPoint(x: 845, y: 840)
) {
  NSGraphicsContext.saveGraphicsState()
  path.addClip()
  NSGradient(colors: colors)!.draw(
    from: a, to: b, options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation])
  NSGraphicsContext.restoreGraphicsState()
}
func tGlyph() -> NSBezierPath {
  let p = roundRect(574, 572, 220, 50, 9)
  p.append(roundRect(657, 592, 54, 202, 9))
  return p
}
let tile = roundRect(80, 76, 864, 864, 202)
func drawCanvas(_ drawing: () -> Void) -> NSBitmapImageRep {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  NSColor.clear.setFill()
  NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
  let flip = NSAffineTransform()
  flip.translateX(by: 0, yBy: 1024)
  flip.scaleX(by: 1, yBy: -1)
  flip.concat()
  NSGraphicsContext.saveGraphicsState()
  let shadow = NSShadow()
  shadow.shadowColor = ink(0x18352F, 0.15)
  shadow.shadowBlurRadius = 24
  shadow.shadowOffset = NSSize(width: 0, height: -14)
  shadow.set()
  fill(tile, ink(0xE8E9E1))
  NSGraphicsContext.restoreGraphicsState()
  NSGraphicsContext.saveGraphicsState()
  tile.addClip()
  drawing()
  NSGraphicsContext.restoreGraphicsState()
  line(tile, ink(0xFFFFFF, 0.22), 1.5)
  NSGraphicsContext.restoreGraphicsState()
  return rep
}

// Deterministic sample field: every section of the waveform contributes points.
struct Sample {
  let x: CGFloat
  let y: CGFloat
  let nx: CGFloat
  let ny: CGFloat
}
var seed: UInt64 = 13011
func rnd() -> CGFloat {
  seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
  return CGFloat((seed >> 33) & 0x7FFF_FFFF) / CGFloat(0x7FFF_FFFF)
}
func gauss() -> CGFloat { sqrt(-2 * log(max(rnd(), 0.00001))) * cos(2 * CGFloat.pi * rnd()) }
func dot(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ c: NSColor) {
  fill(NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), c)
}
func blend(_ a: NSColor, _ b: NSColor, _ f: CGFloat) -> NSColor {
  a.blended(withFraction: min(1, max(0, f)), of: b)!
}
func waveSamples() -> [Sample] {
  let segments: [[CGFloat]] = [
    [218, 370, 245, 370, 241, 310, 264, 310], [264, 310, 290, 310, 297, 438, 324, 438],
    [324, 438, 352, 438, 357, 258, 386, 258], [386, 258, 413, 258, 417, 414, 447, 414],
    [447, 414, 474, 414, 480, 378, 507, 378],
  ]
  var pts: [Sample] = []
  for c in segments {
    for i in 0..<70 {
      let t = CGFloat(i) / 69
      let u = 1 - t
      let x = u * u * u * c[0] + 3 * u * u * t * c[2] + 3 * u * t * t * c[4] + t * t * t * c[6]
      let y = u * u * u * c[1] + 3 * u * u * t * c[3] + 3 * u * t * t * c[5] + t * t * t * c[7]
      let dx = 3 * u * u * (c[2] - c[0]) + 6 * u * t * (c[4] - c[2]) + 3 * t * t * (c[6] - c[4])
      let dy = 3 * u * u * (c[3] - c[1]) + 6 * u * t * (c[5] - c[3]) + 3 * t * t * (c[7] - c[5])
      let n = max(1, sqrt(dx * dx + dy * dy))
      pts.append(Sample(x: x, y: y, nx: -dy / n, ny: dx / n))
    }
  }
  return pts
}
let samples = waveSamples()
func sampleWave() -> Sample { samples[Int(rnd() * CGFloat(samples.count - 1))] }
func diffuseGlow(_ center: NSPoint, _ radius: CGFloat, _ color: NSColor) {
  NSGradient(starting: color, ending: color.withAlphaComponent(0))!.draw(
    fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
}

// Uniform arc-length sampling keeps each grain distinct along peaks and troughs.
func spacedWave(_ distance: CGFloat) -> [Sample] {
  var result: [Sample] = []
  var carry: CGFloat = 0
  var previous = samples[0]
  result.append(previous)
  for p in samples.dropFirst() {
    carry += hypot(p.x - previous.x, p.y - previous.y)
    if carry >= distance {
      result.append(p)
      carry = 0
    }
    previous = p
  }
  return result
}

func smoothStep(_ value: CGFloat) -> CGFloat {
  let t = min(1, max(0, value))
  return t * t * (3 - 2 * t)
}
func strokedWaveMask() -> CGPath {
  let p = CGMutablePath()
  p.move(to: CGPoint(x: 218, y: 370))
  p.addCurve(
    to: CGPoint(x: 264, y: 310), control1: CGPoint(x: 245, y: 370),
    control2: CGPoint(x: 241, y: 310))
  p.addCurve(
    to: CGPoint(x: 324, y: 438), control1: CGPoint(x: 290, y: 310),
    control2: CGPoint(x: 297, y: 438))
  p.addCurve(
    to: CGPoint(x: 386, y: 258), control1: CGPoint(x: 352, y: 438),
    control2: CGPoint(x: 357, y: 258))
  p.addCurve(
    to: CGPoint(x: 447, y: 414), control1: CGPoint(x: 413, y: 258),
    control2: CGPoint(x: 417, y: 414))
  p.addCurve(
    to: CGPoint(x: 507, y: 378), control1: CGPoint(x: 474, y: 414),
    control2: CGPoint(x: 480, y: 378))
  return p.copy(strokingWithWidth: 32, lineCap: .round, lineJoin: .round, miterLimit: 10)
}
func particulateWave(_ color: NSColor, _ ordered: Bool) {
  // Screen-horizontal material change: the left half remains smooth and opaque.
  NSGraphicsContext.saveGraphicsState()
  let ctx = NSGraphicsContext.current!.cgContext
  ctx.addPath(strokedWaveMask())
  ctx.clip()
  let stops: [CGFloat] = [0, 0.14, 0.47, 0.76, 1]
  let colors = [
    color, color.withAlphaComponent(0.98), color.withAlphaComponent(0.68),
    color.withAlphaComponent(0.15), color.withAlphaComponent(0),
  ]
  stops.withUnsafeBufferPointer { positions in
    NSGradient(colors: colors, atLocations: positions.baseAddress, colorSpace: .sRGB)!.draw(
      from: NSPoint(x: 343, y: 350), to: NSPoint(x: 511, y: 350),
      options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation])
  }
  NSGraphicsContext.restoreGraphicsState()
  // Irregular grains replace the material toward the right; no rows of dots on the left.
  let grainTrack = spacedWave(5)
  for _ in 0..<360 {
    let p = grainTrack[Int(rnd() * CGFloat(grainTrack.count - 1))]
    let amount = smoothStep((p.x - 340) / 155)
    if amount < 0.015 || rnd() > 0.14 + 0.86 * amount { continue }
    let normal = (rnd() - 0.5) * (30 + 20 * amount)
    let tangent = gauss() * (ordered ? 2.0 : 4.0) * amount
    let r = 2.5 + rnd() * 1.6 + amount * 0.3
    dot(
      p.x + p.nx * normal - p.ny * tangent, p.y + p.ny * normal + p.nx * tangent, r,
      color.withAlphaComponent(amount * (0.55 + rnd() * 0.35)))
  }
  for _ in 0..<160 {
    let p = sampleWave()
    let amount = smoothStep((p.x - 352) / 150)
    if amount < 0.02 { continue }
    let n = gauss() * 25
    dot(
      p.x + p.nx * n + gauss() * 5, p.y + p.ny * n + gauss() * 5, 2.1 + rnd() * 2.4,
      color.withAlphaComponent(amount * (0.12 + rnd() * 0.28)))
  }
}
func quietTransfer(_ count: Int, _ a: NSColor, _ b: NSColor, _ ordered: Bool) {
  // All parts of the source dissolve. Arriving samples concentrate on the leading cap,
  // leaving the right end and lower stem visually complete rather than dusty.
  for _ in 0..<count {
    let s = sampleWave()
    let t = 0.12 + 0.83 * rnd()
    let e = NSPoint(x: 575 + rnd() * 90, y: 580 + rnd() * 42)
    let spread = (ordered ? 18.0 : 28.0) * sin(t * CGFloat.pi)
    var x = s.x * (1 - t) + e.x * t + gauss() * spread
    var y = s.y * (1 - t) + e.y * t + gauss() * spread
    if ordered && t > 0.7 {
      let f = (t - 0.7) / 0.3
      x = x * (1 - f) + (x / 11).rounded() * 11 * f
      y = y * (1 - f) + (y / 11).rounded() * 11 * f
    }
    let r: CGFloat = ordered ? 2.2 + rnd() * 2.6 : 1.6 + rnd() * 2.1
    let departure = smoothStep((x - 325) / 85)
    dot(x, y, r, blend(a, b, t).withAlphaComponent(departure * (0.17 + rnd() * 0.25)))
  }
}
func assembledType(_ color: NSColor, _ ordered: Bool) {
  // The incoming left edge condenses gradually; the right cap and lower stem are solid.
  grad(
    tGlyph(),
    [
      color.withAlphaComponent(0.02), color.withAlphaComponent(0.30),
      color.withAlphaComponent(0.78), color,
    ], NSPoint(x: 573, y: 590), NSPoint(x: 649, y: 590))
  if ordered {
    for col in 0..<8 {
      for row in 0..<6 {
        let x: CGFloat = 561 + CGFloat(col) * 10.5
        let y: CGFloat = 570 + CGFloat(row) * 10.5
        let fade = CGFloat(col) / 7
        if rnd() < 0.25 + fade * 0.65 {
          dot(
            x + (1 - fade) * (rnd() - 0.5) * 7, y + (1 - fade) * (rnd() - 0.5) * 7,
            2.7 + fade * 0.9, color.withAlphaComponent(0.28 + fade * 0.64))
        }
      }
    }
  } else {
    for _ in 0..<62 {
      let x = 557 + rnd() * 90
      let y = 570 + rnd() * 52
      let fade = min(1, (x - 557) / 90)
      dot(
        x + gauss() * 4, y + gauss() * 4, 2.2 + rnd() * 2.1,
        color.withAlphaComponent(0.24 + fade * 0.48))
    }
  }
  for _ in 0..<13 {
    dot(
      577 + rnd() * 64, 552 + rnd() * 15, 2.0 + rnd() * 1.8,
      color.withAlphaComponent(0.16 + rnd() * 0.22))
  }
  // A short incoming edge on the stem supports the transformation without surrounding it.
  for _ in 0..<8 {
    dot(
      644 + rnd() * 10, 627 + rnd() * 48, 1.8 + rnd() * 1.9,
      color.withAlphaComponent(0.20 + rnd() * 0.18))
  }
}

// The dark artwork keeps its approved sampling and random stream independent of the
// light styles, so regenerating one style cannot move another style's particles.
struct DarkParticleRandom {
  var s: UInt64 = 90117
  mutating func u() -> CGFloat {
    s = s &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return CGFloat((s >> 32) & 0xffff_ffff) / CGFloat(UInt32.max)
  }
  mutating func n() -> CGFloat {
    let a = max(0.00001, u())
    return sqrt(-2 * log(a)) * cos(2 * CGFloat.pi * u())
  }
}
func darkDot(_ p: NSPoint, _ r: CGFloat, _ color: NSColor) {
  fill(NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), color)
}
func darkMix(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
func darkPointMix(_ a: NSPoint, _ b: NSPoint, _ t: CGFloat) -> NSPoint {
  NSPoint(x: darkMix(a.x, b.x, t), y: darkMix(a.y, b.y, t))
}
func darkPigment(_ a: UInt32, _ b: UInt32, _ t: CGFloat, _ alpha: CGFloat) -> NSColor {
  let ar = CGFloat((a >> 16) & 255)
  let ag = CGFloat((a >> 8) & 255)
  let ab = CGFloat(a & 255)
  let br = CGFloat((b >> 16) & 255)
  let bg = CGFloat((b >> 8) & 255)
  let bb = CGFloat(b & 255)
  return NSColor(
    srgbRed: darkMix(ar, br, t) / 255, green: darkMix(ag, bg, t) / 255,
    blue: darkMix(ab, bb, t) / 255, alpha: alpha)
}
func darkCurveSamples() -> [NSPoint] {
  let controls: [(NSPoint, NSPoint, NSPoint, NSPoint)] = [
    (.init(x: 218, y: 370), .init(x: 245, y: 370), .init(x: 241, y: 310), .init(x: 264, y: 310)),
    (.init(x: 264, y: 310), .init(x: 290, y: 310), .init(x: 297, y: 438), .init(x: 324, y: 438)),
    (.init(x: 324, y: 438), .init(x: 352, y: 438), .init(x: 357, y: 258), .init(x: 386, y: 258)),
    (.init(x: 386, y: 258), .init(x: 413, y: 258), .init(x: 417, y: 414), .init(x: 447, y: 414)),
    (.init(x: 447, y: 414), .init(x: 474, y: 414), .init(x: 480, y: 378), .init(x: 507, y: 378)),
  ]
  var out: [NSPoint] = []
  for (a, b, c, d) in controls {
    for i in 0..<80 {
      let t = CGFloat(i) / 80
      let v = 1 - t
      out.append(
        NSPoint(
          x: v * v * v * a.x + 3 * v * v * t * b.x + 3 * v * t * t * c.x + t * t * t * d.x,
          y: v * v * v * a.y + 3 * v * v * t * b.y + 3 * v * t * t * c.y + t * t * t * d.y))
    }
  }
  return out
}
// Uniform arclength keeps the grain size and spacing independent of Bézier speed.
func darkSignalTrack(_ spacing: CGFloat) -> [(NSPoint, NSPoint)] {
  let raw = darkCurveSamples()
  var out: [(NSPoint, NSPoint)] = []
  var carried: CGFloat = 0
  for i in 1..<raw.count {
    let a = raw[i - 1]
    let b = raw[i]
    let dx = b.x - a.x
    let dy = b.y - a.y
    let len = hypot(dx, dy)
    if len < 0.0001 { continue }
    var remaining = len
    var start = a
    while carried + remaining >= spacing {
      let distance = spacing - carried
      let ratio = distance / remaining
      let q = darkPointMix(start, b, ratio)
      out.append((q, NSPoint(x: -dy / len, y: dx / len)))
      start = q
      remaining -= distance
      carried = 0
    }
    carried += remaining
  }
  return out
}
func darkReceivingPoint(_ u: CGFloat) -> NSPoint {
  if u < 0.77 { return NSPoint(x: 574 + u / 0.77 * 100, y: 576) }
  return NSPoint(x: 659, y: 620 + (u - 0.77) / 0.23 * 42)
}
func darkContinuousToGrain(_ color: UInt32) {
  let p = CGMutablePath()
  p.move(to: CGPoint(x: 218, y: 370))
  p.addCurve(
    to: CGPoint(x: 264, y: 310), control1: CGPoint(x: 245, y: 370),
    control2: CGPoint(x: 241, y: 310))
  p.addCurve(
    to: CGPoint(x: 324, y: 438), control1: CGPoint(x: 290, y: 310),
    control2: CGPoint(x: 297, y: 438))
  p.addCurve(
    to: CGPoint(x: 386, y: 258), control1: CGPoint(x: 352, y: 438),
    control2: CGPoint(x: 357, y: 258))
  p.addCurve(
    to: CGPoint(x: 447, y: 414), control1: CGPoint(x: 413, y: 258),
    control2: CGPoint(x: 417, y: 414))
  p.addCurve(
    to: CGPoint(x: 507, y: 378), control1: CGPoint(x: 474, y: 414),
    control2: CGPoint(x: 480, y: 378))
  NSGraphicsContext.saveGraphicsState()
  let c = NSGraphicsContext.current!.cgContext
  c.addPath(p)
  c.setLineWidth(32)
  c.setLineCap(.round)
  c.setLineJoin(.round)
  c.replacePathWithStrokedPath()
  c.clip()
  let colors = (0...40).map { i -> NSColor in
    let x = 218 + CGFloat(i) / 40 * 304
    let t = min(1, max(0, (x - 350) / 157))
    return ink(color, pow(1 - t, 1.1))
  }
  NSGradient(colors: colors)!.draw(
    from: NSPoint(x: 218, y: 350), to: NSPoint(x: 522, y: 350),
    options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation])
  NSGraphicsContext.restoreGraphicsState()
}
func darkSolidifyingType(_ color: UInt32) {
  let colors = (0...32).map { i -> NSColor in
    let t = CGFloat(i) / 32
    let a = 0.12 + 0.88 * (1 - pow(1 - t, 2))
    return ink(color, a)
  }
  NSGraphicsContext.saveGraphicsState()
  tGlyph().addClip()
  NSGradient(colors: colors)!.draw(
    from: NSPoint(x: 574, y: 600), to: NSPoint(x: 652, y: 600),
    options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation])
  NSGraphicsContext.restoreGraphicsState()
}

func drawDarkGlowArtwork() {

  grad(
    tile, [ink(0x153C37), ink(0x102C2B), ink(0x16292D)], NSPoint(x: 110, y: 130),
    NSPoint(x: 860, y: 900))
  let wave = darkCurveSamples().filter { $0.x >= 354 }
  var rng = DarkParticleRandom(s: 66201)
  // The broad middle field is retained, while the intact left half emits no stray grains.
  for _ in 0..<220 {
    let w = wave[min(wave.count - 1, Int(rng.u() * CGFloat(wave.count)))]
    let t = rng.u() * 0.95
    let goal = darkReceivingPoint(rng.u())
    var p = darkPointMix(w, goal, t)
    let spread = 15 + 31 * sin(CGFloat.pi * t)
    p.x += rng.n() * spread
    p.y += rng.n() * spread * 0.8
    if p.x > 355 && p.x < 687 && p.y < 672 {
      darkDot(p, 1.8 + rng.u() * 2.2, darkPigment(0xB3DAC0, 0xCABADA, t, 0.15 + rng.u() * 0.28))
    }
  }
  for _ in 0..<115 {
    let w = wave[min(wave.count - 1, Int(rng.u() * CGFloat(wave.count)))]
    let k = min(1, max(0, (w.x - 350) / 157))
    let sd = 12 + k * 17
    let p = NSPoint(x: w.x + rng.n() * sd, y: w.y + rng.n() * sd)
    if p.x > 354 { darkDot(p, 1.6 + rng.u() * 2.3, ink(0xC1DCBB, (0.16 + rng.u() * 0.25) * k)) }
  }
  darkContinuousToGrain(0xE1EFD7)
  // Grain coverage rises across screen x; the left curve stays a clean single stroke.
  let track = darkSignalTrack(11.3)
  for (i, (p, n)) in track.enumerated() {
    let k = min(1, max(0, (p.x - 350) / 157))
    if k > 0 {
      for lane in -1...1 {
        if rng.u() < 0.18 + 0.82 * k {
          let offset = CGFloat(lane) * 10.7 + rng.n() * 1.2
          let along = lane == 0 ? CGFloat(0) : CGFloat(i % 2 == 0 ? 2.8 : -2.8)
          let q = NSPoint(
            x: p.x + n.x * offset - n.y * along + rng.n() * 0.8,
            y: p.y + n.y * offset + n.x * along + rng.n() * 0.8)
          darkDot(q, 2.6 + 2.3 * k + rng.u() * 0.6, ink(0xE1EFD7, 0.40 + 0.60 * k))
        }
      }
    }
  }
  darkSolidifyingType(0xE7DFE8)
  // Grain-to-mass overlap replaces punched notches, so the receiving edge is soft.
  for _ in 0..<76 {
    let x = 568 + rng.u() * 69
    let p = NSPoint(x: x, y: 574 + rng.u() * 45)
    let k = 1 - min(1, max(0, (x - 568) / 69))
    darkDot(p, 1.9 + 1.9 * k, ink(0xE1D8E6, 0.28 + 0.62 * k))
  }
  for _ in 0..<30 {
    let p = NSPoint(x: 556 + rng.u() * 63, y: 552 + rng.u() * 23)
    darkDot(p, 1.7 + rng.u() * 1.5, ink(0xD5CDD9, 0.22 + rng.u() * 0.34))
  }
  for _ in 0..<11 {
    let p = NSPoint(x: 649 + rng.u() * 8, y: 624 + rng.u() * 37)
    darkDot(p, 1.6 + rng.u() * 1.6, ink(0xD9D0DE, 0.28 + rng.u() * 0.30))
  }

}

enum IconStyle: String, CaseIterable {
  case dotFormation = "AppIconDotFormation"
  case softMist = "AppIconSoftMist"
  case darkGlow = "AppIconDarkGlow"
}

func drawMaster(_ style: IconStyle) -> NSBitmapImageRep {
  drawCanvas {
    switch style {
    case .dotFormation:
      seed = 63142
      grad(tile, [ink(0xE9EFE4), ink(0xEEECE9), ink(0xDFD9E5)])
      quietTransfer(235, ink(0x3D8069), ink(0x7E5F95), true)
      particulateWave(ink(0x245E4D), true)
      assembledType(ink(0x6B537F), true)
    case .softMist:
      seed = 85422
      grad(tile, [ink(0xB7CDC0), ink(0xDDE2D6), ink(0xC4B4D4)])
      diffuseGlow(NSPoint(x: 350, y: 355), 310, ink(0xF5F7DA, 0.55))
      diffuseGlow(NSPoint(x: 590, y: 555), 250, ink(0xFFFFFF, 0.24))
      // Soft overlapping clouds distinguish this style from the discrete lattice.
      diffuseGlow(NSPoint(x: 488, y: 453), 143, ink(0x4C8B76, 0.21))
      diffuseGlow(NSPoint(x: 551, y: 519), 116, ink(0x836598, 0.19))
      quietTransfer(168, ink(0x4F8C76), ink(0x7D6293), false)
      particulateWave(ink(0x326A54), false)
      assembledType(ink(0x674E7D), false)
    case .darkGlow:
      drawDarkGlowArtwork()
    }
  }
}

func writePNG(_ master: NSBitmapImageRep, size: Int, to url: URL) throws {
  if size == 1024 {
    try master.representation(using: .png, properties: [:])!.write(to: url, options: .atomic)
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
  try output.representation(using: .png, properties: [:])!.write(to: url, options: .atomic)
}

func writeICNS(_ master: NSBitmapImageRep, to destination: URL) throws {
  let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let iconset = temporary.appendingPathComponent("AppIcon.iconset")
  try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: temporary) }
  // Standard 1x/2x representations cover 16, 32, 64, 128, 256, 512 and 1024 physical pixels.
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
  guard process.terminationStatus == 0 else {
    throw NSError(
      domain: "LocalDictation.IconGenerator", code: Int(process.terminationStatus),
      userInfo: [
        NSLocalizedDescriptionKey: "iconutil failed to create \(destination.lastPathComponent)"
      ])
  }
}

func writeAll(to directory: URL) throws {
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  for style in IconStyle.allCases {
    let master = drawMaster(style)
    try writePNG(master, size: 1024, to: directory.appendingPathComponent(style.rawValue + ".png"))
    try writeICNS(master, to: directory.appendingPathComponent(style.rawValue + ".icns"))
  }
  // The static fallback is the approved light icon, C, copied without another rendering pass.
  for ext in ["png", "icns"] {
    let named = directory.appendingPathComponent(IconStyle.softMist.rawValue + "." + ext)
    try Data(contentsOf: named).write(
      to: directory.appendingPathComponent("AppIcon." + ext), options: .atomic)
  }
}

func usage() -> Never {
  fputs("Usage: swift generate-icon.swift --all [output-directory]\n", stderr)
  fputs(
    "       swift generate-icon.swift output.png|output.icns  (default: soft mist)\n", stderr)
  exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
  if arguments.first == "--all", arguments.count <= 2 {
    let directory =
      arguments.count == 2
      ? URL(fileURLWithPath: arguments[1], isDirectory: true)
      : URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    try writeAll(to: directory)
  } else if arguments.count == 1 {
    // Keep the original single-file invocation for existing asset workflows.
    let destination = URL(fileURLWithPath: arguments[0])
    switch destination.pathExtension.lowercased() {
    case "png": try writePNG(drawMaster(.softMist), size: 1024, to: destination)
    case "icns": try writeICNS(drawMaster(.softMist), to: destination)
    default: usage()
    }
  } else {
    usage()
  }
} catch {
  fputs("Icon generation failed: \(error.localizedDescription)\n", stderr)
  exit(1)
}
