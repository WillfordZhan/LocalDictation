import AppKit

/// Real history controls with memory-only records; no AppDelegate, model,
/// microphone, clipboard or user history is reachable from this executable.
@main
enum HistoryPaginationChecks {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "HistoryPaginationChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
    static func identified(_ name: String, in root: NSView) -> NSView? {
        descendants(root).first { $0.identifier?.rawValue == name }
    }
    static func rows(_ root: NSView) -> [NSButton] {
        descendants(root).compactMap { $0 as? NSButton }.filter { $0.identifier?.rawValue.hasPrefix("history-row-") == true }
    }
    static func layout(_ root: NSView) {
        root.window?.layoutIfNeeded(); root.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        root.layoutSubtreeIfNeeded()
    }
    static func click(_ identifier: String, in root: NSView) throws {
        guard let button = identified(identifier, in: root) as? NSButton else {
            throw NSError(domain: "HistoryPaginationChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing \(identifier)"])
        }
        try require(button.isEnabled, "Disabled action \(identifier)")
        button.performClick(nil); layout(root)
    }
    static func search(_ text: String, in root: NSView) throws {
        let search = descendants(root).compactMap { $0 as? NSSearchField }.first!
        search.stringValue = text
        search.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: search))
        layout(root)
    }
    static func transcript(_ root: NSView) -> String {
        ((identified("history-transcript", in: root) as? NSScrollView)?.documentView as? NSTextView)?.string ?? ""
    }
    static func pageLabel(_ root: NSView) -> String? {
        (identified("history-page-number", in: root) as? NSTextField)?.stringValue
    }
    @discardableResult
    static func add(_ store: DictationStore, text: String, raw: String? = nil, date: Date) -> DictationEntry {
        store.add(rawText: raw ?? text, text: text, asrSeconds: 0.2, cleanupSeconds: 0.1,
                  totalSeconds: 0.3, audioSeconds: 2, cleanupApplied: true, warning: nil, createdAt: date)
    }
    static func boundaryChecks() throws {
        for width in [CGFloat(1000), CGFloat(1800)] {
            for count in [20, 21, 41] {
                let store = DictationStore(memoryOnly: true), now = Date()
                for index in 0..<count { add(store, text: "边界记录 \(index)", date: now.addingTimeInterval(-Double(index))) }
                let controller = DictationWindowController(store: store, sessionStartedAt: now)
                let window = controller.window!, root = window.contentView!
                defer { window.close() }
                store.onChange = { [weak controller] in controller?.reloadStore() }
                window.setContentSize(NSSize(width: width, height: 700))
                controller.showPage(.history); layout(root)
                try require(rows(root).count == 20, "Initial boundary page exceeds 20 records at \(count)/\(width)")
                if count == 20 {
                    try require(pageLabel(root) == nil, "Exactly 20 records showed a redundant pager")
                    continue
                }
                let expectedPages = count == 21 ? 2 : 3
                for _ in 1..<expectedPages { try click("history-page-next", in: root) }
                try require(rows(root).count == 1 && pageLabel(root) == "\(expectedPages) / \(expectedPages)",
                            "Boundary final page is not a single record")
                let selected = store.entries.last!
                let profile = DictationCleanupProfile(versionID: "fixture", name: "本地测试", contentSHA256: "fixture", modelID: "fixture")
                let revision = store.addRevision(entryID: selected.id, text: "另一个整理结果", cleanupSeconds: 0.1, cleanupProfile: profile)
                layout(root)
                try require(revision != nil && rows(root).count == 1 && transcript(root) == selected.text,
                            "Saving an alternate revision changed the visible page or original output")
                store.delete(id: selected.id); layout(root)
                try require(rows(root).count == 20 && transcript(root) == store.entries[(expectedPages - 2) * 20].text,
                            "Deleting a one-record last page selected an unavailable transcript")
                try require(pageLabel(root) == (count == 21 ? nil : "2 / 2"), "One-record final page did not collapse")
                let pane = identified("history-list-pane", in: root)!
                try require(abs(pane.bounds.width - 238) < 1 && !pane.hasAmbiguousLayout,
                            "Pagination changed list width or made its layout ambiguous")
            }
        }
    }
    static func run() throws {
        let store = DictationStore(memoryOnly: true), now = Date()
        for index in 0..<43 {
            add(store, text: "历史测试 \(index)", raw: index == 42 ? "只在原文中的远处关键词" : nil,
                date: now.addingTimeInterval(-Double(index)))
        }
        let original = store.entries
        let controller = DictationWindowController(store: store, sessionStartedAt: now)
        let window = controller.window!, root = window.contentView!
        defer { window.close() }
        store.onChange = { [weak controller] in controller?.reloadStore() }
        controller.showPage(.history); layout(root)
        try require(rows(root).count == 20 && pageLabel(root) == "1 / 3", "Opening history rendered more than one page")
        try require(transcript(root) == original[0].text, "First page selected the wrong transcript")
        try require((identified("history-page-previous", in: root) as! NSButton).isEnabled == false, "First page permits previous")
        let pager = identified("history-pagination", in: root)!
        try require(abs(pager.bounds.height - 28) < 1 && pager.bounds.width < 240, "Pager is not a compact footer")
        let listPane = identified("history-list-pane", in: root)!
        let pagerRect = pager.convert(pager.bounds, to: listPane)
        try require(abs(pagerRect.maxY - (listPane.bounds.height - 12)) < 1, "Pager does not sit at the list bottom")
        let listScroll = descendants(listPane).compactMap { $0 as? NSScrollView }.first!
        listScroll.contentView.scroll(to: NSPoint(x: 0, y: 500))
        listScroll.reflectScrolledClipView(listScroll.contentView); layout(root)
        try require(listScroll.contentView.bounds.origin.y > 100, "Scroll-reset fixture did not scroll")
        try click("history-page-next", in: root)
        try require(rows(root).count == 20 && pageLabel(root) == "2 / 3" && transcript(root) == original[20].text,
                    "Next page does not update rows and detail together")
        try require(abs(listScroll.contentView.bounds.origin.y) < 1, "Page change left the next page scrolled halfway down")
        try click("history-page-next", in: root)
        try require(rows(root).count == 3 && pageLabel(root) == "3 / 3" && transcript(root) == original[40].text,
                    "Last page has wrong row slice")
        try require((identified("history-page-next", in: root) as! NSButton).isEnabled == false, "Last page permits next")
        try click("history-page-previous", in: root)
        try click("history-row-\(original[39].id.uuidString)", in: root)
        add(store, text: "新到的记录", date: now.addingTimeInterval(1)); layout(root)
        try require(pageLabel(root) == "3 / 3" && transcript(root) == original[39].text,
                    "A new recording lost the selected transcript at a page boundary")
        try require(rows(root).contains { $0.identifier?.rawValue == "history-row-\(original[39].id.uuidString)" },
                    "Selected detail is outside the displayed page after insertion")
        try search("远处关键词", in: root)
        try require(rows(root).count == 1 && transcript(root) == original[42].text, "Search was restricted to the current page or final output")
        try require(identified("history-pagination", in: root) == nil, "One search result reserves pagination space")
        try search("完全没有这个词", in: root)
        try require(rows(root).isEmpty && transcript(root).isEmpty && pageLabel(root) == nil, "Empty search retained stale page/detail")
        try search("", in: root)
        try require(pageLabel(root) == "1 / 3" && rows(root).count == 20 && transcript(root) == "新到的记录",
                    "Clearing search did not reset to the first page")
        try require(store.entries.count == 44 && original.allSatisfy { before in
            store.entries.contains { $0.id == before.id && $0.rawText == before.rawText && $0.text == before.text }
        }, "Pagination/search changed persistent record content")
        try click("history-page-next", in: root); try click("history-page-next", in: root)
        // Deletion arrives through the same store callback as the real detail
        // delete action. Removing a whole final page must clamp selection/page.
        for entry in original[39...] { store.delete(id: entry.id) }
        layout(root)
        try require(store.entries.count == 40 && pageLabel(root) == "2 / 2" && rows(root).count == 20,
                    "Deleting the last page did not fall back to the preceding page")
        try require(transcript(root) == store.entries[20].text, "Deletion fallback retained an invisible detail selection")
        store.removeAll(); layout(root)
        try require(rows(root).isEmpty && pageLabel(root) == nil && transcript(root).isEmpty, "Clearing history retained page state")
        add(store, text: "清空后的新记录", date: now); layout(root)
        try require(rows(root).count == 1 && pageLabel(root) == nil && transcript(root) == "清空后的新记录",
                    "A new single record did not reopen on the first page")
        try require(!window.isVisible && store.storageDirectory == nil, "Pagination fixture touched visible or persistent user state")
        if let index = CommandLine.arguments.firstIndex(of: "--render"), CommandLine.arguments.indices.contains(index + 1) {
            for item in 0..<42 { add(store, text: "语音输入需求 \(item + 1)", date: now.addingTimeInterval(Double(item + 1))) }
            layout(root)
            try controller.renderPNG(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
        print("PASS: 20-row history pages; 28pt footer only when needed; first/last button bounds; detail/page synchronization; new-record boundary retention; full-history raw-text search; empty search; final-page deletion fallback; clear/repopulate; original records preserved.")
    }
    static func latestNavigationChecks() throws {
        let store = DictationStore(memoryOnly: true), now = Date()
        for index in 0..<25 {
            add(store, text: "Earlier record \(index)", date: now.addingTimeInterval(-Double(index)))
        }
        let controller = DictationWindowController(store: store, sessionStartedAt: now)
        let window = controller.window!, root = window.contentView!
        defer { window.close() }
        store.onChange = { [weak controller] in controller?.reloadStore() }
        controller.showPage(.history); layout(root)
        // Automatic initial selection must not silently turn into a reading
        // anchor and move history backwards as background recordings arrive.
        for index in 1...20 {
            add(store, text: "New recording \(index)", date: now.addingTimeInterval(Double(index)))
        }
        layout(root)
        try require(pageLabel(root) == "1 / 3" && transcript(root) == "New recording 20",
                    "Default latest history drifted to an old page after new recordings: page=\(pageLabel(root) ?? "none")")
        try require(rows(root).first?.identifier?.rawValue == "history-row-\(store.entries[0].id.uuidString)",
                    "The newest stored recording is not the first visible history row")
        let reading = store.entries[0]
        try click("history-row-\(reading.id.uuidString)", in: root)
        add(store, text: "New recording 21", date: now.addingTimeInterval(21)); layout(root)
        try require(transcript(root) == reading.text,
                    "Clicking the currently selected latest row did not protect active reading")
        try require((identified("history-latest", in: root) as? NSButton)?.isHidden == false,
                    "Active reading has no compact path back to latest")
        try click("history-latest", in: root)
        try require(pageLabel(root) == "1 / 3" && transcript(root) == "New recording 21",
                    "Latest action did not resume following new records")
        try click("history-page-next", in: root)
        controller.showPage(.home); controller.showPage(.history); layout(root)
        try require(pageLabel(root) == "1 / 3" && transcript(root) == "New recording 21",
                    "Explicit navigation back to history kept an old-page reading anchor")
        try search("Earlier record", in: root)
        controller.showPage(.history); layout(root)
        let searchField = descendants(root).compactMap { $0 as? NSSearchField }.first!
        try require(searchField.stringValue.isEmpty && transcript(root) == "New recording 21",
                    "Explicit history navigation retained a stale search filter")
        try search("No matching record", in: root)
        try require(rows(root).isEmpty, "Empty-search recovery fixture is not empty")
        try click("history-latest", in: root)
        try require(transcript(root) == "New recording 21" && searchField.stringValue.isEmpty,
                    "Latest action failed to recover from an empty filtered page")
        try click("history-page-next", in: root)
        controller.returnToLatestHistoryIfVisible(); layout(root)
        try require(pageLabel(root) == "1 / 3" && transcript(root) == "New recording 21",
                    "Reopening a history window retained its stale page")
        controller.showPage(.dictionary); layout(root)
        controller.returnToLatestHistoryIfVisible(); layout(root)
        try require(identified("history-list-pane", in: root) == nil &&
                    descendants(root).compactMap { $0 as? SidebarNavigationButton }.contains { $0.title == "个人词典" && $0.selected },
                    "Reopening another page unexpectedly switched to history")
        try require(store.entries.count == 46 && !window.isVisible && store.storageDirectory == nil,
                    "Latest-history fixture mutated stored history or showed a window")
        print("PASS: latest history follows new recordings without page drift; explicit reading remains pinned with compact latest action; navigation/reopen clears old page and search; empty search recovers; other pages stay open.")
    }
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do {
            try run(); try boundaryChecks(); try latestNavigationChecks()
            print("PASS: exact 20/21/41-record boundaries at 1000px/1800px; selected record survives reprocessing; deleting the only last-page record collapses or removes pager.")
        } catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
}
