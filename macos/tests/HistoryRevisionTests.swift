import Foundation

@main
enum HistoryRevisionTests {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("revision-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = DictationStore(directory: folder)
        let original = store.add(rawText: "嗯，把 BOM 放到 test 分支。", text: "把 BOM 放到 test 分支。",
            asrSeconds: 0.5, cleanupSeconds: 0.2, totalSeconds: 0.7, audioSeconds: 8,
            cleanupApplied: true, warning: nil)
        let usageBefore = try Data(contentsOf: folder.appendingPathComponent("usage.json"))
        let profile = DictationCleanupProfile(versionID: "alternate", name: "更简洁", contentSHA256: "hash", modelID: "fixture-model")
        let revision = store.addRevision(entryID: original.id, text: "请将 BOM 放到 test 分支。", cleanupSeconds: 0.3, cleanupProfile: profile)!
        precondition(store.entries.count == 1 && store.entries[0].text == original.text && store.entries[0].rawText == original.rawText)
        precondition(store.entries[0].revisions?.first?.id == revision.id)
        let usageAfter = try Data(contentsOf: folder.appendingPathComponent("usage.json"))
        precondition(usageAfter == usageBefore)
        precondition(store.flushHistory())
        let loaded = DictationStore(directory: folder)
        precondition(loaded.entries[0].revisions?.first?.cleanupProfile == profile)
        precondition(loaded.entries[0].revisions?.first?.text == revision.text)
        let mirrored = try JSONDecoder().decode([DictationEntry].self,
            from: Data(contentsOf: folder.appendingPathComponent("history.backup.json")))
        precondition(mirrored[0].revisions?.first?.id == revision.id)
        precondition(loaded.addRevision(entryID: original.id, text: "", cleanupSeconds: 1, cleanupProfile: profile) == nil)
        loaded.delete(id: original.id)
        precondition(loaded.addRevision(entryID: original.id, text: "迟到结果", cleanupSeconds: 1, cleanupProfile: profile) == nil)
        precondition(loaded.entries.isEmpty)
        // An existing history without the new field remains byte-for-byte text equivalent.
        let old = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DictationEntry.self, from: old)
        precondition(decoded.revisions == nil && decoded.text == original.text)
        print("PASS history revisions: immutable original, persistent alternate outputs and provenance, mirrored restart, no extra usage, deleted parent never resurrected")
    }
}
