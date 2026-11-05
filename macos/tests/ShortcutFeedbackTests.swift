import AppKit

private final class ShortcutFocusFixture: NSView {
    override var acceptsFirstResponder: Bool { true }
}

/// Local capture is exercised through its existing candidate/release entry.
/// No global listener, real key event, registration or production data is used.
@main
enum ShortcutFeedbackChecks {
    static var checks = 0
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !value() { throw NSError(domain: "ShortcutFeedback", code: checks, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func settle(_ seconds: TimeInterval = 0.14) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
    static func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(0.8)
        while !condition() && Date() < deadline { settle(0.05) }
        return condition()
    }
    static func capture(_ root: NSView, name: String) throws {
        guard let index = CommandLine.arguments.firstIndex(of: "--render"), CommandLine.arguments.indices.contains(index + 1) else { return }
        let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        settle(); root.layoutSubtreeIfNeeded()
        guard let image = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { throw NSError(domain: "Capture", code: 1) }
        root.cacheDisplay(in: root.bounds, to: image)
        guard let data = image.representation(using: .png, properties: [:]) else { throw NSError(domain: "Capture", code: 2) }
        try data.write(to: directory.appendingPathComponent(name))
    }
    static func main() {
        do { try run(); print("PASS: \(checks) shortcut feedback checks; local synthetic capture, hidden window") }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func run() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        DictationMotion.reduceMotionOverride = false
        defer { DictationMotion.reduceMotionOverride = nil }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 150), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 150)); window.contentView = root
        root.wantsLayer = true; root.layer?.backgroundColor = NSColor.white.cgColor
        let current = NSTextField(labelWithString: "当前生效：Fn")
        current.font = .systemFont(ofSize: 17, weight: .medium); current.textColor = Palette.blue
        let presentation = ShortcutCapturePresentationView(label: current)
        let feedback = NSTextField(wrappingLabelWithString: "Fn 可单独使用；组合键至少包含 ⌘、⌥ 或 ⌃。")
        feedback.font = .systemFont(ofSize: 11); feedback.textColor = Palette.muted
        let recorder = ShortcutRecorderView()
        let previous = ShortcutFocusFixture()
        for item in [presentation, feedback, recorder, previous] { item.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(item) }
        NSLayoutConstraint.activate([
            presentation.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            presentation.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            presentation.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            feedback.leadingAnchor.constraint(equalTo: presentation.leadingAnchor),
            feedback.trailingAnchor.constraint(equalTo: presentation.trailingAnchor),
            feedback.topAnchor.constraint(equalTo: presentation.bottomAnchor, constant: 12),
            recorder.heightAnchor.constraint(equalToConstant: 0), recorder.widthAnchor.constraint(equalToConstant: 0),
            recorder.topAnchor.constraint(equalTo: root.topAnchor), recorder.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            previous.topAnchor.constraint(equalTo: feedback.bottomAnchor, constant: 12),
            previous.leadingAnchor.constraint(equalTo: presentation.leadingAnchor), previous.widthAnchor.constraint(equalToConstant: 160),
            previous.heightAnchor.constraint(equalToConstant: 18)
        ])
        recorder.bindPresentation(presentation, feedback: feedback)
        recorder.onFeedback = { feedback.stringValue = $0 }
        var events: [String] = [], applied: [DictationShortcut] = []
        var expectedResponder: NSResponder?, appliedAfterFocusRestore = false
        recorder.onCaptureChange = { events.append("capture:\($0)") }
        recorder.onCandidate = { shortcut in
            events.append("apply")
            appliedAfterFocusRestore = !recorder.isRecording && window.firstResponder === expectedResponder
            applied.append(shortcut); current.stringValue = "当前生效：" + shortcut.display
            return nil
        }
        defer { recorder.cancel(); window.close() }
        try require(window.makeFirstResponder(previous), "Focus fixture was not accepted")
        root.layoutSubtreeIfNeeded()
        // Use a stable responder; a detached NSTextField field editor has its
        // own AppKit lifetime and is outside these presentation-only checks.
        expectedResponder = window.firstResponder
        let originalFrame = presentation.frame
        recorder.begin()
        try require(recorder.isRecording && presentation.isCapturing && recorder.feedbackState == .capturing, "Capture presentation did not follow actual capture")
        try require(window.firstResponder === recorder && events == ["capture:true"], "Capture/focus ordering changed")
        try require(presentation.alphaValue < 1, "Capture change had no finite reveal")
        let captureSettled = waitUntil { abs(presentation.alphaValue - 1) < 0.001 }
        try require(captureSettled, "Capture reveal never settled: presentation=\(presentation.alphaValue), feedback=\(feedback.alphaValue)")
        let invalid = DictationShortcut(keyCode: 0, modifiers: 0)
        recorder.receiveRegisteredShortcut(invalid, released: false)
        try require(recorder.feedbackState == .invalid && feedback.textColor == Palette.warning && feedback.stringValue.contains("修饰键"), "Invalid shortcut lacked text and error color")
        recorder.receiveRegisteredShortcut(invalid, released: true)
        try require(applied.isEmpty && recorder.isRecording && presentation.isCapturing, "Invalid candidate was applied or stopped listening")
        try capture(root, name: "shortcut-invalid.png")
        recorder.receiveRegisteredShortcut(.defaultValue, released: false)
        try require(presentation.candidate == DictationShortcut.defaultValue.display && applied.isEmpty, "Candidate was hidden or committed before release")
        try capture(root, name: "shortcut-candidate.png")
        recorder.receiveRegisteredShortcut(.defaultValue, released: true)
        try require(applied == [.defaultValue] && recorder.feedbackState == .applied, "Successful callback did not produce success feedback")
        try require(events == ["capture:true", "capture:false", "apply"], "Registration was not after capture exit")
        try require(appliedAfterFocusRestore, "Registration preceded restoration of the original responder")
        try require(!presentation.isCapturing && presentation.candidate == nil && feedback.stringValue == "已生效：" + DictationShortcut.defaultValue.display, "Successful presentation remained in capture state")
        root.layoutSubtreeIfNeeded()
        try require(presentation.frame == originalFrame, "Capture/candidate/success shifted the shortcut area")
        try capture(root, name: "shortcut-applied.png")

        recorder.onCandidate = { _ in "快捷键已被占用。" }
        recorder.begin(); recorder.receiveRegisteredShortcut(.functionKey, released: false)
        recorder.receiveRegisteredShortcut(.functionKey, released: true)
        try require(recorder.feedbackState == .invalid && feedback.stringValue == "快捷键已被占用。" && feedback.textColor == Palette.warning, "Registration failure was presented as success")
        try capture(root, name: "shortcut-apply-error.png")
        recorder.onCandidate = nil
        recorder.begin(); recorder.receiveRegisteredShortcut(.functionKey, released: false)
        recorder.receiveRegisteredShortcut(.functionKey, released: true)
        try require(recorder.feedbackState == .invalid && !feedback.stringValue.contains("已生效"), "Missing registration callback invented success")

        DictationMotion.reduceMotionOverride = true
        recorder.begin(); recorder.receiveRegisteredShortcut(.defaultValue, released: false); recorder.cancel()
        try require(waitUntil { presentation.alphaValue == 1 && feedback.alphaValue == 1 }, "Reduced-motion feedback never settled")
        try require(recorder.feedbackState == .cancelled && !recorder.isRecording && !presentation.isCapturing, "Fast cancellation left stale capture visuals")
        try require(window.firstResponder === expectedResponder && feedback.stringValue.contains("原快捷键保持不变"), "Cancel lost existing focus or result semantics")
        try require(presentation.alphaValue == 1 && feedback.alphaValue == 1, "Reduced-motion feedback stayed translucent")
        try require(!window.isVisible, "The test displayed a window")
        try capture(root, name: "shortcut-cancelled.png")
    }
}
