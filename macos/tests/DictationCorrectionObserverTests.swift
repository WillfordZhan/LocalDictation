import AppKit
import ApplicationServices

/// Injected snapshots only: these tests never read the user's focused app,
/// install keyboard hooks, write the clipboard, or call a model.
@main
enum DictationCorrectionObserverTests {
    static func main() {
        func replays(_ before: String, _ after: String, source: String, destination: String,
                     file: StaticString, line: UInt) {
            precondition(DictationCorrectionDetector.correctedRanges(in: before, edited: after,
                source: source, destination: destination) != nil,
                "Accepted correction cannot be replayed: \(before) -> \(after); \(source) -> \(destination)", file: file, line: line)
        }
        func detects(_ before: String, _ after: String, _ expected: (String, String)?, file: StaticString = #file, line: UInt = #line) {
            let result = DictationCorrectionDetector.correction(in: before, edited: after)
            precondition(result?.original == expected?.0 && result?.corrected == expected?.1,
                "Unexpected correction: \(before) -> \(after); got \(String(describing: result))", file: file, line: line)
            // Every accepted path must provide the same complete edit ranges
            // used by the observer, including candidates requiring confirmation.
            if let result { replays(before, after, source: result.original, destination: result.corrected, file: file, line: line) }
            if let candidate = DictationCorrectionDetector.candidate(in: before, edited: after) {
                replays(before, after, source: candidate.original, destination: candidate.corrected, file: file, line: line)
            }
        }
        detects("修复 SalesPrat 的问题。", "修复 SalesPart 的问题。", ("SalesPrat", "SalesPart"))
        detects("使用 bom 配置。", "使用 BOM 配置。", ("bom", "BOM"))
        detects("读取 A S R 结果。", "读取 ASR 结果。", ("A S R", "ASR"))
        detects("使用 ProductPrat。", "使用 ProductPart。", ("ProductPrat", "ProductPart"))
        detects("采用 Tideless。", "采用 Typeless。", nil)
        detects("采用 Typeles。", "采用 Typeless。", nil) // Ambiguous capitalized ordinary word.
        detects("更新 Cdoex。", "更新 Codex。", ("Cdoex", "Codex"))
        detects("测试 C+。", "测试 C++。", ("C+", "C++"))
        detects("调整莫型。", "调整模型。", ("莫型", "模型"))
        detects("修正 API借口。", "修正 API接口。", ("借口", "接口"))
        detects("修正 API绘画。", "修正 API会话。", ("绘画", "会话"))
        detects("修正借口API。", "修正接口API。", ("借口", "接口"))
        detects("这里需要改变。", "这里需要修改。", nil)
        detects("请部署 SalesPart。", "请删除 SalesPart。", nil)
        detects("run cat", "run car", nil)
        detects("port 8080", "port 8081", nil)
        detects("version v2.1", "version v2.2", nil)
        detects("修复 SalesPart。", "修复 SalesPart。再检查一次。", nil)
        detects("修复 SalesPart。", "", nil)
        detects("修复 SalesPart。", "修复。", nil)
        detects("修复 SalesPart。", "修复 SalesPart！", nil)
        detects("a SalesPrat b ProductPrat", "a SalesPart b ProductPart", nil)
        detects("🍎 用 SalesPrat。", "🍎 用 SalesPart。", ("SalesPrat", "SalesPart"))
        detects("A", "B", nil)
        detects("hello world", "Hello world", nil)
        detects("SalesPar", "SalesPart", nil)
        detects("SalesPart", "SalesPar", nil)
        detects("比较 SalesPrat 和 SalesPrat。", "比较 SalesPart 和 SalesPart。", ("SalesPrat", "SalesPart"))
        detects("比较 SalesPrat 和 SalesPrat。", "比较 SalesPart 和 SalesPrat。", ("SalesPrat", "SalesPart"))
        detects("比较 SalesPrat 和 ProductPrat。", "比较 SalesPart 和 ProductPart。", nil)
        detects("比较 SalesPrat 和 SalesPart。", "比较 SalesPart 和 SalesPrat。", nil)
        detects("计算 pass ratio 的值。", "计算 pathRatio 的值。", ("pass ratio", "pathRatio"))
        detects("计算 pass ratio 的值。", "计算 path ratio 的值。", nil)

        // Lower-case phrases cannot be promoted to automatic terminology by
        // spelling similarity alone. Preserve their full scope for confirmation.
        let phrase = DictationCorrectionDetector.candidate(in: "计算 pass ratio 的值。", edited: "计算 path ratio 的值。")
        precondition(phrase?.original == "pass ratio" && phrase?.corrected == "path ratio" && phrase?.requiresConfirmation == true,
                     "A spaced, lower-case correction needs a complete confirmation candidate")
        func suggests(_ before: String, _ after: String, _ expected: (String, String)?, file: StaticString = #file, line: UInt = #line) {
            let result = DictationCorrectionDetector.candidate(in: before, edited: after)
            precondition(result?.original == expected?.0 && result?.corrected == expected?.1 &&
                         (result == nil || result?.requiresConfirmation == true),
                         "Unexpected confirmation: \(before) -> \(after); got \(String(describing: result))", file: file, line: line)
            if let result { replays(before, after, source: result.original, destination: result.corrected, file: file, line: line) }
        }
        suggests("检查 cache lime 的值。", "检查 cache line 的值。", ("cache lime", "cache line"))
        suggests("检查 cache ration 的值。", "检查 cache ratio 的值。", ("cache ration", "cache ratio"))
        suggests("🍎 检查 pass ratio，再看 pass ratio。", "🍎 检查 path ratio，再看 path ratio。", ("pass ratio", "path ratio"))
        suggests("检查 pass ratio，再看 pass ratio。", "检查 path ratio，再看 pass ratio。", ("pass ratio", "path ratio"))
        suggests("检查 pass ratio，再看 cache lime。", "检查 path ratio，再看 cache line。", nil)
        suggests("计算 pass ratio。", "删除 path ratio。", nil)
        suggests("计算 pass ratio。", "计算 path ratio。再检查一次。", nil)
        suggests("计算 pass ratio。", "计算 path percentage。", nil)
        suggests("计算 pass ratio。", "计算 path ratio2。", nil)
        suggests("计算 ratio 8080。", "计算 ratio 8081。", nil)
        suggests("run cat", "run car", nil)
        suggests("we saw cat", "we saw car", nil)
        suggests("please change the cat", "please change the car", nil)
        suggests("cat", "car", nil)
        suggests("hello world", "Hello world", nil)
        suggests("计算 pass ratio。", "计算 pass  ratio。", nil)

        let element = AXUIElementCreateApplication(getpid()) // Identity fixture, never queried.
        var now: TimeInterval = 100
        var snapshot: DictationCorrectionReadResult = .unavailable
        var candidates: [DictationCorrectionCandidate] = []
        let readQueue = DispatchQueue(label: "fixture.correction-reader", qos: .utility)
        let observer = DictationCorrectionObserver(reader: { _, _ in snapshot }, clock: { now },
            pollsAutomatically: false, readQueue: readQueue)
        func drain(_ queue: DispatchQueue) {
            // Every queued read posts consume to main before this queue marker
            // can run. Its main marker therefore proves both phases completed,
            // including reads that leave availability unchanged. A wall-clock
            // delay cannot establish that ordering under scheduler contention.
            let completed = DispatchGroup(); completed.enter()
            queue.async { DispatchQueue.main.async { completed.leave() } }
            let deadline = Date().addingTimeInterval(2)
            while completed.wait(timeout: .now()) != .success {
                precondition(Date() < deadline, "Reader/main completion did not drain")
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
            }
        }
        observer.onCorrection = { precondition(Thread.isMainThread); candidates.append($0) }
        let entryID = UUID()
        func text(_ value: String, caret: Int? = nil, selected: Int = 0) {
            snapshot = .snapshot(DictationCorrectionSnapshot(text: value,
                selection: CFRange(location: caret ?? value.utf16.count, length: selected)))
        }
        func tick(_ advance: TimeInterval = 0) {
            now += advance; observer.sampleNow()
            drain(readQueue)
        }
        func begin(_ value: String = "修复 SalesPrat。", offset: Int = 0) {
            now = 100
            observer.observeInsertion(pid: getpid(), element: element, range: CFRange(location: offset, length: 0),
                text: value, entryID: entryID, bundleID: "fixture.editor")
            precondition(observer.availability == .confirming)
        }
        func confirmed(_ value: String = "修复 SalesPrat。") {
            begin(value); text(value); tick(); precondition(observer.availability == .observing)
        }
        confirmed()
        text("修复 SalesPart。")
        tick(); tick(1)
        precondition(candidates.isEmpty, "Must wait for a stable correction")
        tick(0.6)
        precondition(candidates.count == 1 && candidates[0].entryID == entryID && candidates[0].original == "SalesPrat"
            && candidates[0].corrected == "SalesPart" && candidates[0].bundleID == "fixture.editor")
        precondition(observer.availability == .learned)
        tick(1); precondition(candidates.count == 1, "An unchanged result must not be learned again")

        begin(offset: 3); text("前文：修复 SalesPrat。", caret: 0); tick(); tick(2.1)
        precondition(observer.availability == .unconfirmed, "Posting paste does not prove insertion")
        begin(); text("another field"); tick(); tick(2.1)
        precondition(observer.availability == .unconfirmed)
        begin(); snapshot = .unavailable; tick()
        precondition(observer.availability == .unsupported)

        confirmed(); text("修复 SalesPart。", selected: 0); tick()
        snapshot = .focusChanged; tick(2)
        precondition(observer.availability == .idle && candidates.count == 1)
        confirmed(); text(""); tick(2)
        precondition(observer.availability == .idle && candidates.count == 1, "Submitted/cleared text cannot be learned")
        confirmed(); text("修复 SalesPart。"); tick(); tick(121)
        precondition(observer.availability == .idle && candidates.count == 1)
        confirmed(); text("修复 SalesPrat。追加内容。"); tick(); tick(1.6)
        precondition(observer.availability == .observing && candidates.count == 1)
        confirmed(); text("请删除这个模块并重新写一遍。"); tick(); tick(1.6)
        precondition(observer.availability == .observing && candidates.count == 1)

        let inserted = "🍎 修复 SalesPrat。", prefix = "前文：", suffix = " 后文"
        begin(inserted, offset: prefix.utf16.count)
        text(prefix + inserted + suffix, caret: prefix.utf16.count + inserted.utf16.count); tick()
        precondition(observer.availability == .observing)
        text(prefix + "🍎 修复 SalesPart。" + suffix, caret: prefix.utf16.count + inserted.utf16.count)
        tick(); tick(1.6)
        precondition(candidates.count == 2 && candidates.last?.corrected == "SalesPart", "UTF-16 AX offsets must preserve surrounding text")
        begin(inserted, offset: prefix.utf16.count)
        text(prefix + inserted + suffix, caret: prefix.utf16.count + inserted.utf16.count); tick()
        text("被改的前文：" + inserted + suffix); tick()
        precondition(observer.availability == .idle && candidates.count == 2)
        confirmed(); text("修复 SalesPart。", caret: 0, selected: 2); tick(); tick(2)
        precondition(candidates.count == 2, "An active selection is not a stable edit")
        text("修复 SalesPart。"); tick()
        precondition(candidates.count == 3)

        begin(); text(String(repeating: "x", count: DictationCorrectionObserver.maximumFieldLength + 1)); tick()
        precondition(observer.availability == .unsupported)
        observer.observeInsertion(pid: getpid(), element: element, range: CFRange(location: Int.max, length: 0),
            text: "SalesPrat", entryID: entryID, bundleID: nil)
        precondition(observer.availability == .unsupported)

        confirmed("计算 pass ratio，再核对 pass ratio。")
        text("计算 path ratio，再核对 path ratio。")
        tick(); tick(1.6)
        precondition(candidates.count == 4 && candidates.last?.original == "pass ratio" &&
                     candidates.last?.corrected == "path ratio" && candidates.last?.requiresConfirmation == true &&
                     observer.availability == .awaitingConfirmation,
                     "A verified phrase edit must ask for confirmation, never report automatic learning")
        tick(2)
        precondition(candidates.count == 4, "A pending confirmation must not repeatedly prompt")
        precondition(candidates.prefix(3).allSatisfy { !$0.requiresConfirmation }, "Existing high-confidence corrections changed policy")

        // A user often selects a typo as soon as text appears. The exact
        // dictated span still proves insertion when the selection is inside it.
        begin(); text("修复 SalesPrat。", caret: 3, selected: 9); tick()
        precondition(observer.availability == .observing, "Selecting the dictated term must not prevent confirmation")
        text("修复 SalesPart。"); tick(); tick(1.6)
        precondition(candidates.count == 5 && candidates.last?.corrected == "SalesPart")

        // Stable punctuation and appended prose may precede the actual term
        // correction. They change the comparison baseline, not its provenance.
        confirmed(); text("修复 SalesPrat！"); tick(); tick(1.6)
        text("修复 SalesPrat！然后检查。"); tick(); tick(1.6)
        precondition(candidates.count == 5 && observer.availability == .observing)
        text("修复 SalesPart！然后检查。"); tick(); tick(1.6)
        precondition(candidates.count == 6 && candidates.last?.corrected == "SalesPart",
                     "A prior non-term edit must not disable a later correction")

        // Both corrections belong to one verified paste and one fixed deadline.
        confirmed("修复 SalesPrat 和 ProductPrat。")
        text("修复 SalesPart 和 ProductPrat。"); tick(); tick(1.6)
        text("修复 SalesPart 和 ProductPart。"); tick(); tick(1.6)
        precondition(candidates.count == 8 && candidates[6].corrected == "SalesPart" &&
                     candidates[7].corrected == "ProductPart" && candidates[6].entryID == candidates[7].entryID,
                     "Distinct stable corrections in one insertion must both be learned")
        tick(2); tick(2)
        precondition(candidates.count == 8, "Polling an unchanged baseline must not duplicate learning")
        text("修复 SalesPrat 和 ProductPart。"); tick(); tick(1.6)
        text("修复 SalesPart 和 ProductPart。"); tick(); tick(1.6)
        precondition(candidates.count == 8, "Undo and redo of a learned pair must not create inverse or duplicate learning")
        tick(121)
        precondition(observer.availability == .idle, "Rebasing must not renew the observation deadline")

        // Text typed after dictation cannot become fresh ASR training data.
        confirmed(); text("修复 SalesPrat。手动追加 ProductPrat。"); tick(); tick(1.6)
        text("修复 SalesPrat。手动追加 ProductPart。"); tick(); tick(1.6)
        precondition(candidates.count == 8, "A correction confined to newly typed text must not be learned")
        text("修复 SalesPart。手动追加 ProductPart。"); tick(); tick(1.6)
        precondition(candidates.count == 9 && candidates.last?.corrected == "SalesPart")

        confirmed(); text("修复 SalesPrat。手动追加 SalesPrat。"); tick(); tick(1.6)
        text("修复 SalesPrat。手动追加 SalesPart。"); tick(); tick(1.6)
        precondition(candidates.count == 9,
                     "A newly typed occurrence remains ineligible even when the same word was dictated")

        // Existing valid words are not taught in reverse when a correction is
        // undone, even when the destination already appeared elsewhere.
        confirmed("比较 SalesPrat 和 SalesPart。")
        text("比较 SalesPart 和 SalesPart。"); tick(); tick(1.6)
        text("比较 SalesPrat 和 SalesPart。"); tick(); tick(1.6)
        precondition(candidates.count == 10 && candidates.last?.original == "SalesPrat")

        // After a successful learn, all original boundary protections remain.
        snapshot = .focusChanged; tick()
        precondition(observer.availability == .idle)
        confirmed(); text("修复 SalesPart。"); tick(); tick(1.6)
        text(""); tick()
        precondition(candidates.count == 11 && observer.availability == .idle)
        begin(inserted, offset: prefix.utf16.count)
        text(prefix + inserted + suffix, caret: prefix.utf16.count + inserted.utf16.count); tick()
        text(prefix + "🍎 修复 SalesPart。" + suffix, caret: prefix.utf16.count + inserted.utf16.count); tick(); tick(1.6)
        text("被改的前文：" + "🍎 修复 SalesPart。" + suffix); tick()
        precondition(candidates.count == 12 && observer.availability == .idle)

        confirmed("修复 SalesPrat，再看 pass ratio。")
        text("修复 SalesPart，再看 pass ratio。"); tick(); tick(1.6)
        text("修复 SalesPart，再看 path ratio。"); tick(); tick(1.6)
        precondition(candidates.count == 14 && candidates.last?.requiresConfirmation == true &&
                     observer.availability == .awaitingConfirmation)
        text("修复 SalesPART，再看 path ratio。"); tick(); tick(2)
        precondition(candidates.count == 14, "A pending confirmation must retain its decision until handled")

        // Disjoint replacements of the same term must not erase the origin of
        // untouched text between them. Exercise equal, shorter and longer
        // replacements so later eligibility does not depend on stale offsets.
        for source in ["SalesPrat", "SalesPratt", "SalesPrt"] {
            let count = candidates.count
            confirmed("比较 \(source)、ProductPrat、\(source)。")
            text("比较 SalesPart、ProductPrat、SalesPart。"); tick(); tick(1.6)
            precondition(candidates.count == count + 1 && candidates.last?.corrected == "SalesPart",
                         "Repeated source term \(source) must first produce one correction")
            text("比较 SalesPart、ProductPart、SalesPart。"); tick(); tick(1.6)
            precondition(candidates.count == count + 2 && candidates.last?.corrected == "ProductPart",
                         "Unchanged middle term lost its dictation origin after disjoint replacements")
        }

        let prefixWordCount = candidates.count
        confirmed("比较 SalesPart 和 SalesPar。")
        text("比较 SalesPart 和 SalesPart。"); tick(); tick(1.6)
        precondition(candidates.count == prefixWordCount + 1 && candidates.last?.original == "SalesPar" &&
                     candidates.last?.corrected == "SalesPart",
                     "An unchanged correct word must not consume the shorter source as an identifier prefix")

        for ending in [".", "...", ". Then check."] {
            let sentenceCount = candidates.count
            confirmed("Use SalesPrat\(ending)")
            text("Use SalesPart\(ending)"); tick(); tick(1.6)
            precondition(candidates.count == sentenceCount + 1,
                         "Sentence punctuation already excluded by tokenization must not block replay")
        }
        precondition(DictationCorrectionDetector.correctedRanges(in: "pkg.SalesPar", edited: "pkg.SalesPart",
            source: "SalesPar", destination: "SalesPart") == nil,
            "A qualified identifier must not be replayed as an isolated suffix")
        precondition(DictationCorrectionDetector.correctedRanges(in: "SalesPar.js", edited: "SalesPart.js",
            source: "SalesPar", destination: "SalesPart") == nil,
            "An internal identifier dot is not sentence punctuation")
        precondition(DictationCorrectionDetector.correctedRanges(in: "SalesPar./file", edited: "SalesPart./file",
            source: "SalesPar", destination: "SalesPart") == nil,
            "A path boundary must not be treated as sentence punctuation")

        // An older AX response may return after the next paste. Its generation
        // must be discarded even when the two fields contain identical text.
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let delayedQueue = DispatchQueue(label: "fixture.delayed-correction-reader", qos: .utility)
        var blockedReads = 0, lateCandidates = 0
        let delayed = DictationCorrectionObserver(reader: { _, _ in
            blockedReads += 1
            if blockedReads == 1 { started.signal(); _ = release.wait(timeout: .now() + 2) }
            return .snapshot(DictationCorrectionSnapshot(text: "SalesPrat", selection: CFRange(location: 9, length: 0)))
        }, clock: { now }, pollsAutomatically: false, readQueue: delayedQueue)
        delayed.onCorrection = { _ in lateCandidates += 1 }
        delayed.observeInsertion(pid: getpid(), element: element, range: CFRange(location: 0, length: 0), text: "SalesPrat", entryID: UUID(), bundleID: nil)
        delayed.sampleNow(); precondition(started.wait(timeout: .now() + 1) == .success)
        // Hold the real asynchronous boundary beyond the former tick window:
        // a 25ms run loop turn must not be mistaken for a completed AX read.
        RunLoop.current.run(until: Date().addingTimeInterval(0.025))
        precondition(delayed.availability == .confirming && lateCandidates == 0)
        delayed.observeInsertion(pid: getpid(), element: element, range: CFRange(location: 0, length: 0), text: "OtherWord", entryID: UUID(), bundleID: nil)
        release.signal(); drain(delayedQueue)
        precondition(delayed.availability == .confirming && lateCandidates == 0)
        delayed.stop(); observer.stop()
        print("PASS correction observer: automatic terminology confidence, complete phrase confirmation, repeated replacements, verified insertion and in-span selection, stability, continuous corrections, harmless-edit rebasing, original-term provenance, undo/redo deduplication, UTF-16 scope, focus/submission/fixed timeout, unsupported AX, read/main completion ordering, blocked-reader late callback isolation")
    }
}
