import AppKit

@main
enum HistoryReprocessingTests {
    static var checks = 0
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw NSError(domain: "HistoryReprocessing", code: checks, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func field<T>(_ value: Any, _ name: String, _: T.Type) -> T? {
        Mirror(reflecting: value).children.first { $0.label == name }?.value as? T
    }
    static func pick(_ picker: NSPopUpButton, _ index: Int) {
        picker.selectItem(at: index)
        if let action = picker.action { NSApp.sendAction(action, to: picker.target, from: picker) }
    }
    static func version(_ id: String, _ name: String) -> CleanupPromptVersion {
        CleanupPromptVersion(id: id, name: name, note: "保留原意，自然清晰。", created_at: "2026-11-05T12:00:00Z", model_id: "model-a",
                             system_prompt: "清理口述，不添加内容。", user_prefix: "原文：", examples: [], content_sha256: "hash-" + id, origin: "user")
    }
    static func main() {
        do { try run(); print("PASS: \(checks) history reprocessing UI checks") }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func run() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let date = Date(timeIntervalSince1970: 1793880000)
        let originalProfile = DictationCleanupProfile(versionID: "original", name: "原始规则", contentSHA256: "h0", modelID: "provider/model-original")
        let alternateProfile = DictationCleanupProfile(versionID: "saved", name: "自然书面语", contentSHA256: "h1", modelID: "provider/model-b")
        var entry = DictationEntry(id: UUID(), createdAt: date, rawText: "嗯，这个页面挺好的。然后啊，把布局再稍微调整一下，合并到 test 分支，再部署到三点二八。\n另外不要改原来的数据。",
                                  text: "这个页面不错。请调整布局，合并到 test 分支，再部署到 3.28。原有数据保持不变。", asrSeconds: 0.8, cleanupSeconds: 2.0, totalSeconds: 2.8,
                                  audioSeconds: 12, cleanupApplied: true, warning: nil, cleanupProfile: originalProfile, asrModel: "Qwen3-ASR")
        let originalRaw = entry.rawText, originalText = entry.text
        let catalog = CleanupPromptCatalog(active_version_id: "active", versions: [version("active", "日常表达"), version("saved", "自然书面语")],
                                           current_model: CleanupPromptModel(id: "provider/model-b", kind: "cloud", ready: true), asr_model: "Qwen3-ASR")
        let sheet = HistoryReprocessingWindowController(entry: entry, catalog: catalog)
        var requests: [(UUID, String)] = [], copies: [String] = []
        sheet.onRun = { requests.append(($0, $1)) }; sheet.onCopy = { copies.append($0) }
        sheet.update(entry: entry, catalog: catalog, busy: false, blockedByOtherEntry: false, error: nil)
        let prompt = field(sheet, "promptPicker", NSPopUpButton.self)!, run = field(sheet, "runButton", NSButton.self)!
        let result = field(sheet, "resultPicker", NSPopUpButton.self)!, copy = field(sheet, "copyButton", NSButton.self)!
        let left = field(sheet, "sourceText", NSTextView.self)!, right = field(sheet, "resultText", NSTextView.self)!
        let status = field(sheet, "statusLabel", NSTextField.self)!, metadata = field(sheet, "resultMetadata", NSTextField.self)!
        try require(prompt.selectedItem?.representedObject as? String == "active", "New sheet did not select the currently active prompt")
        try require(run.isEnabled && !copy.isEnabled && !result.isEnabled, "Empty revision state has wrong available actions")
        try require(left.string == originalText && right.string.isEmpty, "Original output is not the default comparison")
        try require(sheet.window?.isVisible == false, "Fixture unexpectedly showed a production-facing window")
        pick(prompt, 1); run.performClick(nil); run.performClick(nil)
        try require(requests.count == 1 && requests[0].0 == entry.id && requests[0].1 == "saved", "Run duplicated or used the active global rule instead of the local selection")
        try require(!run.isEnabled && !prompt.isEnabled, "Running request permits a duplicate generation")
        try require(catalog.active_version_id == "active", "Local prompt selection changed global activation")
        let source = field(sheet, "sourcePicker", NSSegmentedControl.self)!
        source.selectedSegment = 1; NSApp.sendAction(source.action!, to: source.target, from: source)
        try require(left.string == originalRaw, "ASR original cannot be inspected during generation")
        let first = DictationRevision(id: UUID(), createdAt: date.addingTimeInterval(60), text: "这个页面不错，可以按当前版本调整。\n\n1. 调整布局后合并到 test 分支。\n2. 部署到 3.28，供我检查。\n\n原有数据保持不变。", cleanupSeconds: 2.4, cleanupProfile: alternateProfile)
        entry.revisions = [first]
        sheet.update(entry: entry, catalog: catalog, busy: false, blockedByOtherEntry: false, error: nil)
        try require(right.string == first.text && copy.isEnabled && result.isEnabled, "New saved version was not selected automatically")
        try require(metadata.stringValue.contains("自然书面语") && metadata.stringValue.contains("model-b"), "Saved prompt/model provenance is missing")
        copy.performClick(nil)
        try require(copies == [first.text], "Copy did not use the selected stored revision")
        let second = DictationRevision(id: UUID(), createdAt: date.addingTimeInterval(120), text: "这个页面不错，按当前版本调整布局，再合并到 test 分支并部署到 3.28。\n原有数据保持不变，我之后检查。", cleanupSeconds: 2.1, cleanupProfile: originalProfile)
        entry.revisions?.append(second)
        sheet.update(entry: entry, catalog: catalog, busy: false, blockedByOtherEntry: false, error: nil)
        try require(right.string == second.text, "Latest returned version did not become the selected result")
        pick(result, 1); copy.performClick(nil)
        try require(right.string == first.text && copies.last == first.text, "Older saved revisions cannot be revisited/copied")
        try require(entry.rawText == originalRaw && entry.text == originalText && entry.revisions?.count == 2, "Review overwrote original history or added an extra revision")
        sheet.update(entry: entry, catalog: catalog, busy: true, blockedByOtherEntry: false, error: nil)
        field(sheet, "closeButton", NSButton.self)?.performClick(nil)
        try require(field(sheet, "busy", Bool.self) == true && requests.count == 1, "Closing the sheet cancelled or repeated generation")
        sheet.update(entry: entry, catalog: catalog, busy: false, blockedByOtherEntry: false, error: "服务暂时不可用，请稍后重试。")
        try require(status.stringValue.contains("服务暂时不可用") && run.isEnabled && right.string == first.text, "Failure erased stored results or disabled retry")
        sheet.update(entry: entry, catalog: catalog, busy: false, blockedByOtherEntry: true, error: nil)
        try require(!run.isEnabled && !prompt.isEnabled, "Another pending history request permits duplicate dispatch")
        let unavailable = CleanupPromptCatalog(active_version_id: "active", versions: catalog.versions, current_model: CleanupPromptModel(id: "provider/model-b", kind: "cloud", ready: false), asr_model: "Qwen3-ASR")
        sheet.update(entry: entry, catalog: unavailable, busy: false, blockedByOtherEntry: false, error: nil)
        try require(!run.isEnabled, "An unready model can be dispatched")
        sheet.update(entry: entry, catalog: catalog, busy: false, blockedByOtherEntry: false, error: nil)
        source.selectedSegment = 0; NSApp.sendAction(source.action!, to: source.target, from: source)
        pick(result, 0)
        for size in [NSSize(width: 900, height: 610), NSSize(width: 760, height: 510)] {
            sheet.window?.setContentSize(size)
            let content = sheet.window!.contentView!; content.layoutSubtreeIfNeeded()
            let leftBounds = left.enclosingScrollView!.convert(left.enclosingScrollView!.bounds, to: content)
            let rightBounds = right.enclosingScrollView!.convert(right.enclosingScrollView!.bounds, to: content)
            try require(content.bounds.contains(leftBounds) && content.bounds.contains(rightBounds), "Comparison pane escaped the sheet")
            try require(leftBounds.maxX < rightBounds.minX && leftBounds.height >= 200, "Comparison columns overlap or collapsed")
        }
        if let argument = CommandLine.arguments.firstIndex(of: "--output"), CommandLine.arguments.count > argument + 1 {
            let folder = URL(fileURLWithPath: CommandLine.arguments[argument + 1], isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            sheet.window?.setContentSize(NSSize(width: 900, height: 610))
            try sheet.renderPNG(to: folder.appendingPathComponent("history-reprocessing.png"))
            sheet.update(entry: entry, catalog: catalog, busy: true, blockedByOtherEntry: false, error: nil)
            try sheet.renderPNG(to: folder.appendingPathComponent("history-reprocessing-busy.png"))
        }
        sheet.update(entry: nil, catalog: catalog, busy: false, blockedByOtherEntry: false, error: nil)
        try require(!run.isEnabled && left.string.isEmpty && right.string.isEmpty, "Deleted history remains actionable or visible")

        // Verify the entry point and refresh chain without showing a sheet.
        let store = DictationStore(memoryOnly: true)
        let stored = store.add(rawText: originalRaw, text: originalText, asrSeconds: 1, cleanupSeconds: 2, totalSeconds: 3, audioSeconds: 12, cleanupApplied: true, warning: nil, cleanupProfile: originalProfile)
        let controller = DictationWindowController(store: store, sessionStartedAt: date)
        var routed: [(UUID, String)] = []
        controller.onReprocessEntry = { routed.append(($0, $1)) }
        controller.updatePrompts(catalog: catalog, busy: false, error: nil)
        controller.showReprocessing(entryID: stored.id, show: false)
        let opened = field(controller, "reprocessingSheet", HistoryReprocessingWindowController.self)!
        field(opened, "runButton", NSButton.self)?.performClick(nil)
        try require(routed.count == 1 && routed[0].0 == stored.id, "History entry point failed to route generation")
        controller.updateReprocessing(entryID: stored.id, busy: true, error: nil)
        try require(field(opened, "busy", Bool.self) == true, "Runtime busy update missed the sheet")
        _ = store.addRevision(entryID: stored.id, text: first.text, cleanupSeconds: 2.4, cleanupProfile: alternateProfile)
        controller.reloadStore(); controller.updateReprocessing(entryID: stored.id, busy: false, error: nil)
        try require(field(opened, "resultText", NSTextView.self)?.string == first.text, "Saved revision did not reach an already-open comparison")
        try require(store.entries.count == 1 && store.entries[0].text == originalText, "Sheet integration replaced original history")
        try require(controller.window?.isVisible == false && opened.window?.isVisible == false, "Integration test stole application focus")

        // Force a real mirror-write failure after the original was durable.
        // The new revision remains copyable, but the sheet must not claim it
        // is saved; model errors and storage warnings must both remain visible.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("history-ui-write-failure-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let durable = DictationStore(directory: directory)
        let durableEntry = durable.add(rawText: originalRaw, text: originalText, asrSeconds: 1, cleanupSeconds: 2, totalSeconds: 3, audioSeconds: 12, cleanupApplied: true, warning: nil, cleanupProfile: originalProfile)
        try require(!durable.hasUnsavedHistory, "Fixture original failed to persist before the simulated failure")
        let failureController = DictationWindowController(store: durable, sessionStartedAt: date)
        failureController.onReprocessEntry = { _, _ in }
        failureController.updatePrompts(catalog: catalog, busy: false, error: nil)
        failureController.showReprocessing(entryID: durableEntry.id, show: false)
        durable.onChange = { [weak failureController] in failureController?.reloadStore() }
        let mirror = directory.appendingPathComponent("history.backup.json")
        try FileManager.default.removeItem(at: mirror)
        try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)
        let pendingRevision = durable.addRevision(entryID: durableEntry.id, text: first.text, cleanupSeconds: 2.4, cleanupProfile: alternateProfile)
        try require(pendingRevision != nil && durable.hasUnsavedHistory && durable.storageError != nil, "Mirror obstruction did not exercise memory-only revision retention")
        let failureSheet = field(failureController, "reprocessingSheet", HistoryReprocessingWindowController.self)!
        let failureStatus = field(failureSheet, "statusLabel", NSTextField.self)!
        try require(failureStatus.stringValue.contains("尚未完整保存") && !failureStatus.stringValue.contains("新版本已保存"), "Memory-only revision was falsely shown as saved")
        try require(field(failureSheet, "copyButton", NSButton.self)?.isEnabled == true && field(failureSheet, "resultText", NSTextView.self)?.string == first.text,
                    "Storage failure removed the user's copyable result")
        failureController.updateReprocessing(entryID: durableEntry.id, busy: false, error: "模型连接异常")
        try require(failureStatus.stringValue.contains("模型连接异常") && failureStatus.stringValue.contains("尚未完整保存"), "Storage warning replaced the model error or was hidden by it")
        failureController.updateReprocessing(entryID: durableEntry.id, busy: false, error: nil)
        try FileManager.default.removeItem(at: mirror)
        try require(durable.flushHistory() && !durable.hasUnsavedHistory, "Repaired storage did not persist the pending revision")
        try require(failureStatus.stringValue == "新版本已保存，原输出保留。", "Successful persistence did not automatically restore the saved state on refresh")
        try require(DictationStore(directory: directory).entries.first?.revisions?.first?.text == first.text, "Recovered revision was not durable across store reload")
    }
}
