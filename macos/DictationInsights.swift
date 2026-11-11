import AppKit

/// SF Symbols carry text-baseline alignment insets. Navigation uses a geometric
/// square instead, so Auto Layout must constrain the actual image-view frame.
private final class SidebarSymbolView: NSImageView {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
}

/// A fixed icon column prevents native imageLeading spacing from shifting text.
final class SidebarNavigationButton: NSButton {
    let symbolView: NSImageView = SidebarSymbolView()
    let textLabel: NSTextField
    private let invoke: () -> Void
    private var hover = false
    private var backgroundColor = NSColor.clear
    private var backgroundTransition: DictationMotionAnimation?
    private var motionObserver: NSObjectProtocol?
    var selected = false {
        didSet {
            state = selected ? .on : .off
            textLabel.font = .systemFont(ofSize: 14, weight: selected ? .semibold : .regular)
            textLabel.textColor = selected ? Palette.ink : Palette.secondary
            symbolView.contentTintColor = textLabel.textColor
            updateBackground(duration: 0.12)
        }
    }
    override var isFlipped: Bool { true }
    init(title: String, symbol: String, action: @escaping () -> Void) {
        textLabel = NSTextField(labelWithString: title); invoke = action
        super.init(frame: .zero)
        self.title = title; isBordered = false; setButtonType(.momentaryChange)
        target = self; self.action = #selector(activateRow)
        translatesAutoresizingMaskIntoConstraints = false; setAccessibilityLabel(title)
        symbolView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
        symbolView.imageScaling = .scaleProportionallyDown; symbolView.contentTintColor = Palette.secondary
        textLabel.font = .systemFont(ofSize: 14); textLabel.textColor = Palette.secondary; textLabel.lineBreakMode = .byClipping
        for view in [symbolView, textLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false; view.setAccessibilityElement(false); addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 46),
            symbolView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            symbolView.widthAnchor.constraint(equalToConstant: 20), symbolView.heightAnchor.constraint(equalToConstant: 20),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor),
            textLabel.leadingAnchor.constraint(equalTo: symbolView.trailingAnchor, constant: 12),
            textLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            textLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        motionObserver = NotificationCenter.default.addObserver(forName: DictationMotion.policyDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.updateBackground(duration: 0)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { backgroundTransition?.cancel(); if let motionObserver { NotificationCenter.default.removeObserver(motionObserver) } }
    @objc private func activateRow() { invoke() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // Child labels describe the row; the entire rectangle remains one hit target.
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func updateTrackingAreas() {
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hover = true; updateBackground(duration: 0.10) }
    override func mouseExited(with event: NSEvent) { hover = false; updateBackground(duration: 0.10) }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { hover = false; updateBackground(duration: 0) }
        super.viewWillMove(toWindow: newWindow)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Animated blends are concrete colors. Discard that cached blend on a
        // theme change and resolve the same navigation state in its new theme.
        updateBackground(duration: 0)
    }
    private func updateBackground(duration: TimeInterval) {
        let target = selected ? Palette.selection : hover ? Palette.hover : .clear
        let origin = backgroundColor
        backgroundTransition?.cancel(); backgroundTransition = nil
        let seconds = DictationMotion.duration(duration)
        guard seconds > 0, !origin.isEqual(target) else { backgroundColor = target; needsDisplay = true; return }
        backgroundTransition = DictationMotionAnimation(duration: seconds, update: { [weak self] progress in
            guard let self else { return }
            self.effectiveAppearance.performAsCurrentDrawingAppearance {
                self.backgroundColor = Self.blend(origin, target, progress: progress)
            }
            self.needsDisplay = true
        }, completion: { [weak self] in self?.backgroundTransition = nil })
        backgroundTransition?.start()
    }
    private static func blend(_ origin: NSColor, _ target: NSColor, progress: CGFloat) -> NSColor {
        guard let from = origin.usingColorSpace(.sRGB), let to = target.usingColorSpace(.sRGB) else { return target }
        let t = min(1, max(0, progress)), alpha = from.alphaComponent * (1 - t) + to.alphaComponent * t
        guard alpha > 0 else { return .clear }
        // Premultiplied blending keeps transparent black from darkening the
        // middle of a transition into the sidebar's very light hover color.
        func channel(_ first: CGFloat, _ last: CGFloat) -> CGFloat {
            (first * from.alphaComponent * (1 - t) + last * to.alphaComponent * t) / alpha
        }
        return NSColor(srgbRed: channel(from.redComponent, to.redComponent),
            green: channel(from.greenComponent, to.greenComponent), blue: channel(from.blueComponent, to.blueComponent), alpha: alpha)
    }
    override func draw(_ dirtyRect: NSRect) {
        let color = isHighlighted && !selected ? Palette.hover : backgroundColor
        color.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 11, yRadius: 11).fill()
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 9, yRadius: 9)
            ring.lineWidth = 2; ring.stroke()
        }
    }
}

/// Drawn inside the owning window instead of an AppKit delayed tooltip. Keeping
/// it outside the heatmap's scroll hierarchy lets edge cells show all metrics.
private final class HeatmapDayHoverView: NSView {
    private var lines: [String] = []
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    init(text: String) {
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("activity-day-hover")
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
        wantsLayer = true; layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.16; layer?.shadowRadius = 8; layer?.shadowOffset = CGSize(width: 0, height: -3)
        update(text: text)
    }
    func update(text: String) {
        lines = text.components(separatedBy: "\n")
        let titleFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        let valueFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
        var width = (lines.first! as NSString).size(withAttributes: [.font: titleFont]).width + 28
        for line in lines.dropFirst() {
            width = max(width, (line as NSString).size(withAttributes: [.font: valueFont]).width + 48)
        }
        setFrameSize(NSSize(width: min(320, max(224, ceil(width))), height: 50 + CGFloat(max(1, lines.count - 1)) * 22))
        setAccessibilityLabel(text); needsDisplay = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    // Hover details never become the mouse target or steal the text insertion
    // point. A move over a neighboring day still reaches the heatmap beneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.13, alpha: 0.98).setFill()
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 11, yRadius: 11)
        shape.fill(); NSColor.white.withAlphaComponent(0.12).setStroke(); shape.lineWidth = 1; shape.stroke()
        let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.66)]
        (lines.first! as NSString).draw(at: NSPoint(x: 14, y: 13), withAttributes: title)
        let right = NSMutableParagraphStyle(); right.alignment = .right; right.lineBreakMode = .byTruncatingTail
        let value: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white, .paragraphStyle: right]
        for (index, line) in lines.dropFirst().enumerated() {
            let y = CGFloat(38 + index * 22)
            if let split = line.firstIndex(of: "：") {
                let label = String(line[..<split]), result = String(line[line.index(after: split)...])
                (label as NSString).draw(at: NSPoint(x: 14, y: y), withAttributes: title)
                (result as NSString).draw(in: NSRect(x: 76, y: y - 1, width: bounds.width - 90, height: 20), withAttributes: value)
            } else {
                (line as NSString).draw(at: NSPoint(x: 14, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white])
            }
        }
    }
}

/// Calendar-day heatmap from aggregates, independent of retained transcripts.
final class DictationActivityHeatmap: NSView {
    struct Cell { let date: Date; let count: Int; let enabled: Bool; let rect: NSRect }
    private let usage: DictationUsage
    private let today: Date
    private let calendar: Calendar
    private let lastSunday: Date
    private var heightConstraint: NSLayoutConstraint!
    private var gridRect = NSRect.zero
    private var tileSize: CGFloat = 15
    private var gap: CGFloat = 5
    private var hoveredDate: Date?
    private var hoverCard: HeatmapDayHoverView?
    private var hoverObservers: [NSObjectProtocol] = []
    private var hoverGeneration: UInt64 = 0
    private var pendingHover: DispatchWorkItem?
    private var pendingExit: DispatchWorkItem?
    private var exitingHover = false
    private(set) var visibleWeeks = 26
    private(set) var startDate: Date
    let endDate: Date
    var onRangeChange: ((Date, Date) -> Void)?
    private(set) var cells: [Cell] = []
    override var isFlipped: Bool { true }
    init(usage: DictationUsage, now: Date = Date(), pageOffset: Int = 0) {
        self.usage = usage
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        self.calendar = calendar; today = calendar.startOfDay(for: now)
        // Sunday anchors columns without depending on locale week-number rules.
        let sunday = calendar.date(byAdding: .day, value: 1 - calendar.component(.weekday, from: now), to: today)!
        lastSunday = calendar.date(byAdding: .weekOfYear, value: -26 * max(0, pageOffset), to: sunday)!
        startDate = calendar.date(byAdding: .weekOfYear, value: -25, to: lastSunday)!
        endDate = calendar.date(byAdding: .day, value: 6, to: lastSunday)!
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightConstraint = heightAnchor.constraint(equalToConstant: 240); heightConstraint.isActive = true
        setAccessibilityElement(true); setAccessibilityRole(.image)
        setAccessibilityLabel("口述活跃日历；颜色越深，当日口述字数越多")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { hoverObservers.forEach { NotificationCenter.default.removeObserver($0) } }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        dismissHover()
        hoverObservers.forEach { NotificationCenter.default.removeObserver($0) }; hoverObservers.removeAll()
        super.viewWillMove(toWindow: newWindow)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.willCloseNotification, NSWindow.didResignKeyNotification,
                     NSWindow.willMiniaturizeNotification, NSWindow.didResizeNotification] {
            hoverObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.dismissHover() })
        }
        hoverObservers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self, weak window] _ in
            if window?.isVisible != true || window?.occlusionState.contains(.visible) != true { self?.dismissHover() }
        })
        hoverObservers.append(center.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main) { [weak self] _ in self?.dismissHover() })
        // A stationary pointer can outlive a scroll or window resize. Remove
        // its old date/position together; the next mouse event uses fresh cells.
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            hoverObservers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in self?.dismissHover() })
        }
        postsFrameChangedNotifications = true
        hoverObservers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: self, queue: .main) { [weak self] _ in self?.dismissHover() })
    }
    override func viewDidHide() { super.viewDidHide(); dismissHover() }
    override func layout() {
        super.layout(); cells = []
        // Keep the same right-hand calendar anchor when resizing. Wide windows
        // reveal another half-year instead of stretching the gaps between days.
        let oldStart = startDate
        let oldGrid = gridRect, oldSize = tileSize
        visibleWeeks = bounds.width >= 980 ? 52 : 26
        startDate = calendar.date(byAdding: .weekOfYear, value: -(visibleWeeks - 1), to: lastSunday)!
        let available = max(1, bounds.width - 26)
        gap = min(5, max(2, floor(available / CGFloat(visibleWeeks) / 4)))
        tileSize = max(1, min(22, floor((available - CGFloat(visibleWeeks - 1) * gap) / CGFloat(visibleWeeks))))
        let pitch = tileSize + gap
        let gridWidth = CGFloat(visibleWeeks) * pitch - gap
        gridRect = NSRect(x: 26 + floor(max(0, available - gridWidth) / 2), y: 28,
                          width: gridWidth, height: 7 * pitch - gap)
        if oldGrid != gridRect || oldSize != tileSize || oldStart != startDate { dismissHover() }
        let desiredHeight = gridRect.maxY + 40
        if abs(heightConstraint.constant - desiredHeight) > 0.5 { heightConstraint.constant = desiredHeight }
        let firstKey = usage.days.keys.min()
        var descriptions: [String] = []
        for week in 0..<visibleWeeks {
            for weekday in 0..<7 {
                let date = calendar.date(byAdding: .day, value: week * 7 + weekday, to: startDate)!
                let key = DictationUsage.dayKey(for: date, calendar: calendar)
                let count = usage.days[key]?.characterCount ?? 0
                let enabled = count > 0 || (date <= today && firstKey.map { key >= $0 } == true)
                let rect = NSRect(x: gridRect.minX + CGFloat(week) * pitch, y: gridRect.minY + CGFloat(weekday) * pitch, width: tileSize, height: tileSize)
                cells.append(Cell(date: date, count: count, enabled: enabled, rect: rect))
                if count > 0, let cell = cells.last {
                    descriptions.append(tooltip(for: cell).replacingOccurrences(of: "\n", with: "，"))
                }
            }
        }
        if let hoveredDate, !cells.contains(where: { $0.date == hoveredDate }) { dismissHover() }
        setAccessibilityLabel("口述活跃日历，\(visibleWeeks) 周；颜色越深，当日口述字数越多")
        setAccessibilityValue(descriptions.isEmpty ? "所选日期没有口述记录" : descriptions.joined(separator: "；"))
        if oldStart != startDate { onRangeChange?(startDate, endDate) }
        needsDisplay = true
    }
    private func color(_ count: Int) -> NSColor {
        switch count {
        case ...0: return Palette.heatmapLevels[0]
        case 1...100: return Palette.heatmapLevels[1]
        case 101...500: return Palette.heatmapLevels[2]
        case 501...1500: return Palette.heatmapLevels[3]
        default: return Palette.heatmapLevels[4]
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true
    }
    func cell(at point: NSPoint) -> Cell? { cells.first { $0.rect.contains(point) } }
    override func updateTrackingAreas() {
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let cell = cell(at: point) else { leaveHover(gap: gridRect.contains(point)); return }
        guard cell.date != hoveredDate || exitingHover || (hoverCard == nil && pendingHover == nil) else { return }
        let wasExiting = exitingHover
        cancelPendingHover(); exitingHover = false
        hoveredDate = cell.date; needsDisplay = true
        if hoverCard != nil {
            // Keep the same layer as the user scans adjacent days. Updating
            // metrics and anchor together avoids a stale date following motion.
            showHover(for: cell, resuming: wasExiting)
        } else {
            let generation = hoverGeneration
            let pending = DispatchWorkItem { [weak self] in
                guard let self, self.hoverGeneration == generation, self.hoveredDate == cell.date else { return }
                self.pendingHover = nil
                self.showHover(for: cell)
            }
            pendingHover = pending
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: pending)
        }
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { leaveHover(gap: false) }
    private func showHover(for cell: Cell, resuming: Bool = false) {
        guard let root = window?.contentView else { return }
        let entering = hoverCard == nil
        let card = hoverCard ?? HeatmapDayHoverView(text: tooltip(for: cell))
        if !entering { card.update(text: tooltip(for: cell)) }
        let anchor = convert(cell.rect, to: root), safe = root.bounds.insetBy(dx: 12, dy: 12)
        var frame = card.frame
        frame.origin.x = min(max(safe.minX, anchor.midX - frame.width / 2), safe.maxX - frame.width)
        let above = root.isFlipped ? anchor.minY - frame.height - 9 : anchor.maxY + 9
        let below = root.isFlipped ? anchor.maxY + 9 : anchor.minY - frame.height - 9
        frame.origin.y = above >= safe.minY && above + frame.height <= safe.maxY ? above : below
        frame.origin.y = min(max(safe.minY, frame.minY), safe.maxY - frame.height)
        card.frame = frame.integral
        if entering { card.alphaValue = 0; root.addSubview(card, positioned: .above, relativeTo: nil) }
        hoverCard = card; hoveredDate = cell.date; needsDisplay = true
        if entering || resuming { DictationMotion.fade(card, to: 1, duration: 0.12) }
    }
    private func cancelPendingHover() {
        hoverGeneration &+= 1
        pendingHover?.cancel(); pendingHover = nil
        pendingExit?.cancel(); pendingExit = nil
    }
    private func leaveHover(gap: Bool) {
        guard !exitingHover else { return }
        cancelPendingHover(); exitingHover = true
        if hoveredDate != nil { hoveredDate = nil; needsDisplay = true }
        guard let card = hoverCard else { exitingHover = false; return }
        let generation = hoverGeneration
        let pending = DispatchWorkItem { [weak self, weak card] in
            guard let self, let card, self.hoverGeneration == generation else { return }
            self.pendingExit = nil
            DictationMotion.fade(card, to: 0, duration: 0.09) { [weak self, weak card] in
                guard let self, let card, self.hoverGeneration == generation, self.hoverCard === card else { return }
                card.removeFromSuperview(); self.hoverCard = nil; self.exitingHover = false
            }
        }
        pendingExit = pending
        if gap { DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: pending) }
        else { pending.perform() }
    }
    private func dismissHover() {
        cancelPendingHover(); exitingHover = false
        if let card = hoverCard { DictationMotion.cancel(card); card.removeFromSuperview() }
        hoverCard = nil
        if hoveredDate != nil { hoveredDate = nil; needsDisplay = true }
    }
    override func draw(_ dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: Palette.muted]
        for (row, name) in [(1, "一"), (3, "三"), (5, "五")] {
            let text = name as NSString
            text.draw(at: NSPoint(x: gridRect.minX - 24, y: gridRect.minY + CGFloat(row) * (tileSize + gap) + (tileSize - text.size(withAttributes: attributes).height) / 2), withAttributes: attributes)
        }
        // Month labels use the column containing its first day, including a
        // partial first month. Suppress a cramped label at the left boundary.
        var monthColumns: [Int: Int] = [:]
        if let first = cells.first { monthColumns[0] = calendar.component(.month, from: first.date) }
        for (index, cell) in cells.enumerated() where calendar.component(.day, from: cell.date) == 1 {
            monthColumns[index / 7] = calendar.component(.month, from: cell.date)
        }
        let months = monthColumns.keys.sorted()
        for (index, week) in months.enumerated() {
            let text = "\(monthColumns[week]!)月" as NSString
            let width = text.size(withAttributes: attributes).width
            let x = min(gridRect.maxX - width, gridRect.minX + CGFloat(week) * (tileSize + gap))
            if index + 1 < months.count && x + width + 8 > gridRect.minX + CGFloat(months[index + 1]) * (tileSize + gap) { continue }
            text.draw(at: NSPoint(x: x, y: 2), withAttributes: attributes)
        }
        for cell in cells {
            let radius = min(4, tileSize * 0.22)
            let tile = NSBezierPath(roundedRect: cell.rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
            let future = !cell.enabled && cell.date > today
            (cell.enabled ? color(cell.count) : future ? Palette.surface : Palette.heatmapUnavailable).setFill(); tile.fill()
            Palette.heatmapOutline.withAlphaComponent(cell.enabled ? 0.16 : 0.20).setStroke()
            tile.lineWidth = 0.5; tile.stroke()
            if !cell.enabled && !future {
                // Hatching means no data was collected. It must not look like
                // a measured zero, and future days remain simple outlines.
                NSGraphicsContext.saveGraphicsState(); tile.addClip()
                let stripes = NSBezierPath()
                for offset in stride(from: -tileSize, through: tileSize, by: 5) {
                    stripes.move(to: NSPoint(x: cell.rect.minX + offset, y: cell.rect.maxY))
                    stripes.line(to: NSPoint(x: cell.rect.minX + offset + tileSize, y: cell.rect.minY))
                }
                Palette.heatmapHatch.withAlphaComponent(0.45).setStroke()
                stripes.lineWidth = 0.6; stripes.stroke(); NSGraphicsContext.restoreGraphicsState()
            }
            if calendar.isDate(cell.date, inSameDayAs: today) || cell.date == hoveredDate {
                (cell.date == hoveredDate ? Palette.ink.withAlphaComponent(0.8) : Palette.blue.withAlphaComponent(0.75)).setStroke()
                let ring = NSBezierPath(roundedRect: cell.rect.insetBy(dx: -1, dy: -1), xRadius: radius + 1, yRadius: radius + 1)
                ring.lineWidth = cell.date == hoveredDate ? 1.5 : 1; ring.stroke()
            }
        }
        let legendY = gridRect.maxY + 19
        ("每日输出字数" as NSString).draw(at: NSPoint(x: gridRect.minX, y: legendY), withAttributes: attributes)
        let legendX = gridRect.maxX - 130
        ("少" as NSString).draw(at: NSPoint(x: legendX, y: legendY), withAttributes: attributes)
        for (index, value) in [0, 1, 101, 501, 1501].enumerated() {
            color(value).setFill(); NSBezierPath(roundedRect: NSRect(x: legendX + 20 + CGFloat(index) * 18, y: legendY, width: 12, height: 12), xRadius: 3, yRadius: 3).fill()
        }
        ("多" as NSString).draw(at: NSPoint(x: gridRect.maxX - 10, y: legendY), withAttributes: attributes)
    }
    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let cell = cell(at: point) else { return "" }
        return tooltip(for: cell)
    }
    private func tooltip(for cell: Cell) -> String {
        let key = DictationUsage.dayKey(for: cell.date, calendar: calendar)
        let date = DateFormatter(); date.locale = Locale(identifier: "zh_CN")
        date.calendar = calendar; date.timeZone = calendar.timeZone; date.dateFormat = "yyyy年M月d日 EEEE"
        let heading = date.string(from: cell.date)
        // Saved civil-day activity takes precedence over the current timezone's
        // calendar boundary, just as it does for the cell's color.
        if cell.count == 0 {
            if cell.date > today { return heading + "\n尚未到来" }
            if !cell.enabled { return heading + "\n尚未开始统计" }
        }
        let day = usage.days[key] ?? DictationUsageDay()
        let number = NumberFormatter(); number.numberStyle = .decimal
        func count(_ value: Int) -> String { number.string(from: NSNumber(value: value)) ?? String(value) }
        return "\(heading)\n转写次数：\(count(day.dictationCount)) 次\n输出字数：\(count(day.characterCount)) 字\n口述时长：\(duration(for: day))"
    }
    private func duration(for day: DictationUsageDay) -> String {
        if day.dictationCount == 0 { return "0 秒" }
        guard day.timedDictationCount > 0, day.audioSeconds.isFinite,
              day.audioSeconds > 0, day.audioSeconds < Double(Int.max) else { return "未记录" }
        let seconds = Int(day.audioSeconds)
        var parts: [String] = []
        if seconds >= 3600 { parts.append("\(seconds / 3600) 小时") }
        if seconds % 3600 >= 60 { parts.append("\(seconds % 3600 / 60) 分") }
        if seconds % 60 > 0 { parts.append("\(seconds % 60) 秒") }
        let value = parts.isEmpty ? "不足 1 秒" : parts.joined(separator: " ")
        // A partial recording sum must never look like the day's complete total.
        return day.timedDictationCount < day.dictationCount ? value + "（时长不全）" : value
    }
}
