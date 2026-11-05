import AppKit

/// A finite AppKit transition. It runs on the main run loop only while values
/// change; no display link or idle timer is added to the application's pages.
final class DictationMotionAnimation: NSAnimation {
    private let updateValue: (CGFloat) -> Void
    private var completion: (() -> Void)?
    init(duration: TimeInterval, update: @escaping (CGFloat) -> Void, completion: (() -> Void)? = nil) {
        updateValue = update; self.completion = completion
        super.init(duration: duration, animationCurve: .easeOut)
        animationBlockingMode = .nonblocking; frameRate = 60
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var currentProgress: NSAnimation.Progress {
        didSet {
            updateValue(CGFloat(currentValue))
            if currentProgress >= 1 { let done = completion; completion = nil; done?() }
        }
    }
    func cancel() { completion = nil; stop() }
    func finishImmediately() { stop(); currentProgress = 1 }
}

enum DictationMotion {
    static let policyDidChange = Notification.Name("LocalDictationMotionPolicyDidChange")
    // Test fixtures can exercise both policies without changing user settings.
    static var reduceMotionOverride: Bool? { didSet { settleForPolicyChange() } }
    static var reduceMotion: Bool { reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private final class Fade {
        let id = UUID()
        var animation: DictationMotionAnimation?
    }
    private static let fades = NSMapTable<NSView, Fade>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private static let workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { _ in settleForPolicyChange() }

    static func duration(_ requested: TimeInterval) -> TimeInterval {
        _ = workspaceObserver
        return reduceMotion ? min(0.06, max(0, requested)) : max(0, requested)
    }
    static func reveal(_ view: NSView, duration: TimeInterval = 0.15) {
        let start = fades.object(forKey: view) == nil ? 0.78 : view.alphaValue
        fade(view, to: 1, from: start, duration: duration)
    }
    /// Cancellation means the caller owns the new state. Suppress the old
    /// completion and leave a fully readable view, including after page reuse.
    static func cancel(_ view: NSView) {
        stopFade(view); view.alphaValue = 1
    }
    static func fade(_ view: NSView, to target: CGFloat, from start: CGFloat? = nil,
                     duration requested: TimeInterval, completion: (() -> Void)? = nil) {
        let origin = start ?? view.alphaValue
        stopFade(view)
        let seconds = duration(requested)
        view.alphaValue = origin
        guard seconds > 0, abs(origin - target) > 0.0001 else { view.alphaValue = target; completion?(); return }
        let record = Fade(), id = record.id
        let animation = DictationMotionAnimation(duration: seconds, update: { [weak view] progress in
            view?.alphaValue = origin + (target - origin) * progress
        }, completion: { [weak view] in
            guard let view, fades.object(forKey: view)?.id == id else { return }
            fades.removeObject(forKey: view); view.alphaValue = target; completion?()
        })
        record.animation = animation; fades.setObject(record, forKey: view)
        animation.start()
    }
    private static func stopFade(_ view: NSView) {
        let animation = fades.object(forKey: view)?.animation
        fades.removeObject(forKey: view); animation?.cancel()
    }
    private static func settleForPolicyChange() {
        // Complete each current effect before adopting the new policy. A fade
        // out still removes its own layer; a reveal ends fully readable.
        for case let view as NSView in fades.keyEnumerator().allObjects {
            fades.object(forKey: view)?.animation?.finishImmediately()
        }
        NotificationCenter.default.post(name: policyDidChange, object: nil)
    }
}
