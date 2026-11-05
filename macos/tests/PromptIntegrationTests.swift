import AppKit

/// Full native-page navigation with memory-only history and fixture requests.
/// The window remains hidden and no application runtime or device I/O is linked.
@main
enum PromptIntegrationChecks {
    static var checks = 0
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw NSError(domain: "PromptIntegrationChecks", code: checks, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func find<T: NSView>(_ id: String, in root: NSView, as type: T.Type = T.self) throws -> T {
        let found = descendants(root).filter { $0.identifier?.rawValue == id }.compactMap { $0 as? T }
        try require(found.count == 1, "Expected one \(id), found \(found.count)")
        return found[0]
    }
    static func click(_ title: String, in root: NSView) throws {
        let buttons = descendants(root).compactMap { $0 as? NSButton }.filter { $0.title == title }
        try require(buttons.count == 1 && buttons[0].isEnabled, "Missing or disabled button: \(title)")
        buttons[0].performClick(nil)
    }
    static func contains(_ text: String, in root: NSView) -> Bool {
        descendants(root).contains { ($0 as? NSTextField)?.stringValue.contains(text) == true || ($0 as? NSTextView)?.string.contains(text) == true }
    }
    static func snapshot(_ root: NSView, name: String) throws {
        guard let index = CommandLine.arguments.firstIndex(of: "--render"), CommandLine.arguments.indices.contains(index + 1) else { return }
        let directory = CommandLine.arguments[index + 1]
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let until = Date().addingTimeInterval(0.18)
        while Date() < until { RunLoop.current.run(until: min(until, Date().addingTimeInterval(0.01))) }
        guard let image = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { throw NSError(domain: "Capture", code: 1) }
        root.cacheDisplay(in: root.bounds, to: image)
        guard let data = image.representation(using: .png, properties: [:]) else { throw NSError(domain: "Capture", code: 2) }
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }
    static func main() {
        do { try run(); print("PASS: \(checks) full-page Prompt integration checks (memory-only, hidden window)") }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func run() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let store = DictationStore(memoryOnly: true)
        let controller = DictationWindowController(store: store, sessionStartedAt: Date())
        guard let window = controller.window, let root = window.contentView else { throw NSError(domain: "Window", code: 1) }
        defer { window.close() }
        store.onChange = { [weak controller] in controller?.reloadStore() }
        var state = DictationUIState()
        state.serviceReady = true; state.serviceMessage = "Qwen3-ASR · 本机识别"
        state.cleanupBackend = .local; state.canStart = true
        state.microphoneAllowed = true; state.accessibilityAllowed = true; state.functionKeyEnabled = true
        controller.updateState(state)
        let current = CleanupPromptVersion(id: "integration-current", name: "自然表达", note: "保留原意和个人语气。", created_at: "2026-11-04T09:30:00Z",
            model_id: "mlx/Qwen3-4B-Instruct-2507-4bit",
            system_prompt: "把口述整理为清楚、自然的书面语。\n\n删除填充词和重复表达；尊重说话者明确的自我纠正。\n保留核心判断，不添加原文没有的承诺或结论。\n技术术语使用标准拼写，如 BOM、SalesPart、ProductPart、SalesItem、Typeless。",
            user_prefix: "整理以下口述：", examples: [CleanupPromptExample(source: "那个，把 bom 导出一下。", edited: "导出 BOM。")],
            content_sha256: "current-content", origin: "user")
        let historic = CleanupPromptVersion(id: "integration-historic", name: "自然表达 · 第一版", note: "较早使用的规则。", created_at: "2026-11-03T06:20:00Z",
            model_id: "mlx/Qwen3-1.7B", system_prompt: "清除冗余口述，保留意思与语气。", user_prefix: "请整理原文：",
            examples: [], content_sha256: "historic-content", origin: "user")
        let catalog = CleanupPromptCatalog(active_version_id: current.id, versions: [current, historic],
            current_model: CleanupPromptModel(id: current.model_id!, kind: "local", ready: true), asr_model: "mlx/Qwen3-ASR-0.6B-4bit")
        var reloads = 0, saves: [CleanupPromptDraft] = [], activations: [String] = []
        controller.onReloadPrompts = { reloads += 1 }
        controller.onSavePrompt = { saves.append($0) }
        controller.onActivatePrompt = { activations.append($0) }

        // Enter through the actual sidebar and feed the asynchronous catalog
        // through the same controller method used by the service client.
        try click("润色规则", in: root)
        try require(reloads == 1, "First navigation did not request the catalog")
        controller.updatePrompts(catalog: catalog, busy: false, error: nil)
        root.layoutSubtreeIfNeeded()
        let studio: PromptStudioView = try find("prompt-studio", in: root)
        let editor: NSTextView = try find("prompt-editor", in: root)
        let name: NSTextField = try find("prompt-name", in: root)
        let save: NSButton = try find("prompt-save", in: root)
        let activate: NSButton = try find("prompt-activate", in: root)
        try require(name.stringValue == current.name && editor.string == current.system_prompt, "Controller did not display the active version")
        let edited = "保持清楚自然，不把日常表达改成官话。\nBOM、SalesPart 与 3.28 保持标准格式。"
        editor.string = edited
        studio.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        name.stringValue = "自然表达 · 我的草稿"
        studio.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: name))
        try require(save.isEnabled && !activate.isEnabled, "Draft actions wrong on integrated page")

        try click("首页", in: root)
        try require(!descendants(root).contains { $0 === studio }, "Prompt editor remained attached on Home")
        try click("润色规则", in: root)
        let retained: PromptStudioView = try find("prompt-studio", in: root)
        try require(retained === studio && editor.string == edited && name.stringValue == "自然表达 · 我的草稿", "Sidebar navigation discarded or recreated the draft")
        for _ in 0..<10 { controller.showPage(.home); controller.showPage(.prompts) }
        let finalStudio: PromptStudioView = try find("prompt-studio", in: root)
        try require(finalStudio === studio && editor.string == edited && studio.hasUnsavedChanges, "Rapid navigation lost the retained draft")
        try require(reloads == 1, "Cached page navigation unnecessarily reloaded catalog")
        controller.updatePrompts(catalog: catalog, busy: false, error: nil)
        try require(editor.string == edited && name.stringValue == "自然表达 · 我的草稿", "Catalog refresh replaced the draft")
        state.recording = true; state.processing = false; state.canEditShortcut = false
        controller.updateState(state)
        try require(editor.isEditable && save.isEnabled, "Recording incorrectly disabled Prompt editing")
        state.recording = false; state.canEditShortcut = true; controller.updateState(state)

        for size in [NSSize(width: 1000, height: 668), NSSize(width: 1400, height: 900), NSSize(width: 1000, height: 668)] {
            window.setContentSize(size); root.layoutSubtreeIfNeeded(); studio.layoutSubtreeIfNeeded()
            guard let outer = root.subviews.compactMap({ $0 as? NSScrollView }).first, let document = outer.documentView else { throw NSError(domain: "Viewport", code: 1) }
            let editorScroll: NSScrollView = try find("prompt-editor-scroll", in: root)
            let studioRect = root.convert(studio.bounds, from: studio)
            let editorRect = root.convert(editorScroll.bounds, from: editorScroll)
            let saveRect = root.convert(save.bounds, from: save)
            try require(abs(studio.frame.width - (outer.contentView.bounds.width - 64)) < 1, "Prompt page did not fill available width at \(size)")
            try require(abs(document.bounds.height - outer.contentView.bounds.height) < 1, "Prompt page unnecessarily scrolls instead of filling viewport at \(size)")
            try require(studio.frame.height >= 490 && editorScroll.frame.height >= 210, "Prompt page height was not filled: \(studio.frame), \(editorScroll.frame)")
            try require(root.bounds.contains(studioRect) && root.bounds.contains(editorRect) && root.bounds.contains(saveRect), "Minimum window clipped editor or actions")
            try require(abs(studioRect.minY - 32) < 1, "Prompt editor left unused bottom space: \(studioRect)")
            try require(!studio.hasAmbiguousLayout && !editorScroll.hasAmbiguousLayout, "Integrated Prompt layout is ambiguous")
            try require(editor.string == edited && name.stringValue == "自然表达 · 我的草稿", "Resizing lost the draft")
            try snapshot(root, name: size.width == 1000 ? "prompt-page-1000x668.png" : "prompt-page-1400x900.png")
        }

        // The history entry points at an older immutable rule, independently
        // of today's active version and the draft still open in the editor.
        let profile = DictationCleanupProfile(versionID: historic.id, name: historic.name, contentSHA256: historic.content_sha256, modelID: historic.model_id!)
        let entry = store.add(rawText: "嗯，把那个 BOM 导出一下，然后部署到三点二八。", text: "导出 BOM，然后部署到 3.28。",
            asrSeconds: 0.2, cleanupSeconds: 0.3, totalSeconds: 0.5, audioSeconds: 5, cleanupApplied: true,
            warning: nil, cleanupProfile: profile, asrModel: catalog.asr_model)
        try require(store.entries.first?.id == entry.id && store.entries.first?.cleanupProfile == profile, "History fixture lost provenance")
        try click("历史记录", in: root)
        try require(contains("Qwen3-ASR-0.6B-4bit", in: root) && contains("Qwen3-1.7B", in: root), "History omitted actual ASR or cleanup model")
        let link: NSButton = try find("history-prompt-link", in: root)
        try require(link.title == "查看此规则" && link.isEnabled, "History rule link unavailable")
        link.performClick(nil)
        let historyStudio: PromptStudioView = try find("prompt-studio", in: root)
        try require(historyStudio === studio && name.stringValue == historic.name && editor.string == historic.system_prompt, "History navigation did not select its recorded rule")
        try require(activate.isEnabled && !save.isEnabled && activations.isEmpty, "Viewing an old history rule changed the active rule")
        root.layoutSubtreeIfNeeded()
        try snapshot(root, name: "prompt-page-from-history.png")
        let currentRow: NSButton = try find("prompt-version-" + current.id, in: root)
        currentRow.performClick(nil)
        try require(editor.string == edited && name.stringValue == "自然表达 · 我的草稿", "History round-trip destroyed the other draft")
        save.performClick(nil)
        try require(saves.count == 1 && saves[0].system_prompt == edited && activations.isEmpty, "Integrated save callback lost the draft or activated it")
        controller.updatePrompts(catalog: catalog, busy: false, error: "保存暂不可用")
        try require(save.isEnabled && editor.string == edited, "Integrated save error prevented retry or lost edits")
        try require(!window.isVisible, "Integration test window became visible")
    }
}
