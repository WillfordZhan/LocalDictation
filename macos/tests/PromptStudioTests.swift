import AppKit

/// Exercises the shipped editor in a hidden window. Fixtures and callbacks stay
/// in memory; this process never opens the app, microphone or pasteboard.
@main
enum PromptStudioChecks {
    static var checks = 0
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw NSError(domain: "PromptStudioChecks", code: checks, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func find<T: NSView>(_ id: String, in view: NSView, as type: T.Type = T.self) throws -> T {
        let found = descendants(view).filter { $0.identifier?.rawValue == id }.compactMap { $0 as? T }
        try require(found.count == 1, "Expected one \(id), found \(found.count)")
        return found[0]
    }
    static func action(_ control: NSControl) throws {
        guard let selector = control.action else { throw NSError(domain: "MissingAction", code: 1) }
        try require(control.sendAction(selector, to: control.target), "Action did not route")
    }
    static func edit(_ field: NSTextField, _ text: String, in studio: PromptStudioView) {
        field.stringValue = text
        studio.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }
    static func edit(_ editor: NSTextView, _ text: String, in studio: PromptStudioView) {
        editor.string = text
        studio.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
    }
    static func version(_ id: String, name: String, text: String, model: String? = "mlx/Qwen3-4B-Instruct-2507-4bit") -> CleanupPromptVersion {
        CleanupPromptVersion(id: id, name: name, note: "保留自然表达，修正冗余与术语。", created_at: "2026-11-04T09:30:00Z",
            model_id: model, system_prompt: text, user_prefix: "请整理以下口述：", examples: [
                CleanupPromptExample(source: "嗯，把这个 bom 导出一下，然后部署到三点二八。", edited: "导出 BOM，然后部署到 3.28。")
            ], content_sha256: "fixture", origin: "user")
    }
    static func catalog(_ versions: [CleanupPromptVersion], active: String = "v1") -> CleanupPromptCatalog {
        CleanupPromptCatalog(active_version_id: active, versions: versions,
            current_model: CleanupPromptModel(id: "mlx/Qwen3-4B-Instruct-2507-4bit", kind: "local", ready: true),
            asr_model: "mlx/Qwen3-ASR-0.6B-4bit")
    }
    static func capture(_ studio: PromptStudioView, window: NSWindow, width: CGFloat, name: String, directory: String) throws {
        window.setContentSize(NSSize(width: width + 24, height: 564))
        window.contentView?.layoutSubtreeIfNeeded(); studio.layoutSubtreeIfNeeded()
        guard let bitmap = studio.bitmapImageRepForCachingDisplay(in: studio.bounds) else { throw NSError(domain: "Capture", code: 1) }
        studio.cacheDisplay(in: studio.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "Capture", code: 2) }
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }
    static func main() {
        do { try run(); print("PASS: \(checks) PromptStudio checks (memory-only, hidden window)") }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func run() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 734, height: 564), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 734, height: 564))
        window.contentView = content
        let studio = PromptStudioView(); content.addSubview(studio)
        NSLayoutConstraint.activate([
            studio.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            studio.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            studio.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            studio.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
        defer { window.close() }
        let v1 = version("v1", name: "自然表达", text: "将口述整理为清晰、自然的书面语。\n\n保留说话者的语气和判断，不增加原文没有的内容。\n去掉填充词和重复表达；识别明确的自我纠正。\n专业术语保持标准拼写，如 BOM、SalesPart、ProductPart、SalesItem、Typeless。")
        let v2 = version("v2", name: "简洁书面语", text: "去掉冗余口述，保留主要观点。", model: "mlx/Qwen3-1.7B")
        let original = catalog([v2, v1])
        let name: NSTextField = try find("prompt-name", in: studio)
        let note: NSTextField = try find("prompt-note", in: studio)
        let editor: NSTextView = try find("prompt-editor", in: studio)
        let tabs: NSSegmentedControl = try find("prompt-tabs", in: studio)
        let save: NSButton = try find("prompt-save", in: studio)
        let activate: NSButton = try find("prompt-activate", in: studio)
        let reload: NSButton = try find("prompt-reload", in: studio)
        let feedback: NSTextField = try find("prompt-feedback", in: studio)
        var saves: [CleanupPromptDraft] = [], activations: [String] = [], reloads = 0
        studio.onSave = { saves.append($0) }
        studio.onActivate = { activations.append($0) }
        studio.onReload = { reloads += 1 }
        func captureState(_ name: String) throws {
            guard let index = CommandLine.arguments.firstIndex(of: "--render"), CommandLine.arguments.indices.contains(index + 1) else { return }
            let directory = CommandLine.arguments[index + 1]
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let until = Date().addingTimeInterval(0.14)
            while Date() < until { RunLoop.current.run(until: min(until, Date().addingTimeInterval(0.01))) }
            try capture(studio, window: window, width: 710, name: name, directory: directory)
        }

        // A history reference arriving before the network response must select
        // that exact version, even when another version is currently active.
        studio.selectVersion(id: "v2")
        studio.update(catalog: original, busy: false, error: nil)
        try require(name.stringValue == v2.name, "Deferred history selection lost")
        try require(activate.isEnabled && !save.isEnabled, "Initial saved-version controls wrong")
        let provenance: NSTextField = try find("prompt-provenance", in: studio)
        try require(provenance.stringValue.contains("Qwen3-1.7B"), "Saved model missing")
        studio.selectVersion(id: "missing-version")
        try require(!editor.isEditable && !activate.isEnabled && !save.isEnabled, "Missing version exposed editable unrelated prompt")
        try require(feedback.stringValue.contains("missing-version"), "Missing history version not explained")
        studio.update(catalog: original, busy: false, error: nil)
        try require(name.stringValue.isEmpty, "Refresh silently fell back to active version")
        let activeRow: NSButton = try find("prompt-version-v1", in: studio)
        let versionLabels = descendants(activeRow).compactMap { ($0 as? NSTextField)?.stringValue }
        try require(versionLabels.contains { $0.range(of: #"^11\.04 \d{2}:\d{2} · "#, options: .regularExpression) != nil }, "Version row omitted compact creation date/time")
        try require(activeRow.toolTip == v1.created_at, "Version tooltip omitted the complete timestamp")
        try action(activeRow)
        try require(name.stringValue == v1.name && !activate.isEnabled, "Version row did not select active version")
        try require(!studio.hasUnsavedChanges, "Selection created a draft modification")

        let storeIssue = CleanupPromptCatalog(active_version_id: "v1", versions: [v2, v1], current_model: original.current_model,
            asr_model: original.asr_model, prompt_store_error: "规则存储暂不可读")
        let decodedIssue = try JSONDecoder().decode(CleanupPromptCatalog.self, from: JSONEncoder().encode(storeIssue))
        studio.update(catalog: decodedIssue, busy: false, error: nil)
        try require(feedback.stringValue == "规则存储暂不可读", "Store error was lost in decoding or not shown")
        let recovery = CleanupPromptCatalog(active_version_id: "v1", versions: [v2, v1], current_model: original.current_model,
            asr_model: original.asr_model, recovery_message: "规则已从备份恢复")
        studio.update(catalog: recovery, busy: false, error: nil)
        try require(feedback.stringValue == "规则已从备份恢复", "Recovery notice missing")
        let importIssue = CleanupPromptCatalog(active_version_id: "v1", versions: [v2, v1], current_model: original.current_model,
            asr_model: original.asr_model, prompt_import_error: "旧规则导入失败，请刷新重试")
        studio.update(catalog: importIssue, busy: false, error: nil)
        try require(feedback.stringValue.contains("导入失败"), "Import warning missing")
        studio.update(catalog: original, busy: false, error: nil)

        let editedSystem = "保留人味，不写官话。\nUI、BOM、SalesPart → 保持原始拼写；三点二八 → 3.28。"
        edit(name, "自然表达 · 调优", in: studio)
        edit(note, "自然但清楚，不强制分点。", in: studio)
        edit(editor, editedSystem, in: studio)
        try require(save.isEnabled && !activate.isEnabled && studio.hasUnsavedChanges, "Dirty draft actions incorrect")
        tabs.selectedSegment = 1; try action(tabs)
        let prefix = "只输出润色后的正文。\n以下为原文："
        edit(editor, prefix, in: studio)
        tabs.selectedSegment = 2; try action(tabs)
        edit(editor, "[{\"source\":\"口述\",\"edited\":\"正文\",\"typo\":\"不能静默丢弃\"}]", in: studio)
        try require(!save.isEnabled && feedback.stringValue.contains("示例格式"), "Unknown example keys silently accepted")
        edit(editor, "[{\"source\":\"口述\",\"edited\":4}]", in: studio)
        try require(!save.isEnabled, "Non-string example accepted")
        let examples = "[{\"source\":\"把这个 bom 部署到三点二八\",\"edited\":\"把 BOM 部署到 3.28。\"}]"
        edit(editor, examples, in: studio)
        try require(save.isEnabled, "Valid JSON examples rejected")

        studio.selectVersion(id: "v2")
        try require(name.stringValue == v2.name && activate.isEnabled, "Switching versions failed")
        studio.selectVersion(id: "v1")
        try require(name.stringValue == "自然表达 · 调优" && editor.string == examples, "Version switching lost draft")
        tabs.selectedSegment = 0; try action(tabs)
        try require(editor.string == editedSystem, "Tab switching lost system text")
        studio.update(catalog: original, busy: true, error: nil)
        try require(!save.isEnabled && !activate.isEnabled && !editor.isEditable && !name.isEnabled && !reload.isEnabled, "Busy state left mutable controls enabled")
        studio.update(catalog: original, busy: false, error: "服务暂不可用")
        try require(editor.string == editedSystem && save.isEnabled, "Network failure destroyed draft")
        try require(feedback.stringValue.contains("可重试"), "Retry guidance missing")
        studio.update(catalog: original, busy: false, error: nil)

        content.layoutSubtreeIfNeeded()
        let initialSaveWidth = save.frame.width, initialActivateWidth = activate.frame.width
        try action(save)
        content.layoutSubtreeIfNeeded()
        try require(save.title == "保存中…" && !save.isEnabled && feedback.stringValue == "正在保存新版本…", "Save did not show its own pending state")
        try require(!feedback.stringValue.contains("已保存"), "Save click announced success before a callback")
        try require(abs(save.frame.width - initialSaveWidth) < 0.5 && abs(activate.frame.width - initialActivateWidth) < 0.5, "Pending title moved the action layout")
        try captureState("prompt-saving.png")
        try require(saves.count == 1 && activations.isEmpty, "Saving implicitly activated a version")
        try require(saves[0].system_prompt == editedSystem && saves[0].user_prefix == prefix, "Saved prompt fields differ from editor")
        try require(saves[0].name == "自然表达 · 调优" && saves[0].note == "自然但清楚，不强制分点。", "Saved metadata differs")
        try require(saves[0].examples == [CleanupPromptExample(source: "把这个 bom 部署到三点二八", edited: "把 BOM 部署到 3.28。")], "Saved examples differ")
        try action(save)
        try require(saves.count == 1, "Double action submitted duplicate save")
        studio.update(catalog: nil, busy: false, error: "保存失败")
        try require(save.isEnabled && studio.hasUnsavedChanges && editor.string == editedSystem, "Failed save cleared draft")
        try require(save.title == "保存为新版本" && feedback.stringValue.contains("保存失败") && feedback.textColor == Palette.warning, "Save failure lacked persistent error feedback")
        try captureState("prompt-save-error.png")
        try action(save)
        studio.update(catalog: original, busy: false, error: nil)
        try require(studio.hasUnsavedChanges && save.isEnabled && feedback.stringValue.contains("尚未确认"), "Unchanged catalog cleared a draft or invented save success")
        try action(save)
        let payload = saves.last!
        let saved = CleanupPromptVersion(id: "v3", name: payload.name, note: payload.note, created_at: "2026-11-04T10:00:00Z",
            model_id: original.current_model.id, system_prompt: payload.system_prompt, user_prefix: payload.user_prefix,
            examples: payload.examples, content_sha256: "new-fixture", origin: "user")
        let afterSave = catalog([saved, v2, v1])
        studio.update(catalog: afterSave, busy: false, error: nil)
        try require(name.stringValue == saved.name && !save.isEnabled && activate.isEnabled, "Saved new version not selected independently of active version")
        try require(!studio.hasUnsavedChanges && activations.isEmpty, "Successful save retained dirty state or activated version")
        try require(feedback.stringValue == "已保存，可启用此版本", "Returned matching version did not confirm save")
        try captureState("prompt-saved.png")
        try action(activate)
        try require(activations == ["v3"] && !activate.isEnabled, "Activation did not use selected immutable ID")
        try require(activate.title == "启用中…" && feedback.stringValue == "正在启用所选版本…", "Activation pending state was generic or premature")
        content.layoutSubtreeIfNeeded()
        try require(abs(save.frame.width - initialSaveWidth) < 0.5 && abs(activate.frame.width - initialActivateWidth) < 0.5, "Activation title changed button widths")
        try captureState("prompt-activating.png")
        studio.update(catalog: afterSave, busy: false, error: "启用失败")
        try require(activate.isEnabled && feedback.stringValue == "启用失败" && name.stringValue == saved.name, "Activation failure altered selection or claimed success")
        try action(activate)
        studio.update(catalog: afterSave, busy: false, error: nil)
        try require(feedback.stringValue.contains("尚未确认") && activate.isEnabled, "Unchanged active ID was misreported as activation success")
        try action(activate)
        studio.update(catalog: catalog([saved, v2, v1], active: "v3"), busy: false, error: nil)
        try require(!activate.isEnabled && activate.title == "当前已生效", "Active badge did not refresh")
        try require(feedback.stringValue == "已启用，下次录音生效" && feedback.textColor == Palette.blue, "Confirmed active ID did not show success")
        try captureState("prompt-activated.png")
        studio.update(catalog: afterSave, busy: false, error: nil)
        try require(!feedback.stringValue.contains("已启用"), "Later active-version change left stale success feedback")
        try action(reload)
        try require(reloads == 1, "Reload callback missing")

        // Refreshes and reopening the retained component must not overwrite a
        // draft from a different version while another save succeeds.
        studio.selectVersion(id: "v2"); edit(note, "保留在另一个版本中的草稿", in: studio)
        studio.selectVersion(id: "v1"); edit(note, "v1 的独立草稿", in: studio)
        try action(save)
        let anotherPayload = saves.last!
        let savedOther = CleanupPromptVersion(id: "v4", name: anotherPayload.name, note: anotherPayload.note, created_at: "2026-11-04T10:30:00Z",
            model_id: original.current_model.id, system_prompt: anotherPayload.system_prompt, user_prefix: anotherPayload.user_prefix,
            examples: anotherPayload.examples, content_sha256: "another-fixture", origin: "user")
        studio.update(catalog: catalog([savedOther, saved, v2, v1], active: "v3"), busy: false, error: nil)
        studio.removeFromSuperview(); content.addSubview(studio)
        NSLayoutConstraint.activate([
            studio.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12), studio.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            studio.topAnchor.constraint(equalTo: content.topAnchor, constant: 12), studio.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
        studio.selectVersion(id: "v2")
        try require(note.stringValue == "保留在另一个版本中的草稿", "Unrelated save/navigation erased another version's draft")
        studio.selectVersion(id: "v1")
        try require(note.stringValue == v1.note, "Immutable original version was overwritten")

        for width: CGFloat in [710, 1110] {
            window.setContentSize(NSSize(width: width + 24, height: 564)); content.layoutSubtreeIfNeeded(); studio.layoutSubtreeIfNeeded()
            let scroll: NSScrollView = try find("prompt-editor-scroll", in: studio)
            try require(abs(studio.frame.width - width) < 1, "Editor does not fill available width")
            try require(scroll.frame.width >= 470 && scroll.frame.height >= 140, "Editor unusable at width \(width): \(scroll.frame)")
            let editorBounds = studio.convert(scroll.bounds, from: scroll)
            let saveBounds = studio.convert(save.bounds, from: save)
            try require(editorBounds.maxY < saveBounds.minY, "Actions overlap the editor")
            try require(studio.bounds.contains(saveBounds) && studio.bounds.contains(editorBounds), "Controls clipped outside component")
            try require(!studio.hasAmbiguousLayout && !scroll.hasAmbiguousLayout, "Ambiguous component layout")
        }
        try require(!window.isVisible, "Test window became visible")
        if let outputIndex = CommandLine.arguments.firstIndex(of: "--render"), CommandLine.arguments.indices.contains(outputIndex + 1) {
            let directory = CommandLine.arguments[outputIndex + 1]
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try capture(studio, window: window, width: 710, name: "prompt-narrow.png", directory: directory)
            try capture(studio, window: window, width: 1110, name: "prompt-wide.png", directory: directory)
            tabs.selectedSegment = 2; try action(tabs)
            try capture(studio, window: window, width: 710, name: "prompt-examples.png", directory: directory)
        }
    }
}
