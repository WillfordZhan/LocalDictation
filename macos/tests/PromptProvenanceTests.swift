import Foundation

/// All persistence and recovery checks run under a newly created temporary
/// directory, independent of the installed app and its user's actual history.
@main
enum PromptProvenanceChecks {
    static var checks = 0
    static let files = FileManager.default
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw NSError(domain: "PromptProvenanceChecks", code: checks,
            userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func main() {
        do { try run(); print("PASS: \(checks) prompt provenance checks (temporary storage only)") }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func run() throws {
        let root = files.temporaryDirectory.appendingPathComponent("prompt-provenance-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        let primary = root.appendingPathComponent("history.json")
        let backup = root.appendingPathComponent("history.backup.json")
        let oldID = UUID()
        let oldRecord: [String: Any] = [
            "id": oldID.uuidString, "createdAt": Date().addingTimeInterval(-60).timeIntervalSinceReferenceDate,
            "rawText": "嗯，这是旧记录。", "text": "这是旧记录。", "asrSeconds": 0.2,
            "cleanupSeconds": 0.1, "totalSeconds": 0.3, "audioSeconds": 2.0, "cleanupApplied": true
        ]
        // Deliberately omit both provenance keys rather than encoding nulls.
        let legacyBytes = try JSONSerialization.data(withJSONObject: [oldRecord])
        try legacyBytes.write(to: primary); try legacyBytes.write(to: backup)
        let store = DictationStore(directory: root)
        try require(store.entries.count == 1 && store.storageError == nil, "Legacy record did not load")
        try require(store.entries[0].cleanupProfile == nil && store.entries[0].asrModel == nil,
                    "Legacy record inferred today's prompt or model")
        let profile = DictationCleanupProfile(versionID: "version-at-recording", name: "自然书面语",
            contentSHA256: String(repeating: "b", count: 64), modelID: "Qwen-editor-at-recording")
        let entry = store.add(rawText: "嗯，把这个 BOM 导出。", text: "导出 BOM。", asrSeconds: 0.4,
            cleanupSeconds: 0.5, totalSeconds: 0.9, audioSeconds: 3, cleanupApplied: true, warning: nil,
            cleanupProfile: profile, asrModel: "Qwen-ASR-at-recording")
        let disabled = store.add(rawText: "嗯，不整理。", text: "嗯，不整理。", asrSeconds: 0.2,
            cleanupSeconds: 0, totalSeconds: 0.2, audioSeconds: 2, cleanupApplied: false, warning: nil,
            cleanupProfile: nil, asrModel: "Qwen-ASR-only")
        let failed = store.add(rawText: "请保留这段原话。", text: "请保留这段原话。", asrSeconds: 0.3,
            cleanupSeconds: 0.7, totalSeconds: 1, audioSeconds: 2, cleanupApplied: false,
            warning: "文字整理未完成，已保留原始转写。", cleanupProfile: profile, asrModel: "Qwen-ASR-at-recording")
        try require(!store.hasUnsavedHistory && store.storageError == nil, "New provenance was not safely persisted")
        let primaryBytes = try Data(contentsOf: primary), backupBytes = try Data(contentsOf: backup)
        let encoded = try JSONSerialization.jsonObject(with: primaryBytes) as! [[String: Any]]
        let encodedNew = encoded.first { $0["id"] as? String == entry.id.uuidString }!
        let encodedProfile = encodedNew["cleanupProfile"] as? [String: String]
        try require(encodedProfile == ["version_id": profile.versionID, "name": profile.name,
            "content_sha256": profile.contentSHA256, "model_id": profile.modelID], "On-disk profile lost backend field names or values")
        try require(encodedNew["asrModel"] as? String == "Qwen-ASR-at-recording", "On-disk ASR model missing")
        let mirrorEntries = try JSONDecoder().decode([DictationEntry].self, from: backupBytes)
        try require(mirrorEntries.count == 4, "Mirror omitted a record")

        func verify(_ loaded: DictationStore) throws {
            try require(loaded.entries.count == 4 && !loaded.hasUnsavedHistory, "Reload lost records or left writes pending")
            let restored = loaded.entries.first { $0.id == entry.id }
            try require(restored?.cleanupProfile == profile && restored?.asrModel == entry.asrModel, "Reload changed prompt/model provenance")
            try require(restored?.rawText == entry.rawText && restored?.text == entry.text, "Provenance persistence changed original/output text")
            let old = loaded.entries.first { $0.id == oldID }
            try require(old != nil && old?.cleanupProfile == nil && old?.asrModel == nil, "Reload fabricated legacy provenance")
            let off = loaded.entries.first { $0.id == disabled.id }
            try require(off?.cleanupProfile == nil && off?.asrModel == "Qwen-ASR-only" && off?.cleanupApplied == false,
                        "Disabled cleanup gained a profile or lost ASR metadata")
            let fallback = loaded.entries.first { $0.id == failed.id }
            try require(fallback?.cleanupProfile == profile && fallback?.cleanupApplied == false && fallback?.warning == failed.warning,
                        "Fallback failed to preserve attempted rule and failure status")
        }
        try verify(DictationStore(directory: root))
        let damaged = Data("invalid primary history".utf8)
        try damaged.write(to: primary)
        let recovered = DictationStore(directory: root)
        try verify(recovered)
        try require(recovered.historyRecoveryMessage != nil, "Mirror recovery was not disclosed")
        let preserved = try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("history.damaged-") }
        try require(preserved.count == 1, "Damaged source was not separately preserved")
        let preservedBytes = try Data(contentsOf: preserved[0])
        try require(preservedBytes == damaged, "Recovery altered preserved damaged bytes")
        try verify(DictationStore(directory: root))
    }
}
