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
        let alternateProfile = DictationCleanupProfile(versionID: "saved", name: "自然书面语", contentSHA256: "h1", modelID: "provider/model-a")
        var entry = DictationEntry(id: UUID(), createdAt: date, rawText: "嗯，这个页面挺好的。然后啊，把布局再稍微调整一下，合并到 test 分支，再部署到三点二八。\n另外不要改原来的数据。",
                                  text: "这个页面不错。请调整布局，合并到 test 分支，再部署到 3.28。原有数据保持不变。", asrSeconds: 0.8, cleanupSeconds: 2.0, totalSeconds: 2.8,
                                  audioSeconds: 12, cleanupApplied: true, warning: nil, cleanupProfile: originalProfile, asrModel: "Qwen3-ASR")
        let originalRaw = entry.rawText, originalText = entry.text
        let catalog = CleanupPromptCatalog(active_version_id: "active", versions: [version("active", "日常表达"), version("saved", "自然书面语")],
                                           current_model: CleanupPromptModel(id: "provider/model-b", kind: "local", ready: true), asr_model: "Qwen3-ASR",
                                           reprocess_models: [CleanupPromptModel(id: "provider/model-a", kind: "local", ready: true, name: "Qwen3 · 4B"),
                                                              CleanupPromptModel(id: "provider/model-b", kind: "local", ready: true, name: "Qwen3.5 · 9B")])
        let sheet = HistoryReprocessingWindowController(entry: entry, catalog: catalog)
        var requests: [(UUID, String, String)] = [], copies: [String] = []
        sheet.onRun = { requests.append(($0, $1, $2)) }; sheet.onCopy = { copies.append($0) }
        sheet.update(entry: entry, catalog: catalog, busy: false, blockedByOtherEntry: false, error: nil)
        let prompt = field(sheet, "promptPicker", NSPopUpButton.self)!, run = field(sheet, "runButton", NSButton.self)!
        let model = field(sheet, "modelPicker", NSPopUpButton.self)!
        let selectedModelLabel = field(sheet, "modelLabel", NSTextField.self)!
        let sourceMetadata = field(sheet, "sourceMetadata", NSTextField.self)!
        let result = field(sheet, "resultPicker", NSPopUpButton.self)!, copy = field(sheet, "copyButton", NSButton.self)!
        let left = field(sheet, "sourceText", NSTextView.self)!, right = field(sheet, "resultText", NSTextView.self)!
        let status = field(sheet, "statusLabel", NSTextField.self)!, metadata = field(sheet, "resultMetadata", NSTextField.self)!
        try require(prompt.selectedItem?.representedObject as? String == "active", "New sheet did not select the currently active prompt")
        try require(run.isEnabled && !copy.isEnabled && !result.isEnabled, "Empty revision state has wrong available actions")
        try require(left.string == originalRaw && right.string.isEmpty, "ASR original is not the default test input comparison")
        try require(sourceMetadata.stringValue.contains("原始规则") && sourceMetadata.stringValue.contains("model-original") && sourceMetadata.stringValue.contains("2.00"), "Original output provenance or timing is missing")
        try require(model.numberOfItems == 2 && model.selectedItem?.representedObject as? String == "provider/model-b", "Current model is not the initial test selection")
        try require(run.title == "开始测试" && sheet.window?.title == "润色测试", "Testing action remains ambiguous")
        try require(sheet.window?.isVisible == false, "Fixture unexpectedly showed a production-facing window")
        pick(prompt, 1); pick(model, 0)
        sheet.update(entry: entry, catalog: catalog, busy: false, blockedByOtherEntry: false, error: nil)
        try require(model.selectedItem?.representedObject as? String == "provider/model-a", "Catalog refresh replaced the local model selection")
        run.performClick(nil); run.performClick(nil)
        try require(requests.count == 1 && requests[0].0 == entry.id && requests[0].1 == "saved" && requests[0].2 == "provider/model-a", "Run duplicated or used the active global rule instead of the local selection")
        try require(!run.isEnabled && !prompt.isEnabled && !model.isEnabled, "Running request permits a duplicate generation or model change")
        try require(catalog.active_version_id == "active", "Local prompt selection changed global activation")
        let source = field(sheet, "sourcePicker", NSSegmentedControl.self)!
        source.selectedSegment = 1; NSApp.sendAction(source.action!, to: source.target, from: source)
        try require(left.string == originalText, "Original output cannot be inspected during generation")
        let first = DictationRevision(id: UUID(), createdAt: date.addingTimeInterval(60), text: "这个页面不错，可以按当前版本调整。\n\n1. 调整布局后合并到 test 分支。\n2. 部署到 3.28，供我检查。\n\n原有数据保持不变。", cleanupSeconds: 2.4, cleanupProfile: alternateProfile,
                                      cleanupOutcome: DictationCleanupOutcome(status: "applied"), modelLoadSeconds: 0.65)
        entry.revisions = [first]
        sheet.update(entry: entry, catalog: catalog, busy: false, blockedByOtherEntry: false, error: nil)
        try require(right.string == first.text && copy.isEnabled && result.isEnabled, "New saved version was not selected automatically")
        try require(metadata.stringValue.contains("自然书面语") && metadata.stringValue.contains("model-a") && metadata.stringValue.contains("2.40") && metadata.stringValue.contains("0.65"), "Saved prompt/model provenance is missing")
        // Runtime health refreshes arrive while the user is choosing a model
        // or selecting text. Rebuilding the same menu invalidates native menu
        // tracking; replacing identical strings collapses the text selection.
        let stableItems = [prompt.itemArray, model.itemArray, result.itemArray]
        let stableSelections = [prompt.selectedItem, model.selectedItem, result.selectedItem]
        let leftSelection = NSRange(location: 2, length: 8), rightSelection = NSRange(location: 4, length: 6)
        left.setSelectedRange(leftSelection); right.setSelectedRange(rightSelection)
        for _ in 0..<4 { sheet.update(entry: entry, catalog: catalog, busy: false, blockedByOtherEntry: false, error: nil) }
        for (index, picker) in [prompt, model, result].enumerated() {
            try require(picker.itemArray.count == stableItems[index].count && zip(picker.itemArray, stableItems[index]).allSatisfy { $0 === $1 }, "Unchanged health refresh rebuilt an open menu's items")
            try require(picker.selectedItem === stableSelections[index], "Unchanged health refresh replaced a selected menu item")
        }
        try require(left.selectedRange() == leftSelection && right.selectedRange() == rightSelection, "Unchanged health refresh reset the comparison text selection")
        let activeChanged = CleanupPromptCatalog(active_version_id: "saved", versions: catalog.versions,
            current_model: catalog.current_model, asr_model: catalog.asr_model, reprocess_models: catalog.reprocess_models)
        sheet.update(entry: entry, catalog: activeChanged, busy: false, blockedByOtherEntry: false, error: nil)
        try require(prompt.item(at: 0) !== stableItems[0][0] && prompt.selectedItem?.title.contains("当前规则") == true, "Changed active prompt did not update its menu marker")
        try require(model.item(at: 0) === stableItems[1][0] && result.item(at: 0) === stableItems[2][0], "Prompt change rebuilt unrelated model/result menus")
        let renamedRule = version("saved", "更清晰的表达")
        let renamedCatalog = CleanupPromptCatalog(active_version_id: "saved", versions: [catalog.versions[0], renamedRule],
            current_model: catalog.current_model, asr_model: catalog.asr_model, reprocess_models: catalog.reprocess_models)
        sheet.update(entry: entry, catalog: renamedCatalog, busy: false, blockedByOtherEntry: false, error: nil)
        try require(prompt.selectedItem?.title.contains("更清晰的表达") == true && prompt.selectedItem?.representedObject as? String == "saved", "Changed prompt metadata did not refresh or lost local selection")
        var renamedEntry = entry
        let renamedProfile = DictationCleanupProfile(versionID: alternateProfile.versionID, name: "保存时的规则名称", contentSHA256: alternateProfile.contentSHA256, modelID: alternateProfile.modelID)
        renamedEntry.revisions = [DictationRevision(id: first.id, createdAt: first.createdAt, text: first.text,
            cleanupSeconds: first.cleanupSeconds, cleanupProfile: renamedProfile, cleanupOutcome: first.cleanupOutcome,
            modelLoadSeconds: first.modelLoadSeconds)]
        let promptBeforeRevision = prompt.item(at: 0)
        sheet.update(entry: renamedEntry, catalog: renamedCatalog, busy: false, blockedByOtherEntry: false, error: nil)
        try require(result.item(at: 0) !== stableItems[2][0] && result.selectedItem?.title.contains("保存时的规则名称") == true, "Changed saved-result metadata did not refresh its menu")
        try require(prompt.item(at: 0) === promptBeforeRevision && model.item(at: 0) === stableItems[1][0], "Result change rebuilt unrelated configuration menus")
        try require(left.selectedRange() == leftSelection && right.selectedRange() == rightSelection, "Metadata-only refresh reset unchanged text selections")
        sheet.update(entry: entry, catalog: catalog, busy: false, blockedByOtherEntry: false, error: nil)
        pick(model, 1)
        let refreshedCatalog = CleanupPromptCatalog(active_version_id: "active", versions: catalog.versions,
            current_model: CleanupPromptModel(id: "provider/model-a", kind: "local", ready: true),
            asr_model: catalog.asr_model, reprocess_models: catalog.reprocess_models)
        sheet.update(entry: entry, catalog: refreshedCatalog, busy: false, blockedByOtherEntry: false, error: nil)
        try require(prompt.selectedItem?.representedObject as? String == "saved" && model.selectedItem?.representedObject as? String == "provider/model-b", "Runtime model refresh changed the local test selections")
        try require(metadata.stringValue.contains("model-a") && model.selectedItem?.representedObject as? String == "provider/model-b", "Changing next test model rewrote the shown result provenance")
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
        try require(status.stringValue.contains("服务暂时不可用") && status.stringValue.contains("已有版本") && run.isEnabled && right.string == first.text, "Failure erased stored results or disabled retry")
        sheet.update(entry: entry, catalog: catalog, busy: false, blockedByOtherEntry: true, error: nil)
        try require(!run.isEnabled && !prompt.isEnabled && !model.isEnabled, "Another pending history request permits duplicate dispatch")
        let unavailable = CleanupPromptCatalog(active_version_id: "active", versions: catalog.versions, current_model: CleanupPromptModel(id: "provider/model-b", kind: "local", ready: false, unavailable_reason: "请先下载此模型。"), asr_model: "Qwen3-ASR")
        sheet.update(entry: entry, catalog: unavailable, busy: false, blockedByOtherEntry: false, error: nil)
        try require(!run.isEnabled && selectedModelLabel.stringValue.contains("下载"), "An unready model can be dispatched or lacks an explanation")
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
            let promptBounds = prompt.convert(prompt.bounds, to: content)
            let modelBounds = model.convert(model.bounds, to: content)
            let runBounds = run.convert(run.bounds, to: content)
            try require(content.bounds.contains(promptBounds) && content.bounds.contains(modelBounds) && content.bounds.contains(runBounds), "A test configuration control escaped the sheet")
            try require(promptBounds.maxX < modelBounds.minX && modelBounds.maxX < runBounds.minX, "Prompt, model, and run controls overlap")
        }
        let outputArgument = CommandLine.arguments.firstIndex(of: "--output").flatMap {
            CommandLine.arguments.count > $0 + 1 ? CommandLine.arguments[$0 + 1] : nil
        } ?? CommandLine.arguments.dropFirst().first
        if let outputArgument {
            let folder = URL(fileURLWithPath: outputArgument, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                sheet.window?.appearance = NSAppearance(named: appearance)
                for (width, label) in [(900.0, "wide"), (760.0, "narrow")] {
                    sheet.window?.setContentSize(NSSize(width: width, height: width == 760 ? 510 : 610))
                    try sheet.renderPNG(to: folder.appendingPathComponent("history-reprocessing-\(name)-\(label).png"))
                }
            }
            sheet.window?.appearance = NSAppearance(named: .aqua)
            sheet.window?.setContentSize(NSSize(width: 900, height: 610))
            sheet.update(entry: entry, catalog: catalog, busy: true, blockedByOtherEntry: false, error: nil)
            try sheet.renderPNG(to: folder.appendingPathComponent("history-reprocessing-busy.png"))
            sheet.update(entry: entry, catalog: catalog, busy: false, blockedByOtherEntry: false, error: "模型加载失败，请重试。")
            try sheet.renderPNG(to: folder.appendingPathComponent("history-reprocessing-failed.png"))
        }
        sheet.update(entry: nil, catalog: catalog, busy: false, blockedByOtherEntry: false, error: nil)
        try require(!run.isEnabled && left.string.isEmpty && right.string.isEmpty, "Deleted history remains actionable or visible")

        // Verify the entry point and refresh chain without showing a sheet.
        let store = DictationStore(memoryOnly: true)
        let stored = store.add(rawText: originalRaw, text: originalText, asrSeconds: 1, cleanupSeconds: 2, totalSeconds: 3, audioSeconds: 12, cleanupApplied: true, warning: nil, cleanupProfile: originalProfile)
        let controller = DictationWindowController(store: store, sessionStartedAt: date)
        var routed: [(UUID, String, String)] = []
        controller.onReprocessEntry = { routed.append(($0, $1, $2)) }
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
        let notificationRevision = store.addRevision(entryID: stored.id, text: second.text, cleanupSeconds: 1, cleanupProfile: originalProfile)!
        controller.reloadStore()
        pick(field(opened, "resultPicker", NSPopUpButton.self)!, 1)
        controller.showReprocessing(entryID: stored.id, revisionID: notificationRevision.id, show: false)
        try require(field(opened, "resultText", NSTextView.self)?.string == second.text, "Notification reopened a retained sheet on an older revision")
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
        failureController.onReprocessEntry = { _, _, _ in }
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
