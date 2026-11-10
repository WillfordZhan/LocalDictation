import AppKit
import QuartzCore

enum DictationCleanupBackend: String {
    case local, cloud
}

/// Loading a model and receiving an edited result are separate facts. These
/// states come from the health response, never from the ability to record.
enum DictationModelReadiness {
    case checking, loading, ready, unavailable

    var title: String {
        switch self {
        case .checking: return "待确认"
        case .loading: return "加载中"
        case .ready: return "已就绪"
        case .unavailable: return "不可用"
        }
    }
    var color: NSColor {
        switch self {
        case .ready: return Palette.blue
        case .unavailable: return Palette.warning
        case .checking, .loading: return Palette.muted
        }
    }
}

extension DictationEntry {
    // A successful response can legitimately leave a short sentence unchanged.
    // Report that observable result without claiming either semantic success
    // or a skipped model call; cleanupApplied records the invocation outcome.
    var cleanupResultDescription: String {
        if cleanupApplied { return rawText == text ? "已调用 · 文本未变" : "已调用 · 文本已修改" }
        return warning?.isEmpty == false ? "整理未完成，已保留原文" : "未应用整理"
    }
    var cleanupResultTitle: String {
        cleanupApplied ? (rawText == text ? "模型输出（文本未变）" : "整理结果") : "最终输出（未整理）"
    }
}

struct DictationUIState {
    var status = "准备就绪"
    var serviceMessage = "正在准备本地模型…"
    var serviceReady = false
    var asrReadiness: DictationModelReadiness = .checking
    var cleanupReadiness: DictationModelReadiness = .checking
    var asrModel: String?
    var cleanupModel: String?
    var recording = false
    var processing = false
    // Recording and previously submitted utterances have independent lifetimes.
    var sessionLabel = ""
    var pendingCount = 0
    var processingStage: String?
    var processingProgress: Double?
    var processingComplete = false
    var recognizedSeconds: Double?
    var cleanupEnabled = true
    // nil means no usable backend report yet, rather than an assumed local mode.
    var cleanupBackend: DictationCleanupBackend?
    var autoInsertEnabled = true
    var canStart = false
    var canCancel = false
    var elapsedSeconds = 0
    var meterLevel: Double = 0
    var meterPeakLevel: Double = 0
    var waveformStyle: DictationWaveformStyle = .lively
    var microphoneAllowed = false
    var accessibilityAllowed = false
    var automaticInsertionPermissionDetails = ""
    var detail = ""
    var lastEntryID: UUID?
    var preview = false
    var shortcutDisplay = "Fn"
    var shortcutWarning = ""
    var canEditShortcut = true
    var functionKeyMessage = "Fn 未启用，需要允许输入监控。"
    var inputMonitoringAllowed = false
    var functionKeySelected = true
    var functionKeyEnabled = false
    var fallbackShortcut: String?

    var homeProcessingDescription: String {
        guard cleanupEnabled else { return "语音在本机识别。文字整理已关闭，仅保留本地转写。" }
        switch cleanupBackend {
        case .cloud: return "本地识别，云端整理。仅本次转写文本发送到云端。"
        case .local: return "按下快捷键，专心表达。识别与整理都在本机完成。"
        case nil: return "语音在本机识别。正在确认文字整理方式…"
        }
    }

    func cleanupSettingDescription(enabled: Bool) -> String {
        let editing = "去掉赘词和重复，转成自然书面语，按内容适度分点，保留原意与个人表达。"
        let disabled = enabled ? "" : "文字整理已关闭，仅本地转写。\n"
        switch cleanupBackend {
        case .cloud:
            return disabled + editing + "\n开启后仅本次转写文本发送到云端；录音、历史记录和个人词典留在本机。关闭后仅本地转写。"
        case .local:
            return disabled + editing + "\n识别与整理均在本机完成。关闭后仅本地转写。"
        case nil:
            return disabled + editing + "\n语音在本机识别，整理方式等待服务状态确认。关闭后仅本地转写。"
        }
    }
}

enum DictationPage: String, CaseIterable {
    case home, history, dictionary, prompts, settings
    var title: String { switch self { case .home: return "首页"; case .history: return "历史记录"; case .dictionary: return "个人词典"; case .prompts: return "润色规则"; case .settings: return "设置" } }
    var icon: String { switch self { case .home: return "house"; case .history: return "clock.arrow.circlepath"; case .dictionary: return "book.closed"; case .prompts: return "slider.horizontal.3"; case .settings: return "gearshape" } }
}

enum Palette {
    static let ink = NSColor(calibratedWhite: 0.10, alpha: 1)
    static let secondary = NSColor(calibratedWhite: 0.32, alpha: 1)
    // Explicit sRGB keeps small text readable on white and the light sidebar.
    // Calibrated gray is substantially lighter after display-space conversion.
    static let muted = NSColor(srgbRed: 0.44, green: 0.44, blue: 0.44, alpha: 1)
    static let blue = NSColor(srgbRed: 0.16, green: 0.39, blue: 0.92, alpha: 1)
    static let warning = NSColor(srgbRed: 0.64, green: 0.32, blue: 0.09, alpha: 1)
    static let sidebar = NSColor(calibratedWhite: 0.965, alpha: 1)
    static let selection = NSColor(calibratedWhite: 0.895, alpha: 1)
    static let hover = NSColor(calibratedWhite: 0.935, alpha: 1)
    static let border = NSColor(calibratedWhite: 0.93, alpha: 1)
    static let blueWash = NSColor(calibratedRed: 0.94, green: 0.965, blue: 1, alpha: 1)
}

private class SurfaceView: NSView {
    var fill: NSColor; var radius: CGFloat; var border: NSColor?
    override var isFlipped: Bool { true }
    init(fill: NSColor = .white, radius: CGFloat = 0, border: NSColor? = nil) {
        self.fill = fill; self.radius = radius; self.border = border
        super.init(frame: .zero); translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        fill.setFill(); path.fill()
        if let border { border.setStroke(); path.lineWidth = 1; path.stroke() }
    }
}

private final class ActionButton: NSButton {
    var invoke: (() -> Void)?
    // Circular HUD controls have explicit hit bounds; native bezel alignment
    // insets would otherwise stretch a 24 pt circle into a 28 pt oval.
    var exactLayoutSize = false
    override var alignmentRectInsets: NSEdgeInsets {
        exactLayoutSize ? NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) : super.alignmentRectInsets
    }
    init(_ title: String, icon: String? = nil, primary: Bool = false, action: @escaping () -> Void) {
        super.init(frame: .zero); self.title = title; invoke = action; bezelStyle = .rounded
        font = .systemFont(ofSize: 13, weight: primary ? .semibold : .regular)
        if let icon { image = NSImage(systemSymbolName: icon, accessibilityDescription: title); imagePosition = .imageLeading }
        if primary { bezelColor = Palette.blue; contentTintColor = .white }
        target = self; self.action = #selector(trigger); translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func trigger() { invoke?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class HistoryRowButton: NSButton {
    private let selected: Bool
    private let invoke: () -> Void
    init(date: String, summary: String, selected: Bool, action: @escaping () -> Void) {
        self.selected = selected; invoke = action
        super.init(frame: .zero)
        title = date + "\n" + summary
        isBordered = false; translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityLabel(title + (selected ? "，已选中" : ""))
        target = self; self.action = #selector(pressed)
        let dateLabel = label(date, size: 11, color: Palette.muted)
        let summaryLabel = label(summary, size: 13, weight: selected ? .semibold : .medium,
                                 color: selected ? Palette.blue : Palette.ink)
        for field in [dateLabel, summaryLabel] {
            field.maximumNumberOfLines = 1; field.lineBreakMode = .byTruncatingTail
            field.setAccessibilityElement(false); addSubview(field)
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11).isActive = true
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11).isActive = true
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 58),
            dateLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            summaryLabel.topAnchor.constraint(equalTo: dateLabel.bottomAnchor, constant: 5)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func pressed() { invoke() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        (selected ? Palette.blueWash : isHighlighted ? Palette.hover : .clear).setFill(); shape.fill()
        if selected { Palette.blue.withAlphaComponent(0.12).setStroke(); shape.lineWidth = 1; shape.stroke() }
    }
}

private final class ActionSwitch: NSSwitch {
    var changed: ((Bool) -> Void)?
    init(value: Bool, change: @escaping (Bool) -> Void) { super.init(frame: .zero); state = value ? .on : .off; changed = change; target = self; action = #selector(trigger) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func trigger() { changed?(state == .on) }
}

private final class ActionPopup: NSPopUpButton {
    var changed: ((Int) -> Void)?
    init(items: [(String, Int)], selected: Int, change: @escaping (Int) -> Void) {
        super.init(frame: .zero, pullsDown: false)
        for (title, tag) in items { addItem(withTitle: title); lastItem?.tag = tag }
        selectItem(withTag: selected); changed = change; target = self; action = #selector(trigger)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func trigger() { changed?(selectedItem?.tag ?? 0) }
}

private final class ActionSegments: NSSegmentedControl {
    var changed: ((Int) -> Void)?
    init(selected: Int, labels: [String] = ["输出文字", "原始转写"], change: @escaping (Int) -> Void) {
        super.init(frame: .zero); segmentCount = labels.count
        for (index, text) in labels.enumerated() { setLabel(text, forSegment: index) }
        trackingMode = .selectOne; selectedSegment = selected; segmentStyle = .rounded
        changed = change; target = self; action = #selector(trigger)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func trigger() { changed?(selectedSegment) }
}

private func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = Palette.ink) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text); field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color; field.translatesAutoresizingMaskIntoConstraints = false; return field
}
private func vertical(_ spacing: CGFloat = 12) -> NSStackView {
    let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
    stack.translatesAutoresizingMaskIntoConstraints = false; return stack
}
private func horizontal(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
    let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = spacing
    stack.distribution = .fill
    stack.translatesAutoresizingMaskIntoConstraints = false; return stack
}
private func fill(_ stack: NSStackView, _ view: NSView) {
    view.translatesAutoresizingMaskIntoConstraints = false; stack.addArrangedSubview(view)
    view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
}
private func pin(_ child: NSView, in parent: NSView, inset: CGFloat = 0) {
    child.translatesAutoresizingMaskIntoConstraints = false; parent.addSubview(child)
    NSLayoutConstraint.activate([child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset), child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset), child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset), child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)])
}
private func card(_ content: NSView, color: NSColor = .white, inset: CGFloat = 20) -> NSView {
    let view = SurfaceView(fill: color, radius: 14, border: color == .white ? Palette.border : nil); pin(content, in: view, inset: inset); return view
}
private func clear(_ stack: NSStackView) {
    for child in stack.arrangedSubviews { stack.removeArrangedSubview(child); child.removeFromSuperview() }
}
private func textView(_ string: String, height: CGFloat? = 180) -> NSScrollView {
    let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
    let text = NSTextView(frame: .zero); text.isEditable = false; text.isSelectable = true; text.isRichText = false
    text.drawsBackground = false; text.textColor = Palette.ink; text.font = .systemFont(ofSize: 14); text.textContainerInset = NSSize(width: 0, height: 6)
    text.isVerticallyResizable = true; text.isHorizontallyResizable = false; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true; text.string = string
    scroll.documentView = text
    if let height { scroll.heightAnchor.constraint(equalToConstant: height).isActive = true }
    else {
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        scroll.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
    }
    return scroll
}

final class DictationWindowController: NSWindowController, NSTextFieldDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    let store: DictationStore
    var onStart: (() -> Void)?; var onCancel: (() -> Void)?; var onCopyText: ((String) -> Void)?
    var onCheckService: (() -> Void)?; var onMicrophone: (() -> Void)?; var onAccessibility: (() -> Void)?
    var onSetup: (() -> Void)?
    var onShortcutCapture: ((Bool) -> Void)?
    var onApplyShortcut: ((DictationShortcut) -> String?)?
    var onInputMonitoring: (() -> Void)?
    var onReloadPrompts: (() -> Void)?
    var onSavePrompt: ((CleanupPromptDraft) -> Void)?
    var onActivatePrompt: ((String) -> Void)?
    var onReprocessEntry: ((UUID, String) -> Void)?
    private var reprocessingCatalog: CleanupPromptCatalog?
    private var reprocessingSheet: HistoryReprocessingWindowController?
    private var reprocessingEntryID: UUID?
    private var reprocessingBusy = false
    private var reprocessingError: String?
    private lazy var promptStudio: PromptStudioView = {
        let view = PromptStudioView()
        view.onReload = { [weak self] in self?.onReloadPrompts?() }
        view.onSave = { [weak self] draft in self?.onSavePrompt?(draft) }
        view.onActivate = { [weak self] id in self?.onActivatePrompt?(id) }
        view.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        view.heightAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        return view
    }()
    private var hasPromptCatalog = false
    private var promptWidthConstraint: NSLayoutConstraint?
    private let sessionStartedAt: Date
    private var page = DictationPage.home
    private var state = DictationUIState()
    private let pageStack = vertical(20)
    private let pageScroll = NSScrollView()
    private var pageMinimumHeight: NSLayoutConstraint?
    private var pagePreferredHeight: NSLayoutConstraint?
    private let sidebarStatus = label("正在准备", size: 12, color: Palette.muted)
    private let sidebarCleanupStatus = label("润色 · 待确认", size: 12, color: Palette.muted)
    private let sidebarDetail = label("", size: 11, color: Palette.muted)
    private var navigation: [DictationPage: SidebarNavigationButton] = [:]
    private var activityPageOffset = 0
    private var calendarObservers: [NSObjectProtocol] = []
    private var calendarContext = ""
    private var liveStatus: NSTextField?; private var liveStart: ActionButton?; private var liveCancel: ActionButton?
    private var microphoneStatus: NSTextField?; private var accessibilityStatus: NSTextField?
    private var homeRaw = false; private var historyMode = 0
    private var selectedEntryID: UUID?; private var historySearch = ""
    private var historyFollowsLatest = true
    private var historyLatestButton: ActionButton?
    private var historyList: NSStackView?; private var historyDetail: NSStackView?
    private var historyPage = 0
    private let historyPageSize = 20
    private var historyListContainer: NSStackView?
    private weak var historyListScroll: NSScrollView?
    private var historyPager: NSView?
    private weak var searchField: NSSearchField?; private weak var vocabularyField: NSTextField?
    private var vocabularyFeedback: NSTextField?; private var vocabularyAdd: ActionButton?
    private let vocabularyHint = "更改从下一次录音生效。不限制词条数量，每个词条最多 64 个字符；内容过大时会提示。"
    private var vocabularySource = 0
    private var vocabularyList: NSStackView?
    private var vocabularyCount: NSTextField?
    private weak var vocabularySources: ActionSegments?
    private weak var vocabularyLearningSwitch: ActionSwitch?
    private var correctionLearningStatus = "等待下一次自动填入，检查当前应用是否支持术语学习。"
    private var correctionLearningLabel: NSTextField?
    private var shortcutRecorder: ShortcutRecorderView?
    private var shortcutRecordButton: ActionButton?; private var shortcutDefaultButton: ActionButton?
    private var shortcutLabel: NSTextField?; private var shortcutFeedback: NSTextField?
    private var functionKeyStatus: NSTextField?; private var inputMonitoringButton: ActionButton?
    private var homeShortcut: NSTextField?
    private var homeHeaderShortcut: NSTextField?
    private var homeShortcutNotice: NSStackView?
    private var homeShortcutExplanation: NSTextField?
    private var homeEnableFunctionKey: ActionButton?
    private var homeInsertionNotice: NSStackView?
    private var homeAllowInsertion: ActionButton?
    private var homeProcessingDetail: NSTextField?
    private var homeASRStatus: NSTextField?; private var homeCleanupStatus: NSTextField?
    private var homeASRModel: NSTextField?; private var homeCleanupModel: NSTextField?
    private var homeCleanupResult: NSTextField?
    private var cleanupSettingDetail: NSTextField?

    init(store: DictationStore, sessionStartedAt: Date) {
        self.store = store; self.sessionStartedAt = sessionStartedAt
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.acceptsMouseMovedEvents = true
        window.title = "本地口述"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true; window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 1000, height: 700); window.appearance = NSAppearance(named: .aqua); window.backgroundColor = .white
        super.init(window: window); window.delegate = self; buildShell(); renderPage(); window.center()
        calendarContext = DictationUsage.dayKey(for: Date()) + TimeZone.current.identifier
        for name in [Notification.Name.NSCalendarDayChanged, NSNotification.Name.NSSystemTimeZoneDidChange, NSApplication.didBecomeActiveNotification] {
            calendarObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                let context = DictationUsage.dayKey(for: Date()) + TimeZone.current.identifier
                guard context != self.calendarContext else { return }
                self.calendarContext = context
                if self.page == .home { self.renderPage() }
            })
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { calendarObservers.forEach { NotificationCenter.default.removeObserver($0) } }

    private func buildShell() {
        guard let root = window?.contentView else { return }
        let sidebar = SurfaceView(fill: Palette.sidebar, radius: 20); root.addSubview(sidebar)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            sidebar.widthAnchor.constraint(equalToConstant: 210)
        ])
        let menu = vertical(6); sidebar.addSubview(menu)
        NSLayoutConstraint.activate([
            menu.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            menu.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
            menu.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 26)
        ])
        let icon = NSImageView(); icon.image = NSImage(named: NSImage.Name("AppIcon")) ?? NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "本地口述")
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true; icon.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let brand = horizontal([icon, label("本地口述", size: 19, weight: .semibold)], spacing: 10)
        let brandContainer = NSView(); pin(brand, in: brandContainer, inset: 12); fill(menu, brandContainer)
        let spacer = NSView(); spacer.heightAnchor.constraint(equalToConstant: 16).isActive = true; fill(menu, spacer)
        for item in [DictationPage.home, .history, .dictionary, .prompts] {
            let button = SidebarNavigationButton(title: item.title, symbol: item.icon) { [weak self] in self?.showPage(item) }
            navigation[item] = button; fill(menu, button)
        }
        let footer = vertical(16); sidebar.addSubview(footer)
        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -14),
            footer.topAnchor.constraint(greaterThanOrEqualTo: menu.bottomAnchor, constant: 24)
        ])
        let local = vertical(6)
        sidebarStatus.identifier = NSUserInterfaceItemIdentifier("sidebar-asr-status")
        sidebarCleanupStatus.identifier = NSUserInterfaceItemIdentifier("sidebar-cleanup-status")
        fill(local, sidebarStatus); fill(local, sidebarCleanupStatus); fill(local, sidebarDetail)
        let localContainer = NSView(); pin(local, in: localContainer, inset: 14); fill(footer, localContainer)
        let separator = NSBox(); separator.boxType = .separator; fill(footer, separator)
        let settings = SidebarNavigationButton(title: DictationPage.settings.title, symbol: DictationPage.settings.icon) { [weak self] in self?.showPage(.settings) }
        navigation[.settings] = settings; fill(footer, settings)
        let scroll = pageScroll; scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(scroll)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 4), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor), scroll.topAnchor.constraint(equalTo: root.topAnchor), scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor)])
        let document = SurfaceView(); scroll.documentView = document
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        pageMinimumHeight = document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor)
        // Prefer exactly the viewport for the two-pane history page. Required
        // minimum content may still extend it when a recovery notice needs room.
        pagePreferredHeight = document.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor)
        pagePreferredHeight?.priority = .defaultHigh
        pageStack.identifier = NSUserInterfaceItemIdentifier("dictation-page-stack")
        pin(pageStack, in: document, inset: 32)
    }

    // Runtime updates change existing labels only. They never rebuild editors or
    // lists, so audio metering cannot steal focus or reset an in-progress search.
    func updateState(_ state: DictationUIState) {
        self.state = state
        let cleanupEnabled = store.preferences.cleanupEnabled
        let cleanupStatus = cleanupEnabled ? state.cleanupReadiness.title : "已关闭"
        let cleanupColor = cleanupEnabled ? state.cleanupReadiness.color : Palette.muted
        sidebarStatus.stringValue = "ASR · " + state.asrReadiness.title
        sidebarStatus.textColor = state.asrReadiness.color
        sidebarCleanupStatus.stringValue = "润色 · " + cleanupStatus
        sidebarCleanupStatus.textColor = cleanupColor
        sidebarDetail.stringValue = state.preview ? "界面预览" : state.serviceMessage
        sidebarStatus.toolTip = state.asrModel
        sidebarCleanupStatus.toolTip = state.cleanupModel
        homeASRStatus?.stringValue = state.asrReadiness.title
        homeASRStatus?.textColor = state.asrReadiness.color
        homeCleanupStatus?.stringValue = cleanupStatus
        homeCleanupStatus?.textColor = cleanupColor
        homeASRModel?.stringValue = state.asrModel ?? "模型待确认"
        homeCleanupModel?.stringValue = state.cleanupModel ?? "模型待确认"
        homeASRModel?.toolTip = state.asrModel; homeCleanupModel?.toolTip = state.cleanupModel
        let latest = store.entries.first
        homeCleanupResult?.stringValue = latest.map {
            "最近润色：" + $0.cleanupResultDescription + ($0.cleanupApplied ? String(format: " · %.2f 秒", $0.cleanupSeconds) : "")
        } ?? "最近润色：暂无记录"
        let lastDetails = [latest?.cleanupProfile.map { "该次模型：" + $0.modelID + "\n润色规则：" + $0.name }, latest?.warning].compactMap { $0 }
        homeCleanupResult?.toolTip = lastDetails.isEmpty ? nil : lastDetails.joined(separator: "\n")
        homeProcessingDetail?.stringValue = state.homeProcessingDescription
        // Settings describe the next recording; an in-flight session keeps its
        // captured preference without making the visible switch text stale.
        cleanupSettingDetail?.stringValue = state.cleanupSettingDescription(enabled: store.preferences.cleanupEnabled)
        liveStatus?.stringValue = state.status
        liveStart?.title = state.recording ? (state.cleanupEnabled ? "结束并整理" : "结束并识别") : "开始口述"
        liveStart?.isEnabled = state.canStart || state.recording; liveCancel?.isEnabled = state.canCancel
        microphoneStatus?.stringValue = state.microphoneAllowed ? "已允许" : "录音时需要允许"
        accessibilityStatus?.stringValue = state.automaticInsertionPermissionDetails.isEmpty
            ? (state.accessibilityAllowed ? "已允许" : "自动填入时需要允许")
            : state.automaticInsertionPermissionDetails
        homeShortcut?.stringValue = state.shortcutDisplay
        homeHeaderShortcut?.stringValue = state.shortcutDisplay + "  开始口述"
        // Shortcut availability stays visible independently of transient
        // recording/service messages, especially after backend recovery.
        let needsFunctionKey = state.functionKeySelected && !state.functionKeyEnabled
        homeShortcutNotice?.isHidden = !needsFunctionKey && state.shortcutWarning.isEmpty
        homeEnableFunctionKey?.isHidden = !needsFunctionKey
        homeEnableFunctionKey?.isEnabled = state.canEditShortcut
        homeEnableFunctionKey?.title = state.inputMonitoringAllowed ? "重新检查 Fn" : "启用 Fn…"
        homeShortcutExplanation?.stringValue = !state.shortcutWarning.isEmpty ? state.shortcutWarning
            : state.inputMonitoringAllowed ? "Fn 暂不可用，请重新检查，或在设置中选择组合键。"
            : "Fn 尚未启用，需要允许输入监控。可以先使用上方的备用组合键。"
        homeInsertionNotice?.isHidden = !state.autoInsertEnabled || state.accessibilityAllowed
        homeAllowInsertion?.isEnabled = state.canEditShortcut
        shortcutLabel?.stringValue = "当前生效：" + state.shortcutDisplay
        shortcutRecordButton?.isEnabled = state.canEditShortcut; shortcutDefaultButton?.isEnabled = state.canEditShortcut
        inputMonitoringButton?.isEnabled = state.canEditShortcut
        functionKeyStatus?.stringValue = state.functionKeySelected ? state.functionKeyMessage + (state.fallbackShortcut.map { "\n备用组合：" + $0 } ?? "") : "当前使用组合快捷键；可恢复默认 Fn。"
        if !state.shortcutWarning.isEmpty && shortcutRecorder?.isRecording != true { shortcutFeedback?.stringValue = state.shortcutWarning }
        if !state.canEditShortcut { shortcutRecorder?.cancel() }
    }
    func reloadStore() {
        if page == .dictionary, vocabularyList != nil {
            // Auto-added words can arrive while a manual word is being typed.
            // Refresh the results in place so that editor and its focus survive.
            reloadVocabularyList()
            vocabularyLearningSwitch?.state = store.preferences.automaticVocabularyLearning ? .on : .off
            correctionLearningLabel?.stringValue = visibleCorrectionLearningStatus
            vocabularyFeedback?.stringValue = store.storageError ?? vocabularyHint
            vocabularyFeedback?.textColor = store.storageError == nil ? Palette.muted : .systemOrange
        } else { renderPage() }
        refreshReprocessingSheet()
    }
    func updateReprocessing(entryID: UUID?, busy: Bool, error: String?) {
        reprocessingEntryID = entryID; reprocessingBusy = busy; reprocessingError = error
        refreshReprocessingSheet()
    }
    private func refreshReprocessingSheet() {
        guard let sheet = reprocessingSheet else { return }
        let ownsRequest = reprocessingEntryID == sheet.entryID
        // A generated revision can still be memory-only when either history
        // copy failed to write. Keep it copyable, but never call it saved until
        // the store confirms durability; a later store refresh clears this warning.
        let storageWarning = store.hasUnsavedHistory
            ? (["新结果尚未完整保存，请先复制并检查存储。", store.storageError].compactMap { $0 }.joined(separator: "\n")) : nil
        let requestError = ownsRequest || reprocessingEntryID == nil ? reprocessingError : nil
        let errors = [storageWarning, requestError].compactMap { $0 }.filter { !$0.isEmpty }
        sheet.update(entry: store.entries.first { $0.id == sheet.entryID }, catalog: reprocessingCatalog,
                     busy: reprocessingBusy && ownsRequest, blockedByOtherEntry: reprocessingBusy && !ownsRequest,
                     error: errors.isEmpty ? nil : errors.joined(separator: "\n"))
    }
    func showReprocessing(entryID: UUID, show: Bool = true) {
        guard let entry = store.entries.first(where: { $0.id == entryID }) else { return }
        if reprocessingSheet?.entryID != entryID {
            reprocessingSheet = HistoryReprocessingWindowController(entry: entry, catalog: reprocessingCatalog)
        }
        reprocessingSheet?.onRun = onReprocessEntry
        reprocessingSheet?.onCopy = onCopyText
        refreshReprocessingSheet()
        if reprocessingCatalog == nil { onReloadPrompts?() }
        if show, let window { reprocessingSheet?.present(asSheetOf: window) }
    }
    func updatePrompts(catalog: CleanupPromptCatalog?, busy: Bool, error: String?) {
        hasPromptCatalog = catalog != nil
        promptStudio.update(catalog: catalog, busy: busy, error: error)
        if let catalog { reprocessingCatalog = catalog }
        refreshReprocessingSheet()
    }
    func updateCorrectionLearning(status: String) {
        correctionLearningStatus = status
        // Capability updates must not rebuild the dictionary's active editor.
        correctionLearningLabel?.stringValue = visibleCorrectionLearningStatus
    }
    private var visibleCorrectionLearningStatus: String {
        store.preferences.automaticVocabularyLearning ? correctionLearningStatus : "自动学习已关闭。"
    }
    func showPage(_ page: DictationPage, compareHistory: Bool = false, promptVersionID: String? = nil) {
        let changedPage = self.page != page
        if page == .history {
            resetHistoryToLatest()
            if compareHistory { historyMode = 2 }
        }
        if let promptVersionID { promptStudio.selectVersion(id: promptVersionID) }
        shortcutRecorder?.cancel(); self.page = page; renderPage()
        if page == .prompts && !hasPromptCatalog { onReloadPrompts?() }
        // Explicit navigation starts at the page heading. Store updates keep
        // their existing scroll position and the user's current editor.
        window?.contentView?.layoutSubtreeIfNeeded()
        pageScroll.documentView?.scroll(.zero)
        if changedPage { DictationMotion.reveal(pageStack) }
    }
    // Reopening an existing history window is an explicit request to see the
    // current records. Other pages retain their editor and navigation state.
    func returnToLatestHistoryIfVisible() {
        guard page == .history else { return }
        showPage(.history)
    }
    private func resetHistoryToLatest() {
        historyFollowsLatest = true; historyPage = 0; selectedEntryID = nil; historySearch = ""
    }
    private func showLatestHistory() {
        resetHistoryToLatest(); searchField?.stringValue = ""
        reloadHistoryList(); historyListScroll?.documentView?.scroll(.zero)
    }
    func windowWillClose(_ notification: Notification) { shortcutRecorder?.cancel(); DictationMotion.cancel(pageStack) }
    func windowDidResignKey(_ notification: Notification) { shortcutRecorder?.cancel() }
    func receiveRegisteredShortcut(_ shortcut: DictationShortcut, released: Bool) { shortcutRecorder?.receiveRegisteredShortcut(shortcut, released: released) }
    private func header(_ title: String, subtitle: String) {
        let heading = vertical(8); fill(heading, label(title, size: 29, weight: .semibold))
        if !subtitle.isEmpty { fill(heading, label(subtitle, size: 13, color: Palette.muted)) }
        heading.setContentHuggingPriority(.required, for: .vertical); fill(pageStack, heading)
    }
    private func renderPage() {
        // Store/status refreshes settle any previous navigation transition;
        // only an explicit page change starts a new one.
        DictationMotion.cancel(pageStack)
        pageMinimumHeight?.isActive = page == .history || page == .prompts
        pagePreferredHeight?.isActive = page == .history || page == .prompts
        shortcutRecorder?.cancel(); shortcutRecorder = nil; shortcutRecordButton = nil; shortcutDefaultButton = nil
        shortcutLabel = nil; shortcutFeedback = nil; functionKeyStatus = nil; inputMonitoringButton = nil; homeShortcut = nil; homeHeaderShortcut = nil
        homeShortcutNotice = nil; homeShortcutExplanation = nil; homeEnableFunctionKey = nil
        homeInsertionNotice = nil; homeAllowInsertion = nil
        homeProcessingDetail = nil; cleanupSettingDetail = nil
        homeASRStatus = nil; homeCleanupStatus = nil; homeASRModel = nil; homeCleanupModel = nil; homeCleanupResult = nil
        clear(pageStack); liveStatus = nil; liveStart = nil; liveCancel = nil; microphoneStatus = nil; accessibilityStatus = nil
        historyList = nil; historyDetail = nil; historyListContainer = nil; historyListScroll = nil; historyPager = nil; historyLatestButton = nil
        vocabularyFeedback = nil; vocabularyAdd = nil; correctionLearningLabel = nil
        vocabularyList = nil; vocabularyCount = nil; vocabularySources = nil; vocabularyLearningSwitch = nil
        for (item, button) in navigation { button.selected = item == page }

        switch page { case .home: renderHome(); case .history: renderHistory(); case .dictionary: renderDictionary(); case .prompts: renderPrompts(); case .settings: renderSettings() }
        if page == .history, let recovery = store.historyRecoveryMessage {
            fill(pageStack, label(recovery, size: 12, color: Palette.secondary))
        }
        if let error = store.storageError { fill(pageStack, label(error, size: 12, color: .systemOrange)) }
        if state.preview { fill(pageStack, label("界面预览 · 所有文字与数据均为示例", size: 11, color: Palette.muted)) }
        updateState(state)
    }
    private func renderPrompts() {
        header("润色规则", subtitle: "")
        pageStack.addArrangedSubview(promptStudio)
        // This editor is retained across navigation so each version's draft
        // survives page refreshes. Reuse its single width constraint as well.
        if promptWidthConstraint == nil {
            promptWidthConstraint = promptStudio.widthAnchor.constraint(equalTo: pageStack.widthAnchor)
        }
        promptWidthConstraint?.isActive = true
    }
    private func renderHome() {
        let heading = vertical(8)
        let shortcutHint = label(state.shortcutDisplay + "  开始口述", size: 12, weight: .medium, color: Palette.secondary)
        shortcutHint.setContentHuggingPriority(.required, for: .horizontal)
        shortcutHint.toolTip = "在目标输入框按一下开始，再按一下结束。快捷键可在设置中修改。"
        homeHeaderShortcut = shortcutHint
        fill(heading, horizontal([label("把想法说清楚。", size: 29, weight: .semibold), NSView(), shortcutHint]))
        let processingDetail = label(state.homeProcessingDescription, size: 13, color: Palette.muted)
        homeProcessingDetail = processingDetail; fill(heading, processingDetail)
        fill(pageStack, heading)
        renderModelStatus()
        renderInsights()
        let shortcut = vertical(10); let shortcutTitle = label(state.shortcutDisplay, size: 17, weight: .semibold, color: Palette.ink)
        homeShortcut = shortcutTitle
        let shortcutHeading = horizontal([shortcutTitle, label("按一下开始，再按一下结束", size: 12, color: Palette.muted)], spacing: 14)
        fill(shortcut, shortcutHeading)
        let status = label(state.status, size: 12); liveStatus = status; fill(shortcut, status)
        let notice = vertical(8)
        let explanation = label("", size: 12, color: Palette.ink)
        homeShortcutNotice = notice; homeShortcutExplanation = explanation; fill(notice, explanation)
        let enableFn = ActionButton("启用 Fn…", icon: "keyboard") { [weak self] in self?.onInputMonitoring?() }
        homeEnableFunctionKey = enableFn; notice.addArrangedSubview(enableFn); fill(shortcut, notice)
        let insertionNotice = vertical(8)
        fill(insertionNotice, label("允许自动填入后，说完的文字才能回到输入框。尚未授权时，结果会自动复制，可直接按 ⌘V 粘贴。", size: 12))
        let allowInsertion = ActionButton("允许自动填入…", icon: "text.cursor") { [weak self] in self?.onAccessibility?() }
        homeInsertionNotice = insertionNotice; homeAllowInsertion = allowInsertion
        insertionNotice.addArrangedSubview(allowInsertion); fill(shortcut, insertionNotice)
        let start = ActionButton("开始口述", icon: "mic.fill", primary: true) { [weak self] in self?.onStart?() }
        let cancel = ActionButton("取消") { [weak self] in self?.onCancel?() }; liveStart = start; liveCancel = cancel
        let settings = ActionButton("快捷键设置…") { [weak self] in self?.showPage(.settings) }
        let controls = horizontal([start, cancel, settings], spacing: 8)
        let flexible = NSView(); flexible.setContentHuggingPriority(.defaultLow, for: .horizontal)
        shortcutHeading.addArrangedSubview(flexible); shortcutHeading.addArrangedSubview(controls)
        fill(pageStack, card(shortcut, color: Palette.sidebar, inset: 16))
        let latest = vertical(14); fill(latest, label("最近结果", size: 16, weight: .semibold))
        if let entry = store.entries.first { renderEntry(entry, into: latest, raw: homeRaw, history: false) }
        else { fill(latest, label("下一次口述，会从这里开始。", size: 17, weight: .medium)); fill(latest, label("原文与输出文字会一起保留，方便你查看和复制。", color: Palette.muted)) }
        fill(pageStack, card(latest))
    }
    private func renderModelStatus() {
        let asrStatus = label("", size: 12, weight: .medium)
        let cleanupStatus = label("", size: 12, weight: .medium)
        let asrModel = label("", size: 11, color: Palette.muted)
        let cleanupModel = label("", size: 11, color: Palette.muted)
        homeASRStatus = asrStatus; homeCleanupStatus = cleanupStatus
        homeASRModel = asrModel; homeCleanupModel = cleanupModel
        let models = horizontal([], spacing: 24)
        models.distribution = .fillEqually
        for (title, status, model, identifier) in [
            ("语音识别（ASR）", asrStatus, asrModel, "home-asr-status"),
            ("文字润色", cleanupStatus, cleanupModel, "home-cleanup-status")
        ] {
            status.identifier = NSUserInterfaceItemIdentifier(identifier)
            status.setContentHuggingPriority(.required, for: .horizontal)
            status.setContentCompressionResistancePriority(.required, for: .horizontal)
            let column = vertical(5)
            fill(column, horizontal([label(title, size: 13, weight: .medium), NSView(), status], spacing: 6))
            model.maximumNumberOfLines = 1; model.lineBreakMode = .byTruncatingMiddle
            fill(column, model); models.addArrangedSubview(column)
        }
        let content = vertical(12); fill(content, models)
        let lastResult = label("", size: 11, color: Palette.secondary)
        lastResult.identifier = NSUserInterfaceItemIdentifier("home-cleanup-result")
        homeCleanupResult = lastResult; fill(content, lastResult)
        let statusCard = card(content, inset: 16)
        statusCard.identifier = NSUserInterfaceItemIdentifier("model-status-card")
        fill(pageStack, statusCard)
    }

    private func metricValue(_ value: String, size: CGFloat = 32) -> NSTextField {
        let attributed = NSMutableAttributedString(string: value, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: Palette.ink])
        let expression = try! NSRegularExpression(pattern: "[0-9,，.]+|—")
        for match in expression.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
            attributed.addAttribute(.font, value: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold), range: match.range)
        }
        let view = NSTextField(labelWithAttributedString: attributed)
        view.translatesAutoresizingMaskIntoConstraints = false; view.lineBreakMode = .byClipping
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        return view
    }
    private func durationText(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds < Double(Int.max) else { return "—" }
        let minutes = Int(max(0, seconds) / 60)
        if minutes >= 60 { return "\(minutes / 60) 小时 \(minutes % 60) 分钟" }
        if minutes > 0 { return "\(minutes) 分钟" }
        return "\(Int(max(0, seconds))) 秒"
    }
    private func renderInsights() {
        let summary = store.usageSummary()
        let number = NumberFormatter(); number.numberStyle = .decimal
        let count = number.string(from: NSNumber(value: summary.characterCount)) ?? "0"
        let heading = horizontal([label("洞察", size: 19, weight: .semibold)])
        heading.addArrangedSubview(NSView())
        let period = label(state.preview ? "累计数据 · 示例" : "累计数据", size: 11, color: Palette.muted)
        period.setContentHuggingPriority(.required, for: .horizontal); heading.addArrangedSubview(period)
        fill(pageStack, heading)
        let metrics = [
            (count + " 字", "口述字数", "按输出文字计数，不含空白和标点；英文按字符计数。"),
            (durationText(summary.estimatedSavedSeconds), "预计节省时间", "按每分钟打字 60 字估算，减去录音和处理用时，最低为 0。"),
            (summary.charactersPerMinute.map { String(format: "%.0f 字 / 分钟", $0) } ?? "—", "平均口述速度", "累计输出字数 ÷ 累计录音分钟数；缺少录音时长时不估算。"),
            (durationText(summary.audioSeconds), "总口述时间", "成功口述的录音时长，不含识别与整理等待时间。")
        ]
        let grid = vertical(14)
        for row in 0..<2 {
            let columns = horizontal([], spacing: 14); columns.distribution = .fillEqually
            for index in row * 2..<row * 2 + 2 {
                let metric = metrics[index]; let content = vertical(10)
                fill(content, metricValue(metric.0)); fill(content, label(metric.1, size: 12, color: Palette.muted))
                let tile = card(content, inset: 18); tile.toolTip = metric.2; tile.identifier = NSUserInterfaceItemIdentifier("insight-metric-\(index)")
                columns.addArrangedSubview(tile)
            }
            fill(grid, columns)
        }
        fill(pageStack, grid)
        let activity = vertical(14)
        let streaks = horizontal([], spacing: 16); streaks.distribution = .fillEqually
        for (value, title) in [(summary.activeDays, "活跃天数"), (summary.currentStreak, "当前连续天数"), (summary.longestStreak, "最长连续天数")] {
            let content = vertical(6); fill(content, metricValue("\(value) 天", size: 27)); fill(content, label(title, size: 11, color: Palette.muted)); streaks.addArrangedSubview(content)
        }
        streaks.toolTip = "一天完成至少一次口述即为活跃；当前连续天数允许今天尚未开始，计算截至昨天的连续记录。"
        fill(activity, streaks)
        let heatmap = DictationActivityHeatmap(usage: store.usage, pageOffset: activityPageOffset)
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy.MM.dd"
        let range = formatter.string(from: heatmap.startDate) + " – " + formatter.string(from: heatmap.endDate)
        let rangeLabel = label(range, size: 11, color: Palette.muted)
        rangeLabel.identifier = NSUserInterfaceItemIdentifier("activity-date-range")
        let dateRow = horizontal([rangeLabel], spacing: 6)
        dateRow.addArrangedSubview(NSView())
        let previous = ActionButton("", icon: "chevron.left") { [weak self] in
            guard let self else { return }; self.activityPageOffset += 1; self.renderPage()
        }
        previous.setAccessibilityLabel("查看前 26 周"); previous.toolTip = "查看前 26 周"
        previous.isEnabled = store.usage.days.keys.min().map { $0 < DictationUsage.dayKey(for: heatmap.startDate) } ?? false
        let next = ActionButton("", icon: "chevron.right") { [weak self] in
            guard let self else { return }; self.activityPageOffset = max(0, self.activityPageOffset - 1); self.renderPage()
        }
        next.setAccessibilityLabel("查看后 26 周"); next.toolTip = "查看后 26 周"; next.isEnabled = activityPageOffset > 0
        for button in [previous, next] { button.isBordered = false; button.widthAnchor.constraint(equalToConstant: 26).isActive = true; dateRow.addArrangedSubview(button) }
        // Resizing changes the visible range, not the paging anchor. Update
        // existing controls without rebuilding the page during Auto Layout.
        heatmap.onRangeChange = { [weak rangeLabel, weak previous, weak self] start, end in
            rangeLabel?.stringValue = formatter.string(from: start) + " – " + formatter.string(from: end)
            previous?.isEnabled = self?.store.usage.days.keys.min().map { $0 < DictationUsage.dayKey(for: start) } ?? false
        }
        fill(activity, dateRow); fill(activity, heatmap)
        if summary.activeDays == 0 { fill(activity, label("下一次口述，将点亮你的第一天。", size: 12, color: Palette.muted)) }
        let activityCard = card(activity, inset: 20)
        activityCard.identifier = NSUserInterfaceItemIdentifier("activity-card")
        fill(pageStack, activityCard)
        let started = store.usage.days.keys.min().map { "自 " + $0.replacingOccurrences(of: "-", with: ".") + " 起累计" } ?? "从首次完成口述开始累计"
        fill(pageStack, label(started + " · 只保存每日汇总，重启后保留。节省时间为估算值。", size: 11, color: Palette.muted))
    }
    private func renderEntry(_ entry: DictationEntry, into stack: NSStackView, raw: Bool, history: Bool) {
        let date = DateFormatter(); date.dateFormat = "M月d日 HH:mm"
        let status = entry.cleanupResultDescription
        let resultTitle = entry.cleanupResultTitle
        let timing = String(format: "识别 %.2f 秒  ·  整理 %.2f 秒  ·  总处理 %.2f 秒", entry.asrSeconds, entry.cleanupSeconds, entry.totalSeconds)
        let compared = history && historyMode == 2
        let comparison = "ASR 原文\n\(entry.rawText)\n\n\(resultTitle)\n\(entry.text)"
        let modelName: (String) -> String = { $0.components(separatedBy: "/").last ?? $0 }
        var provenance: [String] = []
        if let asr = entry.asrModel { provenance.append("ASR：" + modelName(asr)) }
        if let profile = entry.cleanupProfile {
            provenance.append((entry.cleanupApplied ? "润色规则：" : "尝试规则：") + profile.name)
            provenance.append("润色模型：" + modelName(profile.modelID))
        } else if history { provenance.append("此记录未记录润色版本") }
        fill(stack, label("\(date.string(from: entry.createdAt))  ·  \(status)", size: 11, color: Palette.muted))
        let segments = ActionSegments(selected: history ? historyMode : (raw ? 1 : 0),
            labels: history ? ["输出文字", "ASR 原文", "对照"] : ["输出文字", "原始转写"]) { [weak self] index in
            guard let self else { return }; if history { self.historyMode = index; self.reloadHistoryDetail() } else { self.homeRaw = index == 1; self.renderPage() }
        }
        let copy = ActionButton(compared ? "复制对照" : "复制文字", icon: "doc.on.doc") { [weak self] in
            let trace = provenance.joined(separator: "\n")
            let text = compared ? "\(date.string(from: entry.createdAt)) · \(status)\n\n\(comparison)\n\n\(timing)\n\(trace)" : (raw ? entry.rawText : entry.text)
            self?.onCopyText?(text)
        }
        let actions = horizontal([segments, copy]); actions.setContentHuggingPriority(.required, for: .vertical)
        stack.addArrangedSubview(actions)
        let transcript = textView(compared ? comparison : (raw ? entry.rawText : entry.text), height: history ? nil : 128)
        if compared, let text = transcript.documentView as? NSTextView, let storage = text.textStorage {
            // Style only the generated headings at known offsets. User text may
            // itself contain these words; do not search-and-format its content.
            storage.addAttributes([.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: Palette.muted], range: NSRange(location: 0, length: ("ASR 原文" as NSString).length))
            let offset = ("ASR 原文\n" + entry.rawText + "\n\n" as NSString).length
            storage.addAttributes([.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: Palette.muted], range: NSRange(location: offset, length: (resultTitle as NSString).length))
        }
        transcript.identifier = NSUserInterfaceItemIdentifier(history ? "history-transcript" : "home-transcript")
        fill(stack, transcript)
        fill(stack, label(timing, size: 11, color: Palette.muted))
        if history {
            fill(stack, label(provenance.joined(separator: "\n"), size: 11, color: Palette.muted))
            let reprocess = ActionButton("重新整理…", icon: "arrow.triangle.2.circlepath") { [weak self] in
                self?.showReprocessing(entryID: entry.id)
            }
            reprocess.identifier = NSUserInterfaceItemIdentifier("history-reprocess")
            reprocess.isEnabled = !entry.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            var revisionActions: [NSView] = [reprocess]
            if let profile = entry.cleanupProfile {
                let showRule = ActionButton("查看此规则", icon: "slider.horizontal.3") { [weak self] in
                    self?.showPage(.prompts, promptVersionID: profile.versionID)
                }
                showRule.identifier = NSUserInterfaceItemIdentifier("history-prompt-link")
                showRule.setContentHuggingPriority(.required, for: .horizontal)
                revisionActions.append(showRule)
            }
            stack.addArrangedSubview(horizontal(revisionActions, spacing: 8))
        }
        if let warning = entry.warning, !warning.isEmpty { fill(stack, label(warning, size: 12, color: .systemOrange)) }
        if state.lastEntryID == entry.id, !state.detail.isEmpty { fill(stack, label(state.detail, size: 11, color: Palette.muted)) }
        if history { let remove = ActionButton("删除这条记录", icon: "trash") { [weak self] in self?.store.delete(id: entry.id) }; remove.contentTintColor = .systemRed; stack.addArrangedSubview(remove) }
    }
}

extension DictationWindowController {
    private func renderHistory() {
        header("历史记录", subtitle: "永久保存在这台 Mac 的独立存储中，更新应用后仍可查看。")
        let search = NSSearchField(); search.placeholderString = "搜索原文或输出文字"; search.stringValue = historySearch; search.delegate = self; searchField = search
        let removeAll = ActionButton("清空历史", icon: "trash") { [weak self] in
            guard let self, self.confirm("清空所有历史记录？", detail: "原文、输出文字和应用管理的历史备份都会删除，此操作无法撤销。独立导出的升级备份不受影响。") else { return }; self.store.removeAll()
        }
        // A preserved unreadable history file can leave the visible list empty.
        // Clearing is also the explicit recovery path for that stored file.
        removeAll.isEnabled = !store.entries.isEmpty || store.storageError != nil
        let latest = ActionButton("最新", icon: "arrow.up.to.line") { [weak self] in self?.showLatestHistory() }
        latest.identifier = NSUserInterfaceItemIdentifier("history-latest")
        latest.toolTip = "清除搜索并回到最新记录"; latest.setAccessibilityLabel("回到最新记录")
        latest.setContentHuggingPriority(.required, for: .horizontal); historyLatestButton = latest
        let row = horizontal([search, latest, removeAll]); row.setContentHuggingPriority(.required, for: .vertical)
        search.setContentHuggingPriority(.defaultLow, for: .horizontal); fill(pageStack, row)
        let list = vertical(8), detail = vertical(14); historyList = list; historyDetail = detail
        // Fill the remaining viewport with independently scrolling panes. A long
        // list or short transcript must not collapse or push aside the other pane.
        let listScroll = NSScrollView(); listScroll.hasVerticalScroller = true; listScroll.drawsBackground = false
        historyListScroll = listScroll
        let listDocument = SurfaceView(fill: Palette.sidebar); listScroll.documentView = listDocument
        listDocument.widthAnchor.constraint(equalTo: listScroll.contentView.widthAnchor).isActive = true
        pin(list, in: listDocument)
        let listContainer = vertical(8); historyListContainer = listContainer
        listScroll.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        listScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        fill(listContainer, listScroll)
        let listCard = card(listContainer, color: Palette.sidebar, inset: 12)
        listCard.widthAnchor.constraint(equalToConstant: 238).isActive = true
        listCard.identifier = NSUserInterfaceItemIdentifier("history-list-pane")
        let detailCard = card(detail, inset: 18)
        detailCard.identifier = NSUserInterfaceItemIdentifier("history-detail-pane")
        let body = horizontal([listCard, detailCard], spacing: 16); body.alignment = .top
        body.identifier = NSUserInterfaceItemIdentifier("history-body")
        body.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        body.heightAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        listCard.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        detailCard.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        detailCard.widthAnchor.constraint(greaterThanOrEqualToConstant: 380).isActive = true
        fill(pageStack, body); reloadHistoryList()
    }
    private var filteredEntries: [DictationEntry] {
        let query = historySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.entries.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) || $0.rawText.localizedCaseInsensitiveContains(query) }
    }
    private func reloadHistoryList() {
        guard let list = historyList else { return }; clear(list)
        let entries = filteredEntries
        let pageCount = max(1, (entries.count + historyPageSize - 1) / historyPageSize)
        if store.entries.isEmpty && historySearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            historyFollowsLatest = true
        }
        // The automatic first-row selection follows new recordings. Only an
        // explicit reading action pins a record, so passive background updates
        // cannot migrate the latest page backwards one page at a time.
        if historyFollowsLatest {
            historyPage = 0; selectedEntryID = entries.first?.id
        } else if let selected = entries.firstIndex(where: { $0.id == selectedEntryID }) {
            historyPage = selected / historyPageSize
        } else {
            historyPage = min(historyPage, pageCount - 1)
        }
        let start = historyPage * historyPageSize
        let visibleEntries = Array(entries.dropFirst(start).prefix(historyPageSize))
        if !visibleEntries.contains(where: { $0.id == selectedEntryID }) { selectedEntryID = visibleEntries.first?.id }
        if entries.isEmpty { fill(list, label(historySearch.isEmpty ? "还没有口述记录" : "没有匹配的记录", size: 12, color: Palette.muted)) }
        let formatter = DateFormatter(); formatter.dateFormat = "M月d日 HH:mm"
        for entry in visibleEntries {
            let button = HistoryRowButton(date: formatter.string(from: entry.createdAt),
                summary: String(entry.text.replacingOccurrences(of: "\n", with: " ").prefix(22)),
                selected: selectedEntryID == entry.id) { [weak self] in
                    guard let self else { return }
                    // Clicking the already selected automatic row also means
                    // reading it; do not replace that detail on the next result.
                    self.historyFollowsLatest = false
                    self.historyLatestButton?.isHidden = false
                    guard self.selectedEntryID != entry.id else { return }
                    self.selectedEntryID = entry.id; self.reloadHistoryList()
                    if let detail = self.historyDetail { DictationMotion.reveal(detail, duration: 0.1) }
                }
            button.identifier = NSUserInterfaceItemIdentifier("history-row-\(entry.id.uuidString)")
            fill(list, button)
        }
        historyLatestButton?.isHidden = historyFollowsLatest
        reloadHistoryPager(pageCount: pageCount)
        reloadHistoryDetail()
    }
    private func reloadHistoryPager(pageCount: Int) {
        if let pager = historyPager {
            historyListContainer?.removeArrangedSubview(pager); pager.removeFromSuperview(); historyPager = nil
        }
        // A single page has no extra footer or reserved blank space.
        guard pageCount > 1, let container = historyListContainer else { return }
        let previous = ActionButton("", icon: "chevron.left") { [weak self] in self?.changeHistoryPage(by: -1) }
        let next = ActionButton("", icon: "chevron.right") { [weak self] in self?.changeHistoryPage(by: 1) }
        for (button, name, enabled) in [(previous, "上一页", historyPage > 0), (next, "下一页", historyPage < pageCount - 1)] {
            button.isBordered = false; button.exactLayoutSize = true; button.isEnabled = enabled
            button.toolTip = name; button.setAccessibilityLabel(name)
            button.identifier = NSUserInterfaceItemIdentifier(button === previous ? "history-page-previous" : "history-page-next")
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        let pageLabel = label("\(historyPage + 1) / \(pageCount)", size: 11, color: Palette.secondary)
        pageLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        pageLabel.alignment = .center; pageLabel.maximumNumberOfLines = 1
        pageLabel.identifier = NSUserInterfaceItemIdentifier("history-page-number")
        pageLabel.setAccessibilityLabel("第 \(historyPage + 1) 页，共 \(pageCount) 页")
        pageLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
        let leftSpace = NSView(), rightSpace = NSView()
        let pager = horizontal([leftSpace, previous, pageLabel, next, rightSpace], spacing: 4)
        leftSpace.widthAnchor.constraint(equalTo: rightSpace.widthAnchor).isActive = true
        pager.identifier = NSUserInterfaceItemIdentifier("history-pagination")
        pager.heightAnchor.constraint(equalToConstant: 28).isActive = true
        pager.setContentHuggingPriority(.required, for: .vertical)
        historyPager = pager; fill(container, pager)
    }
    private func changeHistoryPage(by offset: Int) {
        let pageCount = max(1, (filteredEntries.count + historyPageSize - 1) / historyPageSize)
        let target = min(max(historyPage + offset, 0), pageCount - 1)
        guard target != historyPage else { return }
        historyFollowsLatest = false; historyPage = target; selectedEntryID = nil
        reloadHistoryList()
        historyListScroll?.documentView?.scroll(.zero)
        if let detail = historyDetail { DictationMotion.reveal(detail, duration: 0.1) }
    }
    private func reloadHistoryDetail() {
        guard let detail = historyDetail else { return }; clear(detail)
        if let entry = filteredEntries.first(where: { $0.id == selectedEntryID }) { renderEntry(entry, into: detail, raw: historyMode == 1, history: true) }
        else {
            fill(detail, label("留住每一次清楚的表达。", size: 18, weight: .medium))
            fill(detail, label("完成口述后，可以在这里比较原文、复制文字或删除记录。", color: Palette.muted))
            let spacer = NSView(); spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
            spacer.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true; fill(detail, spacer)
        }
    }
    private func renderDictionary() {
        header("个人词典", subtitle: "添加人名、项目名与专业术语，帮助本机语音识别。词典保存在本机，不随云端整理请求发送。")
        let learning = ActionSwitch(value: store.preferences.automaticVocabularyLearning) { [weak self] value in
            self?.store.updatePreferences { $0.automaticVocabularyLearning = value }
        }
        vocabularyLearningSwitch = learning
        learning.identifier = NSUserInterfaceItemIdentifier("automatic-vocabulary-learning")
        learning.setAccessibilityLabel("自动学习术语")
        learning.toolTip = "仅自动加入高置信度的术语纠错，可随时撤销。"
        let learningStatus = label(visibleCorrectionLearningStatus, size: 12, color: Palette.muted)
        learningStatus.identifier = NSUserInterfaceItemIdentifier("correction-learning-status")
        correctionLearningLabel = learningStatus
        fill(pageStack, card(settingRow("自动学习术语", detail: "", control: learning, detailLabel: learningStatus)))
        let content = vertical(16)
        let input = NSTextField(); input.placeholderString = "例如：CodeGraph、工作流、项目名"; input.delegate = self
        input.target = self; input.action = #selector(addVocabulary); vocabularyField = input
        let add = ActionButton("添加", icon: "plus", primary: true) { [weak self] in self?.addVocabulary() }; vocabularyAdd = add; add.isEnabled = false
        let row = horizontal([input, add]); input.setContentHuggingPriority(.defaultLow, for: .horizontal); fill(content, row)
        let feedback = label(vocabularyHint, size: 11, color: Palette.muted)
        vocabularyFeedback = feedback; fill(content, feedback); fill(pageStack, card(content))
        let terms = vertical(16)
        let sources = ActionSegments(selected: vocabularySource, labels: ["全部", "自动添加", "手动添加"]) { [weak self] source in
            guard let self else { return }
            self.vocabularySource = source; self.reloadVocabularyList()
            if let list = self.vocabularyList { DictationMotion.reveal(list, duration: 0.12) }
        }
        sources.identifier = NSUserInterfaceItemIdentifier("vocabulary-source-filter")
        sources.setAccessibilityLabel("词条来源")
        sources.setContentHuggingPriority(.required, for: .horizontal)
        sources.setContentCompressionResistancePriority(.required, for: .horizontal)
        vocabularySources = sources
        let count = label("", size: 12, color: Palette.muted)
        count.identifier = NSUserInterfaceItemIdentifier("vocabulary-count")
        count.setContentHuggingPriority(.required, for: .horizontal); vocabularyCount = count
        fill(terms, horizontal([sources, NSView(), count]))
        let list = vertical(12); vocabularyList = list; fill(terms, list)
        fill(pageStack, card(terms)); reloadVocabularyList()
    }
    private func reloadVocabularyList() {
        guard let terms = vocabularyList else { return }
        DictationMotion.cancel(terms); clear(terms)
        let activeLearning = store.preferences.learnedVocabulary.filter { !$0.undone }
        // A correction can teach a new spelling for an existing manual word.
        // Only records that own the word make it an automatically added entry.
        let automaticTerms = store.preferences.automaticallyAddedTerms
        let visibleTerms = store.preferences.vocabulary.filter {
            vocabularySource == 0 || (vocabularySource == 1 ? automaticTerms.contains($0) : !automaticTerms.contains($0))
        }
        vocabularySources?.selectedSegment = vocabularySource
        vocabularyCount?.stringValue = "\(visibleTerms.count) 个词"
        if visibleTerms.isEmpty {
            let empty = vocabularySource == 1 ? "还没有自动添加的词条。口述后纠正术语，可自动记住。"
                : vocabularySource == 2 ? "还没有手动添加的词条。在上方添加常用的人名或专业术语。"
                : "还没有词条。先加入一个经常被识别错的名字。"
            fill(terms, label(empty, color: Palette.muted))
        }
        // A term has one visible origin: its newest active correction. Undo
        // records remain in storage for rejection memory, never as extra rows.
        var learnedByTerm: [String: DictationLearnedVocabulary] = [:]
        for record in activeLearning.sorted(by: { $0.createdAt > $1.createdAt }) {
            if learnedByTerm[record.corrected] == nil { learnedByTerm[record.corrected] = record }
        }
        for term in visibleTerms {
            let learned = learnedByTerm[term]
            let text = label(learned.map { "\($0.original) → \($0.corrected)" } ?? term, size: 14)
            text.setContentHuggingPriority(.defaultLow, for: .horizontal)
            if let learned {
                let original = NSAttributedString(string: learned.original + " → ", attributes: [.foregroundColor: Palette.muted])
                let styled = NSMutableAttributedString(attributedString: original)
                styled.append(NSAttributedString(string: learned.corrected, attributes: [.foregroundColor: Palette.ink, .font: NSFont.systemFont(ofSize: 14, weight: .medium)]))
                text.attributedStringValue = styled
            }
            let remove = ActionButton(learned == nil ? "删除" : "撤销", icon: learned == nil ? "minus.circle" : "arrow.uturn.backward") { [weak self] in
                if let learned { self?.store.undoLearnedVocabulary(id: learned.id) }
                else { self?.store.updatePreferences { $0.vocabulary.removeAll { $0 == term } } }
            }
            remove.widthAnchor.constraint(equalToConstant: 64).isActive = true
            remove.setAccessibilityLabel(learned == nil ? "删除词条：\(term)" : "撤销学习：\(term)")
            if let learned { remove.identifier = NSUserInterfaceItemIdentifier("undo-vocabulary-\(learned.id.uuidString)") }
            let row = horizontal([text, remove])
            row.identifier = NSUserInterfaceItemIdentifier("vocabulary-row")
            // The label owns the available width. A wrapping label's intrinsic
            // width otherwise lets AppKit stretch the delete button instead.
            text.widthAnchor.constraint(equalTo: row.widthAnchor, constant: -76).isActive = true
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
            fill(terms, row)
        }
    }
    @objc private func addVocabulary() {
        guard let term = vocabularyField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), !term.isEmpty else { return }
        guard store.addManualVocabulary(term) else {
            vocabularyFeedback?.stringValue = store.storageError ?? "词条未能保存，请重试。"
            vocabularyFeedback?.textColor = .systemOrange; return
        }
        vocabularyField?.stringValue = ""; vocabularyAdd?.isEnabled = false
        vocabularyFeedback?.stringValue = vocabularyHint
        vocabularyFeedback?.textColor = Palette.muted
        // A successful explicit addition stays visible regardless of the tab
        // the user was browsing before entering it.
        vocabularySource = 0; reloadVocabularyList()
    }
    func controlTextDidChange(_ notification: Notification) {
        if let search = notification.object as? NSSearchField, search === searchField {
            historySearch = search.stringValue
            historyFollowsLatest = historySearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            historyPage = 0; selectedEntryID = nil; reloadHistoryList()
            historyListScroll?.documentView?.scroll(.zero)
        }
        else if let field = notification.object as? NSTextField, field === vocabularyField { vocabularyAdd?.isEnabled = !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    private func settingRow(_ title: String, detail: String, control: NSView, detailLabel: NSTextField? = nil) -> NSView {
        let text = vertical(5); fill(text, label(title, size: 14, weight: .medium)); fill(text, detailLabel ?? label(detail, size: 12, color: Palette.muted))
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        if control is NSPopUpButton { control.widthAnchor.constraint(equalToConstant: 175).isActive = true }
        return horizontal([text, control], spacing: 24)
    }
    private func renderSettings() {
        header("按你的习惯来。", subtitle: "设置会应用到下一次录音。正在处理的口述保持原来的设置。")
        renderShortcutSettings()
        let preferences = store.preferences; let input = vertical(22)
        let cleanup = ActionSwitch(value: preferences.cleanupEnabled) { [weak self] value in self?.store.updatePreferences { $0.cleanupEnabled = value } }
        let cleanupDetail = label(state.cleanupSettingDescription(enabled: preferences.cleanupEnabled), size: 12, color: Palette.muted)
        cleanupSettingDetail = cleanupDetail
        fill(input, settingRow("文字整理", detail: "", control: cleanup, detailLabel: cleanupDetail))
        let insert = ActionSwitch(value: preferences.autoInsertEnabled) { [weak self] value in self?.store.updatePreferences { $0.autoInsertEnabled = value } }
        fill(input, settingRow("自动填入原输入框", detail: "无法自动填入时，结果会自动复制，可直接按 ⌘V 粘贴。", control: insert))
        let language = ActionPopup(items: [("中文为主", 0), ("自动识别", 1)], selected: preferences.recognitionLanguage == "auto" ? 1 : 0) { [weak self] value in self?.store.updatePreferences { $0.recognitionLanguage = value == 1 ? "auto" : "zh" } }
        fill(input, settingRow("识别语言", detail: "经常切换语言时，可以使用自动识别。", control: language))
        let waveform = ActionPopup(items: [("灵动", 0), ("柔和", 1)], selected: preferences.waveformStyle == .gentle ? 1 : 0) { [weak self] value in
            self?.store.updatePreferences { $0.waveformStyle = value == 1 ? .gentle : .lively }
        }
        waveform.identifier = NSUserInterfaceItemIdentifier("waveform-style")
        waveform.setAccessibilityLabel("波形动效")
        fill(input, settingRow("波形动效", detail: "", control: waveform)); fill(pageStack, card(input))
        let historyStorage = vertical(10)
        fill(historyStorage, label("历史记录", size: 15, weight: .semibold))
        fill(historyStorage, label("永久保存原文和整理结果，不按天数或条数自动清理。数据与应用分开存放，更新应用后仍会保留。", size: 12, color: Palette.muted))
        let reveal = ActionButton("打开数据文件夹", icon: "folder") { [weak self] in
            guard let directory = self?.store.storageDirectory else { return }
            NSWorkspace.shared.open(directory)
        }
        reveal.isEnabled = store.storageDirectory != nil
        historyStorage.addArrangedSubview(reveal)
        fill(pageStack, card(historyStorage))
        let usage = vertical(10)
        fill(usage, label("口述统计", size: 15, weight: .semibold))
        fill(usage, label("只在本机保存每日字数、次数与用时，不含正文或录音。重启后继续累计；删除历史不会删除统计。", size: 12, color: Palette.muted))
        let clearUsage = ActionButton("清空统计…", icon: "trash") { [weak self] in
            guard let self, self.confirm("清空所有口述统计？", detail: "字数、时长和活跃日历将从零重新累计。口述历史与词典不受影响，此操作无法撤销。") else { return }
            self.activityPageOffset = 0; self.store.clearUsage()
        }
        usage.addArrangedSubview(clearUsage); fill(pageStack, card(usage))
        let access = vertical(18)
        let setup = ActionButton("模型与配置…") { [weak self] in self?.onSetup?() }
        fill(access, horizontal([label("权限与服务", size: 15, weight: .semibold), NSView(), setup]))
        let microphone = label("", size: 12, color: Palette.muted); microphoneStatus = microphone
        let accessibility = label("", size: 12, color: Palette.muted); accessibilityStatus = accessibility
        fill(access, horizontal([label("麦克风", weight: .medium), microphone, ActionButton("管理权限…") { [weak self] in self?.onMicrophone?() }]))
        fill(access, horizontal([label("自动填入", weight: .medium), accessibility, ActionButton("管理权限…") { [weak self] in self?.onAccessibility?() }]))
        fill(access, horizontal([label("本地服务", weight: .medium), ActionButton("检查服务", icon: "arrow.clockwise") { [weak self] in self?.onCheckService?() }]))
        fill(pageStack, card(access))
    }
    private func renderShortcutSettings() {
        let content = vertical(12)
        fill(content, label("快捷键", size: 15, weight: .semibold))
        let current = label("当前生效：" + state.shortcutDisplay, size: 17, weight: .medium, color: Palette.blue)
        let presentation = ShortcutCapturePresentationView(label: current)
        shortcutLabel = current; fill(content, presentation)
        let recorder = ShortcutRecorderView(); recorder.translatesAutoresizingMaskIntoConstraints = false
        recorder.heightAnchor.constraint(equalToConstant: 0).isActive = true
        fill(content, recorder); shortcutRecorder = recorder
        let capture = ActionButton("录制新快捷键…", icon: "keyboard") { [weak self] in
            guard let self, self.state.canEditShortcut else { return }
            if self.shortcutRecorder?.isRecording == true { self.shortcutRecorder?.cancel() } else { self.shortcutRecorder?.begin() }
        }
        let restore = ActionButton("恢复默认 Fn") { [weak self] in
            guard let self, self.state.canEditShortcut else { return }
            self.shortcutRecorder?.cancel()
            let error = self.onApplyShortcut?(.functionKey)
            self.shortcutFeedback?.stringValue = error ?? "已恢复默认 Fn。"
        }
        shortcutRecordButton = capture; shortcutDefaultButton = restore
        content.addArrangedSubview(horizontal([capture, restore]))
        let feedback = label("Fn 可单独使用；组合键至少包含 ⌘、⌥ 或 ⌃。录音或处理时不能修改。", size: 11, color: Palette.muted)
        shortcutFeedback = feedback; fill(content, feedback)
        recorder.bindPresentation(presentation, feedback: feedback)
        recorder.onCaptureChange = { [weak self] capturing in
            self?.shortcutRecordButton?.title = capturing ? "取消录制（Esc）" : "录制新快捷键…"
            self?.onShortcutCapture?(capturing)
        }
        recorder.onCandidate = { [weak self] shortcut in
            guard let self, self.state.canEditShortcut, let apply = self.onApplyShortcut else { return "当前不能修改快捷键。" }
            return apply(shortcut)
        }
        recorder.onFeedback = { [weak self] message in self?.shortcutFeedback?.stringValue = message }
        let fnStatus = label(state.functionKeyMessage, size: 11, color: Palette.muted); functionKeyStatus = fnStatus; fill(content, fnStatus)
        let permission = ActionButton("检查 / 允许输入监控…") { [weak self] in self?.onInputMonitoring?() }
        inputMonitoringButton = permission
        let keyboard = ActionButton("系统键盘设置…") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
        }
        content.addArrangedSubview(horizontal([permission, keyboard]))
        fill(content, label("系统或其他听写工具也可能使用 Fn；若同时触发，请关闭对方快捷键或改用组合键。", size: 11, color: Palette.muted))
        fill(pageStack, card(content))
    }
    private func confirm(_ title: String, detail: String) -> Bool {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail; alert.alertStyle = .warning
        alert.addButton(withTitle: "继续"); alert.addButton(withTitle: "取消"); return alert.runModal() == .alertFirstButtonReturn
    }
    func renderPNG(to url: URL) throws {
        guard let view = window?.contentView else { return }; view.layoutSubtreeIfNeeded(); try renderView(view, to: url, background: .white)
    }
}

/// Sound-triggered center pulses spread toward independently timed shoulders.
/// This is a loudness visualization, not a frequency spectrum. A fixed internal
/// clock makes the same measured input reproducible across display refresh rates.
struct DictationWaveformEnvelope {
    private struct Arrival { let time: Double; let column: Int; let level: Double; let mix: Double; let decay: Double }
    static let columnCount = 10
    private static let step = 1.0 / 240
    private var randomState: UInt64
    private var elapsed = 0.0, remainder = 0.0, nextPulse = 0.0, silentFor = 0.0
    private var current = 0.0
    private var reducedMotion = false
    private var wasVoiced = false
    private var forcePulse = false
    private var style: DictationWaveformStyle = .lively
    private var bars = Array(repeating: 0.0, count: columnCount)
    private var decays = Array(repeating: 0.09, count: columnCount)
    private var arrivals: [Arrival] = []

    init(seed: UInt64 = UInt64.random(in: 1...UInt64.max)) { randomState = seed == 0 ? 1 : seed }

    private mutating func random() -> Double {
        // Per-envelope seeded variation affects pulse geometry only. Silence
        // never consumes it or starts a pulse; tests can replay an exact input.
        randomState = randomState &* 6364136223846793005 &+ 1442695040888963407
        return Double(randomState >> 11) / Double(UInt64(1) << 53)
    }

    /// AVAudioRecorder already returns logarithmic dBFS. Recover amplitude
    /// before compressing its display range; logging normalized dB a second
    /// time would raise medium-volume speech toward the top of the display.
    static func levelFromDecibels(_ decibels: Double) -> Double {
        guard decibels.isFinite, decibels > -55 else { return 0 }
        let floorAmplitude = pow(10.0, -55.0 / 20.0)
        let amplitude = pow(10.0, min(0, decibels) / 20.0)
        return pow(max(0, (amplitude - floorAmplitude) / (1 - floorAmplitude)), 0.55)
    }

    // Keep the sound-control domain unchanged: its values also set pulse
    // density, onset detection and decay. Only the final visual height uses a
    // speech-sized display range; 0 dBFS is a clipping ceiling, not a normal
    // speaking target. The upper two anchors form a soft knee toward 18 pt.
    private static let displayAnchors: [(level: Double, fraction: Double)] = [
        (-50.0, 0.00), (-40.0, 0.08), (-30.0, 0.42),
        (-20.0, 0.78), (-12.0, 0.93), (0.0, 1.00)
    ].map { (levelFromDecibels($0.0), $0.1) }

    static func displayHeight(for level: Double) -> Double {
        guard level.isFinite, level > displayAnchors[0].level else { return 2 }
        for (lower, upper) in zip(displayAnchors, displayAnchors.dropFirst()) where level <= upper.level {
            let position = (level - lower.level) / (upper.level - lower.level)
            return 2 + 16 * (lower.fraction + position * (upper.fraction - lower.fraction))
        }
        return 18
    }

    static func inputLevel(average: Double, peak: Double) -> Double {
        let average = average.isFinite ? max(0, min(1, average)) : 0
        let peak = peak.isFinite ? max(0, min(1, peak)) : 0
        // RMS/average loudness carries the motion. Brief peaks add a little
        // definition without a peak-hold turning an entire phrase into a block.
        return average + max(0, peak - average) * 0.15
    }

    mutating func advance(average: Double, peak: Double, seconds: Double, reduceMotion: Bool = false,
                          style: DictationWaveformStyle = .lively) {
        self.style = style
        guard seconds.isFinite else { return }
        let delta = max(0, min(seconds, 0.1))
        guard delta > 0 || reduceMotion else { return }
        let target = Self.inputLevel(average: average, peak: peak)
        if current > 0, target > 0, target < current {
            // Preserve independent pulse shapes when the speaker softens, but
            // scale all old energy down immediately, including queued arrivals.
            let ratio = target / current
            bars = bars.map { $0 * ratio }
            arrivals = arrivals.map { Arrival(time: $0.time, column: $0.column, level: $0.level * ratio, mix: $0.mix, decay: $0.decay) }
        } else if current > 0, target > current * 1.45 {
            nextPulse = min(nextPulse, elapsed); forcePulse = true
        }
        current = target
        reducedMotion = reduceMotion
        if reduceMotion {
            arrivals.removeAll(); bars = Array(repeating: 0, count: Self.columnCount)
            wasVoiced = false; forcePulse = false; remainder = 0
            return
        }
        remainder += delta
        while remainder + 1e-10 >= Self.step {
            stepSound()
            remainder = max(0, remainder - Self.step)
            elapsed += Self.step
        }
    }

    private mutating func stepSound() {
        let voiced = current > 0
        if !voiced {
            // Stop propagation immediately. A short bounded release preserves
            // the pulse character without a lingering apparently-live mic.
            arrivals.removeAll(); silentFor += Self.step
            for index in bars.indices {
                bars[index] = silentFor >= 0.08 ? 0 : bars[index] * exp(-Self.step / 0.018)
                if bars[index] < 0.003 { bars[index] = 0 }
            }
            wasVoiced = false; forcePulse = false
            return
        }
        silentFor = 0
        for index in bars.indices {
            bars[index] = min(current * 1.10, bars[index] * exp(-Self.step / decays[index]))
        }
        if !wasVoiced || forcePulse || elapsed + 1e-10 >= nextPulse {
            // Gentle motion spaces decorative pulses farther apart. Real
            // syllable onsets and quieting still respond on the current frame.
            let emit = !wasVoiced || forcePulse || random() < min(0.95, 0.18 + current * 1.5)
            if emit { emitPulse() }
            forcePulse = false
            nextPulse = elapsed + (style == .gentle ? 0.075 : 0.05)
        }
        wasVoiced = true
        for arrival in arrivals where arrival.time <= elapsed + 1e-10 {
            let measured = min(current * 1.10, arrival.level)
            let blended = bars[arrival.column] * (1 - arrival.mix) + measured * arrival.mix
            // A newly reached shoulder receives the full pulse. Mixing only
            // preserves stronger previous motion; it must not attenuate onset twice.
            bars[arrival.column] = min(current * 1.10, max(measured, blended))
            decays[arrival.column] = arrival.decay
        }
        arrivals.removeAll { $0.time <= elapsed + 1e-10 }
    }

    private mutating func emitPulse() {
        let center = random() < 0.5 ? 4 : 5
        let amplitude = min(1, current * (0.95 + random() * 0.10))
        bars[center] = amplitude
        decays[center] = style == .gentle ? 0.095 + random() * 0.030 : 0.075 + random() * 0.035
        for index in 0..<Self.columnCount where index != center {
            let distance = abs(index - center)
            let sideLength = index < center ? center : Self.columnCount - 1 - center
            let slope = 0.65 + random() * 0.08
            let attenuation = max(0.18, 1 - slope * Double(distance) / Double(sideLength))
            let level = amplitude * attenuation * (0.90 + random() * 0.20)
            let delay = Double(distance) * (0.012 + random() * 0.004) + random() * 0.015
            let mix = 0.65 + random() * 0.10
            let decay = style == .gentle ? 0.085 + random() * 0.035 : 0.065 + random() * 0.045
            arrivals.append(Arrival(time: elapsed + delay, column: index, level: level, mix: mix, decay: decay))
        }
    }

    var columns: [Double] {
        if reducedMotion {
            return (0..<Self.columnCount).map { index in
                let distance = Double(min(abs(index - 4), abs(index - 5)))
                return current * (1 - distance * 0.155)
            }
        }
        return bars.map { min(1, max(0, $0)) }
    }
}

/// Presentation interpolation only. The owner estimates duration and supplies
/// progress; this view never invents completion or starts another model call.
struct DictationHUDProgress {
    private(set) var target: Double?
    private(set) var displayed: Double = 0
    private(set) var complete = false
    private var completionStart = 0.0
    private var completionElapsed = 0.0
    mutating func receive(_ value: Double?, complete: Bool, active: Bool) {
        guard active else { self = DictationHUDProgress(); return }
        if complete, !self.complete { completionStart = displayed; completionElapsed = 0 }
        self.complete = complete
        if complete { target = 1; return }
        guard let value, value.isFinite else { return }
        target = max(target ?? 0, min(1, max(0, value)))
    }
    mutating func advance(seconds: Double, reduceMotion: Bool) {
        guard let target else { return }
        if reduceMotion { displayed = target; return }
        guard seconds.isFinite, seconds > 0 else { return }
        if complete {
            // The owner keeps the completed card briefly before delivery. Use
            // that interval for a bounded final fill, never a second success toast.
            completionElapsed += min(seconds, 0.1)
            displayed = completionStart + (1 - completionStart) * min(1, completionElapsed / 0.1)
            return
        }
        displayed += (target - displayed) * (1 - exp(-min(seconds, 0.1) / 0.20))
        if target - displayed < 0.0001 { displayed = target }
    }
}

private final class DictationHUDSurface: SurfaceView {
    var progress = DictationHUDProgress()
    func receive(_ state: DictationUIState) {
        progress.receive(state.processingProgress, complete: state.processingComplete,
                         active: state.processing && !state.recording)
        needsDisplay = true
    }
    func advance(seconds: Double, reduceMotion: Bool) {
        progress.advance(seconds: seconds, reduceMotion: reduceMotion); needsDisplay = true
    }
    func resetProgress() { progress = DictationHUDProgress(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard progress.displayed > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 16, yRadius: 16).addClip()
        // AppKit composites the child controls after this background pass.
        // The clipped gray fill never draws over their text or button layers.
        NSColor(srgbRed: 0.95, green: 0.95, blue: 0.95, alpha: 0.17).setFill()
        NSRect(x: 1.5, y: 1.5, width: (bounds.width - 3) * progress.displayed, height: bounds.height - 3).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

private final class DictationActivityView: NSView {
    private var envelope = DictationWaveformEnvelope()
    private var average = 0.0
    private var peak = 0.0
    private var processing = false
    private var phase = 0.0
    private var reducedMotion = false
    private var lastInputAt = 0.0
    private var waveformStyle: DictationWaveformStyle = .lively
    var onProcessingFrame: ((CGFloat) -> Void)?

    func receive(_ state: DictationUIState) {
        if processing != state.processing { reset() }
        processing = state.processing
        waveformStyle = state.waveformStyle
        average = state.meterLevel
        peak = state.meterPeakLevel
        lastInputAt = ProcessInfo.processInfo.systemUptime
        setAccessibilityLabel(processing ? "正在整理" : "麦克风音量")
    }

    func advance(seconds: Double, reduceMotion: Bool, preview: Bool = false) {
        reducedMotion = reduceMotion
        if processing {
            phase = reduceMotion ? 0 : (phase + max(0, min(seconds, 0.1)) * 2 * .pi / 1.8).truncatingRemainder(dividingBy: 2 * .pi)
            onProcessingFrame?(reduceMotion ? 1 : CGFloat(0.82 + 0.18 * (sin(phase) + 1) / 2))
        } else {
            // A stalled recorder update must settle to silence, rather than
            // leaving a frozen, apparently active microphone on screen.
            let stale = !preview && ProcessInfo.processInfo.systemUptime - lastInputAt > 0.10
            envelope.advance(average: stale ? 0 : average, peak: stale ? 0 : peak,
                             seconds: seconds, reduceMotion: reduceMotion, style: waveformStyle)
        }
        needsDisplay = true
    }

    func reset() {
        envelope = DictationWaveformEnvelope()
        average = 0; peak = 0; phase = 0
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Cleanup has its own text feedback, never a pretend microphone trace.
        guard !processing else { return }
        NSColor.white.setFill()
        for (index, level) in envelope.columns.enumerated() {
            let height = CGFloat(DictationWaveformEnvelope.displayHeight(for: level))
            let x = bounds.midX - 19 + CGFloat(index * 4)
            NSBezierPath(roundedRect: NSRect(x: x, y: (bounds.height - height) / 2, width: 2, height: height), xRadius: 1, yRadius: 1).fill()
        }
    }

}
private final class NonactivatingHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
private final class DictationDisplayLinkTarget: NSObject {
    var onFrame: ((CADisplayLink) -> Void)?
    @objc func displayFrame(_ link: CADisplayLink) { onFrame?(link) }
}
final class DictationHUD {
    var onFinish: (() -> Void)?; var onCancel: (() -> Void)?; var onAccessibility: (() -> Void)?
    var onCopy: (() -> Void)?
    private let panel: NonactivatingHUDPanel
    private let surface = DictationHUDSurface(fill: NSColor(calibratedWhite: 0.055, alpha: 0.98), radius: 17,
                                             border: NSColor(white: 1, alpha: 0.32))
    private var surfaceLeading: NSLayoutConstraint!
    private let activity = DictationActivityView()
    private let title = label("正在整理", size: 11.5, weight: .medium, color: .white)
    private let sessionCaption = label("", size: 9, weight: .medium, color: NSColor(calibratedWhite: 0.62, alpha: 1))
    private var finish: ActionButton!; private var cancel: ActionButton!
    private var cancelRecordingPosition: NSLayoutConstraint!
    private var cancelProcessingPosition: NSLayoutConstraint!
    private let deliveryMessage = label("", size: 12, weight: .medium, color: .white)
    private var recordingRow: NSView!; private var deliveryRow: NSStackView!
    private var permissionButton: ActionButton!
    private var copyButton: ActionButton!
    private var deliveryHide: DispatchWorkItem?
    private var deliveryGeneration: UInt64 = 0
    private var displayLink: CADisplayLink?
    private let displayLinkTarget = DictationDisplayLinkTarget()
    private var animationTimestamp = 0.0
    private var previewTimestamp: TimeInterval?
    private var accessibilityObserver: NSObjectProtocol?
    private var motionObserver: NSObjectProtocol?
    private var positionAnimation: DictationMotionAnimation?
    private var positionTarget: NSRect?
    private var stackVisibleFrame: NSRect?
    private var hasExplicitStackFrame = false
    private(set) var stackIndex = 0
    private var stackCount = 1
    private var preferredPanelWidth: CGFloat = 118
    /// Called only when a visible card disappears, including a copy reminder's
    /// delayed dismissal. The owner can then compact the remaining cards.
    var onDidHide: (() -> Void)?
    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }
    init() {
        panel = NonactivatingHUDPanel(contentRect: NSRect(x: 0, y: 0, width: 118, height: 34), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true; panel.becomesKeyOnlyIfNeeded = true; panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let content = NSView(); panel.contentView = content
        content.addSubview(surface)
        surfaceLeading = surface.leadingAnchor.constraint(equalTo: content.leadingAnchor)
        NSLayoutConstraint.activate([
            surfaceLeading, surface.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            surface.topAnchor.constraint(equalTo: content.topAnchor), surface.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        finish = ActionButton("", icon: "checkmark") { [weak self] in self?.onFinish?() }
        cancel = ActionButton("", icon: "xmark") { [weak self] in self?.onCancel?() }
        for button in [finish!, cancel!] {
            button.isBordered = false; button.refusesFirstResponder = true; button.imagePosition = .imageOnly
            button.exactLayoutSize = true
            button.image = button.image?.withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
            button.wantsLayer = true; button.layer?.cornerRadius = 12
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        finish.layer?.backgroundColor = NSColor.white.cgColor; finish.contentTintColor = .black
        // An opaque control surface prevents the progress background from
        // tinting half of the cancel circle as its leading edge passes beneath.
        cancel.layer?.backgroundColor = NSColor(srgbRed: 0.18, green: 0.18, blue: 0.18, alpha: 1).cgColor; cancel.contentTintColor = .white
        finish.toolTip = "结束录音"; finish.setAccessibilityLabel("结束录音"); cancel.toolTip = "取消本次口述"; cancel.setAccessibilityLabel("取消本次口述")
        title.maximumNumberOfLines = 1; title.lineBreakMode = .byTruncatingTail; title.alignment = .center
        sessionCaption.maximumNumberOfLines = 1; sessionCaption.lineBreakMode = .byTruncatingTail
        sessionCaption.font = .monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        sessionCaption.alignment = .center; sessionCaption.isHidden = true
        recordingRow = NSView(); recordingRow.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(sessionCaption)
        for view in [cancel!, activity, title, finish!] { recordingRow.addSubview(view) }
        activity.translatesAutoresizingMaskIntoConstraints = false
        pin(recordingRow, in: surface)
        // The ordinal belongs to the transparent stack gutter, not the capsule.
        // Recording keeps both controls beside the centered waveform; processing
        // puts cancel on the right and keeps its title centered on the same body.
        cancelRecordingPosition = cancel.leadingAnchor.constraint(equalTo: recordingRow.leadingAnchor, constant: 6)
        cancelProcessingPosition = cancel.trailingAnchor.constraint(equalTo: recordingRow.trailingAnchor, constant: -6)
        cancelRecordingPosition.isActive = true
        NSLayoutConstraint.activate([
            cancel.centerYAnchor.constraint(equalTo: recordingRow.centerYAnchor),
            finish.trailingAnchor.constraint(equalTo: recordingRow.trailingAnchor, constant: -6),
            finish.centerYAnchor.constraint(equalTo: recordingRow.centerYAnchor),
            sessionCaption.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 6),
            sessionCaption.widthAnchor.constraint(equalToConstant: 12),
            sessionCaption.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            activity.widthAnchor.constraint(equalToConstant: 38), activity.heightAnchor.constraint(equalToConstant: 24),
            activity.centerXAnchor.constraint(equalTo: recordingRow.centerXAnchor), activity.centerYAnchor.constraint(equalTo: recordingRow.centerYAnchor),
            title.widthAnchor.constraint(equalToConstant: 50), title.centerXAnchor.constraint(equalTo: recordingRow.centerXAnchor, constant: -5),
            title.centerYAnchor.constraint(equalTo: recordingRow.centerYAnchor)
        ])
        // Progress supplies the motion. Keep foreground text fully opaque so
        // its appearance does not change with the background beneath it.
        activity.onProcessingFrame = { [weak self] _ in self?.title.alphaValue = 1 }
        permissionButton = ActionButton("允许") { [weak self] in
            guard let self else { return }
            let action = self.onAccessibility
            self.hide()
            action?()
        }
        permissionButton.toolTip = "允许自动填入"; permissionButton.setAccessibilityLabel("允许自动填入")
        permissionButton.isBordered = false; permissionButton.contentTintColor = NSColor(calibratedRed: 0.63, green: 0.82, blue: 1, alpha: 1)
        permissionButton.refusesFirstResponder = true
        let dismiss = ActionButton("", icon: "xmark") { [weak self] in self?.hide() }
        dismiss.toolTip = "关闭提示"; dismiss.setAccessibilityLabel("关闭提示")
        dismiss.isBordered = false; dismiss.contentTintColor = .white; dismiss.refusesFirstResponder = true; dismiss.exactLayoutSize = true
        dismiss.widthAnchor.constraint(equalToConstant: 24).isActive = true
        dismiss.heightAnchor.constraint(equalToConstant: 24).isActive = true
        deliveryMessage.maximumNumberOfLines = 1; deliveryMessage.lineBreakMode = .byTruncatingTail
        deliveryMessage.setContentHuggingPriority(.defaultLow, for: .horizontal)
        deliveryMessage.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        copyButton = ActionButton("复制") { [weak self] in self?.onCopy?() }
        copyButton.toolTip = "复制此段文字"; copyButton.setAccessibilityLabel("复制此段文字")
        copyButton.isBordered = false; copyButton.contentTintColor = permissionButton.contentTintColor
        copyButton.refusesFirstResponder = true; copyButton.isHidden = true
        for button in [copyButton!, permissionButton!] {
            button.widthAnchor.constraint(equalToConstant: 32).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        deliveryRow = horizontal([deliveryMessage, copyButton, permissionButton, dismiss], spacing: 8)
        deliveryRow.isHidden = true
        surface.addSubview(deliveryRow)
        NSLayoutConstraint.activate([
            deliveryRow.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 10),
            deliveryRow.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -6),
            deliveryRow.centerYAnchor.constraint(equalTo: surface.centerYAnchor), deliveryRow.heightAnchor.constraint(equalToConstant: 24)
        ])
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.updateAnimationPolicy()
        }
        motionObserver = NotificationCenter.default.addObserver(forName: DictationMotion.policyDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.positionAnimation?.finishImmediately(); self?.updateAnimationPolicy()
        }
    }
    func update(_ state: DictationUIState, show: Bool = true) {
        guard state.recording || state.processing else { hide(); return }
        invalidateDeliveryHide()
        recordingRow.isHidden = false; deliveryRow.isHidden = true
        title.stringValue = state.processingComplete && !state.recording ? "已整理" : "正在整理"; title.isHidden = state.recording
        activity.isHidden = !state.recording
        if state.recording {
            cancelProcessingPosition.isActive = false; cancelRecordingPosition.isActive = true
        } else {
            cancelRecordingPosition.isActive = false; cancelProcessingPosition.isActive = true
        }
        title.toolTip = nil
        // The session label remains available to accessibility, while the row
        // uses only its ordinal as a quiet marker instead of a second heading.
        let ordinal = state.sessionLabel.filter { $0.isNumber }
        sessionCaption.stringValue = ordinal.isEmpty ? state.sessionLabel : ordinal
        sessionCaption.isHidden = stackCount <= 1 || state.sessionLabel.isEmpty
        sessionCaption.setAccessibilityLabel(state.sessionLabel)
        setPreferredPanelWidth(118)
        surface.receive(state)
        let elapsed = max(0, state.elapsedSeconds)
        let duration = String(format: "%d:%02d", elapsed / 60, elapsed % 60)
        // The main window can report pending work while this card is recording.
        // Never replace that live microphone waveform with processing dots.
        var activityState = state
        activityState.processing = state.processing && !state.recording
        activity.receive(activityState)
        finish.isHidden = !state.recording; finish.isEnabled = state.recording
        let identity = state.sessionLabel.isEmpty ? "本次口述" : state.sessionLabel
        finish.setAccessibilityLabel("结束录音 · " + identity)
        cancel.setAccessibilityLabel("取消口述 · " + identity)
        panel.setAccessibilityLabel([state.sessionLabel, state.recording ? "正在录音" : title.stringValue, duration].filter { !$0.isEmpty }.joined(separator: " · "))
        if show { showPanel() }
        updateAnimationPolicy()
    }
    /// Delivery feedback remains at the input location, without activating our
    /// app. A new recording invalidates the delayed hide of an older delivery.
    func showDelivery(message: String, needsPermission: Bool, show: Bool = true) {
        let alreadyVisible = panel.isVisible
        invalidateDeliveryHide()
        stopAnimation(); activity.reset(); surface.resetProgress()
        recordingRow.isHidden = true; deliveryRow.isHidden = false
        deliveryMessage.stringValue = message; deliveryMessage.toolTip = message
        permissionButton.isHidden = !needsPermission
        copyButton.isHidden = onCopy == nil
        if !sessionCaption.stringValue.isEmpty { copyButton.setAccessibilityLabel("复制第 " + sessionCaption.stringValue + " 段文字") }
        let textWidth = (message as NSString).size(withAttributes: [.font: deliveryMessage.font!]).width
        let actionsWidth: CGFloat = 24 + (copyButton.isHidden ? 0 : 40) + (permissionButton.isHidden ? 0 : 40)
        // Rare delivery actions size their own card; they do not widen every
        // recording and processing card for the rest of the session.
        setPreferredPanelWidth(min(360, max(180, ceil(textWidth + actionsWidth + 24))))
        if show { showPanel() }
        if show && alreadyVisible { DictationMotion.reveal(deliveryRow, duration: 0.1) }
        // Completed results remain available in history. Copy/permission
        // actions get a little more reading time, but never leave a completed
        // card covering the input field indefinitely.
        let lifetime: TimeInterval = needsPermission || onCopy != nil ? 5 : 3.5
        let generation = deliveryGeneration
        let pending = DispatchWorkItem { [weak self] in
            guard let self, self.deliveryGeneration == generation, self.recordingRow.isHidden else { return }
            self.hide()
        }
        deliveryHide = pending
        DispatchQueue.main.asyncAfter(deadline: .now() + lifetime, execute: pending)
    }
    private func setPreferredPanelWidth(_ width: CGFloat) {
        guard preferredPanelWidth != width else { return }
        preferredPanelWidth = width
        setStackIndex(stackIndex, count: stackCount, animated: panel.isVisible)
    }
    /// Keep a collection on one screen by passing the same visibleFrame to each
    /// card. Hidden cards are placed before appearing; shown cards settle from
    /// their current presentation position if the collection changes again.
    func setStackIndex(_ index: Int, count: Int = 1, animated: Bool = true, visibleFrame: NSRect? = nil) {
        stackIndex = max(0, index); stackCount = max(stackIndex + 1, count)
        surfaceLeading.constant = stackCount > 1 ? 24 : 0
        sessionCaption.isHidden = stackCount <= 1 || sessionCaption.stringValue.isEmpty
        if let visibleFrame { stackVisibleFrame = visibleFrame; hasExplicitStackFrame = true }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let bounds = stackVisibleFrame ?? screen?.visibleFrame else { return }
        stackVisibleFrame = bounds
        let target = Self.stackFrame(index: stackIndex, count: stackCount, visibleFrame: bounds, preferredWidth: preferredPanelWidth)
        guard positionTarget != target else { return }
        positionAnimation?.cancel(); positionAnimation = nil; positionTarget = target
        let start = panel.frame
        guard animated, panel.isVisible, !DictationMotion.reduceMotion, start != target else {
            panel.setFrame(target, display: true); return
        }
        let transition = DictationMotionAnimation(duration: 0.16, update: { [weak self] progress in
            guard let self else { return }
            let frame = NSRect(x: start.minX + (target.minX - start.minX) * progress,
                y: start.minY + (target.minY - start.minY) * progress,
                width: start.width + (target.width - start.width) * progress,
                height: start.height + (target.height - start.height) * progress)
            self.panel.setFrame(frame, display: true)
        }, completion: { [weak self] in self?.positionAnimation = nil })
        positionAnimation = transition; transition.start()
    }
    /// The normal stack grows upward with a 12pt gap. On short displays use a
    /// second column instead of overlapping cards or placing controls offscreen.
    static func stackFrame(index: Int, count: Int, visibleFrame: NSRect, preferredWidth: CGFloat = 118) -> NSRect {
        let height: CGFloat = 34, gap: CGFloat = 12
        let index = max(0, index), count = max(index + 1, count)
        let rows = min(count, max(1, Int((max(height, visibleFrame.height) + gap) / (height + gap))))
        let columns = (count + rows - 1) / rows
        // Shared column slots prevent a wider copy/error card from colliding
        // with a narrow recording card in the adjacent column.
        let gutter: CGFloat = count > 1 ? 24 : 0
        // Reserve a matching clear margin on both sides of each column so its
        // body stays centered even when a wide delivery card shares the stack.
        let slotWidth = min(CGFloat(360) + 2 * gutter, max(1, (visibleFrame.width - CGFloat(columns - 1) * gap) / CGFloat(columns)))
        let width = min(preferredWidth, max(1, slotWidth - 2 * gutter))
        let usedHeight = CGFloat(rows) * height + CGFloat(rows - 1) * gap
        let margin = min(CGFloat(30), max(0, (visibleFrame.height - usedHeight) / 2))
        let usedWidth = CGFloat(columns) * slotWidth + CGFloat(columns - 1) * gap
        // Anchor the capsule body, not the transparent number gutter. Adding or
        // removing a second card must not move the remaining body's center.
        return NSRect(x: visibleFrame.midX - usedWidth / 2 + CGFloat(index / rows) * (slotWidth + gap) + (slotWidth - width) / 2 - gutter,
                      y: visibleFrame.minY + margin + CGFloat(index % rows) * (height + gap),
                      width: width + gutter, height: height)
    }
    private func showPanel() {
        guard !panel.isVisible else { return }
        setStackIndex(stackIndex, count: stackCount, animated: false)
        panel.orderFrontRegardless()
        if let content = panel.contentView { DictationMotion.reveal(content, duration: 0.1) }
    }
    private func invalidateDeliveryHide() {
        deliveryGeneration &+= 1
        deliveryHide?.cancel(); deliveryHide = nil
    }
    private func updateAnimationPolicy() {
        guard panel.isVisible, deliveryRow.isHidden else { stopAnimation(); return }
        let reduced = DictationMotion.reduceMotion
        guard !reduced else {
            stopAnimation()
            activity.advance(seconds: 0, reduceMotion: true)
            surface.advance(seconds: 0, reduceMotion: true)
            return
        }
        guard displayLink == nil else { return }
        animationTimestamp = 0
        // Follow the display's presentation clock instead of an independent
        // 30 Hz timer. Only this 38×24 canvas or the small status label redraws.
        displayLinkTarget.onFrame = { [weak self] link in
            guard let self else { return }
            guard self.panel.isVisible else { self.stopAnimation(); return }
            let now = link.targetTimestamp
            let delta = self.animationTimestamp > 0 ? now - self.animationTimestamp : link.duration
            self.activity.advance(seconds: delta, reduceMotion: false)
            self.surface.advance(seconds: delta, reduceMotion: false)
            self.animationTimestamp = now
        }
        // Bind to the panel: view-based links may stay inactive for this
        // non-layer-backed AppKit canvas even while the panel is visible.
        let link = panel.displayLink(target: displayLinkTarget, selector: #selector(DictationDisplayLinkTarget.displayFrame(_:)))
        let maximum = Float(min(120, max(30, panel.screen?.maximumFramesPerSecond ?? 60)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
        displayLink = link
        link.add(to: .main, forMode: .common)
    }
    private func stopAnimation() {
        displayLink?.invalidate()
        displayLink = nil
        displayLinkTarget.onFrame = nil
        animationTimestamp = 0
    }
    func hide() {
        let wasVisible = panel.isVisible
        positionAnimation?.cancel(); positionAnimation = nil
        invalidateDeliveryHide(); stopAnimation(); activity.reset(); previewTimestamp = nil
        surface.resetProgress()
        if let content = panel.contentView { DictationMotion.cancel(content) }
        DictationMotion.cancel(deliveryRow)
        panel.orderOut(nil)
        if let positionTarget { panel.setFrame(positionTarget, display: false) }
        // A reused single HUD follows the next input location. A collection's
        // explicit screen anchor remains stable until its owner repositions it.
        if !hasExplicitStackFrame { stackVisibleFrame = nil; positionTarget = nil }
        if wasVisible { onDidHide?() }
    }
    // Routine health/status refreshes may arrive after delivery. They may end
    // recording activity, but must leave the short delivery message readable.
    func hideActivity() { if deliveryRow.isHidden { hide() } }
    func renderPNG(to url: URL, state: DictationUIState, animationTime: TimeInterval? = nil, reduceMotion: Bool? = nil) throws {
        update(state, show: false); guard let view = panel.contentView else { return }
        stopAnimation()
        let reduced = reduceMotion ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if let animationTime {
            let elapsed = previewTimestamp.map { max(0, animationTime - $0) } ?? 1.0 / 60
            activity.advance(seconds: elapsed, reduceMotion: reduced, preview: true)
            surface.advance(seconds: elapsed, reduceMotion: reduced)
            previewTimestamp = animationTime
        } else {
            // A single exported still should show the supplied fixture level.
            for _ in 0..<24 {
                activity.advance(seconds: 1.0 / 60, reduceMotion: reduced, preview: true)
                surface.advance(seconds: 1.0 / 60, reduceMotion: reduced)
            }
        }
        view.layoutSubtreeIfNeeded(); try renderView(view, to: url, background: .clear)
    }
    deinit {
        deliveryHide?.cancel()
        displayLink?.invalidate()
        positionAnimation?.cancel()
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
        if let motionObserver { NotificationCenter.default.removeObserver(motionObserver) }
    }
}

private func renderView(_ view: NSView, to url: URL, background: NSColor) throws {
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let image = NSImage(size: view.bounds.size); image.lockFocus(); background.setFill(); view.bounds.fill()
    if let cgImage = bitmap.cgImage { NSImage(cgImage: cgImage, size: view.bounds.size).draw(in: view.bounds, from: .zero, operation: .sourceOver, fraction: 1) }
    image.unlockFocus()
    if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) { try png.write(to: url) }
}
