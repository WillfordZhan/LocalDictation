import AppKit

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
        let message: NSTextField, progress: NSProgressIndicator
        var prepared = 0, released = 0, ready = 0
        init() throws {
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
            controller = DictationSetupWindowController(runtime: runtime, resources: resources)
            root = controller.window!.contentView!
            configure = try find("setup-configure", in: root)
            download = try find("setup-download", in: root)
            check = try find("setup-check", in: root)
            cancel = try find("setup-cancel", in: root)
            message = try find("setup-message", in: root)
            progress = try find("setup-progress", in: root)
            controller.prepareDownload = { [weak self] done in self?.prepared += 1; done(true) }
            controller.onDownloadFinished = { [weak self] in self?.released += 1 }
            controller.onReady = { [weak self] in self?.ready += 1 }
            try report(ready: false)
            try report(ready: true, filename: "ready.json")
            try mode("hold")
        }
        func report(ready: Bool, filename: String = "report.json", long: Bool = false, blocked: String? = nil, asr: String? = nil) throws {
            let row: [String: Any] = ["id": "model", "status": ready ? "ok" : "missing",
                "message": long ? String(repeating: "模型校验与运行环境示例，完整文件会直接复用。", count: 8) : ready ? "本机运行环境与模型已就绪。" : "尚未下载语音识别与文字整理模型。"]
            var report: [String: Any] = ["schema": 1, "ready": ready, "blocked": false, "can_download": !ready && blocked == nil,
                "checks": long ? (0..<12).map { index -> [String: Any] in var copy = row; copy["id"] = "row-\(index)"; return copy } : [row],
                "required_download_bytes": ready ? 0 : 100]
            if let blocked { report["download_block_reason"] = blocked }
            if let asr { report["asr_backend"] = asr }
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
        try require(!diagnose.contains("--asr-backend"), "Diagnosis silently overrode the stored ASR selection")
        f.cancel.performClick(nil)
        try wait("choice download cancelled") { f.check.isEnabled && f.released == 1 }
        let retained = try String(contentsOf: f.runtime.appendingPathComponent("asr-backend"), encoding: .utf8)
        try require(retained == "qwen\n", "Cancelled download rewrote the current ASR preference")
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
}
