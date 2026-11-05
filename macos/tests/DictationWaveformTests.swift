import AppKit

@main
enum DictationWaveformTests {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }

    static func field<T>(_ value: Any, _ name: String, _: T.Type) -> T? {
        Mirror(reflecting: value).children.first { $0.label == name }?.value as? T
    }

    static func main() throws {
        func measured(_ db: Double) -> Double { DictationWaveformEnvelope.levelFromDecibels(db) }
        func level(_ averageDB: Double, _ peakDB: Double) -> Double {
            DictationWaveformEnvelope.inputLevel(average: measured(averageDB), peak: measured(peakDB))
        }
        let decibels: [Double] = [-60, -55, -50, -40, -30, -20, -10, -3, 0]
        let mapped = decibels.map(measured)
        require(mapped[0] == 0 && mapped[1] == 0, "Microphone noise floor must remain still")
        require(zip(mapped.dropFirst(2), mapped.dropFirst()).allSatisfy { $0 > $1 }, "dB transfer must retain quiet-to-loud ordering")
        require(measured(-20) < 0.30 && measured(-10) < 0.55 && measured(0) == 1,
                "Ordinary speech must leave headroom for real peaks")
        require(measured(.nan) == 0 && measured(.infinity) == 0 && measured(-.infinity) == 0,
                "Non-finite microphone dB values must be silent")

        func height(_ db: Double) -> Double { DictationWaveformEnvelope.displayHeight(for: level(db, db + 8)) }
        require(height(-60) == 2 && height(-50) < 2.3 && height(-40) < 4.2,
                "Display gain raised silence or low microphone noise into speech-sized bars")
        require(height(-30) >= 9 && height(-24) >= 12 && height(-18) >= 15,
                "Normal speech still occupies only the lowest few pixels")
        require(height(-12) >= 16.5 && height(-6) > height(-12) && height(-6) < 18,
                "Strong speech must approach the top while retaining a soft, distinguishable ceiling")
        require(DictationWaveformEnvelope.displayHeight(for: .nan) == 2 && DictationWaveformEnvelope.displayHeight(for: .infinity) == 2,
                "Invalid display levels must not draw a full-height pulse")
        let displayRamp = (0...1000).map { DictationWaveformEnvelope.displayHeight(for: Double($0) / 1000) }
        require(zip(displayRamp, displayRamp.dropFirst()).allSatisfy { $0 <= $1 } && displayRamp.allSatisfy { (2...18).contains($0) },
                "The display calibration must stay monotonic and inside the waveform canvas")
        var amplitudeMetrics: [[String: Double]] = []
        for (db, minimumP95, maximumP95) in [(-50.0, 2.0, 2.3), (-40.0, 2.5, 4.2), (-30.0, 8.0, 10.5),
                                             (-24.0, 10.5, 13.0), (-18.0, 14.0, 16.0), (-12.0, 16.0, 17.5), (-6.0, 17.0, 17.8)] {
            var probe = DictationWaveformEnvelope(seed: 53)
            var oldMaxima: [Double] = [], newMaxima: [Double] = []
            for _ in 0..<240 {
                probe.advance(average: measured(db), peak: measured(db + 8), seconds: 1.0 / 60)
                oldMaxima.append(probe.columns.map { 2 + 16 * $0 }.max()!)
                newMaxima.append(probe.columns.map { DictationWaveformEnvelope.displayHeight(for: $0) }.max()!)
            }
            oldMaxima.sort(); newMaxima.sort()
            let p95 = newMaxima[Int(Double(newMaxima.count - 1) * 0.95)]
            require(p95 >= minimumP95 && p95 <= maximumP95,
                    "Rendered peak height at \(db) dB is outside its calibrated speech range: \(p95)")
            amplitudeMetrics.append(["averageDB": db, "peakDB": db + 8, "oldP50": oldMaxima[120], "newP50": newMaxima[120],
                                     "oldP95": oldMaxima[227], "newP95": p95])
        }
        var variable = DictationWaveformEnvelope(seed: 54), nearCeiling = 0
        for frame in 0..<1200 {
            let db = -25 + 11 * sin(Double(frame) / 23)
            variable.advance(average: measured(db), peak: measured(db + 8), seconds: 1.0 / 60)
            if variable.columns.contains(where: { DictationWaveformEnvelope.displayHeight(for: $0) >= 17.8 }) { nearCeiling += 1 }
        }
        require(nearCeiling < 12, "Ordinary varying speech became a permanently full waveform")

        var envelope = DictationWaveformEnvelope(seed: 53)
        for _ in 0..<120 { envelope.advance(average: 0, peak: 0, seconds: 1.0 / 60) }
        require(envelope.columns.allSatisfy { $0 == 0 }, "Silent input invented microphone activity")
        let target = level(-14, -6)
        envelope.advance(average: measured(-14), peak: measured(-6), seconds: 1.0 / 120)
        require((envelope.columns.max() ?? 0) >= target * 0.80,
                "First audible frame waited for a delayed pulse instead of responding immediately")
        require(envelope.columns.count == 10 && ((envelope.columns[4] > 0) != (envelope.columns[5] > 0)),
                "Pulse onset must choose one center; the second center arrives independently")
        let onset = envelope.columns
        for _ in 0..<6 { envelope.advance(average: measured(-14), peak: measured(-6), seconds: 1.0 / 120) }
        require(envelope.columns.enumerated().contains { $0.offset < 3 && $0.element > 0 }, "Measured pulse never travelled to a shoulder")
        require(onset[0] == 0 && onset[9] == 0, "Outer columns anticipated the pulse")
        var shapes: [[Double]] = []
        for _ in 0..<120 {
            envelope.advance(average: measured(-14), peak: measured(-6), seconds: 1.0 / 120)
            let maximum = envelope.columns.max() ?? 1
            shapes.append(envelope.columns.map { $0 / max(0.0001, maximum) })
        }
        let shapeDifference = shapes.dropFirst().map { zip($0, shapes[0]).map { abs($0 - $1) }.max() ?? 0 }.max() ?? 0
        require(shapeDifference > 0.20, "Constant audible input remained a fixed shape times one scalar")
        require(shapes.contains { abs($0[4] - $0[5]) > 0.10 }, "The center pair remained locked together")
        require(shapes.contains { zip($0, $0.reversed()).contains { abs($0 - $1) > 0.10 } }, "Left and right pulses were mirrored")
        let quieter = level(-35, -29)
        envelope.advance(average: measured(-35), peak: measured(-29), seconds: 1.0 / 120)
        require(envelope.columns.allSatisfy { $0 <= quieter * 1.10 + 1e-9 }, "Previous loud pulses survived above the softened voice")
        for _ in 0..<10 {
            envelope.advance(average: measured(-35), peak: measured(-29), seconds: 1.0 / 120)
            require(envelope.columns.allSatisfy { $0 <= quieter * 1.10 + 1e-9 }, "Queued loud pulse rebounded after the speaker became quiet")
        }
        envelope.advance(average: measured(-14), peak: measured(-6), seconds: 1.0 / 120)
        require((envelope.columns.max() ?? 0) >= target * 0.80, "A stronger syllable waited for random pulse admission")
        var previous = envelope.columns
        for _ in 0..<12 {
            envelope.advance(average: 0, peak: 0, seconds: 1.0 / 120)
            require(zip(envelope.columns, previous).allSatisfy { $0 <= $1 + 1e-9 }, "Pending pulse revived a silent microphone")
            previous = envelope.columns
        }
        require(envelope.columns.allSatisfy { $0 == 0 }, "Silence release exceeded 100 ms")
        for _ in 0..<120 { envelope.advance(average: 0, peak: 0, seconds: 1.0 / 120) }
        require(envelope.columns.allSatisfy { $0 == 0 }, "Silence generated a new random pulse")
        envelope.advance(average: measured(-26), peak: measured(-18), seconds: 0, reduceMotion: true)
        let still = envelope.columns
        envelope.advance(average: measured(-26), peak: measured(-18), seconds: 10, reduceMotion: true)
        require(envelope.columns == still && still[4] == level(-26, -18), "Reduced motion retained propagation or lost current amplitude")
        envelope.advance(average: .nan, peak: .infinity, seconds: 1, reduceMotion: true)
        require(envelope.columns.allSatisfy { $0 == 0 }, "Non-finite microphone input must be silent")

        // Both clocks replay the same measured sample intervals and PRNG seed.
        // Display callbacks must neither speed up decay nor draw extra randomness.
        var sixty = DictationWaveformEnvelope(seed: 53), oneTwenty = DictationWaveformEnvelope(seed: 53)
        var largestRefreshDifference = 0.0
        for frame in 0..<180 {
            let input = frame < 12 || (30..<42).contains(frame) ? measured(-18) : frame > 90 ? measured(-25) : 0.0
            sixty.advance(average: input, peak: input, seconds: 1.0 / 60)
            for _ in 0..<2 { oneTwenty.advance(average: input, peak: input, seconds: 1.0 / 120) }
            let difference = zip(sixty.columns, oneTwenty.columns).map { abs($0 - $1) }.max() ?? 0
            largestRefreshDifference = max(largestRefreshDifference, difference)
        }
        require(largestRefreshDifference < 1e-9, "Pulse propagation changed with screen refresh rate")
        var repeatA = DictationWaveformEnvelope(seed: 53), repeatB = DictationWaveformEnvelope(seed: 53)
        var otherSeed = DictationWaveformEnvelope(seed: 54), seedDifference = 0.0
        for index in 0..<180 {
            let db = [-44.0, -31, -19, -25, -39, -55][index % 6]
            repeatA.advance(average: measured(db), peak: measured(db + 4), seconds: 1.0 / 120)
            repeatB.advance(average: measured(db), peak: measured(db + 4), seconds: 1.0 / 120)
            otherSeed.advance(average: measured(db), peak: measured(db + 4), seconds: 1.0 / 120)
            require(repeatA.columns == repeatB.columns, "The same seed and measured input cannot be replayed")
            seedDifference += zip(repeatA.columns, otherSeed.columns).map { abs($0 - $1) }.reduce(0, +)
            require(repeatA.columns.allSatisfy { $0 >= 0 && $0 <= 1 }, "Pulse gain escaped the display bounds")
        }
        require(seedDifference > 0.1, "Every recording reused the same pulse pattern regardless of its seed")
        let finiteBefore = sixty.columns
        sixty.advance(average: 1, peak: 1, seconds: .nan)
        require(sixty.columns == finiteBefore, "Invalid frame timestamps corrupted the waveform")

        NSApplication.shared.setActivationPolicy(.prohibited)
        require(CommandLine.arguments.count == 2, "Pass an output directory for temporary frames")
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: amplitudeMetrics, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("amplitude-metrics.json"))
        let hud = DictationHUD()
        var permissionRequests = 0
        hud.onAccessibility = { permissionRequests += 1 }
        hud.showDelivery(message: "已复制 · 需允许自动填入", needsPermission: true, show: false)
        guard let permission = field(hud, "permissionButton", NSButton.self),
              let message = field(hud, "deliveryMessage", NSTextField.self),
              let oldHide = field(hud, "deliveryHide", DispatchWorkItem.self),
              let panel = field(hud, "panel", NSPanel.self) else { fatalError("Missing delivery controls") }
        require(!permission.isHidden && message.stringValue == "已复制 · 需允许自动填入", "Permission fallback must be visible in the HUD")
        require(field(hud, "displayLink", CADisplayLink.self) == nil, "Delivery must not animate microphone activity")
        require(!panel.canBecomeKey && !panel.canBecomeMain && !panel.isVisible, "Delivery tests must preserve the target app's focus")
        permission.performClick(nil)
        require(permissionRequests == 1, "Permission action was not connected")
        var nextRecording = DictationUIState(); nextRecording.recording = true
        hud.update(nextRecording, show: false)
        require(oldHide.isCancelled, "A previous delivery must not hide a new recording")
        hud.showDelivery(message: "已填入输入框", needsPermission: false, show: false)
        require(permission.isHidden, "Successful delivery must not ask for permission")
        let deliveryHide = field(hud, "deliveryHide", DispatchWorkItem.self)
        hud.hideActivity()
        require(deliveryHide?.isCancelled == false, "A health refresh must not erase delivery feedback")
        hud.hide()
        require(deliveryHide?.isCancelled == true, "Explicit hide must cancel pending delivery feedback")
        let speech: [Double] = [-46, -38, -26, -15, -23, -32, -43, -51, -39, -28, -18, -27, -35, -49, -58, -54, -37, -21, -10, -25, -34]
        var comparisonEnvelope = DictationWaveformEnvelope(seed: 54)
        let began = ProcessInfo.processInfo.systemUptime
        for frame in 0..<360 {
            let time = Double(frame) / 60
            var state = DictationUIState()
            state.preview = true
            state.recording = time < 4.1
            state.processing = !state.recording
            state.elapsedSeconds = state.recording ? Int(time) : Int(time - 4.1)
            state.sessionLabel = "第1段"
            state.processingProgress = state.processing ? min(0.94, (time - 4.1) / 2) : nil
            state.processingComplete = time > 5.8
            let speaking = (time >= 0.6 && time < 2.3) || (time >= 3.5 && time < 4.1)
            // Interpolate a dBFS speech fixture at the recorder's 60 Hz cadence.
            // These are synthetic sample data, not microphone measurements.
            let sample = time / 0.045
            let index = Int(sample) % speech.count
            let next = speech[(index + 1) % speech.count]
            let sampleDB = speech[index] + (next - speech[index]) * (sample - floor(sample))
            state.meterLevel = speaking ? measured(sampleDB) : 0
            state.meterPeakLevel = speaking ? measured(sampleDB + 8) : 0
            let file = directory.appendingPathComponent(String(format: "frame-%03d.png", frame))
            try hud.renderPNG(to: file, state: state, animationTime: time, reduceMotion: false)
            comparisonEnvelope.advance(average: state.meterLevel, peak: state.meterPeakLevel, seconds: 1.0 / 60)
            let sheet = NSImage(size: NSSize(width: 240, height: 100)); sheet.lockFocus()
            NSColor(white: 0.96, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 240, height: 100).fill()
            for (row, caption) in ["0.5.3", "0.5.4"].enumerated() {
                let y = CGFloat(54 - row * 46)
                (caption as NSString).draw(at: NSPoint(x: 12, y: y + 9), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.darkGray])
                NSColor(white: 0.055, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: 72, y: y, width: 132, height: 34), xRadius: 17, yRadius: 17).fill()
                NSColor.white.setFill()
                for (index, column) in comparisonEnvelope.columns.enumerated() {
                    let barHeight = row == 0 ? 2 + 16 * column : DictationWaveformEnvelope.displayHeight(for: column)
                    NSBezierPath(roundedRect: NSRect(x: 119 + CGFloat(index * 4), y: y + (34 - barHeight) / 2, width: 2, height: barHeight), xRadius: 1, yRadius: 1).fill()
                }
            }
            sheet.unlockFocus()
            if let tiff = sheet.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) {
                try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(String(format: "comparison-%03d.png", frame)))
            }
        }
        hud.hide()
        var reduced = DictationUIState()
        reduced.preview = true; reduced.processing = true
        for frame in 0..<2 {
            try hud.renderPNG(to: directory.appendingPathComponent("reduced-\(frame).png"), state: reduced,
                              animationTime: Double(frame), reduceMotion: true)
        }
        let first = try Data(contentsOf: directory.appendingPathComponent("reduced-0.png"))
        let second = try Data(contentsOf: directory.appendingPathComponent("reduced-1.png"))
        require(first == second, "Reduced-motion processing frames must be identical")
        hud.hide()
        print(String(format: "PASS: calibrated speech display range, quiet floor/soft ceiling, actual rendered peak heights, unchanged dB/pulse control, first-frame onset and immediate softened peaks, <=100ms silence release, independent sound-triggered pulses, reduced motion, invalid input, delivery feedback/action/cancellation; max 60/120 Hz difference %.4f; 362 invisible frames rendered in %.2f s.", largestRefreshDifference, ProcessInfo.processInfo.systemUptime - began))
        print("No app window shown, microphone started, production app launched, or global listener enabled.")
    }
}
