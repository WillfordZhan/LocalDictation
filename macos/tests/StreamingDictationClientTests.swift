import Foundation

private final class StreamStub: URLProtocol {
    struct Seen { let path: String; let method: String; let body: Data; let offset: String?; let options: String?; let prompt: String? }
    enum Scenario { case normal, delayedStart, delayedAudio, delayedFinish, invalidAck, pollCrossing, failedFinish, failedStart, transportFailure }
    private static let lock = NSLock()
    private static var scenario: Scenario = .normal
    private static var seen: [Seen] = []
    private static var counts: [String: Int64] = [:]
    private static var activeAudio = 0
    private(set) static var maximumAudio = 0
    private var isStopped = false
    static func prepare(_ scenario: Scenario) {
        lock.lock(); defer { lock.unlock() }
        self.scenario = scenario; seen = []; counts = [:]; activeAudio = 0; maximumAudio = 0
    }
    static func requests() -> [Seen] { lock.lock(); defer { lock.unlock() }; return seen }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body: Data
        if let data = request.httpBody { body = data }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; data.append(buffer, count: count)
            }
            body = data
        } else { body = Data() }
        let path = request.url!.path
        Self.lock.lock()
        let scenario = Self.scenario
        Self.seen.append(Seen(path: path, method: request.httpMethod ?? "GET", body: body,
            offset: request.value(forHTTPHeaderField: "X-Audio-Offset"), options: request.value(forHTTPHeaderField: "X-Dictation-Options"),
            prompt: request.value(forHTTPHeaderField: "X-Cleanup-Prompt-Version")))
        Self.lock.unlock()
        var delay = 0.005
        if path == "/stream/start", scenario == .delayedStart { delay = 0.15 }
        if path.hasSuffix("/finish"), scenario == .delayedFinish { delay = 0.15 }
        if path.hasSuffix("/audio") {
            Self.lock.lock(); Self.activeAudio += 1; Self.maximumAudio = max(Self.maximumAudio, Self.activeAudio); Self.lock.unlock()
            if scenario == .delayedAudio { delay = 0.15 }
            if scenario == .pollCrossing { delay = 1.0 }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            Self.lock.lock()
            if path.hasSuffix("/audio") { Self.activeAudio -= 1 }
            guard !isStopped else { Self.lock.unlock(); return }
            if path.hasSuffix("/audio"), scenario == .transportFailure {
                Self.lock.unlock()
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                return
            }
            var status = 200, object: [String: Any] = [:]
            let id: String
            if path == "/stream/start" {
                id = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["session_id"] as? String ?? "invalid"
                Self.counts[id] = 0
            } else { id = path.split(separator: "/").dropFirst().first.map(String.init) ?? "invalid" }
            var count = Self.counts[id] ?? 0
            if path.hasSuffix("/cancel") {
                status = Self.counts[id] == nil ? 404 : 200
                object = ["cancelled": true]
            } else if path.hasSuffix("/finish") {
                status = scenario == .failedFinish ? 503 : 200
                object = status == 200 ? ["raw_text": "原文", "text": "最终结果"] : ["detail": "fixture unavailable"]
            } else {
                if path.hasSuffix("/audio") {
                    count += Int64(body.count / 2)
                    Self.counts[id] = count
                    if scenario == .invalidAck { count += 1 }
                }
                if request.httpMethod == "GET", scenario == .pollCrossing { count = 8000 }
                object = ["session_id": id, "state": "recording", "received_samples": count,
                    "processed_samples": request.httpMethod == "GET" && scenario == .pollCrossing ? count : 0,
                    "raw_text": request.httpMethod == "GET" && scenario == .pollCrossing ? "已有草稿" : ""]
            }
            if path == "/stream/start", scenario == .failedStart {
                status = 429; object = ["detail": "fixture queue full"]
            }
            Self.lock.unlock()
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: object))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { Self.lock.lock(); isStopped = true; Self.lock.unlock() }
}

@main enum StreamingClientChecks {
    static var checks = 0
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw NSError(domain: "StreamingClientChecks", code: checks, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func wait(_ condition: () -> Bool, timeout: Double = 3) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        try require(condition(), "Fixture timed out")
    }
    static func settle(_ seconds: Double = 0.25) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    static func make(_ session: URLSession) -> StreamingDictationClient {
        StreamingDictationClient(baseURL: URL(string: "http://127.0.0.1:1")!, session: session,
            optionsHeader: "frozen-options", promptVersionID: "frozen-prompt", sessionID: UUID())
    }
    static func main() {
        do { try run(); print("PASS: \(checks) streaming client checks (URLProtocol only; no network)") }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func run() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamStub.self]; configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        StreamStub.prepare(.delayedStart)
        let client = make(session)
        var finalCount = 0, failure: String?, callbacksMain = true
        client.onFinal = { _, _, _ in finalCount += 1; callbacksMain = callbacksMain && Thread.isMainThread }
        client.onFailure = { failure = $0 }
        client.onProgress = { _ in callbacksMain = callbacksMain && Thread.isMainThread }
        client.start()
        client.appendPCM(Data(repeating: 1, count: 16000), offset: 0)
        client.appendPCM(Data(repeating: 2, count: 16000), offset: 8000)
        client.appendPCM(Data(repeating: 3, count: 222), offset: 16000)
        client.finish(totalSamples: 16111)
        client.finish(totalSamples: 16111)
        try wait { finalCount == 1 || failure != nil }
        try require(failure == nil && callbacksMain, "Callbacks failed or left main thread")
        let requests = StreamStub.requests()
        try require(requests.map { $0.path.split(separator: "/").last! } == ["start", "audio", "audio", "audio", "finish"], "Finish overtook audio or duplicate finish")
        try require(requests.filter { $0.path.hasSuffix("/audio") }.map { $0.offset! } == ["0", "8000", "16000"], "Incorrect ordered offsets")
        try require(requests[0].options == "frozen-options" && requests[0].prompt == "frozen-prompt", "Configuration snapshot changed")
        try require(StreamStub.maximumAudio == 1, "Audio uploads ran concurrently")
        try require(requests[3].body.count == 222, "Short tail was omitted")

        StreamStub.prepare(.normal)
        let first = make(session), second = make(session)
        var finals = 0
        first.onFinal = { _, _, _ in finals += 1 }; second.onFinal = { _, _, _ in finals += 1 }
        first.start(); second.start()
        first.appendPCM(Data(repeating: 0, count: 200), offset: 0); second.appendPCM(Data(repeating: 0, count: 400), offset: 0)
        first.finish(totalSamples: 100); second.finish(totalSamples: 200)
        try wait { finals == 2 }
        try require(StreamStub.requests().filter { $0.path.hasSuffix("/audio") }.allSatisfy { $0.offset == "0" }, "Clients shared offsets")

        StreamStub.prepare(.delayedFinish)
        let editing = make(session), recording = make(session)
        var editingFinished = false, recordingFinished = false
        editing.onFinal = { _, _, _ in editingFinished = true }; recording.onFinal = { _, _, _ in recordingFinished = true }
        editing.start(); editing.appendPCM(Data(repeating: 0, count: 200), offset: 0); editing.finish(totalSamples: 100)
        try wait { StreamStub.requests().contains { $0.path.hasSuffix("/finish") } }
        recording.start(); recording.appendPCM(Data(repeating: 0, count: 200), offset: 0); recording.finish(totalSamples: 100)
        try wait { StreamStub.requests().filter { $0.path.hasSuffix("/audio") }.count == 2 }
        try require(!editingFinished, "Second recording waited for previous editing response")
        try wait { editingFinished && recordingFinished }

        for scenario in [StreamStub.Scenario.failedStart, .transportFailure] {
            StreamStub.prepare(scenario)
            let failed = make(session)
            var failedCount = 0, finalized = false
            failed.onFailure = { _ in failedCount += 1 }; failed.onFinal = { _, _, _ in finalized = true }
            failed.start(); failed.appendPCM(Data(repeating: 0, count: 200), offset: 0); failed.finish(totalSamples: 100)
            try wait { failedCount == 1 }; settle()
            try require(!finalized && failedCount == 1, "Failed transport delivered final text")
            try require(!StreamStub.requests().contains { $0.path.hasSuffix("/finish") }, "Failed transport finalized incomplete audio")
            try require(StreamStub.requests().contains { $0.path.hasSuffix("/cancel") }, "Failed transport omitted explicit server cancellation")
        }

        StreamStub.prepare(.delayedStart)
        var cancelled: StreamingDictationClient? = make(session)
        weak var weakCancelled = cancelled
        defer { weakCancelled = nil }
        var cancelCallback = false
        cancelled?.onFinal = { _, _, _ in cancelCallback = true }; cancelled?.onFailure = { _ in cancelCallback = true }
        cancelled?.start(); cancelled?.appendPCM(Data(repeating: 0, count: 100), offset: 0)
        cancelled?.cancel(); cancelled = nil
        try wait { StreamStub.requests().filter { $0.path.hasSuffix("/cancel") }.count == 2 }
        settle()
        try require(!cancelCallback, "Cancelled start delivered output")
        try require(weakCancelled == nil, "Client was leaked after late cancellation")
        try require(!StreamStub.requests().contains { $0.path.hasSuffix("/audio") || $0.path.hasSuffix("/finish") }, "Cancelled start submitted audio")

        StreamStub.prepare(.delayedAudio)
        let during = make(session)
        during.start(); during.appendPCM(Data(repeating: 0, count: 100), offset: 0); during.finish(totalSamples: 50)
        try wait { StreamStub.requests().contains { $0.path.hasSuffix("/audio") } }
        during.cancel(); settle()
        try require(StreamStub.requests().contains { $0.path.hasSuffix("/cancel") }, "Audio cancellation was only local")
        try require(!StreamStub.requests().contains { $0.path.hasSuffix("/finish") }, "Cancelled audio finalized")

        StreamStub.prepare(.invalidAck)
        let invalid = make(session)
        var failures = 0
        invalid.onFailure = { _ in failures += 1 }
        invalid.start(); invalid.appendPCM(Data(repeating: 0, count: 100), offset: 0); invalid.finish(totalSamples: 50)
        try wait { failures == 1 }
        settle()
        try require(failures == 1 && !StreamStub.requests().contains { $0.path.hasSuffix("/finish") }, "Invalid ACK was finalized")
        try require(StreamStub.requests().contains { $0.path.hasSuffix("/cancel") }, "Invalid ACK did not cancel server")

        StreamStub.prepare(.normal)
        let gap = make(session)
        var gapFailure = 0
        gap.onFailure = { _ in gapFailure += 1 }
        gap.appendPCM(Data(repeating: 0, count: 20), offset: 1)
        try require(gapFailure == 1 && StreamStub.requests().isEmpty, "Offset gap accepted")
        let cap = make(session)
        cap.onFailure = { _ in gapFailure += 1 }
        cap.appendPCM(Data(repeating: 0, count: 9_600_002), offset: 0)
        try require(gapFailure == 2, "Unbounded audio buffer accepted")

        StreamStub.prepare(.pollCrossing)
        let crossing = make(session)
        var drafts: [String] = [], done = false
        crossing.onProgress = { drafts.append($0.rawText) }; crossing.onFinal = { _, _, _ in done = true }
        crossing.start(); crossing.appendPCM(Data(repeating: 0, count: 16000), offset: 0); crossing.finish(totalSamples: 8000)
        try wait({ done }, timeout: 4)
        try require(drafts.last == "已有草稿", "Older audio ACK erased newer poll draft")

        StreamStub.prepare(.failedFinish)
        let failed = make(session)
        var finalStatus: Int?
        failed.onFinal = { _, response, _ in finalStatus = (response as? HTTPURLResponse)?.statusCode }
        failed.start(); failed.finish(totalSamples: 0)
        try wait { finalStatus != nil }; settle()
        try require(finalStatus == 503, "Finish error did not reach established final decoder")
        try require(StreamStub.requests().contains { $0.path.hasSuffix("/cancel") }, "Failed finish was left running")
    }
}
