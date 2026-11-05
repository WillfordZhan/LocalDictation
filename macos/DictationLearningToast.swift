import AppKit

private final class LearningToastPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class LearningToastButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class LearningToastSurface: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
        NSColor(srgbRed: 0.12, green: 0.12, blue: 0.12, alpha: 1).setFill(); shape.fill()
        NSColor(white: 1, alpha: 0.18).setStroke(); shape.lineWidth = 1; shape.stroke()
    }
}

/// A reversible learning notice has its own short lifetime, independent of
/// recording sessions. It never becomes key or reads the destination field.
final class DictationLearningToast: NSObject {
    private let panel: LearningToastPanel
    private let surface = LearningToastSurface()
    private let message = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let undo = LearningToastButton(title: "撤销", target: nil, action: nil)
    private let dismiss = LearningToastButton(title: "", target: nil, action: nil)
    private var onUndo: (() -> Void)?
    private var onIgnored: (() -> Void)?
    private var expiration: DispatchWorkItem?
    private var generation: UInt64 = 0
    private(set) var awaitingConfirmation = false

    override init() {
        panel = LearningToastPanel(contentRect: NSRect(x: 0, y: 0, width: 270, height: 44),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .aqua); panel.contentView = surface
        surface.setAccessibilityElement(false)
        icon.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
        icon.contentTintColor = NSColor(white: 1, alpha: 0.7)
        icon.setAccessibilityElement(false)
        message.font = .systemFont(ofSize: 12.5, weight: .medium); message.textColor = .white
        message.maximumNumberOfLines = 1; message.lineBreakMode = .byTruncatingMiddle
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        undo.font = .systemFont(ofSize: 11.5, weight: .medium)
        undo.isBordered = false; undo.wantsLayer = true; undo.layer?.cornerRadius = 7
        undo.layer?.backgroundColor = NSColor(white: 0.26, alpha: 1).cgColor
        undo.contentTintColor = .white; undo.target = self; undo.action = #selector(undoLearning)
        undo.identifier = NSUserInterfaceItemIdentifier("learning-toast-undo")
        dismiss.isBordered = false; dismiss.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭提示")
        dismiss.imageScaling = .scaleProportionallyDown; dismiss.contentTintColor = NSColor(white: 1, alpha: 0.65)
        dismiss.target = self; dismiss.action = #selector(dismissNotice)
        dismiss.identifier = NSUserInterfaceItemIdentifier("learning-toast-dismiss")
        dismiss.setAccessibilityLabel("关闭提示")
        for view in [icon, message, undo, dismiss] {
            view.translatesAutoresizingMaskIntoConstraints = false; surface.addSubview(view)
            view.centerYAnchor.constraint(equalTo: surface.centerYAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 13),
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            message.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            message.trailingAnchor.constraint(equalTo: undo.leadingAnchor, constant: -12),
            undo.widthAnchor.constraint(equalToConstant: 44), undo.heightAnchor.constraint(equalToConstant: 26),
            undo.trailingAnchor.constraint(equalTo: dismiss.leadingAnchor, constant: -6),
            dismiss.widthAnchor.constraint(equalToConstant: 22), dismiss.heightAnchor.constraint(equalToConstant: 26),
            dismiss.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -7)
        ])
    }

    deinit { expiration?.cancel(); panel.orderOut(nil) }

    func show(term: String, showWindow: Bool = true, visibleFrame: NSRect? = nil,
              onUndo: @escaping () -> Void) {
        present(term: term, original: nil, showWindow: showWindow, visibleFrame: visibleFrame, onIgnored: nil, action: onUndo)
    }

    func showConfirmation(original: String, term: String, showWindow: Bool = true, visibleFrame: NSRect? = nil,
                          onIgnored: (() -> Void)? = nil,
                          onRemember: @escaping () -> Void) {
        present(term: term, original: original, showWindow: showWindow, visibleFrame: visibleFrame, onIgnored: onIgnored, action: onRemember)
    }

    private func present(term: String, original: String?, showWindow: Bool, visibleFrame: NSRect?,
                         onIgnored: (() -> Void)?, action: @escaping () -> Void) {
        generation &+= 1; let current = generation
        expiration?.cancel(); DictationMotion.cancel(surface)
        awaitingConfirmation = original != nil
        self.onIgnored = onIgnored
        self.onUndo = action; undo.isEnabled = true; dismiss.isEnabled = true
        message.stringValue = awaitingConfirmation ? "记住 \(term)？" : "已学会 \(term)"
        message.toolTip = original.map { "\($0) → \(term)" } ?? term
        undo.title = awaitingConfirmation ? "记住" : "撤销"
        undo.setAccessibilityLabel((awaitingConfirmation ? "记住词组：" : "撤销学习：") + term)
        icon.image = NSImage(systemSymbolName: awaitingConfirmation ? "book" : "checkmark.circle", accessibilityDescription: nil)
        let frame = visibleFrame ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 700)
        let textWidth = (message.stringValue as NSString).size(withAttributes: [.font: message.font!]).width
        let width = min(max(220, textWidth + 128), min(360, max(180, frame.width - 32)))
        panel.setFrame(NSRect(x: frame.maxX - width - 16, y: frame.maxY - 60, width: width, height: 44), display: false)
        surface.layoutSubtreeIfNeeded()
        if showWindow { panel.orderFrontRegardless(); DictationMotion.reveal(surface) }
        // Replacement invalidates the previous deadline and callback together;
        // a delayed timer cannot remove a newer correction notice.
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, self.generation == current else { return }
            self.hide()
        }
        expiration = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + (awaitingConfirmation ? 12 : 5), execute: deadline)
    }

    func hide() {
        let ignored = onIgnored
        onIgnored = nil
        generation &+= 1; let current = generation
        expiration?.cancel(); expiration = nil; onUndo = nil
        awaitingConfirmation = false
        undo.isEnabled = false; dismiss.isEnabled = false
        ignored?()
        guard panel.isVisible else { DictationMotion.cancel(surface); return }
        DictationMotion.fade(surface, to: 0, duration: 0.12) { [weak self] in
            guard let self, self.generation == current else { return }
            self.panel.orderOut(nil)
        }
    }

    @objc private func undoLearning() {
        guard let action = onUndo else { return }
        onIgnored = nil
        hide(); action()
    }
    @objc private func dismissNotice() { hide() }

    func renderPNG(to url: URL) throws {
        surface.layoutSubtreeIfNeeded()
        guard let bitmap = surface.bitmapImageRepForCachingDisplay(in: surface.bounds) else { return }
        surface.cacheDisplay(in: surface.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try png.write(to: url)
    }
}
