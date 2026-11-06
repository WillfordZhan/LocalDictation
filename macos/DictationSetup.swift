import AppKit
import AVFoundation
import ApplicationServices
import Darwin

struct InstallationCheck: Decodable {
    let id: String
    let status: String
    let message: String
}
struct InstallationReport: Decodable {
    let schema: Int
    let ready: Bool
    let blocked: Bool
    let can_download: Bool
    let checks: [InstallationCheck]
    let required_download_bytes: Int64?
    let download_block_reason: String?
    let asr_backend: String?
}
struct ModelDownloadEvent: Decodable {
    let schema: Int
    let event: String
    let operation: String?
    let model_id: String?
    let completed_bytes: Int64?
    let total_bytes: Int64?
    let message: String?
    let ready: Bool?
}

/// JSONL consumers discard complete lines. Neither a long download nor a
/// broken writer omitting newlines can grow the UI process without a bound.
struct SetupProcessOutput {
    static let lineLimit = 128 * 1024
    static let reportLimit = 1024 * 1024
    let streaming: Bool
    private(set) var output = Data()
    private var pending = Data()
    private(set) var lastEvent: ModelDownloadEvent?
    private(set) var failure: String?
    // Keep construction independent of compiler-specific memberwise access
    // inference for the private streaming buffer.
    init(streaming: Bool) { self.streaming = streaming }
    var retainedByteCount: Int { output.count + pending.count }
    mutating func append(_ chunk: Data) -> [ModelDownloadEvent] {
        guard failure == nil else { return [] }
        if !streaming {
            guard output.count + chunk.count <= Self.reportLimit else { failure = "检查结果过大，已停止读取。请重新检查后重试。"; output.removeAll(); return [] }
            output.append(chunk); return []
        }
        pending.append(chunk)
        var events: [ModelDownloadEvent] = []
        while let newline = pending.firstIndex(of: 10) {
            let line = Data(pending[..<newline]); pending.removeSubrange(...newline)
            if let event = decode(line) { events.append(event) }
            if failure != nil { pending.removeAll(); break }
        }
        if pending.count > Self.lineLimit { failure = "模型任务返回的数据格式异常，请重新检查后重试。"; pending.removeAll() }
        return events
    }
    mutating func finish() -> ModelDownloadEvent? {
        guard streaming, failure == nil, !pending.isEmpty else { return nil }
        let line = pending; pending.removeAll(); return decode(line)
    }
    private mutating func decode(_ line: Data) -> ModelDownloadEvent? {
        if line.isEmpty { return nil }
        guard line.count <= Self.lineLimit, let event = try? JSONDecoder().decode(ModelDownloadEvent.self, from: line),
              event.schema == 1, ["start", "progress", "verified", "complete", "error", "cancelled"].contains(event.event) else {
            failure = "模型任务返回的数据格式异常，请重新检查后重试。"; return nil
        }
        lastEvent = event; return event
    }
}

private final class SetupDocumentView: NSView { override var isFlipped: Bool { true } }

/// Setup reads installation metadata only. Downloads and preferences live
/// outside the application; no history, audio or clipboard is inspected here.
final class DictationSetupWindowController: NSWindowController, NSWindowDelegate {
    var onReady: (() -> Void)?
    var onMicrophone: (() -> Void)?
    var onAccessibility: (() -> Void)?
    var onInputMonitoring: (() -> Void)?
    var canConfigure: () -> Bool = { true }
    var prepareDownload: ((@escaping (Bool) -> Void) -> Void)?
    var onDownloadFinished: (() -> Void)?
    private let runtime: URL
    private let resources: URL
    private let message = NSTextField(wrappingLabelWithString: "检查这台 Mac 的运行环境与模型。")
    private let rows = NSStackView()
    private let progress = NSProgressIndicator()
    private let configure = NSButton(title: "一键配置", target: nil, action: nil)
    private let download = NSButton(title: "下载模型", target: nil, action: nil)
    private let check = NSButton(title: "检查配置", target: nil, action: nil)
    private let cancel = NSButton(title: "取消", target: nil, action: nil)
    private let microphone = NSButton(title: "允许麦克风…", target: nil, action: nil)
    private let insertion = NSButton(title: "允许自动填入…", target: nil, action: nil)
    private let monitoring = NSButton(title: "允许 Fn 快捷键…", target: nil, action: nil)
    private var process: Process?
    private var generation = UUID()
    private var busy = false
    private var cancelled = false
    private var report: InstallationReport?
    private enum CheckIntent { case check, prepare, verifyDownload }
    private var activeASR = "qwen"
    private var downloadLease = false
    private var shuttingDown = false
    private var fraction: Double?
    private var motionObserver: NSObjectProtocol?
    private var processFailure: String?
    var pythonURL: URL { resources.appendingPathComponent("Python/bin/python3") }
    private var backend: URL { resources.appendingPathComponent("backend") }

    init(runtime: URL, resources: URL) {
        self.runtime = runtime; self.resources = resources
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "模型与配置"; window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 640)
        window.backgroundColor = .white; window.appearance = NSAppearance(named: .aqua)
        super.init(window: window); window.delegate = self
        build(); window.center()
        motionObserver = NotificationCenter.default.addObserver(forName: DictationMotion.policyDidChange, object: nil, queue: .main) { [weak self] _ in self?.updateProgress() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let motionObserver { NotificationCenter.default.removeObserver(motionObserver) } }
    private func build() {
        guard let root = window?.contentView else { return }
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.detachesHiddenViews = false
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
                                     stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
                                     stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
                                     stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -28)])
        let title = NSTextField(labelWithString: "准备好，就可以开始说了。")
        title.font = .systemFont(ofSize: 24, weight: .semibold); title.textColor = Palette.ink
        message.font = .systemFont(ofSize: 13); message.textColor = Palette.secondary
        message.maximumNumberOfLines = 3; message.lineBreakMode = .byTruncatingTail
        message.identifier = NSUserInterfaceItemIdentifier("setup-message")
        stack.addArrangedSubview(title); stack.addArrangedSubview(message)
        message.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 14
        rows.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        scroll.identifier = NSUserInterfaceItemIdentifier("setup-checks-scroll")
        let document = SetupDocumentView(); document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document; document.addSubview(rows)
        NSLayoutConstraint.activate([document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 4), rows.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -4),
            rows.topAnchor.constraint(equalTo: document.topAnchor, constant: 8), rows.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8)])
        stack.addArrangedSubview(scroll); scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        scroll.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        progress.style = .bar; progress.isIndeterminate = true; progress.minValue = 0; progress.maxValue = 1
        stack.addArrangedSubview(progress); progress.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let actions = NSStackView(views: [configure, download, check, cancel]); actions.spacing = 8
        stack.addArrangedSubview(actions)
        let separator = NSBox(); separator.boxType = .separator; stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let permissionTitle = NSTextField(labelWithString: "系统权限"); permissionTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        stack.addArrangedSubview(permissionTitle)
        let permissions = NSStackView(views: [microphone, insertion, monitoring]); permissions.spacing = 8
        permissions.distribution = .fillEqually
        stack.addArrangedSubview(permissions)
        permissions.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let storage = NSTextField(wrappingLabelWithString: "模型、历史与规则保存在这台 Mac 上，更新应用后仍会保留。")
        storage.font = .systemFont(ofSize: 12); storage.textColor = Palette.muted
        stack.addArrangedSubview(storage); storage.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        for button in [configure, download, check, cancel, microphone, insertion, monitoring] {
            button.bezelStyle = .rounded; button.target = self; button.font = .systemFont(ofSize: 13)
        }
        configure.bezelColor = Palette.blue; configure.contentTintColor = .white
        configure.action = #selector(prepareAll); download.action = #selector(prepareAll)
        check.action = #selector(checkOnly); cancel.action = #selector(cancelWork)
        microphone.action = #selector(allowMicrophone); insertion.action = #selector(allowInsertion)
        monitoring.action = #selector(allowMonitoring)
        for (button, id) in [(configure, "configure"), (download, "download"), (check, "check"), (cancel, "cancel"), (microphone, "microphone"), (insertion, "insertion"), (monitoring, "monitoring")] {
            button.identifier = NSUserInterfaceItemIdentifier("setup-" + id)
        }
        for view in stack.arrangedSubviews where view !== scroll { view.setContentHuggingPriority(.required, for: .vertical) }
        progress.identifier = NSUserInterfaceItemIdentifier("setup-progress")
        cancel.isHidden = true; progress.isHidden = true; download.isEnabled = false; refreshPermissions()
    }
    func present() {
        guard !shuttingDown else { return }
        showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if !busy { checkConfiguration(intent: .check) }
    }
    func windowDidBecomeKey(_ notification: Notification) { refreshPermissions() }
    // Closing the window keeps the requested download running; Cancel stops it.
    func shutdown() {
        guard !shuttingDown else { return }
        shuttingDown = true; cancelled = true; DictationMotion.cancel(rows)
        if let process { terminate(process) } else { releaseDownload() }
    }
    private func refreshPermissions() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        microphone.title = mic ? "麦克风已允许" : "允许麦克风…"; microphone.isEnabled = !mic
        let paste = AXIsProcessTrusted() && CGPreflightPostEventAccess()
        insertion.title = paste ? "自动填入已允许" : "允许自动填入…"; insertion.isEnabled = !paste
        let fn = CGPreflightListenEventAccess()
        monitoring.title = fn ? "Fn 已允许" : "允许 Fn 快捷键…"; monitoring.isEnabled = !fn
    }
    @objc private func allowMicrophone() { onMicrophone?() }
    @objc private func allowInsertion() { onAccessibility?() }
    @objc private func allowMonitoring() { onInputMonitoring?() }
    @objc private func checkOnly() { checkConfiguration(intent: .check) }
    @objc private func prepareAll() {
        guard !busy, !shuttingDown else { return }
        guard canConfigure() else { message.stringValue = "本次口述结束后再配置，当前录音与结果会保留。"; return }
        checkConfiguration(intent: .prepare)
    }
    @objc private func cancelWork() {
        guard busy else { return }
        cancelled = true; cancel.isEnabled = false; message.stringValue = "正在取消，已完成的文件会保留供重试…"
        if let process { terminate(process) }
    }
    private func setBusy(_ value: Bool, _ text: String) {
        busy = value; message.stringValue = text
        message.toolTip = text
        configure.isEnabled = !value && !shuttingDown
        download.isEnabled = !value && !shuttingDown && report?.can_download == true && report?.blocked == false
        check.isEnabled = !value && !shuttingDown
        cancel.isHidden = !value; cancel.isEnabled = value
        fraction = nil; updateProgress()
    }
    private func updateProgress() {
        progress.stopAnimation(nil); progress.isHidden = !busy
        progress.isIndeterminate = busy && fraction == nil && !DictationMotion.reduceMotion
        progress.doubleValue = fraction ?? 0
        if progress.isIndeterminate { progress.startAnimation(nil) }
    }
    private func finishWork(_ text: String) { setBusy(false, text); releaseDownload() }
    private func releaseDownload() {
        guard downloadLease else { return }; downloadLease = false; onDownloadFinished?()
    }
    private func checkConfiguration(intent: CheckIntent) {
        guard (!busy || intent == .verifyDownload), !shuttingDown else { return }
        if intent != .verifyDownload { cancelled = false }
        guard FileManager.default.isExecutableFile(atPath: pythonURL.path) else {
            finishWork("安装包缺少内置运行环境，请重新下载完整应用。"); return
        }
        setBusy(true, "正在检查运行环境与模型…")
        // Diagnose the stored selection rather than silently replacing an
        // invalid value with a default. Downloads freeze the diagnosed choice.
        run("diagnose.py", arguments: ["--installation", "--json", "--runtime-dir", runtime.path,
                                       "--python-bin", pythonURL.path]) { [weak self] status, output, _, failure in
            guard let self else { return }
            if self.shuttingDown { self.releaseDownload(); return }
            if self.cancelled { self.finishWork("已取消，可随时重新检查。"); return }
            guard failure == nil, status == 0, let report = try? JSONDecoder().decode(InstallationReport.self, from: output),
                  report.schema == 1, report.checks.count <= 128 else {
                self.finishWork(failure ?? "检查未完成（退出码 \(status)），请重新检查或重新安装完整应用。"); return
            }
            self.report = report
            if let selected = report.asr_backend, ["qwen", "whisper"].contains(selected) { self.activeASR = selected }
            self.render(report)
            switch intent {
            case .check:
                self.finishWork(report.ready ? "运行环境与模型已就绪。" : report.can_download ? "检查完成，可继续配置模型。" : report.download_block_reason ?? "请先处理上方的运行环境问题。")
            case .prepare:
                if report.ready { self.finishPreparation() }
                else if report.blocked || !report.can_download { self.finishWork(report.download_block_reason ?? "请先处理上方的运行环境问题，再配置模型。") }
                else { self.downloadModels() }
            case .verifyDownload:
                // One click performs at most one model task. A failed final
                // check stays actionable instead of entering a download loop.
                if report.ready { self.finishPreparation() }
                else { self.finishWork("模型任务已结束，但配置仍未通过检查。请查看上方结果后重试。"); }
            }
        }
    }
    private func render(_ report: InstallationReport) {
        for view in rows.arrangedSubviews { rows.removeArrangedSubview(view); view.removeFromSuperview() }
        for item in report.checks {
            let icon = NSImageView(image: NSImage(systemSymbolName: item.status == "ok" ? "checkmark.circle.fill" : "circle.dashed", accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = item.status == "ok" ? Palette.blue : Palette.muted
            icon.widthAnchor.constraint(equalToConstant: 18).isActive = true; icon.heightAnchor.constraint(equalToConstant: 18).isActive = true
            let text = NSTextField(wrappingLabelWithString: item.message); text.font = .systemFont(ofSize: 13)
            text.textColor = item.status == "invalid" ? .systemOrange : Palette.secondary
            let row = NSStackView(views: [icon, text]); row.spacing = 10; row.alignment = .top
            rows.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            text.widthAnchor.constraint(equalTo: row.widthAnchor, constant: -28).isActive = true
        }
        download.title = (report.required_download_bytes ?? 0) > 0 ? "下载模型" : "校验模型"; DictationMotion.reveal(rows)
    }
    private func downloadModels() {
        guard canConfigure(), report?.blocked == false, report?.can_download == true else { finishWork("本次口述结束后再配置模型。"); return }
        if let needed = report?.required_download_bytes, needed > 0,
           let values = try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let free = values.volumeAvailableCapacityForImportantUsage {
            let requirement = needed.addingReportingOverflow(512 * 1024 * 1024)
            if requirement.overflow || free < requirement.partialValue { finishWork("磁盘空间不足，请腾出空间后重试。"); return }
        }
        guard let prepareDownload else { finishWork("暂时无法安全配置模型，请重新打开应用后重试。"); return }
        setBusy(true, "正在准备模型配置，等待本地服务安全退出…")
        downloadLease = true; let token = UUID(); generation = token
        prepareDownload { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                if self.shuttingDown { self.releaseDownload(); return }
                if self.cancelled { self.finishWork("已取消，模型与记录保持不变。"); return }
                guard allowed, self.canConfigure() else { self.finishWork("当前服务无法安全停止。请结束口述或关闭其他本地服务后重试。"); return }
                self.startModelTask()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.generation == token, self.process == nil, self.busy, !self.shuttingDown else { return }
            self.generation = UUID(); self.finishWork("等待本地服务退出超时，请稍后重新配置。");
        }
    }
    private func startModelTask() {
        setBusy(true, "正在配置模型，完整文件会直接复用。关闭窗口后仍会继续。")
        run("download_models.py", arguments: ["--models-dir", runtime.appendingPathComponent("models").path,
                                              "--asr-backend", activeASR, "--json-events"], events: { [weak self] event in
            guard let self, !self.cancelled else { return }
            if event.event == "start" { self.fraction = nil; self.updateProgress() }
            if event.event == "verified" || event.event == "complete" {
                self.fraction = 1; self.updateProgress()
                self.message.stringValue = event.message ?? "模型已完成校验。"
            } else if let total = event.total_bytes, total > 0, let done = event.completed_bytes {
                self.fraction = min(1, max(0, Double(done) / Double(total))); self.updateProgress()
                let action = event.operation == "verify" ? "正在校验模型" : event.operation == "download" ? "正在下载模型" : "正在配置模型"
                self.message.stringValue = action + " · " + ByteCountFormatter.string(fromByteCount: max(0, done), countStyle: .file)
                    + " / " + ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            } else if let text = event.message { self.message.stringValue = text }
            self.message.toolTip = self.message.stringValue
        }) { [weak self] status, _, event, failure in
            guard let self else { return }
            if self.shuttingDown { self.releaseDownload(); return }
            if self.cancelled || status == 130 { self.finishWork("已取消。已完成的文件已保留，可再次重试。"); return }
            guard failure == nil, status == 0, event?.event == "complete", event?.ready == true else {
                // A final progress/verified event is not completion. Only an
                // explicit error may supply the failure explanation.
                let problem = failure ?? (event?.event == "error" ? event?.message : nil) ?? "模型任务未完成，请检查网络后重试。"
                self.finishWork(problem + " 已完成的文件已保留，可再次重试。"); return
            }
            self.checkConfiguration(intent: .verifyDownload)
        }
    }
    private func finishPreparation() {
        guard !cancelled, !shuttingDown, canConfigure() else { finishWork("模型已就绪，本次口述结束后可再次完成配置。"); return }
        do {
            try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
            let selection = runtime.appendingPathComponent("asr-backend")
            if !FileManager.default.fileExists(atPath: selection.path) { try (activeASR + "\n").write(to: selection, atomically: true, encoding: .utf8) }
            finishWork("模型已就绪，正在启动本地服务。"); onReady?(); refreshPermissions()
        } catch { finishWork("无法保存配置：" + error.localizedDescription) }
    }
    private func terminate(_ child: Process) {
        guard child.isRunning else { return }
        child.terminate()
        // Let an active file operation close before reclaiming a stuck worker.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
        }
    }
    /// Spawn before returning to the run loop, then read pipes off-thread. A
    /// cancellation cannot miss a queued launch, and retry waits for exit.
    private func run(_ script: String, arguments: [String], events: ((ModelDownloadEvent) -> Void)? = nil,
                     completion: @escaping (Int32, Data, ModelDownloadEvent?, String?) -> Void) {
        let token = UUID(); generation = token; processFailure = nil
        let child = Process(); process = child
        child.executableURL = pythonURL; child.arguments = ["-B", backend.appendingPathComponent(script).path] + arguments
        var env = ProcessInfo.processInfo.environment
        for name in ["PYTHONPATH", "PYTHONHOME", "VIRTUAL_ENV", "HF_HUB_OFFLINE", "TRANSFORMERS_OFFLINE"] { env.removeValue(forKey: name) }
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"; env["PYTHONNOUSERSITE"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"; env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        env["HF_HOME"] = runtime.appendingPathComponent("huggingface-cache").path
        child.environment = env; child.standardInput = FileHandle.nullDevice
        let pipe = Pipe(); child.standardOutput = pipe; child.standardError = FileHandle.nullDevice
        do { try child.run() }
        catch { process = nil; completion(-1, Data(), nil, "无法运行配置任务：" + error.localizedDescription); return }
        let deadline = DispatchWorkItem { [weak self, weak child] in
            guard let self, let child, self.generation == token, child.isRunning else { return }
            self.processFailure = "检查超时，已停止任务。请重新检查后重试。"; self.terminate(child)
        }
        if events == nil { DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: deadline) }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var buffer = SetupProcessOutput(streaming: events != nil)
            var readFailure: String?
            do {
                // FileHandle.read(upToCount:) may wait to fill the requested
                // length on a Darwin pipe. One POSIX read delivers each small
                // JSONL write immediately, while still bounding every chunk.
                var bytes = [UInt8](repeating: 0, count: 16_384)
                let descriptor = pipe.fileHandleForReading.fileDescriptor
                while true {
                    let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, $0.count) }
                    if count == 0 { break }
                    if count < 0 {
                        let code = errno
                        if code == EINTR { continue }
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
                    }
                    let decoded = buffer.append(Data(bytes.prefix(count)))
                    if let event = decoded.last {
                        // Backpressure bounds queued UI updates as well as bytes.
                        DispatchQueue.main.sync { [weak self] in
                            guard self?.generation == token, self?.shuttingDown == false else { return }; events?(event)
                        }
                    }
                    if buffer.failure != nil { break }
                }
                if let event = buffer.finish() {
                    DispatchQueue.main.sync { [weak self] in if self?.generation == token && self?.shuttingDown == false { events?(event) } }
                }
            } catch { readFailure = "无法读取配置结果：" + error.localizedDescription }
            if buffer.failure != nil || readFailure != nil { DispatchQueue.main.sync { [weak self] in self?.terminate(child) } }
            try? pipe.fileHandleForReading.close()
            child.waitUntilExit()
            let finalCode = child.terminationStatus, finalOutput = buffer.output
            let finalEvent = buffer.lastEvent, finalFailure = buffer.failure ?? readFailure
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                deadline.cancel(); self.process = nil
                completion(finalCode, finalOutput, finalEvent, finalFailure ?? self.processFailure)
            }
        }
    }
}
