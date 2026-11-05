import AppKit

/// Hidden production views, real control actions, and in-memory sample data.
/// No AppDelegate, microphone, clipboard, global shortcuts, or disk store is used.
@main
enum DictationInsightsChecks {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try condition() == false {
            throw NSError(domain: "DictationInsightsChecks", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    static func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.6 }

    static func descendants(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(descendants)
    }

    static func calendar() -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = .current
        return result
    }

    static func layout(_ root: NSView) {
        root.window?.layoutIfNeeded()
        root.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        for view in descendants(root) { view.layoutSubtreeIfNeeded() }
        for map in descendants(root).compactMap({ $0 as? DictationActivityHeatmap }) {
            map.needsLayout = true
            map.layoutSubtreeIfNeeded()
        }
    }

    static func heatmap(in root: NSView) throws -> DictationActivityHeatmap {
        let maps = descendants(root).compactMap { $0 as? DictationActivityHeatmap }
        try require(maps.count == 1, "Expected exactly one home heatmap, found \(maps.count)")
        return maps[0]
    }

    static func metric(_ index: Int, in root: NSView) throws -> NSView {
        let identifier = NSUserInterfaceItemIdentifier("insight-metric-\(index)")
        let matches = descendants(root).filter { $0.identifier == identifier }
        try require(matches.count == 1, "Missing or duplicate metric tile \(index)")
        return matches[0]
    }

    static func metricText(_ index: Int, in root: NSView) throws -> [String] {
        descendants(try metric(index, in: root)).compactMap { ($0 as? NSTextField)?.stringValue }
    }

    static func navigation(_ title: String, in root: NSView) throws -> SidebarNavigationButton {
        let buttons = descendants(root).compactMap { $0 as? SidebarNavigationButton }.filter { $0.title == title }
        try require(buttons.count == 1, "Missing or duplicate sidebar row \(title)")
        return buttons[0]
    }

    static func pager(_ title: String, in root: NSView) throws -> NSButton {
        let buttons = descendants(root).compactMap { $0 as? NSButton }.filter { $0.toolTip == title }
        try require(buttons.count == 1, "Missing or duplicate heatmap pager \(title)")
        return buttons[0]
    }

    static func checkRangeControls(_ map: DictationActivityHeatmap, usage: DictationUsage,
                                   in root: NSView, pageOffset: Int) throws {
        let ranges = descendants(root).compactMap { $0 as? NSTextField }
            .filter { $0.identifier?.rawValue == "activity-date-range" }
        try require(ranges.count == 1, "Missing visible heatmap range")
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy.MM.dd"
        let expected = formatter.string(from: map.startDate) + " – " + formatter.string(from: map.endDate)
        try require(ranges[0].stringValue == expected, "Range label retained a different column count or page")
        let firstKey = usage.days.keys.min()
        let hasOlder = firstKey.map { $0 < DictationUsage.dayKey(for: map.startDate) } ?? false
        try require((try pager("查看前 26 周", in: root)).isEnabled == hasOlder,
                    "Previous availability does not reflect the displayed start date")
        try require((try pager("查看后 26 周", in: root)).isEnabled == (pageOffset > 0),
                    "Next availability does not reflect the current page")
    }

    static func add(_ store: DictationStore, text: String, at date: Date, audio: Double? = 30) {
        store.add(rawText: "嗯，" + text, text: text, asrSeconds: 0.2, cleanupSeconds: 0.1,
                  totalSeconds: 0.3, audioSeconds: audio, cleanupApplied: true, warning: nil,
                  createdAt: date)
    }

    static func checkSidebar(in root: NSView, width: CGFloat) throws {
        let rows = descendants(root).compactMap { $0 as? SidebarNavigationButton }
        try require(rows.count == 5, "Expected all five sidebar actions at width \(width)")
        let symbols = rows.map { $0.symbolView.convert($0.symbolView.bounds, to: root) }
        let labels = rows.map { $0.textLabel.convert($0.textLabel.bounds, to: root) }
        let labelAlignment = rows.map { $0.convert($0.textLabel.alignmentRect(forFrame: $0.textLabel.frame), to: root) }
        let frames = rows.map { $0.convert($0.bounds, to: root) }
        for index in rows.indices {
            try require(near(symbols[index].minX, symbols[0].minX) &&
                        near(labels[index].minX, labels[0].minX),
                        "Sidebar icon/text column moved for \(rows[index].title) at width \(width)")
            try require(near(symbols[index].width, 20) && near(symbols[index].height, 20),
                        "Sidebar icon box is not 20×20 for \(rows[index].title): converted=\(symbols[index]), frame=\(rows[index].symbolView.frame), bounds=\(rows[index].symbolView.bounds), alignment=\(rows[index].symbolView.alignmentRect(forFrame: rows[index].symbolView.frame)), insets=\(rows[index].symbolView.alignmentRectInsets), row=\(frames[index]), window=\(String(describing: root.window?.frame))")
            try require(near(symbols[index].midY, frames[index].midY) &&
                        near(labelAlignment[index].midY, frames[index].midY),
                        "Sidebar icon or text is not vertically centered for \(rows[index].title)")
            // Native label frames include text-cell insets; spacing constraints
            // apply to the label's alignment rectangle, which tracks its text.
            try require(near(labelAlignment[index].minX - symbols[index].maxX, 12),
                        "Sidebar icon/text gap changed for \(rows[index].title)")
            try require(near(frames[index].minX, frames[0].minX) &&
                        near(frames[index].width, frames[0].width) && near(frames[index].height, 46),
                        "Sidebar selection rectangles do not share bounds")
            try require(!rows[index].hasAmbiguousLayout && !rows[index].symbolView.hasAmbiguousLayout &&
                        !rows[index].textLabel.hasAmbiguousLayout,
                        "Sidebar has ambiguous constraints for \(rows[index].title)")
        }
        for title in ["历史记录", "个人词典", "设置", "首页"] {
            let row = try navigation(title, in: root)
            row.performClick(nil)
            layout(root)
            let selected = rows.filter { $0.selected && $0.state == .on }
            try require(selected.count == 1 && selected[0] === row,
                        "Real sidebar action did not select exactly \(title)")
            if title == "首页" {
                _ = try metric(0, in: root)
            } else {
                try require(!descendants(root).contains { $0.identifier?.rawValue == "insight-metric-0" },
                            "Sidebar action changed selection without replacing home content")
            }
        }
    }

    static func checkMetricGrid(in root: NSView, width: CGFloat) throws {
        let tiles = try (0..<4).map { try metric($0, in: root) }
        let frames = tiles.map { $0.convert($0.bounds, to: root) }
        try require(frames.allSatisfy { $0.width > 250 && $0.height > 50 }, "Metric tile collapsed at width \(width)")
        // An odd number of physical pixels cannot split evenly across two
        // columns. AppKit assigns that one pixel to a column on a 1x display.
        let pixel = 1 / (root.window?.backingScaleFactor ?? 1)
        try require(frames.allSatisfy { abs($0.width - frames[0].width) <= pixel + 0.001 },
                    "Metric tiles have unequal widths at window \(width), scale \(root.window?.backingScaleFactor ?? 1): \(frames)")
        try require(near(frames[0].width, frames[2].width) && near(frames[1].width, frames[3].width),
                    "Metric widths differ within the same column")
        try require(near(frames[0].minY, frames[1].minY) && near(frames[2].minY, frames[3].minY) &&
                    near(frames[0].minX, frames[2].minX) && near(frames[1].minX, frames[3].minX),
                    "Metrics do not form aligned 2×2 rows/columns")
        try require(frames[0].maxX < frames[1].minX && frames[2].maxX < frames[3].minX,
                    "Metric row has no horizontal gap")
        for left in frames.indices {
            for right in frames.indices where left < right {
                try require(frames[left].intersection(frames[right]).isEmpty,
                            "Metric tiles overlap at width \(width): \(left), \(right)")
            }
            try require(frames[left].minX >= 0 && frames[left].maxX <= root.bounds.width + 0.6,
                        "Metric tile escapes the content width")
            try require(!tiles[left].hasAmbiguousLayout, "Metric tile has ambiguous layout")
            for label in descendants(tiles[left]).compactMap({ $0 as? NSTextField }) {
                let bounds = label.convert(label.bounds, to: tiles[left])
                try require(bounds.minX >= -0.6 && bounds.maxX <= tiles[left].bounds.width + 0.6,
                            "Metric text escapes its tile")
            }
        }
    }

    static func checkHeatmap(_ map: DictationActivityHeatmap, usage: DictationUsage, now: Date) throws {
        let calendar = calendar()
        let today = calendar.startOfDay(for: now)
        let firstKey = usage.days.keys.min()
        let expectedWeeks = map.bounds.width >= 980 ? 52 : 26
        try require(map.visibleWeeks == expectedWeeks && map.cells.count == expectedWeeks * 7,
                    "Heatmap column count does not match its available width")
        try require(map.cells.first?.date == map.startDate && map.cells.last?.date == map.endDate,
                    "Heatmap cells do not cover its displayed range")
        for (index, cell) in map.cells.enumerated() {
            let key = DictationUsage.dayKey(for: cell.date, calendar: calendar)
            try require(cell.count == (usage.days[key]?.characterCount ?? 0), "Heatmap invented or lost daily characters")
            if index > 0 {
                try require(calendar.date(byAdding: .day, value: 1, to: map.cells[index - 1].date) == cell.date,
                            "Heatmap skipped/repeated a calendar day")
            }
            if cell.count == 0 && (cell.date > today || firstKey == nil || key < firstKey!) {
                try require(!cell.enabled, "Future/pre-collection cell appears active")
            }
            if cell.count > 0 { try require(cell.enabled, "Recorded activity was hidden by calendar gating") }
            try require(near(cell.rect.width, cell.rect.height) && cell.rect.width <= 22.6 && cell.rect.width >= 12,
                        "Heatmap tile is distorted or excessively large/small")
            try require(cell.rect.minX >= 0 && cell.rect.maxX <= map.bounds.width + 0.6 &&
                        cell.rect.minY >= 0 && cell.rect.maxY <= map.bounds.height + 0.6,
                        "Heatmap cell escapes the rendered bounds")
            for prior in map.cells.prefix(index) {
                try require(prior.rect.intersection(cell.rect).isEmpty, "Heatmap cells overlap")
            }
            let center = NSPoint(x: cell.rect.midX, y: cell.rect.midY)
            try require(map.cell(at: center)?.date == cell.date, "Drawn cell center selects a different date")
        }
        let first = map.cells[0], below = map.cells[1], right = map.cells[7]
        let horizontalGap = right.rect.minX - first.rect.maxX
        let verticalGap = below.rect.minY - first.rect.maxY
        try require(horizontalGap > 0 && horizontalGap <= 5.6 && near(horizontalGap, verticalGap),
                    "Grid stretches horizontal spacing independently of vertical spacing")
        let gaps = [NSPoint(x: (first.rect.maxX + right.rect.minX) / 2, y: first.rect.midY),
                    NSPoint(x: first.rect.midX, y: (first.rect.maxY + below.rect.minY) / 2)]
        for gap in gaps {
            try require(map.cell(at: gap) == nil, "Gap incorrectly selects a neighboring day")
            try require(map.view(map, stringForToolTip: 0, point: gap, userData: nil).isEmpty,
                        "Gap displays a neighboring day's tooltip")
        }
        try require(map.cell(at: NSPoint(x: -1, y: -1)) == nil, "Outside pointer selects a date")
    }

    static func checkCalendarTravel() throws {
        let local = calendar()
        let now = local.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 12))!
        let localKey = DictationUsage.dayKey(for: now, calendar: local)
        // Simulate a record made in a different timezone without changing the
        // process timezone or the user's system settings. One extreme always
        // yields a different civil day for this same absolute instant.
        let previousCalendars = [-12, 14].map { hours -> Calendar in
            var value = Calendar(identifier: .gregorian)
            value.timeZone = TimeZone(secondsFromGMT: hours * 3600)!
            return value
        }
        guard let sourceCalendar = previousCalendars.first(where: { DictationUsage.dayKey(for: now, calendar: $0) != localKey }) else {
            throw NSError(domain: "DictationInsightsChecks", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Travel fixture failed to cross a civil-day boundary"])
        }
        var usage = DictationUsage()
        let entry = DictationEntry(id: UUID(), createdAt: now, rawText: "旅行口述", text: "旅行口述",
                                   asrSeconds: 0.2, cleanupSeconds: 0.1, totalSeconds: 0.3,
                                   audioSeconds: 2, cleanupApplied: true, warning: nil)
        usage.record(entry, calendar: sourceCalendar)
        let recordedKey = usage.days.keys.first!
        let map = DictationActivityHeatmap(usage: usage, now: now)
        map.setFrameSize(NSSize(width: 720, height: 300)); map.needsLayout = true; map.layoutSubtreeIfNeeded()
        try checkHeatmap(map, usage: usage, now: now)
        guard let cell = map.cells.first(where: { DictationUsage.dayKey(for: $0.date, calendar: local) == recordedKey }) else {
            throw NSError(domain: "DictationInsightsChecks", code: 3)
        }
        try require(cell.enabled && cell.count == 4, "Timezone shift hid a recorded day")
        let tip = map.view(map, stringForToolTip: 0, point: NSPoint(x: cell.rect.midX, y: cell.rect.midY), userData: nil)
        try require(tip.contains("4 字") && !tip.contains("尚未"), "Recorded day tooltip was replaced by a calendar placeholder")

        let empty = DictationActivityHeatmap(usage: DictationUsage(), now: now)
        empty.setFrameSize(NSSize(width: 720, height: 300)); empty.needsLayout = true; empty.layoutSubtreeIfNeeded()
        try checkHeatmap(empty, usage: DictationUsage(), now: now)
        try require(empty.cells.allSatisfy { !$0.enabled && $0.count == 0 }, "Empty heatmap fabricated activity")
        let past = empty.cells.first!
        let future = empty.cells.last!
        func tooltip(_ cell: DictationActivityHeatmap.Cell) -> String {
            empty.view(empty, stringForToolTip: 0, point: NSPoint(x: cell.rect.midX, y: cell.rect.midY), userData: nil)
        }
        try require(tooltip(past).contains("尚未开始统计"), "Pre-collection day lost its distinct tooltip")
        try require(tooltip(future).contains("尚未到来"), "Future day is shown as measured zero usage")
    }

    static func checkWindow(width: CGFloat, height: CGFloat) throws {
        let now = Date(), calendar = calendar()
        let store = DictationStore(memoryOnly: true)
        let old = calendar.date(byAdding: .day, value: -400, to: now)!
        add(store, text: String(repeating: "旧日口述", count: 20), at: old)
        add(store, text: String(repeating: "今日口述", count: 30), at: now)
        let controller = DictationWindowController(store: store, sessionStartedAt: now)
        guard let window = controller.window, let root = window.contentView else {
            throw NSError(domain: "DictationInsightsChecks", code: 4)
        }
        defer { window.close() }
        store.onChange = { [weak controller] in controller?.reloadStore() }
        window.setContentSize(NSSize(width: width, height: height))
        var state = DictationUIState()
        state.preview = true; state.serviceReady = true; state.canStart = true
        state.shortcutDisplay = "⌥⌘V"; state.functionKeySelected = false
        state.microphoneAllowed = true; state.accessibilityAllowed = true
        state.serviceMessage = "识别和整理都在本机完成"
        controller.updateState(state)
        layout(root)
        try require(!window.isVisible && near(root.bounds.width, width), "Fixture window visible or wrong width")
        try checkSidebar(in: root, width: width)
        try checkMetricGrid(in: root, width: width)
        var current = try heatmap(in: root)
        try checkHeatmap(current, usage: store.usage, now: now)
        try require(current.cells.filter { $0.count > 0 }.count == 1, "Latest range should show today's fixture only")
        let initialStart = current.startDate, initialEnd = current.endDate
        try require((try metricText(0, in: root)).contains("200 字"), "Metric does not show aggregate character total")
        let previous = try pager("查看前 26 周", in: root)
        let next = try pager("查看后 26 周", in: root)
        try require(previous.isEnabled && !next.isEnabled, "Initial pagination availability incorrect")
        try checkRangeControls(current, usage: store.usage, in: root, pageOffset: 0)
        var offset = 0
        while (try pager("查看前 26 周", in: root)).isEnabled {
            let priorStart = current.startDate, priorEnd = current.endDate
            (try pager("查看前 26 周", in: root)).performClick(nil); layout(root)
            offset += 1
            try require(offset <= 3, "Previous paging did not stop at the oldest data")
            current = try heatmap(in: root)
            try checkHeatmap(current, usage: store.usage, now: now)
            try require(calendar.date(byAdding: .day, value: -182, to: priorStart) == current.startDate &&
                        calendar.date(byAdding: .day, value: -182, to: priorEnd) == current.endDate,
                        "Previous page did not move exactly 26 weeks")
            try checkRangeControls(current, usage: store.usage, in: root, pageOffset: offset)
        }
        try require(current.cells.contains { $0.count == 80 }, "Oldest page omitted the 400-day-old fixture")
        try require(!(try pager("查看前 26 周", in: root)).isEnabled && (try pager("查看后 26 周", in: root)).isEnabled,
                    "Oldest page pagination availability incorrect")
        while offset > 0 {
            (try pager("查看后 26 周", in: root)).performClick(nil); layout(root)
            offset -= 1; current = try heatmap(in: root)
            try checkRangeControls(current, usage: store.usage, in: root, pageOffset: offset)
        }
        try require(current.startDate == initialStart && current.endDate == initialEnd &&
                    !(try pager("查看后 26 周", in: root)).isEnabled, "Next-page action did not restore the latest range")

        store.clearUsage(); layout(root)
        try require((try metricText(0, in: root)).contains("0 字") &&
                    (try metricText(1, in: root)).contains("0 秒") &&
                    (try metricText(2, in: root)).contains("—") &&
                    (try metricText(3, in: root)).contains("0 秒"), "Empty metric values do not match data semantics")
        try require(store.entries.count == 2, "Clearing aggregate fixture deleted its transcript history")
        add(store, text: "缺失时长", at: now, audio: nil); layout(root)
        try require((try metricText(0, in: root)).contains("4 字") &&
                    (try metricText(1, in: root)).contains("—") &&
                    (try metricText(2, in: root)).contains("—") &&
                    (try metricText(3, in: root)).contains("—"), "Unknown duration was displayed as measured data")
        try checkMetricGrid(in: root, width: width)
        try require(!window.isVisible && store.storageError == nil, "UI checks escaped invisible memory-only mode")
    }

    static func checkTooltipData() throws {
        let calendar = calendar()
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 12))!
        let partialDate = calendar.date(byAdding: .day, value: -3, to: now)!
        let zeroDate = calendar.date(byAdding: .day, value: -2, to: now)!
        let unknownDate = calendar.date(byAdding: .day, value: -1, to: now)!
        var usage = DictationUsage()
        usage.days[DictationUsage.dayKey(for: partialDate)] = DictationUsageDay(
            characterCount: 64, dictationCount: 2, audioSeconds: 61, timedDictationCount: 1)
        usage.days[DictationUsage.dayKey(for: unknownDate)] = DictationUsageDay(
            characterCount: 16, dictationCount: 1)
        usage.days[DictationUsage.dayKey(for: now)] = DictationUsageDay(
            characterCount: 96, dictationCount: 3, audioSeconds: 3661, timedDictationCount: 3)
        for width in [CGFloat(720), CGFloat(1120)] {
            let map = DictationActivityHeatmap(usage: usage, now: now)
            map.setFrameSize(NSSize(width: width, height: 300)); map.needsLayout = true; map.layoutSubtreeIfNeeded()
            func tip(_ date: Date) throws -> String {
                guard let cell = map.cells.first(where: { calendar.isDate($0.date, inSameDayAs: date) }) else {
                    throw NSError(domain: "DictationInsightsChecks", code: 6)
                }
                return map.view(map, stringForToolTip: 0, point: NSPoint(x: cell.rect.midX, y: cell.rect.midY), userData: nil)
            }
            let complete = try tip(now)
            try require(complete.components(separatedBy: "\n").count == 4 &&
                        complete.contains("转写次数：3 次") && complete.contains("口述时长：1 小时 1 分 1 秒") &&
                        complete.contains("输出字数：96 字"), "Tooltip no longer reports the saved three metrics")
            try require(try tip(partialDate).contains("口述时长：1 分 1 秒（时长不全）"),
                        "Partial duration looks like a complete daily measurement")
            try require(try tip(unknownDate).contains("口述时长：未记录"), "Missing duration was invented")
            let zero = try tip(zeroDate)
            try require(zero.contains("转写次数：0 次") && zero.contains("口述时长：0 秒") &&
                        zero.contains("输出字数：0 字") && !zero.contains("尚未"),
                        "Collected zero-use day was confused with an unavailable day")
        }
    }

    static func checkResizeRange() throws {
        let now = Date(), calendar = calendar(), store = DictationStore(memoryOnly: true)
        add(store, text: "半年之前", at: calendar.date(byAdding: .day, value: -200, to: now)!)
        add(store, text: "今日口述", at: now)
        let controller = DictationWindowController(store: store, sessionStartedAt: now)
        guard let window = controller.window, let root = window.contentView else {
            throw NSError(domain: "DictationInsightsChecks", code: 5)
        }
        defer { window.close() }
        var expectedEnd: Date?
        // Resize the existing view, not a newly constructed page: this catches
        // stale range labels, pager state, hover geometry, and calendar anchors.
        for width in [1000, 1400, 1800, 1400, 1000] {
            window.setContentSize(NSSize(width: width, height: 820)); layout(root)
            let map = try heatmap(in: root)
            try checkHeatmap(map, usage: store.usage, now: now)
            try checkRangeControls(map, usage: store.usage, in: root, pageOffset: 0)
            if let expectedEnd { try require(map.endDate == expectedEnd, "Resize moved the calendar's end date") }
            else { expectedEnd = map.endDate }
            try require(map.cells.filter { $0.count > 0 }.count == (map.visibleWeeks == 52 ? 2 : 1),
                        "Resize omitted a visible recorded day or invented data")
        }
        (try pager("查看前 26 周", in: root)).performClick(nil); layout(root)
        let shiftedEnd = try heatmap(in: root).endDate
        for width in [1800, 1000] {
            window.setContentSize(NSSize(width: width, height: 820)); layout(root)
            let map = try heatmap(in: root)
            try require(map.endDate == shiftedEnd, "Resize reset a browsed page to today")
            try checkRangeControls(map, usage: store.usage, in: root, pageOffset: 1)
            try checkHeatmap(map, usage: store.usage, now: now)
        }
        try require(!window.isVisible, "Resize check showed a production-looking window")
    }

    static func main() {
        do {
            NSApplication.shared.setActivationPolicy(.prohibited)
            try checkWindow(width: 1100, height: 820)
            try checkWindow(width: 1000, height: 700)
            try checkWindow(width: 1400, height: 820)
            try checkWindow(width: 1800, height: 820)
            try checkResizeRange()
            try checkCalendarTravel()
            try checkTooltipData()
            print("PASS: hidden AppKit at 1000/1100/1400/1800 widths; sidebar and metric alignment; responsive 182/364 consecutive calendar days; square tiles/equal gaps; gap hit-testing; live resize keeps page anchor, range label and pager state; precise 182-day paging; no invented future/pre-collection activity; timezone civil-day preservation; empty and unknown-duration display.")
            print("LIMIT: memory-only fixtures and invisible production views; no user data, microphone, clipboard, service, global shortcut, permission, or destructive-confirmation action was accessed.")
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
