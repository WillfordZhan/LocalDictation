import AppKit
import Darwin

/// Real native controls and child-process pipes, with a temporary fake Python
/// executable. No production runtime, network, model or permission is touched.
@main
enum DictationSetupChecks {
    static var checks = 0
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw NSError(domain: "DictationSetupChecks", code: checks, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func find<T: NSView>(_ id: String, in root: NSView, as type: T.Type = T.self) throws -> T {
        let found = descendants(root).filter { $0.identifier?.rawValue == id }.compactMap { $0 as? T }
        try require(found.count == 1, "Expected one \(id), found \(found.count)"); return found[0]
    }
    @discardableResult static func wait(_ message: String, timeout: TimeInterval = 4, until condition: () -> Bool) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        try require(condition(), "Timed out: " + message); return true
    }
    static func snapshot(_ root: NSView, name: String) throws {
        guard let index = CommandLine.arguments.firstIndex(of: "--render"), CommandLine.arguments.indices.contains(index + 1) else { return }
        let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.18)); root.layoutSubtreeIfNeeded()
        for button in descendants(root).compactMap({ $0 as? NSButton }) where !button.isHidden {
            try require(button.bounds.width > 40 && button.bounds.height >= 18, "Setup button collapsed: " + button.title + " " + NSStringFromRect(button.bounds))
        }
        root.wantsLayer = true; root.layer?.backgroundColor = NSColor.white.cgColor
        root.displayIfNeeded()
        // The hidden window first creates native control layers on display.
        // Allow their presentation to catch up before capturing the final UI.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3)); root.displayIfNeeded()
        guard let image = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { throw NSError(domain: "Capture", code: 1) }
        root.cacheDisplay(in: root.bounds, to: image)
        guard let data = image.representation(using: .png, properties: [:]) else { throw NSError(domain: "Capture", code: 2) }
        try data.write(to: directory.appendingPathComponent(name))
        if CommandLine.arguments.contains("--windowserver"), name == "setup-progress.png", let window = root.window {
            window.orderFrontRegardless()
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l", String(window.windowNumber), directory.appendingPathComponent("setup-progress-window.png").path]
            try capture.run(); capture.waitUntilExit(); window.orderOut(nil)
            try require(capture.terminationStatus == 0, "Fixture WindowServer capture failed")
        }
    }
    final class Fixture {
        let directory: URL, runtime: URL, resources: URL
        let controller: DictationSetupWindowController
        let root: NSView
        let configure: NSButton, download: NSButton, check: NSButton, cancel: NSButton
        let cleanup: NSPopUpButton, asr: NSPopUpButton
        let message: NSTextField, progress: NSProgressIndicator
        var prepared = 0, released = 0, ready = 0
        var activity: [Bool] = []
        init(savedCleanup: String? = nil, selectionKind: String? = nil, savedASR: String? = nil,
             writeSelection: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-setup-check-" + UUID().uuidString)
            runtime = directory.appendingPathComponent("Runtime"); resources = directory.appendingPathComponent("Resources")
            let bin = resources.appendingPathComponent("Python/bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: resources.appendingPathComponent("backend"), withIntermediateDirectories: true)
            let executable = bin.appendingPathComponent("python3")
            let script = #"""
            #!/bin/bash
            set -eu
            base="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
            printf '%s\n' "$2" >> "$base/invocations"
            printf '%s\n' "$@" > "$base/${2##*/}.args"
            trap 'exit 130' TERM INT
            if [[ "$2" == */diagnose.py ]]; then
              /bin/cat "$base/report.json"
              exit 0
            fi
            /bin/cat "$base/events.jsonl"
            mode="$(/bin/cat "$base/mode")"
            if [[ "$mode" == error ]]; then exit 1; fi
            if [[ "$mode" == hold ]]; then
              while [[ ! -f "$base/release" ]]; do
                if [[ -f "$base/supplement" ]]; then /bin/cat "$base/supplement"; /bin/rm "$base/supplement"; fi
                /bin/sleep 0.05
              done
            fi
            if [[ "$mode" == success ]]; then /bin/cp "$base/ready.json" "$base/report.json"; fi
            printf '%s\n' '{"schema":1,"event":"complete","ready":true}'
            """#
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            if let savedCleanup {
                try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
                try (savedCleanup + "\n").write(to: runtime.appendingPathComponent("cleanup-model"), atomically: true, encoding: .utf8)
            }
            if let savedASR {
                try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
                try (savedASR + "\n").write(to: runtime.appendingPathComponent("asr-backend"), atomically: true, encoding: .utf8)
            }
            if let selectionKind {
                try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
                let selection = runtime.appendingPathComponent("cleanup-model")
                switch selectionKind {
                case "symlink":
                    let target = directory.appendingPathComponent("linked-selection")
                    try "cleanup-9b\n".write(to: target, atomically: true, encoding: .utf8)
                    try FileManager.default.createSymbolicLink(at: selection, withDestinationURL: target)
                case "fifo": try require(mkfifo(selection.path, 0o600) == 0, "Could not create isolated FIFO fixture")
                default: try FileManager.default.createDirectory(at: selection, withIntermediateDirectories: true)
                }
            }
            controller = DictationSetupWindowController(runtime: runtime, resources: resources, writeSelection: writeSelection)
            root = controller.window!.contentView!
            configure = try find("setup-configure", in: root)
            download = try find("setup-download", in: root)
            check = try find("setup-check", in: root)
            cancel = try find("setup-cancel", in: root)
            cleanup = try find("setup-cleanup-model", in: root)
            asr = try find("setup-asr-model", in: root)
            message = try find("setup-message", in: root)
            progress = try find("setup-progress", in: root)
            controller.prepareDownload = { [weak self] done in self?.prepared += 1; done(true) }
            controller.onDownloadFinished = { [weak self] in self?.released += 1 }
            controller.onReady = { [weak self] in self?.ready += 1 }
            controller.onConfigurationActivity = { [weak self] active in self?.activity.append(active) }
            try report(ready: false)
            try report(ready: true, filename: "ready.json")
            try mode("hold")
        }
        func report(ready: Bool, filename: String = "report.json", long: Bool = false, blocked: String? = nil, asr: String = "qwen", cleanup: String = "cleanup", serviceBusy: Bool = false) throws {
            let row: [String: Any] = ["id": "model", "status": ready ? "ok" : "missing",
                "message": long ? String(repeating: "模型校验与运行环境示例，完整文件会直接复用。", count: 8) : ready ? "本机运行环境与模型已就绪。" : "尚未下载语音识别与文字整理模型。"]
            var report: [String: Any] = ["schema": 1, "ready": ready, "blocked": false, "can_download": !ready && blocked == nil,
                "checks": long ? (0..<12).map { index -> [String: Any] in var copy = row; copy["id"] = "row-\(index)"; return copy } : [row],
                "required_download_bytes": ready ? 0 : 100, "cleanup_model": cleanup, "service_busy": serviceBusy]
            if let blocked { report["download_block_reason"] = blocked }
            report["asr_backend"] = asr
            try JSONSerialization.data(withJSONObject: report).write(to: resources.appendingPathComponent(filename))
        }
        func mode(_ value: String) throws {
            try value.write(to: resources.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
            let event = value == "error" ? #"{"schema":1,"event":"error","message":"模型下载失败：测试网络不可用。"}"#
                : #"{"schema":1,"event":"progress","operation":"download","completed_bytes":40,"total_bytes":100}"#
            try (event + "\n").write(to: resources.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)
        }
        func calls(_ script: String) -> Int {
            ((try? String(contentsOf: resources.appendingPathComponent("invocations"), encoding: .utf8)) ?? "")
                .split(separator: "\n").filter { $0.hasSuffix("/" + script + ".py") }.count
        }
        var savedCleanup: String? { try? String(contentsOf: runtime.appendingPathComponent("cleanup-model"), encoding: .utf8) }
        var savedASR: String? { try? String(contentsOf: runtime.appendingPathComponent("asr-backend"), encoding: .utf8) }
        func choose(_ choice: CleanupModelChoice) {
            cleanup.selectItem(at: CleanupModelChoice.allCases.firstIndex(of: choice)!)
            NSApp.sendAction(cleanup.action!, to: cleanup.target, from: cleanup)
        }
        func chooseASR(_ choice: ASRModelChoice) {
            asr.selectItem(at: ASRModelChoice.allCases.firstIndex(of: choice)!)
            NSApp.sendAction(asr.action!, to: asr.target, from: asr)
        }
        func argument(_ name: String, script: String) throws -> String? {
            let args = try String(contentsOf: resources.appendingPathComponent(script + ".py.args"), encoding: .utf8).split(separator: "\n").map(String.init)
            return args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        func releaseWorker() throws { try Data().write(to: resources.appendingPathComponent("release")) }
        func send(_ event: String) throws {
            let file = resources.appendingPathComponent("supplement")
            try (event + "\n").write(to: file, atomically: true, encoding: .utf8)
            try wait("worker consumed extra event") { !FileManager.default.fileExists(atPath: file.path) }
        }
        func dispose() {
            controller.shutdown(); controller.window?.close()
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            try? FileManager.default.removeItem(at: directory)
        }
    }
    static func main() {
        do { try run(); let visibility = CommandLine.arguments.contains("--windowserver") ? "one isolated fixture shown for capture" : "hidden windows"; print("PASS: \(checks) native Setup checks; temporary fake executable, \(visibility), no network or production data") }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func run() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        DictationMotion.reduceMotionOverride = false
        defer { DictationMotion.reduceMotionOverride = nil }
        try parserBounds()
        try missingProgressAndCancellation()
        try readyAndLayout()
        try errorsAndFinalVerification()
        try pendingCancellationAndSafety()
        try asrChoiceFreeze()
        try cleanupModelDownloadsAndPersistence()
        try readyCleanupSwitchAndSafety()
        try cleanupSwitchFailures()
        try externalModelConfiguration()
        try externalFailureAndCancellation()
        try selectionSaveRollback()
        try closeAndShutdown()
    }
    static func parserBounds() throws {
        let line = Data((#"{"schema":1,"event":"progress","completed_bytes":40,"total_bytes":100}"# + "\n").utf8)
        var stream = SetupProcessOutput(streaming: true)
        for _ in 0..<25000 { _ = stream.append(line) }
        try require(stream.failure == nil && stream.retainedByteCount == 0 && stream.lastEvent?.event == "progress", "Streaming output accumulated completed lines")
        var oversized = SetupProcessOutput(streaming: true)
        _ = oversized.append(Data(repeating: 65, count: SetupProcessOutput.lineLimit + 1))
        try require(oversized.failure != nil && oversized.retainedByteCount == 0, "Oversized JSONL line was not bounded")
        var final = SetupProcessOutput(streaming: true)
        _ = final.append(Data(#"{"schema":1,"event":"complete","ready":true}"#.utf8))
        try require(final.finish()?.ready == true && final.lastEvent?.event == "complete" && final.retainedByteCount == 0, "Final line without newline was lost")
        var malformed = SetupProcessOutput(streaming: true)
        _ = malformed.append(Data("not-json\n".utf8))
        try require(malformed.failure != nil, "Malformed JSONL was silently ignored")
        var report = SetupProcessOutput(streaming: false)
        _ = report.append(Data(repeating: 65, count: SetupProcessOutput.reportLimit + 1))
        try require(report.failure != nil && report.retainedByteCount == 0, "Installation report grew without a bound")
    }
    static func missingProgressAndCancellation() throws {
        let f = try Fixture(); defer { f.dispose() }
        if CommandLine.arguments.contains("--windowserver") { f.controller.present() }
        else { f.check.performClick(nil) }
        try wait("missing report") { f.check.isEnabled && f.message.stringValue.contains("检查完成") }
        try require(f.download.isEnabled && f.ready == 0 && f.calls("download_models") == 0, "Checking missing models started a download or claimed ready")
        try snapshot(f.root, name: "setup-missing.png")
        f.configure.performClick(nil); f.configure.performClick(nil)
        do { try wait("progress") { f.progress.doubleValue == 0.4 && !f.progress.isIndeterminate } }
        catch { print("PROGRESS_DIAGNOSTIC prepared=\(f.prepared) downloaded=\(f.calls("download_models")) released=\(f.released) value=\(f.progress.doubleValue) indeterminate=\(f.progress.isIndeterminate) message=\(f.message.stringValue)"); throw error }
        try require(f.progress.maxValue == 1 && f.progress.minValue == 0, "Progress scale differs from fraction: min=\(f.progress.minValue) max=\(f.progress.maxValue)")
        try require(f.prepared == 1 && f.calls("download_models") == 1 && !f.configure.isEnabled && !f.check.isEnabled, "Duplicate click launched another operation")
        try require(f.released == 0 && f.ready == 0 && f.message.stringValue.contains("正在下载"), "Progress invented completion")
        try snapshot(f.root, name: "setup-progress.png")
        try f.send(#"{"schema":1,"event":"start","operation":"verify","message":"准备校验模型。"}"#)
        try wait("verification stage start") { f.progress.isIndeterminate && f.message.stringValue == "准备校验模型。" }
        try f.send(#"{"schema":1,"event":"progress","operation":"verify","completed_bytes":60,"total_bytes":100}"#)
        try wait("verification progress") { f.progress.doubleValue == 0.6 && f.message.stringValue.contains("正在校验模型") }
        try f.send(#"{"schema":1,"event":"verified","completed_bytes":100,"total_bytes":100,"message":"模型校验完成。"}"#)
        try wait("verified event") { f.progress.doubleValue == 1 && f.message.stringValue == "模型校验完成。" }
        try require(f.ready == 0 && f.released == 0 && !f.check.isEnabled, "A model verified event falsely completed the whole task")
        f.cancel.performClick(nil)
        try wait("download cancellation") { f.check.isEnabled && f.released == 1 }
        try require(f.message.stringValue.contains("已取消") && f.ready == 0 && f.cancel.isHidden, "Cancel became success or left UI busy")
    }
    static func readyAndLayout() throws {
        let f = try Fixture(); defer { f.dispose() }
        try f.report(ready: true, long: true)
        f.controller.window?.setContentSize(NSSize(width: 640, height: 640))
        f.check.performClick(nil)
        try wait("ready report") { f.check.isEnabled && f.message.stringValue.contains("已就绪") }
        f.root.layoutSubtreeIfNeeded()
        let scroll: NSScrollView = try find("setup-checks-scroll", in: f.root)
        try require(scroll.documentView!.bounds.height > scroll.contentView.bounds.height, "Long checks did not scroll")
        for button in [f.configure, f.download, f.check] {
            try require(button.bounds.width > 40 && button.bounds.height >= 18 && f.root.bounds.contains(f.root.convert(button.bounds, from: button)), "Minimum window clipped or collapsed actions")
        }
        try require(!f.root.hasAmbiguousLayout && !f.download.isEnabled && f.ready == 0, "Ready check changed runtime or left ambiguous layout")
        try snapshot(f.root, name: "setup-ready.png")
        f.configure.performClick(nil)
        try wait("ready configure") { f.ready == 1 }
        try require(f.calls("download_models") == 0 && f.prepared == 0 && f.released == 0, "Ready models were downloaded again")
        let selection = try String(contentsOf: f.runtime.appendingPathComponent("asr-backend"), encoding: .utf8)
        try require(selection == "qwen\n", "First configuration did not retain ASR selection")
    }
    static func errorsAndFinalVerification() throws {
        let error = try Fixture(); defer { error.dispose() }
        try error.mode("error"); error.configure.performClick(nil)
        try wait("download error") { error.check.isEnabled && error.released == 1 }
        try require(error.message.stringValue.contains("测试网络不可用") && error.ready == 0 && error.download.isEnabled, "Download error was lost or presented as success")
        try snapshot(error.root, name: "setup-error.png")
        let missing = try Fixture(); defer { missing.dispose() }
        try missing.mode("incomplete"); missing.configure.performClick(nil)
        try wait("final check still missing") { missing.check.isEnabled && missing.released == 1 }
        try require(missing.calls("download_models") == 1 && missing.calls("diagnose") == 2 && missing.ready == 0 && missing.message.stringValue.contains("仍未通过"), "Missing final validation looped or falsely completed")
        let success = try Fixture(); defer { success.dispose() }
        try success.mode("success"); success.configure.performClick(nil)
        try wait("verified download") { success.ready == 1 && success.released == 1 }
        try require(success.calls("diagnose") == 2 && success.calls("download_models") == 1 && success.progress.isHidden, "Success skipped verification or stayed busy")
    }
    static func pendingCancellationAndSafety() throws {
        let f = try Fixture(); defer { f.dispose() }
        var answer: ((Bool) -> Void)?
        f.controller.prepareDownload = { done in f.prepared += 1; answer = done }
        f.configure.performClick(nil)
        try wait("prepare callback") { answer != nil }
        f.cancel.performClick(nil)
        try require(f.calls("download_models") == 0 && !f.check.isEnabled, "Cancel allowed a retry before preparation settled")
        answer?(true)
        try wait("pending preparation cancellation") { f.check.isEnabled && f.released == 1 }
        try require(f.calls("download_models") == 0 && f.ready == 0, "Late prepare callback started a cancelled download")
        f.controller.canConfigure = { false }; let previous = f.calls("diagnose")
        f.configure.performClick(nil)
        try require(f.calls("diagnose") == previous && f.message.stringValue.contains("本次口述结束"), "Busy recording entered setup")
        let denied = try Fixture(); defer { denied.dispose() }
        denied.controller.prepareDownload = { done in denied.prepared += 1; done(false) }
        denied.configure.performClick(nil)
        try wait("external service denied") { denied.check.isEnabled && denied.released == 1 }
        try require(denied.calls("download_models") == 0 && denied.ready == 0 && denied.message.stringValue.contains("无法安全停止"), "Denied service lease launched a worker")
        let blocked = try Fixture(); defer { blocked.dispose() }
        try blocked.report(ready: false, blocked: "语音服务正在处理录音，请完成后再配置模型。")
        blocked.configure.performClick(nil)
        try wait("service busy reason") { blocked.check.isEnabled }
        try require(blocked.message.stringValue.contains("语音服务正在处理录音") && blocked.prepared == 0, "Service busy reason was hidden or bypassed")
    }
    static func asrChoiceFreeze() throws {
        let f = try Fixture(); defer { f.dispose() }
        try f.report(ready: false, asr: "whisper")
        f.chooseASR(.whisper)
        try wait("ASR pending choice checked") { f.check.isEnabled }
        var answer: ((Bool) -> Void)?
        f.controller.prepareDownload = { done in f.prepared += 1; answer = done }
        f.configure.performClick(nil)
        try wait("diagnosed choice pending") { answer != nil }
        try FileManager.default.createDirectory(at: f.runtime, withIntermediateDirectories: true)
        try "qwen\n".write(to: f.runtime.appendingPathComponent("asr-backend"), atomically: true, encoding: .utf8)
        try f.report(ready: false, asr: "qwen")
        answer?(true)
        try wait("frozen choice downloading") { f.progress.doubleValue == 0.4 }
        let args = try String(contentsOf: f.resources.appendingPathComponent("download_models.py.args"), encoding: .utf8).split(separator: "\n").map(String.init)
        let selected = args.firstIndex(of: "--asr-backend").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        try require(selected == "whisper", "Download used a later selection instead of the diagnosed choice")
        let diagnose = try String(contentsOf: f.resources.appendingPathComponent("diagnose.py.args"), encoding: .utf8)
        try require(diagnose.contains("--asr-backend\nwhisper\n"), "Diagnosis did not freeze the selected ASR")
        f.cancel.performClick(nil)
        try wait("choice download cancelled") { f.check.isEnabled && f.released == 1 }
        let retained = try String(contentsOf: f.runtime.appendingPathComponent("asr-backend"), encoding: .utf8)
        try require(retained == "qwen\n", "Cancelled download rewrote the current ASR preference")
    }
    static func cleanupModelDownloadsAndPersistence() throws {
        for choice in CleanupModelChoice.allCases {
            let previous: CleanupModelChoice = choice == .standard ? .larger : .standard
            let f = try Fixture(savedCleanup: previous.rawValue); defer { f.dispose() }
            try f.report(ready: false, cleanup: choice.rawValue)
            try f.report(ready: true, filename: "ready.json", cleanup: choice.rawValue)
            try f.mode("success")
            f.choose(choice)
            try wait("selected model check") { f.check.isEnabled && f.message.stringValue.contains("检查完成") }
            try require(f.savedCleanup == previous.rawValue + "\n" && f.prepared == 0 && f.ready == 0, "Choosing a model changed saved selection or stopped the service")
            let checked = try f.argument("--cleanup-model", script: "diagnose")
            try require(checked == choice.rawValue, "Check did not inspect selected cleanup model")
            f.configure.performClick(nil)
            try require(!f.cleanup.isEnabled, "Model picker stayed enabled during configuration")
            try wait("selected model applied") { f.ready == 1 && f.released == 1 }
            let downloaded = try f.argument("--cleanup-model", script: "download_models")
            let verified = try f.argument("--cleanup-model", script: "diagnose")
            try require(downloaded == choice.rawValue && verified == choice.rawValue && f.prepared == 1 && f.calls("download_models") == 1, "Download and verification did not share the selected model or safe-stop lease")
            try require(f.savedCleanup == choice.rawValue + "\n" && f.cleanup.isEnabled, "Successful configuration did not persist selection or unlock picker")
            // A new controller reads only the external runtime file, as it does
            // after relaunch; no DictationPreferences or in-memory cache assists.
            let reopened = DictationSetupWindowController(runtime: f.runtime, resources: f.resources)
            defer { reopened.shutdown(); reopened.window?.close() }
            let picker: NSPopUpButton = try find("setup-cleanup-model", in: reopened.window!.contentView!)
            try require(picker.titleOfSelectedItem == choice.title, "Relaunched setup lost the saved cleanup model")
            let recheck: NSButton = try find("setup-check", in: reopened.window!.contentView!)
            recheck.performClick(nil)
            try wait("reopened selected model checked") { recheck.isEnabled }
            let restarted = try f.argument("--cleanup-model", script: "diagnose")
            try require(restarted == choice.rawValue, "Relaunched setup diagnosed a different cleanup model")
            if choice == .larger { try snapshot(reopened.window!.contentView!, name: "setup-9b-applied.png") }
        }
    }
    static func readyCleanupSwitchAndSafety() throws {
        let f = try Fixture(); defer { f.dispose() }
        try require(f.cleanup.titleOfSelectedItem == CleanupModelChoice.standard.title && f.savedCleanup == nil, "Missing selection did not default to 4B without writing")
        try f.report(ready: true, cleanup: "cleanup-9b")
        f.choose(.larger)
        try wait("ready 9B checked") { f.check.isEnabled && f.message.stringValue.contains("已就绪") }
        try snapshot(f.root, name: "setup-9b-pending.png")
        var answer: ((Bool) -> Void)?
        f.controller.prepareDownload = { done in f.prepared += 1; answer = done }
        f.configure.performClick(nil)
        try wait("ready model lease requested") { answer != nil }
        try require(f.savedCleanup == nil && f.ready == 0 && !f.cleanup.isEnabled && f.calls("download_models") == 0, "Ready model switched before service safely stopped")
        f.choose(.standard)
        try require(f.cleanup.titleOfSelectedItem == CleanupModelChoice.larger.title, "Busy model choice was not frozen")
        answer?(true)
        try wait("ready model switch") { f.ready == 1 && f.released == 1 }
        try require(f.savedCleanup == "cleanup-9b\n" && f.calls("download_models") == 0, "Ready switch downloaded again or failed to persist")

        let denied = try Fixture(savedCleanup: "cleanup"); defer { denied.dispose() }
        try denied.report(ready: true, cleanup: "cleanup-9b")
        denied.choose(.larger)
        try wait("external switch checked") { denied.check.isEnabled }
        denied.controller.prepareDownload = { done in denied.prepared += 1; done(false) }
        denied.configure.performClick(nil)
        try wait("external switch refused") { denied.released == 1 }
        try require(denied.savedCleanup == "cleanup\n" && denied.ready == 0 && denied.prepared == 1, "External service guard did not protect ready-model selection")

        let backendBusy = try Fixture(savedCleanup: "cleanup"); defer { backendBusy.dispose() }
        try backendBusy.report(ready: true, cleanup: "cleanup-9b", serviceBusy: true)
        backendBusy.choose(.larger); try wait("busy backend checked") { backendBusy.check.isEnabled }
        backendBusy.configure.performClick(nil); try wait("ready busy backend refused") { backendBusy.check.isEnabled }
        try require(backendBusy.savedCleanup == "cleanup\n" && backendBusy.prepared == 0 && backendBusy.ready == 0,
            "Ready model bypassed active backend work and requested a stop")

        let recording = try Fixture(savedCleanup: "cleanup"); defer { recording.dispose() }
        recording.controller.canConfigure = { false }; recording.controller.refreshConfigurationAvailability()
        recording.choose(.larger); recording.configure.performClick(nil)
        try require(!recording.cleanup.isEnabled && recording.cleanup.titleOfSelectedItem == CleanupModelChoice.standard.title
            && recording.savedCleanup == "cleanup\n" && recording.calls("diagnose") == 0 && recording.prepared == 0, "Recording permitted model change or configuration")
    }
    static func cleanupSwitchFailures() throws {
        for kind in ["symlink", "fifo", "directory"] {
            let started = Date()
            let invalid = try Fixture(selectionKind: kind); defer { invalid.dispose() }
            try require(Date().timeIntervalSince(started) < 2 && invalid.cleanup.titleOfSelectedItem == CleanupModelChoice.standard.title,
                "Non-regular selection \(kind) was read or blocked the UI")
            let caption: NSTextField = try find("setup-cleanup-caption", in: invalid.root)
            try require(!caption.stringValue.contains("当前配置"), "Invalid selection was displayed as an applied configuration")
            try require(FileManager.default.fileExists(atPath: invalid.runtime.appendingPathComponent("cleanup-model").path), "Checking invalid preference removed it")
        }
        for mode in ["error", "incomplete", "hold"] {
            let f = try Fixture(savedCleanup: "cleanup"); defer { f.dispose() }
            try f.report(ready: false, cleanup: "cleanup-9b"); try f.mode(mode)
            f.choose(.larger); try wait("failing model checked") { f.check.isEnabled }
            f.configure.performClick(nil)
            if mode == "hold" {
                try wait("download ready for cancel") { f.progress.doubleValue == 0.4 }
                f.cancel.performClick(nil)
            }
            try wait("failed or cancelled selection") { f.check.isEnabled && f.released == 1 }
            try require(f.savedCleanup == "cleanup\n" && f.ready == 0, "Failed or cancelled \(mode) changed saved cleanup model")
        }
        let mismatch = try Fixture(savedCleanup: "cleanup"); defer { mismatch.dispose() }
        try mismatch.report(ready: true, cleanup: "cleanup")
        mismatch.choose(.larger); try wait("wrong model report rejected") { mismatch.check.isEnabled }
        try require(mismatch.message.stringValue.contains("不一致") && mismatch.savedCleanup == "cleanup\n" && mismatch.prepared == 0, "Report for another model was accepted")

        let cancelled = try Fixture(savedCleanup: "cleanup"); defer { cancelled.dispose() }
        try cancelled.report(ready: true, cleanup: "cleanup-9b")
        cancelled.choose(.larger); try wait("ready cancellation checked") { cancelled.check.isEnabled }
        var answer: ((Bool) -> Void)?
        cancelled.controller.prepareDownload = { done in cancelled.prepared += 1; answer = done }
        cancelled.configure.performClick(nil); try wait("ready cancellation lease") { answer != nil }
        cancelled.cancel.performClick(nil); answer?(true)
        try wait("ready switch cancellation settled") { cancelled.released == 1 }
        try require(cancelled.savedCleanup == "cleanup\n" && cancelled.ready == 0 && cancelled.calls("download_models") == 0, "Cancelled ready-model switch changed selection")
    }
    static func closeAndShutdown() throws {
        let f = try Fixture(); defer { f.dispose() }
        DictationMotion.reduceMotionOverride = true
        var answer: ((Bool) -> Void)?
        f.controller.prepareDownload = { done in f.prepared += 1; answer = done }
        f.configure.performClick(nil)
        try wait("reduced motion pending") { answer != nil }
        try require(!f.progress.isIndeterminate && !f.progress.isHidden, "Reduced-motion setup kept a looping progress animation")
        answer?(true)
        try wait("worker before close") { f.progress.doubleValue == 0.4 }
        f.controller.window?.close()
        try require(f.released == 0 && !f.check.isEnabled, "Closing the window cancelled the requested download")
        try f.report(ready: true); try f.releaseWorker()
        try wait("download completed while closed") { f.released == 1 && f.ready == 1 }
        try require(f.controller.window?.isVisible == false, "Closed setup window was reopened by completion")
        let shutdown = try Fixture(); defer { shutdown.dispose() }
        shutdown.configure.performClick(nil)
        try wait("worker before shutdown") { shutdown.progress.doubleValue == 0.4 }
        shutdown.controller.shutdown(); shutdown.controller.shutdown()
        try wait("shutdown releases lease") { shutdown.released == 1 }
        try require(shutdown.ready == 0 && !shutdown.configure.isEnabled && shutdown.controller.window?.isVisible == false, "Shutdown claimed success or left configuration active")
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        try require(shutdown.released == 1, "Shutdown released the lease twice")
    }

    static func externalModelConfiguration() throws {
        let f = try Fixture(savedCleanup: "cleanup", savedASR: "qwen"); defer { f.dispose() }
        try f.report(ready: true, asr: "whisper", cleanup: "cleanup-9b")
        var results: [Result<Void, Error>] = [], completionReleased = false
        var answer: ((Bool) -> Void)?
        f.controller.prepareDownload = { done in f.prepared += 1; answer = done }
        let accepted = f.controller.configureModels(asr: "whisper", cleanup: "cleanup-9b") { result in
            results.append(result); completionReleased = f.released == 1 && !f.controller.isConfiguringModels && f.activity.last == false
        }
        try require(accepted && f.controller.isConfiguringModels && f.activity == [true], "External request did not start exactly one configuration activity")
        try require(!f.controller.configureModels(asr: "qwen", cleanup: "cleanup") { results.append($0) }, "Duplicate external operation was accepted")
        try wait("external safe lease") { answer != nil }
        try require(f.savedASR == "qwen\n" && f.savedCleanup == "cleanup\n" && !f.controller.window!.isVisible,
                    "External request saved too early or opened setup window")
        answer?(true)
        try wait("external completion") { results.count == 1 && f.ready == 1 }
        guard case .success = results[0] else { throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "External valid switch failed"]) }
        try require(completionReleased && f.activity == [true, false] && f.savedASR == "whisper\n" && f.savedCleanup == "cleanup-9b\n", "External completion preceded release or failed to persist both choices")
        let checkedASR = try f.argument("--asr-backend", script: "diagnose")
        try require(checkedASR == "whisper" && f.calls("download_models") == 0, "Ready external switch checked wrong ASR or downloaded again")
        answer?(true); answer?(false)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        try require(results.count == 1 && f.ready == 1 && f.released == 1, "Repeated lease callback completed an operation twice")
        let reopened = DictationSetupWindowController(runtime: f.runtime, resources: f.resources)
        defer { reopened.shutdown(); reopened.window?.close() }
        let picker: NSPopUpButton = try find("setup-asr-model", in: reopened.window!.contentView!)
        try require(picker.titleOfSelectedItem == ASRModelChoice.whisper.title, "ASR choice did not survive controller restart")

        let pending = try Fixture(savedCleanup: "cleanup", savedASR: "qwen"); defer { pending.dispose() }
        try pending.report(ready: true, cleanup: "cleanup-9b")
        pending.choose(.larger); try wait("pending UI selection") { pending.check.isEnabled }
        var callbacks = 0
        try require(!pending.controller.configureModels(asr: "whisper", cleanup: "cleanup") { _ in callbacks += 1 }, "External switch overwrote settings draft")
        try require(pending.cleanup.titleOfSelectedItem == CleanupModelChoice.larger.title && pending.activity.isEmpty && callbacks == 0, "Rejected request changed UI or emitted completion")
        try require(!f.controller.configureModels(asr: "invalid", cleanup: "cleanup") { _ in callbacks += 1 }, "Invalid ASR accepted")
        try require(!f.controller.configureModels(asr: "qwen", cleanup: "qwen") { _ in callbacks += 1 }, "ASR model accepted as cleanup")
        f.controller.canConfigure = { false }
        try require(!f.controller.configureModels(asr: "qwen", cleanup: "cleanup") { _ in callbacks += 1 } && callbacks == 0, "Busy service accepted request or called rejected completion")
    }

    static func externalFailureAndCancellation() throws {
        for failure in ["download", "verify", "cancel", "denied", "mismatch", "shutdown"] {
            let f = try Fixture(savedCleanup: "cleanup", savedASR: "qwen"); defer { f.dispose() }
            let ready = ["denied", "mismatch"].contains(failure)
            try f.report(ready: ready, asr: failure == "mismatch" ? "qwen" : "whisper", cleanup: "cleanup-9b")
            try f.report(ready: true, filename: "ready.json", asr: "whisper", cleanup: "cleanup-9b")
            try f.mode(failure == "download" ? "error" : failure == "verify" ? "incomplete" : "hold")
            if failure == "denied" { f.controller.prepareDownload = { done in f.prepared += 1; done(false) } }
            var results: [Result<Void, Error>] = []
            try require(f.controller.configureModels(asr: "whisper", cleanup: "cleanup-9b") { results.append($0) }, "External \(failure) request was not accepted")
            if failure == "cancel" || failure == "shutdown" {
                try wait("external active download") { f.progress.doubleValue == 0.4 }
                if failure == "shutdown" { f.controller.shutdown() } else { f.cancel.performClick(nil) }
            }
            try wait("external \(failure) settled") { results.count == 1 }
            guard case .failure(let error) = results[0] else { throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "External \(failure) incorrectly succeeded"]) }
            try require(!error.localizedDescription.isEmpty && f.activity == [true, false] && !f.controller.isConfiguringModels,
                        "External failure lost explanation or left configuration active")
            try require(f.savedASR == "qwen\n" && f.savedCleanup == "cleanup\n" && f.ready == 0,
                        "External \(failure) changed saved pair or claimed model ready")
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            try require(results.count == 1, "External \(failure) called completion twice")
        }
    }

    static func selectionSaveRollback() throws {
        for absent in [false, true] {
            var writes = 0
            let f = try Fixture(savedCleanup: absent ? nil : "cleanup", savedASR: absent ? nil : "qwen", writeSelection: { data, url in
                writes += 1
                if writes == 2 { throw NSError(domain: "FixtureWrite", code: 1, userInfo: [NSLocalizedDescriptionKey: "second selection write failed"]) }
                try data.write(to: url, options: .atomic)
            }); defer { f.dispose() }
            try f.report(ready: true, asr: "whisper", cleanup: "cleanup-9b")
            var results: [Result<Void, Error>] = []
            try require(f.controller.configureModels(asr: "whisper", cleanup: "cleanup-9b") { results.append($0) }, "Rollback test not accepted")
            try wait("second selection failure") { results.count == 1 }
            guard case .failure(let error) = results[0] else { throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Partial persistence reported success"]) }
            try require(error.localizedDescription.contains("second selection") && f.ready == 0 && f.released == 1 && f.activity == [true, false], "Save failure was hidden or retained service lease")
            try require(f.savedASR == (absent ? nil : "qwen\n") && f.savedCleanup == (absent ? nil : "cleanup\n"), "Two-file failure left a mixed or newly created configuration")
        }
    }
}
