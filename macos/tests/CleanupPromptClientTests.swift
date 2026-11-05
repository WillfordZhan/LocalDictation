import Foundation

/// Every URL is intercepted, including accidental endpoint changes. No test
/// can fall through to a real HTTP server or the user's running application.
private final class PromptStubProtocol: URLProtocol {
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
enum CleanupPromptClientChecks {
    static var checks = 0
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw NSError(domain: "CleanupPromptClientChecks", code: checks,
            userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func main() {
        do { try run(); print("PASS: \(checks) CleanupPromptClient checks (URLProtocol only, no network)") }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func awaitResult(_ start: (@escaping (Result<CleanupPromptCatalog, Error>) -> Void) -> Void)
        throws -> Result<CleanupPromptCatalog, Error> {
        var received: Result<CleanupPromptCatalog, Error>?, onMain = false
        start { result in onMain = Thread.isMainThread; received = result }
        let deadline = Date().addingTimeInterval(3)
        while received == nil && Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        try require(received != nil, "Client callback timed out")
        try require(onMain, "Client callback did not run on the main thread")
        return received!
    }
    private static func onlyRequest(_ method: String, _ path: String) throws -> PromptStubProtocol.Captured {
        let recorded = PromptStubProtocol.requests()
        try require(recorded.count == 1, "One operation made \(recorded.count) requests")
        let captured = recorded[0]
        try require(captured.request.httpMethod == method, "Unexpected HTTP method")
        try require(captured.request.url?.path == path, "Unexpected endpoint path")
        try require(captured.request.value(forHTTPHeaderField: "Origin") == nil, "Native request sent Origin")
        return captured
    }
    static func run() throws {
        try require(Thread.isMainThread, "Test runner must start on main thread")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PromptStubProtocol.self]
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = CleanupPromptClient(base: URL(string: "http://127.0.0.1:1/")!, session: session)
        let version = CleanupPromptVersion(id: "saved-version", name: "自然书面语", note: "保留人味。",
            created_at: "2026-11-04T09:30:00Z", model_id: "local-editor", system_prompt: "去掉冗余，保留判断。\n",
            user_prefix: "以下是素材：\n", examples: [CleanupPromptExample(source: "嗯，继续。", edited: "继续。")],
            content_sha256: String(repeating: "a", count: 64), origin: "user")
        let catalog = CleanupPromptCatalog(active_version_id: version.id, versions: [version],
            current_model: CleanupPromptModel(id: "local-editor", kind: "local", ready: true), asr_model: "local-asr")
        let data = try JSONEncoder().encode(catalog)

        PromptStubProtocol.prepare(.http(200, data))
        let loaded = try awaitResult(client.load).get()
        try require(loaded == catalog, "GET lost version content or model metadata")
        let load = try onlyRequest("GET", "/cleanup/prompts")
        try require(load.body == nil, "GET unexpectedly sent a body")

        PromptStubProtocol.prepare(.http(200, data))
        let saved = try awaitResult { client.save(version.draft, completion: $0) }.get()
        try require(saved == catalog, "Save response did not decode catalog")
        let save = try onlyRequest("POST", "/cleanup/prompts")
        try require(save.request.value(forHTTPHeaderField: "Content-Type") == "application/json", "Save lacks JSON content type")
        let body = try JSONSerialization.jsonObject(with: save.body!) as! [String: Any]
        try require(Set(body.keys) == ["name", "note", "system_prompt", "user_prefix", "examples"], "Save sent immutable IDs or omitted editable fields")
        try require(body["name"] as? String == version.name && body["note"] as? String == version.note, "Save changed metadata")
        try require(body["system_prompt"] as? String == version.system_prompt && body["user_prefix"] as? String == version.user_prefix,
                    "Save changed whitespace or Unicode in prompt")
        let examples = body["examples"] as? [[String: String]]
        try require(examples == [["source": "嗯，继续。", "edited": "继续。"]], "Save changed paired examples")

        PromptStubProtocol.prepare(.http(200, data))
        _ = try awaitResult { client.activate(id: version.id, completion: $0) }.get()
        let activate = try onlyRequest("POST", "/cleanup/prompts/activate")
        let activation = try JSONSerialization.jsonObject(with: activate.body!) as? [String: String]
        try require(activation == ["version_id": version.id], "Activation did not send only the chosen immutable ID")
        try require(activate.request.value(forHTTPHeaderField: "Content-Type") == "application/json", "Activation lacks JSON content type")

        // Both backend error shapes and failures before/after HTTP parsing must
        // reach the same main-thread completion path without a second request.
        let failures: [(PromptStubProtocol.Reply, String?)] = [
            (.http(400, Data("{\"error\":\"所选版本不存在\"}".utf8)), "所选版本不存在"),
            (.http(503, Data("{\"detail\":\"存储暂不可用\"}".utf8)), "存储暂不可用"),
            (.http(404, Data("missing".utf8)), "404"),
            (.http(200, Data("{invalid".utf8)), nil),
            (.failure(URLError(.cannotConnectToHost)), nil),
            (.nonHTTP, "没有返回规则数据")
        ]
        for (reply, message) in failures {
            PromptStubProtocol.prepare(reply)
            let result = try awaitResult(client.load)
            if case .failure(let error) = result {
                if let message { try require(error.localizedDescription.contains(message), "Useful failure detail was lost") }
            } else { try require(false, "Failed request reported success") }
            _ = try onlyRequest("GET", "/cleanup/prompts")
        }
    }
}
