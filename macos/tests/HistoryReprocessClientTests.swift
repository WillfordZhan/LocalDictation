import Foundation

/// Every URL is intercepted, including accidental endpoint changes. No test
/// can fall through to a real HTTP server or the user's running application.
private final class HistoryStubProtocol: URLProtocol {
    enum Reply {
        case http(Int, Data)
        case failure(Error)
        case nonHTTP
    }
    struct Captured {
        let request: URLRequest
        let body: Data?
    }
    private static let lock = NSLock()
    private static var reply: Reply = .failure(URLError(.unsupportedURL))
    private static var captured: [Captured] = []

    static func prepare(_ next: Reply) {
        lock.lock(); defer { lock.unlock() }
        reply = next; captured = []
    }
    static func requests() -> [Captured] {
        lock.lock(); defer { lock.unlock() }
        return captured
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var collected = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                collected.append(buffer, count: count)
            }
            body = collected
        }
        Self.lock.lock()
        Self.captured.append(Captured(request: request, body: body))
        let response = Self.reply
        Self.lock.unlock()
        switch response {
        case .http(let status, let data):
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .nonHTTP:
            client?.urlProtocol(self, didReceive: URLResponse(url: request.url!, mimeType: "text/plain",
                expectedContentLength: 2, textEncodingName: "utf-8"), cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

@main
enum HistoryReprocessClientTests {
    static func main() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HistoryStubProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = HistoryReprocessClient(base: URL(string: "http://127.0.0.1:1")!, session: session)
        var preferences = DictationPreferences(); preferences.cleanupEnabled = false; preferences.vocabulary = ["BOM"]
        let raw = "嗯，BOM 要保留。"
        let valid: [String: Any] = ["raw_text": raw, "text": "保留 BOM。", "cleanup_seconds": 0.3,
            "cleanup_applied": true, "cleanup_profile": ["version_id": "selected", "name": "简洁",
                "content_sha256": "hash", "model_id": "fixture-model"]]
        func call(_ reply: HistoryStubProtocol.Reply, input: String? = nil, modelID: String? = nil,
                  afterDispatch: (() -> Void)? = nil) -> Result<HistoryReprocessResult, Error> {
            HistoryStubProtocol.prepare(reply)
            var result: Result<HistoryReprocessResult, Error>?
            _ = client.reprocess(rawText: input ?? raw, versionID: "selected", modelID: modelID, preferences: preferences) {
                precondition(Thread.isMainThread); result = $0
            }
            afterDispatch?()
            let deadline = Date().addingTimeInterval(3)
            while result == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
            precondition(result != nil)
            return result!
        }
        let success = call(.http(200, try JSONSerialization.data(withJSONObject: valid)))
        let responseValue = try success.get()
        precondition(responseValue.cleanup_profile?.versionID == "selected")
        let request = HistoryStubProtocol.requests()[0]
        precondition(HistoryStubProtocol.requests().count == 1 && request.request.url?.path == "/cleanup/reprocess")
        precondition(request.request.value(forHTTPHeaderField: "X-Cleanup-Prompt-Version") == "selected")
        let options = try JSONSerialization.jsonObject(with: Data(base64Encoded: request.request.value(forHTTPHeaderField: "X-Dictation-Options")!)!) as! [String: Any]
        precondition(options["cleanup"] as? Bool == true && options["vocabulary"] as? [String] == ["BOM"])
        let body = try JSONSerialization.jsonObject(with: request.body!) as! [String: String]
        precondition(body == ["raw_text": raw])

        let selectedModelReply = valid.merging(["model_load_seconds": 1.25]) { _, new in new }
        let modelResult = try call(.http(200, try JSONSerialization.data(withJSONObject: selectedModelReply)), modelID: "fixture-model").get()
        let modelRequest = HistoryStubProtocol.requests()[0]
        let modelBody = try JSONSerialization.jsonObject(with: modelRequest.body!) as! [String: String]
        precondition(modelBody == ["raw_text": raw, "model_id": "fixture-model"])
        precondition(modelResult.model_load_seconds == 1.25)
        if case .success = call(.http(200, try JSONSerialization.data(withJSONObject: valid)), modelID: "another-model") {
            preconditionFailure("A response from a different model cannot be saved as the selected test")
        }
        let invalidTiming = valid.merging(["model_load_seconds": -0.1]) { _, new in new }
        if case .success = call(.http(200, try JSONSerialization.data(withJSONObject: invalidTiming)), modelID: "fixture-model") {
            preconditionFailure("Accepted invalid loading timing")
        }
        if case .success = call(.nonHTTP, modelID: "") { preconditionFailure("Empty model selection must fail locally") }
        precondition(HistoryStubProtocol.requests().isEmpty)

        // A history retry freezes learned mappings with its other preferences.
        // Editing the dictionary while HTTP is in flight must not alter that
        // request, rewrite the saved ASR, or activate the selected prompt.
        let initialPreferences = preferences
        preferences.vocabulary = ["BOM", "SalesPart", "UndoneTerm"]
        preferences.learnedVocabulary = [
            DictationLearnedVocabulary(id: UUID(), original: "SalesPrat", corrected: "SalesPart",
                createdAt: Date(), bundleID: nil, entryID: UUID()),
            DictationLearnedVocabulary(id: UUID(), original: "UndoenTerm", corrected: "UndoneTerm",
                createdAt: Date(), bundleID: nil, entryID: UUID(), undone: true),
            DictationLearnedVocabulary(id: UUID(), original: "RemvoedTerm", corrected: "RemovedTerm",
                createdAt: Date(), bundleID: nil, entryID: UUID())
        ]
        let correctionRaw = "嗯，SalesPrat 要保留。"
        let correctionReply = valid.merging(["raw_text": correctionRaw, "text": "保留 SalesPart。"]) { _, replacement in replacement }
        let correctionResult = try call(.http(200, try JSONSerialization.data(withJSONObject: correctionReply)), input: correctionRaw) {
            preferences.vocabulary = ["ChangedLater"]
            preferences.learnedVocabulary = []
        }.get()
        let correctionRequests = HistoryStubProtocol.requests()
        precondition(correctionRequests.count == 1 && correctionRequests[0].request.url?.path == "/cleanup/reprocess",
                     "History retry sent an extra request or activated the selected prompt")
        let correctionRequest = correctionRequests[0]
        let correctionOptions = try JSONSerialization.jsonObject(with: Data(base64Encoded: correctionRequest.request.value(forHTTPHeaderField: "X-Dictation-Options")!)!) as! [String: Any]
        precondition(correctionOptions["vocabulary"] as? [String] == ["BOM", "SalesPart", "UndoneTerm"])
        precondition(correctionOptions["corrections"] as? [[String: String]] == [["original": "SalesPrat", "corrected": "SalesPart"]],
                     "Frozen request lost its correction, included revoked mappings, or read newer preferences")
        let correctionBody = try JSONSerialization.jsonObject(with: correctionRequest.body!) as! [String: String]
        precondition(correctionBody == ["raw_text": correctionRaw] && correctionResult.raw_text == correctionRaw,
                     "Correction hints mutated the original ASR")
        precondition(correctionRequest.request.value(forHTTPHeaderField: "X-Cleanup-Prompt-Version") == "selected")
        precondition(preferences.vocabulary == ["ChangedLater"] && preferences.learnedVocabulary.isEmpty,
                     "History retry mutated current preferences")
        preferences = initialPreferences
        for modification in [["cleanup_applied": false], ["raw_text": "wrong"], ["text": ""], ["cleanup_seconds": -1],
                             ["cleanup_profile": ["version_id": "wrong", "name": "n", "content_sha256": "h", "model_id": "m"]]] as [[String: Any]] {
            let value = valid.merging(modification) { _, replacement in replacement }
            if case .success = call(.http(200, try JSONSerialization.data(withJSONObject: value))) { preconditionFailure("Accepted invalid or unapplied result") }
        }
        for status in ["unchanged", "suspected_insufficient", "future_status"] {
            let value = valid.merging(["cleanup_outcome": ["status": status, "reason": "fixture_reason"]]) { _, replacement in replacement }
            let decoded = try call(.http(200, try JSONSerialization.data(withJSONObject: value))).get()
            precondition(decoded.cleanup_outcome?.status == status && decoded.cleanup_outcome?.reason == "fixture_reason")
        }
        for status in ["failed", "skipped"] {
            for applied in [true, false] {
                let outcome = ["status": status, "reason": "invalid_model_output", "error_type": "CleanupOutputError"]
                let value = valid.merging(["cleanup_applied": applied, "cleanup_outcome": outcome]) { _, replacement in replacement }
                switch call(.http(200, try JSONSerialization.data(withJSONObject: value))) {
                case .success: preconditionFailure("A failed/skipped attempt became a successful history revision")
                case .failure(let error):
                    let detail = (error as NSError).userInfo
                    precondition(detail["cleanup_outcome_status"] as? String == status)
                    precondition(detail["cleanup_outcome_reason"] as? String == "invalid_model_output")
                    precondition(detail["cleanup_outcome_error_type"] as? String == "CleanupOutputError")
                }
            }
        }
        for status in [400, 409, 503] {
            if case .success = call(.http(status, Data("{\"error\":\"fixture unavailable\"}".utf8))) { preconditionFailure() }
            precondition(HistoryStubProtocol.requests().count == 1)
        }
        if case .success = call(.failure(URLError(.networkConnectionLost))) { preconditionFailure() }
        precondition(HistoryStubProtocol.requests().count == 1, "An explicit retry must never be automatically replayed")
        if case .success = call(.http(200, Data("bad json".utf8))) { preconditionFailure() }
        if case .success = call(.nonHTTP) { preconditionFailure() }
        for invalid in ["  ", String(repeating: "长", count: 50000)] {
            if case .success = call(.nonHTTP, input: invalid) { preconditionFailure() }
            precondition(HistoryStubProtocol.requests().isEmpty)
        }
        print("PASS history reprocess client: one text-only request, explicit frozen version, vocabulary and correction snapshot, unchanged raw/current preferences, no audio/activation, fallback/invalid/error rejection, no retry, main-thread completion")
    }
}

