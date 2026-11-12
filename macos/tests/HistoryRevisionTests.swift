import Foundation

@main
enum HistoryRevisionTests {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("revision-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = DictationStore(directory: folder)
        let failure = DictationCleanupOutcome(status: "failed", reason: "invalid_model_output", errorType: "CleanupOutputError")
        let unchanged = DictationCleanupOutcome(status: "unchanged", reason: "identical_output")
        let original = store.add(rawText: "嗯，把 BOM 放到 test 分支。", text: "把 BOM 放到 test 分支。",
            asrSeconds: 0.5, cleanupSeconds: 0.2, totalSeconds: 0.7, audioSeconds: 8,
            cleanupApplied: false, warning: "整理未完成", cleanupOutcome: failure)
        let usageBefore = try Data(contentsOf: folder.appendingPathComponent("usage.json"))
        let profile = DictationCleanupProfile(versionID: "alternate", name: "更简洁", contentSHA256: "hash", modelID: "fixture-model")
        let revision = store.addRevision(entryID: original.id, text: "请将 BOM 放到 test 分支。", cleanupSeconds: 0.3, cleanupProfile: profile, cleanupOutcome: unchanged, modelLoadSeconds: 1.5)!
        precondition(store.entries.count == 1 && store.entries[0].text == original.text && store.entries[0].rawText == original.rawText)
        precondition(store.entries[0].revisions?.first?.id == revision.id)
        let usageAfter = try Data(contentsOf: folder.appendingPathComponent("usage.json"))
        precondition(usageAfter == usageBefore)
        precondition(store.flushHistory())
        let loaded = DictationStore(directory: folder)
        precondition(loaded.entries[0].revisions?.first?.cleanupProfile == profile)
        precondition(loaded.entries[0].revisions?.first?.text == revision.text)
        precondition(loaded.entries[0].revisions?.first?.modelLoadSeconds == 1.5)
        precondition(loaded.entries[0].cleanupOutcome == failure && loaded.entries[0].revisions?.first?.cleanupOutcome == unchanged)
        let mirrored = try JSONDecoder().decode([DictationEntry].self,
            from: Data(contentsOf: folder.appendingPathComponent("history.backup.json")))
        precondition(mirrored[0].revisions?.first?.id == revision.id)
        precondition(mirrored[0].cleanupOutcome?.errorType == "CleanupOutputError")
        precondition(loaded.addRevision(entryID: original.id, text: "", cleanupSeconds: 1, cleanupProfile: profile) == nil)
        for invalid in [-1.0, Double.nan, Double.infinity] {
            precondition(loaded.addRevision(entryID: original.id, text: "无效计时", cleanupSeconds: 1,
                cleanupProfile: profile, modelLoadSeconds: invalid) == nil)
        }
        loaded.delete(id: original.id)
        precondition(loaded.addRevision(entryID: original.id, text: "迟到结果", cleanupSeconds: 1, cleanupProfile: profile) == nil)
        precondition(loaded.entries.isEmpty)
        // An existing history without the new field remains byte-for-byte text equivalent.
        var oldObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        oldObject.removeValue(forKey: "cleanupOutcome")
        let old = try JSONSerialization.data(withJSONObject: oldObject)
        let decoded = try JSONDecoder().decode(DictationEntry.self, from: old)
        precondition(decoded.cleanupOutcome == nil && decoded.revisions == nil && decoded.text == original.text)
        var oldRevision = try JSONSerialization.jsonObject(with: JSONEncoder().encode(revision)) as! [String: Any]
        oldRevision.removeValue(forKey: "cleanupOutcome")
        oldRevision.removeValue(forKey: "modelLoadSeconds")
        let decodedRevision = try JSONDecoder().decode(DictationRevision.self, from: JSONSerialization.data(withJSONObject: oldRevision))
        precondition(decodedRevision.cleanupOutcome == nil && decodedRevision.modelLoadSeconds == nil && decodedRevision.text == revision.text)
        let unknown = try JSONDecoder().decode(DictationCleanupOutcome.self, from: Data("{\"status\":\"future_status\",\"reason\":\"future_reason\"}".utf8))
        precondition(unknown.attentionMessage == nil && unknown.completionTitle == "已完成")
        precondition(DictationCleanupOutcome.legacy(raw: "原文", text: "原文", applied: true)?.status == "unchanged")
        precondition(DictationCleanupOutcome.legacy(raw: "原文", text: "原文", applied: false) == nil)
        print("PASS history revisions: immutable original, persistent alternate outputs and provenance, mirrored restart, no extra usage, deleted parent never resurrected")
    }
}
