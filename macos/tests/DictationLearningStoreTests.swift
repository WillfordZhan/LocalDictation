import Foundation

@main
enum DictationLearningStoreTests {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("learning-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = DictationStore(directory: folder)
        store.updatePreferences { $0.vocabulary = ["ManualTerm"] }
        let entryID = UUID()
        let learned = store.learnVocabulary(original: "SalesPrat", corrected: "SalesPart",
            entryID: entryID, bundleID: "test.fixture")!
        precondition(store.preferences.vocabulary == ["ManualTerm", "SalesPart"])
        precondition(store.preferences.automaticallyAddedTerms == ["SalesPart"])
        precondition(store.entries.isEmpty && store.usageSummary().dictationCount == 0)
        precondition(store.learnVocabulary(original: "SalesPrat", corrected: "SalesPart",
            entryID: entryID, bundleID: nil) == nil)
        let restarted = DictationStore(directory: folder)
        precondition(restarted.preferences.learnedVocabulary.first?.id == learned.id)
        precondition(restarted.preferences.learnedVocabulary.first?.entryID == entryID)
        precondition(restarted.preferences.automaticallyAddedTerms == ["SalesPart"])
        restarted.undoLearnedVocabulary(id: learned.id)
        precondition(restarted.preferences.vocabulary == ["ManualTerm"])
        precondition(restarted.preferences.automaticallyAddedTerms.isEmpty)
        precondition(restarted.preferences.learnedVocabulary.first?.undone == true)
        precondition(restarted.learnVocabulary(original: "SalesPrat", corrected: "SalesPart",
            entryID: entryID, bundleID: nil) == nil, "Undo must prevent immediate relearning")
        restarted.updatePreferences { $0.vocabulary.append("SalesPart") }
        restarted.undoLearnedVocabulary(id: learned.id)
        precondition(restarted.preferences.vocabulary.contains("SalesPart"), "Repeated undo must not remove a manual addition")
        restarted.updatePreferences { $0.automaticVocabularyLearning = false }
        precondition(restarted.learnVocabulary(original: "Foobar", corrected: "FooBar2",
            entryID: entryID, bundleID: nil) == nil)
        let saved = DictationStore(directory: folder)
        precondition(!saved.preferences.automaticVocabularyLearning && saved.preferences.learnedVocabulary.first?.undone == true)
        let old = try JSONDecoder().decode(DictationPreferences.self, from: Data("{\"vocabulary\":[\"Existing\"]}".utf8))
        precondition(old.vocabulary == ["Existing"] && old.learnedVocabulary.isEmpty)
        saved.updatePreferences { $0.automaticVocabularyLearning = true; $0.vocabulary.append("会话") }
        let known = saved.learnVocabulary(original: "绘画", corrected: "会话", entryID: entryID, bundleID: nil)!
        precondition(!saved.preferences.automaticallyAddedTerms.contains("会话"), "A learned correction must not reclassify a manual word")
        precondition(saved.preferences.correctionHints.contains(.init(original: "绘画", corrected: "会话")))
        let payload = try DictationStore.encodeRequestOptions(cleanup: true, language: "zh",
            vocabulary: saved.preferences.vocabulary, corrections: saved.preferences.correctionHints)
        let decoded = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
        precondition((decoded["corrections"] as? [[String: String]])?.contains(["original": "绘画", "corrected": "会话"]) == true)
        precondition(saved.undoLearnedVocabulary(id: known.id) && saved.preferences.vocabulary.contains("会话"))
        precondition(!saved.preferences.correctionHints.contains(.init(original: "绘画", corrected: "会话")))
        let first = saved.learnVocabulary(original: "DemoPrat", corrected: "DemoPart", entryID: entryID, bundleID: nil)!
        let second = saved.learnVocabulary(original: "Demopart", corrected: "DemoPart", entryID: entryID, bundleID: nil)!
        precondition(saved.undoLearnedVocabulary(id: first.id) && saved.preferences.vocabulary.contains("DemoPart"))
        precondition(saved.preferences.automaticallyAddedTerms.contains("DemoPart"), "Ownership transfers with remaining corrections")
        precondition(saved.undoLearnedVocabulary(id: second.id) && !saved.preferences.vocabulary.contains("DemoPart"))
        let overlap = DictationStore(memoryOnly: true)
        overlap.updatePreferences { $0.vocabulary = ["bom", "BOM"] }
        let exact = overlap.learnVocabulary(original: "bon", corrected: "BOM", entryID: entryID, bundleID: nil)!
        precondition(overlap.preferences.vocabulary == ["bom", "BOM"] && exact.vocabularyWasPresent == true)
        precondition(overlap.undoLearnedVocabulary(id: exact.id) && overlap.preferences.vocabulary == ["bom", "BOM"])
        let chained = DictationStore(memoryOnly: true)
        let lower = chained.learnVocabulary(original: "SalesPrat", corrected: "SalesPart", entryID: entryID, bundleID: nil)!
        let upper = chained.learnVocabulary(original: "salespart", corrected: "SalesPART", entryID: entryID, bundleID: nil)!
        precondition(chained.undoLearnedVocabulary(id: upper.id) && chained.preferences.vocabulary == ["SalesPart"])
        precondition(chained.preferences.correctionHints == [.init(original: "SalesPrat", corrected: "SalesPart")])
        precondition(chained.undoLearnedVocabulary(id: lower.id) && chained.preferences.vocabulary.isEmpty)
        let transfer = DictationStore(memoryOnly: true)
        let transferLower = transfer.learnVocabulary(original: "Partt", corrected: "Part", entryID: entryID, bundleID: nil)!
        let transferUpper = transfer.learnVocabulary(original: "part", corrected: "PART", entryID: entryID, bundleID: nil)!
        let transferAlias = transfer.learnVocabulary(original: "Prat", corrected: "PART", entryID: entryID, bundleID: nil)!
        precondition(transfer.undoLearnedVocabulary(id: transferUpper.id))
        precondition(transfer.undoLearnedVocabulary(id: transferAlias.id) && transfer.preferences.vocabulary == ["Part"])
        precondition(transfer.undoLearnedVocabulary(id: transferLower.id) && transfer.preferences.vocabulary.isEmpty)
        let manualRestore = DictationStore(memoryOnly: true)
        let oldOwner = manualRestore.learnVocabulary(original: "Partt", corrected: "Part", entryID: entryID, bundleID: nil)!
        let newCase = manualRestore.learnVocabulary(original: "part", corrected: "PART", entryID: entryID, bundleID: nil)!
        manualRestore.updatePreferences { $0.vocabulary.append("Part") }
        precondition(manualRestore.undoLearnedVocabulary(id: newCase.id))
        precondition(!manualRestore.undoLearnedVocabulary(id: oldOwner.id) && manualRestore.preferences.vocabulary == ["Part"])
        saved.updatePreferences { $0.automaticVocabularyLearning = true; $0.vocabulary.append("bom") }
        let casing = saved.learnVocabulary(original: "bom", corrected: "BOM", entryID: entryID, bundleID: nil)!
        precondition(saved.preferences.vocabulary.contains("BOM") && !saved.preferences.vocabulary.contains("bom"))
        precondition(saved.undoLearnedVocabulary(id: casing.id))
        precondition(saved.preferences.vocabulary.contains("bom") && !saved.preferences.vocabulary.contains("BOM"))
        let owned = saved.learnVocabulary(original: "ProductPrat", corrected: "ProductPart", entryID: entryID, bundleID: nil)!
        saved.updatePreferences { $0.vocabulary.removeAll { $0 == "ProductPart" } }
        saved.updatePreferences { $0.vocabulary.append("ProductPart") }
        precondition(!saved.undoLearnedVocabulary(id: owned.id) && saved.preferences.vocabulary.contains("ProductPart"))
        let persisted = folder.appendingPathComponent("preferences.json")
        let originalPreferences = try Data(contentsOf: persisted)
        try FileManager.default.removeItem(at: persisted)
        try FileManager.default.createDirectory(at: persisted, withIntermediateDirectories: false)
        let failed = saved.learnVocabulary(original: "TestPrat", corrected: "TestPart", entryID: entryID, bundleID: nil)
        precondition(failed == nil && saved.storageError != nil && !saved.preferences.vocabulary.contains("TestPart"))
        try FileManager.default.removeItem(at: persisted)
        try originalPreferences.write(to: persisted)
        let retry = saved.learnVocabulary(original: "TestPrat", corrected: "TestPart", entryID: entryID, bundleID: nil)!
        let beforeUndo = try Data(contentsOf: persisted)
        try FileManager.default.removeItem(at: persisted)
        try FileManager.default.createDirectory(at: persisted, withIntermediateDirectories: false)
        precondition(!saved.undoLearnedVocabulary(id: retry.id) && saved.preferences.vocabulary.contains("TestPart"))
        try FileManager.default.removeItem(at: persisted)
        try beforeUndo.write(to: persisted)
        precondition(saved.undoLearnedVocabulary(id: retry.id))
        let promoted = saved.learnVocabulary(original: "CachePrat", corrected: "CachePart", entryID: entryID, bundleID: nil)!
        let alias = saved.learnVocabulary(original: "CahcePart", corrected: "CachePart", entryID: entryID, bundleID: nil)!
        precondition(saved.preferences.automaticallyAddedTerms.contains("CachePart"))
        precondition(saved.addManualVocabulary("  CachePart  "))
        let manualRestart = DictationStore(directory: folder)
        precondition(manualRestart.preferences.vocabulary.filter { $0 == "CachePart" }.count == 1)
        precondition(!manualRestart.preferences.automaticallyAddedTerms.contains("CachePart"))
        precondition(manualRestart.preferences.correctionHints.contains(.init(original: "CachePrat", corrected: "CachePart")))
        precondition(manualRestart.undoLearnedVocabulary(id: promoted.id) && manualRestart.undoLearnedVocabulary(id: alias.id))
        precondition(manualRestart.preferences.vocabulary.contains("CachePart"), "Explicit manual addition survives undo of all learned spellings")
        precondition(!manualRestart.addManualVocabulary(String(repeating: "x", count: 65)))
        precondition(!manualRestart.addManualVocabulary("  "))
        let beforeManual = try Data(contentsOf: persisted)
        try FileManager.default.removeItem(at: persisted)
        try FileManager.default.createDirectory(at: persisted, withIntermediateDirectories: false)
        precondition(!manualRestart.addManualVocabulary("UnsavedManual") && !manualRestart.preferences.vocabulary.contains("UnsavedManual"))
        try FileManager.default.removeItem(at: persisted)
        try beforeManual.write(to: persisted)
        print("PASS learning store: confirmed terms persist, undo is durable and blocks relearning, manual words preserved, disabled mode, no transcript or usage mutation")
    }
}
