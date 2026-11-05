import AppKit

/// Uses the real AppKit run loop and intermediate rendered frames. The windows
/// stay hidden, model inputs stay in memory, and system preferences are intact.
@main
enum DictationMotionChecks {
    static var checks = 0
    static var samples: [[String: Any]] = []
    static var renderedFrames: [(String, NSBitmapImageRep)] = []
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw NSError(domain: "DictationMotionChecks", code: checks, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func wait(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    static func wait(until uptime: TimeInterval) { wait(max(0, uptime - ProcessInfo.processInfo.systemUptime)) }
    static func waitFor(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            wait(min(0.002, remaining))
        }
        return true
    }
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func card(_ root: NSView) -> NSView? { descendants(root).first { $0.identifier?.rawValue == "activity-day-hover" } }
    static func event(_ type: NSEvent.EventType, for view: NSView, point: NSPoint) -> NSEvent {
        let location = view.convert(point, to: nil), window = view.window!
        if type == .mouseMoved {
            return NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0)!
        }
        return NSEvent.enterExitEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, trackingNumber: 0, userData: nil)!
    }
    static func move(_ map: DictationActivityHeatmap, _ cell: DictationActivityHeatmap.Cell) {
        map.mouseMoved(with: event(.mouseMoved, for: map, point: NSPoint(x: cell.rect.midX, y: cell.rect.midY)))
    }
    static func leave(_ map: DictationActivityHeatmap) { map.mouseExited(with: event(.mouseExited, for: map, point: .zero)) }
    static func rowShade(_ row: NSView, in root: NSView) -> CGFloat {
        let image = renderedFrames.last!.1, rect = row.convert(row.bounds, to: root)
        let scale = CGFloat(image.pixelsWide) / root.bounds.width
        let y = root.isFlipped ? rect.midY : root.bounds.height - rect.midY
        return image.colorAt(x: Int((rect.minX + 5) * scale), y: Int(y * scale))!.usingColorSpace(.sRGB)!.redComponent
    }
    @discardableResult static func frame(_ root: NSView, _ name: String, since start: TimeInterval) throws -> Data {
        guard let image = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { throw NSError(domain: "Frame", code: 1) }
        root.cacheDisplay(in: root.bounds, to: image)
        // Encode PNGs only after timing assertions: compression on the main
        // thread would otherwise stall the animation we are measuring.
        let data = Data(bytes: image.bitmapData!, count: image.bytesPerRow * image.pixelsHigh)
        samples.append(["frame": name, "elapsed_ms": (ProcessInfo.processInfo.systemUptime - start) * 1000,
                        "tooltip_alpha": card(root)?.alphaValue ?? -1])
        renderedFrames.append((name, image))
        return data
    }
    static func main() {
        do { try run(); print("PASS: \(checks) timed motion checks, intermediate frames and cancellation verified") }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func run() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        DictationMotion.reduceMotionOverride = false
        defer { DictationMotion.reduceMotionOverride = nil }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.acceptsMouseMovedEvents = true
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 400)); root.wantsLayer = true; root.layer?.backgroundColor = NSColor.white.cgColor
        window.contentView = root
        defer { window.close() }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 12))!
        var usage = DictationUsage()
        _ = usage.record(DictationEntry(id: UUID(), createdAt: now, rawText: "", text: String(repeating: "语", count: 680),
            asrSeconds: 0.1, cleanupSeconds: 0.1, totalSeconds: 0.2, audioSeconds: 125, cleanupApplied: true, warning: nil))
        let map = DictationActivityHeatmap(usage: usage, now: now); root.addSubview(map)
        NSLayoutConstraint.activate([map.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 230), map.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12), map.topAnchor.constraint(equalTo: root.topAnchor, constant: 15)])
        let row = SidebarNavigationButton(title: "首页", symbol: "house") {}; root.addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16), row.topAnchor.constraint(equalTo: root.topAnchor, constant: 45), row.widthAnchor.constraint(equalToConstant: 186)])
        root.layoutSubtreeIfNeeded(); map.layoutSubtreeIfNeeded(); wait(0.04)
        let active = map.cells.first { $0.count == 680 }!, next = map.cells.last!
        map.updateTrackingAreas()
        try require(map.trackingAreas.contains { $0.options.contains(.mouseMoved) }, "Native tracking route missing")
        let firstResponder = window.firstResponder

        let initial = try frame(root, "tooltip-000", since: ProcessInfo.processInfo.systemUptime)
        let began = ProcessInfo.processInfo.systemUptime
        move(map, active)
        try require(card(root) == nil, "Tooltip appeared at the first frame without dwell")
        wait(until: began + 0.035)
        try require(card(root) == nil, "Tooltip skipped 80ms dwell")
        try frame(root, "tooltip-dwell", since: began)
        // Dwell and animation are separate run-loop callbacks. Sample the
        // actual transition, so a delayed callback on a busy CI host is not
        // mistaken for an instant entry before its first frame has run.
        try require(waitFor(timeout: 0.5) { card(root) != nil }, "Dwell completed without showing tooltip")
        guard let entering = card(root) else { throw NSError(domain: "Tooltip", code: 1, userInfo: [NSLocalizedDescriptionKey: "Dwell completed without showing tooltip"]) }
        try require(waitFor(timeout: 0.2) { entering.alphaValue > 0 }, "Tooltip entry never advanced past its initial opacity")
        let earlyAlpha = entering.alphaValue
        try require(earlyAlpha > 0 && earlyAlpha < 0.98, "Tooltip entry was instantaneous: \(earlyAlpha)")
        let early = try frame(root, "tooltip-entry", since: began)
        try require(waitFor(timeout: 0.2) { entering.alphaValue > earlyAlpha }, "Tooltip opacity stopped during entry")
        try require(entering.alphaValue > earlyAlpha && entering.alphaValue < 1, "Tooltip opacity did not progress through intermediate frames: \(earlyAlpha) → \(entering.alphaValue), elapsed \(ProcessInfo.processInfo.systemUptime - began)")
        let middle = try frame(root, "tooltip-middle", since: began)
        // Wait for the completion assignment, not merely the final eased
        // frame: date changes below require a fully settled tooltip.
        _ = waitFor(timeout: 0.4) { entering.alphaValue == 1 }
        try require(entering.alphaValue == 1, "Tooltip did not finish its entry")
        let full = try frame(root, "tooltip-full", since: began)
        try require(initial != early && early != middle && middle != full, "Rendered intermediate tooltip frames did not change")
        try require(window.firstResponder === firstResponder, "Tooltip took input focus")

        move(map, next)
        try require(card(root) === entering && entering.alphaValue == 1, "Date change recreated or faded out the tooltip")
        try require(entering.accessibilityLabel()?.contains("尚未到来") == true, "Date change retained old metrics")
        let first = map.cells[0], right = map.cells[7]
        map.mouseMoved(with: event(.mouseMoved, for: map, point: NSPoint(x: (first.rect.maxX + right.rect.minX) / 2, y: first.rect.midY)))
        wait(0.02)
        try require(card(root) === entering && entering.alphaValue == 1, "Grid gap did not preserve its 40ms bridge")
        move(map, active); wait(0.15)
        try require(card(root) === entering && entering.alphaValue == 1, "A cancelled gap exit removed the resumed tooltip")

        let exitBegan = ProcessInfo.processInfo.systemUptime
        leave(map)
        // Observe the first real exit frame, just as entry does above. A
        // loaded CI run loop can defer its timer past an arbitrary 35 ms.
        try require(waitFor(timeout: 0.2) { entering.alphaValue < 1 }, "Tooltip exit never advanced")
        let exitAlpha = entering.alphaValue
        try require(card(root) === entering && exitAlpha > 0 && exitAlpha < 1,
                    "Tooltip exit skipped its intermediate opacity: \(exitAlpha), elapsed \(ProcessInfo.processInfo.systemUptime - exitBegan)")
        try frame(root, "tooltip-exit", since: exitBegan)
        move(map, next)
        try require(card(root) === entering && abs(entering.alphaValue - exitAlpha) < 0.01, "Re-entry jumped opacity or created a duplicate layer")
        wait(0.16)
        try require(card(root) === entering && entering.alphaValue == 1, "Old exit completion removed the new hover")
        leave(map); wait(0.14)
        try require(card(root) == nil, "Tooltip exit never removed its layer")
        move(map, active); wait(0.025); leave(map); wait(0.20)
        try require(card(root) == nil, "Leaving during dwell produced a ghost tooltip")
        move(map, active); wait(0.02); move(map, next); wait(0.02); move(map, active); wait(0.24)
        try require(card(root)?.accessibilityLabel()?.contains("680 字") == true, "Rapid date changes displayed an older scheduled result")
        leave(map); wait(0.14)
        move(map, active); map.isHidden = true; wait(0.24)
        try require(card(root) == nil, "Hidden map's delayed work created an orphan tooltip")
        map.isHidden = false

        let rowStart = ProcessInfo.processInfo.systemUptime
        let rowPlain = try frame(root, "sidebar-idle", since: rowStart)
        let idleShade = rowShade(row, in: root)
        row.mouseEntered(with: event(.mouseEntered, for: row, point: NSPoint(x: 10, y: 10)))
        wait(0.035)
        let rowMiddle = try frame(root, "sidebar-hover-middle", since: rowStart)
        let middleShade = rowShade(row, in: root)
        wait(0.10)
        let rowHover = try frame(root, "sidebar-hover-full", since: rowStart)
        let finalShade = rowShade(row, in: root)
        try require(rowPlain != rowMiddle && rowMiddle != rowHover, "Sidebar hover has no rendered color transition")
        try require(idleShade > middleShade && middleShade > finalShade, "Sidebar animation flashes darker than its final color: \(idleShade), \(middleShade), \(finalShade)")
        let rowFrame = row.frame, symbolFrame = row.symbolView.frame, labelFrame = row.textLabel.frame
        row.selected = true; wait(0.04); row.selected = false
        row.mouseExited(with: event(.mouseExited, for: row, point: .zero)); wait(0.16)
        try require(row.frame == rowFrame && row.symbolView.frame == symbolFrame && row.textLabel.frame == labelFrame, "Sidebar motion shifted hit target, icon or text")
        try require(!row.selected && row.state == .off, "Interrupted selection retained old semantic state")

        let reveal = NSView(frame: NSRect(x: 20, y: 20, width: 100, height: 30)); root.addSubview(reveal)
        DictationMotion.reveal(reveal)
        try require(abs(reveal.alphaValue - 0.78) < 0.001, "Reveal did not start at 0.78")
        wait(0.05)
        let revealAlpha = reveal.alphaValue
        try require(revealAlpha > 0.78 && revealAlpha < 1, "Reveal has no intermediate values")
        DictationMotion.reveal(reveal)
        try require(abs(reveal.alphaValue - revealAlpha) < 0.001, "Repeated reveal jumped backwards")
        DictationMotion.cancel(reveal); wait(0.18)
        try require(reveal.alphaValue == 1, "Cancelled reveal left stale transparency")
        var oldCompletion = false
        DictationMotion.fade(reveal, to: 0, duration: 0.09) { oldCompletion = true }
        wait(0.025); DictationMotion.cancel(reveal); wait(0.12)
        try require(!oldCompletion && reveal.alphaValue == 1, "Cancelled completion fired after replacement")

        DictationMotion.reduceMotionOverride = true
        DictationMotion.reveal(reveal, duration: 0.3); wait(0.025)
        try require(reveal.alphaValue > 0.78 && reveal.alphaValue < 1, "Reduced motion lost all state transition feedback")
        wait(0.07)
        try require(reveal.alphaValue == 1 && reveal.frame.origin == NSPoint(x: 20, y: 20), "Reduced motion moved the view or stayed transparent")
        move(map, active); wait(0.18)
        try require(card(root)?.alphaValue == 1, "Reduced-motion tooltip did not complete within 80+60ms")
        leave(map); wait(0.09)
        try require(card(root) == nil, "Reduced-motion exit failed to clean up")
        DictationMotion.reduceMotionOverride = false
        DictationMotion.reveal(reveal, duration: 0.5); wait(0.04)
        DictationMotion.reduceMotionOverride = true
        try require(reveal.alphaValue == 1, "Runtime motion-policy change left an unfinished transition")
        try require(!window.isVisible, "Motion test activated a window")

        if let i = CommandLine.arguments.firstIndex(of: "--render"), CommandLine.arguments.indices.contains(i + 1) {
            let directory = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, image) in renderedFrames {
                try image.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
            }
            let data = try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("motion-samples.json"))
        }
    }
}
