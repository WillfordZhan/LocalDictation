import AppKit
import CoreFoundation

/// Real dwell/timer integration plus deterministic progress through the actual
/// animation callbacks. Hidden windows and memory-only inputs preserve user state.
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
            // Return after one source is handled so the predicate observes
            // that callback's state before later animation callbacks run.
            CFRunLoopRunInMode(.defaultMode, min(0.002, remaining), true)
        }
        return true
    }
    struct CapturedAnimation {
        let animation: DictationMotionAnimation
        let startedAt: TimeInterval
    }
    static func capture(duration: TimeInterval, after action: () throws -> Void) throws -> CapturedAnimation {
        var started: [CapturedAnimation] = []
        try require(DictationMotionAnimation.startForTesting == nil, "Animation driver leaked into another transition")
        DictationMotionAnimation.startForTesting = {
            started.append(CapturedAnimation(animation: $0, startedAt: ProcessInfo.processInfo.systemUptime))
        }
        defer { DictationMotionAnimation.startForTesting = nil }
        try action()
        try require(waitFor(timeout: 0.8) { !started.isEmpty }, "Expected transition never started")
        try require(started.count == 1, "One action started multiple animations")
        let captured = started[0], animation = captured.animation
        try require(abs(animation.duration - duration) < 0.000001 && animation.frameRate == 60 &&
                    animation.animationBlockingMode == .nonblocking, "Animation timing contract changed")
        try require(animation.currentProgress == 0, "Captured animation advanced before the fixture drove it")
        return captured
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
        let renderStarted = ProcessInfo.processInfo.systemUptime
        let alphaBeforeRender = card(root)?.alphaValue ?? -1
        guard let image = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { throw NSError(domain: "Frame", code: 1) }
        root.cacheDisplay(in: root.bounds, to: image)
        // Encode PNGs only after timing assertions: compression on the main
        // thread would otherwise stall the animation we are measuring.
        let data = Data(bytes: image.bitmapData!, count: image.bytesPerRow * image.pixelsHigh)
        samples.append(["frame": name, "elapsed_ms": (ProcessInfo.processInfo.systemUptime - start) * 1000,
                        "render_ms": (ProcessInfo.processInfo.systemUptime - renderStarted) * 1000,
                        "tooltip_alpha_before_render": alphaBeforeRender,
                        "tooltip_alpha": card(root)?.alphaValue ?? -1])
        renderedFrames.append((name, image))
        return data
    }
    static func main() {
        do { try run(); print("PASS: \(checks) timed motion checks, intermediate frames and cancellation verified") }
        catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            if let data = try? JSONSerialization.data(withJSONObject: samples, options: [.sortedKeys]),
               let diagnostic = String(data: data, encoding: .utf8) {
                fputs("MOTION SAMPLES: \(diagnostic)\n", stderr)
            }
            exit(1)
        }
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
        let entry = try capture(duration: 0.12) {
            move(map, active)
            try require(card(root) == nil, "Tooltip appeared at the first frame without dwell")
            wait(until: began + 0.035)
            // The callback time below proves the real dwell even when a busy
            // host returns from this negative window after its deadline.
            if ProcessInfo.processInfo.systemUptime < began + 0.08 {
                try require(card(root) == nil, "Tooltip skipped 80ms dwell")
            }
            try frame(root, "tooltip-dwell", since: began)
        }
        try require(entry.startedAt - began >= 0.08, "Tooltip started before its real 80ms dwell elapsed")
        guard let entering = card(root) else { throw NSError(domain: "Tooltip", code: 1, userInfo: [NSLocalizedDescriptionKey: "Dwell completed without showing tooltip"]) }
        try require(entering.alphaValue == 0, "Tooltip entry did not start transparent")
        entry.animation.currentProgress = 0.15
        let earlyAlpha = entering.alphaValue
        try require(earlyAlpha > 0 && earlyAlpha < 0.98, "Tooltip entry was instantaneous: \(earlyAlpha)")
        let early = try frame(root, "tooltip-entry", since: began)
        entry.animation.currentProgress = 0.5
        try require(entering.alphaValue > earlyAlpha && entering.alphaValue < 1, "Tooltip opacity did not progress through intermediate frames: \(earlyAlpha) → \(entering.alphaValue), elapsed \(ProcessInfo.processInfo.systemUptime - began)")
        let middle = try frame(root, "tooltip-middle", since: began)
        entry.animation.currentProgress = 1
        try require(entering.alphaValue == 1, "Tooltip did not finish its entry")
        let full = try frame(root, "tooltip-full", since: began)
        try require(initial != early && early != middle && middle != full, "Rendered intermediate tooltip frames did not change")
        try require(window.firstResponder === firstResponder, "Tooltip took input focus")

        move(map, next)
        try require(card(root) === entering && entering.alphaValue == 1, "Date change recreated or faded out the tooltip")
        try require(entering.accessibilityLabel()?.contains("尚未到来") == true, "Date change retained old metrics")
        let first = map.cells[0], right = map.cells[7]
        let gapBegan = ProcessInfo.processInfo.systemUptime
        let gapExit = try capture(duration: 0.09) {
            map.mouseMoved(with: event(.mouseMoved, for: map, point: NSPoint(x: (first.rect.maxX + right.rect.minX) / 2, y: first.rect.midY)))
            wait(0.02)
            try require(card(root) === entering && entering.alphaValue == 1, "Grid gap did not preserve its bridge")
        }
        try require(gapExit.startedAt - gapBegan >= 0.04, "Grid gap skipped its real 40ms bridge")
        move(map, active); wait(0.15)
        try require(card(root) === entering && entering.alphaValue == 1, "A cancelled gap exit removed the resumed tooltip")
        do {
            var unexpectedStarts = 0
            DictationMotionAnimation.startForTesting = { _ in unexpectedStarts += 1 }
            defer { DictationMotionAnimation.startForTesting = nil }
            map.mouseMoved(with: event(.mouseMoved, for: map, point: NSPoint(x: (first.rect.maxX + right.rect.minX) / 2, y: first.rect.midY)))
            move(map, active)
            wait(0.15)
            try require(unexpectedStarts == 0 && card(root) === entering && entering.alphaValue == 1,
                        "Returning before the gap deadline failed to cancel pending exit work")
        }

        let exitBegan = ProcessInfo.processInfo.systemUptime
        let exit = try capture(duration: 0.09) { leave(map) }
        exit.animation.currentProgress = 0.25
        let exitAlpha = entering.alphaValue
        try require(card(root) === entering && exitAlpha > 0 && exitAlpha < 1,
                    "Tooltip exit skipped its intermediate opacity: \(exitAlpha), elapsed \(ProcessInfo.processInfo.systemUptime - exitBegan)")
        try frame(root, "tooltip-exit", since: exitBegan)
        let resumed = try capture(duration: 0.12) { move(map, next) }
        try require(card(root) === entering && abs(entering.alphaValue - exitAlpha) < 0.01, "Re-entry jumped opacity or created a duplicate layer")
        resumed.animation.currentProgress = 0.5
        try require(entering.alphaValue > exitAlpha && entering.alphaValue < 1, "Resumed tooltip skipped intermediate opacity")
        resumed.animation.currentProgress = 1
        wait(0.15)
        try require(card(root) === entering && entering.alphaValue == 1, "Old exit completion removed the new hover")
        // Keep a timer-driven cancellation/re-entry case as well: a cancelled
        // animation must not later remove the layer owned by the resumed hover.
        leave(map); move(map, next)
        try require(card(root) === entering, "Real-timer re-entry replaced the tooltip layer")
        try require(waitFor(timeout: 0.8) { card(root) === entering && entering.alphaValue == 1 },
                    "Real-timer re-entry did not finish")
        wait(0.15)
        try require(card(root) === entering && entering.alphaValue == 1, "Cancelled real exit later removed the resumed layer")
        let removal = try capture(duration: 0.09) { leave(map) }
        removal.animation.currentProgress = 1
        try require(card(root) == nil, "Tooltip exit never removed its layer")
        move(map, active); wait(0.025); leave(map); wait(0.20)
        try require(card(root) == nil, "Leaving during dwell produced a ghost tooltip")
        move(map, active); wait(0.02); move(map, next); wait(0.02); move(map, active)
        _ = waitFor(timeout: 0.5) { card(root)?.accessibilityLabel()?.contains("680 字") == true }
        try require(card(root)?.accessibilityLabel()?.contains("680 字") == true, "Rapid date changes displayed an older scheduled result")
        leave(map)
        try require(waitFor(timeout: 0.3) { card(root) == nil }, "Rapid-date tooltip did not finish removal")
        move(map, active); map.isHidden = true; wait(0.24)
        try require(card(root) == nil, "Hidden map's delayed work created an orphan tooltip")
        map.isHidden = false

        let rowStart = ProcessInfo.processInfo.systemUptime
        let rowPlain = try frame(root, "sidebar-idle", since: rowStart)
        let idleShade = rowShade(row, in: root)
        let sidebarAnimation = try capture(duration: 0.10) {
            row.mouseEntered(with: event(.mouseEntered, for: row, point: NSPoint(x: 10, y: 10)))
        }.animation
        sidebarAnimation.currentProgress = 0.25
        let rowMiddle = try frame(root, "sidebar-hover-middle", since: rowStart)
        let middleShade = rowShade(row, in: root)
        sidebarAnimation.currentProgress = 1
        let rowHover = try frame(root, "sidebar-hover-full", since: rowStart)
        let finalShade = rowShade(row, in: root)
        try require(rowPlain != rowMiddle && rowMiddle != rowHover, "Sidebar hover has no rendered color transition")
        try require(idleShade > middleShade && middleShade > finalShade, "Sidebar animation flashes darker than its final color: \(idleShade), \(middleShade), \(finalShade)")
        let rowFrame = row.frame, symbolFrame = row.symbolView.frame, labelFrame = row.textLabel.frame
        let selection = try capture(duration: 0.12) { row.selected = true }
        selection.animation.currentProgress = 0.25
        let deselection = try capture(duration: 0.12) { row.selected = false }
        deselection.animation.currentProgress = 0.25
        let sidebarExit = try capture(duration: 0.10) { row.mouseExited(with: event(.mouseExited, for: row, point: .zero)) }
        sidebarExit.animation.currentProgress = 1
        try require(row.frame == rowFrame && row.symbolView.frame == symbolFrame && row.textLabel.frame == labelFrame, "Sidebar motion shifted hit target, icon or text")
        try require(!row.selected && row.state == .off, "Interrupted selection retained old semantic state")

        let reveal = NSView(frame: NSRect(x: 20, y: 20, width: 100, height: 30)); root.addSubview(reveal)
        let revealEntry = try capture(duration: 0.15) { DictationMotion.reveal(reveal) }
        try require(abs(reveal.alphaValue - 0.78) < 0.001, "Reveal did not start at 0.78")
        revealEntry.animation.currentProgress = 0.25
        let revealAlpha = reveal.alphaValue
        try require(revealAlpha > 0.78 && revealAlpha < 1, "Reveal has no intermediate values")
        _ = try capture(duration: 0.15) { DictationMotion.reveal(reveal) }
        try require(abs(reveal.alphaValue - revealAlpha) < 0.001, "Repeated reveal jumped backwards")
        DictationMotion.cancel(reveal); wait(0.18)
        try require(reveal.alphaValue == 1, "Cancelled reveal left stale transparency")
        var oldCompletion = false
        let cancellable = try capture(duration: 0.09) {
            DictationMotion.fade(reveal, to: 0, duration: 0.09) { oldCompletion = true }
        }
        cancellable.animation.currentProgress = 0.25
        try require(reveal.alphaValue > 0 && !oldCompletion, "Cancellable fade skipped its intermediate state")
        DictationMotion.cancel(reveal); wait(0.12)
        try require(!oldCompletion && reveal.alphaValue == 1, "Cancelled completion fired after replacement")

        DictationMotion.reduceMotionOverride = true
        try require(DictationMotion.duration(0.3) == 0.06, "Reduced-motion duration exceeded its 60ms policy")
        let reducedEntry = try capture(duration: 0.06) { DictationMotion.reveal(reveal, duration: 0.3) }
        try require(reveal.alphaValue == 0.78, "Reduced-motion reveal lost its initial opacity")
        reducedEntry.animation.currentProgress = 0.25
        try require(reveal.alphaValue > 0.78 && reveal.alphaValue < 1, "Reduced motion lost all state transition feedback")
        reducedEntry.animation.currentProgress = 1
        try require(reveal.alphaValue == 1 && reveal.frame.origin == NSPoint(x: 20, y: 20), "Reduced motion moved the view or stayed transparent")
        move(map, active)
        _ = waitFor(timeout: 0.4) { card(root)?.alphaValue == 1 }
        try require(card(root)?.alphaValue == 1, "Reduced-motion tooltip did not finish its dwell and entry")
        leave(map)
        _ = waitFor(timeout: 0.3) { card(root) == nil }
        try require(card(root) == nil, "Reduced-motion exit failed to clean up")
        DictationMotion.reduceMotionOverride = false
        let policyEntry = try capture(duration: 0.5) { DictationMotion.reveal(reveal, duration: 0.5) }
        policyEntry.animation.currentProgress = 0.25
        try require(reveal.alphaValue < 1, "Policy-change fixture finished before interruption")
        DictationMotion.reduceMotionOverride = true
        try require(reveal.alphaValue == 1, "Runtime motion-policy change left an unfinished transition")
        DictationMotion.reduceMotionOverride = false

        // Exercise the actual NSAnimation timer as well. Completion/cleanup
        // has a bounded deadline; only intermediate visual samples are manual.
        try require(DictationMotionAnimation.startForTesting == nil, "Manual driver escaped into timer integration")
        var timerCompletions = 0
        DictationMotion.fade(reveal, to: 0, duration: 0.09) { timerCompletions += 1 }
        try require(waitFor(timeout: 0.8) { timerCompletions == 1 && reveal.alphaValue == 0 }, "Real animation timer never completed")
        let cleanReveal = try capture(duration: 0.15) { DictationMotion.reveal(reveal) }
        try require(reveal.alphaValue == 0.78, "Completed timer left a stale fade owner")
        cleanReveal.animation.currentProgress = 1
        DictationMotion.fade(reveal, to: 0, duration: 0.09) { timerCompletions += 1 }
        DictationMotion.cancel(reveal)
        wait(0.20)
        try require(timerCompletions == 1 && reveal.alphaValue == 1, "Cancelled real timer changed the view or fired its completion")
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
