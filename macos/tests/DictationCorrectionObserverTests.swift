import AppKit
import ApplicationServices

/// Injected snapshots only: these tests never read the user's focused app,
/// install keyboard hooks, write the clipboard, or call a model.
@main
enum DictationCorrectionObserverTests {
    static func main() {
        func detects(_ before: String, _ after: String, _ expected: (String, String)?, file: StaticString = #file, line: UInt = #line) {
            let result = DictationCorrectionDetector.correction(in: before, edited: after)
            precondition(result?.original == expected?.0 && result?.corrected == expected?.1,
                "Unexpected correction: \(before) -> \(after); got \(String(describing: result))", file: file, line: line)
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
        tick(1); precondition(candidates.count == 1, "An insertion can learn only once")

        begin(); text("修复 SalesPrat。", caret: 0); tick(); tick(2.1)
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
        precondition(observer.availability == .idle && candidates.count == 1)
        confirmed(); text("请删除这个模块并重新写一遍。"); tick(); tick(1.6)
        precondition(observer.availability == .idle && candidates.count == 1)

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
        print("PASS correction observer: automatic terminology confidence, complete phrase confirmation, repeated replacements, verified insertion, stability, UTF-16 scope, focus/submission/timeout, unsupported AX, one result, read/main completion ordering, blocked-reader late callback isolation")
    }
}
