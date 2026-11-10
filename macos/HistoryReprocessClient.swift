import Foundation

struct HistoryReprocessResult: Decodable {
    let raw_text: String
    let text: String
    let cleanup_seconds: Double
    let cleanup_applied: Bool
    let warning: String?
    let cleanup_profile: DictationCleanupProfile?
    var cleanup_outcome: DictationCleanupOutcome? = nil
}

/// Explicit text-only request to the existing loopback worker. There is no
/// automatic retry: a lost response must not silently trigger another edit.
final class HistoryReprocessClient {
    private let base: URL
    private let session: URLSession
    init(base: URL, session: URLSession = .shared) { self.base = base; self.session = session }

    @discardableResult
    func reprocess(rawText: String, versionID: String, preferences: DictationPreferences,
                   completion: @escaping (Result<HistoryReprocessResult, Error>) -> Void) -> URLSessionDataTask? {
        do {
            let body = try JSONSerialization.data(withJSONObject: ["raw_text": rawText])
            guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !versionID.isEmpty, body.count <= 128 * 1024 else {
                throw Self.failure("原文为空或过长，无法重新整理。原记录仍保留。")
            }
            let options = try DictationStore.encodeRequestOptions(cleanup: true,
                language: preferences.recognitionLanguage, vocabulary: preferences.vocabulary,
                corrections: preferences.correctionHints)
            let encodedOptions = options.base64EncodedString()
            guard encodedOptions.utf8.count <= DictationStore.maxOptionsHeaderBytes else {
                throw Self.failure("个人词典超出请求容量，请调整后重试。")
            }
            var request = URLRequest(url: base.appendingPathComponent("cleanup/reprocess"))
            request.httpMethod = "POST"; request.httpBody = body; request.timeoutInterval = 60
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(encodedOptions, forHTTPHeaderField: "X-Dictation-Options")
            request.setValue(versionID, forHTTPHeaderField: "X-Cleanup-Prompt-Version")
            let task = session.dataTask(with: request) { data, response, error in
                let result: Result<HistoryReprocessResult, Error>
                do {
                    if let error { throw error }
                    guard let response = response as? HTTPURLResponse, let data else {
                        throw Self.failure("本地服务没有返回整理结果。")
                    }
                    guard (200..<300).contains(response.statusCode) else {
                        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                        throw Self.failure(object?["error"] as? String ?? "重新整理失败，请检查本地服务。")
                    }
                    let value = try JSONDecoder().decode(HistoryReprocessResult.self, from: data)
                    guard value.cleanup_applied, !["failed", "skipped"].contains(value.cleanup_outcome?.status ?? "") else {
                        throw Self.failure(value.warning ?? "本次整理未完成，原记录仍保留。", outcome: value.cleanup_outcome)
                    }
                    guard value.raw_text == rawText, value.cleanup_profile?.versionID == versionID,
                          !value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          value.cleanup_seconds.isFinite, value.cleanup_seconds >= 0 else {
                        throw Self.failure("整理结果或规则版本不匹配，未保存本次结果。")
                    }
                    result = .success(value)
                } catch { result = .failure(error) }
                DispatchQueue.main.async { completion(result) }
            }
            task.resume()
            return task
        } catch {
            // Always asynchronous, including preflight failures, so the owner
            // can register its generation/task before handling completion.
            DispatchQueue.main.async { completion(.failure(error)) }
            return nil
        }
    }
    private static func failure(_ message: String, outcome: DictationCleanupOutcome? = nil) -> NSError {
        var detail: [String: Any] = [NSLocalizedDescriptionKey: message]
        // Keep the worker's failure category for diagnostics even though a
        // failed attempt must not create a successful history revision.
        if let outcome {
            detail["cleanup_outcome_status"] = outcome.status
            detail["cleanup_outcome_reason"] = outcome.reason
            detail["cleanup_outcome_error_type"] = outcome.errorType
        }
        return NSError(domain: "HistoryReprocess", code: 1, userInfo: detail)
    }
}
