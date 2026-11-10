import AppKit

/// Native mouse events exercise the visible hover layer, rather than calling
/// the tooltip string formatter. All records and windows are isolated fixtures.
@main
enum HeatmapHoverChecks {
    static var checks = 0
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw NSError(domain: "HeatmapHoverChecks", code: checks, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func card(in root: NSView) -> NSView? { descendants(root).first { $0.identifier?.rawValue == "activity-day-hover" } }
    static func contents(in root: NSView) -> String { card(in: root)?.accessibilityLabel() ?? "" }
    static func calendar() -> Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = .current; return value }
    static func prepare(_ root: NSView) {
        root.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        for map in descendants(root).compactMap({ $0 as? DictationActivityHeatmap }) { map.needsLayout = true; map.layoutSubtreeIfNeeded() }
        root.layoutSubtreeIfNeeded()
    }
    static func move(_ map: DictationActivityHeatmap, at point: NSPoint) throws {
        guard let window = map.window,
              let event = NSEvent.mouseEvent(with: .mouseMoved, location: map.convert(point, to: nil), modifierFlags: [],
                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                  eventNumber: 1, clickCount: 0, pressure: 0) else { throw NSError(domain: "MouseEvent", code: 1) }
        // AppKit does not dispatch a tracking area's activeInKeyWindow event
        // in an intentionally hidden test window. Deliver that NSEvent to its
        // registered owner, exactly where native tracking dispatch enters.
        map.updateTrackingAreas()
        try require(map.trackingAreas.contains { $0.owner as AnyObject? === map && $0.options.contains(.mouseMoved) }, "Heatmap missing mouse tracking registration")
        map.mouseMoved(with: event)
        RunLoop.current.run(until: Date().addingTimeInterval(0.24))
    }
    static func hover(_ map: DictationActivityHeatmap, cell: DictationActivityHeatmap.Cell) throws {
        try move(map, at: NSPoint(x: cell.rect.midX, y: cell.rect.midY))
    }
    static func revealAndHover(_ map: DictationActivityHeatmap, date: Date) throws {
        guard let root = map.window?.contentView, let clip = map.enclosingScrollView?.contentView,
              let target = map.cells.first(where: { $0.date == date }) else { throw NSError(domain: "HomeHoverFixture", code: 1) }
        // Scrolling can finish in a later AppKit run-loop pass. A bounds/frame
        // change correctly dismisses the tooltip, so the mouse event must
        // target a settled viewport rather than race deferred scroll completion.
        // Reveal the actual target, then require stable viewport geometry before
        // sending one mouse event. Do not retry mouse events to mask dismissal.
        map.scrollToVisible(target.rect.insetBy(dx: -4, dy: -4))
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var previous: [NSRect] = [], stableSince = ProcessInfo.processInfo.systemUptime
        var visibleCell: DictationActivityHeatmap.Cell?
        while ProcessInfo.processInfo.systemUptime < deadline {
            map.window?.layoutIfNeeded(); root.layoutSubtreeIfNeeded(); map.layoutSubtreeIfNeeded()
            guard let cell = map.cells.first(where: { $0.date == date }) else { break }
            let geometry = [root.bounds, map.frame, map.bounds, clip.bounds, map.convert(cell.rect, to: root)]
            let now = ProcessInfo.processInfo.systemUptime
            if geometry != previous { previous = geometry; stableSince = now }
            if map.visibleRect.contains(cell.rect), now - stableSince >= 0.10 { visibleCell = cell; break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        try require(visibleCell != nil, "Home hover target did not settle in viewport: map=\(map.frame) visible=\(map.visibleRect) clip=\(clip.bounds)")
        try hover(map, cell: visibleCell!)
        // Timing fidelity is covered by DictationMotionTests. This integration
        // check waits for the queued UI result without weakening its contents.
        let hoverDeadline = ProcessInfo.processInfo.systemUptime + 1
        while card(in: root) == nil && ProcessInfo.processInfo.systemUptime < hoverDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
    static func leave(_ map: DictationActivityHeatmap) throws {
        guard let window = map.window,
              let event = NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
                  windowNumber: window.windowNumber, context: nil, eventNumber: 2, trackingNumber: 0, userData: nil) else { throw NSError(domain: "MouseEvent", code: 2) }
        map.mouseExited(with: event)
        RunLoop.current.run(until: Date().addingTimeInterval(0.14))
    }
    static func screenshot(_ root: NSView, name: String) throws {
        guard let index = CommandLine.arguments.firstIndex(of: "--render"), CommandLine.arguments.indices.contains(index + 1) else { return }
        let directory = CommandLine.arguments[index + 1]
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        guard let image = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { throw NSError(domain: "Capture", code: 1) }
        root.cacheDisplay(in: root.bounds, to: image)
        guard let data = image.representation(using: .png, properties: [:]) else { throw NSError(domain: "Capture", code: 2) }
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }
    static func add(_ store: DictationStore, date: Date, text: String, audio: Double?) {
        store.add(rawText: text, text: text, asrSeconds: 0.1, cleanupSeconds: 0.2, totalSeconds: 0.3,
                  audioSeconds: audio, cleanupApplied: true, warning: nil, createdAt: date)
    }
    static func main() {
        do { try run(); print("PASS: \(checks) heatmap hover checks (native NSEvents, hidden fixture windows)") }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func run() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        DictationMotion.reduceMotionOverride = false
        defer { DictationMotion.reduceMotionOverride = nil }
        let local = calendar(), now = local.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 12))!
        let today = local.startOfDay(for: now)
        let store = DictationStore(memoryOnly: true)
        add(store, date: local.date(byAdding: .day, value: -400, to: now)!, text: "最早记录", audio: 1)
        add(store, date: local.date(byAdding: .day, value: -20, to: now)!, text: "先前记录", audio: 2)
        add(store, date: now, text: String(repeating: "语", count: 640), audio: 70)
        add(store, date: now, text: String(repeating: "音", count: 360), audio: 95)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 350), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.acceptsMouseMovedEvents = true
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 350)); root.wantsLayer = true; root.layer?.backgroundColor = NSColor.white.cgColor
        window.contentView = root
        let map = DictationActivityHeatmap(usage: store.usage, now: now)
        root.addSubview(map)
        NSLayoutConstraint.activate([map.leadingAnchor.constraint(equalTo: root.leadingAnchor), map.trailingAnchor.constraint(equalTo: root.trailingAnchor), map.topAnchor.constraint(equalTo: root.topAnchor, constant: 15)])
        prepare(root)
        defer { window.close() }
        guard let active = map.cells.first(where: { local.isDate($0.date, inSameDayAs: now) }) else { throw NSError(domain: "Fixture", code: 1) }
        let firstResponder = window.firstResponder
        try hover(map, cell: active)
        try require(card(in: root) != nil, "Mouse hover showed only a border and no visible statistics")
        try require(contents(in: root).contains("转写次数：2 次") && contents(in: root).contains("输出字数：1,000 字") && contents(in: root).contains("口述时长：2 分 45 秒"), "Hover lost the day's count, characters or duration")
        try require(contents(in: root).components(separatedBy: "\n").count == 4, "Hover includes more than three metrics")
        try require(window.firstResponder === firstResponder && card(in: root)?.acceptsFirstResponder == false, "Hover stole keyboard focus")
        try require(card(in: root)?.hitTest(.zero) == nil, "Hover card intercepted pointer events")
        let originalCard = card(in: root)
        try hover(map, cell: active)
        try require(card(in: root) === originalCard, "Stationary hover recreates its view")
        map.needsLayout = true; map.layoutSubtreeIfNeeded()
        try require(card(in: root) === originalCard, "Unchanged layout reset visible statistics")
        try screenshot(root, name: "hover-today.png")
        try leave(map)
        try require(card(in: root) == nil, "Mouse exit left statistics visible")

        let zero = map.cells.first { $0.date < today && $0.enabled && $0.count == 0 }!
        try hover(map, cell: zero)
        try require(contents(in: root).contains("转写次数：0 次") && contents(in: root).contains("输出字数：0 字") && contents(in: root).contains("口述时长：0 秒"), "Measured empty day was not shown as zero")
        try screenshot(root, name: "hover-empty-day.png")
        let future = map.cells.first { $0.date > today }!
        try hover(map, cell: future)
        try require(contents(in: root).contains("尚未到来") && !contents(in: root).contains("转写次数"), "Future date displayed fabricated zero metrics")
        try screenshot(root, name: "hover-future.png")
        let left = map.cells[0], below = map.cells[1], right = map.cells[7]
        try move(map, at: NSPoint(x: (left.rect.maxX + right.rect.minX) / 2, y: left.rect.midY))
        try require(card(in: root) == nil, "Grid gap retained a neighboring day's statistics")
        try hover(map, cell: active)
        try move(map, at: NSPoint(x: -2, y: -2))
        try require(card(in: root) == nil, "Pointer outside map retained hover")

        // Check left/right and upper/lower cells. The overlay is attached to
        // the root, so its frame is bounded by the viewport, not the tiny tile.
        for cell in [left, below, map.cells[6], map.cells[map.cells.count - 7], map.cells.last!] {
            try hover(map, cell: cell)
            guard let visible = card(in: root) else { throw NSError(domain: "Hover", code: 1) }
            try require(root.bounds.insetBy(dx: 10, dy: 10).contains(visible.frame), "Edge hover clipped outside window: \(visible.frame)")
            try require(visible.superview === root, "Hover remains clipped inside grid or scroll view")
        }
        try screenshot(root, name: "hover-right-edge.png")
        window.setContentSize(NSSize(width: 1120, height: 350)); prepare(root)
        try require(card(in: root) == nil && map.visibleWeeks == 52, "Resize left old geometry or hover behind")
        try hover(map, cell: map.cells.last!)
        try require(root.bounds.insetBy(dx: 10, dy: 10).contains(card(in: root)!.frame), "Resized hover did not use new viewport")
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        try require(card(in: root) == nil, "Hidden window retained its hover layer")
        try hover(map, cell: map.cells.last!)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        try require(card(in: root) == nil, "Inactive window retained its hover layer")
        try hover(map, cell: map.cells.last!); map.isHidden = true
        try require(card(in: root) == nil, "Hidden view left an orphan overlay")
        map.isHidden = false
        try hover(map, cell: map.cells.last!); map.removeFromSuperview()
        try require(card(in: root) == nil, "Page removal left an orphan overlay")

        let empty = DictationActivityHeatmap(usage: DictationUsage(), now: now)
        root.addSubview(empty)
        NSLayoutConstraint.activate([empty.leadingAnchor.constraint(equalTo: root.leadingAnchor), empty.trailingAnchor.constraint(equalTo: root.trailingAnchor), empty.topAnchor.constraint(equalTo: root.topAnchor, constant: 15)])
        prepare(root); try hover(empty, cell: empty.cells.first!)
        try require(contents(in: root).contains("尚未开始统计") && !contents(in: root).contains("转写次数"), "Uncollected dates were shown as measured zeros")
        try screenshot(root, name: "hover-before-collection.png")
        empty.removeFromSuperview()

        // Also enter through the real home page, its scroll view and pager.
        let controller = DictationWindowController(store: store, sessionStartedAt: now)
        guard let appWindow = controller.window, let appRoot = appWindow.contentView else { throw NSError(domain: "Window", code: 3) }
        defer { appWindow.close() }
        appWindow.setContentSize(NSSize(width: 1000, height: 668))
        var state = DictationUIState(); state.serviceReady = true; state.cleanupBackend = .local
        state.functionKeyEnabled = true; state.accessibilityAllowed = true; state.microphoneAllowed = true
        controller.updateState(state); prepare(appRoot)
        let homeMap = descendants(appRoot).compactMap { $0 as? DictationActivityHeatmap }.first!
        let latest = homeMap.cells.first { $0.count > 100 }!
        try revealAndHover(homeMap, date: latest.date)
        try require(contents(in: appRoot).contains("1,000 字"), "Home hover did not display its daily statistics: contents=\(contents(in: appRoot)), map=\(homeMap.frame), visible=\(homeMap.visibleRect), target=\(latest.rect)")
        try require(appRoot.bounds.insetBy(dx: 10, dy: 10).contains(card(in: appRoot)!.frame), "Home hover escaped viewport")
        try screenshot(appRoot, name: "home-hover-1000.png")
        let previous = descendants(appRoot).compactMap { $0 as? NSButton }.first { $0.toolTip == "查看前 26 周" }!
        try require(previous.isEnabled, "Paging fixture lacks prior statistics")
        previous.performClick(nil); prepare(appRoot)
        try require(card(in: appRoot) == nil, "Page change retained previous date's overlay")
        let priorMap = descendants(appRoot).compactMap { $0 as? DictationActivityHeatmap }.first!
        try revealAndHover(priorMap, date: priorMap.cells.last!.date)
        try require(!contents(in: appRoot).contains("1,000 字") && card(in: appRoot) != nil, "Prior page hover reused current statistics")
        guard let outer = appRoot.subviews.compactMap({ $0 as? NSScrollView }).first else { throw NSError(domain: "Scroll", code: 1) }
        let oldOrigin = outer.contentView.bounds.origin
        outer.contentView.scroll(to: NSPoint(x: 0, y: oldOrigin.y > 0 ? oldOrigin.y - 1 : 1))
        try require(outer.contentView.bounds.origin != oldOrigin, "Scroll fixture did not move its viewport")
        try require(card(in: appRoot) == nil, "Scrolling left a detached hover anchor")
        try hover(priorMap, cell: priorMap.cells.last!)
        let history = descendants(appRoot).compactMap { $0 as? SidebarNavigationButton }.first { $0.title == "历史记录" }!
        history.performClick(nil)
        try require(card(in: appRoot) == nil, "Sidebar navigation left home hover visible")
        try require(!window.isVisible && !appWindow.isVisible, "Fixture windows became visible")
    }
}
