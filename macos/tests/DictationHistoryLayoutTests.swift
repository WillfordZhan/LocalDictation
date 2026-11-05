import AppKit

/// Exercises the actual history controls in a hidden, memory-only application.
/// AppDelegate is not linked, so no recording, service, permissions, or disk
/// history are reached by these geometry and independent-scroll checks.
@main
enum DictationHistoryLayoutChecks {
    static var fixtureScrollerStyle: NSScroller.Style = .legacy

    struct Measurement {
        let count: Int
        let documentHeight: CGFloat
        let bodyHeight: CGFloat
        let transcriptHeight: CGFloat?
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw NSError(domain: "DictationHistoryLayoutChecks", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    static func near(_ left: CGFloat, _ right: CGFloat) -> Bool { abs(left - right) < 0.8 }

    static func descendants(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(descendants)
    }

    static func identified(_ name: String, in root: NSView) throws -> NSView {
        let matches = descendants(root).filter { $0.identifier?.rawValue == name }
        try require(matches.count == 1, "Expected one \(name), found \(matches.count)")
        return matches[0]
    }

    static func layout(_ root: NSView) {
        // System “automatic” scrollers can switch from overlay to legacy after
        // app initialization/input-device events. Fix this fixture dimension,
        // like its window size, so a 17pt platform style change cannot be
        // mistaken for movement caused by scrolling the inner history list.
        let scrolls = descendants(root).compactMap { $0 as? NSScrollView }
        scrolls.forEach { $0.scrollerStyle = fixtureScrollerStyle }
        root.window?.layoutIfNeeded()
        root.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        // Resolve AppKit's queued preference notification and tile the hidden
        // scroll views under the selected style before taking measurements.
        scrolls.forEach { $0.scrollerStyle = fixtureScrollerStyle; $0.tile() }
        root.window?.layoutIfNeeded()
        root.layoutSubtreeIfNeeded()
        for view in descendants(root) { view.layoutSubtreeIfNeeded() }
    }

    static func check(count: Int, width: CGFloat, height: CGFloat) throws -> Measurement {
        let store = DictationStore(memoryOnly: true)
        let now = Date()
        for index in 0..<count {
            store.add(rawText: "测试原文 \(index)", text: "短句 \(index)",
                      asrSeconds: 0.2, cleanupSeconds: 0.1, totalSeconds: 0.3,
                      audioSeconds: 2, cleanupApplied: true, warning: nil,
                      createdAt: now.addingTimeInterval(-Double(index) * 60))
        }
        let controller = DictationWindowController(store: store, sessionStartedAt: now)
        guard let window = controller.window, let root = window.contentView else {
            throw NSError(domain: "DictationHistoryLayoutChecks", code: 2)
        }
        defer { window.close() }
        store.onChange = { [weak controller] in controller?.reloadStore() }
        window.setContentSize(NSSize(width: width, height: height))
        var state = DictationUIState()
        state.serviceReady = true; state.serviceMessage = "内存界面验证"
        state.functionKeySelected = false; state.shortcutDisplay = "⌥⌘V"
        state.microphoneAllowed = true; state.accessibilityAllowed = true
        controller.updateState(state)
        guard let historyAction = descendants(root).compactMap({ $0 as? SidebarNavigationButton }).first(where: { $0.title == "历史记录" }) else {
            throw NSError(domain: "DictationHistoryLayoutChecks", code: 3)
        }
        historyAction.performClick(nil)
        layout(root)
        guard let outer = root.subviews.compactMap({ $0 as? NSScrollView }).first,
              let document = outer.documentView else {
            throw NSError(domain: "DictationHistoryLayoutChecks", code: 4)
        }
        let body = try identified("history-body", in: document)
        let listPane = try identified("history-list-pane", in: body)
        let detailPane = try identified("history-detail-pane", in: body)
        guard let listScroll = descendants(listPane).compactMap({ $0 as? NSScrollView }).first,
              let listDocument = listScroll.documentView else {
            throw NSError(domain: "DictationHistoryLayoutChecks", code: 5)
        }
        try require(descendants(root).compactMap { $0 as? NSScrollView }.allSatisfy { $0.scrollerStyle == fixtureScrollerStyle },
                    "Fixture scrollers did not use the selected platform style")
        let bodyRect = body.convert(body.bounds, to: document)
        let listRect = listPane.convert(listPane.bounds, to: document)
        let detailRect = detailPane.convert(detailPane.bounds, to: document)
        let transcript = descendants(detailPane).first { $0.identifier?.rawValue == "history-transcript" } as? NSScrollView
        let transcriptHeight = transcript?.bounds.height
        let bottomGap = document.bounds.maxY - bodyRect.maxY
        let geometry: [String: Any] = [
            "content": "\(Int(width))×\(Int(height))", "records": count, "scrollerStyle": fixtureScrollerStyle.rawValue,
            "viewportHeight": outer.contentView.bounds.height,
            "documentHeight": document.bounds.height,
            "body": NSStringFromRect(bodyRect), "listPane": NSStringFromRect(listRect),
            "detailPane": NSStringFromRect(detailRect), "bottomGap": bottomGap,
            "listViewportHeight": listScroll.contentView.bounds.height,
            "listDocumentHeight": listDocument.bounds.height,
            "ambiguousBody": body.hasAmbiguousLayout,
            "ambiguousListPane": listPane.hasAmbiguousLayout,
            "ambiguousDetailPane": detailPane.hasAmbiguousLayout,
            "transcriptHeight": transcriptHeight.map { $0 as Any } ?? NSNull()
        ]
        let encoded = try JSONSerialization.data(withJSONObject: geometry, options: [.sortedKeys])
        print("GEOMETRY " + String(decoding: encoded, as: UTF8.self))
        try require(!window.isVisible && store.storageDirectory == nil && !store.hasUnsavedHistory,
                    "History layout fixture escaped hidden memory-only mode")
        try require(near(root.bounds.width, width) && near(root.bounds.height, height), "Wrong content fixture dimensions")
        try require(near(listRect.height, bodyRect.height) && near(detailRect.height, bodyRect.height) &&
                    near(listRect.minY, bodyRect.minY) && near(detailRect.minY, bodyRect.minY),
                    "History list/detail panes are not equally tall and top-aligned with the body")
        try require(near(bodyRect.minX, 32) && near(document.bounds.maxX - bodyRect.maxX, 32),
                    "History body does not fill the document width with 32-point margins")
        try require(near(listRect.minX, bodyRect.minX) && near(detailRect.maxX, bodyRect.maxX) &&
                    near(detailRect.minX - listRect.maxX, 16),
                    "History panes do not fill the body from left to right")
        try require(near(bottomGap, 32), "History body bottom is not 32 points above the document bottom")
        try require(near(document.bounds.height, outer.contentView.bounds.height),
                    "History document is shorter or taller than its viewport")
        let paginationHeight: CGFloat = count > 20 ? 36 : 0
        try require(near(listScroll.convert(listScroll.bounds, to: listPane).height, listPane.bounds.height - 24 - paginationHeight),
                    "Independent list scroll view does not fill its pane")
        let ambiguous = [body, listPane, detailPane].filter { $0.hasAmbiguousLayout }
        if !ambiguous.isEmpty {
            for view in ambiguous { view.exerciseAmbiguityInLayout() }
            layout(root)
            let changedBody = body.convert(body.bounds, to: document)
            let changedList = listPane.convert(listPane.bounds, to: document)
            let changedDetail = detailPane.convert(detailPane.bounds, to: document)
            print("AMBIGUITY after exercise: body=\(changedBody), list=\(changedList), detail=\(changedDetail), documentHeight=\(document.bounds.height)")
        }
        try require(ambiguous.isEmpty, "History panes have ambiguous Auto Layout geometry")
        try require(store.entries.count == count, "History layout pruned records")

        if count > 0 {
            guard let transcript, let text = transcript.documentView as? NSTextView else {
                throw NSError(domain: "DictationHistoryLayoutChecks", code: 6)
            }
            let transcriptRect = transcript.convert(transcript.bounds, to: detailPane)
            try require(text.string.count < 40, "Short-transcript fixture unexpectedly contains long content")
            try require(transcript.bounds.height > 120 && transcript.bounds.height > detailPane.bounds.height * 0.45,
                        "Short transcript stayed at its minimum height instead of filling the detail pane")
            try require(near(transcriptRect.minX, 18) && near(detailPane.bounds.width - transcriptRect.maxX, 18),
                        "Transcript scroll view does not span the detail content width")
            let rows = descendants(listDocument).compactMap { $0 as? NSButton }
            try require(rows.count == min(count, 20), "History page did not bound its rendered rows")
        } else {
            try require(transcript == nil, "Empty history retained a stale transcript editor")
            let labels = descendants(detailPane).compactMap { ($0 as? NSTextField)?.stringValue }
            try require(labels.contains("留住每一次清楚的表达。"), "Empty detail message is missing")
        }

        if count > 200 {
            try require(listDocument.bounds.height > listScroll.contentView.bounds.height + 100,
                        "Long history list did not create independently scrollable content")
            let outerOrigin = outer.contentView.bounds.origin
            let detailBefore = detailPane.convert(detailPane.bounds, to: document)
            listScroll.contentView.scroll(to: NSPoint(x: 0, y: 500))
            listScroll.reflectScrolledClipView(listScroll.contentView)
            layout(root)
            try require(listScroll.contentView.bounds.origin.y > 100,
                        "Actual inner list clip view did not scroll")
            try require(outer.contentView.bounds.origin == outerOrigin,
                        "Scrolling the history list moved the whole page")
            let detailAfter = detailPane.convert(detailPane.bounds, to: document)
            try require(detailAfter == detailBefore && near(document.bounds.height, outer.contentView.bounds.height),
                        "List scrolling moved the detail pane or expanded the outer document")
        }
        if count > 0, let segment = descendants(detailPane).compactMap({ $0 as? NSSegmentedControl }).first {
            segment.selectedSegment = 2
            try require(segment.sendAction(segment.action!, to: segment.target), "Comparison action failed")
            layout(root)
            let comparison = try identified("history-transcript", in: detailPane) as! NSScrollView
            let text = comparison.documentView as! NSTextView
            try require(text.string.contains("ASR 原文\n测试原文 0") && text.string.contains("整理结果\n短句 0"), "Both stored versions must be visible in comparison")
            try require(near(comparison.bounds.height, transcriptHeight!) && near(document.bounds.height, outer.contentView.bounds.height), "Comparison shrank history or overflowed the viewport")
        }
        return Measurement(count: count, documentHeight: document.bounds.height,
                           bodyHeight: bodyRect.height, transcriptHeight: transcriptHeight)
    }

    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var failed = false
        for style in [NSScroller.Style.overlay, .legacy] {
            fixtureScrollerStyle = style
            var byWidth: [Int: [Measurement]] = [:]
            for (width, height) in [(CGFloat(1100), CGFloat(820)), (CGFloat(1000), CGFloat(700))] {
                for count in [1, 251, 0] {
                    do { byWidth[Int(width), default: []].append(try check(count: count, width: width, height: height)) }
                    catch {
                        failed = true
                        fputs("FAIL: \(Int(width))×\(Int(height)), \(count) records: \(error.localizedDescription)\n", stderr)
                    }
                }
            }
            do {
                for measurements in byWidth.values where measurements.count == 3 {
                    try require(measurements.allSatisfy { near($0.documentHeight, measurements[0].documentHeight) && near($0.bodyHeight, measurements[0].bodyHeight) },
                                "Record count changed the outer document or history body height")
                }
                if let large = byWidth[1100]?.first(where: { $0.count == 1 })?.transcriptHeight,
                   let small = byWidth[1000]?.first(where: { $0.count == 1 })?.transcriptHeight {
                    try require(large - small > 100, "Short transcript did not grow with the available window height")
                }
            } catch { failed = true; fputs("FAIL: \(error.localizedDescription)\n", stderr) }
        }
        if failed { exit(1) }
        print("PASS: hidden AppKit history in overlay/legacy scroller styles at 1100×820 and 1000×700, with 1/251/0 records; equal-height full-width panes; compact pagination only for multiple pages; 32-point document bottom inset; viewport-sized outer document; independently scrolling current page; short transcript expands with window height; all permanent records retained.")
        print("LIMIT: synthetic in-memory history and invisible production views; no production files, recording, services, clipboard, or destructive confirmation was accessed.")
    }
}
