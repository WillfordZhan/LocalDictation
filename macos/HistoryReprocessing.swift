import AppKit

/// A history edit is a separate saved version. This sheet never writes history,
/// changes the active prompt, starts recording or pastes into another application.
final class HistoryReprocessingWindowController: NSWindowController, NSWindowDelegate {
    let entryID: UUID
    var onRun: ((UUID, String, String) -> Void)?
    var onCopy: ((String) -> Void)?
    private var entry: DictationEntry?
    private var catalog: CleanupPromptCatalog?
    private var busy = false
    private var blockedByOtherEntry = false
    private var requestError: String?
    private var selectedPromptID: String?
    private var selectedModelID: String?
    private var selectedRevisionID: UUID?
    private let promptPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modelPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let resultPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sourcePicker = NSSegmentedControl(labels: ["ASR 原文", "原输出"], trackingMode: .selectOne, target: nil, action: nil)
    private let modelLabel = NSTextField(labelWithString: "")
    private let sourceMetadata = NSTextField(wrappingLabelWithString: "")
    private let resultMetadata = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let sourceText = NSTextView()
    private let resultText = NSTextView()
    private let runButton = NSButton(title: "开始测试", target: nil, action: nil)
    private let copyButton = NSButton(title: "复制此版本", target: nil, action: nil)
    private let closeButton = NSButton(title: "完成", target: nil, action: nil)

    init(entry: DictationEntry, catalog: CleanupPromptCatalog?) {
        self.entryID = entry.id; self.entry = entry; self.catalog = catalog
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 610),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "润色测试"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 760, height: 510); window.isReleasedWhenClosed = false
        window.backgroundColor = Palette.background
        super.init(window: window); window.delegate = self
        build(); update(entry: entry, catalog: catalog, busy: false, blockedByOtherEntry: false, error: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var revisions: [DictationRevision] {
        (entry?.revisions ?? []).sorted { $0.createdAt > $1.createdAt }
    }
    private var selectedRevision: DictationRevision? { revisions.first { $0.id == selectedRevisionID } }

    /// A result notification opens the exact saved version it refers to, even
    /// if an older comparison sheet is already retained by the main window.
    func selectRevision(id: UUID) {
        guard let index = revisions.firstIndex(where: { $0.id == id }) else { return }
        selectedRevisionID = id; resultPicker.selectItem(at: index)
        populateText(); refreshControls()
    }

    private func build() {
        guard let content = window?.contentView else { return }
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24), root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 20), root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])
        func add(_ view: NSView) { root.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        let heading = NSTextField(labelWithString: "润色测试"); heading.font = .systemFont(ofSize: 22, weight: .semibold)
        add(heading)
        modelLabel.font = .systemFont(ofSize: 11); modelLabel.textColor = Palette.muted
        modelLabel.lineBreakMode = .byTruncatingMiddle
        let ruleLabel = NSTextField(labelWithString: "规则")
        let selectionLabel = NSTextField(labelWithString: "模型")
        for label in [ruleLabel, selectionLabel] {
            label.font = .systemFont(ofSize: 12); label.textColor = Palette.muted
            label.setContentHuggingPriority(.required, for: .horizontal)
        }
        let controls = NSStackView(views: [ruleLabel, promptPicker, selectionLabel, modelPicker, runButton]); controls.spacing = 8
        for picker in [promptPicker, modelPicker] {
            picker.setContentHuggingPriority(.defaultLow, for: .horizontal)
            picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            (picker.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingTail
        }
        promptPicker.widthAnchor.constraint(equalTo: modelPicker.widthAnchor, multiplier: 1.15).isActive = true
        modelPicker.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        modelPicker.target = self; modelPicker.action = #selector(modelChanged)
        modelPicker.setAccessibilityLabel("本次测试的润色模型")
        promptPicker.target = self; promptPicker.action = #selector(promptChanged)
        promptPicker.setAccessibilityLabel("本次使用的润色规则")
        runButton.target = self; runButton.action = #selector(runPressed); runButton.bezelStyle = .rounded
        runButton.bezelColor = Palette.primaryFill; runButton.contentTintColor = .white
        runButton.widthAnchor.constraint(equalToConstant: 100).isActive = true
        add(controls); add(modelLabel)
        sourcePicker.selectedSegment = 0; sourcePicker.target = self; sourcePicker.action = #selector(sourceChanged)
        resultPicker.target = self; resultPicker.action = #selector(resultChanged)
        resultPicker.setAccessibilityLabel("已保存的整理版本")
        let left = textPane(header: sourcePicker, text: sourceText)
        let right = textPane(header: resultPicker, text: resultText)
        let comparison = NSStackView(views: [left, right]); comparison.spacing = 16; comparison.distribution = .fillEqually
        comparison.setContentHuggingPriority(.defaultLow, for: .vertical)
        comparison.heightAnchor.constraint(greaterThanOrEqualToConstant: 230).isActive = true
        left.heightAnchor.constraint(equalTo: comparison.heightAnchor).isActive = true
        right.heightAnchor.constraint(equalTo: comparison.heightAnchor).isActive = true
        add(comparison)
        for metadata in [sourceMetadata, resultMetadata] {
            metadata.font = .systemFont(ofSize: 11); metadata.textColor = Palette.muted
            metadata.maximumNumberOfLines = 3; metadata.lineBreakMode = .byTruncatingTail
        }
        let details = NSStackView(views: [sourceMetadata, resultMetadata]); details.spacing = 16
        details.alignment = .top; details.distribution = .fillEqually
        add(details)
        statusLabel.font = .systemFont(ofSize: 12); statusLabel.textColor = Palette.muted
        statusLabel.maximumNumberOfLines = 2
        copyButton.target = self; copyButton.action = #selector(copyPressed); copyButton.bezelStyle = .rounded
        closeButton.target = self; closeButton.action = #selector(closePressed); closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"
        let footer = NSStackView(views: [statusLabel, copyButton, closeButton]); footer.spacing = 12
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        add(footer)
    }

    private func textPane(header: NSView, text: NSTextView) -> NSView {
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.addArrangedSubview(header); header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .noBorder
        scroll.drawsBackground = true; scroll.backgroundColor = Palette.editorBackground
        scroll.wantsLayer = true; scroll.layer?.cornerRadius = 10
        text.isEditable = false; text.isSelectable = true; text.isRichText = false
        text.font = .systemFont(ofSize: 14); text.textColor = Palette.ink
        text.drawsBackground = false; text.textContainerInset = NSSize(width: 12, height: 12)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false; text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 360, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = text; stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        return stack
    }

    func update(entry: DictationEntry?, catalog: CleanupPromptCatalog?, busy: Bool, blockedByOtherEntry: Bool, error: String?) {
        let previousRevisions = revisions
        let knownIDs = Set(previousRevisions.map(\.id))
        let previousVersions = self.catalog?.versions
        let previousActiveID = self.catalog?.active_version_id
        let previousModels = self.catalog?.reprocessModels
        self.entry = entry; if let catalog { self.catalog = catalog }
        self.busy = busy; self.blockedByOtherEntry = blockedByOtherEntry; requestError = error
        if let added = revisions.first(where: { !knownIDs.contains($0.id) }) { selectedRevisionID = added.id }
        else if selectedRevision == nil { selectedRevisionID = revisions.first?.id }
        let versions = self.catalog?.versions ?? []
        if selectedPromptID == nil || !versions.contains(where: { $0.id == selectedPromptID }) {
            selectedPromptID = versions.first { $0.id == self.catalog?.active_version_id }?.id ?? versions.first?.id
        }
        // Health polling refreshes this sheet even while a popup is tracking
        // the pointer. Keep native menu items alive until their content changes;
        // removeAllItems() otherwise dismisses the user's in-progress choice.
        if promptPicker.numberOfItems == 0 || previousVersions != self.catalog?.versions
            || previousActiveID != self.catalog?.active_version_id {
            promptPicker.removeAllItems()
            for version in versions {
                promptPicker.addItem(withTitle: version.name + (version.id == self.catalog?.active_version_id ? " · 当前规则" : ""))
                promptPicker.lastItem?.representedObject = version.id
                promptPicker.lastItem?.toolTip = version.note
            }
            if let index = versions.firstIndex(where: { $0.id == selectedPromptID }) { promptPicker.selectItem(at: index) }
            if versions.isEmpty { promptPicker.addItem(withTitle: "正在加载润色规则…") }
        }
        let models = self.catalog?.reprocessModels ?? []
        if selectedModelID == nil || !models.contains(where: { $0.id == selectedModelID }) {
            selectedModelID = models.first { $0.id == self.catalog?.current_model.id }?.id
                ?? models.first { $0.ready }?.id ?? models.first?.id
        }
        if modelPicker.numberOfItems == 0 || previousModels != self.catalog?.reprocessModels {
            modelPicker.removeAllItems()
            for model in models {
                let title = model.name ?? model.id.components(separatedBy: "/").last ?? model.id
                modelPicker.addItem(withTitle: title + (model.ready ? "" : " · 未就绪"))
                modelPicker.lastItem?.representedObject = model.id
                modelPicker.lastItem?.toolTip = model.unavailable_reason ?? model.id
            }
            if let index = models.firstIndex(where: { $0.id == selectedModelID }) { modelPicker.selectItem(at: index) }
            if models.isEmpty { modelPicker.addItem(withTitle: "正在加载模型…") }
        }
        let currentRevisions = revisions
        let revisionMenuChanged = previousRevisions.count != currentRevisions.count
            || zip(previousRevisions, currentRevisions).contains { previous, current in
                previous.id != current.id || previous.createdAt != current.createdAt
                    || previous.cleanupProfile != current.cleanupProfile
            }
        if resultPicker.numberOfItems == 0 || revisionMenuChanged {
            resultPicker.removeAllItems()
            let date = DateFormatter(); date.dateFormat = "M/d HH:mm:ss"
            for (index, revision) in currentRevisions.enumerated() {
                resultPicker.addItem(withTitle: (index == 0 ? "最新结果 · " : "测试结果 · ") + date.string(from: revision.createdAt) + " · " + revision.cleanupProfile.name)
                resultPicker.lastItem?.representedObject = revision.id.uuidString
            }
            if let index = currentRevisions.firstIndex(where: { $0.id == selectedRevisionID }) { resultPicker.selectItem(at: index) }
            if currentRevisions.isEmpty { resultPicker.addItem(withTitle: "测试结果") }
        }
        if resultPicker.isEnabled != !currentRevisions.isEmpty { resultPicker.isEnabled = !currentRevisions.isEmpty }
        populateText(); refreshControls()
    }

    private func populateText() {
        let source = sourcePicker.selectedSegment == 0 ? (entry?.rawText ?? "") : (entry?.text ?? "")
        // TextView.string assignment resets selection and scrolling, even for
        // equal text. Background health updates must not interrupt comparison.
        if sourceText.string != source { sourceText.string = source }
        if let entry {
            let model = entry.cleanupProfile?.modelID.components(separatedBy: "/").last ?? "模型未记录"
            let rule = entry.cleanupProfile?.name ?? "规则未记录"
            let outcome = entry.cleanupOutcome?.completionTitle ?? (entry.cleanupApplied ? "已整理" : "未整理")
            sourceMetadata.stringValue = "原输出：\(rule) · \(model)\n" + String(format: "整理 %.2f 秒 · %@", entry.cleanupSeconds, outcome)
            sourceMetadata.toolTip = entry.cleanupProfile.map { "规则：\($0.versionID)\n模型：\($0.modelID)" }
        } else { sourceMetadata.stringValue = ""; sourceMetadata.toolTip = nil }
        let result = selectedRevision?.text ?? ""
        if resultText.string != result { resultText.string = result }
        if let revision = selectedRevision {
            let outcome = revision.cleanupOutcome?.completionTitle ?? "已整理"
            let load = revision.modelLoadSeconds.map { String(format: " · 加载 %.2f 秒", $0) } ?? ""
            resultMetadata.stringValue = "\(revision.cleanupProfile.name) · \(revision.cleanupProfile.modelID.components(separatedBy: "/").last ?? revision.cleanupProfile.modelID)\n" + String(format: "整理 %.2f 秒", revision.cleanupSeconds) + load + " · " + outcome
            resultMetadata.toolTip = "规则：\(revision.cleanupProfile.versionID)\n模型：\(revision.cleanupProfile.modelID)"
        } else { resultMetadata.stringValue = ""; resultMetadata.toolTip = nil }
        copyButton.isEnabled = selectedRevision != nil
    }
    private func refreshControls() {
        let model = catalog?.reprocessModels.first { $0.id == selectedModelID }
        let ready = model?.ready == true && selectedPromptID != nil && entry?.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        modelLabel.stringValue = model == nil ? "正在确认可用模型…"
            : model?.ready == false ? (model?.unavailable_reason ?? "此模型暂未就绪，请先在设置中完成配置。")
            : "仅用于本次测试，日常口述的规则和模型保持不变。"
        modelLabel.textColor = model?.ready == false ? .systemOrange : Palette.muted
        modelLabel.toolTip = model?.id
        runButton.isEnabled = ready && !busy && !blockedByOtherEntry && onRun != nil
        let canPickPrompt = !busy && !blockedByOtherEntry && !(catalog?.versions.isEmpty ?? true)
        let canPickModel = !busy && !blockedByOtherEntry && !(catalog?.reprocessModels.isEmpty ?? true)
        if promptPicker.isEnabled != canPickPrompt { promptPicker.isEnabled = canPickPrompt }
        if modelPicker.isEnabled != canPickModel { modelPicker.isEnabled = canPickModel }
        runButton.title = busy ? "正在测试…" : "开始测试"
        if let requestError, !requestError.isEmpty {
            statusLabel.stringValue = requestError + (selectedRevision == nil ? "" : " 右侧为已有版本。")
            statusLabel.textColor = .systemRed
        }
        else {
            statusLabel.textColor = Palette.muted
            let outcome = selectedRevision?.cleanupOutcome?.attentionMessage
            statusLabel.stringValue = entry == nil ? "这条历史记录已被删除。"
                : busy ? "正在测试，关闭后仍会完成并保存。"
                : blockedByOtherEntry ? "另一条历史正在测试。"
                : selectedRevision == nil ? "原输出保留，新结果另存为版本。" : (outcome.map { $0 + "。" } ?? "") + "新版本已保存，原输出保留。"
        }
    }
    func present(asSheetOf parent: NSWindow) {
        guard let window else { return }
        refreshControls()
        if window.sheetParent == nil { parent.beginSheet(window) { [weak window] _ in window?.orderOut(nil) } }
    }
    @objc private func promptChanged() { selectedPromptID = promptPicker.selectedItem?.representedObject as? String; refreshControls() }
    @objc private func modelChanged() { selectedModelID = modelPicker.selectedItem?.representedObject as? String; refreshControls() }
    @objc private func sourceChanged() { populateText() }
    @objc private func resultChanged() {
        selectedRevisionID = (resultPicker.selectedItem?.representedObject as? String).flatMap(UUID.init(uuidString:)); populateText()
    }
    @objc private func runPressed() {
        guard !busy, !blockedByOtherEntry, runButton.isEnabled, let id = selectedPromptID, let modelID = selectedModelID, let onRun else { return }
        busy = true; requestError = nil; refreshControls(); onRun(entryID, id, modelID)
    }
    @objc private func copyPressed() { if let revision = selectedRevision { onCopy?(revision.text) } }
    @objc private func closePressed() {
        guard let window else { return }
        if let parent = window.sheetParent { parent.endSheet(window) }
        window.orderOut(nil)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { closePressed(); return false }
    func renderPNG(to url: URL) throws {
        guard let view = window?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        // Hidden fixtures omit the window backing surface. Resolve its dynamic
        // color against this window so previews match the selected appearance.
        let image = NSImage(size: view.bounds.size); image.lockFocus()
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            Palette.background.setFill(); view.bounds.fill()
        }
        if let cgImage = bitmap.cgImage { NSImage(cgImage: cgImage, size: view.bounds.size).draw(in: view.bounds) }
        image.unlockFocus()
        if let tiff = image.tiffRepresentation, let rendered = NSBitmapImageRep(data: tiff) {
            try rendered.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
}
