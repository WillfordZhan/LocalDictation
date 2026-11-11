import AppKit

/// Independent cards must retain their own actions and state while sharing a
/// layout. Default checks never show a window or touch the live dictation app.
@main
enum DictationHUDStackTests {
    static var checks = 0
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw NSError(domain: "HUDStack", code: checks, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func field<T>(_ value: Any, _ name: String, _: T.Type) -> T? {
        Mirror(reflecting: value).children.first { $0.label == name }?.value as? T
    }
    static func wait(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    static func main() {
        do { try run(); print("PASS: \(checks) independent HUD stack checks") }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func run() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        defer { DictationMotion.reduceMotionOverride = nil }
        let normal = NSRect(x: 100, y: 80, width: 1200, height: 740)
        for bounds in [normal, NSRect(x: -1800, y: -200, width: 1728, height: 1060),
                       NSRect(x: 0, y: 0, width: 700, height: 280), NSRect(x: 0, y: 0, width: 320, height: 240)] {
            for count in [1, 2, 3, 4, 8] {
                let frames = (0..<count).map { DictationHUD.stackFrame(index: $0, count: count, visibleFrame: bounds) }
                for (i, frame) in frames.enumerated() {
                    try require(bounds.contains(frame), "HUD \(i) of \(count) escaped visible screen")
                    try require(frame.height == 34, "Stack changed card height")
                    for previous in frames.prefix(i) {
                        try require(!frame.intersects(previous), "HUDs overlap on short screen")
                    }
                }
            }
        }
        let reusable = DictationHUD()
        reusable.setStackIndex(0, animated: false)
        reusable.hide()
        try require(field(reusable, "stackVisibleFrame", NSRect.self) == nil, "Reused single HUD remained pinned to an old display")
        let first = DictationHUD.stackFrame(index: 0, count: 1, visibleFrame: normal)
        try require(first == NSRect(x: normal.midX - 59, y: normal.minY + 30, width: 118, height: 34), "Compact card lost the bottom-center anchor")
        let four = (0..<4).map { DictationHUD.stackFrame(index: $0, count: 4, visibleFrame: normal) }
        try require(zip(four, four.dropFirst()).allSatisfy { $1.minY - $0.maxY == 12 }, "Normal vertical gap changed")
        let compact = (0..<8).map { DictationHUD.stackFrame(index: $0, count: 8, visibleFrame: NSRect(x: 0, y: 0, width: 700, height: 280)) }
        try require(compact.map(\.minX).max()! > compact.map(\.minX).min()!, "Short screen failed to use a second column")

        let cards = (0..<4).map { _ in DictationHUD() }
        defer { cards.forEach { $0.hide() } }
        var finishes: [Int] = [], cancels: [Int] = [], copies: [Int] = []
        var states: [DictationUIState] = []
        for (index, card) in cards.enumerated() {
            card.onFinish = { finishes.append(index) }; card.onCancel = { cancels.append(index) }
            card.onCopy = { copies.append(index) }
            card.setStackIndex(index, count: cards.count, animated: false, visibleFrame: normal)
            var state = DictationUIState()
            state.sessionLabel = "第\(index + 1)段"
            state.processing = index < 3; state.recording = index == 3; state.pendingCount = 3
            state.processingStage = index == 0 ? "正在整理" : "等待整理"
            state.elapsedSeconds = 7 + index; state.meterLevel = 0.4; state.meterPeakLevel = 0.65
            state.recognizedSeconds = index == 3 ? 32.5 : nil
            state.processingProgress = index < 3 ? [0.82, 0.54, 0.22][index] : nil
            card.update(state, show: false); states.append(state)
            try require(card.frame == four[index] && !card.isVisible, "Hidden fixture showed a window or lost its stack position")
            let panel = field(card, "panel", NSPanel.self)!
            try require(!panel.canBecomeKey && !panel.canBecomeMain, "HUD can steal input focus")
            let title = field(card, "title", NSTextField.self)!
            try require(title.stringValue == "正在整理" && title.isHidden == (index == 3), "HUD leaked an internal processing stage")
            try require(field(card, "sessionCaption", NSTextField.self)?.stringValue == String(index + 1), "HUD lost session identity")
            field(card, "cancel", NSButton.self)?.performClick(nil)
            if index == 3 { field(card, "finish", NSButton.self)?.performClick(nil) }
        }
        try require(cancels == [0, 1, 2, 3] && finishes == [3], "Per-session actions were mixed between cards")
        var concurrent = states[3]; concurrent.processing = true
        cards[3].update(concurrent, show: false)
        let activity = Mirror(reflecting: cards[3]).children.first { $0.label == "activity" }!.value
        try require(field(activity, "processing", Bool.self) == false, "Pending processing replaced the active recording waveform")
        try require(field(cards[3], "finish", NSButton.self)?.isHidden == false, "Pending processing hid the active recording finish button")
        try require(field(cards[3], "time", NSTextField.self) == nil, "Recording retained a permanent timer")
        try require(field(cards[3], "activity", NSView.self)?.isHidden == false, "Pending work hid the live waveform")

        // Every processing state uses the same calm, single-line description.
        // Backend diagnostics remain in logs/history, not the floating controls.
        for stage in ["等待处理", "正在识别尾段", "正在整理", "等待填入"] {
            for cleanup in [true, false] {
                var state = states[0]; state.processingStage = stage; state.cleanupEnabled = cleanup
                cards[0].update(state, show: false)
                try require(field(cards[0], "title", NSTextField.self)?.stringValue == "正在整理", "Processing detail escaped the compact label")
                try require(field(cards[0], "title", NSTextField.self)?.toolTip == nil, "Internal processing detail leaked into a tooltip")
            }
        }
        func validateActivityLayout(_ card: DictationHUD) throws {
            let panel = field(card, "panel", NSPanel.self)!, content = panel.contentView!
            content.layoutSubtreeIfNeeded()
            let body = field(card, "surface", NSView.self)!
            let names = ["sessionCaption", "cancel", "activity", "title", "finish"]
            let views = names.compactMap { name -> NSView? in
                guard let view = field(card, name, NSView.self), !view.isHidden else { return nil }
                return view
            }
            let rects = views.map { $0.convert($0.bounds, to: content) }.sorted { $0.minX < $1.minX }
            for rect in rects { try require(content.bounds.contains(rect), "Compact HUD control escaped its card") }
            for (left, right) in zip(rects, rects.dropFirst()) {
                try require(left.maxX <= right.minX + 0.5, "Compact HUD controls overlap: \(left) then \(right)")
                try require(abs(left.midY - right.midY) <= 1, "Compact HUD reverted to uneven/two-line alignment")
            }
            try require(body.bounds.width == 118 && card.frame.height == 34, "Normal activity retained oversized delivery dimensions: \(card.frame)")
            let cancel = field(card, "cancel", NSButton.self)!, finish = field(card, "finish", NSButton.self)!
            try require(cancel.frame.size == NSSize(width: 24, height: 24) && finish.frame.size == cancel.frame.size, "Capsule controls lost their 24 pt hit targets: cancel=\(cancel.frame) finish=\(finish.frame)")
            let wave = field(card, "activity", NSView.self)!
            try require(wave.frame.size == NSSize(width: 38, height: 24) && abs(wave.frame.midX - body.bounds.midX) < 0.1, "Recording waveform is not centered in its compact canvas")
            let status = field(card, "title", NSTextField.self)!
            try require(wave.isHidden != status.isHidden, "Waveform and status appeared together")
            if !status.isHidden {
                try require(abs(status.frame.midX - (body.bounds.midX - 5)) < 0.1, "Processing text lost its optical alignment")
                try require(cancel.frame.minX - status.frame.maxX >= 7, "Processing cancel crowds its label")
            }
        }
        for (index, card) in cards.enumerated() {
            card.update(states[index], show: false)
            try validateActivityLayout(card)
        }
        var withoutOrdinal = states[3]; withoutOrdinal.sessionLabel = ""
        cards[3].update(withoutOrdinal, show: false)
        try validateActivityLayout(cards[3])
        cards[3].update(states[3], show: false)
        // The ordinal is an outer stack aid, not part of the capsule. It uses
        // the immutable job label even after earlier cards leave the stack.
        let identityCard = DictationHUD()
        var identityState = states[3]; identityState.sessionLabel = "第7段"
        identityCard.setStackIndex(0, count: 1, animated: false, visibleFrame: normal)
        identityCard.update(identityState, show: false)
        let identityPanel = field(identityCard, "panel", NSPanel.self)!, identityBody = field(identityCard, "surface", NSView.self)!
        let identityCaption = field(identityCard, "sessionCaption", NSTextField.self)!
        identityPanel.contentView!.layoutSubtreeIfNeeded()
        let singleBodyCenter = identityCard.frame.minX + identityBody.frame.midX
        try require(identityCaption.isHidden && identityCard.frame.width == 118, "Single card reserved or displayed an ordinal gutter")
        identityCard.setStackIndex(1, count: 2, animated: false, visibleFrame: normal)
        identityPanel.contentView!.layoutSubtreeIfNeeded()
        try require(!identityCaption.isHidden && identityCaption.stringValue == "7", "Stack used row index instead of original job number")
        try require(identityCard.frame.width == 142 && identityCaption.frame.maxX < identityBody.frame.minX, "Ordinal was drawn inside the capsule")
        try require(abs(identityCard.frame.minX + identityBody.frame.midX - singleBodyCenter) < 0.1, "Showing an ordinal shifted the capsule body")
        try require(identityBody.hitTest(identityBody.convert(identityCaption.frame.origin, from: identityPanel.contentView)) == nil, "Outer ordinal overlaps capsule hit testing")
        identityCard.showDelivery(message: "已复制 · 按 ⌘V 粘贴", needsPermission: false, show: false)
        identityPanel.contentView!.layoutSubtreeIfNeeded()
        try require(!identityCaption.isHidden && identityCaption.stringValue == "7", "Copy/error card lost its original stack identity")
        try require(abs(identityCard.frame.minX + identityBody.frame.midX - singleBodyCenter) < 0.1, "Wider delivery body lost the shared center")
        identityCard.setStackIndex(0, count: 1, animated: false, visibleFrame: normal)
        identityPanel.contentView!.layoutSubtreeIfNeeded()
        try require(identityCaption.isHidden && identityBody.frame.minX == 0, "Returning to one card did not remove the ordinal gutter")
        identityCard.update(identityState, show: false)
        try require(identityCaption.isHidden, "Routine single-card update restored the hidden ordinal")
        identityCard.hide()

        let shortScreen = NSRect(x: 0, y: 0, width: 700, height: 280)
        let mixedFrames = (0..<8).map { DictationHUD.stackFrame(index: $0, count: 8, visibleFrame: shortScreen, preferredWidth: $0.isMultiple(of: 3) ? 360 : 118) }
        for (i, rect) in mixedFrames.enumerated() {
            try require(shortScreen.contains(rect), "Wide delivery card escaped short screen")
            for other in mixedFrames.prefix(i) { try require(!rect.intersects(other), "Mixed delivery/activity widths overlapped") }
        }

        // Estimates advance only toward values supplied by the owner. The
        // fill is monotonic, completion is real, and UI interpolation is small.
        var progress = DictationHUDProgress()
        progress.receive(nil, complete: false, active: true)
        progress.advance(seconds: 1, reduceMotion: false)
        try require(progress.target == nil && progress.displayed == 0, "Unknown progress invented an estimate")
        progress.receive(0.60, complete: false, active: true)
        progress.advance(seconds: 1.0 / 60, reduceMotion: false)
        try require(progress.displayed > 0 && progress.displayed < 0.60, "New progress jumped without an intermediate visual frame")
        var previousProgress = progress.displayed
        for _ in 0..<120 {
            progress.advance(seconds: 1.0 / 60, reduceMotion: false)
            try require(progress.displayed >= previousProgress && progress.displayed <= 0.60, "Estimated fill moved backward or invented completion")
            previousProgress = progress.displayed
        }
        progress.receive(0.20, complete: false, active: true)
        try require(progress.target == 0.60, "A revised estimate visually rewound the fill")
        progress.receive(.nan, complete: false, active: true)
        try require(progress.target == 0.60, "Invalid progress corrupted the previous estimate")
        progress.receive(0.88, complete: false, active: true)
        progress.advance(seconds: 0, reduceMotion: true)
        try require(progress.displayed == 0.88, "Reduced motion kept interpolating progress")
        progress.receive(nil, complete: true, active: true)
        try require(progress.target == 1 && progress.displayed == 0.88 && progress.complete, "Actual completion skipped the final fill transition")
        progress.advance(seconds: 0.05, reduceMotion: false)
        try require(progress.displayed > 0.88 && progress.displayed < 1, "Completion fill had no intermediate frame")
        progress.receive(nil, complete: true, active: true)
        progress.advance(seconds: 0.05, reduceMotion: false)
        try require(progress.displayed == 1, "Completion did not reach full fill within 100 ms or restarted on repeated state")
        progress.receive(0.50, complete: false, active: false)
        try require(progress.target == nil && progress.displayed == 0 && !progress.complete, "Recording/fallback retained a previous processing fill")
        progress.receive(-1, complete: false, active: true)
        progress.advance(seconds: 0, reduceMotion: true)
        try require(progress.displayed == 0, "Negative progress drew outside the capsule")
        progress.receive(2, complete: false, active: true)
        progress.advance(seconds: 0, reduceMotion: true)
        try require(progress.displayed == 1 && !progress.complete, "Progress clamp inferred business completion")
        let otherSurface = field(cards[2], "surface", NSView.self)!
        let otherProgress = field(otherSurface, "progress", DictationHUDProgress.self)?.target
        var completeState = states[0]; completeState.processingComplete = true
        cards[0].update(completeState, show: false)
        try require(field(cards[0], "title", NSTextField.self)?.stringValue == "已整理", "Final result kept an in-progress label")
        for outcome in ["unchanged", "suspected_insufficient", "failed", "skipped", "future_status"] {
            completeState.processingCompletionTitle = DictationCleanupOutcome(status: outcome).completionTitle
            cards[0].update(completeState, show: false)
            try require(field(cards[0], "title", NSTextField.self)?.stringValue == completeState.processingCompletionTitle,
                        "Completion implied cleanup success for \(outcome)")
        }
        let surface = field(cards[0], "surface", NSView.self)!
        try require(field(surface, "progress", DictationHUDProgress.self)?.target == 1, "Final result did not target full internal fill")
        var recordAgain = states[3]; recordAgain.processingProgress = 0.7
        cards[0].update(recordAgain, show: false)
        try require(field(surface, "progress", DictationHUDProgress.self)?.target == nil, "A new recording retained processing progress")
        cards[0].update(states[0], show: false)

        cards[0].showDelivery(message: "已复制 · 按 ⌘V 粘贴", needsPermission: false, show: false)
        try require(field(otherSurface, "progress", DictationHUDProgress.self)?.target == otherProgress, "One segment delivery reset another segment progress")
        try require(field(surface, "progress", DictationHUDProgress.self)?.target == nil, "Copy fallback retained internal progress")
        let copy = field(cards[0], "copyButton", NSButton.self)!
        try require(!copy.isHidden, "Fallback lost per-result copy action")
        copy.performClick(nil)
        try require(copies == [0], "Copy button did not preserve the original result's callback")
        let pendingHide = field(cards[0], "deliveryHide", DispatchWorkItem.self)!
        cards[1].hide()
        try require(!pendingHide.isCancelled, "Hiding a different card cancelled this delivery")
        try require(field(cards[2], "title", NSTextField.self)?.stringValue == "正在整理", "Hiding a card changed another job's display")
        cards[0].showDelivery(message: "前段尚未确认填入 · 点击复制", needsPermission: false, show: false)
        try require(field(cards[0], "deliveryHide", DispatchWorkItem.self) != nil, "A completed copy fallback has no expiry and will remain indefinitely")
        try require(pendingHide.isCancelled && !copy.isHidden, "Replacement fallback retained the old hide or lost copy action")
        cards[0].onCopy = nil
        cards[0].showDelivery(message: "未识别到文字", needsPermission: false, show: false)
        try require(copy.isHidden, "A non-copy delivery retained a stale copy action")

        cards[0].onCopy = { copies.append(0) }
        cards[0].showDelivery(message: "已复制 · 需要允许自动填入", needsPermission: true, show: false)
        let deliveryPanel = field(cards[0], "panel", NSPanel.self)!, deliveryContent = deliveryPanel.contentView!
        deliveryContent.layoutSubtreeIfNeeded()
        var deliveryControls = ["deliveryMessage", "copyButton", "permissionButton"].compactMap { field(cards[0], $0, NSView.self) }
        deliveryControls.append(field(cards[0], "deliveryRow", NSStackView.self)!.arrangedSubviews.last!)
        let deliveryRects = deliveryControls.map { $0.convert($0.bounds, to: deliveryContent) }
        try require(surface.bounds.width >= 180 && surface.bounds.width <= 360, "Delivery width is not bounded independently")
        for rect in deliveryRects { try require(deliveryContent.bounds.contains(rect), "Delivery action escaped resized card") }
        for (left, right) in zip(deliveryRects, deliveryRects.dropFirst()) { try require(left.maxX <= right.minX, "Copy and permission actions overlap") }

        // Attention and retry reuse the same nonactivating production panel.
        // Keep the warning readable after copying, lock duplicate taps, and
        // cancel the previous result's expiry while a retry is processing.
        let retryCard = DictationHUD()
        defer { retryCard.hide() }
        var retries = 0, views = 0
        retryCard.onRetryCleanup = { retries += 1 }
        retryCard.onViewResult = { views += 1 }
        retryCard.onCopy = { retryCard.showDelivery(message: "改动较少，请检查 · 已复制", needsPermission: false, show: false) }
        retryCard.showDelivery(message: "改动较少，请检查", needsPermission: false, show: false)
        let retry = field(retryCard, "retryButton", NSButton.self)!
        let view = field(retryCard, "viewButton", NSButton.self)!
        let retryCopy = field(retryCard, "copyButton", NSButton.self)!
        try require(!retry.isHidden && retry.isEnabled && !view.isHidden, "Attention lost its explicit retry/view actions")
        let attentionExpiry = field(retryCard, "deliveryHide", DispatchWorkItem.self)!
        retryCopy.performClick(nil)
        try require(field(retryCard, "deliveryMessage", NSTextField.self)?.stringValue == "改动较少，请检查 · 已复制", "Copy erased the attention state")
        try require(attentionExpiry.isCancelled, "Copy feedback left the preceding attention timer active")
        let copiedAttentionExpiry = field(retryCard, "deliveryHide", DispatchWorkItem.self)!
        retry.performClick(nil); retry.performClick(nil)
        try require(retries == 1 && !retry.isEnabled, "Repeated tap queued duplicate edits")
        retryCard.showDelivery(message: "正在重新整理", needsPermission: false, show: false, retrying: true)
        copiedAttentionExpiry.perform()
        try require(!retry.isEnabled && !view.isEnabled && !retryCopy.isEnabled && field(retryCard, "deliveryHide", DispatchWorkItem.self) == nil,
                    "In-flight retry retained enabled actions or an expiry")
        try require(copiedAttentionExpiry.isCancelled && field(retryCard, "deliveryMessage", NSTextField.self)?.stringValue == "正在重新整理",
                    "The preceding result's expiry interrupted a running retry")
        retryCard.showDelivery(message: "重新整理未完成", needsPermission: false, show: false)
        retry.performClick(nil)
        try require(retries == 2, "Failed retry could not be attempted again")
        retryCard.showDelivery(message: "原文未改 · 新版本已保存", needsPermission: false, show: false)
        view.performClick(nil)
        try require(views == 1 && retry.isEnabled, "Unchanged revision lost view or retry")
        let retryPanel = field(retryCard, "panel", NSPanel.self)!
        retryPanel.contentView!.layoutSubtreeIfNeeded()
        let retryRow = field(retryCard, "deliveryRow", NSStackView.self)!
        let retryRects = retryRow.arrangedSubviews.filter { !$0.isHidden }.map { $0.convert($0.bounds, to: retryPanel.contentView!) }
        for rect in retryRects { try require(retryPanel.contentView!.bounds.contains(rect), "Retry action escaped the actual HUD") }
        for (left, right) in zip(retryRects, retryRects.dropFirst()) { try require(left.maxX <= right.minX + 0.5, "Retry actions overlap") }
        try require(retryCard.frame.width <= 360 && !retryPanel.canBecomeKey && !retryPanel.canBecomeMain, "Retry widened the HUD or stole input focus")

        // Exercise the actual asynchronous expiry with hidden production HUDs.
        // Finished reminders must expire without touching another recording,
        // while a user can still open permission settings before their expiry.
        let expiringCopy = DictationHUD(), expiringPermission = DictationHUD(), reused = DictationHUD()
        let expiringAttention = DictationHUD(), dismissedAttention = DictationHUD()
        var expiredResultActions = 0
        expiringAttention.onCopy = { expiredResultActions += 1 }
        expiringAttention.onRetryCleanup = { expiredResultActions += 1 }
        expiringAttention.onViewResult = { expiredResultActions += 1 }
        let attentionStarted = ProcessInfo.processInfo.systemUptime
        expiringAttention.showDelivery(message: "原文未改 · 已复制 · 按 ⌘V 粘贴", needsPermission: false, show: false)
        let automaticAttentionExpiry = field(expiringAttention, "deliveryHide", DispatchWorkItem.self)!
        let attentionDismissal = expiringAttention.dismissalGeneration
        expiringCopy.onCopy = {}; expiringPermission.onCopy = {}
        expiringCopy.showDelivery(message: "已复制 · 按 ⌘V 粘贴", needsPermission: false, show: false)
        expiringPermission.showDelivery(message: "已复制 · 需要允许自动填入", needsPermission: true, show: false)
        try require(field(expiringCopy, "deliveryHide", DispatchWorkItem.self) != nil && field(expiringPermission, "deliveryHide", DispatchWorkItem.self) != nil,
                    "A copy or permission reminder has no bounded expiry")
        let recording = states[3]
        reused.onRetryCleanup = {}
        reused.showDelivery(message: "原文未改", needsPermission: false, show: false)
        let oldExpiry = field(reused, "deliveryHide", DispatchWorkItem.self)!
        reused.update(recording, show: false)
        oldExpiry.perform()
        try require(oldExpiry.isCancelled && field(reused, "deliveryHide", DispatchWorkItem.self) == nil && field(reused, "recordingRow", NSView.self)?.isHidden == false,
                    "An old reminder expired a subsequent recording")
        dismissedAttention.onRetryCleanup = {}
        dismissedAttention.showDelivery(message: "原文未改", needsPermission: false, show: false)
        let manuallyCancelledExpiry = field(dismissedAttention, "deliveryHide", DispatchWorkItem.self)!
        let dismissButton = field(dismissedAttention, "deliveryRow", NSStackView.self)!.arrangedSubviews.last as! NSButton
        dismissButton.performClick(nil)
        let manualDismissal = dismissedAttention.dismissalGeneration
        manuallyCancelledExpiry.perform()
        try require(manuallyCancelledExpiry.isCancelled && field(dismissedAttention, "deliveryHide", DispatchWorkItem.self) == nil
                    && dismissedAttention.dismissalGeneration == manualDismissal,
                    "Closing an attention card left a timer that dismissed it again")
        let permissionAction = DictationHUD()
        var permissionClicks = 0, dismissedBeforePermission = false
        permissionAction.onAccessibility = {
            permissionClicks += 1
            dismissedBeforePermission = field(permissionAction, "deliveryHide", DispatchWorkItem.self) == nil
        }
        permissionAction.showDelivery(message: "已复制 · 需要允许自动填入", needsPermission: true, show: false)
        let permissionExpiry = field(permissionAction, "deliveryHide", DispatchWorkItem.self)!
        let allow = field(permissionAction, "permissionButton", NSButton.self)!
        try require(!allow.isHidden && allow.isEnabled, "Finite reminder disabled its permission action")
        allow.performClick(nil)
        try require(permissionClicks == 1 && dismissedBeforePermission && permissionExpiry.isCancelled,
                    "Permission action did not dismiss the reminder before opening settings")
        let expiryDeadline = ProcessInfo.processInfo.systemUptime + 5.5
        while (field(expiringCopy, "deliveryHide", DispatchWorkItem.self) != nil || field(expiringPermission, "deliveryHide", DispatchWorkItem.self) != nil)
                && ProcessInfo.processInfo.systemUptime < expiryDeadline { wait(0.01) }
        try require(field(expiringCopy, "deliveryHide", DispatchWorkItem.self) == nil && field(expiringPermission, "deliveryHide", DispatchWorkItem.self) == nil,
                    "Copy or permission reminder did not expire within its five-second lifetime")
        try require(!automaticAttentionExpiry.isCancelled && expiringAttention.dismissalGeneration == attentionDismissal,
                    "Attention did not allow its longer review interval")
        let attentionDeadline = attentionStarted + 15.5
        while field(expiringAttention, "deliveryHide", DispatchWorkItem.self) != nil
                && ProcessInfo.processInfo.systemUptime < attentionDeadline { wait(0.01) }
        let attentionElapsed = ProcessInfo.processInfo.systemUptime - attentionStarted
        try require(field(expiringAttention, "deliveryHide", DispatchWorkItem.self) == nil && automaticAttentionExpiry.isCancelled
                    && expiringAttention.dismissalGeneration == attentionDismissal + 1 && attentionElapsed >= 14.8 && attentionElapsed <= 15.5,
                    "Attention did not expire automatically after fifteen seconds")
        try require(expiredResultActions == 0, "Expiry invoked a result action instead of only dismissing the card")
        try require(field(reused, "recordingRow", NSView.self)?.isHidden == false, "Expiring completed reminders interrupted another recording")
        for item in [expiringCopy, expiringPermission, expiringAttention, dismissedAttention, reused, permissionAction] { item.hide() }

        // Progress paints only the background. Compare actual rendered pixels
        // inside the cancel circle at three fills; antialiased edge pixels are
        // excluded because they necessarily composite with surrounding pixels.
        let layerCard = DictationHUD()
        layerCard.setStackIndex(0, count: 2, animated: false, visibleFrame: normal)
        var layerState = states[0]; layerState.sessionLabel = "第8段"
        let layerDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("hud-progress-layers-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: layerDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: layerDirectory) }
        var layerFrames: [NSBitmapImageRep] = []
        for (index, fill) in [0.0, 0.5, 0.99].enumerated() {
            layerState.processingProgress = fill
            let url = layerDirectory.appendingPathComponent("layer-\(index).png")
            try layerCard.renderPNG(to: url, state: layerState, animationTime: Double(index), reduceMotion: true)
            layerFrames.append(NSBitmapImageRep(data: try Data(contentsOf: url))!)
        }
        let layerPanel = field(layerCard, "panel", NSPanel.self)!, layerContent = layerPanel.contentView!
        let layerCancel = field(layerCard, "cancel", NSButton.self)!
        let buttonRect = layerCancel.convert(layerCancel.bounds, to: layerContent)
        let scale = Double(layerFrames[0].pixelsWide) / layerContent.bounds.width
        func rgb(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> [Double] {
            let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
            return [color.redComponent, color.greenComponent, color.blueComponent]
        }
        var greatestControlDifference = 0.0
        let interiorRadius = max(1, Int(9 * scale))
        for dy in -interiorRadius...interiorRadius { for dx in -interiorRadius...interiorRadius where dx * dx + dy * dy <= interiorRadius * interiorRadius {
            let x = Int(buttonRect.midX * scale) + dx
            let y = Int(buttonRect.midY * scale) + dy
            let original = rgb(layerFrames[0], x: x, y: y)
            for bitmap in layerFrames.dropFirst() {
                greatestControlDifference = max(greatestControlDifference, zip(original, rgb(bitmap, x: x, y: y)).map { abs($0 - $1) }.max()!)
            }
        }}
        try require(greatestControlDifference <= 1.0 / 255, "Progress tinted the cancel button or icon: \(greatestControlDifference)")
        let layerSurface = field(layerCard, "surface", NSView.self)!
        let backgroundX = Int((layerSurface.frame.minX + 10) * scale)
        let backgroundY = Int(layerSurface.bounds.midY * scale)
        let dark = rgb(layerFrames[0], x: backgroundX, y: backgroundY)
        let filled = rgb(layerFrames[1], x: backgroundX, y: backgroundY)
        try require(zip(dark, filled).contains { abs($0 - $1) > 0.05 }, "Layer isolation accidentally removed the visible progress fill")
        try require(layerCancel.layer?.backgroundColor?.alpha == 1 && field(layerCard, "title", NSTextField.self)?.alphaValue == 1,
                    "Foreground controls still blend transparently with processing progress")
        layerState.processingProgress = 0.99
        try layerCard.renderPNG(to: layerDirectory.appendingPathComponent("layer-motion.png"), state: layerState, animationTime: 2.5, reduceMotion: false)
        try require(field(layerCard, "title", NSTextField.self)?.alphaValue == 1, "Processing still fades the foreground text")

        if let option = CommandLine.arguments.firstIndex(of: "--output"), CommandLine.arguments.count > option + 1 {
            let destination = URL(fileURLWithPath: CommandLine.arguments[option + 1], isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for (name, message, retrying) in [
                ("cleanup-failed", "整理未完成，已保留原文", false),
                ("cleanup-unchanged", "原文未改", false),
                ("cleanup-check", "改动较少，请检查", false),
                ("cleanup-retrying", "正在重新整理", true),
                ("cleanup-revision", "新版本已保存", false)
            ] {
                retryCard.onViewResult = name == "cleanup-revision" ? { views += 1 } : nil
                retryCard.onRetryCleanup = name == "cleanup-revision" ? nil : { retries += 1 }
                retryCard.showDelivery(message: message, needsPermission: false, show: false, retrying: retrying)
                let content = retryPanel.contentView!
                content.layoutSubtreeIfNeeded()
                if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: destination.appendingPathComponent(name + ".png"))
                }
            }
            for index in 0..<3 {
                let source = layerDirectory.appendingPathComponent("layer-\(index).png")
                try Data(contentsOf: source).write(to: destination.appendingPathComponent("background-layer-\(index).png"))
            }
            if let bitmap = deliveryContent.bitmapImageRepForCachingDisplay(in: deliveryContent.bounds) {
                deliveryContent.cacheDisplay(in: deliveryContent.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: destination.appendingPathComponent("delivery-permission.png"))
            }
            for (index, card) in cards.enumerated() {
                for frame in 0..<36 {
                    try card.renderPNG(to: destination.appendingPathComponent("hud-\(index + 1).png"), state: states[index], animationTime: Double(frame) / 60)
                }
            }
            let progressCard = DictationHUD()
            for (name, value) in [("progress-10", 0.10), ("progress-50", 0.50), ("progress-94", 0.94), ("progress-complete", 1.0)] {
                var state = states[0]; state.processingProgress = value; state.processingComplete = value == 1
                try progressCard.renderPNG(to: destination.appendingPathComponent(name + ".png"), state: state, reduceMotion: true)
            }
            for count in [1, 2, 4] {
                let indexes = count == 1 ? [3] : count == 2 ? [0, 3] : [0, 1, 2, 3]
                for (row, index) in indexes.enumerated() {
                    cards[index].setStackIndex(row, count: count, animated: false, visibleFrame: normal)
                    try cards[index].renderPNG(to: destination.appendingPathComponent("stack-\(count)-card-\(row).png"), state: states[index], reduceMotion: true)
                }
                let size = NSSize(width: 220, height: CGFloat(count * 46 + 52))
                let sheet = NSImage(size: size); sheet.lockFocus()
                NSColor(calibratedWhite: 0.96, alpha: 1).setFill(); NSRect(origin: .zero, size: size).fill()
                for (row, index) in indexes.enumerated() {
                    let image = NSImage(contentsOf: destination.appendingPathComponent("stack-\(count)-card-\(row).png"))!
                    let gutter: CGFloat = count > 1 ? 24 : 0
                    image.draw(in: NSRect(x: 44 - gutter, y: CGFloat(32 + row * 46), width: cards[index].frame.width, height: 34))
                }
                sheet.unlockFocus()
                if let tiff = sheet.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) {
                    try bitmap.representation(using: .png, properties: [:])?.write(to: destination.appendingPathComponent("stack-\(count).png"))
                }
            }
        }
        if CommandLine.arguments.contains("--visible") {
            // Opt-in verification uses only this process's nonactivating panels.
            // It never invokes AX actions or changes the target application.
            DictationMotion.reduceMotionOverride = false
            var hidden: [Int] = []
            let previousKey = NSApp.keyWindow
            for (index, card) in cards.enumerated() {
                card.onDidHide = { hidden.append(index) }
                card.setStackIndex(index, count: 4, animated: false)
                card.update(states[index])
            }
            try require(cards.allSatisfy(\.isVisible), "Visible stack omitted a session")
            try require(NSApp.keyWindow === previousKey, "Stack activated a key window")
            let startY = cards[3].frame.minY
            cards[0].hide(); cards[0].hide()
            try require(hidden == [0], "Hide callback fired more than once")
            cards[3].setStackIndex(2, count: 3)
            wait(0.06)
            let intermediateY = cards[3].frame.minY
            try require(intermediateY < startY && intermediateY > four[2].minY, "Stack compaction has no intermediate frame")
            cards[3].setStackIndex(1, count: 2)
            wait(0.22)
            try require(abs(cards[3].frame.minY - four[1].minY) < 0.5, "Interrupted compaction reached a stale target")
            try require(cards[1...3].allSatisfy(\.isVisible), "One hide removed unrelated sessions")
            DictationMotion.reduceMotionOverride = true
            cards[3].setStackIndex(0, count: 1)
            try require(abs(cards[3].frame.minY - first.minY) < 0.5, "Reduced motion retained spatial movement")
            cards[2].showDelivery(message: "已复制 · 按 ⌘V 粘贴", needsPermission: false)
            let dismiss = field(cards[2], "deliveryHide", DispatchWorkItem.self)!
            dismiss.perform()
            try require(!cards[2].isVisible && hidden == [0, 2], "Delivery dismissal did not notify stack owner")
        }
    }
}
