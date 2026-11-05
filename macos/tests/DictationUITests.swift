import AppKit

/// Runs the shipped views in an invisible, nonactivating test process. All
/// persistence and copy callbacks are local fixtures; no AppDelegate is linked.
@main
enum DictationUIChecks {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "DictationUIChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func descendants(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(descendants)
    }

    static func button(_ title: String, in root: NSView) throws -> NSButton {
        let matches = descendants(root).compactMap { $0 as? NSButton }.filter { $0.title == title }
        try require(matches.count == 1, "Expected one button: \(title); found \(matches.count)")
        return matches[0]
    }

    static func control<T: NSControl>(_ type: T.Type, beside title: String, in root: NSView) throws -> T {
        let labels = descendants(root).compactMap { $0 as? NSTextField }.filter { !$0.isEditable && $0.stringValue == title }
        for label in labels {
            var parent = label.superview
            while let current = parent, current !== root {
                let controls = descendants(current).compactMap { $0 as? T }
                if controls.count == 1 { return controls[0] }
                parent = current.superview
            }
        }
        throw NSError(domain: "DictationUIChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing control beside \(title)"])
    }

    static func click(_ title: String, in root: NSView) throws {
        let target = try button(title, in: root)
        try require(target.isEnabled, "Button disabled: \(title)")
        target.performClick(nil)
    }

    static func sendAction(_ control: NSControl) throws {
        guard let action = control.action else { throw NSError(domain: "DictationUIChecks", code: 3) }
        try require(control.sendAction(action, to: control.target), "Control did not route its action")
    }

    static func edit(_ field: NSTextField, text: String) {
        field.stringValue = text
        // NSTextField's delegate receives the same notification emitted by its
        // field editor. Do not call the controller's private action methods.
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
    }

    static func containsText(_ text: String, in root: NSView) -> Bool {
        descendants(root).contains {
            ($0 as? NSTextField)?.stringValue == text || ($0 as? NSTextView)?.string == text
        }
    }
    static func luminance(_ color: NSColor) -> CGFloat {
        let rgb = color.usingColorSpace(.sRGB)!
        let linear = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map {
            $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4)
        }
        return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
    }
    static func captureHistory(_ controller: DictationWindowController) throws {
        guard let index = CommandLine.arguments.firstIndex(of: "--render"), CommandLine.arguments.indices.contains(index + 1),
              let window = controller.window else { return }
        let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = window.contentView!.frame.size
        defer { window.setContentSize(original) }
        let until = Date().addingTimeInterval(0.18)
        while Date() < until { RunLoop.current.run(until: min(until, Date().addingTimeInterval(0.01))) }
        for size in [NSSize(width: 1000, height: 668), NSSize(width: 1400, height: 900)] {
            window.setContentSize(size); window.contentView?.layoutSubtreeIfNeeded()
            try controller.renderPNG(to: directory.appendingPathComponent("history-feedback-\(Int(size.width))x\(Int(size.height)).png"))
        }
    }

    static func learningChecks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-learning-ui-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DictationStore(directory: directory)
        let controller = DictationWindowController(store: store, sessionStartedAt: Date())
        let root = controller.window!.contentView!
        defer { controller.window?.close() }
        store.onChange = { [weak controller] in controller?.reloadStore() }
        let unsupported = "当前应用无法读取输入框，暂不支持自动学习。"
        controller.updateCorrectionLearning(status: unsupported)
        try require(!containsText(unsupported, in: root), "Learning status leaked outside the dictionary page")
        controller.showPage(.dictionary)
        try require(containsText(unsupported, in: root), "Unreadable-input limitation was hidden")
        let initialToggle = try control(NSSwitch.self, beside: "自动学习术语", in: root)
        try require(initialToggle.state == .on && store.preferences.automaticVocabularyLearning, "Learning is not enabled by default")
        let input = descendants(root).compactMap { $0 as? NSTextField }.first { $0.isEditable }!
        edit(input, text: "未提交词条")
        controller.updateCorrectionLearning(status: "正在留意术语纠错。")
        try require(input.superview != nil && input.stringValue == "未提交词条", "Learning status rebuilt the active dictionary editor")
        let add = try button("添加", in: root)
        try require(add.isEnabled, "Status update reset pending dictionary input")
        initialToggle.performClick(nil)
        try require(!store.preferences.automaticVocabularyLearning && containsText("自动学习已关闭。", in: root), "Switch did not turn learning off")
        try require(!DictationStore(directory: directory).preferences.automaticVocabularyLearning, "Learning toggle was not persisted")
        controller.updateCorrectionLearning(status: "正在留意术语纠错。")
        try require(containsText("自动学习已关闭。", in: root), "Runtime update overrode the disabled preference")
        try control(NSSwitch.self, beside: "自动学习术语", in: root).performClick(nil)
        try require(store.preferences.automaticVocabularyLearning && containsText("正在留意术语纠错。", in: root), "Enabling did not restore current learning status")

        store.updatePreferences { $0.vocabulary = ["BOM"] }
        let entryID = UUID()
        let first = store.learnVocabulary(original: "SalesPrat", corrected: "SalesPart", entryID: entryID, bundleID: "fixture.editor")!
        let second = store.learnVocabulary(original: "这是一个较长但仍属于术语的识别结果", corrected: "ProductPart", entryID: entryID, bundleID: nil)!
        let rejected = store.learnVocabulary(original: "RejectedPrat", corrected: "RejectedPart", entryID: entryID, bundleID: nil)!
        store.undoLearnedVocabulary(id: rejected.id)
        // A restored older origin must not displace the newest active origin.
        let older = DictationLearnedVocabulary(id: UUID(), original: "OldSpelling", corrected: "SalesPart",
            createdAt: first.createdAt.addingTimeInterval(-100), bundleID: nil, entryID: entryID)
        store.updatePreferences { $0.learnedVocabulary.insert(older, at: 0) }
        try require(containsText("SalesPrat → SalesPart", in: root), "Learned correction does not show its origin")
        try require(!containsText("OldSpelling → SalesPart", in: root), "Older learned origin replaced the newest one")
        try require(!containsText("RejectedPart", in: root) && !containsText("RejectedPrat → RejectedPart", in: root), "Undone learning remained a dictionary row")
        let beforeHistory = store.entries.count
        var output: URL?
        if let i = CommandLine.arguments.firstIndex(of: "--render"), CommandLine.arguments.indices.contains(i + 1) {
            output = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            try FileManager.default.createDirectory(at: output!, withIntermediateDirectories: true)
        }
        DictationMotion.cancel(descendants(root).first { $0.identifier?.rawValue == "dictation-page-stack" }!)
        for width in [CGFloat(1000), CGFloat(1500)] {
            controller.window?.setContentSize(NSSize(width: width, height: 760)); root.layoutSubtreeIfNeeded()
            let rows = descendants(root).filter { $0.identifier?.rawValue == "vocabulary-row" }
            try require(rows.count == 3, "Learning created duplicate or undone dictionary rows")
            var rightEdges: [CGFloat] = []
            for row in rows {
                let action = descendants(row).compactMap { $0 as? NSButton }.first!
                let text = row.subviews.compactMap { $0 as? NSTextField }.first!
                let textRect = text.alignmentRect(forFrame: text.frame)
                let actionRect = action.alignmentRect(forFrame: action.frame)
                // Auto Layout constrains the alignment rect. Native button
                // bezels extend their drawing frames differently across macOS.
                try require(abs(actionRect.width - 64) < 1 && textRect.maxX <= actionRect.minX - 11,
                            "Learning action stretches or overlaps correction text: frame=\(action.frame), alignment=\(actionRect)")
                rightEdges.append(row.convert(actionRect, to: root).maxX)
            }
            try require(rightEdges.max()! - rightEdges.min()! < 1, "Learned and manual actions do not share a right edge")
            if let output { try controller.renderPNG(to: output.appendingPathComponent("dictionary-learning-\(Int(width)).png")) }
        }
        let undoID = "undo-vocabulary-\(second.id.uuidString)"
        let undo = descendants(root).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == undoID }!
        undo.performClick(nil)
        try require(store.preferences.learnedVocabulary.first { $0.id == second.id }?.undone == true, "Undo button did not call the learned-word store operation")
        try require(!store.preferences.vocabulary.contains("ProductPart") && !containsText("ProductPart", in: root), "Undo left the learned word as an ordinary row")
        try require(store.entries.count == beforeHistory, "Vocabulary undo mutated dictation history")
        store.updatePreferences { $0.vocabulary.append("ProductPart") }
        let manualRow = descendants(root).first { $0.identifier?.rawValue == "vocabulary-row" && containsText("ProductPart", in: $0) }!
        let manualDelete = try button("删除", in: manualRow)
        try require(manualDelete.isEnabled, "A later manual addition reused an undone learning origin")
        controller.showPage(.home)
        try require(!descendants(root).contains { $0.identifier?.rawValue == "correction-learning-status" }, "Learning status is displayed outside dictionary")
        try require(controller.window?.isVisible == false, "Learning fixture unexpectedly displayed its window")

        let toast = DictationLearningToast()
        let panel = Mirror(reflecting: toast).children.first { $0.label == "panel" }!.value as! NSPanel
        let toastRoot = panel.contentView!
        var actions = 0
        let visibleFrame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        toast.show(term: "SalesPart", showWindow: false, visibleFrame: visibleFrame) { actions += 1 }
        try require(!panel.canBecomeKey && !panel.canBecomeMain && !panel.isVisible && panel.styleMask.contains(.nonactivatingPanel), "Learning toast can steal input focus")
        try require(containsText("已学会 SalesPart", in: toastRoot), "Learning notice includes the wrong term")
        try require(panel.frame.minY > 700 && panel.frame.maxX <= visibleFrame.maxX, "Learning toast overlaps the bottom dictation stack or screen edge")
        if let output { try toast.renderPNG(to: output.appendingPathComponent("learning-toast.png")) }
        let toastUndo = try button("撤销", in: toastRoot)
        try require(toastUndo.acceptsFirstMouse(for: nil), "Undo needs a focus-acquiring first click")
        toastUndo.performClick(nil); toastUndo.performClick(nil)
        try require(actions == 1 && !toastUndo.isEnabled, "Learning toast undo executed more than once")

        // Deadlines and replaced notices must release their callbacks. None of
        // these checks displays a window or touches the destination application.
        var oldActions = 0
        weak var oldCapture: NSObject?
        do {
            let token = NSObject(); oldCapture = token
            toast.show(term: "OldTerm", showWindow: false, visibleFrame: visibleFrame) { [token] in
                withExtendedLifetime(token) { oldActions += 1 }
            }
        }
        try require(oldCapture != nil, "Callback fixture was not retained")
        toast.show(term: "NewTerm", showWindow: false, visibleFrame: visibleFrame) { actions += 1 }
        try require(oldCapture == nil, "Replacement retained the old callback capture")
        toastUndo.performClick(nil)
        try require(oldActions == 0 && actions == 2, "Replacement notice retained the old undo action")
        weak var closedCapture: NSObject?
        do {
            let token = NSObject(); closedCapture = token
            toast.show(term: "ClosedTerm", showWindow: false, visibleFrame: visibleFrame) { [token] in
                withExtendedLifetime(token) { actions += 1 }
            }
        }
        let close = descendants(toastRoot).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "learning-toast-dismiss" }!
        close.performClick(nil); toastUndo.performClick(nil)
        try require(actions == 2 && !toastUndo.isEnabled && closedCapture == nil, "Closing a learning notice retained an active undo action")
        weak var expiredCapture: NSObject?
        do {
            let token = NSObject(); expiredCapture = token
            toast.show(term: String(repeating: "长术语", count: 20), showWindow: false,
                       visibleFrame: NSRect(x: 0, y: 0, width: 320, height: 700)) { [token] in
                withExtendedLifetime(token) { actions += 1 }
            }
        }
        toastRoot.layoutSubtreeIfNeeded()
        try require(panel.frame.minX >= 16 && panel.frame.maxX <= 304, "Long learning notice overflows a narrow display")
        let toastText = descendants(toastRoot).compactMap { $0 as? NSTextField }.first!
        try require(toastText.frame.maxX < toastUndo.frame.minX, "Long learning term overlaps undo button")
        if let output { try toast.renderPNG(to: output.appendingPathComponent("learning-toast-long.png")) }
        let expires = Date().addingTimeInterval(5.15)
        while Date() < expires { RunLoop.current.run(until: min(expires, Date().addingTimeInterval(0.02))) }
        toastUndo.performClick(nil)
        try require(actions == 2 && !toastUndo.isEnabled && !panel.isVisible && expiredCapture == nil, "Expired learning toast retained an action or visible panel")
        toast.hide()
        print("PASS: automatic learning defaults/persistence; truthful app capability status without editor rebuild; newest active origin; compact aligned undo; undone/manual separation; independent nonactivating learning toast; one-shot undo, replacement, close and five-second expiry.")
    }

    @discardableResult
    static func fixture(_ store: DictationStore, raw: String, text: String) -> DictationEntry {
        store.add(rawText: raw, text: text, asrSeconds: 0.2, cleanupSeconds: 0.1,
                  totalSeconds: 0.3, audioSeconds: 2, cleanupApplied: true, warning: nil)
    }

    static func main() {
        do { try run() }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }

    static func run() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        DictationMotion.reduceMotionOverride = false
        defer { DictationMotion.reduceMotionOverride = nil }
        for foreground in [Palette.muted, Palette.blue, Palette.warning] {
            for background in [NSColor.white, Palette.sidebar, Palette.blueWash] {
                let ratio = (luminance(background) + 0.05) / (luminance(foreground) + 0.05)
                try require(ratio >= 4.5, "Small UI text contrast below 4.5:1: \(ratio)")
            }
        }
        let store = DictationStore(memoryOnly: true)
        let controller = DictationWindowController(store: store, sessionStartedAt: Date())
        guard let root = controller.window?.contentView else { throw NSError(domain: "DictationUIChecks", code: 4) }
        defer { controller.window?.close() }
        store.onChange = { [weak controller] in controller?.reloadStore() }
        var copies: [String] = []
        controller.onCopyText = { copies.append($0) }
        var state = DictationUIState()
        state.preview = true
        state.serviceReady = true
        state.canStart = true
        controller.updateState(state)
        try require(controller.window?.isVisible == false, "Test window must remain invisible")

        // Fn readiness is independent of the transient service/status line.
        state.shortcutDisplay = "⌃⌥⌘Space"
        state.functionKeySelected = true
        state.functionKeyEnabled = false
        state.shortcutWarning = "Fn 未启用，请允许输入监控。备用组合：⌃⌥⌘Space"
        controller.updateState(state)
        var permissionRequests = 0
        controller.onInputMonitoring = { permissionRequests += 1 }
        try require(containsText(state.shortcutWarning, in: root), "Home omitted the Fn availability reason")
        let homePermission = try button("启用 Fn…", in: root)
        try click("启用 Fn…", in: root)
        try require(permissionRequests == 1, "Home permission action did not route its callback")
        state.status = "服务已恢复"
        controller.updateState(state)
        try require(containsText(state.shortcutWarning, in: root), "Service recovery hid the independent shortcut reason")
        state.canEditShortcut = false
        controller.updateState(state)
        try require(!homePermission.isEnabled, "Permission action remained enabled while busy")
        state.canEditShortcut = true
        state.inputMonitoringAllowed = true
        controller.updateState(state)
        try click("重新检查 Fn", in: root)
        try require(permissionRequests == 2, "Permission recheck action did not route its callback")
        state.functionKeyEnabled = true
        state.shortcutDisplay = "Fn"
        state.shortcutWarning = ""
        controller.updateState(state)
        try require(homePermission.isHiddenOrHasHiddenAncestor, "Fn enabled should hide its setup action")
        state.functionKeySelected = false
        state.functionKeyEnabled = false
        state.shortcutDisplay = "⌃⌥⌘Space"
        controller.updateState(state)
        try require(homePermission.isHiddenOrHasHiddenAncestor, "Custom combination should not ask for Fn permission")
        try click("快捷键设置…", in: root)
        try require(containsText("快捷键", in: root), "Home shortcut settings link did not navigate")

        // Switching pages resets the outer viewport, including when the user
        // came from lower settings. Updating live status does not navigate.
        root.layoutSubtreeIfNeeded()
        guard let outerScroll = root.subviews.compactMap({ $0 as? NSScrollView }).first,
              let document = outerScroll.documentView else { throw NSError(domain: "DictationUIChecks", code: 8) }
        document.scroll(NSPoint(x: 0, y: 350))
        let scrolled = outerScroll.contentView.bounds.origin.y
        try require(scrolled > 0, "Scroll fixture did not reach lower settings")
        controller.updateState(state)
        try require(outerScroll.contentView.bounds.origin.y == scrolled, "Live status reset the user's scroll")
        controller.reloadStore(); root.layoutSubtreeIfNeeded()
        try require(outerScroll.contentView.bounds.origin.y == scrolled, "Background reload reset the user's scroll")
        let pageStack = descendants(root).first { $0.identifier?.rawValue == "dictation-page-stack" }!
        try require(pageStack.alphaValue == 1, "Background reload started a navigation fade")
        try click("首页", in: root)
        try require(abs(outerScroll.contentView.bounds.origin.y) < 1, "Navigation retained the previous page's scroll")
        try require(pageStack.alphaValue < 1, "Explicit navigation omitted the local content transition")
        let initialAlpha = pageStack.alphaValue
        controller.updateState(state)
        try require(pageStack.alphaValue == initialAlpha, "Live status restarted the navigation transition")

        var insertionPermissionRequests = 0
        controller.onAccessibility = { insertionPermissionRequests += 1 }
        state.autoInsertEnabled = true; state.accessibilityAllowed = false
        controller.updateState(state)
        let insertionPermission = try button("允许自动填入…", in: root)
        try require(!insertionPermission.isHiddenOrHasHiddenAncestor, "Missing auto-insert permission should be actionable on Home")
        try click("允许自动填入…", in: root)
        try require(insertionPermissionRequests == 1, "Home insertion permission action did not route")
        state.canEditShortcut = false; controller.updateState(state)
        try require(!insertionPermission.isEnabled, "Insertion permission action should be disabled while busy")
        state.canEditShortcut = true; state.accessibilityAllowed = true; controller.updateState(state)
        try require(insertionPermission.isHiddenOrHasHiddenAncestor, "Granted insertion permission should hide setup")
        state.accessibilityAllowed = false; state.autoInsertEnabled = false; controller.updateState(state)
        try require(insertionPermission.isHiddenOrHasHiddenAncestor, "Copy-only mode should not ask for insertion permission")

        // Sidebar navigation and text editing use the actual shipped controls.
        try click("个人词典", in: root)
        guard let input = descendants(root).compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable && !($0 is NSSearchField) }) else {
            throw NSError(domain: "DictationUIChecks", code: 5)
        }
        edit(input, text: "  UI验证术语  ")
        try click("添加", in: root)
        try require(store.preferences.vocabulary == ["UI验证术语"], "Dictionary add did not update store")
        try require(containsText("UI验证术语", in: root), "Dictionary did not render added term")
        try click("删除", in: root)
        try require(store.preferences.vocabulary.isEmpty, "Dictionary delete did not update store")

        try click("设置", in: root)
        var setupRequests = 0
        controller.onSetup = { setupRequests += 1 }
        try click("模型与配置…", in: root)
        try require(setupRequests == 1, "Model setup action did not route its callback")
        try require(descendants(root).contains { $0 is ShortcutCapturePresentationView }, "Shortcut presentation was not connected to Settings")
        let cleanup = try control(NSSwitch.self, beside: "文字整理", in: root)
        cleanup.performClick(nil)
        try require(!store.preferences.cleanupEnabled, "Cleanup switch did not update preferences")
        let autoInsert = try control(NSSwitch.self, beside: "自动填入原输入框", in: root)
        autoInsert.performClick(nil)
        try require(!store.preferences.autoInsertEnabled, "Auto-insert switch did not update preferences")
        let language = try control(NSPopUpButton.self, beside: "识别语言", in: root)
        language.selectItem(withTag: 1)
        try sendAction(language)
        try require(store.preferences.recognitionLanguage == "auto", "Language popup did not update preferences")

        let first = fixture(store, raw: "嗯，第一条原文。", text: "第一条输出。")
        let second = fixture(store, raw: "那个，第二条原文。", text: "第二条输出。")
        try click("历史记录", in: root)
        try require(containsText(second.text, in: root), "History did not initially select newest entry")
        guard let firstRow = descendants(root).compactMap({ $0 as? NSButton }).first(where: { $0.title.hasSuffix("\n" + first.text) }) else {
            throw NSError(domain: "DictationUIChecks", code: 6)
        }
        firstRow.performClick(nil)
        try require(containsText(first.text, in: root), "History row did not change detail")
        let selectedRow = descendants(root).compactMap { $0 as? NSButton }.first { $0.title.hasSuffix("\n" + first.text) }!
        let rowLabels = descendants(selectedRow).compactMap { $0 as? NSTextField }
        try require(rowLabels.count == 2 && rowLabels[0].font?.pointSize == 11 && rowLabels[1].font?.pointSize == 13, "History row lost date/summary hierarchy")
        try require(selectedRow.frame.height == 58 || selectedRow.constraints.contains { $0.firstAttribute == .height && $0.constant == 58 }, "History row height changed")
        try captureHistory(controller)
        let segments = descendants(root).compactMap { $0 as? NSSegmentedControl }
        try require(segments.count == 1, "Expected output/raw segments")
        segments[0].selectedSegment = 1
        try sendAction(segments[0])
        try require(containsText(first.rawText, in: root), "Raw segment did not display original transcript")
        try click("复制文字", in: root)
        try require(copies == [first.rawText], "Copy callback returned wrong history version")
        let compareSegments = descendants(root).compactMap { $0 as? NSSegmentedControl }.first!
        try require(compareSegments.segmentCount == 3 && compareSegments.label(forSegment: 2) == "对照", "History comparison tab missing")
        compareSegments.selectedSegment = 2
        try sendAction(compareSegments)
        let pair = "ASR 原文\n\(first.rawText)\n\n整理结果\n\(first.text)"
        try require(containsText(pair, in: root), "Comparison changed or omitted a stored result")
        try click("复制对照", in: root)
        try require(copies.count == 2 && copies.last!.contains(pair) && copies.last!.contains("已整理") && copies.last!.contains("识别 0.20 秒"), "Comparison copy omitted text, status or timing")
        let restoredSegments = descendants(root).compactMap { $0 as? NSSegmentedControl }.first!
        restoredSegments.selectedSegment = 1
        try sendAction(restoredSegments)
        try require(store.entries.count == 2, "History selection/copy mutated records")
        try click("删除这条记录", in: root)
        try require(store.entries.map(\.id) == [second.id], "History delete removed wrong entry")
        try require(!containsText(first.rawText, in: root), "Deleted text remained in visible detail")

        guard let search = descendants(root).compactMap({ $0 as? NSSearchField }).first else {
            throw NSError(domain: "DictationUIChecks", code: 7)
        }
        edit(search, text: "不存在的词")
        try require(containsText("没有匹配的记录", in: root), "History search did not filter list")
        edit(search, text: "第二条")
        try require(containsText(second.rawText, in: root), "History search did not match available entry")
        try click("删除这条记录", in: root)
        try require(store.entries.isEmpty, "Deleting final record did not empty store")
        let clearHistory = try button("清空历史", in: root)
        try require(!clearHistory.isEnabled, "Empty healthy history should not enable clear")
        let currentSearch = descendants(root).compactMap { $0 as? NSSearchField }.first!
        edit(currentSearch, text: "")

        try click("首页", in: root)
        try require(containsText("下一次口述，会从这里开始。", in: root), "Home retained deleted results")
        try require(!containsText(first.text, in: root) && !containsText(second.text, in: root), "Deleted text remained on home")

        // Two equal fields can mean fallback, disabled editing or a successful
        // no-op edit. Preserve the saved status instead of guessing from text.
        for (applied, warning, expected) in [(false, Optional("文字整理未完成，已保留原始转写。"), "整理未完成，已保留原文"), (false, nil, "未应用整理"), (true, nil, "已整理")] {
            let entry = store.add(rawText: "保留原文", text: "保留原文", asrSeconds: 0.2, cleanupSeconds: 0,
                totalSeconds: 0.2, audioSeconds: 2, cleanupApplied: applied, warning: warning)
            try click("历史记录", in: root)
            let segment = descendants(root).compactMap { $0 as? NSSegmentedControl }.first!
            segment.selectedSegment = 2; try sendAction(segment)
            try click("复制对照", in: root)
            try require(copies.last!.contains(expected), "Comparison fabricated processing state")
            try require(copies.last!.contains(applied ? "整理结果\n保留原文" : "最终输出（未整理）\n保留原文"), "Fallback shown as model output")
            store.delete(id: entry.id)
        }

        try click("个人词典", in: root)
        store.updatePreferences { $0.vocabulary = ["BOM", "SalesPart", "一个用于验证长词条布局的名称"] }
        for width in [CGFloat(1000), CGFloat(1800)] {
            controller.window?.setContentSize(NSSize(width: width, height: 820))
            controller.window?.layoutIfNeeded(); root.layoutSubtreeIfNeeded()
            let rows = descendants(root).filter { $0.identifier?.rawValue == "vocabulary-row" }
            try require(rows.count == 3, "Dictionary rows missing")
            var rightEdges: [CGFloat] = []
            for row in rows {
                let remove = try button("删除", in: row)
                let text = row.subviews.compactMap { $0 as? NSTextField }.first!
                // Labels and native button bezels both have drawing insets.
                // Compare the alignment rectangles used by stack constraints.
                let textRect = text.alignmentRect(forFrame: text.frame)
                let removeRect = remove.alignmentRect(forFrame: remove.frame)
                try require(abs(removeRect.width - 64) < 1,
                            "Delete button stretches with window: frame=\(remove.frame), alignment=\(removeRect)")
                try require(abs(removeRect.maxX - row.bounds.maxX) < 1 && abs(textRect.minX) < 1, "Dictionary row alignment drifted")
                try require(textRect.maxX <= removeRect.minX - 11, "Term overlaps delete button")
                rightEdges.append(row.convert(removeRect, to: root).maxX)
            }
            try require((rightEdges.max()! - rightEdges.min()!) < 1, "Delete buttons do not share right edge")
        }
        try require(controller.window?.isVisible == false, "UI checks unexpectedly showed a window")
        try require(store.storageError == nil, "Unexpected memory-only storage error")
        try learningChecks()
        print("PASS: invisible AppKit controls; independent Fn readiness and permission callbacks; navigation scroll reset; sidebar navigation; dictionary edit/add/delete; cleanup and auto-insert switches; language popup; history selection/raw/copy/search/delete; empty home synchronization.")
        print("LIMIT: destructive clear/retention modal and shortcut capture were not invoked. Copy was intercepted before clipboard access. No AppDelegate, model, microphone, global key listener, or production preferences were used.")
    }
}
