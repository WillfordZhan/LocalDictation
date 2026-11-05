import AppKit

/// A history edit is a separate saved version. This sheet never writes history,
/// changes the active prompt, starts recording or pastes into another application.
final class HistoryReprocessingWindowController: NSWindowController, NSWindowDelegate {
    let entryID: UUID
    var onRun: ((UUID, String) -> Void)?
    var onCopy: ((String) -> Void)?
    private var entry: DictationEntry?
    private var catalog: CleanupPromptCatalog?
    private var busy = false
    private var blockedByOtherEntry = false
    private var requestError: String?
    private var selectedPromptID: String?
    private var selectedRevisionID: UUID?
    private let promptPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let resultPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sourcePicker = NSSegmentedControl(labels: ["原输出", "ASR 原文"], trackingMode: .selectOne, target: nil, action: nil)
    private let modelLabel = NSTextField(labelWithString: "")
    private let resultMetadata = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let sourceText = NSTextView()
    private let resultText = NSTextView()
    private let runButton = NSButton(title: "重新整理", target: nil, action: nil)
    private let copyButton = NSButton(title: "复制此版本", target: nil, action: nil)
    private let closeButton = NSButton(title: "完成", target: nil, action: nil)

    init(entry: DictationEntry, catalog: CleanupPromptCatalog?) {
        self.entryID = entry.id; self.entry = entry; self.catalog = catalog
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 610),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "重新整理历史"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 760, height: 510); window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua); window.backgroundColor = .white
        super.init(window: window); window.delegate = self
        build(); update(entry: entry, catalog: catalog, busy: false, blockedByOtherEntry: false, error: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var revisions: [DictationRevision] {
        (entry?.revisions ?? []).sorted { $0.createdAt > $1.createdAt }
    }
    private var selectedRevision: DictationRevision? { revisions.first { $0.id == selectedRevisionID } }

    private func build() {
        guard let content = window?.contentView else { return }
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 16
        root.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24), root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 20), root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])
        func add(_ view: NSView) { root.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        let heading = NSTextField(labelWithString: "重新整理"); heading.font = .systemFont(ofSize: 22, weight: .semibold)
        add(heading)
        modelLabel.font = .systemFont(ofSize: 11); modelLabel.textColor = Palette.muted
        modelLabel.lineBreakMode = .byTruncatingMiddle
        let controls = NSStackView(views: [promptPicker, runButton]); controls.spacing = 10
        promptPicker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        promptPicker.target = self; promptPicker.action = #selector(promptChanged)
        promptPicker.setAccessibilityLabel("本次使用的润色规则")
        runButton.target = self; runButton.action = #selector(runPressed); runButton.bezelStyle = .rounded
        runButton.bezelColor = Palette.blue; runButton.contentTintColor = .white
        runButton.widthAnchor.constraint(equalToConstant: 100).isActive = true
        add(controls); add(modelLabel)
        sourcePicker.selectedSegment = 0; sourcePicker.target = self; sourcePicker.action = #selector(sourceChanged)
        resultPicker.target = self; resultPicker.action = #selector(resultChanged)
        resultPicker.setAccessibilityLabel("已保存的整理版本")
        let left = textPane(header: sourcePicker, text: sourceText)
        let right = textPane(header: resultPicker, text: resultText)
        let comparison = NSStackView(views: [left, right]); comparison.spacing = 16; comparison.distribution = .fillEqually
        comparison.setContentHuggingPriority(.defaultLow, for: .vertical)
        comparison.heightAnchor.constraint(greaterThanOrEqualToConstant: 250).isActive = true
        left.heightAnchor.constraint(equalTo: comparison.heightAnchor).isActive = true
        right.heightAnchor.constraint(equalTo: comparison.heightAnchor).isActive = true
        add(comparison)
        resultMetadata.font = .systemFont(ofSize: 11); resultMetadata.textColor = Palette.muted
        resultMetadata.lineBreakMode = .byTruncatingMiddle; add(resultMetadata)
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
        scroll.drawsBackground = true; scroll.backgroundColor = NSColor(white: 0.975, alpha: 1)
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
        let knownIDs = Set(revisions.map(\.id))
        self.entry = entry; if let catalog { self.catalog = catalog }
        self.busy = busy; self.blockedByOtherEntry = blockedByOtherEntry; requestError = error
        if let added = revisions.first(where: { !knownIDs.contains($0.id) }) { selectedRevisionID = added.id }
        else if selectedRevision == nil { selectedRevisionID = revisions.first?.id }
        let versions = self.catalog?.versions ?? []
        if selectedPromptID == nil || !versions.contains(where: { $0.id == selectedPromptID }) {
            selectedPromptID = versions.first { $0.id == self.catalog?.active_version_id }?.id ?? versions.first?.id
        }
        promptPicker.removeAllItems()
        for version in versions {
            promptPicker.addItem(withTitle: version.name + (version.id == self.catalog?.active_version_id ? " · 当前规则" : ""))
            promptPicker.lastItem?.representedObject = version.id
            promptPicker.lastItem?.toolTip = version.note
        }
        if let index = versions.firstIndex(where: { $0.id == selectedPromptID }) { promptPicker.selectItem(at: index) }
        if versions.isEmpty { promptPicker.addItem(withTitle: "正在加载润色规则…") }
        if let model = self.catalog?.current_model {
            modelLabel.stringValue = "润色模型  " + (model.id.components(separatedBy: "/").last ?? model.id) + (model.ready ? "" : " · 暂未就绪")
            modelLabel.toolTip = model.id
        } else { modelLabel.stringValue = "正在确认润色模型…" }
        resultPicker.removeAllItems()
        let date = DateFormatter(); date.dateFormat = "M/d HH:mm:ss"
        for (index, revision) in revisions.enumerated() {
            resultPicker.addItem(withTitle: (index == 0 ? "最新 · " : "") + date.string(from: revision.createdAt) + " · " + revision.cleanupProfile.name)
            resultPicker.lastItem?.representedObject = revision.id.uuidString
        }
        if let index = revisions.firstIndex(where: { $0.id == selectedRevisionID }) { resultPicker.selectItem(at: index) }
        if revisions.isEmpty { resultPicker.addItem(withTitle: "暂无新版本") }
        resultPicker.isEnabled = !revisions.isEmpty
        populateText(); refreshControls()
    }

    private func populateText() {
        sourceText.string = sourcePicker.selectedSegment == 1 ? (entry?.rawText ?? "") : (entry?.text ?? "")
        resultText.string = selectedRevision?.text ?? ""
        if let revision = selectedRevision {
            let date = DateFormatter(); date.dateFormat = "yyyy.M.d HH:mm:ss"
            resultMetadata.stringValue = "\(revision.cleanupProfile.name)  ·  \(revision.cleanupProfile.modelID.components(separatedBy: "/").last ?? revision.cleanupProfile.modelID)  ·  \(date.string(from: revision.createdAt))"
            resultMetadata.toolTip = "规则：\(revision.cleanupProfile.versionID)\n模型：\(revision.cleanupProfile.modelID)"
        } else { resultMetadata.stringValue = ""; resultMetadata.toolTip = nil }
        copyButton.isEnabled = selectedRevision != nil
    }
    private func refreshControls() {
        let ready = catalog?.current_model.ready == true && selectedPromptID != nil && entry?.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        runButton.isEnabled = ready && !busy && !blockedByOtherEntry && onRun != nil
        promptPicker.isEnabled = !busy && !blockedByOtherEntry && !(catalog?.versions.isEmpty ?? true)
        runButton.title = busy ? "正在整理…" : "重新整理"
        if let requestError, !requestError.isEmpty { statusLabel.stringValue = requestError; statusLabel.textColor = .systemRed }
        else {
            statusLabel.textColor = Palette.muted
            statusLabel.stringValue = entry == nil ? "这条历史记录已被删除。"
                : busy ? "关闭后仍会完成并保存。"
                : blockedByOtherEntry ? "另一条历史正在整理。"
                : selectedRevision == nil ? "原输出保留，新结果另存为版本。" : "新版本已保存，原输出保留。"
        }
    }
    func present(asSheetOf parent: NSWindow) {
        guard let window else { return }
        refreshControls()
        if window.sheetParent == nil { parent.beginSheet(window) { [weak window] _ in window?.orderOut(nil) } }
    }
    @objc private func promptChanged() { selectedPromptID = promptPicker.selectedItem?.representedObject as? String; refreshControls() }
    @objc private func sourceChanged() { populateText() }
    @objc private func resultChanged() {
        selectedRevisionID = (resultPicker.selectedItem?.representedObject as? String).flatMap(UUID.init(uuidString:)); populateText()
    }
    @objc private func runPressed() {
        guard !busy, !blockedByOtherEntry, runButton.isEnabled, let id = selectedPromptID, let onRun else { return }
        busy = true; requestError = nil; refreshControls(); onRun(entryID, id)
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
        // Hidden fixtures do not include NSWindow's white backing surface.
        // Composite the actual content bitmap over that same background.
        let image = NSImage(size: view.bounds.size); image.lockFocus()
        NSColor.white.setFill(); view.bounds.fill()
        if let cgImage = bitmap.cgImage { NSImage(cgImage: cgImage, size: view.bounds.size).draw(in: view.bounds) }
        image.unlockFocus()
        if let tiff = image.tiffRepresentation, let rendered = NSBitmapImageRep(data: tiff) {
            try rendered.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
}
