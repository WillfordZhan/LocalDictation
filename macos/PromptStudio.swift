import AppKit

struct CleanupPromptExample: Codable, Equatable {
    let source: String
    let edited: String
}

struct CleanupPromptVersion: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let note: String
    let created_at: String
    let model_id: String?
    let system_prompt: String
    let user_prefix: String
    let examples: [CleanupPromptExample]
    let content_sha256: String
    let origin: String
    var draft: CleanupPromptDraft {
        CleanupPromptDraft(name: name, note: note, system_prompt: system_prompt,
                           user_prefix: user_prefix, examples: examples)
    }
}

struct CleanupPromptModel: Codable, Equatable {
    let id: String
    let kind: String
    let ready: Bool
}

struct CleanupPromptCatalog: Codable, Equatable {
    let active_version_id: String?
    let versions: [CleanupPromptVersion]
    let current_model: CleanupPromptModel
    let asr_model: String
    let prompt_store_error: String?
    let recovery_message: String?
    let prompt_import_error: String?

    init(active_version_id: String?, versions: [CleanupPromptVersion], current_model: CleanupPromptModel,
         asr_model: String, prompt_store_error: String? = nil, recovery_message: String? = nil,
         prompt_import_error: String? = nil) {
        self.active_version_id = active_version_id; self.versions = versions
        self.current_model = current_model; self.asr_model = asr_model
        self.prompt_store_error = prompt_store_error; self.recovery_message = recovery_message
        self.prompt_import_error = prompt_import_error
    }
}

struct CleanupPromptDraft: Encodable, Equatable {
    let name: String
    let note: String
    let system_prompt: String
    let user_prefix: String
    let examples: [CleanupPromptExample]
}

private final class PromptSurface: NSView {
    let color: NSColor
    init(color: NSColor = Palette.surface) {
        self.color = color; super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        color.setFill(); path.fill()
        Palette.border.setStroke(); path.lineWidth = 1; path.stroke()
    }
}

private final class PromptActionButton: NSButton {
    var invoke: (() -> Void)?
    init(_ title: String, primary: Bool = false, action: @escaping () -> Void) {
        super.init(frame: .zero)
        self.title = title; invoke = action; bezelStyle = .rounded
        font = .systemFont(ofSize: 12, weight: primary ? .semibold : .regular)
        translatesAutoresizingMaskIntoConstraints = false
        if primary { bezelColor = Palette.primaryFill; contentTintColor = .white }
        target = self; self.action = #selector(pressed)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func pressed() { invoke?() }
    func reserveWidth(for titles: [String]) {
        let font = self.font ?? .systemFont(ofSize: 12)
        let textWidth = titles.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        widthAnchor.constraint(equalToConstant: ceil(textWidth + 32)).isActive = true
    }
}

private final class PromptVersionRow: NSButton {
    private let select: () -> Void
    private let picked: Bool
    init(version: CleanupPromptVersion, selected: Bool, active: Bool, dirty: Bool, select: @escaping () -> Void) {
        self.select = select; picked = selected
        super.init(frame: .zero)
        title = ""; isBordered = false; translatesAutoresizingMaskIntoConstraints = false
        identifier = NSUserInterfaceItemIdentifier("prompt-version-" + version.id)
        setAccessibilityLabel(version.name + (active ? "，当前生效" : "") + (dirty ? "，有未保存修改" : ""))
        target = self; action = #selector(pressed)
        let name = NSTextField(labelWithString: version.name)
        name.font = .systemFont(ofSize: 12, weight: selected ? .semibold : .medium)
        name.textColor = selected ? Palette.blue : Palette.ink; name.lineBreakMode = .byTruncatingTail
        let date = Self.displayDate(version.created_at)
        toolTip = version.created_at
        let state = dirty ? "未保存修改" : active ? "当前生效" : version.origin == "user" ? "自定义" : "已保存"
        let detail = NSTextField(labelWithString: date + " · " + state)
        detail.font = .systemFont(ofSize: 11); detail.textColor = dirty ? Palette.warning : Palette.muted
        detail.lineBreakMode = .byTruncatingTail
        for label in [name, detail] {
            label.translatesAutoresizingMaskIntoConstraints = false; label.setAccessibilityElement(false); addSubview(label)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 58),
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            name.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            detail.leadingAnchor.constraint(equalTo: name.leadingAnchor), detail.trailingAnchor.constraint(equalTo: name.trailingAnchor),
            detail.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 5)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private static func displayDate(_ timestamp: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractionalDate = parser.date(from: timestamp)
        parser.formatOptions = [.withInternetDateTime]
        guard let date = fractionalDate ?? parser.date(from: timestamp) else { return String(timestamp.prefix(16)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "MM.dd HH:mm"
        return formatter.string(from: date)
    }
    @objc private func pressed() { select() }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func draw(_ dirtyRect: NSRect) {
        (picked ? Palette.blueWash : isHighlighted ? Palette.hover : .clear).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
}

/// A retained editor, independent of network requests and persistent storage.
/// Keep this instance when navigating away: drafts belong to their source
/// versions and survive tab changes, refreshes and failed save requests.
final class PromptStudioView: NSView, NSTextViewDelegate, NSTextFieldDelegate {
    var onSave: ((CleanupPromptDraft) -> Void)?
    var onActivate: ((String) -> Void)?
    var onReload: (() -> Void)?

    private struct EditingDraft: Equatable {
        var name: String
        var note: String
        var systemPrompt: String
        var userPrefix: String
        var examplesJSON: String
        init(_ version: CleanupPromptVersion) {
            name = version.name; note = version.note; systemPrompt = version.system_prompt; userPrefix = version.user_prefix
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            examplesJSON = String(data: (try? encoder.encode(version.examples)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
        }
        func payload() throws -> CleanupPromptDraft {
            // Codable ignores unknown keys. Reject them here so a typo cannot
            // silently remove part of an example when saving a new version.
            let json = try JSONSerialization.jsonObject(with: Data(examplesJSON.utf8))
            guard let pairs = json as? [[String: Any]], pairs.allSatisfy({
                Set($0.keys) == Set(["source", "edited"]) && $0["source"] is String && $0["edited"] is String
            }) else { throw NSError(domain: "PromptExamples", code: 1) }
            let examples = try JSONDecoder().decode([CleanupPromptExample].self, from: Data(examplesJSON.utf8))
            return CleanupPromptDraft(name: name.trimmingCharacters(in: .whitespacesAndNewlines), note: note,
                system_prompt: systemPrompt, user_prefix: userPrefix, examples: examples)
        }
    }
    private struct SaveAttempt {
        let sourceID: String
        let sourceDraft: EditingDraft
        let payload: CleanupPromptDraft
        let priorIDs: Set<String>
    }
    private var catalog: CleanupPromptCatalog?
    private var selectedID: String?
    private var requestedID: String?
    private var drafts: [String: EditingDraft] = [:]
    private var pendingSave: SaveAttempt?
    private var pendingActivation: String?
    private var confirmedAction: (versionID: String, message: String, requiresActive: Bool)?
    private var busy = false
    private var requestError: String?
    private var selectionError: String?
    private var populating = false
    private var selectedTab = 0
    private var currentDraft: EditingDraft? { selectedID.flatMap { drafts[$0] } }
    private var selectedVersion: CleanupPromptVersion? { catalog?.versions.first { $0.id == selectedID } }
    private var selectedIsDirty: Bool {
        guard let currentDraft, let selectedVersion else { return false }
        return currentDraft != EditingDraft(selectedVersion)
    }
    var hasUnsavedChanges: Bool {
        guard let catalog else { return !drafts.isEmpty }
        return catalog.versions.contains { version in drafts[version.id].map { $0 != EditingDraft(version) } ?? false }
    }
    private let modelLabel = PromptStudioView.label("正在读取润色模型…", size: 12)
    private let flowLabel = PromptStudioView.label("ASR 识别  →  模型润色  →  自动填入", size: 13, weight: .semibold)
    private let list = NSStackView()
    private let countLabel = PromptStudioView.label("版本", size: 13, weight: .semibold)
    private let nameField = NSTextField()
    private let noteField = NSTextField()
    private let provenance = PromptStudioView.label("", size: 11, color: Palette.muted)
    private let tabHelp = PromptStudioView.label("", size: 11, color: Palette.muted)
    private let tabs = NSSegmentedControl()
    private let editor = NSTextView(frame: .zero)
    private let feedback = PromptStudioView.label("", size: 11, color: Palette.muted)
    private var reloadButton: PromptActionButton!
    private var saveButton: PromptActionButton!
    private var activateButton: PromptActionButton!

    override var isFlipped: Bool { true }
    init() {
        super.init(frame: .zero); translatesAutoresizingMaskIntoConstraints = false
        identifier = NSUserInterfaceItemIdentifier("prompt-studio")
        build(); update(catalog: nil, busy: false, error: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func label(_ value: String, size: CGFloat = 12, weight: NSFont.Weight = .regular, color: NSColor = Palette.ink) -> NSTextField {
        let view = NSTextField(wrappingLabelWithString: value)
        view.font = .systemFont(ofSize: size, weight: weight); view.textColor = color
        view.translatesAutoresizingMaskIntoConstraints = false; return view
    }
    private func stack(_ orientation: NSUserInterfaceLayoutOrientation, spacing: CGFloat) -> NSStackView {
        let view = NSStackView(); view.orientation = orientation; view.spacing = spacing
        view.alignment = orientation == .vertical ? .leading : .centerY
        view.translatesAutoresizingMaskIntoConstraints = false; return view
    }
    private func add(_ child: NSView, to stack: NSStackView) {
        child.translatesAutoresizingMaskIntoConstraints = false; stack.addArrangedSubview(child)
        if stack.orientation == .vertical { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }
    private func pin(_ child: NSView, to parent: NSView, inset: CGFloat = 0) {
        child.translatesAutoresizingMaskIntoConstraints = false; parent.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
        ])
    }

    private func build() {
        let root = stack(.vertical, spacing: 12); pin(root, to: self)
        let pipeline = stack(.vertical, spacing: 5)
        modelLabel.maximumNumberOfLines = 1; modelLabel.lineBreakMode = .byTruncatingTail
        add(flowLabel, to: pipeline); add(modelLabel, to: pipeline)
        let pipelineCard = PromptSurface(color: Palette.blueWash); pin(pipeline, to: pipelineCard, inset: 14); add(pipelineCard, to: root)
        pipelineCard.setContentHuggingPriority(.required, for: .vertical)
        let body = stack(.horizontal, spacing: 14); body.alignment = .top; add(body, to: root)
        let left = PromptSurface(color: Palette.sidebar), right = PromptSurface()
        body.addArrangedSubview(left); body.addArrangedSubview(right)
        NSLayoutConstraint.activate([
            left.widthAnchor.constraint(equalToConstant: 180),
            right.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -194),
            left.heightAnchor.constraint(equalTo: body.heightAnchor), right.heightAnchor.constraint(equalTo: body.heightAnchor)
        ])
        let versionColumn = stack(.vertical, spacing: 10); pin(versionColumn, to: left, inset: 12)
        add(countLabel, to: versionColumn)
        let versionScroll = NSScrollView(); versionScroll.drawsBackground = false; versionScroll.hasVerticalScroller = true
        let document = PromptSurface(color: Palette.sidebar); versionScroll.documentView = document
        document.widthAnchor.constraint(equalTo: versionScroll.contentView.widthAnchor).isActive = true
        list.orientation = .vertical; list.alignment = .leading; list.spacing = 4; list.translatesAutoresizingMaskIntoConstraints = false
        pin(list, to: document); add(versionScroll, to: versionColumn)
        versionScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        reloadButton = PromptActionButton("刷新版本") { [weak self] in self?.onReload?() }
        reloadButton.identifier = NSUserInterfaceItemIdentifier("prompt-reload"); add(reloadButton, to: versionColumn)
        let editing = stack(.vertical, spacing: 9); pin(editing, to: right, inset: 16)
        nameField.placeholderString = "例如：自然表达 · 第二版"; nameField.delegate = self
        nameField.font = .systemFont(ofSize: 13); nameField.identifier = NSUserInterfaceItemIdentifier("prompt-name")
        nameField.setAccessibilityLabel("版本名称"); add(nameField, to: editing)
        noteField.placeholderString = "调优说明（可选）"; noteField.delegate = self
        noteField.font = .systemFont(ofSize: 12); noteField.identifier = NSUserInterfaceItemIdentifier("prompt-note")
        noteField.setAccessibilityLabel("调优说明"); add(noteField, to: editing)
        provenance.identifier = NSUserInterfaceItemIdentifier("prompt-provenance"); add(provenance, to: editing)
        tabs.segmentCount = 3; tabs.trackingMode = .selectOne; tabs.selectedSegment = 0; tabs.segmentStyle = .rounded
        for (index, value) in ["系统规则", "输入说明", "示例"].enumerated() { tabs.setLabel(value, forSegment: index) }
        tabs.target = self; tabs.action = #selector(changeTab); tabs.identifier = NSUserInterfaceItemIdentifier("prompt-tabs")
        add(tabs, to: editing); add(tabHelp, to: editing)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = true
        scroll.backgroundColor = Palette.editorBackground; scroll.borderType = .bezelBorder
        scroll.identifier = NSUserInterfaceItemIdentifier("prompt-editor-scroll")
        editor.isRichText = false; editor.isEditable = true; editor.isSelectable = true
        editor.font = .systemFont(ofSize: 13); editor.textColor = Palette.ink; editor.backgroundColor = scroll.backgroundColor
        editor.insertionPointColor = Palette.ink
        editor.textContainerInset = NSSize(width: 10, height: 10); editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false
        editor.delegate = self; editor.identifier = NSUserInterfaceItemIdentifier("prompt-editor")
        editor.setAccessibilityLabel("系统规则编辑器")
        scroll.documentView = editor; add(scroll, to: editing)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        scroll.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        feedback.identifier = NSUserInterfaceItemIdentifier("prompt-feedback"); add(feedback, to: editing)
        let actions = stack(.horizontal, spacing: 8)
        saveButton = PromptActionButton("保存为新版本", primary: true) { [weak self] in self?.saveDraft() }
        activateButton = PromptActionButton("启用此版本") { [weak self] in self?.activateSelection() }
        saveButton.identifier = NSUserInterfaceItemIdentifier("prompt-save"); activateButton.identifier = NSUserInterfaceItemIdentifier("prompt-activate")
        saveButton.reserveWidth(for: ["保存为新版本", "保存中…"])
        activateButton.reserveWidth(for: ["启用此版本", "当前已生效", "启用中…"])
        actions.addArrangedSubview(saveButton); actions.addArrangedSubview(activateButton)
        let spacer = NSView(); spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal); actions.addArrangedSubview(spacer)
        add(actions, to: editing)
        for item in [nameField, noteField, provenance, tabs, tabHelp, feedback, actions] {
            item.setContentHuggingPriority(.required, for: .vertical)
        }
    }

    func update(catalog: CleanupPromptCatalog?, busy: Bool, error: String?) {
        let oldSelection = selectedID
        var confirmed = false
        self.busy = busy; requestError = error
        // Only a returned immutable version or the returned active ID confirms
        // an action. A click, a generic refresh, or a missing callback cannot.
        if let attempt = pendingSave, !busy {
            if error == nil, let saved = catalog?.versions.first(where: { !attempt.priorIDs.contains($0.id) && $0.draft == attempt.payload }) {
                if drafts[attempt.sourceID] == attempt.sourceDraft { drafts.removeValue(forKey: attempt.sourceID) }
                selectedID = saved.id; drafts[saved.id] = EditingDraft(saved); requestedID = nil
                confirmedAction = (saved.id, "已保存，可启用此版本", false)
                confirmed = true
            } else if error == nil {
                requestError = "尚未确认新版本，修改仍在。请刷新后重试。"
            }
            pendingSave = nil
        }
        if let activatedID = pendingActivation, !busy {
            if error == nil, catalog?.active_version_id == activatedID {
                confirmedAction = (activatedID, "已启用，下次录音生效", true)
                confirmed = true
            } else if error == nil {
                requestError = "启用结果尚未确认，请刷新版本。"
            }
            pendingActivation = nil
        }
        if let catalog {
            self.catalog = catalog
            if let requestedID {
                if catalog.versions.contains(where: { $0.id == requestedID }) { selectedID = requestedID; selectionError = nil }
                else { selectedID = nil; selectionError = "找不到这条历史使用的规则版本：\(requestedID)。未切换到其他版本。" }
            } else if selectedID == nil || !catalog.versions.contains(where: { $0.id == selectedID }) {
                selectedID = catalog.versions.first { $0.id == catalog.active_version_id }?.id ?? catalog.versions.first?.id
            }
            if let version = selectedVersion, drafts[version.id] == nil { drafts[version.id] = EditingDraft(version) }
            let location = catalog.current_model.kind == "local" ? "本机" : catalog.current_model.kind
            modelLabel.stringValue = "识别：\(catalog.asr_model.components(separatedBy: "/").last ?? catalog.asr_model)  ·  润色：\(catalog.current_model.id.components(separatedBy: "/").last ?? catalog.current_model.id)\(catalog.current_model.ready ? "" : " · 暂未就绪")"
            modelLabel.toolTip = "识别：\(catalog.asr_model)\n润色：\(catalog.current_model.id) · \(location)"
        } else if self.catalog == nil {
            modelLabel.stringValue = busy ? "正在读取模型与已保存的规则…" : "服务就绪后可查看模型和规则。"
        }
        renderVersionList()
        if confirmed { DictationMotion.reveal(list, duration: 0.1) }
        if oldSelection != selectedID || editor.string.isEmpty && !selectedIsDirty { populateFields() }
        refreshControls()
    }

    /// History can open its recorded version before a catalog request completes.
    /// A missing reference stays missing; showing today's active rule would lie.
    func selectVersion(id: String) {
        rememberFields(); requestedID = id; confirmedAction = nil
        guard let catalog else { selectedID = nil; selectionError = nil; populateFields(); refreshControls(); return }
        if let version = catalog.versions.first(where: { $0.id == id }) {
            selectedID = id; selectionError = nil
            if drafts[id] == nil { drafts[id] = EditingDraft(version) }
        } else {
            selectedID = nil; selectionError = "找不到这条历史使用的规则版本：\(id)。未切换到其他版本。"
        }
        populateFields(); renderVersionList(); refreshControls()
    }
    private func renderVersionList() {
        for view in list.arrangedSubviews { list.removeArrangedSubview(view); view.removeFromSuperview() }
        let versions = catalog?.versions ?? []; countLabel.stringValue = "版本 · \(versions.count)"
        for version in versions {
            let row = PromptVersionRow(version: version, selected: version.id == selectedID,
                active: version.id == catalog?.active_version_id,
                dirty: drafts[version.id].map { $0 != EditingDraft(version) } ?? false) { [weak self] in self?.selectVersion(id: version.id) }
            row.isEnabled = !busy; add(row, to: list)
        }
        if versions.isEmpty { add(Self.label("暂无可读取的版本", size: 11, color: Palette.muted), to: list) }
    }
    private func populateFields() {
        populating = true
        nameField.stringValue = currentDraft?.name ?? ""; noteField.stringValue = currentDraft?.note ?? ""
        populateEditor(); populating = false
    }
    private func populateEditor() {
        populating = true; defer { populating = false }
        switch selectedTab {
        case 1:
            editor.string = currentDraft?.userPrefix ?? ""
            tabHelp.isHidden = true
            editor.font = .systemFont(ofSize: 13); editor.setAccessibilityLabel("输入说明编辑器")
        case 2:
            editor.string = currentDraft?.examplesJSON ?? "[]"
            tabHelp.isHidden = false; tabHelp.stringValue = "JSON 示例：source 为原文，edited 为期望输出。"
            editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular); editor.setAccessibilityLabel("示例 JSON 编辑器")
        default:
            editor.string = currentDraft?.systemPrompt ?? ""
            tabHelp.isHidden = true
            editor.font = .systemFont(ofSize: 13); editor.setAccessibilityLabel("系统规则编辑器")
        }
        editor.setSelectedRange(NSRange(location: 0, length: 0)); editor.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }
    private func rememberFields() {
        guard !populating, let id = selectedID, var draft = drafts[id] else { return }
        draft.name = nameField.stringValue; draft.note = noteField.stringValue
        switch selectedTab { case 1: draft.userPrefix = editor.string; case 2: draft.examplesJSON = editor.string; default: draft.systemPrompt = editor.string }
        drafts[id] = draft
    }
    @objc private func changeTab() {
        rememberFields(); selectedTab = tabs.selectedSegment; populateEditor(); refreshControls()
    }
    func controlTextDidChange(_ notification: Notification) {
        guard !populating else { return }; confirmedAction = nil; rememberFields(); renderVersionList(); refreshControls()
    }
    func textDidChange(_ notification: Notification) {
        guard !populating else { return }; confirmedAction = nil; rememberFields(); renderVersionList(); refreshControls()
    }
    private func validationIssue() -> String? {
        guard let draft = currentDraft else { return nil }
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请填写版本名称。" }
        if draft.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "系统规则不能为空。" }
        do { _ = try draft.payload() }
        catch { return "示例格式不正确。请使用包含 source 和 edited 字符串的 JSON 数组。" }
        return nil
    }
    private func refreshControls() {
        let previousFeedback = feedback.stringValue
        let available = selectedVersion != nil
        nameField.isEnabled = available && !busy; noteField.isEnabled = available && !busy
        editor.isEditable = available && !busy; tabs.isEnabled = available && !busy; reloadButton.isEnabled = !busy
        let issue = validationIssue()
        saveButton.isEnabled = available && !busy && selectedIsDirty && issue == nil
        activateButton.isEnabled = available && !busy && !selectedIsDirty && selectedID != catalog?.active_version_id
        saveButton.title = busy && pendingSave != nil ? "保存中…" : "保存为新版本"
        activateButton.title = busy && pendingActivation != nil ? "启用中…"
            : selectedID != nil && selectedID == catalog?.active_version_id ? "当前已生效" : "启用此版本"
        reloadButton.title = busy && pendingSave == nil && pendingActivation == nil ? "刷新中…" : "刷新版本"
        if let version = selectedVersion {
            provenance.stringValue = "保存时模型：\(version.model_id?.components(separatedBy: "/").last ?? "未记录")"
            provenance.toolTip = version.model_id
        } else { provenance.stringValue = ""; provenance.toolTip = nil }
        if let error = [selectionError, requestError, catalog?.prompt_store_error, catalog?.prompt_import_error]
            .compactMap({ $0 }).first(where: { !$0.isEmpty }) {
            feedback.stringValue = error + (hasUnsavedChanges ? " 未保存的修改仍在，可重试。" : ""); feedback.textColor = Palette.warning
        } else if let issue {
            feedback.stringValue = issue; feedback.textColor = Palette.warning
        } else if let recovery = catalog?.recovery_message, !recovery.isEmpty, !busy {
            feedback.stringValue = recovery; feedback.textColor = Palette.muted
        } else if !busy, let confirmedAction, confirmedAction.versionID == selectedID,
                  !confirmedAction.requiresActive || catalog?.active_version_id == confirmedAction.versionID {
            feedback.stringValue = confirmedAction.message; feedback.textColor = Palette.blue
        } else {
            feedback.textColor = Palette.muted
            feedback.stringValue = busy ? (pendingSave != nil ? "正在保存新版本…" : pendingActivation != nil ? "正在启用所选版本…" : "正在读取版本…")
                : selectedIsDirty ? "有未保存修改" : available ? "启用后从下一次录音生效" : "连接本地服务后，点击“刷新版本”。"
        }
        if previousFeedback != feedback.stringValue { DictationMotion.reveal(feedback, duration: 0.1) }
    }
    private func saveDraft() {
        rememberFields()
        guard !busy, let id = selectedID, let draft = currentDraft, selectedIsDirty,
              validationIssue() == nil, let payload = try? draft.payload(), let onSave else { refreshControls(); return }
        pendingSave = SaveAttempt(sourceID: id, sourceDraft: draft, payload: payload, priorIDs: Set(catalog?.versions.map(\.id) ?? []))
        confirmedAction = nil; requestError = nil
        busy = true; refreshControls(); renderVersionList()
        onSave(payload)
    }
    private func activateSelection() {
        guard !busy, !selectedIsDirty, let id = selectedID, id != catalog?.active_version_id, let onActivate else { return }
        pendingActivation = id; confirmedAction = nil; requestError = nil
        busy = true; refreshControls(); renderVersionList()
        onActivate(id)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { DictationMotion.cancel(feedback); DictationMotion.cancel(list) }
    }
}
