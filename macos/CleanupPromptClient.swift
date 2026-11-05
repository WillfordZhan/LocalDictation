import Foundation

/// Prompt editing uses the same loopback service as dictation. No credentials,
/// transcript, audio or dictionary is included in these configuration requests.
final class CleanupPromptClient {
    private let base: URL
    private let session: URLSession
    init(base: URL, session: URLSession = .shared) { self.base = base; self.session = session }

    func load(completion: @escaping (Result<CleanupPromptCatalog, Error>) -> Void) {
        request(path: "cleanup/prompts", body: nil, completion: completion)
    }
    func save(_ draft: CleanupPromptDraft, completion: @escaping (Result<CleanupPromptCatalog, Error>) -> Void) {
        do { request(path: "cleanup/prompts", body: try JSONEncoder().encode(draft), completion: completion) }
        catch { completion(.failure(error)) }
    }
    func activate(id: String, completion: @escaping (Result<CleanupPromptCatalog, Error>) -> Void) {
        do {
            let body = try JSONSerialization.data(withJSONObject: ["version_id": id])
            request(path: "cleanup/prompts/activate", body: body, completion: completion)
        } catch { completion(.failure(error)) }
    }
    private func request(path: String, body: Data?, completion: @escaping (Result<CleanupPromptCatalog, Error>) -> Void) {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body; request.timeoutInterval = 10
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        session.dataTask(with: request) { data, response, error in
            let result: Result<CleanupPromptCatalog, Error>
            do {
                if let error { throw error }
                guard let response = response as? HTTPURLResponse, let data else {
                    throw Self.failure("本地服务没有返回规则数据。")
                }
                guard (200..<300).contains(response.statusCode) else {
                    let detail = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    let message = (detail?["detail"] as? String) ?? (detail?["error"] as? String)
                    throw Self.failure(message ?? "规则请求失败（\(response.statusCode)），请检查本地服务版本。")
                }
                result = .success(try JSONDecoder().decode(CleanupPromptCatalog.self, from: data))
            } catch { result = .failure(error) }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "CleanupPromptClient", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
