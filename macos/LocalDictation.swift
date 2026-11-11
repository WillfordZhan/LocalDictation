import AppKit
import AVFoundation
import Carbon
import ApplicationServices
import OSLog

private let serviceBase = URL(string: "http://127.0.0.1:8765")!

struct DictationResult: Decodable {
    let raw_text: String
    let text: String
    let asr_seconds: Double
    let cleanup_seconds: Double
    let total_seconds: Double
    let cleanup_applied: Bool
    let warning: String?
    let audio_seconds: Double?
    let cleanup_profile: DictationCleanupProfile?
    let asr_model: String?
    let streaming_metrics: DictationStreamingMetrics?
    var cleanup_outcome: DictationCleanupOutcome? = nil
    func cleanupOutcome(requested: Bool, promptWarning: String? = nil) -> DictationCleanupOutcome? {
        // A broken prompt catalog forces ASR-only in the frozen request. That
        // fallback is distinct from a user deliberately turning cleanup off.
        if let promptWarning, !promptWarning.isEmpty {
            return DictationCleanupOutcome(status: "failed", reason: "prompt_unavailable")
        }
        return cleanup_outcome ?? .legacy(raw: raw_text, text: text, applied: cleanup_applied, requested: requested)
    }
}

private struct DictationRequestOptions {
    let cleanup: Bool
    let language: String
    // Sent only to the loopback ASR service; cloud cleanup receives transcript
    // text only and must not forward this personal dictionary.
    let vocabulary: [String]
    let corrections: [DictationCorrectionHint]
    init(_ preferences: DictationPreferences) {
        cleanup = preferences.cleanupEnabled; language = preferences.recognitionLanguage; vocabulary = preferences.vocabulary
        corrections = preferences.correctionHints
    }
    func encoded() throws -> Data {
        try DictationStore.encodeRequestOptions(cleanup: cleanup, language: language, vocabulary: vocabulary, corrections: corrections)
    }
}

private struct ServiceHealth: Decodable {
    let service: String
    let status: String
    let ready: Bool
    let asr_ready: Bool
    let cleanup_ready: Bool
    let busy: Bool
    let message: String
    let supports_options: Bool?
    let cleanup_backend: String?
    let supports_prompt_versions: Bool?
    let active_prompt_version_id: String?
    let supports_streaming: Bool?
    let accepts_streaming: Bool?
    let supports_reprocess: Bool?
    let models: [String: String]?
    var asrReadiness: DictationModelReadiness {
        asr_ready ? .ready : status == "loading" ? .loading : .unavailable
    }
    var cleanupReadiness: DictationModelReadiness {
        cleanup_ready ? .ready : status == "loading" ? .loading : .unavailable
    }
    var permitsRecording: Bool {
        ready && asr_ready && supports_options == true &&
            (supports_streaming == true ? accepts_streaming == true : !busy)
    }
    var cleanupBackend: DictationCleanupBackend? {
        // Older services only support local cleanup. An unknown explicit value
        // must stay unknown instead of displaying a false local-only promise.
        guard let cleanup_backend else { return .local }
        return DictationCleanupBackend(rawValue: cleanup_backend)
    }
    var readyMessage: String {
        guard cleanup_ready else { return "本地识别已就绪，文字整理暂不可用；会保留原始转写。" }
        switch cleanupBackend {
        case .cloud: return "本地识别已就绪；云端整理已配置。"
        case .local: return "本地识别与整理已就绪，可以开始口述。"
        case nil: return "本地识别已就绪，整理方式待确认。"
        }
    }
}

private enum Phase {
    case idle, preparing, recording, processing, completed, failed
    var busy: Bool { self == .preparing || self == .recording || self == .processing }
}

private struct Selection: Equatable {
    let location: Int
    let length: Int

    static func matchesKnown(_ captured: Selection?, _ current: Selection?) -> Bool {
        // Two unavailable AX ranges do not establish an unchanged caret.
        guard let captured, let current else { return false }
        return captured == current
    }
}

private struct FocusTarget {
    let pid: pid_t
    let element: AXUIElement
    let selection: Selection
}

/// Each utterance owns its inputs and transport. A new microphone
/// session never reuses the previous utterance's completion or cancellation.
private final class StreamingUtterance {
    let id: UUID
    let number: Int
    let preferences: DictationPreferences
    let promptWarning: String?
    let audioURL: URL
    let client: StreamingDictationClient
    let hud = DictationHUD()
    var stoppedAt: Date?
    var audioSeconds = 0.0
    var recognizedSeconds = 0.0
    var partialText = ""
    var result: DictationResult?
    var resultReceivedAt: Date?
    var completionDeadline = 0.0
    var completionScheduled = false
    var savedEntryID: UUID?
    var progress = DictationProcessingProgress()
    var backendState = "queued"

    init(id: UUID, number: Int, preferences: DictationPreferences, promptWarning: String?,
         audioURL: URL, client: StreamingDictationClient) {
        self.id = id; self.number = number; self.preferences = preferences
        self.promptWarning = promptWarning; self.audioURL = audioURL; self.client = client
    }
}

private struct HotKeyLatch {
    private var pressed = false
    mutating func shouldToggle(eventKind: UInt32) -> Bool {
        if eventKind == UInt32(kEventHotKeyReleased) { pressed = false; return false }
        guard eventKind == UInt32(kEventHotKeyPressed), !pressed else { return false }
        pressed = true
        return true
    }
}

/// A rolling window limits automatic recovery. Once repeated exits exhaust it,
/// only an explicit service check re-arms recovery, even after the window ends.
private struct BackendRecoveryBudget {
    private var attemptTimes: [TimeInterval] = []
    private(set) var isPaused = false

    mutating func nextDelay(now: TimeInterval) -> TimeInterval? {
        guard !isPaused else { return nil }
        attemptTimes.removeAll { now - $0 >= 60 }
        guard attemptTimes.count < 2 else { isPaused = true; return nil }
        attemptTimes.append(now)
        return TimeInterval(attemptTimes.count)
    }

    mutating func reset() {
        attemptTimes.removeAll()
        isPaused = false
    }
}

private let pasteLogger = Logger(subsystem: "local.willford.dictation", category: "AutoInsert")

private func focusedElement(pid: pid_t, failed: ((AXError) -> Void)? = nil) -> AXUIElement? {
    var value: CFTypeRef?
    let application = AXUIElementCreateApplication(pid)
    // Bound cross-process IPC; an unresponsive target falls back to copying.
    AXUIElementSetMessagingTimeout(application, 0.08)
    let code = AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &value)
    guard code == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
        pasteLogger.notice("gate=read_focus pid=\(pid) ax_error=\(code.rawValue)")
        failed?(code == .success ? .noValue : code); return nil
    }
    return (value as! AXUIElement)
}

private func selection(of element: AXUIElement, failed: ((AXError) -> Void)? = nil) -> Selection? {
    var value: CFTypeRef?
    AXUIElementSetMessagingTimeout(element, 0.08)
    let code = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value)
    guard code == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else {
        pasteLogger.notice("gate=read_selection ax_error=\(code.rawValue)")
        failed?(code == .success ? .noValue : code); return nil
    }
    let axValue = value as! AXValue
    guard AXValueGetType(axValue) == .cfRange else { return nil }
    var range = CFRange(location: 0, length: 0)
    guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
    return Selection(location: range.location, length: range.length)
}

private func isEditable(_ element: AXUIElement, knownSelection: Selection? = nil) -> Bool {
    var subrole: CFTypeRef?
    _ = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
    if (subrole as? String) == "AXSecureTextField" { return false }
    var writable = DarwinBoolean(false)
    if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &writable) == .success && writable.boolValue { return true }
    // A selection range is a generic text-input capability, including editors
    // that reject AX text mutation but support ordinary keyboard paste.
    return knownSelection != nil || selection(of: element) != nil
}

private enum FocusStatus {
    case unchanged, changed, unavailable
}

private struct DeliveryResult {
    let message: String
    let hudMessage: String
    var needsPermission = false
    var showHUD = true

    // Targeted paste has no cross-app receipt. Suppress the copy reminder
    // after dispatch without claiming verified insertion or retrying it.
    static var pasteDispatched: DeliveryResult {
        DeliveryResult(message: "已向输入框发送粘贴。", hudMessage: "", showHUD: false)
    }
}

private final class TextInserter {
    var onPasteDispatched: ((String, FocusTarget, UUID) -> Void)?
    private let board: NSPasteboard
    private let writeClipboard: (String) -> Bool
    private let permissionCheck: () -> String?
    private var captureIssue: String?
    private var captureTransient = false
    private var captureAXError: Int32 = 0
    // The focus identity can be known before its selected range becomes ready.
    // Retain that partial observation so recovery cannot silently change fields.
    fileprivate var captureObservedElement: AXUIElement?
    private let targetReader: (() -> FocusTarget?)?
    private let pasteKeySender: (pid_t) -> Bool
    private let foregroundPID: () -> pid_t?
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    var clipboardChangeCount: Int { board.changeCount }

    init(board: NSPasteboard = .general,
         writeClipboard: ((String) -> Bool)? = nil,
         permissionCheck: @escaping () -> String? = TextInserter.systemPermissionIssue,
         targetReader: (() -> FocusTarget?)? = nil,
         pasteKeySender: @escaping (pid_t) -> Bool = TextInserter.postPasteKey,
         foregroundPID: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, action in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
         }) {
        self.board = board
        self.writeClipboard = writeClipboard ?? { text in
            board.clearContents(); return board.writeObjects([text as NSString])
        }
        self.permissionCheck = permissionCheck
        self.targetReader = targetReader
        self.pasteKeySender = pasteKeySender
        self.foregroundPID = foregroundPID
        self.schedule = schedule
    }

    private static func postPasteKey(to pid: pid_t) -> Bool {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else { return false }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.postToPid(pid); up.postToPid(pid)
        return true
    }

    static func systemPermissionState() -> (accessibility: Bool, postEvent: Bool) {
        // Query each capability independently: one failed preflight must not
        // hide the other state when a saved grant belongs to an older build.
        (AXIsProcessTrusted(), CGPreflightPostEventAccess())
    }

    private static func systemPermissionIssue() -> String? {
        let permission = systemPermissionState()
        if !permission.accessibility {
            return "系统尚未认可当前版本的辅助功能授权。若系统开关已打开，请重新添加当前应用。"
        }
        if !permission.postEvent { return "辅助功能已允许，但系统尚未允许发送粘贴按键。" }
        return nil
    }

    func captureTarget() -> FocusTarget? {
        captureIssue = nil
        captureTransient = false; captureAXError = 0
        captureObservedElement = nil
        if let issue = permissionCheck() { captureIssue = issue; return nil }
        if let targetReader {
            let target = targetReader()
            if let target { captureObservedElement = target.element }
            captureTransient = target == nil
            return target
        }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            captureIssue = "当前没有前台输入窗口。"; return nil
        }
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            captureIssue = "当前焦点在本地口述窗口。请点击需要填入的输入框。"; return nil
        }
        let failed: (AXError) -> Void = { [self] code in
            captureAXError = code.rawValue
            captureTransient = code == .cannotComplete || code == .noValue
        }
        guard let element = focusedElement(pid: app.processIdentifier, failed: failed) else {
            captureIssue = "无法读取当前输入框。请点击需要填入的输入框。"; return nil
        }
        captureObservedElement = element
        guard let range = selection(of: element, failed: failed), isEditable(element, knownSelection: range) else {
            captureIssue = "当前输入框未提供可确认的光标位置。"; return nil
        }
        return FocusTarget(pid: app.processIdentifier, element: element, selection: range)
    }

    /// Warm the target application's accessibility tree while speech is being
    /// captured. This never stores a caret or mutates captureIssue: subsequent
    /// segments still belong to the input focused when their result is ready.
    static func warmInput(pid: pid_t) {
        guard pid != getpid(), AXIsProcessTrusted() else { return }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.08)
        var role: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(application, kAXRoleAttribute as CFString, &role)
        if let element = focusedElement(pid: pid) { _ = selection(of: element) }
    }

    /// Only AX readiness is retried, before touching the clipboard or posting a
    /// key. A changed foreground app invalidates this delivery; no delayed work
    /// may send text into an app the user switched to during recovery.
    func prepareCurrentInput(isCurrent: @escaping () -> Bool,
                             completion: @escaping (FocusTarget?) -> Void) {
        let expectedPID = foregroundPID(), eventID = UUID().uuidString
        let started = ProcessInfo.processInfo.systemUptime
        var observedElement: AXUIElement?
        func attempt(_ index: Int) {
            guard isCurrent() else { return }
            guard foregroundPID() == expectedPID else {
                captureIssue = "输入位置已变化，已停止自动填入。"
                pasteLogger.notice("event=\(eventID, privacy: .public) gate=foreground_changed attempt=\(index)")
                completion(nil); return
            }
            let target = captureTarget()
            if let element = captureObservedElement {
                if let previous = observedElement, !CFEqual(previous, element) {
                    captureIssue = "输入位置已变化，已停止自动填入。"
                    pasteLogger.notice("event=\(eventID, privacy: .public) gate=focused_element_changed attempt=\(index)")
                    completion(nil); return
                }
                observedElement = element
            }
            guard target == nil || target?.pid == expectedPID else {
                captureIssue = "输入位置已变化，已停止自动填入。"
                completion(nil); return
            }
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
            pasteLogger.notice("event=\(eventID, privacy: .public) gate=prepare pid=\(expectedPID ?? -1) attempt=\(index) ready=\(target != nil) transient=\(self.captureTransient) ax_error=\(self.captureAXError) elapsed_ms=\(elapsed)")
            if target == nil, captureTransient, index < 3 {
                schedule([0.10, 0.20, 0.40][index]) { attempt(index + 1) }
            } else { completion(target) }
        }
        attempt(0)
    }

    func focusStatus(_ target: FocusTarget?) -> FocusStatus {
        guard let target, permissionCheck() == nil else { return .unavailable }
        if let targetReader {
            guard let current = targetReader() else { return .unavailable }
            return current.pid == target.pid && CFEqual(current.element, target.element) && current.selection == target.selection
                ? .unchanged : .changed
        }
        guard let app = NSWorkspace.shared.frontmostApplication else { return .unavailable }
        guard app.processIdentifier == target.pid else { return .changed }
        guard let current = focusedElement(pid: target.pid) else { return .unavailable }
        guard CFEqual(current, target.element) else { return .changed }
        guard let range = selection(of: current) else { return .unavailable }
        return Selection.matchesKnown(target.selection, range) ? .unchanged : .changed
    }

    func matches(_ target: FocusTarget?) -> Bool { focusStatus(target) == .unchanged }

    /// Every completed segment follows the same ordinary paste path. Read the
    /// current caret at delivery, so an earlier paste or user edit cannot leave
    /// later segments tied to a stale selection or a missing AX text receipt.
    func insertIntoCurrentInput(_ text: String, automatic: Bool, entryID: UUID? = nil) -> DeliveryResult {
        insert(text, target: automatic ? captureTarget() : nil, changed: false, automatic: automatic, entryID: entryID)
    }

    func insert(_ text: String, target: FocusTarget?, changed: Bool, automatic: Bool = true, entryID: UUID? = nil,
                expectedClipboardChangeCount: Int? = nil) -> DeliveryResult {
        // An explicit copy made during AX recovery belongs to the user. It must
        // survive even if no paste event has yet been sent for this utterance.
        if let expectedClipboardChangeCount, board.changeCount != expectedClipboardChangeCount {
            pasteLogger.notice("gate=clipboard_changed_during_prepare paste_dispatched=false")
            return DeliveryResult(message: "剪贴板随后被其他复制操作更新，已停止自动填入；本次文字仍保留在口述记录。",
                                  hudMessage: "剪贴板已变化 · 文字已保留")
        }
        // Copy is useful even when macOS denies event posting or the user moves
        // their caret. Keep the recognized text on the clipboard so recovery is
        // a single Cmd-V in the destination; never require a trip to our window.
        guard writeClipboard(text) else {
            return DeliveryResult(message: "无法写入剪贴板；文字已保留在结果窗口。", hudMessage: "复制失败 · 文字已保留")
        }
        let ownedCount = board.changeCount
        func copied(_ reason: String, permission: Bool = false) -> DeliveryResult {
            // Reasons are fixed product messages, never recognized text or AX
            // field values. Keep failure evidence across later utterances.
            pasteLogger.notice("gate=copy_fallback reason=\(reason, privacy: .public) pid=\(target?.pid ?? -1) paste_dispatched=false")
            return DeliveryResult(message: reason + "文字已自动复制，可在需要的位置直接按 ⌘V 粘贴。",
                           hudMessage: "已复制 · 按 ⌘V 粘贴",
                           needsPermission: permission)
        }
        if !automatic { return copied("自动填入已关闭。") }
        if let issue = permissionCheck() { return copied(issue, permission: true) }
        guard let target else { return copied(captureIssue ?? "当前没有可填入的输入框。") }
        guard !changed else { return copied("录音或处理期间输入位置已变化，已停止自动填入。") }
        switch focusStatus(target) {
        case .changed: return copied("输入位置已变化，已停止自动填入。")
        case .unavailable: return copied("当前输入框暂时不可读取，已停止自动填入。")
        case .unchanged: break
        }
        // A later copy belongs to the user. Do not paste that unrelated content,
        // and do not overwrite it in an attempt to retry this delivery.
        guard board.changeCount == ownedCount else {
            return DeliveryResult(message: "剪贴板随后被其他复制操作更新，已停止自动填入；本次文字仍保留在口述记录。",
                                  hudMessage: "剪贴板已变化 · 文字已保留")
        }
        guard pasteKeySender(target.pid) else { return copied("无法发送粘贴按键。") }
        pasteLogger.notice("gate=paste_dispatched pid=\(target.pid)")
        // Learning observes a successful dispatch independently and must first
        // confirm actual insertion. It never gates or retries this paste.
        if let entryID { onPasteDispatched?(text, target, entryID) }
        // Event posting has no cross-application receipt, so never retry an
        // uncertain paste. Keep the text available, including for slow targets;
        // restoring an old clipboard after a fixed delay can paste stale data.
        return .pasteDispatched
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate, AVAudioRecorderDelegate {
    private let correctionObserver = DictationCorrectionObserver()
    private let learningToast = DictationLearningToast()
    private var pendingCorrectionID: UUID?
    private var correctionStatus = "填入后纠正术语，可自动加入词典。"
    private var phase: Phase = .idle
    private var statusText = "准备就绪"
    private var serviceText = "正在准备本地识别服务…"
    private var serviceCanRecord = false
    private var serviceResponded = false
    private var asrReadiness: DictationModelReadiness = .checking
    private var cleanupReadiness: DictationModelReadiness = .checking
    private var asrModel: String?
    private var cleanupModel: String?
    private var cleanupBackend: DictationCleanupBackend?
    private var healthRequest: URLSessionDataTask?
    private var healthRetry: DispatchWorkItem?
    private var healthGeneration = UUID()
    private var recoveryBudget = BackendRecoveryBudget()
    private var recoveryInterruptedUtterance: Bool?
    private var ownedBackend: Process?
    private var backendLog: FileHandle?
    private let backendIO = DispatchQueue(label: "local-dictation.backend-io", qos: .utility)
    private var backendLaunching = false
    private var backendLaunchID: UUID?
    private var terminating = false
    private var statusItem: NSStatusItem!
    private var startMenu: NSMenuItem!
    private var cancelMenu: NSMenuItem!
    private var statusMenu: NSMenuItem!
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var hotKeyLatch = HotKeyLatch()
    private var activeShortcut: DictationShortcut?
    private var registeredHotKeyID: UInt32 = 0
    private var hotKeyEventGeneration = UUID()
    private var shortcutCapturing = false
    private var shortcutWarning = ""
    private let functionKeyMonitor = FunctionKeyMonitor()
    private var functionKeyMessage = "Fn 未启用，需要允许输入监控。"
    private var shortcutDisplay: String { functionKeyMonitor.isEnabled ? "Fn" : activeShortcut?.display ?? "未设置" }
    private var shortcutPrompt: String { shortcutDisplay == "未设置" ? "可点击开始口述" : "按 \(shortcutDisplay) 开始口述" }
    private var recorder: AVAudioRecorder?
    private var audioURL: URL?
    private var request: URLSessionDataTask?
    private var timer: Timer?
    private var sessionID: UUID?
    private var target: FocusTarget?
    private var targetChanged = false
    private let inserter: TextInserter
    private var processingStartedAt: Date?
    private var activePreferences: DictationPreferences?
    private var activePromptVersionID: String?
    private var activePromptWarning: String?
    private var supportsPromptVersions = false
    private var supportsStreaming = false
    private var streamingCapture: StreamingAudioCapture?
    private var streamingJobs: [StreamingUtterance] = []
    private var deliveryHUDs: [UUID: DictationHUD] = [:]
    private var deliveryHUDOrder: [UUID] = []
    private var utteranceNumber = 0
    private var deliveryInFlight = false
    private var preparingDeliveryID: UUID?
    private var deliveryGeneration = UUID()
    private var hudScreenFrame: NSRect?
    private var suppressStreamingPresentation = CommandLine.arguments.contains("--self-test")
    private var hasStreamingWork: Bool { !streamingJobs.isEmpty }
    private var hasPendingWork: Bool { phase.busy || hasStreamingWork || reprocessGeneration != nil }
    private var canBeginRecording: Bool {
        serviceCanRecord && !configuringModels && !modelConfigurationActive && pendingModelSelection == nil && phase != .preparing && phase != .recording &&
            (supportsStreaming ? streamingJobs.count < 8 : !phase.busy)
    }
    private var promptCatalog: CleanupPromptCatalog?
    private var promptBusy = false
    private var promptError: String?
    private var promptGeneration = UUID()
    private var promptCatalogCurrent = false
    private var promptRefreshPending = false
    private lazy var promptClient = CleanupPromptClient(base: serviceBase, session: serviceSession)
    private lazy var reprocessClient = HistoryReprocessClient(base: serviceBase, session: serviceSession)
    private var supportsReprocess = false
    private var reprocessTask: URLSessionDataTask?
    private var reprocessGeneration: UUID?
    private var reprocessEntryID: UUID?
    private var reprocessError: String?
    private var reprocessHUD: DictationHUD?
    private var reprocessHUDGeneration: UInt64 = 0
    private var recordedAudioSeconds: Double?
    private var lastFocusCheck = Date.distantPast
    private let focusCheckQueue = DispatchQueue(label: "local-dictation.focus-check", qos: .userInitiated)
    private var focusCheckInFlight = false
    private var lastDisplayedSecond = -1
    private var lastEntryID: UUID?
    private var detailText = ""
    private let sessionStartedAt = Date()
    private let store = DictationStore(memoryOnly: CommandLine.arguments.contains("--render-preview") || CommandLine.arguments.contains("--self-test"))
    private var observer: NSObjectProtocol?
    private var windowController: DictationWindowController?
    private lazy var appIconController = DictationAppIconController()
    private lazy var appIconCoordinator = DictationAppIconCoordinator(store: store, controller: appIconController)
    private var appAppearanceObservation: NSKeyValueObservation?
    private var appearanceError: String?
    private var setupController: DictationSetupWindowController?
    private var configuringModels = false
    private var modelConfigurationActive = false
    private var selectedASRModelID = "qwen"
    private var selectedCleanupModelID = "cleanup"
    private var modelConfigurationMessage: String?
    // Saving a selection is not readiness. Keep the home controls pending
    // until health identifies the requested models and confirms both loaded.
    private var pendingModelSelection: (asr: String, cleanup: String)?
    private var modelSelectionTimedOut = false
    private var modelSelectionGeneration = UUID()
    private var hud: DictationHUD?
    private let serviceSession: URLSession

    init(serviceSession: URLSession = .shared, inserter: TextInserter = TextInserter()) {
        self.serviceSession = serviceSession
        self.inserter = inserter
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.onChange = { [weak self] in
            guard let self else { return }
            // History deletion removes completed presentation data only. The
            // current upload, insertion target, and option snapshot stay intact.
            if let id = self.lastEntryID, !self.store.entries.contains(where: { $0.id == id }) {
                self.lastEntryID = nil; self.detailText = ""
            }
            self.windowController?.reloadStore()
            if !self.store.preferences.automaticVocabularyLearning {
                self.correctionObserver.stop()
                if self.learningToast.awaitingConfirmation { self.learningToast.hide() }
            }
            self.updateUI()
        }
        if let option = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > option + 1 {
            NSApp.setActivationPolicy(.prohibited)
            // Preview appearance is transient: no user settings, icon metadata,
            // backend or global system appearance is changed by this branch.
            if let appearance = CommandLine.arguments.firstIndex(of: "--appearance"),
               CommandLine.arguments.count > appearance + 1 {
                NSApp.appearance = NSAppearance(named: CommandLine.arguments[appearance + 1] == "dark" ? .darkAqua : .aqua)
            }
            renderPreview(to: URL(fileURLWithPath: CommandLine.arguments[option + 1]))
            NSApp.terminate(nil)
            return
        }
        configureCorrectionLearning()
        readSavedModelSelection()
        NSApp.setActivationPolicy(.regular)
        applyApplicationAppearance(store.preferences.appearanceMode)
        appIconCoordinator.onChange = { [weak self] in self?.updateAppIconUI() }
        appAppearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.appIconCoordinator.systemAppearanceChanged() }
        }
        appIconCoordinator.restore()
        createMenu()
        registerHotKey()
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let active = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if self.phase.busy, let target = self.target, active.processIdentifier != target.pid { self.targetChanged = true }
        }
        showResults()
        checkHealth()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showResults()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if reprocessGeneration != nil {
            let alert = NSAlert()
            alert.messageText = "历史文字正在重新整理"
            alert.informativeText = "请等待本次结果保存后再退出。原记录会继续保留。"
            alert.addButton(withTitle: "继续等待"); alert.runModal()
            return .terminateCancel
        }
        if hasStreamingWork {
            let alert = NSAlert()
            alert.messageText = "口述尚未完成"
            alert.informativeText = "还有 \(streamingJobs.count) 段正在录音或处理。请等待结果，或在对应浮条中取消后再退出。"
            alert.addButton(withTitle: "继续口述")
            alert.runModal()
            return .terminateCancel
        }
        // Exiting or replacing the executable must never discard completed
        // dictations that are still waiting for durable storage. The store also
        // verifies its mirror here, including after recovery from a bad file.
        guard store.flushHistory() else {
            showResults()
            let alert = NSAlert()
            alert.messageText = "历史记录尚未保存，应用将继续运行"
            alert.informativeText = store.storageError ?? "请检查数据文件夹的权限和磁盘空间，保存成功后再退出或更新。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "返回应用")
            alert.runModal()
            return .terminateCancel
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminating = true
        correctionObserver.stop(); learningToast.hide()
        reprocessGeneration = nil; reprocessTask?.cancel(); reprocessTask = nil
        setupController?.shutdown()
        streamingCapture?.cancel()
        for job in streamingJobs { job.client.cancel(); job.hud.hide() }
        for panel in deliveryHUDs.values { panel.hide() }
        functionKeyMonitor.stop()
        cancelPendingBackendLaunch()
        sessionID = nil
        request?.cancel()
        invalidateHealthCallbacks()
        // An already running local-dictation service belongs to its launcher.
        // Only the process created by this app is stopped on app exit.
        if let ownedBackend, ownedBackend.isRunning { ownedBackend.terminate() }
        closeBackendLog()
        recorder?.stop()
        removeAudioFile()
        timer?.invalidate()
        hud?.hide()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func createMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "本地口述")
        let menu = NSMenu()
        menu.autoenablesItems = false
        statusMenu = NSMenuItem(title: "准备就绪", action: nil, keyEquivalent: "")
        statusMenu.isEnabled = false
        menu.addItem(statusMenu)
        startMenu = menuItem("开始口述", #selector(toggleRecording))
        menu.addItem(startMenu)
        cancelMenu = menuItem("取消本次口述", #selector(cancelRecording))
        menu.addItem(cancelMenu)
        menu.addItem(.separator())
        menu.addItem(menuItem("查看最近结果…", #selector(showResults)))
        menu.addItem(menuItem("复制整理文字", #selector(copyClean)))
        menu.addItem(menuItem("复制原始转写", #selector(copyRaw)))
        menu.addItem(.separator())
        menu.addItem(menuItem("检查本地服务", #selector(checkHealth)))
        menu.addItem(menuItem("模型与配置…", #selector(showSetup)))
        menu.addItem(menuItem("允许麦克风录音…", #selector(requestMicrophone)))
        menu.addItem(menuItem("允许自动填入…", #selector(requestAccessibility)))
        menu.addItem(.separator())
        menu.addItem(menuItem("退出本地口述", #selector(quit)))
        statusItem.menu = menu
        updateUI()
    }

    private func registerHotKey() {
        let specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let context = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = specs.withUnsafeBufferPointer { types in
            InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let context, let event else { return OSStatus(eventNotHandledErr) }
                let app = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
                var identifier = EventHotKeyID(signature: 0, id: 0)
                guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr else { return OSStatus(eventNotHandledErr) }
                let kind = GetEventKind(event), generation = app.hotKeyEventGeneration
                DispatchQueue.main.async { app.handleHotKey(kind: kind, id: identifier.id, generation: generation) }
                return noErr
            }, types.count, types.baseAddress, context, &eventHandler)
        }
        if handlerStatus != noErr { shortcutWarning = "无法安装组合快捷键，可重新打开应用后重试。" }
        functionKeyMonitor.onTrigger = { [weak self] in
            guard let self, !self.shortcutCapturing, !self.terminating else { return }
            self.toggleRecording()
        }
        functionKeyMonitor.shouldTrigger = { [weak self] in self?.shortcutCapturing == false && self?.terminating == false }
        let preferences = store.preferences
        if preferences.shortcutMode == "fn" {
            _ = replaceCombination(.defaultValue)
            activateFunctionKey()
        } else {
            let saved = DictationShortcut(keyCode: preferences.shortcutKeyCode, modifiers: preferences.shortcutModifiers)
            if let error = replaceCombination(saved) {
                if saved != .defaultValue, replaceCombination(.defaultValue) == nil {
                    shortcutWarning = "已改用默认组合 \(shortcutDisplay)。上次保存的快捷键不可用。"
                } else { shortcutWarning = error + " 可点击开始口述。" }
            }
        }
        statusText = shortcutWarning.isEmpty ? "准备就绪 · \(shortcutPrompt)" : shortcutWarning
        updateUI()
    }

    private func handleHotKey(kind: UInt32, id: UInt32, generation: UUID) {
        guard generation == hotKeyEventGeneration, id == registeredHotKeyID, activeShortcut != nil else { return }
        if shortcutCapturing {
            if let activeShortcut { windowController?.receiveRegisteredShortcut(activeShortcut, released: kind == UInt32(kEventHotKeyReleased)) }
            return
        }
        if hotKeyLatch.shouldToggle(eventKind: kind) { toggleRecording() }
    }

    private func replaceCombination(_ shortcut: DictationShortcut) -> String? {
        if let error = shortcut.validationError { return error }
        guard !shortcut.isFunctionKey, eventHandler != nil else { return "组合快捷键未能初始化，请重新打开应用。" }
        if activeShortcut != shortcut || hotKey == nil {
            var candidate: EventHotKeyRef?
            let candidateID = registeredHotKeyID &+ 1
            let identifier = EventHotKeyID(signature: 0x4C444943, id: candidateID)
            let result = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, identifier,
                GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &candidate)
            guard result == noErr, let candidate else {
                return "\(shortcut.display) 已被占用或系统不允许（\(result)），原快捷键保持不变。"
            }
            // Swap only after success. Queued old events must not trigger speech.
            let previous = hotKey
            hotKey = candidate; activeShortcut = shortcut; registeredHotKeyID = candidateID
            hotKeyEventGeneration = UUID(); hotKeyLatch = HotKeyLatch()
            if let previous { UnregisterEventHotKey(previous) }
        }
        return nil
    }

    private func activateFunctionKey() {
        functionKeyMessage = functionKeyMonitor.start() ?? "Fn 已启用：单独按下并松开，开始或结束口述。"
        if !functionKeyMonitor.isEnabled {
            if activeShortcut == nil { _ = replaceCombination(.defaultValue) }
            shortcutWarning = functionKeyMessage + (activeShortcut.map { " 备用组合：" + $0.display } ?? " 可点击开始口述。")
        } else {
            // Fn replaces the old combination only after its tap is enabled.
            // A missing permission keeps the existing combination as fallback.
            if let hotKey { UnregisterEventHotKey(hotKey) }
            hotKey = nil; activeShortcut = nil
            hotKeyEventGeneration = UUID(); hotKeyLatch = HotKeyLatch()
            shortcutWarning = ""
        }
        if phase == .idle { statusText = shortcutWarning.isEmpty ? "准备就绪 · \(shortcutPrompt)" : shortcutWarning }
    }

    private func replaceShortcut(_ shortcut: DictationShortcut, persist: Bool) -> String? {
        guard !hasPendingWork else { return "请先结束或取消本次口述，再修改快捷键。" }
        if let error = shortcut.validationError { return error }
        if shortcut.isFunctionKey {
            if activeShortcut == nil { _ = replaceCombination(.defaultValue) }
            activateFunctionKey()
        } else {
            if let error = replaceCombination(shortcut) { return error }
            functionKeyMonitor.stop(); functionKeyMessage = "当前使用组合快捷键。"; shortcutWarning = ""
        }
        if persist {
            store.updatePreferences {
                $0.shortcutMode = shortcut.isFunctionKey ? "fn" : "combination"
                $0.shortcutKeyCode = shortcut.keyCode; $0.shortcutModifiers = shortcut.modifiers; $0.shortcutDisplay = shortcut.display
            }
        }
        if phase == .idle { statusText = "准备就绪 · \(shortcutPrompt)" }
        updateUI()
        return shortcut.isFunctionKey && !functionKeyMonitor.isEnabled ? functionKeyMessage : nil
    }

    @objc private func requestInputMonitoring() {
        guard !hasPendingWork else { return }
        _ = CGRequestListenEventAccess()
        if store.preferences.shortcutMode == "fn" { activateFunctionKey() }
        updateUI()
        if !CGPreflightListenEventAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !CommandLine.arguments.contains("--render-preview"), !CommandLine.arguments.contains("--self-test") else { return }
        if store.preferences.shortcutMode == "fn", !hasPendingWork { activateFunctionKey() }
        updateUI()
    }

    @objc private func toggleRecording() {
        if phase == .recording { finishRecording(); return }
        guard phase != .preparing, supportsStreaming || !phase.busy else { return }
        guard canBeginRecording else {
            rejectRecordingStart("本地模型或处理队列暂未就绪，正在检查服务。")
            refreshHealth()
            return
        }
        // A retained dictionary may exceed the transport budget. Explain this
        // before recording so the user can repair it without losing a dictation.
        if let issue = DictationStore.validateVocabulary(store.preferences.vocabulary) {
            rejectRecordingStart(issue); return
        }
        if store.preferences.cleanupEnabled && !promptReadyForRecording {
            rejectRecordingStart("润色规则尚未就绪。请在“润色规则”中刷新，或关闭整理后仅转写。")
            loadPrompts(); return
        }
        let id = UUID()
        sessionID = id
        captureRecordingConfiguration()
        recordedAudioSeconds = nil
        target = !supportsStreaming && activePreferences?.autoInsertEnabled == true ? inserter.captureTarget() : nil
        if supportsStreaming, activePreferences?.autoInsertEnabled == true,
           let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            focusCheckQueue.async { TextInserter.warmInput(pid: pid) }
        }
        targetChanged = false
        setPhase(.preparing, "正在准备录音…")
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: beginRecording(id)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.sessionID == id else { return }
                    if granted { self.beginRecording(id) }
                    else { self.rejectRecordingStart("麦克风尚未授权。可在系统设置中允许后重试。") }
                }
            }
        default: rejectRecordingStart("麦克风尚未授权。请在“系统设置 → 隐私与安全性 → 麦克风”中允许本地口述。")
        }
    }

    private func rejectRecordingStart(_ message: String) {
        // A failed attempt to start another recording must never cancel the
        // independent utterances already running in the model queue.
        if hasStreamingWork {
            if phase == .preparing {
                sessionID = nil; activePreferences = nil; activePromptVersionID = nil
                activePromptWarning = nil; target = nil
            }
            refreshStreamingPresentation()
            statusText = message; updateUI()
        } else { fail(message) }
    }

    private func captureRecordingConfiguration() {
        activePreferences = store.preferences
        activePromptWarning = nil
        if store.preferences.cleanupEnabled && supportsPromptVersions && promptCatalog?.prompt_store_error != nil {
            // Freeze ASR-only fallback too: recovery of an independently
            // launched service must not add cleanup midway through dictation.
            activePreferences?.cleanupEnabled = false
            activePromptWarning = "润色规则暂不可用，本次保留 ASR 原文。"
        }
        // A later rule activation applies to the next recording. The service
        // resolves this immutable ID, not whichever version is active at stop.
        activePromptVersionID = activePreferences?.cleanupEnabled == true && supportsPromptVersions ? promptCatalog?.active_version_id : nil
    }

    private func beginRecording(_ id: UUID) {
        guard sessionID == id else { return }
        if supportsStreaming { beginStreamingRecording(id); return }
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("localdictation-\(id.uuidString).wav")
            audioURL = url
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            self.recorder = recorder
            guard recorder.prepareToRecord(), recorder.record(forDuration: 300) else { throw NSError(domain: "LocalDictation", code: 1) }
            setPhase(.recording, "正在听 · 再按 \(shortcutDisplay) 结束")
            timer?.invalidate()
            lastFocusCheck = .distantPast
            lastDisplayedSecond = -1
            let meteringTimer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.checkFocusIfNeeded()
                if self.phase == .recording {
                    self.recorder?.updateMeters()
                    let seconds = Int(self.recorder?.currentTime ?? 0)
                    if seconds >= 300 {
                        self.finishRecording()
                        self.setPhase(.processing, "已录满 5 分钟，" + self.processingMessage)
                        return
                    }
                    if seconds != self.lastDisplayedSecond {
                        self.lastDisplayedSecond = seconds
                        self.statusText = "正在听 \(seconds / 60):\(String(format: "%02d", seconds % 60)) · 再按快捷键结束"
                        self.updateUI()
                    } else { self.updateHUD() }
                } else if self.phase == .processing, Int(Date().timeIntervalSince(self.processingStartedAt ?? Date())) != self.lastDisplayedSecond {
                    self.lastDisplayedSecond = Int(Date().timeIntervalSince(self.processingStartedAt ?? Date()))
                    self.updateHUD()
                }
            }
            meteringTimer.tolerance = 1.0 / 240.0
            RunLoop.main.add(meteringTimer, forMode: .common)
            timer = meteringTimer
        } catch {
            fail("无法开始录音。请检查麦克风是否连接、权限是否已允许。")
        }
    }

    // MARK: - Continuous recognition and independently delivered utterances

    private func beginStreamingRecording(_ id: UUID) {
        guard let preferences = activePreferences,
              let options = try? DictationRequestOptions(preferences).encoded() else {
            rejectRecordingStart("本次录音设置不可用，请重新开始。"); return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("localdictation-\(id.uuidString).wav")
        let client = StreamingDictationClient(baseURL: serviceBase, session: serviceSession,
            optionsHeader: options.base64EncodedString(), promptVersionID: activePromptVersionID, sessionID: id)
        let job = StreamingUtterance(id: id, number: nextUtteranceNumber(), preferences: preferences,
            promptWarning: activePromptWarning, audioURL: url, client: client)
        let currentModel = promptCatalog?.current_model.id
        let samples = store.entries.filter { $0.cleanupApplied && currentModel != nil && $0.cleanupProfile?.modelID == currentModel }
            .prefix(16).map { DictationProcessingProgress.Sample(characterCount: $0.rawText.count, cleanupSeconds: $0.cleanupSeconds) }
        job.progress = DictationProcessingProgress(samples: samples, cleanupEnabled: preferences.cleanupEnabled)
        streamingJobs.append(job)
        if hudScreenFrame == nil {
            hudScreenFrame = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })?.visibleFrame
                ?? NSScreen.main?.visibleFrame
        }
        let capture = StreamingAudioCapture(url: url)
        streamingCapture = capture
        capture.onPCM = { [weak self] bytes, offset in
            guard self?.streamingJobs.contains(where: { $0.id == id }) == true else { return }
            client.appendPCM(bytes, offset: offset)
        }
        capture.onFailure = { [weak self] message in self?.failStreamingJob(id, message: message) }
        client.onProgress = { [weak self] snapshot in
            guard let self, let job = self.streamingJobs.first(where: { $0.id == id }) else { return }
            job.recognizedSeconds = Double(snapshot.processedSamples) / 16000
            job.partialText = snapshot.rawText
            job.backendState = snapshot.state
            if job.stoppedAt != nil {
                job.progress.observe(state: snapshot.state, characters: snapshot.rawText.count,
                    audioSeconds: job.audioSeconds, recognizedSeconds: job.recognizedSeconds,
                    now: ProcessInfo.processInfo.systemUptime)
            }
            if snapshot.state == "failed" {
                self.failStreamingJob(id, message: snapshot.error ?? "本段处理失败，已有识别结果已保留。"); return
            }
            self.updateStreamingHUDs()
        }
        client.onFinal = { [weak self] data, response, error in
            self?.receiveStreamingResult(id: id, data: data, response: response, error: error)
        }
        client.onFailure = { [weak self] message in self?.failStreamingJob(id, message: message) }
        job.hud.onFinish = { [weak self] in
            guard self?.sessionID == id else { return }; self?.finishRecording()
        }
        job.hud.onCancel = { [weak self] in self?.cancelStreamingJob(id) }
        job.hud.onAccessibility = { [weak self] in self?.requestAccessibility() }
        job.hud.onDidHide = { [weak self] in self?.removeDeliveryHUD(id) }
        do {
            try capture.start()
            client.start()
            setPhase(.recording, "正在听 · 再按 \(shortcutDisplay) 结束")
            startStreamingTimer(); restackStreamingHUDs()
        } catch { failStreamingJob(id, message: "无法开始录音，请检查麦克风连接与权限。") }
    }

    private func startStreamingTimer() {
        timer?.invalidate()
        lastFocusCheck = .distantPast; lastDisplayedSecond = -1
        let tick = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if let capture = self.streamingCapture, self.phase == .recording {
                let seconds = Int(capture.meterSnapshot.elapsedSeconds)
                if seconds >= 300 { self.finishRecording(); return }
                if seconds != self.lastDisplayedSecond {
                    self.lastDisplayedSecond = seconds
                    self.statusText = "正在听 \(seconds / 60):\(String(format: "%02d", seconds % 60)) · 再按快捷键结束"
                    self.updateUI()
                } else { self.updateStreamingHUDs() }
            } else { self.updateStreamingHUDs() }
        }
        tick.tolerance = 1.0 / 240.0
        RunLoop.main.add(tick, forMode: .common); timer = tick
    }

    private func finishStreamingRecording(_ id: UUID) {
        guard sessionID == id, phase == .recording,
              let capture = streamingCapture, let job = streamingJobs.first(where: { $0.id == id }),
              job.stoppedAt == nil else { return }
        job.stoppedAt = Date(); job.audioSeconds = capture.meterSnapshot.elapsedSeconds
        job.progress.observe(state: job.backendState, characters: job.partialText.count,
            audioSeconds: job.audioSeconds, recognizedSeconds: job.recognizedSeconds,
            now: ProcessInfo.processInfo.systemUptime)
        // Release the microphone immediately. Draining the previous converter,
        // uploading its tail and waiting for its model result cannot block the
        // next microphone session or overwrite that session's configuration.
        streamingCapture = nil; sessionID = nil
        activePreferences = nil; activePromptVersionID = nil; activePromptWarning = nil
        target = nil; audioURL = nil
        refreshStreamingPresentation()
        capture.stop { [weak self] result in
            guard let self, self.streamingJobs.contains(where: { $0.id == id }) else { return }
            switch result {
            case .success(let count): job.audioSeconds = Double(count) / 16000; job.client.finish(totalSamples: count)
            case .failure: self.failStreamingJob(id, message: "录音尾段保存失败，已有识别结果已保留。")
            }
        }
    }

    private func receiveStreamingResult(id: UUID, data: Data?, response: URLResponse?, error: Error?) {
        guard let job = streamingJobs.first(where: { $0.id == id }), job.result == nil else { return }
        if let error { failStreamingJob(id, message: "本段处理连接中断：\(error.localizedDescription)"); return }
        guard let response = response as? HTTPURLResponse, let data else {
            failStreamingJob(id, message: "本地服务没有返回本段结果。"); return
        }
        guard (200..<300).contains(response.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            failStreamingJob(id, message: String((object?["error"] as? String ?? "本段处理失败。").prefix(220))); return
        }
        guard let result = try? JSONDecoder().decode(DictationResult.self, from: data) else {
            failStreamingJob(id, message: "本段结果格式不完整，已有识别结果已保留。"); return
        }
        job.result = result; job.resultReceivedAt = Date()
        job.completionDeadline = ProcessInfo.processInfo.systemUptime + 0.18
        updateStreamingHUDs(); drainStreamingResults()
    }

    private func refreshStreamingPresentation() {
        if sessionID != nil && (phase == .recording || phase == .preparing) { updateUI(); return }
        if !streamingJobs.isEmpty {
            processingStartedAt = streamingJobs.first?.stoppedAt
            setPhase(.processing, "\(streamingJobs.count) 段正在整理 · 可继续口述")
        } else {
            timer?.invalidate(); timer = nil
            setPhase(.idle, "准备就绪 · \(shortcutPrompt)")
        }
    }

    private func updateStreamingHUDs() {
        guard !suppressStreamingPresentation else { return }
        for job in streamingJobs {
            var state = displayState
            state.sessionLabel = "第 \(job.number) 段"
            state.recording = sessionID == job.id && phase == .recording
            state.processing = !state.recording
            state.canCancel = true; state.processingStage = "正在整理"
            state.processingComplete = job.result != nil
            state.processingCompletionTitle = job.result?.cleanupOutcome(requested: job.preferences.cleanupEnabled, promptWarning: job.promptWarning)?.completionTitle
            state.processingProgress = state.recording ? nil : job.result != nil ? 1
                : job.progress.advance(now: ProcessInfo.processInfo.systemUptime)
            state.recognizedSeconds = job.recognizedSeconds
            state.cleanupEnabled = job.preferences.cleanupEnabled
            state.elapsedSeconds = state.recording ? Int(streamingCapture?.meterSnapshot.elapsedSeconds ?? 0)
                : Int(Date().timeIntervalSince(job.stoppedAt ?? Date()))
            if !state.recording { state.meterLevel = 0; state.meterPeakLevel = 0 }
            job.hud.update(state)
        }
    }

    private func nextUtteranceNumber() -> Int {
        // A batch lasts exactly as long as its cards. A clipboard dispatch
        // cooldown is not a visible session and must not keep its numbering.
        if streamingJobs.isEmpty && deliveryHUDs.isEmpty { utteranceNumber = 0 }
        utteranceNumber += 1
        return utteranceNumber
    }

    private func restackStreamingHUDs() {
        let panels = deliveryHUDOrder.compactMap { deliveryHUDs[$0] } + streamingJobs.map(\.hud)
        if panels.isEmpty { hudScreenFrame = nil; utteranceNumber = 0 }
        guard !suppressStreamingPresentation else { return }
        for (index, panel) in panels.enumerated() { panel.setStackIndex(index, count: panels.count, visibleFrame: hudScreenFrame) }
    }

    private func removeDeliveryHUD(_ id: UUID) {
        guard deliveryHUDs.removeValue(forKey: id) != nil else { return }
        deliveryHUDOrder.removeAll { $0 == id }; restackStreamingHUDs()
    }

    private func retainDeliveryHUD(_ job: StreamingUtterance, message: String, permission: Bool = false,
                                   text: String? = nil, attention: String? = nil) {
        deliveryHUDs[job.id] = job.hud
        if !deliveryHUDOrder.contains(job.id) { deliveryHUDOrder.append(job.id) }
        configureResultHUD(job.hud, entryID: job.savedEntryID, message: message, permission: permission, text: text, attention: attention)
        restackStreamingHUDs()
    }

    private func configureResultHUD(_ panel: DictationHUD, entryID: UUID?, message: String,
                                    permission: Bool = false, text: String? = nil, attention: String? = nil) {
        panel.onCopy = nil; panel.onRetryCleanup = nil; panel.onViewResult = nil
        if let text, !text.isEmpty {
            panel.onCopy = { [weak self, weak panel] in
                guard let self, let panel else { return }
                let copied = self.inserter.insert(text, target: nil, changed: false, automatic: false)
                panel.showDelivery(message: attention.map { $0 + " · " + copied.hudMessage } ?? copied.hudMessage,
                    needsPermission: false, show: !self.suppressStreamingPresentation)
            }
        }
        if attention != nil, let entryID,
           store.entries.first(where: { $0.id == entryID })?.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            panel.onRetryCleanup = { [weak self, weak panel] in
                guard let self, let panel else { return }; self.retryCleanup(entryID: entryID, panel: panel)
            }
        }
        panel.showDelivery(message: message, needsPermission: permission, show: !suppressStreamingPresentation)
    }

    private func cancelStreamingJob(_ id: UUID) {
        guard let job = streamingJobs.first(where: { $0.id == id }) else { return }
        if preparingDeliveryID == id {
            preparingDeliveryID = nil; deliveryGeneration = UUID(); deliveryInFlight = false
        }
        job.client.cancel()
        if sessionID == id {
            streamingCapture?.cancel(); streamingCapture = nil; sessionID = nil
            activePreferences = nil; activePromptVersionID = nil; activePromptWarning = nil; target = nil
        }
        streamingJobs.removeAll { $0.id == id }
        job.hud.hide(); try? FileManager.default.removeItem(at: job.audioURL)
        refreshStreamingPresentation(); restackStreamingHUDs(); drainStreamingResults()
        // Recording may already have GPU work in flight. Cancelling the HTTP
        // connection alone cannot establish that the model worker is free.
        refreshHealth()
    }

    private func failStreamingJob(_ id: UUID, message: String, refresh: Bool = true) {
        guard let job = streamingJobs.first(where: { $0.id == id }) else { return }
        if preparingDeliveryID == id {
            preparingDeliveryID = nil; deliveryGeneration = UUID(); deliveryInFlight = false
        }
        job.client.cancel()
        if sessionID == id {
            streamingCapture?.cancel(); streamingCapture = nil; sessionID = nil
            activePreferences = nil; activePromptVersionID = nil; activePromptWarning = nil; target = nil
        }
        streamingJobs.removeAll { $0.id == id }
        // A complete later result may be waiting behind an earlier utterance.
        // Service failure stops its delivery, never downgrades or discards it.
        if job.result != nil {
            persistStreamingResult(job, interrupted: "结果已保存，自动填入已中止。" + message)
        } else if !job.partialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Stable ASR after transport failure is explicitly marked partial.
            let entry = store.add(rawText: job.partialText, text: job.partialText, asrSeconds: 0,
                cleanupSeconds: 0, totalSeconds: 0, audioSeconds: job.recognizedSeconds,
                cleanupApplied: false, warning: "未完成口述，仅保存已识别部分。" + message,
                cleanupOutcome: DictationCleanupOutcome(status: "skipped", reason: "incomplete_asr"))
            lastEntryID = entry.id
            job.savedEntryID = entry.id
        }
        try? FileManager.default.removeItem(at: job.audioURL)
        let notice = job.result != nil ? "结果已保留 · 自动填入未完成"
            : job.partialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "本段处理未完成 · 请重新口述" : "处理未完成 · 已保留部分文字"
        retainDeliveryHUD(job, message: notice, text: job.result?.text ?? job.partialText, attention: notice)
        detailText = message
        refreshStreamingPresentation(); restackStreamingHUDs(); drainStreamingResults()
        if refresh { refreshHealth() }
    }

    private func persistStreamingResult(_ job: StreamingUtterance, interrupted: String? = nil) {
        guard job.savedEntryID == nil, let result = job.result,
              !result.text.isEmpty || !result.raw_text.isEmpty else { return }
        var metrics = result.streaming_metrics
        metrics?.clientStopToResultSeconds = (job.resultReceivedAt ?? Date()).timeIntervalSince(job.stoppedAt ?? Date())
        let warning = [result.warning, job.promptWarning, interrupted].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        let entry = store.add(rawText: result.raw_text, text: result.text, asrSeconds: result.asr_seconds,
            cleanupSeconds: result.cleanup_seconds, totalSeconds: result.total_seconds,
            audioSeconds: result.audio_seconds ?? job.audioSeconds, cleanupApplied: result.cleanup_applied,
            warning: warning.isEmpty ? nil : warning, cleanupProfile: result.cleanup_profile,
            asrModel: result.asr_model, streamingMetrics: metrics,
            cleanupOutcome: result.cleanupOutcome(requested: job.preferences.cleanupEnabled, promptWarning: job.promptWarning))
        job.savedEntryID = entry.id; lastEntryID = entry.id
    }

    private func drainStreamingResults() {
        guard !deliveryInFlight, let job = streamingJobs.first, let result = job.result else { return }
        // Persist in utterance order before the visual hold. A crash during
        // animation must not introduce a new loss window. Cancelling this
        // already-finished card stops paste; the saved result remains history.
        persistStreamingResult(job)
        // Let the actual completion fill land before delivery. This is a short
        // presentation hold, never a receipt barrier or another model wait.
        // Re-enter through the queue: cancellation/removal invalidates the job.
        let remaining = job.completionDeadline - ProcessInfo.processInfo.systemUptime
        if remaining > 0 {
            guard !job.completionScheduled else { return }
            job.completionScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self, weak job] in
                guard let self, let job, self.streamingJobs.contains(where: { $0.id == job.id }) else { return }
                job.completionScheduled = false; self.drainStreamingResults()
            }
            return
        }
        deliveryInFlight = true
        let generation = UUID(); deliveryGeneration = generation
        preparingDeliveryID = job.id
        let clipboardCount = inserter.clipboardChangeCount
        let deliver: (FocusTarget?) -> Void = { [weak self, weak job] target in
            guard let self, let job, !self.terminating, self.deliveryGeneration == generation,
                  self.streamingJobs.first?.id == job.id else { return }
            self.preparingDeliveryID = nil
            self.streamingJobs.removeFirst()
            self.finishStreamingDelivery(job, target: target, clipboardCount: clipboardCount, generation: generation)
        }
        if job.preferences.autoInsertEnabled, !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            inserter.prepareCurrentInput(isCurrent: { [weak self, weak job] in
                guard let self, let job else { return false }
                return !self.terminating && self.deliveryGeneration == generation && self.streamingJobs.first?.id == job.id
            }, completion: deliver)
        } else { deliver(nil) }
    }

    private func finishStreamingDelivery(_ job: StreamingUtterance, target: FocusTarget?, clipboardCount: Int, generation: UUID) {
        guard let result = job.result else { return }
        let elapsed = (job.resultReceivedAt ?? Date()).timeIntervalSince(job.stoppedAt ?? Date())
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let delivery = text.isEmpty
            ? DeliveryResult(message: "未识别到文字", hudMessage: "未识别到文字")
            : inserter.insert(text, target: target, changed: false, automatic: job.preferences.autoInsertEnabled,
                              entryID: job.savedEntryID, expectedClipboardChangeCount: clipboardCount)
        detailText = String(format: "第 %d 段 · 停止到结果 %.2f 秒 · 识别计算 %.2f 秒 · 整理 %.2f 秒", job.number, elapsed, result.asr_seconds, result.cleanup_seconds) + "\n" + delivery.message
        let attention = text.isEmpty ? nil : result.cleanupOutcome(requested: job.preferences.cleanupEnabled, promptWarning: job.promptWarning)?.attentionMessage
        if delivery.showHUD || attention != nil {
            let message = attention.map { $0 + (delivery.showHUD ? " · " + delivery.hudMessage : "") } ?? delivery.hudMessage
            retainDeliveryHUD(job, message: message, permission: delivery.needsPermission, text: text, attention: attention)
        }
        else { job.hud.hide() }
        try? FileManager.default.removeItem(at: job.audioURL)
        refreshStreamingPresentation(); restackStreamingHUDs()
        if !delivery.showHUD {
            // Ready results may arrive together. Space ordinary Cmd-V events
            // briefly so they do not share the same clipboard update/runloop.
            // This is dispatch pacing, not a receipt: never gate later segments
            // on AX text readback, and never retry an uncertain paste.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
                guard let self, self.deliveryGeneration == generation else { return }
                self.deliveryInFlight = false; self.drainStreamingResults()
            }
        } else { deliveryInFlight = false; drainStreamingResults() }
    }

    private func checkFocusIfNeeded() {
        if supportsStreaming { return }
        guard !focusCheckInFlight, Date().timeIntervalSince(lastFocusCheck) >= 0.25,
              let target, let id = sessionID, !targetChanged else { return }
        lastFocusCheck = Date()
        focusCheckInFlight = true
        // AX messaging can wait for another app. Keep it off the audio-meter and
        // display runloop, and treat temporary unreadability as unknown, not as
        // evidence that the user moved. Final delivery still requires a match.
        focusCheckQueue.async { [weak self] in
            guard let self else { return }
            let status = self.inserter.focusStatus(target)
            DispatchQueue.main.async {
                self.focusCheckInFlight = false
                guard self.sessionID == id, self.phase.busy else { return }
                if status == .changed { self.targetChanged = true }
            }
        }
    }

    private func finishRecording() {
        if let id = sessionID, streamingJobs.contains(where: { $0.id == id }) {
            finishStreamingRecording(id); return
        }
        guard phase == .recording else { return }
        guard let id = sessionID, let url = audioURL else { return }
        recordedAudioSeconds = recorder?.currentTime
        recorder?.stop()
        recorder = nil
        processingStartedAt = Date()
        setPhase(.processing, processingMessage)
        // Read the finished file off the main thread. Once bytes are retained by
        // the upload, remove the temporary recording on success and on failure.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let data = try? Data(contentsOf: url)
            try? FileManager.default.removeItem(at: url)
            DispatchQueue.main.async {
                guard let self, self.sessionID == id else { return }
                self.audioURL = nil
                guard let data, data.count > 44 else { self.fail("没有录到可识别的声音，请重试。"); return }
                self.submit(data, id: id)
            }
        }
    }

    private func submit(_ audio: Data, id: UUID) {
        guard let preferences = activePreferences, let options = try? DictationRequestOptions(preferences).encoded() else {
            rejectRecordingStart("本次录音设置不可用，请重新开始。"); return
        }
        var upload = URLRequest(url: serviceBase.appendingPathComponent("dictate"))
        upload.httpMethod = "POST"
        upload.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        upload.setValue(options.base64EncodedString(), forHTTPHeaderField: "X-Dictation-Options")
        if let activePromptVersionID { upload.setValue(activePromptVersionID, forHTTPHeaderField: "X-Cleanup-Prompt-Version") }
        upload.httpBody = audio
        upload.timeoutInterval = 180
        request = serviceSession.dataTask(with: upload) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.receiveDictationReply(id: id, preferences: preferences, data: data, response: response, error: error)
            }
        }
        request?.resume()
    }

    private func receiveDictationReply(id: UUID, preferences: DictationPreferences, data: Data?, response: URLResponse?, error: Error?) {
        guard sessionID == id else { return }
        request = nil
        if let error = error as NSError? {
            if error.code == NSURLErrorCancelled { return }
            failUpload("本地服务未响应，正在检查服务。本次口述已中止，请稍后重新录音。"); return
        }
        guard let response = response as? HTTPURLResponse, let data else {
            failUpload("本地服务没有返回结果，正在检查服务。"); return
        }
        guard (200..<300).contains(response.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let detail = (object?["detail"] as? String) ?? (object?["error"] as? String) ?? "请检查本地服务状态后重试。"
            failUpload("处理失败：\(String(detail.prefix(220)))")
            return
        }
        guard let result = try? JSONDecoder().decode(DictationResult.self, from: data) else {
            failUpload("本地服务的结果格式不完整。原有结果已保留，正在检查服务。"); return
        }
        timer?.invalidate()
        timer = nil
        serviceCanRecord = true
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        sessionID = nil
        activePreferences = nil
        activePromptVersionID = nil
        let outcome = result.cleanupOutcome(requested: preferences.cleanupEnabled, promptWarning: activePromptWarning)
        let cleanupWarning = [result.warning, activePromptWarning].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        activePromptWarning = nil
        let elapsed = Date().timeIntervalSince(processingStartedAt ?? Date())
        let metrics = String(format: "停止到结果 %.2f 秒 · 识别 %.2f 秒 · 整理 %.2f 秒 · 服务处理 %.2f 秒", elapsed, result.asr_seconds, result.cleanup_seconds, result.total_seconds)
        var savedEntryID: UUID?
        if !text.isEmpty || !result.raw_text.isEmpty {
            let entry = store.add(rawText: result.raw_text, text: result.text, asrSeconds: result.asr_seconds,
                cleanupSeconds: result.cleanup_seconds, totalSeconds: result.total_seconds,
                audioSeconds: result.audio_seconds ?? recordedAudioSeconds,
                cleanupApplied: result.cleanup_applied, warning: cleanupWarning.isEmpty ? nil : cleanupWarning,
                cleanupProfile: result.cleanup_profile, asrModel: result.asr_model,
                cleanupOutcome: outcome)
            lastEntryID = entry.id
            savedEntryID = entry.id
        }
        let delivery = text.isEmpty
            ? DeliveryResult(message: "未识别到文字，请重试口述。", hudMessage: "未识别到文字")
            : inserter.insert(text, target: target, changed: targetChanged, automatic: preferences.autoInsertEnabled, entryID: savedEntryID)
        detailText = metrics + "\n" + delivery.message
        let attention = text.isEmpty ? nil : outcome?.attentionMessage
        setPhase(text.isEmpty ? .failed : .completed, text.isEmpty ? "未识别到文字" : "\(outcome?.completionTitle ?? "已完成") · \(delivery.message)")
        if delivery.showHUD || attention != nil {
            if hud == nil { hud = DictationHUD(); hud?.onAccessibility = { [weak self] in self?.requestAccessibility() } }
            let message = attention.map { $0 + (delivery.showHUD ? " · " + delivery.hudMessage : "") } ?? delivery.hudMessage
            configureResultHUD(hud!, entryID: savedEntryID, message: message, permission: delivery.needsPermission, text: text, attention: attention)
        }
        else { hud?.hide() }
        windowController?.reloadStore()
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.recorder === recorder else { return }
            self.fail("录音中断，请检查麦克风后重试。")
        }
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.recorder === recorder, self.phase == .recording else { return }
            if flag {
                self.finishRecording()
                self.setPhase(.processing, "录音已结束，" + self.processingMessage)
            } else { self.fail("录音提前结束，请检查麦克风后重试。") }
        }
    }

    @objc private func cancelRecording() {
        if hasStreamingWork {
            if let id = sessionID ?? streamingJobs.last?.id { cancelStreamingJob(id) }
            return
        }
        guard phase.busy else { return }
        let wasProcessing = phase == .processing
        sessionID = nil
        activePreferences = nil
        activePromptVersionID = nil
        activePromptWarning = nil
        request?.cancel()
        request = nil
        recorder?.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        removeAudioFile()
        setPhase(.idle, "已取消 · 上次结果仍可查看")
        if wasProcessing { refreshHealth() }
    }

    private func removeAudioFile() {
        if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
        audioURL = nil
    }

    private func fail(_ message: String) {
        if hasStreamingWork {
            deliveryInFlight = true; deliveryGeneration = UUID()
            preparingDeliveryID = nil
            for id in streamingJobs.map(\.id) { failStreamingJob(id, message: message, refresh: false) }
            deliveryInFlight = false
        }
        sessionID = nil
        activePreferences = nil
        activePromptVersionID = nil
        activePromptWarning = nil
        request?.cancel()
        request = nil
        recorder?.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        removeAudioFile()
        setPhase(.failed, message)
    }

    private func failUpload(_ message: String) {
        // A failed HTTP request does not prove server inference has stopped.
        // Disable the next recording before publishing the failed state, then
        // poll health until the service is ready. Never resubmit these bytes.
        serviceCanRecord = false
        fail(message)
        if hud == nil { hud = DictationHUD() }
        configureResultHUD(hud!, entryID: nil, message: "本段处理未完成 · 请重新口述", attention: nil)
        refreshHealth()
    }

    private func setPhase(_ phase: Phase, _ message: String) {
        self.phase = phase
        statusText = message
        updateUI()
    }

    private var processingMessage: String {
        "正在整理"
    }

    private var displayState: DictationUIState {
        var state = DictationUIState()
        state.status = statusText; state.serviceMessage = serviceText; state.serviceReady = serviceCanRecord
        state.asrReadiness = asrReadiness; state.cleanupReadiness = cleanupReadiness
        state.asrModel = asrModel; state.cleanupModel = cleanupModel
        state.selectedASRModelID = pendingModelSelection?.asr ?? selectedASRModelID
        state.selectedCleanupModelID = pendingModelSelection?.cleanup ?? selectedCleanupModelID
        state.canSwitchModels = !terminating && !hasPendingWork && !configuringModels && !modelConfigurationActive && (pendingModelSelection == nil || modelSelectionTimedOut) && !backendLaunching
        state.modelConfigurationMessage = modelConfigurationMessage
        if modelConfigurationActive || (pendingModelSelection != nil && !modelSelectionTimedOut) {
            state.asrReadiness = .loading; state.cleanupReadiness = .loading
        } else if pendingModelSelection != nil && modelSelectionTimedOut {
            state.asrReadiness = .unavailable; state.cleanupReadiness = .unavailable
        }
        state.recording = phase == .recording; state.processing = phase == .processing
        state.cleanupEnabled = (activePreferences ?? store.preferences).cleanupEnabled
        state.cleanupBackend = cleanupBackend
        state.waveformStyle = store.preferences.waveformStyle
        state.canStart = canBeginRecording; state.canCancel = phase.busy
        state.pendingCount = streamingJobs.filter { $0.stoppedAt != nil }.count
        state.elapsedSeconds = phase == .recording ? Int(streamingCapture?.meterSnapshot.elapsedSeconds ?? recorder?.currentTime ?? 0)
            : phase == .processing ? Int(Date().timeIntervalSince(processingStartedAt ?? Date())) : 0
        if let recorder, phase == .recording {
            state.meterLevel = DictationWaveformEnvelope.levelFromDecibels(Double(recorder.averagePower(forChannel: 0)))
            state.meterPeakLevel = DictationWaveformEnvelope.levelFromDecibels(Double(recorder.peakPower(forChannel: 0)))
        }
        if let capture = streamingCapture, phase == .recording {
            state.meterLevel = DictationWaveformEnvelope.levelFromDecibels(capture.meterSnapshot.averageDecibels)
            state.meterPeakLevel = DictationWaveformEnvelope.levelFromDecibels(capture.meterSnapshot.peakDecibels)
        }
        state.detail = detailText; state.lastEntryID = lastEntryID
        state.shortcutDisplay = shortcutDisplay; state.shortcutWarning = shortcutWarning
        state.canEditShortcut = !hasPendingWork
        state.functionKeyMessage = functionKeyMessage
        state.functionKeyEnabled = functionKeyMonitor.isEnabled
        state.functionKeySelected = store.preferences.shortcutMode == "fn"
        state.autoInsertEnabled = (activePreferences ?? store.preferences).autoInsertEnabled
        state.fallbackShortcut = activeShortcut?.display
        return state
    }

    private func updateHUD() {
        if hasStreamingWork { hud?.hideActivity(); updateStreamingHUDs(); return }
        guard phase == .recording || phase == .processing else { hud?.hideActivity(); return }
        if hud == nil {
            let hud = DictationHUD()
            hud.onFinish = { [weak self] in if self?.phase == .recording { self?.finishRecording() } }
            hud.onCancel = { [weak self] in self?.cancelRecording() }
            hud.onAccessibility = { [weak self] in self?.requestAccessibility() }
            self.hud = hud
        }
        hud?.update(displayState)
    }

    private func updateUI() {
        statusMenu?.title = phase == .recording ? "正在录音" : phase == .processing ? processingMessage : "本地口述"
        statusItem?.button?.image = NSImage(systemSymbolName: phase == .recording ? "record.circle.fill" : phase == .processing ? "ellipsis.circle" : "mic", accessibilityDescription: "本地口述")
        let shortcutSuffix = shortcutDisplay == "未设置" ? "" : "  " + shortcutDisplay
        startMenu?.title = (phase == .recording ? (activePreferences?.cleanupEnabled == false ? "结束并识别" : "结束并整理") : "开始口述") + shortcutSuffix
        startMenu?.isEnabled = canBeginRecording || phase == .recording
        cancelMenu?.isEnabled = phase.busy
        var state = displayState
        state.inputMonitoringAllowed = CGPreflightListenEventAccess()
        state.microphoneAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let permission = TextInserter.systemPermissionState()
        state.accessibilityAllowed = permission.accessibility && permission.postEvent
        state.automaticInsertionPermissionDetails = "辅助功能：\(permission.accessibility ? "已允许" : "未生效") · 粘贴按键：\(permission.postEvent ? "已允许" : "未生效")"
        windowController?.updateState(state)
        setupController?.refreshConfigurationAvailability()
        updateHUD()
    }

    @objc private func checkHealth() {
        if let ownedBackend, !ownedBackend.isRunning { handleBackendTermination(ownedBackend) }
        recoveryBudget.reset()
        refreshHealth()
    }

    private func invalidateHealthCallbacks() {
        healthGeneration = UUID()
        healthRequest?.cancel()
        healthRequest = nil
        healthRetry?.cancel()
        healthRetry = nil
    }

    private func scheduleHealthRefresh(after delay: TimeInterval) {
        guard pendingModelSelection == nil || !modelSelectionTimedOut else { return }
        healthRetry?.cancel()
        let generation = healthGeneration
        let retry = DispatchWorkItem { [weak self] in
            guard let self, !self.terminating, self.healthGeneration == generation else { return }
            self.refreshHealth()
        }
        healthRetry = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: retry)
    }

    private var diagnosticDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/LocalDictation", isDirectory: true)
    }

    private var runtimeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LocalDictation/Runtime", isDirectory: true)
    }

    private var bundledPython: URL? {
        guard let path = Bundle.main.resourceURL?.appendingPathComponent("Python/bin/python3"),
              FileManager.default.isExecutableFile(atPath: path.path) else { return nil }
        return path
    }

    private func ensureSetupController() -> DictationSetupWindowController? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        if setupController == nil {
            let controller = DictationSetupWindowController(runtime: runtimeDirectory, resources: resources)
            controller.canConfigure = { [weak self] in self?.hasPendingWork == false }
            controller.onReady = { [weak self] in
                guard let self else { return }
                self.readSavedModelSelection()
                self.waitForSelectedModels(asr: self.selectedASRModelID, cleanup: self.selectedCleanupModelID)
                self.checkHealth()
            }
            controller.onConfigurationActivity = { [weak self] active in
                guard let self else { return }
                self.modelConfigurationActive = active
                if active { self.modelConfigurationMessage = nil }
                self.updateUI()
            }
            controller.prepareDownload = { [weak self] completion in self?.prepareModelDownload(completion) }
            controller.onDownloadFinished = { [weak self] in
                guard let self else { return }
                self.configuringModels = false
                if !self.terminating { self.checkHealth() }
            }
            controller.onMicrophone = { [weak self] in self?.requestMicrophone() }
            controller.onAccessibility = { [weak self] in self?.requestAccessibility() }
            controller.onInputMonitoring = { [weak self] in self?.requestInputMonitoring() }
            setupController = controller
        }
        return setupController
    }

    @objc private func showSetup() { ensureSetupController()?.present() }

    private func readSavedModelSelection() {
        // Only regular local files are read; pipes and links must never block
        // UI updates. Installation diagnostics report invalid configurations.
        func selection(_ name: String, allowed: [String], fallback: String) -> String {
            let url = runtimeDirectory.appendingPathComponent(name)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let value = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                  allowed.contains(value) else { return fallback }
            return value
        }
        selectedASRModelID = selection("asr-backend", allowed: ["qwen", "whisper"], fallback: "qwen")
        selectedCleanupModelID = selection("cleanup-model", allowed: ["cleanup", "cleanup-9b"], fallback: "cleanup")
    }

    private func selectHomeModels(asr: String? = nil, cleanup: String? = nil) {
        guard displayState.canSwitchModels, let setup = ensureSetupController() else { return }
        let requestedASR = asr ?? selectedASRModelID
        let requestedCleanup = cleanup ?? selectedCleanupModelID
        guard ["qwen", "whisper"].contains(requestedASR), ["cleanup", "cleanup-9b"].contains(requestedCleanup) else { return }
        guard requestedASR != selectedASRModelID || requestedCleanup != selectedCleanupModelID else { updateUI(); return }
        let previousPending = pendingModelSelection
        let previousTimeout = modelSelectionTimedOut
        pendingModelSelection = (requestedASR, requestedCleanup)
        modelSelectionTimedOut = false
        modelConfigurationMessage = nil
        let accepted = setup.configureModels(asr: requestedASR, cleanup: requestedCleanup) { [weak self] result in
            guard let self else { return }
            if case .failure(let error) = result {
                self.readSavedModelSelection()
                self.restoreModelSelectionAfterFailure(previous: previousPending, timedOut: previousTimeout, message: error.localizedDescription)
                self.checkHealth()
            }
            self.updateUI()
        }
        if !accepted {
            restoreModelSelectionAfterFailure(previous: previousPending, timedOut: previousTimeout,
                message: "模型配置暂不可用，请完成当前操作后重试。")
        }
        updateUI()
    }

    private func restoreModelSelectionAfterFailure(previous: (asr: String, cleanup: String)?, timedOut: Bool, message: String) {
        // A rejected retry does not prove the previously requested model ever
        // loaded. Preserve its identity guard until health can confirm it.
        pendingModelSelection = previous; modelSelectionTimedOut = timedOut
        modelSelectionGeneration = UUID(); modelConfigurationMessage = message
        if previous != nil { serviceCanRecord = false }
    }

    private func waitForSelectedModels(asr: String, cleanup: String) {
        pendingModelSelection = (asr, cleanup)
        modelSelectionTimedOut = false
        let generation = UUID(); modelSelectionGeneration = generation
        // A stalled loader must not leave the picker spinning forever. The
        // saved choice remains intact and a later health reply can recover it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in
            self?.expireModelSelection(generation: generation)
        }
        updateUI()
    }

    private func expireModelSelection(generation: UUID) {
        guard modelSelectionGeneration == generation, pendingModelSelection != nil else { return }
        // Stop the animation and allow another choice, but retain the identity
        // requirement: an old ready process must never masquerade as this model.
        modelSelectionTimedOut = true; serviceCanRecord = false
        healthRetry?.cancel(); healthRetry = nil
        asrReadiness = .unavailable; cleanupReadiness = .unavailable
        modelConfigurationMessage = "模型加载超时，请检查配置或切换其他模型。"
        updateUI()
    }

    private func receiveSelectedModels(_ health: ServiceHealth) {
        guard let pending = pendingModelSelection, !modelConfigurationActive, !configuringModels else { return }
        let expectedASR = pending.asr == "whisper" ? "whisper-large-v3-turbo" : "Qwen3-ASR-1.7B-8bit"
        let expectedCleanup = pending.cleanup == "cleanup-9b" ? "Qwen3.5-9B-4bit" : "Qwen3.5-4B-4bit"
        guard health.models?["asr"] == expectedASR && health.models?["cleanup"] == expectedCleanup else {
            serviceCanRecord = false
            if modelSelectionTimedOut { asrReadiness = .unavailable; cleanupReadiness = .unavailable }
            else { scheduleHealthRefresh(after: 1) }
            return
        }
        if health.asr_ready && health.cleanup_ready {
            pendingModelSelection = nil; modelSelectionTimedOut = false; modelSelectionGeneration = UUID()
            modelConfigurationMessage = nil
        } else if health.status != "loading" {
            pendingModelSelection = nil; modelSelectionTimedOut = false; modelSelectionGeneration = UUID()
            modelConfigurationMessage = "所选模型未能加载，请检查配置或切换其他模型。"
        }
    }

    private func prepareModelDownload(_ completion: @escaping (Bool) -> Void) {
        guard !terminating, !hasPendingWork, !configuringModels else { completion(false); return }
        // A ready service without an owned Process belongs to another launcher.
        // Do not replace its model files or send signals to it.
        guard ownedBackend != nil || !serviceResponded else { completion(false); return }
        configuringModels = true; serviceCanRecord = false
        asrReadiness = .loading; cleanupReadiness = .loading
        invalidateHealthCallbacks(); cancelPendingBackendLaunch()
        serviceText = "正在配置模型…"; updateUI()
        guard let child = ownedBackend, child.isRunning else {
            ownedBackend = nil
            // Recheck the live port: an external launcher may have appeared
            // since the last health snapshot. A timeout is not proof of absence.
            var probe = URLRequest(url: serviceBase.appendingPathComponent("health")); probe.timeoutInterval = 3
            serviceSession.dataTask(with: probe) { [weak self] _, _, error in
                DispatchQueue.main.async {
                    guard let self else { completion(false); return }
                    let absent = (error as NSError?)?.code == NSURLErrorCannotConnectToHost
                    let allowed = absent && !self.terminating && !self.hasPendingWork
                    if !allowed { self.configuringModels = false; if !self.terminating { self.checkHealth() } }
                    completion(allowed)
                }
            }.resume()
            return
        }
        child.terminationHandler = nil; child.terminate()
        let deadline = Date().addingTimeInterval(5)
        func awaitExit() {
            if !child.isRunning {
                self.ownedBackend = nil; self.closeBackendLog(); completion(!self.terminating)
            } else if self.terminating || Date() >= deadline {
                self.configuringModels = false
                child.terminationHandler = { [weak self] child in DispatchQueue.main.async { self?.handleBackendTermination(child) } }
                completion(false)
                if !self.terminating { self.checkHealth() }
            } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: awaitExit) }
        }
        awaitExit()
    }

    private func closeBackendLog() {
        guard let handle = backendLog else { return }
        backendLog = nil
        backendIO.async { try? handle.close() }
    }

    private func cancelPendingBackendLaunch() {
        backendLaunching = false
        backendLaunchID = nil
    }

    private func recordBackendLifecycle(event: String, pid: pid_t?, reason: String?, code: Int32?) {
        // Fixture children must not appear as real backend launches in the
        // user's diagnostics; native self-tests and previews are isolated.
        guard !CommandLine.arguments.contains("--self-test"), !CommandLine.arguments.contains("--render-preview") else { return }
        // Process identity and exit metadata only: no audio, transcript,
        // clipboard data, environment, or exception payload enters this log.
        var record: [String: Any] = ["time": ISO8601DateFormatter().string(from: Date()),
                                   "event": event, "app_pid": ProcessInfo.processInfo.processIdentifier]
        if let pid { record["backend_pid"] = pid }
        if let reason { record["exit_reason"] = reason }
        if let code { record["exit_code"] = code }
        let directory = diagnosticDirectory
        let immutableRecord = record
        // File access can wait for OS authorization. Never let diagnostics or
        // log preparation hold the UI or become a prerequisite for recovery.
        backendIO.async {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let url = directory.appendingPathComponent("local-dictation-lifecycle.jsonl")
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                var data = try JSONSerialization.data(withJSONObject: immutableRecord, options: [.sortedKeys])
                data.append(0x0A)
                try handle.write(contentsOf: data)
            } catch {
                // Diagnostic write failures must not prevent state recovery.
            }
        }
    }

    private func handleBackendTermination(_ child: Process) {
        guard !terminating, ownedBackend === child else { return }
        if reprocessGeneration != nil {
            reprocessGeneration = nil; reprocessTask?.cancel(); reprocessTask = nil
            reprocessError = "本地服务已中断，原记录和已有版本仍保留。请稍后重试。"
            updateReprocessUI()
        }
        let reason = child.terminationReason == .uncaughtSignal ? "signal" : "exit"
        recordBackendLifecycle(event: "backend_exit", pid: child.processIdentifier, reason: reason, code: child.terminationStatus)
        // Reject queued successes from the old service before releasing its
        // process. Recovery never replays audio or re-arms a previous insertion.
        invalidateHealthCallbacks()
        invalidatePromptCallbacks()
        child.terminationHandler = nil
        ownedBackend = nil
        closeBackendLog()
        serviceCanRecord = false
        asrReadiness = .unavailable; cleanupReadiness = .unavailable
        cleanupBackend = nil
        target = nil
        targetChanged = true
        let interrupted = phase.busy
        recoveryInterruptedUtterance = interrupted
        let delay = recoveryBudget.nextDelay(now: ProcessInfo.processInfo.systemUptime)
        serviceText = delay.map { "本地服务已停止，\(Int($0)) 秒后尝试恢复…" }
            ?? "本地服务连续停止，已暂停自动恢复。请点击“检查服务”重试。"
        fail(interrupted ? "本地服务意外停止，本次口述已中止。已有结果仍可复制。"
                         : "本地服务意外停止，已有结果仍可查看和复制。")
        if let delay { scheduleHealthRefresh(after: delay) }
    }

    private func startBackend() {
        guard !terminating, !configuringModels, ownedBackend == nil, !backendLaunching, !recoveryBudget.isPaused else { return }
        let id = UUID()
        backendLaunching = true; backendLaunchID = id
        serviceCanRecord = false
        asrReadiness = .loading; cleanupReadiness = .loading
        cleanupBackend = nil
        serviceText = "正在准备本地服务…"
        updateUI()
        let runtime = runtimeDirectory
        let python = bundledPython
        let script = python == nil ? runtime.appendingPathComponent("backend/start.sh")
            : Bundle.main.resourceURL!.appendingPathComponent("backend/start.sh")
        let logDirectory = diagnosticDirectory
        let io = backendIO
        // The distributed app owns its interpreter and backend. Models and
        // saved data remain independent of app upgrades in Application Support.
        // Preparation has its own worker so a delayed diagnostic write cannot
        // queue ahead of service availability or a later recovery attempt.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var available = FileManager.default.fileExists(atPath: script.path)
            if python != nil {
                let saved = (try? String(contentsOf: runtime.appendingPathComponent("asr-backend")))?.trimmingCharacters(in: .whitespacesAndNewlines)
                let asrName = saved == "whisper" ? "whisper-large-v3-turbo" : "Qwen3-ASR-1.7B-8bit"
                // A fast first-run gate, not a substitute for the full hash
                // validation in configuration checks and the downloader.
                // Keep ASR available when only cleanup assets need repair.
                for name in [asrName] {
                    let model = runtime.appendingPathComponent("models/" + name)
                    let files = (try? FileManager.default.contentsOfDirectory(atPath: model.path)) ?? []
                    available = available && files.contains("config.json") && files.contains { $0.hasSuffix(".safetensors") || $0 == "weights.npz" }
                }
            }
            var log: FileHandle?
            if available {
                // Even an unexpectedly stalled log open must not delay service
                // availability. A late handle is discarded by the launch ID.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.completeBackendLaunch(id: id, runtime: runtime, script: script, available: true, log: nil)
                }
                do {
                    try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true,
                                                            attributes: [.posixPermissions: 0o700])
                    let url = logDirectory.appendingPathComponent("local-dictation-backend.log")
                    if !FileManager.default.fileExists(atPath: url.path) {
                        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
                    }
                    let opened = try FileHandle(forWritingTo: url)
                    do { try opened.seekToEnd(); log = opened }
                    catch { try? opened.close() }
                } catch {
                    // Logging is optional. The service can run with /dev/null
                    // even when its diagnostic directory cannot be written.
                }
            }
            let preparedLog = log
            DispatchQueue.main.async {
                guard let self else { if let preparedLog { io.async { try? preparedLog.close() } }; return }
                self.completeBackendLaunch(id: id, runtime: runtime, script: script,
                                           available: available, log: preparedLog)
            }
        }
    }

    private func completeBackendLaunch(id: UUID, runtime: URL, script: URL, available: Bool, log: FileHandle?) {
        // A reply that discovered an existing service, or application exit,
        // invalidates this preparation. It must never launch a stale child.
        guard !terminating, !configuringModels, backendLaunching, backendLaunchID == id, ownedBackend == nil, !recoveryBudget.isPaused else {
            if let log { backendIO.async { try? log.close() } }
            return
        }
        cancelPendingBackendLaunch()
        guard available else {
            if let log { backendIO.async { try? log.close() } }
            asrReadiness = .unavailable; cleanupReadiness = .unavailable
            serviceText = "首次使用需要准备模型，请打开“模型与配置”。"
            updateUI()
            if bundledPython != nil && setupController == nil { showSetup() }
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        process.currentDirectoryURL = runtime
        var environment = ProcessInfo.processInfo.environment
        // The app's model picker owns the saved runtime selection. A shell or
        // login environment must not silently override it on the next launch.
        // Direct CLI launches may still use start.sh's explicit override.
        environment.removeValue(forKey: "LOCAL_DICTATION_CLEANUP_MODEL")
        environment.removeValue(forKey: "LOCAL_DICTATION_ASR_BACKEND")
        environment["LOCAL_DICTATION_WORK_DIR"] = runtime.path
        if let python = bundledPython {
            environment["LOCAL_DICTATION_PYTHON"] = python.path
            environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
            if !FileManager.default.fileExists(atPath: runtime.appendingPathComponent("asr-backend").path) {
                environment["LOCAL_DICTATION_ASR_BACKEND"] = "qwen"
            }
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log ?? FileHandle.nullDevice
        process.standardError = log ?? FileHandle.nullDevice
        process.terminationHandler = { [weak self] child in
            DispatchQueue.main.async { self?.handleBackendTermination(child) }
        }
        do {
            invalidateHealthCallbacks()
            invalidatePromptCallbacks()
            try process.run()
            ownedBackend = process
            backendLog = log
            recordBackendLifecycle(event: "backend_started", pid: process.processIdentifier, reason: nil, code: nil)
            serviceText = "正在启动本地服务并加载模型…"
            serviceCanRecord = false
            updateUI()
            scheduleHealthRefresh(after: 1)
        } catch {
            process.terminationHandler = nil
            if let log { backendIO.async { try? log.close() } }
            recordBackendLifecycle(event: "backend_launch_failed", pid: nil, reason: "launch_error", code: nil)
            serviceCanRecord = false
            asrReadiness = .unavailable; cleanupReadiness = .unavailable
            serviceText = "无法启动本地服务，请检查安装是否完成后重试。"
            updateUI()
        }
    }

    private func refreshHealth() {
        guard !terminating, !configuringModels else { return }
        invalidateHealthCallbacks()
        let generation = healthGeneration
        serviceCanRecord = false
        serviceText = "正在检查本地服务…"
        updateUI()
        var health = URLRequest(url: serviceBase.appendingPathComponent("health"))
        health.timeoutInterval = 5
        healthRequest = serviceSession.dataTask(with: health) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.receiveHealthReply(generation: generation, data: data, response: response, error: error)
            }
        }
        healthRequest?.resume()
    }

    private func receiveHealthReply(generation: UUID, data: Data?, response: URLResponse?, error: Error?) {
        guard !terminating, healthGeneration == generation else { return }
        if (error as NSError?)?.code == NSURLErrorCancelled { return }
        healthRequest = nil
        cleanupBackend = nil
        if error == nil, let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
           let data, let health = try? JSONDecoder().decode(ServiceHealth.self, from: data), health.service == "local-dictation" {
            serviceResponded = true
            cancelPendingBackendLaunch()
            serviceCanRecord = health.permitsRecording
            asrReadiness = health.asrReadiness; cleanupReadiness = health.cleanupReadiness
            asrModel = health.models?["asr"]; cleanupModel = health.models?["cleanup"]
            cleanupBackend = health.cleanupBackend
            supportsPromptVersions = health.supports_prompt_versions == true
            supportsStreaming = health.supports_streaming == true
            supportsReprocess = health.supports_reprocess == true
            if supportsPromptVersions && (!promptCatalogCurrent || promptCatalog?.active_version_id != health.active_prompt_version_id) {
                promptCatalogCurrent = false
                loadPrompts()
            }
            switch health.status {
            case "ready": serviceText = health.readyMessage
            case "degraded": serviceText = "本地识别已就绪，文字整理暂不可用；会保留原始转写。"
            case "loading": serviceText = "正在准备本地模型…"
            default: serviceText = "本地服务需要检查：" + health.message
            }
            if health.busy { serviceText = health.permitsRecording ? "后台正在处理，可以继续口述。" : "本地服务正在处理，请稍候。" }
            if health.supports_options != true { serviceText = "本地服务版本较旧，需更新服务后才能使用词典与整理设置。" }
            if serviceCanRecord, let interrupted = recoveryInterruptedUtterance {
                recoveryInterruptedUtterance = nil
                if phase == .failed {
                    phase = .idle
                    statusText = interrupted ? "服务已恢复，上次口述已中止，请重新录音。"
                        : "服务已恢复 · \(shortcutPrompt)"
                }
            }
            if health.status == "loading" || health.busy { scheduleHealthRefresh(after: 4) }
            receiveSelectedModels(health)
        } else if response != nil {
            asrReadiness = .unavailable; cleanupReadiness = .unavailable
            serviceResponded = true
            cancelPendingBackendLaunch()
            serviceCanRecord = false
            serviceText = "本地服务端口已被其他程序占用，或服务协议不匹配。未改动该程序。"
        } else if (error as NSError?)?.code == NSURLErrorCannotConnectToHost {
            asrReadiness = .unavailable; cleanupReadiness = .unavailable
            serviceResponded = false
            invalidatePromptCallbacks()
            serviceCanRecord = false
            if recoveryBudget.isPaused {
                serviceText = "自动恢复已暂停。请点击“检查服务”重试。"
            } else if backendLaunching {
                asrReadiness = .loading; cleanupReadiness = .loading
                serviceText = "正在准备本地服务，请稍候…"
                scheduleHealthRefresh(after: 2)
            } else if ownedBackend == nil { startBackend() }
            else if let ownedBackend, !ownedBackend.isRunning { handleBackendTermination(ownedBackend) }
            else {
                asrReadiness = .loading; cleanupReadiness = .loading
                serviceText = "正在启动本地服务并加载模型…"
                scheduleHealthRefresh(after: 2)
            }
        } else {
            cancelPendingBackendLaunch()
            serviceCanRecord = false
            asrReadiness = .unavailable; cleanupReadiness = .unavailable
            serviceText = "本地服务暂未响应。点击“检查服务”可重试。"
        }
        // Model availability changes independently of the selected Prompt.
        // Refresh both the rule page and an open history retry sheet even when
        // the immutable version ID has stayed the same throughout startup.
        updatePromptUI()
        updateUI()
    }

    static func verifyHistoryReprocessing() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("local.dictation.history-reprocess.\(UUID())"))
        defer { board.releaseGlobally() }
        board.setString("unchanged clipboard", forType: .string)
        let controller = AppDelegate(inserter: TextInserter(board: board, permissionCheck: { nil },
            pasteKeySender: { _ in preconditionFailure("History reprocessing must never paste") }))
        controller.supportsStreaming = true; controller.serviceCanRecord = true
        let entry = controller.store.add(rawText: "嗯，原文。", text: "原输出。", asrSeconds: 1,
            cleanupSeconds: 1, totalSeconds: 2, audioSeconds: 8, cleanupApplied: true, warning: nil)
        let profile = DictationCleanupProfile(versionID: "chosen", name: "另一版", contentSHA256: "chosen-hash", modelID: "fixture")
        let value = HistoryReprocessResult(raw_text: entry.rawText, text: "新版本。", cleanup_seconds: 0.3,
            cleanup_applied: true, warning: nil, cleanup_profile: profile)
        let originalCount = controller.store.usageSummary().dictationCount
        func prepare() -> UUID {
            let generation = UUID(); controller.reprocessGeneration = generation; controller.reprocessEntryID = entry.id
            return generation
        }
        let first = prepare()
        precondition(controller.hasPendingWork && controller.canBeginRecording,
                     "Historical cleanup must block model reconfiguration, not the next streaming microphone session")
        controller.receiveReprocessedHistory(.success(value), entryID: entry.id, generation: first,
            expectedVersionID: "chosen", expectedHash: "chosen-hash")
        precondition(controller.store.entries.count == 1 && controller.store.entries[0].text == "原输出。" &&
            controller.store.entries[0].rawText == entry.rawText && controller.store.entries[0].revisions?.count == 1)
        precondition(controller.store.usageSummary().dictationCount == originalCount)
        controller.receiveReprocessedHistory(.success(value), entryID: entry.id, generation: first,
            expectedVersionID: "chosen", expectedHash: "chosen-hash")
        precondition(controller.store.entries[0].revisions?.count == 1)
        let wrong = prepare()
        controller.receiveReprocessedHistory(.success(value), entryID: entry.id, generation: wrong,
            expectedVersionID: "chosen", expectedHash: "different-hash")
        precondition(controller.reprocessError != nil && controller.store.entries[0].revisions?.count == 1)
        let failed = prepare()
        controller.receiveReprocessedHistory(.failure(URLError(.timedOut)), entryID: entry.id, generation: failed,
            expectedVersionID: "chosen", expectedHash: "chosen-hash")
        precondition(controller.reprocessError != nil && controller.store.entries[0].revisions?.count == 1)
        let deleted = prepare(); controller.store.delete(id: entry.id)
        controller.receiveReprocessedHistory(.success(value), entryID: entry.id, generation: deleted,
            expectedVersionID: "chosen", expectedHash: "chosen-hash")
        precondition(controller.store.entries.isEmpty && controller.reprocessError != nil)
        precondition(board.string(forType: .string) == "unchanged clipboard")
        // Exercise the actual completion HUD -> text-only HTTP -> revision
        // path. A named pasteboard and URLProtocol make insertion/model access
        // impossible, including when retries return unchanged or fail again.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NativeFailureURLProtocol.self]
        let transport = URLSession(configuration: config)
        defer { transport.invalidateAndCancel() }
        let retrying = AppDelegate(serviceSession: transport,
            inserter: TextInserter(board: board, permissionCheck: { nil },
                pasteKeySender: { _ in preconditionFailure("HUD retry must not auto-paste") }))
        retrying.supportsReprocess = true; retrying.serviceCanRecord = true; retrying.cleanupBackend = .local
        let version = CleanupPromptVersion(id: "chosen", name: "测试", note: "", created_at: "fixture", model_id: "fixture",
            system_prompt: "fixture", user_prefix: "", examples: [], content_sha256: "chosen-hash", origin: "user")
        retrying.promptCatalog = CleanupPromptCatalog(active_version_id: "chosen", versions: [version],
            current_model: CleanupPromptModel(id: "fixture", kind: "local", ready: true), asr_model: "fixture")
        retrying.promptCatalogCurrent = true
        let source = retrying.store.add(rawText: "嗯，保留原文。", text: "嗯，保留原文。", asrSeconds: 1,
            cleanupSeconds: 0, totalSeconds: 1, audioSeconds: 8, cleanupApplied: false, warning: "整理未完成",
            cleanupOutcome: DictationCleanupOutcome(status: "failed", reason: "invalid_model_output"))
        let panel = DictationHUD()
        defer { panel.hide() }
        retrying.configureResultHUD(panel, entryID: source.id, message: "整理未完成，已保留原文",
            text: source.text, attention: "整理未完成，已保留原文")
        func field<T>(_ value: Any, _ name: String, _: T.Type) -> T? {
            Mirror(reflecting: value).children.first { $0.label == name }?.value as? T
        }
        let retryButton = field(panel, "retryButton", NSButton.self)!
        let status = field(panel, "deliveryMessage", NSTextField.self)!
        let attemptsBefore = retrying.store.usageSummary().dictationCount
        for outcome in ["unchanged", "suspected_insufficient", "failed", "applied"] {
            let reply: [String: Any] = ["raw_text": source.rawText, "text": outcome == "unchanged" ? source.rawText : "保留原文。",
                "cleanup_seconds": 0.1, "cleanup_applied": outcome != "failed",
                "cleanup_profile": ["version_id": "chosen", "name": "测试", "content_sha256": "chosen-hash", "model_id": "fixture"],
                "cleanup_outcome": ["status": outcome, "reason": "fixture"]]
            NativeFailureURLProtocol.configureCleanup(try JSONSerialization.data(withJSONObject: reply))
            let revisionsBefore = retrying.store.entries[0].revisions?.count ?? 0
            retryButton.performClick(nil); retryButton.performClick(nil)
            precondition(retrying.reprocessGeneration != nil && !retryButton.isEnabled, "Retry failed to start for \(outcome): \(status.stringValue)")
            precondition(status.stringValue == "正在重新整理")
            let deadline = Date().addingTimeInterval(2)
            while retrying.reprocessGeneration != nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            precondition(retrying.reprocessGeneration == nil)
            precondition(NativeFailureURLProtocol.recordedPaths() == ["/cleanup/reprocess"])
            precondition(NativeFailureURLProtocol.recordedPromptHeaders() == ["chosen"])
            let saved = retrying.store.entries[0]
            precondition(saved.rawText == source.rawText && saved.text == source.text && saved.cleanupOutcome == source.cleanupOutcome)
            precondition(retrying.store.usageSummary().dictationCount == attemptsBefore)
            precondition(board.string(forType: .string) == "unchanged clipboard")
            if outcome == "failed" {
                precondition((saved.revisions?.count ?? 0) == revisionsBefore && status.stringValue.contains("重新整理未完成") && retryButton.isEnabled)
            } else {
                precondition(saved.revisions?.count == revisionsBefore + 1 && saved.revisions?.last?.cleanupOutcome?.status == outcome)
                precondition(panel.onViewResult != nil && panel.onCopy != nil)
                if outcome == "applied" { precondition(panel.onRetryCleanup == nil && status.stringValue == "新版本已保存") }
                else { precondition(status.stringValue.contains(DictationCleanupOutcome(status: outcome).attentionMessage!) && retryButton.isEnabled) }
            }
        }
        panel.onCopy?()
        precondition(board.string(forType: .string) == "保留原文。", "New version only reaches clipboard through explicit Copy")
        for reuseForRecording in [false, true] {
            retrying.configureResultHUD(panel, entryID: source.id, message: "原文未改", text: source.text, attention: "原文未改")
            let beforeDismissedRetry = retrying.store.entries[0].revisions?.count ?? 0
            retryButton.performClick(nil)
            precondition(retrying.reprocessGeneration != nil)
            if reuseForRecording {
                var recordingState = DictationUIState(); recordingState.recording = true
                panel.update(recordingState, show: false)
            } else { panel.hide() }
            let dismissedDeadline = Date().addingTimeInterval(2)
            while retrying.reprocessGeneration != nil && Date() < dismissedDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            precondition(retrying.store.entries[0].revisions?.count == beforeDismissedRetry + 1 && retrying.reprocessHUD == nil)
            precondition(!panel.isVisible && status.stringValue == "正在重新整理", "Dismissed retry unexpectedly re-presented its completion")
            if reuseForRecording { precondition(field(panel, "recordingRow", NSView.self)?.isHidden == false) }
        }
        var failedWrites = 0
        let copyFailure = AppDelegate(inserter: TextInserter(board: board, writeClipboard: { _ in failedWrites += 1; return false },
            permissionCheck: { nil }, pasteKeySender: { _ in preconditionFailure("Failed copy must not paste") }))
        let copyFailurePanel = DictationHUD()
        defer { copyFailurePanel.hide() }
        copyFailure.configureResultHUD(copyFailurePanel, entryID: nil, message: "原文未改", text: "copy-failure", attention: "原文未改")
        let beforeCopyFailure = board.string(forType: .string)
        copyFailurePanel.onCopy?()
        precondition(failedWrites == 1 && board.string(forType: .string) == beforeCopyFailure)
        precondition(field(copyFailurePanel, "deliveryMessage", NSTextField.self)?.stringValue == "原文未改 · 复制失败 · 文字已保留",
                     "Attention copy replaced clipboard failure with a false success")
        print("PASS cleanup HUD retry: real one text-only request per click, duplicate lock, failed retry retained, outcome-aware revisions, explicit copy only, original ASR/output and usage unchanged")
        print("PASS history reprocessing integration: immutable originals, explicit version/hash, persistent revision only, no extra usage, deleted/duplicate/error isolation, recording remains available, no clipboard or paste side effect")
    }

    static func verifyStreamingQueue() throws {
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw NSError(domain: "StreamingQueueSelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NativeFailureURLProtocol.self]
        let transport = URLSession(configuration: configuration)
        defer { transport.invalidateAndCancel() }
        let board = NSPasteboard(name: NSPasteboard.Name("local.dictation.queue-test.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let controller = AppDelegate(serviceSession: transport,
            inserter: TextInserter(board: board, permissionCheck: { "fixture permission denied" }))
        controller.supportsStreaming = true; controller.serviceCanRecord = true
        func job(_ number: Int) -> StreamingUtterance {
            var preferences = DictationPreferences(); preferences.autoInsertEnabled = false
            preferences.vocabulary = ["term-\(number)"]
            let id = UUID()
            let client = StreamingDictationClient(baseURL: serviceBase, session: transport,
                optionsHeader: "e30=", promptVersionID: "rule-\(number)", sessionID: id)
            let job = StreamingUtterance(id: id, number: number, preferences: preferences, promptWarning: nil,
                audioURL: FileManager.default.temporaryDirectory.appendingPathComponent("absent-fixture-\(id).wav"),
                client: client)
            job.stoppedAt = Date(); return job
        }
        func result(_ text: String, outcome: String? = nil) throws -> Data {
            var object: [String: Any] = ["raw_text": outcome == "unchanged" ? text : "raw-" + text, "text": text,
                "asr_seconds": 2.0, "cleanup_seconds": 1.0, "total_seconds": 3.0,
                "audio_seconds": 50.0, "cleanup_applied": !["failed", "skipped"].contains(outcome ?? ""), "asr_model": "fixture-asr",
                "streaming_metrics": ["processed_audio_before_stop_seconds": 30.0,
                    "asr_before_stop_seconds": 1.2, "asr_after_stop_seconds": 0.8,
                    "stop_to_result_seconds": 1.8, "asr_calls": 2]]
            if let outcome { object["cleanup_outcome"] = ["status": outcome, "reason": "fixture"] }
            return try JSONSerialization.data(withJSONObject: object)
        }
        let response = HTTPURLResponse(url: serviceBase, statusCode: 200, httpVersion: nil, headerFields: nil)!
        func awaitReadyResults(_ controller: AppDelegate) throws {
            let deadline = Date().addingTimeInterval(2)
            while (controller.deliveryInFlight || controller.streamingJobs.contains(where: { $0.result != nil })) && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            try require(!controller.deliveryInFlight && !controller.streamingJobs.contains(where: { $0.result != nil }),
                        "完成展示后没有按时交付结果。")
        }
        let first = job(1), second = job(2)
        controller.streamingJobs = [first, second]; controller.phase = .processing
        try require(controller.displayState.canStart && controller.displayState.pendingCount == 2,
                    "后台整理阻止了下一段录音。")
        controller.sessionID = UUID(); controller.phase = .preparing
        controller.rejectRecordingStart("fixture microphone denied")
        try require(controller.streamingJobs.count == 2 && controller.sessionID == nil && controller.phase == .processing,
                    "新录音准备失败取消了旧段，或遗失忙碌状态。")
        controller.phase = .idle
        var configureAllowed: Bool?
        controller.prepareModelDownload { configureAllowed = $0 }
        try require(configureAllowed == false, "全局界面空闲时忽略了后台会话，错误允许修改模型。")
        controller.phase = .processing
        controller.receiveStreamingResult(id: second.id, data: try result("second"), response: response, error: nil)
        try require(controller.store.entries.isEmpty, "后一段抢先写入或粘贴。")
        controller.receiveStreamingResult(id: first.id, data: try result("first"), response: response, error: nil)
        try require(controller.store.entries.map(\.text) == ["first"] && first.resultReceivedAt != nil &&
                    controller.streamingJobs.first?.id == first.id,
                    "完成展示之前没有先保存结果，或没有保留填满展示。")
        try awaitReadyResults(controller)
        try require(controller.store.entries.map(\.text) == ["second", "first"], "按段顺序交付丢失或重复。")
        try require(board.string(forType: .string) == "second", "最终剪贴板不是后段结果。")
        try require(controller.store.entries.allSatisfy { $0.streamingMetrics?.asrCalls == 2 }, "流式耗时没有保存进历史。")
        controller.receiveStreamingResult(id: first.id, data: try result("duplicate"), response: response, error: nil)
        try require(controller.store.entries.count == 2, "迟到/重复结果再次入库。")

        let third = job(3), fourth = job(4)
        controller.streamingJobs = [third, fourth]; controller.phase = .recording; controller.sessionID = fourth.id
        fourth.stoppedAt = nil
        controller.receiveStreamingResult(id: third.id, data: try result("third"), response: response, error: nil)
        try awaitReadyResults(controller)
        try require(controller.sessionID == fourth.id && controller.phase == .recording && controller.streamingJobs.count == 1,
                    "前段完成中断了后段录音。")
        controller.cancelStreamingJob(fourth.id)
        controller.receiveStreamingResult(id: fourth.id, data: try result("cancelled"), response: response, error: nil)
        try require(controller.store.entries.count == 3, "取消后仍接受迟到结果。")

        // Visible fallback cards belong to the same batch. Once the last
        // card disappears, even the very next start is segment one again.
        controller.utteranceNumber = 4
        try require(controller.nextUtteranceNumber() == 5, "仍有浮条时错误重置了段号。")
        for id in Array(controller.deliveryHUDs.keys) { controller.removeDeliveryHUD(id) }
        controller.deliveryInFlight = true
        try require(controller.nextUtteranceNumber() == 1, "浮条全部消失后没有立即从第一段开始。")
        controller.deliveryInFlight = false
        let continued = job(1)
        controller.streamingJobs = [continued]
        try require(controller.nextUtteranceNumber() == 2, "仍在录音或整理时段号没有递增。")
        controller.streamingJobs.removeAll(); controller.restackStreamingHUDs()
        try require(controller.nextUtteranceNumber() == 1, "取消最后一段后段号没有重置。")

        // Simulate an editor that supports selection and Cmd-V but exposes no
        // AX text value. Each paste reads the latest caret/current editor.
        let element = AXUIElementCreateApplication(-1)
        var currentTarget: FocusTarget? = FocusTarget(pid: -1, element: element, selection: Selection(location: 2, length: 0))
        var pasted: [(pid_t, Int, String, Date)] = []
        let automatic = AppDelegate(serviceSession: transport,
            inserter: TextInserter(board: board, permissionCheck: { nil }, targetReader: { currentTarget }, pasteKeySender: { pid in
                guard let target = currentTarget else { return false }
                let text = board.string(forType: .string) ?? ""
                pasted.append((pid, target.selection.location, text, Date()))
                currentTarget = FocusTarget(pid: target.pid, element: target.element,
                    selection: Selection(location: target.selection.location + text.utf16.count, length: 0))
                return true
            }, foregroundPID: { currentTarget?.pid ?? -1 }))
        automatic.supportsStreaming = true; automatic.serviceCanRecord = true
        func autoJob(_ number: Int) -> StreamingUtterance {
            let source = job(number)
            var preferences = source.preferences; preferences.autoInsertEnabled = true
            return StreamingUtterance(id: source.id, number: number, preferences: preferences, promptWarning: nil,
                audioURL: source.audioURL, client: source.client)
        }
        func awaitDelivery() throws {
            try awaitReadyResults(automatic)
        }
        let a = autoJob(1), b = autoJob(2), c = autoJob(3)
        automatic.streamingJobs = [a, b, c]; automatic.phase = .processing
        automatic.receiveStreamingResult(id: c.id, data: try result("third"), response: response, error: nil)
        automatic.receiveStreamingResult(id: b.id, data: try result("second"), response: response, error: nil)
        automatic.receiveStreamingResult(id: a.id, data: try result("first"), response: response, error: nil)
        try require(pasted.isEmpty, "完成填充还未展示就提前粘贴了结果。")
        try awaitDelivery()
        try require(pasted.map { $0.2 } == ["first", "second", "third"] && pasted.map { $0.1 } == [2, 7, 13],
                    "后续段落没有沿用普通粘贴，或仍依赖旧光标/文本回执。")
        try require(pasted[1].3.timeIntervalSince(pasted[0].3) >= 0.18 && automatic.deliveryHUDs.isEmpty,
                    "连续粘贴没有留出调度间隔，或成功后仍显示复制提示。")
        let d = autoJob(1)
        automatic.streamingJobs = [d]
        currentTarget = FocusTarget(pid: -2, element: AXUIElementCreateApplication(-2), selection: Selection(location: 20, length: 0))
        automatic.receiveStreamingResult(id: d.id, data: try result("new-field"), response: response, error: nil)
        try awaitDelivery()
        try require(pasted.last?.0 == -2 && pasted.last?.1 == 20, "没有使用交付时的当前输入框。")
        let e = autoJob(2)
        automatic.streamingJobs = [e]; currentTarget = nil
        automatic.receiveStreamingResult(id: e.id, data: try result("no-field"), response: response, error: nil)
        try awaitDelivery()
        try require(pasted.count == 4 && board.string(forType: .string) == "no-field" && automatic.deliveryHUDs[e.id] != nil,
                    "没有可填入输入框时，复制提示或结果保留失效。")
        automatic.receiveStreamingResult(id: d.id, data: try result("duplicate"), response: response, error: nil)
        try require(pasted.count == 4 && automatic.store.entries.count == 5, "迟到结果触发了重复粘贴或入库。")
        // A cancelled completion card must invalidate its pending timer too.
        let cancelledCompletion = autoJob(3)
        automatic.streamingJobs = [cancelledCompletion]
        automatic.receiveStreamingResult(id: cancelledCompletion.id, data: try result("cancel-before-paste"), response: response, error: nil)
        automatic.cancelStreamingJob(cancelledCompletion.id)
        RunLoop.current.run(until: Date().addingTimeInterval(0.22))
        try require(pasted.count == 4 && automatic.store.entries.count == 6 &&
                    automatic.store.entries.first?.text == "cancel-before-paste",
                    "完成展示期间取消后仍然粘贴、重复入库，或丢失已保存的结果。")
        let failingCompletion = autoJob(4)
        automatic.streamingJobs = [failingCompletion]; automatic.phase = .processing
        automatic.receiveStreamingResult(id: failingCompletion.id, data: try result("saved-before-fault"), response: response, error: nil)
        automatic.receiveStreamingResult(id: failingCompletion.id, data: try result("duplicate-during-hold"), response: response, error: nil)
        try require(failingCompletion.result?.text == "saved-before-fault" && failingCompletion.completionScheduled,
                    "完成展示期间重复结果覆盖了首次结果。")
        let clipboardBeforeCompletionFault = board.string(forType: .string)
        automatic.fail("fixture failure during completion display")
        RunLoop.current.run(until: Date().addingTimeInterval(0.22))
        try require(automatic.store.entries.count == 7 && automatic.store.entries.first?.text == "saved-before-fault" &&
                    automatic.store.entries.first?.rawText == "raw-saved-before-fault" && pasted.count == 4 &&
                    board.string(forType: .string) == clipboardBeforeCompletionFault && automatic.streamingJobs.isEmpty,
                    "完成展示期间全局故障丢失了结果，或定时器仍触发了粘贴。")
        // Cancellation must also work after the presentation hold, while AX
        // recovery owns the queue head. A late retry cannot dispatch that job.
        for globalFailure in [false, true] {
            let pendingInput = autoJob(globalFailure ? 6 : 5)
            automatic.streamingJobs = [pendingInput]; automatic.phase = .processing; currentTarget = nil
            automatic.receiveStreamingResult(id: pendingInput.id, data: try result("pending-input"), response: response, error: nil)
            pendingInput.completionDeadline = 0
            automatic.drainStreamingResults()
            try require(automatic.preparingDeliveryID == pendingInput.id && automatic.deliveryInFlight &&
                        automatic.streamingJobs.first?.id == pendingInput.id, "输入框恢复期间过早移除了可取消的队首。")
            let beforeRecovery = board.string(forType: .string)
            if globalFailure { automatic.fail("fixture failure during input recovery") }
            else { automatic.cancelStreamingJob(pendingInput.id) }
            currentTarget = FocusTarget(pid: -1, element: element, selection: Selection(location: 0, length: 0))
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            try require(pasted.count == 4 && board.string(forType: .string) == beforeRecovery &&
                        automatic.streamingJobs.isEmpty && !automatic.deliveryInFlight && automatic.preparingDeliveryID == nil,
                        "输入框恢复期间取消或失败后仍粘贴、改写剪贴板或锁住队列。")
        }
        // A successful paste is a delivery fact, not a cleanup-quality fact.
        // Keep actionable outcome cards even after Cmd-V dispatch, without
        // delaying the next segment or changing the original ASR in history.
        for outcome in ["unchanged", "suspected_insufficient", "failed", "skipped", "future_status", "applied"] {
            let next = autoJob(1)
            automatic.streamingJobs = [next]; automatic.phase = .processing
            currentTarget = FocusTarget(pid: -1, element: element, selection: Selection(location: 0, length: 0))
            let pasteCount = pasted.count
            automatic.receiveStreamingResult(id: next.id, data: try result("outcome-" + outcome, outcome: outcome), response: response, error: nil)
            try awaitDelivery()
            try require(pasted.count == pasteCount + 1, "Cleanup feedback blocked the normal one-time insertion")
            let attention = DictationCleanupOutcome(status: outcome).attentionMessage
            let panel = automatic.deliveryHUDs[next.id]
            try require((panel != nil) == (attention != nil), "Paste success hid a cleanup issue or created a false warning for \(outcome)")
            try require(automatic.store.entries.first?.cleanupOutcome?.status == outcome, "History lost cleanup outcome")
            if let panel, let attention {
                try require(panel.onRetryCleanup != nil, "Attention has no text-only retry action")
                panel.onCopy?()
                let message = Mirror(reflecting: panel).children.first { $0.label == "deliveryMessage" }?.value as? NSTextField
                try require(message?.stringValue == attention + " · 已复制 · 按 ⌘V 粘贴", "Copy erased cleanup attention")
                try require(pasted.count == pasteCount + 1, "Explicit Copy unexpectedly pasted a second time")
                automatic.removeDeliveryHUD(next.id)
            }
        }
        automatic.invalidateHealthCallbacks()
        automatic.deliveryHUDs.removeAll(); automatic.deliveryHUDOrder.removeAll()
        let waiting = job(7), complete = job(8)
        controller.streamingJobs = [waiting, complete]; controller.phase = .processing
        controller.receiveStreamingResult(id: complete.id, data: try result("completed-before-fault"), response: response, error: nil)
        let boardBeforeFault = board.string(forType: .string)
        controller.fail("fixture backend terminated")
        try require(controller.store.entries.first?.text == "completed-before-fault" &&
                    controller.store.entries.first?.rawText == "raw-completed-before-fault" &&
                    controller.store.entries.first?.asrModel == "fixture-asr" &&
                    controller.store.entries.first?.streamingMetrics?.asrCalls == 2,
                    "全局故障丢失了已完成但等待交付的原文、整理结果或来源。")
        try require(board.string(forType: .string) == boardBeforeFault && controller.streamingJobs.isEmpty,
                    "服务故障后仍自动修改剪贴板或遗留会话。")
        for partial in ["", "已识别的一部分"] {
            let interrupted = job(1); interrupted.partialText = partial
            controller.streamingJobs = [interrupted]
            let clipboardBefore = board.string(forType: .string)
            controller.failStreamingJob(interrupted.id, message: "fixture transport failure", refresh: false)
            let panel = controller.deliveryHUDs[interrupted.id]!
            try require((panel.onRetryCleanup != nil) == !partial.isEmpty, "Empty ASR offered text retry, or partial ASR lost its retry")
            try require(board.string(forType: .string) == clipboardBefore, "An incomplete ASR result silently changed the clipboard")
            if !partial.isEmpty {
                try require(interrupted.savedEntryID == controller.store.entries.first?.id &&
                            controller.store.entries.first?.rawText == partial &&
                            controller.store.entries.first?.cleanupOutcome?.reason == "incomplete_asr",
                            "Partial result retry lost its source history association")
            }
            controller.removeDeliveryHUD(interrupted.id)
        }
        controller.invalidateHealthCallbacks()
        for panel in controller.deliveryHUDs.values { panel.hide() }
        controller.deliveryHUDs.removeAll(); controller.deliveryHUDOrder.removeAll()
        print("PASS streaming queue: ordered single delivery, recording during edit, per-session failure/cancel, setup guard, persistent timing, batch numbering reset, current-input paste for every segment, no receipt barrier, copy fallback, completion hold with cancellation/failure/duplicate safety")
    }

    static func verifyLateRecoveryCallbacks() {
        let controller = AppDelegate()
        let ready = Data("""
        {"service":"local-dictation","status":"ready","ready":true,"asr_ready":true,"cleanup_ready":true,"busy":false,"message":"ready","supports_options":true}
        """.utf8)
        let response = HTTPURLResponse(url: serviceBase, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let oldGeneration = controller.healthGeneration
        controller.receiveHealthReply(generation: oldGeneration, data: ready, response: response, error: nil)
        precondition(controller.serviceCanRecord)
        controller.invalidateHealthCallbacks()
        controller.serviceCanRecord = false
        controller.serviceText = "recovering-fixture"
        controller.phase = .failed
        controller.recoveryInterruptedUtterance = true
        controller.receiveHealthReply(generation: oldGeneration, data: ready, response: response, error: nil)
        precondition(!controller.serviceCanRecord && controller.serviceText == "recovering-fixture")
        precondition(controller.recoveryInterruptedUtterance == true)
        controller.receiveHealthReply(generation: controller.healthGeneration, data: ready, response: response, error: nil)
        precondition(controller.serviceCanRecord && controller.phase == .idle)
        precondition(controller.recoveryInterruptedUtterance == nil && controller.statusText.contains("请重新录音"))
        controller.serviceCanRecord = false

        let preparation = UUID()
        controller.backendLaunching = true; controller.backendLaunchID = preparation
        controller.startBackend()
        precondition(controller.backendLaunchID == preparation)
        controller.receiveHealthReply(generation: controller.healthGeneration, data: ready, response: response, error: nil)
        precondition(!controller.backendLaunching && controller.backendLaunchID == nil)
        // A service discovered during log preparation wins. A delayed file-open
        // callback must not launch another process or replace that ready state.
        controller.completeBackendLaunch(id: preparation, runtime: controller.runtimeDirectory,
            script: controller.runtimeDirectory.appendingPathComponent("backend/start.sh"), available: true, log: nil)
        precondition(controller.ownedBackend == nil && controller.serviceCanRecord)
        precondition(!controller.runtimeDirectory.path.contains("/Documents/"))
        precondition(!controller.diagnosticDirectory.path.contains("/Documents/"))
        controller.serviceCanRecord = false

        // These Process objects are never launched. A superseded child's callback
        // must be rejected before inspecting its termination status or doing IO.
        let oldChild = Process(), currentChild = Process()
        controller.ownedBackend = currentChild
        controller.handleBackendTermination(oldChild)
        precondition(controller.ownedBackend === currentChild && !controller.serviceCanRecord)
        controller.terminating = true
        controller.backendLaunching = true; controller.backendLaunchID = preparation
        controller.completeBackendLaunch(id: preparation, runtime: controller.runtimeDirectory,
            script: controller.runtimeDirectory.appendingPathComponent("backend/start.sh"), available: true, log: nil)
        controller.handleBackendTermination(currentChild)
        controller.receiveHealthReply(generation: controller.healthGeneration, data: ready, response: response, error: nil)
        precondition(controller.ownedBackend === currentChild && !controller.serviceCanRecord)
    }

    static func verifyModelHealthTransitions() {
        let controller = AppDelegate()
        let response = HTTPURLResponse(url: serviceBase, statusCode: 200, httpVersion: nil, headerFields: nil)!
        func reply(status: String, asr: Bool, cleanup: Bool) {
            let data = Data("""
            {"service":"local-dictation","status":"\(status)","ready":\(asr),"asr_ready":\(asr),"cleanup_ready":\(cleanup),"busy":false,"message":"fixture","supports_options":true,"models":{"asr":"fixture-asr","cleanup":"fixture-cleanup"}}
            """.utf8)
            controller.receiveHealthReply(generation: controller.healthGeneration, data: data, response: response, error: nil)
        }
        func assertStates(_ asr: DictationModelReadiness, _ cleanup: DictationModelReadiness) {
            precondition(controller.displayState.asrReadiness == asr && controller.displayState.cleanupReadiness == cleanup)
        }
        reply(status: "ready", asr: true, cleanup: true)
        assertStates(.ready, .ready)
        precondition(controller.displayState.asrModel == "fixture-asr" && controller.displayState.cleanupModel == "fixture-cleanup")
        reply(status: "loading", asr: false, cleanup: false)
        assertStates(.loading, .loading)
        controller.invalidateHealthCallbacks() // Keep the fixture off the real loopback service.
        reply(status: "error", asr: false, cleanup: false)
        assertStates(.unavailable, .unavailable)
        reply(status: "degraded", asr: true, cleanup: false)
        assertStates(.ready, .unavailable)
        precondition(controller.serviceCanRecord)
        reply(status: "ready", asr: true, cleanup: true)
        controller.receiveHealthReply(generation: controller.healthGeneration, data: nil, response: nil,
                                      error: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        assertStates(.unavailable, .unavailable)
        precondition(!controller.serviceCanRecord)
        // A failed connection may normally start recovery. Pause only this
        // in-memory fixture so no child process or model is reached by the test.
        _ = controller.recoveryBudget.nextDelay(now: 1)
        _ = controller.recoveryBudget.nextDelay(now: 2)
        _ = controller.recoveryBudget.nextDelay(now: 3)
        precondition(controller.recoveryBudget.isPaused)
        reply(status: "ready", asr: true, cleanup: true)
        let obsolete = controller.healthGeneration
        controller.invalidateHealthCallbacks()
        controller.receiveHealthReply(generation: controller.healthGeneration, data: nil, response: nil,
                                      error: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost))
        assertStates(.unavailable, .unavailable)
        let stale = Data("""
        {"service":"local-dictation","status":"ready","ready":true,"asr_ready":true,"cleanup_ready":true,"busy":false,"message":"stale","supports_options":true}
        """.utf8)
        controller.receiveHealthReply(generation: obsolete, data: stale, response: response, error: nil)
        assertStates(.unavailable, .unavailable)
        reply(status: "ready", asr: true, cleanup: true)
        assertStates(.ready, .ready)
        // A save/check result and a stale ready service must not complete the
        // home switch. The selected model names and both load flags must agree.
        controller.pendingModelSelection = ("qwen", "cleanup-9b")
        controller.selectedCleanupModelID = "cleanup-9b"
        reply(status: "ready", asr: true, cleanup: true)
        precondition(controller.displayState.asrReadiness == .loading && controller.displayState.cleanupReadiness == .loading)
        precondition(!controller.displayState.canSwitchModels && !controller.canBeginRecording)
        controller.invalidateHealthCallbacks()
        controller.expireModelSelection(generation: controller.modelSelectionGeneration)
        precondition(controller.pendingModelSelection != nil && controller.displayState.canSwitchModels && !controller.canBeginRecording)
        assertStates(.unavailable, .unavailable)
        reply(status: "ready", asr: true, cleanup: true)
        precondition(!controller.canBeginRecording && controller.modelConfigurationMessage != nil)
        assertStates(.unavailable, .unavailable)
        let unresolved = controller.pendingModelSelection
        controller.pendingModelSelection = ("whisper", "cleanup")
        controller.modelSelectionTimedOut = false
        controller.restoreModelSelectionAfterFailure(previous: unresolved, timedOut: true, message: "fixture rejected retry")
        reply(status: "ready", asr: true, cleanup: true)
        precondition(controller.pendingModelSelection?.cleanup == "cleanup-9b" && !controller.canBeginRecording)
        assertStates(.unavailable, .unavailable)
        reply(status: "loading", asr: false, cleanup: false)
        assertStates(.unavailable, .unavailable)
        controller.invalidateHealthCallbacks()
        let selected = Data("""
        {"service":"local-dictation","status":"ready","ready":true,"asr_ready":true,"cleanup_ready":true,"busy":false,"message":"fixture","supports_options":true,"models":{"asr":"Qwen3-ASR-1.7B-8bit","cleanup":"Qwen3.5-9B-4bit"}}
        """.utf8)
        controller.receiveHealthReply(generation: controller.healthGeneration, data: selected, response: response, error: nil)
        precondition(controller.pendingModelSelection == nil && controller.displayState.canSwitchModels && controller.canBeginRecording)
        precondition(controller.modelConfigurationMessage == nil && !controller.modelSelectionTimedOut)
        assertStates(.ready, .ready)
        controller.modelConfigurationActive = true
        precondition(!controller.displayState.canSwitchModels && !controller.canBeginRecording)
        assertStates(.loading, .loading)
        controller.modelConfigurationActive = false
        controller.pendingModelSelection = ("qwen", "cleanup-9b")
        let failedModel = Data("""
        {"service":"local-dictation","status":"degraded","ready":true,"asr_ready":true,"cleanup_ready":false,"busy":false,"message":"fixture","supports_options":true,"models":{"asr":"Qwen3-ASR-1.7B-8bit","cleanup":"Qwen3.5-9B-4bit"}}
        """.utf8)
        controller.receiveHealthReply(generation: controller.healthGeneration, data: failedModel, response: response, error: nil)
        precondition(controller.pendingModelSelection == nil && controller.modelConfigurationMessage != nil)
        assertStates(.ready, .unavailable)
        controller.terminating = true; controller.invalidateHealthCallbacks()
        precondition(controller.ownedBackend == nil && !controller.backendLaunching && controller.healthRequest == nil)
        print("PASS model health lifecycle: pending home switches require matching ready models; configuration blocks recording; load failures stop the spinner; stale replies rejected; recovery restores model identities. No real service contacted.")
    }

    static func verifyConfigurationGuards() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NativeFailureURLProtocol.self]
        NativeFailureURLProtocol.configure(.transport)
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let controller = AppDelegate(serviceSession: session)
        controller.phase = .recording
        var answer: Bool?
        controller.prepareModelDownload { answer = $0 }
        precondition(answer == false && !controller.configuringModels)
        controller.phase = .idle; controller.serviceResponded = true; answer = nil
        controller.prepareModelDownload { answer = $0 }
        precondition(answer == false && !controller.configuringModels)
        // An external endpoint appearing after the snapshot also blocks writes.
        // This ephemeral URLProtocol never reaches a real service.
        controller.serviceResponded = false; answer = nil
        controller.prepareModelDownload { answer = $0 }
        var deadline = Date().addingTimeInterval(3)
        while answer == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        precondition(answer == false && !controller.configuringModels)
        controller.invalidateHealthCallbacks()
        // Only this disposable owned child receives a signal.
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["10"]
        try child.run(); defer { if child.isRunning { child.terminate() } }
        controller.ownedBackend = child; controller.serviceResponded = false; answer = nil
        controller.prepareModelDownload { answer = $0 }
        deadline = Date().addingTimeInterval(6)
        while answer == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        precondition(answer == true && !child.isRunning && controller.ownedBackend == nil && controller.configuringModels)
        let stale = UUID(); controller.backendLaunching = true; controller.backendLaunchID = stale
        controller.completeBackendLaunch(id: stale, runtime: controller.runtimeDirectory,
            script: controller.runtimeDirectory.appendingPathComponent("backend/start.sh"), available: true, log: nil)
        precondition(controller.ownedBackend == nil)
        controller.terminating = true; controller.cancelPendingBackendLaunch(); controller.invalidateHealthCallbacks()

        let runtime = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-model-launch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtime) }
        let selection = runtime.appendingPathComponent("cleanup-model")
        try "cleanup-9b\n".write(to: selection, atomically: true, encoding: .utf8)
        let script = runtime.appendingPathComponent("start.sh")
        try "#!/bin/bash\nexec /bin/sleep 10\n".write(to: script, atomically: true, encoding: .utf8)
        let previousOverride = ProcessInfo.processInfo.environment["LOCAL_DICTATION_CLEANUP_MODEL"]
        setenv("LOCAL_DICTATION_CLEANUP_MODEL", "cleanup", 1)
        defer {
            if let previousOverride { setenv("LOCAL_DICTATION_CLEANUP_MODEL", previousOverride, 1) }
            else { unsetenv("LOCAL_DICTATION_CLEANUP_MODEL") }
        }
        let launcher = AppDelegate(serviceSession: session)
        let launchID = UUID(); launcher.backendLaunching = true; launcher.backendLaunchID = launchID
        launcher.completeBackendLaunch(id: launchID, runtime: runtime, script: script, available: true, log: nil)
        guard let launched = launcher.ownedBackend else { preconditionFailure("Fixture backend did not launch") }
        launcher.terminating = true; launcher.invalidateHealthCallbacks()
        launched.terminationHandler = nil
        defer { if launched.isRunning { launched.terminate(); launched.waitUntilExit() } }
        precondition(launched.environment?["LOCAL_DICTATION_CLEANUP_MODEL"] == nil)
        let retainedSelection = try String(contentsOf: selection, encoding: .utf8)
        precondition(retainedSelection == "cleanup-9b\n")
        print("PASS setup guards: recording, external service, owned child exit, stale launch exclusion, GUI model selection cannot be overridden by inherited environment")
    }

    static func verifyPromptModelReadiness() throws {
        // Exercise the real retained rule page and retry sheet through health
        // callbacks, without reaching local inference or the general clipboard.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NativeFailureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let board = NSPasteboard(name: NSPasteboard.Name("local.dictation.prompt-health.\(UUID())"))
        board.setString("prompt-health clipboard", forType: .string)
        let controller = AppDelegate(serviceSession: session,
            inserter: TextInserter(board: board, permissionCheck: { nil },
                pasteKeySender: { _ in preconditionFailure("Readiness and history retry must not paste") }))
        defer {
            controller.terminating = true; controller.invalidateHealthCallbacks()
            controller.reprocessTask?.cancel(); session.invalidateAndCancel()
            controller.windowController?.window?.close(); board.releaseGlobally()
        }
        func field<T>(_ value: Any, _ name: String, _: T.Type) -> T? {
            Mirror(reflecting: value).children.first { $0.label == name }?.value as? T
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let version = CleanupPromptVersion(id: "same-rule", name: "原始规则", note: "原始备注", created_at: "fixture",
            model_id: "Qwen3.5-9B-4bit", system_prompt: "保留原意。", user_prefix: "原文：",
            examples: [], content_sha256: "same-rule-hash", origin: "user")
        func catalog(ready: Bool) -> CleanupPromptCatalog {
            CleanupPromptCatalog(active_version_id: version.id, versions: [version],
                current_model: CleanupPromptModel(id: "Qwen3.5-9B-4bit", kind: "local", ready: ready),
                asr_model: "Qwen3-ASR-1.7B-8bit")
        }
        let response = HTTPURLResponse(url: serviceBase, statusCode: 200, httpVersion: nil, headerFields: nil)!
        func health(_ status: String, ready: Bool, model: String = "Qwen3.5-9B-4bit") {
            let data = Data("""
            {"service":"local-dictation","status":"\(status)","ready":true,"asr_ready":true,"cleanup_ready":\(ready),"busy":false,"message":"fixture","supports_options":true,"supports_prompt_versions":true,"supports_reprocess":true,"active_prompt_version_id":"same-rule","models":{"asr":"Qwen3-ASR-1.7B-8bit","cleanup":"\(model)"}}
            """.utf8)
            controller.receiveHealthReply(generation: controller.healthGeneration, data: data, response: response, error: nil)
            controller.invalidateHealthCallbacks() // Cancel scheduled polling; every reply here is a fixture.
        }
        NativeFailureURLProtocol.configure(.transport)
        controller.receivePromptCatalog(.success(catalog(ready: false)), generation: controller.promptGeneration)
        let entry = controller.store.add(rawText: "嗯，请保留原意。", text: "嗯，请保留原意。", asrSeconds: 0.1,
            cleanupSeconds: 0, totalSeconds: 0.1, audioSeconds: 2, cleanupApplied: false, warning: nil)
        controller.createWindowIfNeeded()
        let window = controller.windowController!
        window.showPage(.prompts)
        window.showReprocessing(entryID: entry.id, show: false)
        let studio = descendants(window.window!.contentView!).compactMap { $0 as? PromptStudioView }.first!
        let modelLabel = field(studio, "modelLabel", NSTextField.self)!
        let editor = field(studio, "editor", NSTextView.self)!
        let name = field(studio, "nameField", NSTextField.self)!
        let sheet = field(window, "reprocessingSheet", HistoryReprocessingWindowController.self)!
        defer { sheet.window?.close() }
        let run = field(sheet, "runButton", NSButton.self)!
        let retryModel = field(sheet, "modelLabel", NSTextField.self)!
        func assertReady(_ ready: Bool, model: String = "Qwen3.5-9B-4bit") {
            precondition(modelLabel.stringValue.contains(model) && retryModel.stringValue.contains(model))
            precondition(modelLabel.stringValue.contains("暂未就绪") == !ready &&
                retryModel.stringValue.contains("暂未就绪") == !ready && run.isEnabled == ready,
                "Rule page and existing retry sheet did not reflect live model availability")
            precondition(controller.livePromptCatalog?.current_model.ready == ready)
        }
        health("loading", ready: false); assertReady(false)
        editor.string = "尚未保存的个人规则。"
        studio.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        name.stringValue = "尚未保存的名称"
        studio.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: name))

        // The active rule never changes: readiness must refresh independently.
        health("ready", ready: true); assertReady(true)
        controller.receivePromptCatalog(.success(catalog(ready: false)), generation: controller.promptGeneration)
        assertReady(true)
        precondition(controller.promptCatalog?.current_model.ready == false,
            "The regression must retain an outdated catalog to test the live projection")
        let reply: [String: Any] = ["raw_text": entry.rawText, "text": "请保留原意。", "cleanup_seconds": 0.1,
            "cleanup_applied": true, "cleanup_profile": ["version_id": version.id, "name": version.name,
                "content_sha256": version.content_sha256, "model_id": "Qwen3.5-9B-4bit"],
            "cleanup_outcome": ["status": "applied", "reason": "changed"]]
        NativeFailureURLProtocol.configureCleanup(try JSONSerialization.data(withJSONObject: reply))
        run.performClick(nil)
        precondition(controller.reprocessGeneration != nil, "Fresh health must unlock the real retry dispatch guard")
        let deadline = Date().addingTimeInterval(2)
        while controller.reprocessGeneration != nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(controller.reprocessGeneration == nil && controller.store.entries[0].revisions?.count == 1)
        precondition(NativeFailureURLProtocol.recordedPaths() == ["/cleanup/reprocess"] &&
            NativeFailureURLProtocol.recordedPromptHeaders() == [version.id], "Readiness triggered unnecessary catalog requests")
        precondition(board.string(forType: .string) == "prompt-health clipboard")

        health("degraded", ready: false); assertReady(false)
        controller.receivePromptCatalog(.success(catalog(ready: true)), generation: controller.promptGeneration)
        assertReady(false)
        health("ready", ready: true); assertReady(true)
        controller.pendingModelSelection = ("qwen", "cleanup")
        controller.selectedCleanupModelID = "cleanup"
        health("ready", ready: true); assertReady(false)
        precondition(controller.pendingModelSelection != nil, "The old ready model cannot finish a new model selection")
        health("ready", ready: true, model: "Qwen3.5-4B-4bit")
        assertReady(true, model: "Qwen3.5-4B-4bit")
        controller.receivePromptCatalog(.success(catalog(ready: false)), generation: controller.promptGeneration)
        assertReady(true, model: "Qwen3.5-4B-4bit")
        precondition(controller.pendingModelSelection == nil && controller.promptCatalogCurrent)
        precondition(controller.promptCatalog?.versions == [version] && controller.livePromptCatalog?.versions == [version] &&
            controller.livePromptCatalog?.active_version_id == version.id, "Runtime metadata changed an immutable rule")
        precondition(editor.string == "尚未保存的个人规则。" && name.stringValue == "尚未保存的名称" && studio.hasUnsavedChanges,
            "A readiness refresh discarded the editor draft")
        precondition(controller.store.entries[0].rawText == entry.rawText && controller.store.entries[0].text == entry.text)
        precondition(!window.window!.isVisible && !sheet.window!.isVisible && controller.ownedBackend == nil)
        print("PASS Prompt live readiness: same-rule startup recovery, real retained page and retry sheet, guarded retry dispatch, late catalogs, degradation, model switching, immutable versions and unsaved drafts preserved")
    }

    static func verifyPromptSnapshots() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("local.dictation.prompt-snapshot.\(UUID())"))
        defer { board.releaseGlobally() }
        let target = FocusTarget(pid: -1, element: AXUIElementCreateApplication(-1), selection: Selection(location: 0, length: 0))
        var pastes = 0
        let controller = AppDelegate(inserter: TextInserter(board: board, permissionCheck: { nil }, targetReader: { target },
            pasteKeySender: { _ in pastes += 1; return true }, foregroundPID: { -1 }))
        let model = CleanupPromptModel(id: "fixture-cleanup", kind: "local", ready: true)
        func catalog(_ id: String?, error: String? = nil) -> CleanupPromptCatalog {
            CleanupPromptCatalog(active_version_id: id, versions: [], current_model: model,
                                 asr_model: "fixture-asr", prompt_store_error: error)
        }
        controller.supportsPromptVersions = true
        precondition(!controller.promptReadyForRecording)
        controller.receivePromptCatalog(.success(catalog("version-a")), generation: controller.promptGeneration)
        precondition(controller.promptReadyForRecording)
        controller.captureRecordingConfiguration()
        controller.receivePromptCatalog(.success(catalog("version-b")), generation: controller.promptGeneration)
        precondition(controller.activePromptVersionID == "version-a")
        controller.captureRecordingConfiguration()
        precondition(controller.activePromptVersionID == "version-b")
        controller.store.updatePreferences { $0.cleanupEnabled = false }
        controller.captureRecordingConfiguration()
        precondition(controller.activePromptVersionID == nil)

        let obsolete = controller.promptGeneration
        controller.invalidatePromptCallbacks()
        controller.receivePromptCatalog(.success(catalog("version-a")), generation: obsolete)
        precondition(controller.promptCatalog?.active_version_id == "version-b" && !controller.promptReadyForRecording)
        controller.receivePromptCatalog(.success(catalog(nil, error: "fixture damaged store")), generation: controller.promptGeneration)
        precondition(controller.promptReadyForRecording, "Readable ASR must remain usable when Prompt storage is damaged")
        controller.store.updatePreferences { $0.cleanupEnabled = true }
        controller.captureRecordingConfiguration()
        controller.receivePromptCatalog(.success(catalog("version-b")), generation: controller.promptGeneration)
        precondition(controller.activePreferences?.cleanupEnabled == false && controller.activePromptVersionID == nil && controller.activePromptWarning != nil)
        let damagedReply = Data("""
        {"raw_text":"保留原文","text":"保留原文","asr_seconds":0.2,"cleanup_seconds":0,"total_seconds":0.2,"cleanup_applied":false,
         "cleanup_outcome":{"status":"skipped","reason":"disabled"}}
        """.utf8)
        let damagedID = UUID(); controller.sessionID = damagedID; controller.phase = .processing; controller.target = target
        var damagedPreferences = controller.activePreferences!; damagedPreferences.autoInsertEnabled = true
        let damagedResponse = HTTPURLResponse(url: serviceBase, statusCode: 200, httpVersion: nil, headerFields: nil)!
        controller.receiveDictationReply(id: damagedID, preferences: damagedPreferences, data: damagedReply, response: damagedResponse, error: nil)
        precondition(pastes == 1 && controller.store.entries.first?.cleanupOutcome?.reason == "prompt_unavailable")
        precondition(controller.hud?.onRetryCleanup != nil, "A forced ASR-only fallback was hidden after paste dispatch")
        let warning = controller.hud.flatMap { Mirror(reflecting: $0).children.first { $0.label == "deliveryMessage" }?.value as? NSTextField }
        precondition(warning?.stringValue == "整理未完成，已保留原文")
        let userDisabled = try JSONDecoder().decode(DictationResult.self, from: damagedReply)
        precondition(userDisabled.cleanupOutcome(requested: false)?.status == "skipped" &&
                     userDisabled.cleanupOutcome(requested: false)?.attentionMessage == nil,
                     "Intentional cleanup disable became a failure warning")

        // Receive the actual wire contract without invoking system insertion.
        let id = UUID(); controller.sessionID = id; controller.phase = .processing
        var preferences = DictationPreferences(); preferences.autoInsertEnabled = false
        let body = Data("""
        {"raw_text":"测试原文","text":"测试结果","asr_seconds":0.2,"cleanup_seconds":0.4,"total_seconds":0.6,"cleanup_applied":true,
         "asr_model":"fixture-asr","cleanup_profile":{"version_id":"version-a","name":"测试规则","content_sha256":"fixture-hash","model_id":"fixture-cleanup"}}
        """.utf8)
        let response = HTTPURLResponse(url: serviceBase, statusCode: 200, httpVersion: nil, headerFields: nil)!
        controller.receiveDictationReply(id: id, preferences: preferences, data: body, response: response, error: nil)
        precondition(controller.store.entries.first?.cleanupProfile?.versionID == "version-a")
        precondition(controller.store.entries.first?.asrModel == "fixture-asr")
        precondition(controller.store.entries.first?.cleanupProfile?.modelID == "fixture-cleanup")
        controller.terminating = true
        print("Prompt 快照验证通过：切换仅影响下一次口述；过期回调被拒绝；规则故障允许 ASR；实际响应来源写入历史。")
    }

    static func verifyUploadFailureRecovery() throws {
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw NSError(domain: "NativeUploadSelfTest", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func waitFor(_ condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(3)
            while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            try require(condition(), "模拟响应未在期限内完成。")
        }
        for failure in NativeFailureURLProtocol.Failure.allCases {
            NativeFailureURLProtocol.configure(failure)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [NativeFailureURLProtocol.self]
            let session = URLSession(configuration: configuration)
            let controller = AppDelegate(serviceSession: session)
            defer { controller.invalidateHealthCallbacks(); session.invalidateAndCancel() }
            _ = controller.store.add(rawText: "已保留的测试原文", text: "已保留的测试结果", asrSeconds: 0,
                cleanupSeconds: 0, totalSeconds: 0, audioSeconds: nil, cleanupApplied: false, warning: nil)
            let id = UUID()
            controller.sessionID = id
            controller.activePreferences = DictationPreferences()
            controller.activePromptVersionID = "fixture-frozen-prompt"
            controller.serviceCanRecord = true
            controller.phase = .processing
            // Submit through the actual URLSession completion path. This local
            // protocol consumes fixture bytes; no socket or recording is used.
            controller.submit(Data([0, 1, 2, 3]), id: id)
            try waitFor { controller.phase == .failed }
            try require(!controller.serviceCanRecord && !controller.displayState.canStart, "上传失败后，健康检查确认空闲前仍允许录音。")
            try waitFor { controller.phase == .failed && controller.healthRequest == nil && controller.healthRetry != nil }
            try require(!controller.serviceCanRecord && !controller.displayState.canStart, "服务 busy 时仍允许录音。")
            try require(controller.sessionID == nil && controller.request == nil, "失败请求未失效。")
            try require(controller.store.entries.count == 1 && controller.store.entries[0].text == "已保留的测试结果", "上次结果被改动。")
            try require(controller.recorder == nil && controller.hud?.isVisible == false && controller.hud?.onRetryCleanup == nil,
                        "故障提示不应启动录音、抢焦点或在没有正文时提供整理重试。")
            let feedback = controller.hud.flatMap { Mirror(reflecting: $0).children.first { $0.label == "deliveryMessage" }?.value as? NSTextField }
            try require(feedback?.stringValue == "本段处理未完成 · 请重新口述", "上传失败没有给出准确的可恢复提示。")
            // Execute the scheduled retry itself to avoid a real four-second
            // delay; its generation and health callback guards remain active.
            controller.healthRetry?.perform()
            try waitFor { controller.serviceCanRecord }
            try require(controller.displayState.canStart && controller.sessionID == nil, "ready 后未恢复开始或重启了旧口述。")
            try require(NativeFailureURLProtocol.recordedPaths() == ["/dictate", "/health", "/health"], "重复提交了录音或未检查 busy→ready。")
            try require(NativeFailureURLProtocol.recordedPromptHeaders() == ["fixture-frozen-prompt"], "录音未独立发送已冻结的规则版本。")
            print("上传故障模拟通过：\(failure.rawValue) → busy 禁用 → ready 可录音；仅 1 次提交，旧结果保留。")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NativeFailureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let controller = AppDelegate(serviceSession: session)
        defer { controller.terminating = true; controller.invalidateHealthCallbacks(); session.invalidateAndCancel() }
        let oldSession = UUID()
        controller.sessionID = oldSession; controller.phase = .processing; controller.serviceCanRecord = true
        controller.receiveDictationReply(id: oldSession, preferences: DictationPreferences(), data: nil, response: nil, error: URLError(.timedOut))
        let obsoleteHealth = controller.healthGeneration
        // Both clicks execute before any queued health callback can run. They
        // may request a check, but must not allocate a new recording session.
        controller.toggleRecording(); controller.toggleRecording()
        try require(!controller.displayState.canStart && controller.sessionID == nil && controller.recorder == nil,
                    "健康检查返回前连点启动了录音。")
        let ready = Data("""
        {"service":"local-dictation","status":"ready","ready":true,"asr_ready":true,"cleanup_ready":true,"busy":false,"message":"fixture","supports_options":true}
        """.utf8)
        let response = HTTPURLResponse(url: serviceBase, statusCode: 200, httpVersion: nil, headerFields: nil)!
        controller.receiveHealthReply(generation: obsoleteHealth, data: ready, response: response, error: nil)
        try require(!controller.serviceCanRecord, "迟到健康响应提前开放了录音。")

        let newSession = UUID()
        controller.sessionID = newSession; controller.phase = .processing
        let newRequest = session.dataTask(with: serviceBase.appendingPathComponent("dictate"))
        controller.request = newRequest // Deliberately never resumed.
        controller.receiveDictationReply(id: oldSession, preferences: DictationPreferences(), data: nil, response: nil, error: URLError(.timedOut))
        controller.receiveDictationReply(id: oldSession, preferences: DictationPreferences(), data: Data("{}".utf8), response: response, error: nil)
        try require(controller.sessionID == newSession && controller.request === newRequest && controller.phase == .processing,
                    "旧口述的迟到结果或超时改动了新会话。")
        print("交错验证通过：健康返回前连点不会录音；旧健康响应、旧超时与旧结果不能改动新会话。")
    }

    @objc private func requestMicrophone() {
        guard !hasPendingWork else { return }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] allowed in
                DispatchQueue.main.async { self?.setPhase(.idle, allowed ? "麦克风已允许，按快捷键即可开始。" : "麦克风未允许，可在系统设置中修改。") }
            }
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
    }

    @objc private func requestAccessibility() {
        guard !hasPendingWork else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func copyClean() { copy(store.entries.first?.text) }
    @objc private func copyRaw() { copy(store.entries.first?.rawText) }
    private func copy(_ text: String?) {
        guard let text, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([text as NSString])
        if !hasPendingWork { setPhase(.completed, "已复制。请在需要的位置粘贴。") }
    }

    private var promptReadyForRecording: Bool {
        // An unreadable store still permits ASR: the server returns the raw
        // transcript with a warning. An unfetched catalog must not pick a rule
        // later at recording stop, because that would break the start snapshot.
        !supportsPromptVersions || (promptCatalogCurrent &&
            (promptCatalog?.active_version_id != nil || promptCatalog?.prompt_store_error != nil))
    }

    private func invalidatePromptCallbacks() {
        promptGeneration = UUID(); promptBusy = false
        promptCatalogCurrent = false; promptRefreshPending = false
        updatePromptUI()
    }

    private func loadPrompts() {
        guard !promptBusy else { promptRefreshPending = true; return }
        promptBusy = true; promptError = nil; updatePromptUI()
        let generation = promptGeneration
        promptClient.load { [weak self] result in self?.receivePromptCatalog(result, generation: generation) }
    }

    private func savePrompt(_ draft: CleanupPromptDraft) {
        guard !promptBusy else { return }
        promptBusy = true; promptError = nil; updatePromptUI()
        let generation = promptGeneration
        promptClient.save(draft) { [weak self] result in self?.receivePromptCatalog(result, generation: generation) }
    }

    private func activatePrompt(id: String) {
        guard !promptBusy else { return }
        promptCatalogCurrent = false
        promptBusy = true; promptError = nil; updatePromptUI()
        let generation = promptGeneration
        promptClient.activate(id: id) { [weak self] result in self?.receivePromptCatalog(result, generation: generation) }
    }

    private func receivePromptCatalog(_ result: Result<CleanupPromptCatalog, Error>, generation: UUID) {
        guard !terminating, generation == promptGeneration else { return }
        promptBusy = false
        switch result {
        case .success(let catalog): promptCatalog = catalog; promptCatalogCurrent = !promptRefreshPending; promptError = nil
        case .failure(let error): promptError = error.localizedDescription
        }
        updatePromptUI()
        if promptRefreshPending { promptRefreshPending = false; loadPrompts() }
    }

    private var livePromptCatalog: CleanupPromptCatalog? {
        guard let catalog = promptCatalog else { return nil }
        let state = displayState
        // The catalog owns saved rule content; health owns runtime availability.
        // A delayed catalog response must not restore a startup ready=false (or
        // an old ready=true after a model failure). Project only live metadata,
        // keeping version contents, selection, and unsaved editor drafts intact.
        let ready = state.cleanupReadiness == .checking ? catalog.current_model.ready : state.cleanupReadiness == .ready
        return CleanupPromptCatalog(active_version_id: catalog.active_version_id, versions: catalog.versions,
            current_model: CleanupPromptModel(id: state.cleanupModel ?? catalog.current_model.id,
                kind: cleanupBackend?.rawValue ?? catalog.current_model.kind, ready: ready),
            asr_model: state.asrModel ?? catalog.asr_model, prompt_store_error: catalog.prompt_store_error,
            recovery_message: catalog.recovery_message, prompt_import_error: catalog.prompt_import_error)
    }

    private func updatePromptUI() {
        windowController?.updatePrompts(catalog: livePromptCatalog, busy: promptBusy, error: promptError)
    }

    private func retryCleanup(entryID: UUID, panel: DictationHUD) {
        guard reprocessGeneration == nil else {
            if reprocessHUD !== panel { panel.showDelivery(message: "另一段正在重新整理，请稍后再试", needsPermission: false, show: !suppressStreamingPresentation) }
            return
        }
        guard let versionID = promptCatalog?.active_version_id, promptCatalogCurrent else {
            panel.showDelivery(message: "润色规则尚未就绪，请稍后重试", needsPermission: false, show: !suppressStreamingPresentation)
            loadPrompts(); return
        }
        reprocessHistory(entryID: entryID, versionID: versionID, feedbackHUD: panel)
    }

    private func reprocessHistory(entryID: UUID, versionID: String, feedbackHUD: DictationHUD? = nil) {
        guard reprocessGeneration == nil else { return }
        reprocessHUD = feedbackHUD
        reprocessHUDGeneration = feedbackHUD?.dismissalGeneration ?? 0
        reprocessEntryID = entryID; reprocessError = nil
        guard supportsReprocess, cleanupBackend == .local else {
            reprocessError = "当前服务尚不支持本地历史重新整理，请更新并检查服务。"
            updateReprocessUI(); return
        }
        guard !phase.busy, !hasStreamingWork, !configuringModels else {
            reprocessError = "当前口述尚未完成，请在空闲时重新整理。"
            updateReprocessUI(); return
        }
        guard let entry = store.entries.first(where: { $0.id == entryID }),
              let catalog = livePromptCatalog, promptCatalogCurrent, catalog.current_model.ready,
              let version = catalog.versions.first(where: { $0.id == versionID }) else {
            reprocessError = "原记录或润色规则暂不可用，请刷新后重试。"
            updateReprocessUI(); return
        }
        // Freeze both the selected immutable rule and current dictionary. The
        // active rule used by subsequent microphone sessions is never changed.
        let generation = UUID(); reprocessGeneration = generation
        updateReprocessUI(); updateUI()
        reprocessTask = reprocessClient.reprocess(rawText: entry.rawText, versionID: versionID,
            preferences: store.preferences) { [weak self] result in
                self?.receiveReprocessedHistory(result, entryID: entryID, generation: generation,
                    expectedVersionID: versionID, expectedHash: version.content_sha256)
            }
    }

    private func receiveReprocessedHistory(_ result: Result<HistoryReprocessResult, Error>, entryID: UUID,
                                           generation: UUID, expectedVersionID: String, expectedHash: String) {
        guard !terminating, reprocessGeneration == generation, reprocessEntryID == entryID else { return }
        reprocessTask = nil; reprocessGeneration = nil
        switch result {
        case .success(let value):
            guard value.cleanup_applied, !["failed", "skipped"].contains(value.cleanup_outcome?.status ?? ""), let profile = value.cleanup_profile,
                  profile.versionID == expectedVersionID, profile.contentSHA256 == expectedHash else {
                reprocessError = "返回的润色规则不匹配，未保存本次结果。"
                updateReprocessUI(); updateUI(); return
            }
            let outcome = value.cleanup_outcome ?? .legacy(raw: value.raw_text, text: value.text, applied: value.cleanup_applied)
            if store.addRevision(entryID: entryID, text: value.text, cleanupSeconds: value.cleanup_seconds,
                                 cleanupProfile: profile, cleanupOutcome: outcome) == nil {
                reprocessError = "原记录已删除或结果无效，未保存本次结果。"
            } else { reprocessError = nil }
        case .failure(let error): reprocessError = error.localizedDescription
        }
        // Reprocessing has no insertion side effect. The user explicitly
        // copies a chosen version from the comparison window when needed.
        updateReprocessUI(); updateUI()
    }

    private func updateReprocessUI() {
        windowController?.updateReprocessing(entryID: reprocessEntryID,
            busy: reprocessGeneration != nil, error: reprocessError)
        guard let panel = reprocessHUD, let entryID = reprocessEntryID else { return }
        // A dismissed or reused card no longer owns this asynchronous result.
        // Persist the revision, but never bring a closed notification back.
        guard panel.dismissalGeneration == reprocessHUDGeneration else { reprocessHUD = nil; return }
        if reprocessGeneration != nil {
            panel.showDelivery(message: "正在重新整理", needsPermission: false, show: !suppressStreamingPresentation, retrying: true)
        } else if let error = reprocessError {
            // Keep the original result and retry callback. A failed retry must
            // not overwrite the clipboard or imply the previous text was fixed.
            panel.showDelivery(message: "重新整理未完成 · " + error, needsPermission: false, show: !suppressStreamingPresentation)
        } else if let revision = store.entries.first(where: { $0.id == entryID })?.revisions?.last {
            let saved = store.hasUnsavedHistory ? "新结果尚未保存，请复制" : "新版本已保存"
            let attention = revision.cleanupOutcome?.attentionMessage
            let message = attention.map { $0 + " · " + saved } ?? saved
            configureResultHUD(panel, entryID: entryID, message: message, text: revision.text, attention: attention)
            panel.onViewResult = { [weak self] in
                guard let self else { return }
                self.showResults(); self.windowController?.showPage(.history)
                self.windowController?.showReprocessing(entryID: entryID, revisionID: revision.id)
            }
            panel.showDelivery(message: message, needsPermission: false, show: !suppressStreamingPresentation)
        }
    }

    private func configureCorrectionLearning() {
        inserter.onPasteDispatched = { [weak self] text, target, entryID in
            guard let self, self.store.preferences.automaticVocabularyLearning else { return }
            self.correctionObserver.observeInsertion(pid: target.pid, element: target.element,
                range: CFRange(location: target.selection.location, length: target.selection.length),
                text: text, entryID: entryID,
                bundleID: NSRunningApplication(processIdentifier: target.pid)?.bundleIdentifier)
        }
        correctionObserver.onAvailability = { [weak self] status in
            guard let self else { return }
            switch status {
            case .idle: self.correctionStatus = "填入后纠正术语，可自动加入词典。"
            case .confirming: self.correctionStatus = "正在确认文字已填入。"
            case .observing: self.correctionStatus = "正在留意本次文字中的术语纠正。"
            case .awaitingConfirmation: self.correctionStatus = "发现词组纠正，确认后可记住。"
            case .learned: break // The persistence callback supplies the actual outcome.
            case .unsupported: self.correctionStatus = "当前输入框不支持读取修改，仍可手动添加词条。"
            case .unconfirmed: self.correctionStatus = "未能确认本次填入，已跳过自动学习。"
            }
            self.windowController?.updateCorrectionLearning(status: self.correctionStatus)
        }
        correctionObserver.onCorrection = { [weak self] candidate in
            guard let self, !self.terminating, self.store.preferences.automaticVocabularyLearning else { return }
            // Previously undone pairs remain a rejection memory. Do not ask
            // the user to confirm a pair the store intentionally will not learn.
            if self.store.preferences.learnedVocabulary.contains(where: {
                $0.original == candidate.original && $0.corrected == candidate.corrected
            }) {
                self.correctionStatus = "填入后纠正术语，可自动加入词典。"
                self.windowController?.updateCorrectionLearning(status: self.correctionStatus)
                return
            }
            if candidate.requiresConfirmation {
                let pendingID = UUID(); self.pendingCorrectionID = pendingID
                self.learningToast.showConfirmation(original: candidate.original, term: candidate.corrected, onIgnored: { [weak self] in
                    guard let self, self.pendingCorrectionID == pendingID else { return }
                    self.pendingCorrectionID = nil
                    if self.correctionObserver.availability == .awaitingConfirmation {
                        self.correctionStatus = "填入后纠正术语，可自动加入词典。"
                        self.windowController?.updateCorrectionLearning(status: self.correctionStatus)
                    }
                }) { [weak self] in
                    self?.acceptCorrection(candidate)
                }
            } else { self.acceptCorrection(candidate) }
        }
    }

    private func acceptCorrection(_ candidate: DictationCorrectionCandidate) {
        pendingCorrectionID = nil
        guard !terminating, store.preferences.automaticVocabularyLearning else { return }
        guard let learned = store.learnVocabulary(original: candidate.original, corrected: candidate.corrected,
            entryID: candidate.entryID, bundleID: candidate.bundleID, at: candidate.observedAt) else {
            self.correctionStatus = self.store.storageError ?? "已跳过已有词条或撤销过的纠正。"
            self.windowController?.updateCorrectionLearning(status: self.correctionStatus)
            return
        }
        self.correctionStatus = self.store.storageError ?? "已学会 \(learned.corrected)，可在此撤销。"
        self.windowController?.updateCorrectionLearning(status: self.correctionStatus)
        self.learningToast.show(term: learned.corrected) { [weak self] in
            guard let self else { return }
            let undone = self.store.undoLearnedVocabulary(id: learned.id)
            self.correctionStatus = undone ? "已撤销 \(learned.corrected)。" : self.store.storageError ?? "该学习记录已撤销。"
            self.windowController?.updateCorrectionLearning(status: self.correctionStatus)
        }
    }

    private func createWindowIfNeeded() {
        guard windowController == nil else { return }
        let controller = DictationWindowController(store: store, sessionStartedAt: sessionStartedAt)
        controller.onStart = { [weak self] in self?.toggleRecording() }
        controller.onCancel = { [weak self] in self?.cancelRecording() }
        controller.onCopyText = { [weak self] text in self?.copy(text) }
        controller.onCheckService = { [weak self] in self?.checkHealth() }
        controller.onSetup = { [weak self] in self?.showSetup() }
        controller.onSelectASRModel = { [weak self] id in self?.selectHomeModels(asr: id) }
        controller.onSelectCleanupModel = { [weak self] id in self?.selectHomeModels(cleanup: id) }
        controller.onSelectAppearanceMode = { [weak self] mode in self?.selectApplicationAppearance(mode) }
        controller.onSelectAppIcon = { [weak self] style in self?.appIconCoordinator.selectManual(style) }
        controller.onAppIconFollowsSystemAppearance = { [weak self] follows in self?.appIconCoordinator.setFollowsSystem(follows) }
        controller.onMicrophone = { [weak self] in self?.requestMicrophone() }
        controller.onAccessibility = { [weak self] in self?.requestAccessibility() }
        controller.onShortcutCapture = { [weak self] capturing in
            guard let self else { return }
            self.shortcutCapturing = capturing
            self.hotKeyEventGeneration = UUID()
            self.hotKeyLatch = HotKeyLatch()
            self.functionKeyMonitor.resetCandidate()
        }
        controller.onApplyShortcut = { [weak self] shortcut in
            guard let self else { return "应用尚未就绪。" }
            return self.replaceShortcut(shortcut, persist: true)
        }
        controller.onInputMonitoring = { [weak self] in self?.requestInputMonitoring() }
        controller.onReloadPrompts = { [weak self] in self?.loadPrompts() }
        controller.onSavePrompt = { [weak self] draft in self?.savePrompt(draft) }
        controller.onActivatePrompt = { [weak self] id in self?.activatePrompt(id: id) }
        controller.onReprocessEntry = { [weak self] entryID, versionID in
            self?.reprocessHistory(entryID: entryID, versionID: versionID)
        }
        windowController = controller
        updateAppIconUI()
        controller.updateAppearanceSelection(error: appearanceError)
        updatePromptUI()
        updateReprocessUI()
        controller.updateCorrectionLearning(status: correctionStatus)
    }

    private func applyApplicationAppearance(_ mode: DictationAppearanceMode) {
        switch mode {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func selectApplicationAppearance(_ mode: DictationAppearanceMode) {
        guard store.setAppearanceMode(mode) else {
            appearanceError = "外观设置未能保存，请检查数据文件夹后重试。"
            windowController?.updateAppearanceSelection(error: appearanceError)
            return
        }
        appearanceError = nil
        applyApplicationAppearance(mode)
        windowController?.updateAppearanceSelection(error: nil)
        appIconCoordinator.systemAppearanceChanged()
    }

    private func updateAppIconUI() {
        windowController?.updateAppIconSelection(busy: appIconCoordinator.busy, error: appIconCoordinator.error,
                                                 appliedStyle: appIconCoordinator.appliedStyle)
    }

    @objc private func showResults() {
        createWindowIfNeeded()
        // Opening the main window is a fresh visit. A retained history window
        // must not reopen on a page anchored to an old recording.
        windowController?.returnToLatestHistoryIfVisible()
        updateUI()
        NSApp.activate(ignoringOtherApps: true)
        windowController?.window?.makeKeyAndOrderFront(nil)
    }

    private func renderPreview(to url: URL) {
        // Preview uses an in-memory store. It never loads saved dictation,
        // starts a service, registers shortcuts, or requests system access.
        let arguments = CommandLine.arguments
        let previewPrompt = CleanupPromptVersion(id: "preview-natural", name: "日常表达", note: "保留个人表达，整理重复和口误。",
            created_at: "2026-11-04T08:00:00Z", model_id: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
            system_prompt: "你是一名口述编辑。保留说话者的意思和表达习惯，让文字清楚、自然。\n\n去掉无意义的语气词和重复内容；后面的明确更正优先。不要补充原文没有的信息。明确列举时逐项分行，其他内容使用自然段。\n\n只输出整理后的文字，不加解释。",
            user_prefix: "请整理以下口述，保留原意。", examples: [CleanupPromptExample(source: "那个，周四，不对，周五下午三点开会。", edited: "周五下午三点开会。")],
            content_sha256: "preview", origin: "builtin")
        let previewProfile = DictationCleanupProfile(versionID: previewPrompt.id, name: previewPrompt.name,
            contentSHA256: previewPrompt.content_sha256, modelID: previewPrompt.model_id!)
        if !arguments.contains("--empty") {
            // This deterministic activity belongs only to the memory-only preview.
            // Historical production transcripts are never replayed into statistics.
            for offset in stride(from: 170, through: 1, by: -1) where offset % 7 < 2 || offset % 11 == 0 || offset < 3 {
                let text = String(repeating: "这是一段用于展示口述统计的示例文字", count: 5 + offset % 45)
                let date = Calendar.current.date(byAdding: .day, value: -offset, to: Date())!
                _ = store.add(rawText: text, text: text, asrSeconds: 0.8, cleanupSeconds: 1.3,
                    totalSeconds: 2.1, audioSeconds: Double(text.count) / 2.8, cleanupApplied: true, warning: nil, createdAt: date)
            }
        store.updatePreferences { $0.vocabulary = ["Whisper", "CodeGraph", "工作流"] }
        _ = store.add(rawText: "那个，我们先把快捷键的录音流程走通，然后再看一下速度。",
            text: "先验证快捷键录音流程，再检查识别速度。", asrSeconds: 0.41,
            cleanupSeconds: 0.92, totalSeconds: 1.33, audioSeconds: 8.2, cleanupApplied: true, warning: nil)
        _ = store.add(rawText: "明天下午，明天下午三点我们开会。主要说两件事，一个是语音识别的速度，另一个是整理以后有没有改变原意。",
            text: "明天下午三点开会，主要讨论两件事：\n\n1. 语音识别的速度。\n2. 整理后的内容是否保留原意。", asrSeconds: 0.53,
            cleanupSeconds: 1.12, totalSeconds: 1.65, audioSeconds: 14.5, cleanupApplied: true, warning: nil)
        if arguments.contains("--page"), arguments.contains("history") {
            _ = store.add(rawText: "这个版本就可以，先改到test分支，然后部署到三点二八，我看一下。",
                text: "这个版本可以。先改到 test 分支，再部署到 3.28，我看一下。", asrSeconds: 0.8,
                cleanupSeconds: 1.1, totalSeconds: 1.9, audioSeconds: 8, cleanupApplied: true, warning: nil,
                cleanupProfile: previewProfile, asrModel: "mlx-community/Qwen3-ASR-1.7B-8bit")
        }
        }
        let cleanupEnabled = !arguments.contains("--no-cleanup")
        store.updatePreferences { $0.cleanupEnabled = cleanupEnabled }
        var state = DictationUIState()
        state.status = "已整理 · 文字已保留，可随时复制。"
        let backendIndex = arguments.firstIndex(of: "--cleanup-backend")
        let backendName = backendIndex.flatMap { arguments.count > $0 + 1 ? arguments[$0 + 1] : nil } ?? "local"
        state.cleanupBackend = DictationCleanupBackend(rawValue: backendName)
        state.cleanupEnabled = cleanupEnabled
        switch state.cleanupBackend {
        case .cloud: state.serviceMessage = "本地识别已就绪；云端整理已配置。"
        case .local: state.serviceMessage = "本地识别与整理已就绪。"
        case nil: state.serviceMessage = "本地识别已就绪，整理方式待确认。"
        }
        state.serviceReady = true; state.canStart = true; state.microphoneAllowed = true; state.accessibilityAllowed = true
        state.asrReadiness = .ready; state.cleanupReadiness = .ready
        state.asrModel = "Qwen3-ASR-1.7B-8bit"
        state.cleanupModel = "Qwen3-4B-Instruct-2507-4bit"
        state.lastEntryID = store.entries.first?.id; state.preview = true
        state.functionKeyMessage = "Fn 已启用（界面预览）"
        state.functionKeyEnabled = true
        let pageIndex = arguments.firstIndex(of: "--page")
        let pageName = pageIndex.flatMap { arguments.count > $0 + 1 ? arguments[$0 + 1] : nil } ?? "home"
        do {
            if pageName.hasPrefix("hud-") {
                state.recording = pageName == "hud-recording"; state.processing = !state.recording
                state.elapsedSeconds = state.recording ? 12 : 2; state.meterLevel = 0.72
                let previewHUD = DictationHUD(); try previewHUD.renderPNG(to: url, state: state)
            } else {
                createWindowIfNeeded(); windowController?.updateState(state)
                windowController?.updatePrompts(catalog: CleanupPromptCatalog(active_version_id: previewPrompt.id,
                    versions: [previewPrompt], current_model: CleanupPromptModel(id: previewPrompt.model_id!, kind: "local", ready: true),
                    asr_model: "mlx-community/Qwen3-ASR-1.7B-8bit"), busy: false, error: nil)
                if arguments.contains("--minimum-size") { windowController?.window?.setContentSize(NSSize(width: 1000, height: 668)) }
                if arguments.contains("--wide") { windowController?.window?.setContentSize(NSSize(width: 1800, height: 1000)) }
                windowController?.showPage(DictationPage(rawValue: pageName) ?? .home, compareHistory: arguments.contains("--compare"))
                try windowController?.renderPNG(to: url)
            }
            print("已保存本应用界面预览。示例数据，未录音、未读取历史、未请求权限。")
        } catch { fputs("无法保存界面预览。\n", stderr) }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

/// Only installed on an ephemeral self-test session. It never forwards a
/// request, reads personal data, or changes the process-wide URL loading system.
private final class NativeFailureURLProtocol: URLProtocol {
    enum Failure: String, CaseIterable { case transport, http, malformed }
    private static let lock = NSLock()
    private static var failure: Failure = .transport
    private static var paths: [String] = []
    private static var promptHeaders: [String] = []
    private static var cleanupReply: Data?
    static func configureCleanup(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        cleanupReply = data; paths = []; promptHeaders = []
    }
    static func configure(_ failure: Failure) {
        lock.lock(); defer { lock.unlock() }
        self.failure = failure; paths = []; promptHeaders = []; cleanupReply = nil
    }
    static func recordedPaths() -> [String] {
        lock.lock(); defer { lock.unlock() }; return paths
    }
    static func recordedPromptHeaders() -> [String] {
        lock.lock(); defer { lock.unlock() }; return promptHeaders
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        Self.paths.append(url.path)
        if url.path == "/dictate" || url.path == "/cleanup/reprocess" { Self.promptHeaders.append(request.value(forHTTPHeaderField: "X-Cleanup-Prompt-Version") ?? "") }
        let failure = Self.failure
        let cleanupReply = Self.cleanupReply
        let healthCount = Self.paths.filter { $0 == "/health" }.count
        Self.lock.unlock()
        if url.path == "/dictate", failure == .transport {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return
        }
        let status: Int
        let body: Data
        if url.path == "/cleanup/reprocess", let cleanupReply {
            status = 200; body = cleanupReply
        } else if url.path == "/health" {
            status = 200
            body = Data("""
            {"service":"local-dictation","status":"ready","ready":true,"asr_ready":true,"cleanup_ready":true,"busy":\(healthCount == 1 ? "true" : "false"),"message":"fixture","supports_options":true}
            """.utf8)
        } else if url.path == "/dictate" {
            status = failure == .http ? 500 : 200
            body = Data((failure == .http ? "{\"error\":\"fixture failure\"}" : "{\"text\":\"incomplete fixture\"}").utf8)
        } else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func verifyClipboardFallback() {
    let board = NSPasteboard(name: NSPasteboard.Name("local.dictation.regression.\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    let inserter = TextInserter(board: board, permissionCheck: { "TEST_PERMISSION_DENIED。" })
    precondition(inserter.captureTarget() == nil)
    let expected = "自动填入权限未开启时，也应直接复制本次口述。"
    let result = inserter.insert(expected, target: nil, changed: false)
    precondition(result.needsPermission)
    precondition(result.showHUD && !DeliveryResult.pasteDispatched.showHUD)
    let manual = inserter.insert(expected, target: nil, changed: false, automatic: false)
    precondition(manual.showHUD && !manual.needsPermission && manual.hudMessage.contains("⌘V"))
    precondition(board.string(forType: .string) == expected)
    precondition(result.hudMessage.contains("已复制"))
    precondition(board.string(forType: .string) == expected,
                 "Permission failure discarded the automatic clipboard fallback")
    RunLoop.current.run(until: Date().addingTimeInterval(1.25))
    precondition(board.string(forType: .string) == expected,
                 "A delayed clipboard restore replaced the recognized text")

    // A distinct utterance may legitimately have identical text. Every call is
    // explicit; this driver has no automatic paste retries or timed reinsertion.
    let second = inserter.insert(expected, target: nil, changed: false)
    precondition(second.needsPermission && board.string(forType: .string) == expected)
    let permitted = TextInserter(board: board, permissionCheck: { nil })
    let fake = FocusTarget(pid: getpid(), element: AXUIElementCreateApplication(getpid()), selection: Selection(location: 0, length: 0))
    let changed = permitted.insert("输入位置变化时也可直接粘贴。", target: fake, changed: true)
    precondition(!changed.needsPermission && changed.message.contains("输入位置已变化"))
    precondition(board.string(forType: .string) == "输入位置变化时也可直接粘贴。")
    print("PASS named pasteboard: denied permission and changed target retain result; no delayed rollback; general clipboard untouched")
}

private func verifyInputReadiness() {
    let board = NSPasteboard(name: NSPasteboard.Name("local.dictation.readiness.\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    let element = AXUIElementCreateApplication(-1)
    let ready = FocusTarget(pid: -1, element: element, selection: Selection(location: 2, length: 0))
    var current: FocusTarget? = nil, pid: pid_t = -1, valid = true, denied = false
    var pending: [() -> Void] = [], delays: [TimeInterval] = [], reads = 0, pastes = 0
    var result: DeliveryResult?
    let inserter = TextInserter(board: board, permissionCheck: { denied ? "TEST_PERMISSION_DENIED。" : nil },
        targetReader: { reads += 1; return current }, pasteKeySender: { _ in pastes += 1; return true },
        foregroundPID: { pid }, schedule: { delay, work in delays.append(delay); pending.append(work) })
    func begin() {
        let count = board.changeCount
        inserter.prepareCurrentInput(isCurrent: { valid }) { target in
            result = inserter.insert("fixture", target: target, changed: false, expectedClipboardChangeCount: count)
        }
    }
    func tick() { precondition(!pending.isEmpty); pending.removeFirst()() }
    func reset() {
        current = nil; pid = -1; valid = true; denied = false
        pending = []; delays = []; reads = 0; pastes = 0; result = nil
        board.clearContents(); _ = board.writeObjects(["previous" as NSString])
    }
    reset(); begin()
    precondition(result == nil && board.string(forType: .string) == "previous" && pastes == 0)
    current = ready; tick()
    precondition(result?.showHUD == false && pastes == 1 && pending.isEmpty)

    reset(); begin(); pid = -2; current = ready; tick()
    precondition(pastes == 0 && result?.message.contains("输入位置已变化") == true && pending.isEmpty)

    reset(); begin(); valid = false; current = ready; tick()
    precondition(pastes == 0 && result == nil && board.string(forType: .string) == "previous")

    reset(); begin()
    board.clearContents(); _ = board.writeObjects(["user-copy" as NSString])
    current = ready; tick()
    precondition(pastes == 0 && board.string(forType: .string) == "user-copy" && result?.showHUD == true)

    reset(); denied = true; begin()
    precondition(pending.isEmpty && reads == 0 && pastes == 0 && result?.needsPermission == true)

    reset(); begin(); tick(); tick(); tick()
    precondition(reads == 4 && delays == [0.1, 0.2, 0.4] && pending.isEmpty && pastes == 0 && result?.showHUD == true)

    reset(); current = ready
    inserter.prepareCurrentInput(isCurrent: { true }) { target in
        current = FocusTarget(pid: -1, element: element, selection: Selection(location: 3, length: 0))
        result = inserter.insert("fixture", target: target, changed: false)
    }
    precondition(pastes == 0 && result?.message.contains("输入位置已变化") == true)

    // The first IPC can identify a field while its selected range is not yet
    // available. Recovery must not adopt a different field in the same app.
    reset()
    let otherElement = AXUIElementCreateApplication(-2)
    var partialInserter: TextInserter!
    partialInserter = TextInserter(board: board, permissionCheck: { nil }, targetReader: {
        partialInserter.captureObservedElement = current?.element ?? element
        return current
    }, pasteKeySender: { _ in pastes += 1; return true }, foregroundPID: { -1 },
       schedule: { _, work in pending.append(work) })
    partialInserter.prepareCurrentInput(isCurrent: { true }) { target in
        result = partialInserter.insert("fixture", target: target, changed: false)
    }
    current = FocusTarget(pid: -1, element: otherElement, selection: ready.selection)
    tick()
    precondition(pastes == 0 && result?.message.contains("输入位置已变化") == true && pending.isEmpty)
    partialInserter = nil
    print("PASS input readiness: temporary failure recovers once; foreground/caret changes, cancellation, permission denial and clipboard ownership stop paste; retries bounded; no general clipboard access")
}

private func selfTest() throws {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    verifyClipboardFallback()
    verifyInputReadiness()
    let caret = Selection(location: 3, length: 0)
    let selectionCases: [(Selection?, Selection?, Bool)] = [(nil, nil, false), (nil, caret, false),
        (caret, nil, false), (caret, Selection(location: 4, length: 0), false), (caret, caret, true)]
    for (captured, current, expected) in selectionCases {
        guard Selection.matchesKnown(captured, current) == expected else {
            throw NSError(domain: "NativeSelectionSelfTest", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "未知或已变化的选区被允许回填。"])
        }
    }
    print("选区守卫验证通过：未知/已变化位置拒绝回填，仅明确相同位置允许。")
    precondition(DictationShortcut.functionKey.validationError == nil && DictationShortcut.functionKey.display == "Fn")
    precondition(DictationShortcut.defaultValue.display == "⌃⌥⌘Space")
    precondition(DictationShortcut(keyCode: 122, modifiers: UInt32(cmdKey)).display == "⌘F1")
    precondition(DictationShortcut(keyCode: 0, modifiers: UInt32(shiftKey)).validationError != nil)
    precondition(DictationShortcut(keyCode: 55, modifiers: UInt32(cmdKey)).validationError != nil)
    precondition(DictationShortcut(keyCode: 53, modifiers: UInt32(cmdKey)).validationError != nil)
    var fn = FunctionKeyGate()
    precondition(!fn.consume(type: .flagsChanged, keyCode: 63, flags: .maskSecondaryFn))
    precondition(!fn.consume(type: .flagsChanged, keyCode: 63, flags: .maskSecondaryFn))
    precondition(fn.consume(type: .flagsChanged, keyCode: 63, flags: []))
    precondition(!fn.consume(type: .flagsChanged, keyCode: 63, flags: []))
    precondition(!fn.consume(type: .flagsChanged, keyCode: 63, flags: .maskSecondaryFn))
    precondition(!fn.consume(type: .keyDown, keyCode: 49, flags: .maskSecondaryFn))
    precondition(!fn.consume(type: .flagsChanged, keyCode: 63, flags: []))
    precondition(!fn.consume(type: .flagsChanged, keyCode: 63, flags: [.maskSecondaryFn, .maskShift]))
    precondition(!fn.consume(type: .flagsChanged, keyCode: 63, flags: []))
    precondition(!fn.consume(type: .flagsChanged, keyCode: 63, flags: .maskSecondaryFn))
    precondition(!fn.consume(type: .flagsChanged, keyCode: 56, flags: [.maskSecondaryFn, .maskShift]))
    precondition(!fn.consume(type: .flagsChanged, keyCode: 63, flags: []))
    precondition(!fn.consume(type: .flagsChanged, keyCode: 63, flags: .maskSecondaryFn))
    fn.reset()
    precondition(!fn.consume(type: .flagsChanged, keyCode: 63, flags: []))
    precondition(!fn.consume(type: .flagsChanged, keyCode: 63, flags: .maskSecondaryFn))
    precondition(!fn.consume(type: .flagsChanged, keyCode: 0, flags: []))
    precondition(!fn.consume(type: .flagsChanged, keyCode: 63, flags: []))
    let fixture = Data("""
    {"raw_text":"那个，明天，明天下午三点开会。","text":"明天下午三点开会。","asr_seconds":0.2,"cleanup_seconds":0.1,"total_seconds":0.3,"cleanup_applied":true}
    """.utf8)
    let result = try JSONDecoder().decode(DictationResult.self, from: fixture)
    precondition(result.text == "明天下午三点开会。" && result.warning == nil && result.audio_seconds == nil)
    var preferences = DictationPreferences()
    preferences.cleanupEnabled = false; preferences.recognitionLanguage = "auto"; preferences.vocabulary = ["工作流", "Whisper"]
    let snapshot = DictationRequestOptions(preferences)
    preferences.cleanupEnabled = true; preferences.vocabulary = []
    let header = try snapshot.encoded().base64EncodedString()
    let options = try JSONSerialization.jsonObject(with: Data(base64Encoded: header)!) as! [String: Any]
    precondition(options["cleanup"] as? Bool == false && options["language"] as? String == "auto")
    precondition(options["vocabulary"] as? [String] == ["工作流", "Whisper"])
    var hotKey = HotKeyLatch()
    precondition(hotKey.shouldToggle(eventKind: UInt32(kEventHotKeyPressed)))
    precondition(!hotKey.shouldToggle(eventKind: UInt32(kEventHotKeyPressed)))
    precondition(!hotKey.shouldToggle(eventKind: UInt32(kEventHotKeyReleased)))
    precondition(hotKey.shouldToggle(eventKind: UInt32(kEventHotKeyPressed)))
    let loading = try JSONDecoder().decode(ServiceHealth.self, from: Data("""
    {"service":"local-dictation","status":"loading","ready":false,"asr_ready":false,"cleanup_ready":false,"busy":false,"message":"loading models","models":{}}
    """.utf8))
    precondition(!loading.asr_ready && loading.supports_options == nil && !loading.permitsRecording)
    precondition(loading.asrReadiness == .loading && loading.cleanupReadiness == .loading)
    let degraded = try JSONDecoder().decode(ServiceHealth.self, from: Data("""
    {"service":"local-dictation","status":"degraded","ready":true,"asr_ready":true,"cleanup_ready":false,"busy":false,"message":"cleanup unavailable","models":{},"supports_options":true}
    """.utf8))
    precondition(degraded.asr_ready && !degraded.cleanup_ready && degraded.permitsRecording)
    precondition(degraded.asrReadiness == .ready && degraded.cleanupReadiness == .unavailable)
    let oldService = try JSONDecoder().decode(ServiceHealth.self, from: Data("""
    {"service":"local-dictation","status":"ready","ready":true,"asr_ready":true,"cleanup_ready":true,"busy":false,"message":"ready"}
    """.utf8))
    precondition(oldService.ready && !oldService.permitsRecording)
    precondition(oldService.asrReadiness == .ready && oldService.cleanupReadiness == .ready && oldService.models == nil)
    let namedModels = try JSONDecoder().decode(ServiceHealth.self, from: Data("""
    {"service":"local-dictation","status":"ready","ready":true,"asr_ready":true,"cleanup_ready":true,"busy":true,"message":"busy","supports_options":true,"models":{"asr":"ASR-fixture","cleanup":"Qwen-fixture"}}
    """.utf8))
    precondition(!namedModels.permitsRecording && namedModels.asrReadiness == .ready && namedModels.cleanupReadiness == .ready)
    precondition(namedModels.models?["asr"] == "ASR-fixture" && namedModels.models?["cleanup"] == "Qwen-fixture")
    precondition(oldService.cleanup_backend == nil && oldService.cleanupBackend == .local)
    let cloudFixture = """
    {"service":"local-dictation","status":"ready","ready":true,"asr_ready":true,"cleanup_ready":true,"busy":false,"message":"configured","supports_options":true,"cleanup_backend":"cloud"}
    """
    let cloudService = try JSONDecoder().decode(ServiceHealth.self, from: Data(cloudFixture.utf8))
    precondition(cloudService.permitsRecording && cloudService.cleanupBackend == .cloud)
    precondition(cloudService.readyMessage.contains("已配置") && !cloudService.readyMessage.contains("连通"))
    let localService = try JSONDecoder().decode(ServiceHealth.self, from: Data(cloudFixture.replacingOccurrences(of: "\"cloud\"", with: "\"local\"").utf8))
    precondition(localService.cleanupBackend == .local)
    let futureService = try JSONDecoder().decode(ServiceHealth.self, from: Data(cloudFixture.replacingOccurrences(of: "\"cloud\"", with: "\"future\"").utf8))
    precondition(futureService.cleanupBackend == nil && futureService.readyMessage.contains("待确认"))
    var cleanupUI = DictationUIState()
    precondition(cleanupUI.homeProcessingDescription.contains("正在确认"))
    cleanupUI.cleanupBackend = .cloud
    precondition(cleanupUI.homeProcessingDescription.contains("本地识别，云端整理"))
    let cloudDetail = cleanupUI.cleanupSettingDescription(enabled: true)
    precondition(cloudDetail.contains("仅本次转写文本") && cloudDetail.contains("录音、历史记录和个人词典留在本机"))
    precondition(cloudDetail.contains("自然书面语") && cloudDetail.contains("适度分点"))
    cleanupUI.cleanupEnabled = false
    precondition(cleanupUI.homeProcessingDescription.contains("仅保留本地转写"))
    precondition(cleanupUI.cleanupSettingDescription(enabled: false).hasPrefix("文字整理已关闭，仅本地转写。"))
    cleanupUI.cleanupEnabled = true; cleanupUI.cleanupBackend = .local
    precondition(cleanupUI.homeProcessingDescription.contains("识别与整理都在本机完成"))
    var recovery = BackendRecoveryBudget()
    precondition(recovery.nextDelay(now: 100) == 1)
    precondition(recovery.nextDelay(now: 101) == 2)
    precondition(recovery.nextDelay(now: 102) == nil && recovery.isPaused)
    precondition(recovery.nextDelay(now: 500) == nil)
    recovery.reset()
    precondition(recovery.nextDelay(now: 500) == 1)
    precondition(recovery.nextDelay(now: 560) == 1)
    AppDelegate.verifyLateRecoveryCallbacks()
    AppDelegate.verifyModelHealthTransitions()
    try AppDelegate.verifyPromptModelReadiness()
    try AppDelegate.verifyConfigurationGuards()
    try AppDelegate.verifyPromptSnapshots()
    try AppDelegate.verifyUploadFailureRecovery()
    try AppDelegate.verifyStreamingQueue()
    try AppDelegate.verifyHistoryReprocessing()
    print("本地口述自检通过：Fn 元数据状态机、组合键校验、选项快照、版本能力、整理方式文案、焦点变化、权限拒绝、恢复预算、迟到回调。未录音、未监听按键、未请求权限、未发送按键、未启动后端。")
}

private func checkHealthCLI() -> Int32 {
    let done = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 1
    var request = URLRequest(url: serviceBase.appendingPathComponent("health"))
    request.timeoutInterval = 5
    URLSession.shared.dataTask(with: request) { data, response, error in
        if error == nil, let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
           let data, let health = try? JSONDecoder().decode(ServiceHealth.self, from: data), health.service == "local-dictation" {
            let cleanupState = health.cleanupBackend == .cloud ? "云端整理配置就绪" : health.cleanupBackend == .local ? "本地整理就绪" : "整理方式待确认，配置就绪"
            print("本地服务：\(health.status)，本地识别就绪：\(health.asr_ready)，\(cleanupState)：\(health.cleanup_ready)，支持词典与整理设置：\(health.supports_options == true)。")
            if health.supports_options != true { print("本地服务版本较旧，需更新服务后才能使用词典与整理设置。") }
            exitCode = health.permitsRecording ? 0 : 2
        } else { print("本地服务尚未连接：请先运行启动脚本。") }
        done.signal()
    }.resume()
    _ = done.wait(timeout: .now() + 7)
    return exitCode
}

@main
private struct LocalDictationApplication {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            do { try selfTest(); exit(0) }
            catch { fputs("本地口述自检失败：\(error.localizedDescription)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--check-health") { exit(checkHealthCLI()) }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
