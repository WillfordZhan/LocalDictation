import Foundation

struct StreamingDictationSnapshot: Decodable {
    let sessionID: String
    let state: String
    let receivedSamples: Int64
    let processedSamples: Int64
    let rawText: String
    let error: String?
    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id", state, receivedSamples = "received_samples"
        case processedSamples = "processed_samples", rawText = "raw_text", error
    }
}

/// One dictation owns one client and one immutable configuration. Audio requests
/// are acknowledged in order; the finalize request cannot overtake their tail.
/// Separate clients can upload while another session is editing its final text.
final class StreamingDictationClient {
    var onProgress: ((StreamingDictationSnapshot) -> Void)?
    var onFinal: ((Data?, URLResponse?, Error?) -> Void)?
    var onFailure: ((String) -> Void)?
    let sessionID: UUID
    private let baseURL: URL
    private let session: URLSession
    private let optionsHeader: String
    private let promptVersionID: String?
    private enum State { case idle, starting, streaming, finishing, terminal, cancelled }
    private struct AudioBlock { let data: Data; let offset: Int64 }
    private var state: State = .idle
    private var queued: [AudioBlock] = []
    private var acceptedSamples: Int64 = 0
    private var acknowledgedSamples: Int64 = 0
    private var finalSamples: Int64?
    private var task: URLSessionDataTask?
    private var progressTask: URLSessionDataTask?
    private var progressTimer: DispatchWorkItem?
    private var cancelTask: URLSessionDataTask?
    private var cancelAgain = false
    private var cancellationKeepAlive: StreamingDictationClient?
    private var startWasSent = false
    private var startPending = false
    private var finalWasSent = false
    private var lastReceived: Int64 = 0
    private var lastProcessed: Int64 = 0
    private var lastRawText = ""
    private var lastReportedState = ""
    private static let maximumSamples: Int64 = 300 * 16_000

    init(baseURL: URL, session: URLSession = .shared, optionsHeader: String, promptVersionID: String?, sessionID: UUID) {
        self.baseURL = baseURL; self.session = session; self.optionsHeader = optionsHeader
        self.promptVersionID = promptVersionID; self.sessionID = sessionID
    }

    func start() {
        precondition(Thread.isMainThread)
        guard state == .idle else { return }
        state = .starting; startWasSent = true; startPending = true
        var request = makeRequest(path: "stream/start", method: "POST")
        request.setValue(optionsHeader, forHTTPHeaderField: "X-Dictation-Options")
        if let promptVersionID { request.setValue(promptVersionID, forHTTPHeaderField: "X-Cleanup-Prompt-Version") }
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["session_id": sessionID.uuidString.lowercased()])
        // A cancelled client keeps itself alive only through cancellation and any
        // pending start, so a late successful start cannot escape server cleanup.
        task = session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                task = nil; startPending = false
                if state == .cancelled || state == .terminal { sendCancel(); return }
                guard let snapshot = decode(data, response: response, error: error, operation: "开始实时识别") else { return }
                guard snapshot.receivedSamples == 0 else { fail("实时识别会话已有音频，请重新开始。"); return }
                state = .streaming
                publish(snapshot)
                scheduleProgress()
                pump()
            }
        }
        task?.resume()
    }

    func appendPCM(_ data: Data, offset: Int64) {
        precondition(Thread.isMainThread)
        guard state == .idle || state == .starting || state == .streaming else { return }
        guard finalSamples == nil, !data.isEmpty, data.count % 2 == 0, offset == acceptedSamples else {
            fail("录音音频片段不连续，本次实时识别已停止。"); return
        }
        let count = Int64(data.count / 2)
        guard count <= Self.maximumSamples - acceptedSamples else { fail("录音已超过 5 分钟。"); return }
        // The complete session is bounded by the existing five-minute cap
        // (9.6 MB PCM), including data waiting for a delayed start response.
        queued.append(AudioBlock(data: data, offset: offset)); acceptedSamples += count
        if state == .streaming { pump() }
    }

    func finish(totalSamples: Int64) {
        precondition(Thread.isMainThread)
        guard state != .terminal && state != .cancelled else { return }
        if let finalSamples {
            if finalSamples != totalSamples { fail("录音结束位置不一致。"); return }
            return
        }
        guard totalSamples == acceptedSamples else { fail("录音尾部尚未完整传递，已停止提交。"); return }
        finalSamples = totalSamples
        if state == .idle { start() }
        else if state == .streaming { pump() }
    }

    private func pump() {
        guard state == .streaming, task == nil else { return }
        if !queued.isEmpty {
            let block = queued.removeFirst()
            guard block.offset == acknowledgedSamples else { fail("实时音频确认位置不一致。"); return }
            var request = makeRequest(path: sessionPath + "/audio", method: "POST")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue(String(block.offset), forHTTPHeaderField: "X-Audio-Offset")
            request.httpBody = block.data
            task = session.dataTask(with: request) { [weak self] data, response, error in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    task = nil
                    guard state == .streaming else { return }
                    guard let snapshot = decode(data, response: response, error: error, operation: "发送音频") else { return }
                    let expected = block.offset + Int64(block.data.count / 2)
                    guard snapshot.receivedSamples == expected else { fail("服务未完整确认音频片段。"); return }
                    acknowledgedSamples = expected
                    publish(snapshot)
                    pump()
                }
            }
            task?.resume()
            return
        }
        guard let finalSamples, !finalWasSent else { return }
        guard finalSamples == acknowledgedSamples else { fail("录音尾部没有获得确认。"); return }
        finalWasSent = true; state = .finishing
        var request = makeRequest(path: sessionPath + "/finish", method: "POST")
        request.timeoutInterval = 300
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["total_samples": finalSamples])
        task = session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                task = nil
                guard state == .finishing else { return }
                state = .terminal; stopProgress(); queued.removeAll()
                if error != nil || !(response is HTTPURLResponse) || !((200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0)) { sendCancel() }
                // Preserve the established final JSON/error path in AppDelegate.
                // This client never performs insertion or retries final delivery.
                onFinal?(data, response, error)
            }
        }
        task?.resume()
    }

    func cancel() {
        precondition(Thread.isMainThread)
        guard state != .cancelled else { return }
        state = .cancelled; queued.removeAll(); stopProgress()
        // Let a pending start complete so cancellation can cover the race where
        // the server creates the session after receiving our first cancel.
        if !startPending { task?.cancel(); task = nil }
        if startWasSent { sendCancel() }
    }

    private func sendCancel() {
        guard startWasSent else { return }
        cancellationKeepAlive = self
        if cancelTask != nil { cancelAgain = true; return }
        var request = makeRequest(path: sessionPath + "/cancel", method: "POST")
        request.httpBody = Data("{}".utf8)
        cancelTask = session.dataTask(with: request) { [weak self] _, _, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                cancelTask = nil
                if cancelAgain { cancelAgain = false; sendCancel() }
                else if !startPending { cancellationKeepAlive = nil }
            }
        }
        cancelTask?.resume()
    }

    private func fail(_ message: String) {
        guard state != .terminal && state != .cancelled else { return }
        state = .terminal; queued.removeAll(); stopProgress()
        if !startPending { task?.cancel(); task = nil }
        if startWasSent { sendCancel() }
        onFailure?(message)
    }

    private func decode(_ data: Data?, response: URLResponse?, error: Error?, operation: String) -> StreamingDictationSnapshot? {
        if let error { fail(operation + "失败：" + error.localizedDescription); return nil }
        guard let response = response as? HTTPURLResponse, let data else { fail(operation + "未返回有效响应。"); return nil }
        guard (200..<300).contains(response.statusCode) else {
            let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let detail = (payload?["detail"] as? String) ?? (payload?["error"] as? String) ?? "请检查本地服务。"
            fail(operation + "失败：" + String(detail.prefix(220))); return nil
        }
        guard data.count <= 1_048_576,
              let snapshot = try? JSONDecoder().decode(StreamingDictationSnapshot.self, from: data),
              UUID(uuidString: snapshot.sessionID) == sessionID,
              snapshot.receivedSamples >= 0, snapshot.receivedSamples <= acceptedSamples,
              snapshot.processedSamples >= 0, snapshot.processedSamples <= snapshot.receivedSamples else {
            fail("实时识别响应格式或音频位置不匹配。"); return nil
        }
        if snapshot.state == "failed" || snapshot.state == "cancelled" {
            fail(snapshot.error ?? "本次实时识别已停止。"); return nil
        }
        return snapshot
    }

    private func publish(_ snapshot: StreamingDictationSnapshot) {
        guard state != .terminal && state != .cancelled else { return }
        // Polls and upload acknowledgements may cross in flight. Never replace a
        // newer partial transcript/progress with an older server snapshot.
        guard snapshot.receivedSamples >= lastReceived, snapshot.processedSamples >= lastProcessed else { return }
        if snapshot.receivedSamples == lastReceived && snapshot.processedSamples == lastProcessed,
           snapshot.rawText == lastRawText && snapshot.state == lastReportedState { return }
        lastReceived = snapshot.receivedSamples; lastProcessed = snapshot.processedSamples
        lastRawText = snapshot.rawText; lastReportedState = snapshot.state
        onProgress?(snapshot)
    }

    private func scheduleProgress() {
        guard state == .streaming || state == .finishing else { return }
        let scheduled = DispatchWorkItem { [weak self] in self?.poll() }
        progressTimer = scheduled
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: scheduled)
    }

    private func poll() {
        progressTimer = nil
        guard state == .streaming || state == .finishing, progressTask == nil else { return }
        let request = makeRequest(path: sessionPath, method: "GET")
        progressTask = session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                progressTask = nil
                guard state == .streaming || state == .finishing else { return }
                // Status reads are advisory. A transient observation failure must
                // not discard audio whose serial upload is still succeeding.
                if error == nil, let response = response as? HTTPURLResponse, response.statusCode == 200,
                   let data, data.count <= 1_048_576,
                   let snapshot = try? JSONDecoder().decode(StreamingDictationSnapshot.self, from: data),
                   UUID(uuidString: snapshot.sessionID) == sessionID,
                   snapshot.receivedSamples >= 0, snapshot.receivedSamples <= acceptedSamples,
                   snapshot.processedSamples >= 0, snapshot.processedSamples <= snapshot.receivedSamples {
                    if snapshot.state == "failed" || snapshot.state == "cancelled" { fail(snapshot.error ?? "本次实时识别已停止。"); return }
                    publish(snapshot)
                }
                scheduleProgress()
            }
        }
        progressTask?.resume()
    }

    private func stopProgress() {
        progressTimer?.cancel(); progressTimer = nil
        progressTask?.cancel(); progressTask = nil
    }

    private var sessionPath: String { "stream/" + sessionID.uuidString.lowercased() }
    private func makeRequest(path: String, method: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }
}
