import AppKit
import Carbon

struct FunctionKeyGate {
    private var held = false
    private var cancelled = false
    mutating func reset() { held = false; cancelled = false }
    mutating func consume(type: CGEventType, keyCode: Int64, flags: CGEventFlags) -> Bool {
        if type == .keyDown { if held { cancelled = true }; return false }
        guard type == .flagsChanged else { return false }
        let fn = flags.contains(.maskSecondaryFn)
        let other = !flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty
        if keyCode == 63 {
            if fn {
                if !held { held = true; cancelled = other } else if other { cancelled = true }
                return false
            }
            let fire = held && !cancelled && !other
            reset(); return fire
        }
        if held { if !fn { reset() } else { cancelled = true } }
        return false
    }
}

/// Passive observation of key metadata only. The event is always returned;
/// system actions and other dictation tools may also react to the same Fn key.
final class FunctionKeyMonitor {
    var onTrigger: (() -> Void)?
    var shouldTrigger: (() -> Bool)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var gate = FunctionKeyGate()
    private var generation = UUID()
    private var sleepObserver: NSObjectProtocol?
    var isEnabled: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }
    init() {
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main) { [weak self] _ in self?.resetCandidate() }
    }
    func start() -> String? {
        guard CGPreflightListenEventAccess() else { stop(); return "Fn 未启用，请允许输入监控后返回应用。" }
        if isEnabled { return nil }
        stop()
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue) | CGEventMask(1 << CGEventType.keyDown.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<FunctionKeyMonitor>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    monitor.resetCandidate()
                    if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                } else {
                    let fire = monitor.gate.consume(type: type, keyCode: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags)
                    // Capture state is checked before dispatch. Ending local
                    // shortcut capture must never re-arm this same Fn release.
                    if fire && monitor.shouldTrigger?() == true {
                        let generation = monitor.generation
                        DispatchQueue.main.async { [weak monitor] in
                            guard let monitor, monitor.generation == generation, monitor.isEnabled else { return }
                            monitor.onTrigger?()
                        }
                    }
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: context), let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0) else {
            return "Fn 未启用：无法建立监听，请检查输入监控权限或重新打开应用。"
        }
        tap = created; source = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        if !isEnabled { stop(); return "Fn 未启用：系统尚未允许监听，请检查权限后重试。" }
        return nil
    }
    func resetCandidate() { gate.reset(); generation = UUID() }
    func stop() {
        resetCandidate()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
    }
    deinit {
        stop()
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
    }
}

/// Labels follow the same physical key codes that Carbon registers, rather
/// than an editable saved label or text produced by an input method.
struct DictationShortcut: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    static let defaultValue = DictationShortcut(keyCode: 49, modifiers: 6400)
    static let functionKey = DictationShortcut(keyCode: 63, modifiers: 0)
    var isFunctionKey: Bool { keyCode == 63 && modifiers == 0 }
    static let allowedModifiers = UInt32(controlKey | optionKey | cmdKey | shiftKey)
    static let requiredModifiers = UInt32(controlKey | optionKey | cmdKey)
    var validationError: String? {
        if isFunctionKey { return nil }
        guard modifiers & Self.requiredModifiers != 0 else { return "请至少加上 ⌘、⌥ 或 ⌃ 中的一个修饰键。" }
        guard modifiers & ~Self.allowedModifiers == 0, Self.keyNames[keyCode] != nil else { return "这个按键暂不支持，请选择字母、数字、方向键或功能键。" }
        return nil
    }
    var display: String {
        if isFunctionKey { return "Fn" }
        return [(UInt32(controlKey), "⌃"), (UInt32(optionKey), "⌥"), (UInt32(shiftKey), "⇧"), (UInt32(cmdKey), "⌘")]
            .filter { modifiers & $0.0 != 0 }.map { $0.1 }.joined() + (Self.keyNames[keyCode] ?? "未知按键")
    }
    init(keyCode: UInt32, modifiers: UInt32) { self.keyCode = keyCode; self.modifiers = modifiers }
    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        let flags: [(NSEvent.ModifierFlags, UInt32)] = [(.control, UInt32(controlKey)), (.option, UInt32(optionKey)), (.shift, UInt32(shiftKey)), (.command, UInt32(cmdKey))]
        modifiers = flags.reduce(0) { result, item in result | (event.modifierFlags.contains(item.0) ? item.1 : 0) }
    }
    private static let keyNames: [UInt32: String] = [
        0:"A", 1:"S", 2:"D", 3:"F", 4:"H", 5:"G", 6:"Z", 7:"X", 8:"C", 9:"V", 10:"§", 11:"B", 12:"Q", 13:"W", 14:"E", 15:"R", 16:"Y", 17:"T",
        18:"1", 19:"2", 20:"3", 21:"4", 22:"6", 23:"5", 24:"=", 25:"9", 26:"7", 27:"−", 28:"8", 29:"0", 30:"]", 31:"O", 32:"U", 33:"[", 34:"I", 35:"P",
        36:"Return", 37:"L", 38:"J", 39:"'", 40:"K", 41:";", 42:"\\", 43:",", 44:"/", 45:"N", 46:"M", 47:".", 48:"Tab", 49:"Space", 50:"`", 51:"Delete",
        65:"小键盘 .", 67:"小键盘 ×", 69:"小键盘 +", 71:"Clear", 75:"小键盘 /", 76:"Enter", 78:"小键盘 −", 81:"小键盘 =", 82:"小键盘 0", 83:"小键盘 1", 84:"小键盘 2", 85:"小键盘 3", 86:"小键盘 4", 87:"小键盘 5", 88:"小键盘 6", 89:"小键盘 7", 91:"小键盘 8", 92:"小键盘 9", 93:"¥", 94:"_", 95:"小键盘 ,",
        96:"F5", 97:"F6", 98:"F7", 99:"F3", 100:"F8", 101:"F9", 103:"F11", 105:"F13", 106:"F16", 107:"F14", 109:"F10", 111:"F12", 113:"F15", 114:"Help", 115:"Home", 116:"Page Up", 117:"Forward Delete", 118:"F4", 119:"End", 120:"F2", 121:"Page Down", 122:"F1", 123:"←", 124:"→", 125:"↓", 126:"↑", 64:"F17", 79:"F18", 80:"F19", 90:"F20"
    ]
}

/// The existing shortcut label keeps its layout while a candidate is shown in
/// the same place. This view adds no key handling or focusable controls.
final class ShortcutCapturePresentationView: NSView {
    private let label: NSTextField
    private let candidateLabel = NSTextField(labelWithString: "")
    private(set) var isCapturing = false
    private(set) var candidate: String?
    init(label: NSTextField) {
        self.label = label
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        identifier = NSUserInterfaceItemIdentifier("shortcut-capture-presentation")
        candidateLabel.font = label.font; candidateLabel.textColor = Palette.blue
        candidateLabel.isHidden = true
        for item in [label, candidateLabel] {
            item.translatesAutoresizingMaskIntoConstraints = false; addSubview(item)
            NSLayoutConstraint.activate([
                item.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
                item.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
                item.topAnchor.constraint(equalTo: topAnchor, constant: 6),
                item.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
            ])
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present(capturing: Bool, candidate: String?) {
        let captureChanged = isCapturing != capturing
        let candidateChanged = self.candidate != candidate
        isCapturing = capturing; self.candidate = candidate
        candidateLabel.stringValue = candidate ?? ""
        candidateLabel.isHidden = !capturing || candidate == nil
        label.isHidden = !candidateLabel.isHidden
        needsDisplay = true
        if captureChanged { DictationMotion.reveal(self, duration: 0.1) }
        else if candidateChanged && !candidateLabel.isHidden { DictationMotion.reveal(candidateLabel, duration: 0.1) }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard isCapturing else { return }
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        Palette.blueWash.setFill(); outline.fill()
        Palette.blue.withAlphaComponent(0.45).setStroke(); outline.lineWidth = 1; outline.stroke()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { DictationMotion.cancel(self); DictationMotion.cancel(candidateLabel) }
    }
}

/// The local monitor exists only while recording and consumes events only for
/// this view's key window. No global monitor or event tap is installed.
final class ShortcutRecorderView: NSView {
    enum FeedbackState { case idle, capturing, candidate, invalid, applied, cancelled }
    var onCaptureChange: ((Bool) -> Void)?
    var onCandidate: ((DictationShortcut) -> String?)?
    var onFeedback: ((String) -> Void)?
    private(set) var isRecording = false
    private var pending: DictationShortcut?
    private var monitor: Any?
    private weak var previousResponder: NSResponder?
    private weak var presentation: ShortcutCapturePresentationView?
    private weak var feedbackLabel: NSTextField?
    private(set) var feedbackState: FeedbackState = .idle
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 0, height: 0) }
    func bindPresentation(_ view: ShortcutCapturePresentationView, feedback: NSTextField) {
        presentation = view; feedbackLabel = feedback
        view.present(capturing: isRecording, candidate: pending?.display)
    }
    private func publishFeedback(_ message: String, state: FeedbackState) {
        let changed = feedbackLabel.map { $0.stringValue != message || $0.textColor != feedbackColor(for: state) } ?? false
        feedbackState = state
        onFeedback?(message)
        presentation?.present(capturing: isRecording, candidate: pending?.display)
        if let feedbackLabel {
            feedbackLabel.stringValue = message; feedbackLabel.textColor = feedbackColor(for: state)
            if changed { DictationMotion.reveal(feedbackLabel, duration: 0.1) }
        }
    }
    private func feedbackColor(for state: FeedbackState) -> NSColor {
        switch state {
        case .invalid: return Palette.warning
        case .capturing, .candidate, .applied: return Palette.blue
        case .idle, .cancelled: return Palette.muted
        }
    }
    func begin() {
        guard !isRecording, let window else { return }
        previousResponder = window.firstResponder; isRecording = true; pending = nil
        onCaptureChange?(true); window.makeFirstResponder(self)
        publishFeedback("按下新组合，松开按键后保存；按 Esc 取消。", state: .capturing)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self, self.isRecording, event.window === self.window, self.window?.isKeyWindow == true else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.cancel(); return nil }
                if event.modifierFlags.contains(.function), event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                    self.pending = nil; self.publishFeedback("Fn 请单独按；组合键请使用 ⌘、⌥ 或 ⌃。", state: .invalid); return nil
                }
                if !event.isARepeat { self.capture(DictationShortcut(event: event)) }
            } else if event.type == .keyUp, UInt32(event.keyCode) == self.pending?.keyCode { self.commitPending() }
            else if event.type == .flagsChanged {
                if event.keyCode == 63 {
                    if event.modifierFlags.contains(.function) {
                        if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty { self.capture(.functionKey) }
                    } else if self.pending?.isFunctionKey == true { self.commitPending() }
                } else if self.pending?.isFunctionKey == true {
                    self.pending = nil
                    self.publishFeedback("Fn 请单独按；组合键请使用 ⌘、⌥ 或 ⌃。", state: .invalid)
                }
            }
            return nil
        }
    }
    func receiveRegisteredShortcut(_ shortcut: DictationShortcut, released: Bool) {
        guard isRecording else { return }
        if released { if pending == shortcut { commitPending() } }
        else { capture(shortcut) }
    }
    private func capture(_ shortcut: DictationShortcut) {
        if let error = shortcut.validationError { pending = nil; publishFeedback(error, state: .invalid); return }
        pending = shortcut; publishFeedback(shortcut.display + " · 松开按键后保存", state: .candidate)
    }
    private func commitPending() {
        guard let pending else { return }
        // Registration happens after release, so this captured press cannot
        // immediately trigger the new global shortcut or leave its latch held.
        finish()
        guard let onCandidate else { publishFeedback("当前不能修改快捷键。", state: .invalid); return }
        let result = onCandidate(pending)
        publishFeedback(result ?? "已生效：" + pending.display, state: result == nil ? .applied : .invalid)
    }
    func cancel() {
        guard isRecording else { return }
        finish(); publishFeedback("已取消修改，原快捷键保持不变。", state: .cancelled)
    }
    private func finish() {
        isRecording = false; pending = nil
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if window?.firstResponder === self { window?.makeFirstResponder(previousResponder) }
        previousResponder = nil; onCaptureChange?(false)
        presentation?.present(capturing: false, candidate: nil)
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
