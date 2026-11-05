import Foundation
import Darwin

/// Only a confirmed term correction is retained; the destination field's
/// surrounding text is never written to preferences or history by learning.
struct DictationLearnedVocabulary: Codable, Identifiable {
    let id: UUID
    let original: String
    let corrected: String
    let createdAt: Date
    let bundleID: String?
    let entryID: UUID
    var undone: Bool = false
    var replacedVocabulary: String? = nil
    // Existing manual words survive undo; only the learned mapping is removed.
    var vocabularyWasPresent: Bool? = nil
    var supersededLearningIDs: [UUID]? = nil
}

struct DictationCorrectionHint: Codable, Equatable {
    let original: String
    let corrected: String
}

enum DictationWaveformStyle: String, Codable, CaseIterable {
    case lively, gentle
    var title: String { self == .lively ? "灵动" : "柔和" }
}

struct DictationPreferences: Codable {
    var cleanupEnabled = true
    var autoInsertEnabled = true
    var waveformStyle: DictationWaveformStyle = .lively
    var recognitionLanguage = "zh"
    // Kept in the settings schema for old installations; -1 means permanent.
    // Session-only and age-based deletion are no longer supported policies.
    var historyRetentionDays = -1
    var vocabulary: [String] = []
    var automaticVocabularyLearning = true
    var learnedVocabulary: [DictationLearnedVocabulary] = []
    var shortcutMode = "fn"
    var shortcutKeyCode: UInt32 = 63
    var shortcutModifiers: UInt32 = 0
    var shortcutDisplay = "Fn"

    var correctionHints: [DictationCorrectionHint] {
        learnedVocabulary.filter { !$0.undone && vocabulary.contains($0.corrected) }
            .map { DictationCorrectionHint(original: $0.original, corrected: $0.corrected) }
    }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case cleanupEnabled, autoInsertEnabled, waveformStyle, recognitionLanguage, historyRetentionDays, vocabulary
        case automaticVocabularyLearning, learnedVocabulary
        case shortcutMode, shortcutKeyCode, shortcutModifiers, shortcutDisplay
    }

    // Missing fields are older settings, not a reason to discard existing ones.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        cleanupEnabled = try values.decodeIfPresent(Bool.self, forKey: .cleanupEnabled) ?? true
        autoInsertEnabled = try values.decodeIfPresent(Bool.self, forKey: .autoInsertEnabled) ?? true
        waveformStyle = (try? values.decodeIfPresent(DictationWaveformStyle.self, forKey: .waveformStyle)) ?? .lively
        recognitionLanguage = try values.decodeIfPresent(String.self, forKey: .recognitionLanguage) ?? "zh"
        historyRetentionDays = (try? values.decodeIfPresent(Int.self, forKey: .historyRetentionDays)) ?? -1
        vocabulary = try values.decodeIfPresent([String].self, forKey: .vocabulary) ?? []
        automaticVocabularyLearning = try values.decodeIfPresent(Bool.self, forKey: .automaticVocabularyLearning) ?? true
        learnedVocabulary = try values.decodeIfPresent([DictationLearnedVocabulary].self, forKey: .learnedVocabulary) ?? []
        // A malformed shortcut must not discard valid recording settings or
        // vocabulary. Repair the mode and key fields together as one setting.
        let hasLegacyShortcut = values.contains(.shortcutKeyCode) || values.contains(.shortcutModifiers) || values.contains(.shortcutDisplay)
        do {
            // Preserve explicitly saved combinations from versions without a
            // mode field; older settings with no shortcut adopt the Fn default.
            shortcutMode = try values.decodeIfPresent(String.self, forKey: .shortcutMode) ?? (hasLegacyShortcut ? "combination" : "fn")
            shortcutKeyCode = try values.decodeIfPresent(UInt32.self, forKey: .shortcutKeyCode) ?? (shortcutMode == "fn" ? 63 : 49)
            shortcutModifiers = try values.decodeIfPresent(UInt32.self, forKey: .shortcutModifiers) ?? (shortcutMode == "fn" ? 0 : 6400)
            shortcutDisplay = try values.decodeIfPresent(String.self, forKey: .shortcutDisplay) ?? (shortcutMode == "fn" ? "Fn" : "⌃⌥⌘Space")
        } catch {
            shortcutMode = "fn"
            shortcutKeyCode = 63
            shortcutModifiers = 0
            shortcutDisplay = "Fn"
        }
    }
}

/// The service reports the rule it actually used, rather than the rule that
/// happens to be selected when the result is displayed later.
struct DictationCleanupProfile: Codable, Equatable {
    let versionID: String
    let name: String
    let contentSHA256: String
    let modelID: String
    private enum CodingKeys: String, CodingKey {
        case versionID = "version_id", name, contentSHA256 = "content_sha256", modelID = "model_id"
    }
}

/// Compute time and user-visible tail latency are distinct once recognition
/// overlaps recording. Old histories legitimately have no streaming metrics.
struct DictationStreamingMetrics: Codable, Equatable {
    var processedAudioBeforeStopSeconds: Double
    var asrBeforeStopSeconds: Double
    var asrAfterStopSeconds: Double
    var stopToResultSeconds: Double
    var asrCalls: Int
    var clientStopToResultSeconds: Double? = nil

    private enum CodingKeys: String, CodingKey {
        case processedAudioBeforeStopSeconds = "processed_audio_before_stop_seconds"
        case asrBeforeStopSeconds = "asr_before_stop_seconds"
        case asrAfterStopSeconds = "asr_after_stop_seconds"
        case stopToResultSeconds = "stop_to_result_seconds"
        case asrCalls = "asr_calls"
        case clientStopToResultSeconds = "client_stop_to_result_seconds"
    }
}

/// Alternate edits belong to one recording. They do not replace its original
/// output or count as another dictation in the daily activity totals.
struct DictationRevision: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    let text: String
    let cleanupSeconds: Double
    let cleanupProfile: DictationCleanupProfile
}

struct DictationEntry: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    let rawText: String
    let text: String
    let asrSeconds: Double
    let cleanupSeconds: Double
    let totalSeconds: Double
    let audioSeconds: Double?
    let cleanupApplied: Bool
    let warning: String?
    // Missing provenance is an older record, not permission to infer which
    // model or prompt produced it from today's selected configuration.
    var cleanupProfile: DictationCleanupProfile? = nil
    var asrModel: String? = nil
    var streamingMetrics: DictationStreamingMetrics? = nil
    var revisions: [DictationRevision]? = nil
}

/// Daily totals contain no transcript, audio, entry identifiers, or vocabulary.
/// Dates are recorded as local Gregorian calendar days at the time of use; a
/// later timezone change must not move already-recorded activity to another day.
struct DictationUsageDay: Codable {
    var characterCount = 0
    var dictationCount = 0
    var audioSeconds = 0.0
    var timedDictationCount = 0
    var processingSeconds = 0.0
    var measuredProcessingCount = 0
}

struct DictationUsageSummary {
    let startedAt: Date?
    let characterCount: Int
    let dictationCount: Int
    let audioSeconds: Double?
    let charactersPerMinute: Double?
    let estimatedSavedSeconds: Double?
    let activeDays: Int
    let currentStreak: Int
    let longestStreak: Int
}

struct DictationUsage: Codable {
    var version = 1
    var startedAt: Date?
    var days: [String: DictationUsageDay] = [:]

    private static func gregorian(_ calendar: Calendar) -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = calendar.timeZone
        return result
    }

    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let parts = gregorian(calendar).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    private static func date(for key: String, calendar: Calendar) -> Date? {
        let pieces = key.split(separator: "-")
        guard key.count == 10, pieces.count == 3,
              let year = Int(pieces[0]), let month = Int(pieces[1]), let day = Int(pieces[2]),
              (1...9999).contains(year) else { return nil }
        let calendar = gregorian(calendar)
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)),
              dayKey(for: date, calendar: calendar) == key else { return nil }
        return date
    }

    /// Count output characters rather than ASR fillers. A composed character is
    /// one unit, English letters count individually, and punctuation/space do not.
    static func characterCount(in text: String) -> Int {
        let ignored = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        return text.reduce(0) { count, character in
            guard let first = character.unicodeScalars.first else { return count }
            return count + (ignored.contains(first) ? 0 : 1)
        }
    }

    @discardableResult
    mutating func record(_ entry: DictationEntry, calendar: Calendar = .current) -> Bool {
        let count = Self.characterCount(in: entry.text)
        guard count > 0, entry.createdAt.timeIntervalSinceReferenceDate.isFinite else { return false }
        // A readable but implausibly large counter must not crash the next
        // dictation. Keep the existing ledger until the user explicitly clears it.
        let totalCharacters = days.values.reduce(0) { $0 + $1.characterCount }
        let totalCount = days.values.reduce(0) { $0 + $1.dictationCount }
        guard !totalCharacters.addingReportingOverflow(count).overflow,
              !totalCount.addingReportingOverflow(1).overflow else { return false }
        let key = Self.dayKey(for: entry.createdAt, calendar: calendar)
        var day = days[key] ?? DictationUsageDay()
        day.characterCount += count
        day.dictationCount += 1
        if let seconds = entry.audioSeconds, seconds.isFinite, seconds > 0 {
            day.audioSeconds += seconds
            day.timedDictationCount += 1
        }
        // ASR performed during speech already overlaps audioSeconds. Counting
        // its compute again would understate saved time after streaming begins.
        let waiting = entry.streamingMetrics?.clientStopToResultSeconds
            ?? entry.streamingMetrics?.stopToResultSeconds ?? entry.totalSeconds
        if waiting.isFinite, waiting >= 0 {
            day.processingSeconds += waiting
            day.measuredProcessingCount += 1
        }
        guard day.audioSeconds.isFinite, day.processingSeconds.isFinite else { return false }
        days[key] = day
        startedAt = startedAt.map { min($0, entry.createdAt) } ?? entry.createdAt
        return true
    }

    func summary(now: Date = Date(), calendar: Calendar = .current) -> DictationUsageSummary {
        let calendar = Self.gregorian(calendar)
        let count = days.values.reduce(0) { $0 + $1.dictationCount }
        let characters = days.values.reduce(0) { $0 + $1.characterCount }
        let seconds = days.values.reduce(0) { $0 + $1.audioSeconds }
        let processing = days.values.reduce(0) { $0 + $1.processingSeconds }
        let completeAudio = days.values.reduce(0) { $0 + $1.timedDictationCount } == count
        let completeProcessing = days.values.reduce(0) { $0 + $1.measuredProcessingCount } == count
        let keys = days.keys.sorted()
        var longest = 0, run = 0
        var previous: Date?
        for key in keys {
            guard let date = Self.date(for: key, calendar: calendar) else { continue }
            let followsPrevious = previous.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) }
                .map { Self.dayKey(for: $0, calendar: calendar) == key } ?? false
            run = followsPrevious ? run + 1 : 1
            longest = max(longest, run)
            previous = date
        }
        // Yesterday's streak stays current while today is still in progress.
        // Calendar arithmetic handles DST days that are not 24 hours long.
        var cursor = calendar.startOfDay(for: now)
        if days[Self.dayKey(for: cursor, calendar: calendar)] == nil {
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        var current = 0
        while days[Self.dayKey(for: cursor, calendar: calendar)] != nil {
            current += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        // The 60-character/minute baseline is an estimate, not measured typing
        // performance. Include model wait time instead of counting it as saved.
        return DictationUsageSummary(startedAt: startedAt, characterCount: characters,
            dictationCount: count, audioSeconds: completeAudio ? seconds : nil,
            charactersPerMinute: completeAudio && seconds > 0 ? Double(characters) / seconds * 60 : nil,
            estimatedSavedSeconds: completeAudio && completeProcessing ? max(0, Double(characters) - seconds - processing) : nil,
            activeDays: days.count, currentStreak: current, longestStreak: longest)
    }

    /// Preserve unknown versions and damaged files; never silently reset them
    /// during a normal add, history deletion, or preference change.
    var isValid: Bool {
        guard version == 1, startedAt?.timeIntervalSinceReferenceDate.isFinite != false,
              days.isEmpty == (startedAt == nil) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var totalCharacters = 0, totalCount = 0
        var totalAudio = 0.0, totalProcessing = 0.0
        for (key, day) in days {
            guard Self.date(for: key, calendar: calendar) != nil,
                  day.characterCount > 0, day.dictationCount > 0,
                  (0...day.dictationCount).contains(day.timedDictationCount),
                  (0...day.dictationCount).contains(day.measuredProcessingCount),
                  day.audioSeconds.isFinite, day.audioSeconds >= 0,
                  day.processingSeconds.isFinite, day.processingSeconds >= 0,
                  (day.timedDictationCount == 0 ? day.audioSeconds == 0 : day.audioSeconds > 0),
                  day.measuredProcessingCount != 0 || day.processingSeconds == 0 else { return false }
            let characters = totalCharacters.addingReportingOverflow(day.characterCount)
            let count = totalCount.addingReportingOverflow(day.dictationCount)
            guard !characters.overflow, !count.overflow else { return false }
            totalCharacters = characters.partialValue; totalCount = count.partialValue
            totalAudio += day.audioSeconds; totalProcessing += day.processingSeconds
            guard totalAudio.isFinite, totalProcessing.isFinite else { return false }
        }
        return true
    }
}

/// The app uses this store on its main thread. Preview/self-test instances pass
/// memoryOnly, which bypasses even directory discovery and all filesystem reads.
final class DictationStore {
    private(set) var preferences = DictationPreferences()
    private(set) var entries: [DictationEntry] = []
    private(set) var usage = DictationUsage()
    private(set) var storageError: String?
    private(set) var hasUnsavedHistory = false
    private(set) var historyRecoveryMessage: String?
    var storageDirectory: URL? { directory }
    var onChange: (() -> Void)?

    private let directory: URL?
    private let memoryOnly: Bool
    private let files = FileManager.default
    private var preferencesError: String?
    private var historyError: String?
    private var validationError: String?
    private var usageError: String?
    private var historyWriteBlocked = false
    private var usageWriteBlocked = false
    private var historyClearRequested = false
    private var historyRecoveryPending = false
    private var preservedHistoryBytes: [String: Data] = [:]

    init(directory: URL? = nil, memoryOnly: Bool = false) {
        self.memoryOnly = memoryOnly
        self.directory = memoryOnly ? nil : directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("LocalDictation", isDirectory: true)
        guard !memoryOnly else { return }
        loadPreferences()
        loadUsage()
        loadHistory()
        refreshError()
    }

    private static func normalizedVocabulary(_ words: [String]) -> [String] {
        var seen = Set<Data>()
        return words.compactMap { word in
            let value = word.trimmingCharacters(in: .whitespacesAndNewlines)
            return !value.isEmpty && seen.insert(Data(value.utf8)).inserted ? value : nil
        }
    }

    // The loopback service accepts at most 40 KiB of base64 request options.
    // This is a transport budget, not a word-count or model vocabulary limit.
    static let maxOptionsHeaderBytes = 40 * 1024

    static func encodeRequestOptions(cleanup: Bool, language: String, vocabulary: [String],
                                     corrections: [DictationCorrectionHint] = []) throws -> Data {
        struct Options: Encodable {
            let cleanup: Bool
            let language: String
            let vocabulary: [String]
            let corrections: [DictationCorrectionHint]?
        }
        return try JSONEncoder().encode(Options(cleanup: cleanup, language: language, vocabulary: vocabulary,
                                               corrections: corrections.isEmpty ? nil : corrections))
    }

    static func validateVocabulary(_ words: [String], corrections: [DictationCorrectionHint] = []) -> String? {
        let words = normalizedVocabulary(words)
        // Python len counts Unicode code points, not Swift grapheme clusters.
        // Keep the native editor and backend limits identical for composed text.
        guard !words.contains(where: { $0.unicodeScalars.count > 64 }) else {
            return "每个术语最多 64 个 Unicode 字符，请缩短后重试。"
        }
        // Reserve the longest supported switch/language encoding so changing
        // settings later cannot make an already accepted dictionary unsendable.
        guard let options = try? encodeRequestOptions(cleanup: false, language: "auto", vocabulary: words, corrections: corrections) else {
            return "词典无法编码，请检查词条后重试。"
        }
        guard options.base64EncodedData().count <= maxOptionsHeaderBytes else {
            return "词典内容超过单次传输容量（40 KiB），请缩短或删除部分词条后重试。"
        }
        return nil
    }

    static func validateShortcut(keyCode: UInt32, modifiers: UInt32, display: String, mode: String = "combination") -> String? {
        if mode == "fn" {
            return keyCode == 63 && modifiers == 0 && display == "Fn" ? nil : "Fn 模式请使用单独的 Fn 键。"
        }
        guard mode == "combination" else { return "快捷键模式只能选择 Fn 或自定义组合键。" }
        // Carbon modifier masks: Control, Option, Command, and optional Shift.
        // Escape cancels capture; 54...63 are modifier keys, including Fn/Caps Lock.
        let requiredModifiers: UInt32 = 4096 | 2048 | 256
        let allowedModifiers = requiredModifiers | 512
        guard keyCode <= 127, !(53...63).contains(keyCode) else {
            return "请选择普通按键、空格或功能键；Esc 与单独的修饰键不能作为快捷键。"
        }
        guard modifiers & ~allowedModifiers == 0, modifiers & requiredModifiers != 0 else {
            return "快捷键至少包含 Control、Option 或 Command，可同时按住 Shift。"
        }
        guard !display.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              display.unicodeScalars.count <= 64 else {
            return "快捷键显示名称不能为空，且最多 64 个 Unicode 字符。"
        }
        return nil
    }

    func updatePreferences(_ change: (inout DictationPreferences) -> Void) {
        var next = preferences
        change(&next)
        next.historyRetentionDays = -1
        next.vocabulary = Self.normalizedVocabulary(next.vocabulary)
        // Removing or replacing an automatically owned entry relinquishes its
        // undo ownership. A later manual addition must not be deleted by an
        // old "undo learning" action.
        for index in next.learnedVocabulary.indices where !next.learnedVocabulary[index].undone {
            if !next.vocabulary.contains(next.learnedVocabulary[index].corrected) {
                next.learnedVocabulary[index].undone = true
            }
        }
        let vocabularyError = Self.validateVocabulary(next.vocabulary, corrections: next.correctionHints)
        // A previously saved oversized dictionary must remain repairable one
        // deletion at a time. Allow only strict removal of existing exact terms;
        // additions or replacements still require a fully valid request.
        let oldWords = Set(preferences.vocabulary.map { Data($0.utf8) })
        let repairingByDeletion = vocabularyError != nil && Self.validateVocabulary(preferences.vocabulary, corrections: preferences.correctionHints) != nil
            && next.vocabulary.count < preferences.vocabulary.count
            && next.vocabulary.allSatisfy { oldWords.contains(Data($0.utf8)) }
        let error = (repairingByDeletion ? nil : vocabularyError)
            ?? Self.validateShortcut(keyCode: next.shortcutKeyCode, modifiers: next.shortcutModifiers, display: next.shortcutDisplay, mode: next.shortcutMode)
            ?? (!["zh", "auto"].contains(next.recognitionLanguage) ? "识别语言只能选择中文或自动。" : nil)
        guard error == nil else {
            validationError = error
            changed()
            return
        }
        validationError = vocabularyError
        preferences = next
        savePreferences()
        if hasUnsavedHistory { _ = persistHistory() }
        changed()
    }

    @discardableResult
    func learnVocabulary(original: String, corrected: String, entryID: UUID,
                         bundleID: String?, at: Date = Date()) -> DictationLearnedVocabulary? {
        let source = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let term = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard preferences.automaticVocabularyLearning, !source.isEmpty, !term.isEmpty,
              source != term, source.unicodeScalars.count <= 64, term.unicodeScalars.count <= 64,
              !preferences.learnedVocabulary.contains(where: {
                  $0.original == source && $0.corrected == term
              }) else { return nil }
        let existing = preferences.vocabulary.first { $0 == term }
            ?? preferences.vocabulary.first { $0.caseInsensitiveCompare(term) == .orderedSame }
        let superseded = existing == nil || existing == term ? [] : preferences.learnedVocabulary
            .filter { !$0.undone && $0.corrected == existing }.map(\.id)
        let learned = DictationLearnedVocabulary(id: UUID(), original: source, corrected: term,
            createdAt: at, bundleID: bundleID, entryID: entryID,
            replacedVocabulary: existing == term ? nil : existing, vocabularyWasPresent: existing == term,
            supersededLearningIDs: superseded.isEmpty ? nil : superseded)
        // Use the same validated, atomically saved preferences as manual words.
        // This does not create a global replacement or alter earlier transcripts.
        var next = preferences
        if existing == term {
            // A known destination still needs its new, confirmed source spelling.
        } else if let existing, let index = next.vocabulary.firstIndex(of: existing) {
            next.vocabulary[index] = term
            for learnedIndex in next.learnedVocabulary.indices where next.learnedVocabulary[learnedIndex].corrected == existing {
                next.learnedVocabulary[learnedIndex].undone = true
            }
        } else { next.vocabulary.append(term) }
        next.learnedVocabulary.insert(learned, at: 0)
        guard saveLearningPreferences(next) else { return nil }
        return learned
    }

    /// Learning is acknowledged only after atomic preference persistence. A
    /// failed auto-add/undo never silently takes effect for just this process.
    private func saveLearningPreferences(_ next: DictationPreferences) -> Bool {
        if let error = Self.validateVocabulary(next.vocabulary, corrections: next.correctionHints) {
            validationError = error; changed(); return false
        }
        do {
            if !memoryOnly { try write(next, named: "preferences.json") }
            preferences = next; preferencesError = nil; validationError = nil
            changed(); return true
        } catch {
            preferencesError = "词典修改未能保存，原词典保持不变。请检查存储后重试。"
            changed(); return false
        }
    }

    @discardableResult
    func undoLearnedVocabulary(id: UUID) -> Bool {
        guard let record = preferences.learnedVocabulary.first(where: { $0.id == id }), !record.undone else { return false }
        var next = preferences
        var restoredPrevious = false
        let other = next.learnedVocabulary.firstIndex {
            $0.id != id && !$0.undone && $0.corrected == record.corrected
        }
        if record.vocabularyWasPresent != true, let other {
            // Another learned spelling still needs this word. Transfer undo
            // ownership so removing either mapping cannot delete it early.
            next.learnedVocabulary[other].vocabularyWasPresent = false
            next.learnedVocabulary[other].replacedVocabulary = record.replacedVocabulary
            next.learnedVocabulary[other].supersededLearningIDs = record.supersededLearningIDs
        } else if record.vocabularyWasPresent != true, let wordIndex = next.vocabulary.firstIndex(of: record.corrected) {
            if let previous = record.replacedVocabulary, !next.vocabulary.contains(previous) {
                next.vocabulary[wordIndex] = previous
                restoredPrevious = true
            } else { next.vocabulary.remove(at: wordIndex) }
        }
        if let index = next.learnedVocabulary.firstIndex(where: { $0.id == id }) {
                // Keep the rejected pair so the same correction is not silently
                // learned again after undo. Manual additions remain available.
                next.learnedVocabulary[index].undone = true
        }
        // Undoing a capitalization change restores the previous learned word
        // and its own undo action, not an unowned leftover dictionary entry.
        if restoredPrevious {
            for index in next.learnedVocabulary.indices where
                record.supersededLearningIDs?.contains(next.learnedVocabulary[index].id) == true {
                next.learnedVocabulary[index].undone = false
            }
        }
        return saveLearningPreferences(next)
    }

    @discardableResult
    func add(rawText: String, text: String, asrSeconds: Double, cleanupSeconds: Double,
             totalSeconds: Double, audioSeconds: Double?, cleanupApplied: Bool,
             warning: String?, createdAt: Date = Date(), cleanupProfile: DictationCleanupProfile? = nil,
             asrModel: String? = nil, streamingMetrics: DictationStreamingMetrics? = nil) -> DictationEntry {
        let entry = DictationEntry(id: UUID(), createdAt: createdAt, rawText: rawText, text: text,
                                  asrSeconds: asrSeconds, cleanupSeconds: cleanupSeconds,
                                  totalSeconds: totalSeconds, audioSeconds: audioSeconds,
                                  cleanupApplied: cleanupApplied, warning: warning,
                                  cleanupProfile: cleanupProfile, asrModel: asrModel, streamingMetrics: streamingMetrics)
        entries.insert(entry, at: 0)
        sortHistory()
        hasUnsavedHistory = true
        _ = persistHistory()
        // Only the new successful result is counted. Loading history never
        // replays entries, so restart cannot double count independent usage.
        if DictationUsage.characterCount(in: entry.text) > 0 {
            if usage.record(entry) {
                saveUsage()
            } else {
                usageWriteBlocked = true
                usageError = "统计数值无法继续累计，原文件已保留；口述结果仍可使用，清空统计后可恢复。"
            }
        }
        changed()
        return entry
    }

    @discardableResult
    func addRevision(entryID: UUID, text: String, cleanupSeconds: Double,
                     cleanupProfile: DictationCleanupProfile) -> DictationRevision? {
        // Deleting the parent while a request is running is authoritative.
        // A late reply must never resurrect it or create a replacement entry.
        guard let index = entries.firstIndex(where: { $0.id == entryID }),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              cleanupSeconds.isFinite, cleanupSeconds >= 0 else { return nil }
        let revision = DictationRevision(id: UUID(), createdAt: Date(), text: text,
            cleanupSeconds: cleanupSeconds, cleanupProfile: cleanupProfile)
        entries[index].revisions = (entries[index].revisions ?? []) + [revision]
        hasUnsavedHistory = true
        _ = persistHistory()
        changed()
        return revision
    }

    func usageSummary(now: Date = Date(), calendar: Calendar = .current) -> DictationUsageSummary {
        usage.summary(now: now, calendar: calendar)
    }

    func clearUsage() {
        usage = DictationUsage()
        guard !memoryOnly, let url = directory?.appendingPathComponent("usage.json") else { changed(); return }
        do {
            if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
            usageWriteBlocked = false
            usageError = nil
        } catch {
            usageError = "磁盘上的统计未能清除，请检查目录权限后再次清空统计。"
        }
        changed()
    }

    func delete(id: UUID) {
        entries.removeAll { $0.id == id }
        hasUnsavedHistory = true
        _ = persistHistory()
        changed()
    }

    func removeAll() {
        entries.removeAll()
        // Only this explicit destructive action may replace unreadable history.
        // Both complete copies become empty, so a backup cannot resurrect it.
        historyWriteBlocked = false
        historyClearRequested = true
        hasUnsavedHistory = true
        _ = persistHistory()
        changed()
    }

    private func sortHistory() {
        entries.sort { $0.createdAt > $1.createdAt }
    }

    private func loadPreferences() {
        guard let url = directory?.appendingPathComponent("preferences.json"), files.fileExists(atPath: url.path) else { return }
        do {
            var loaded = try JSONDecoder().decode(DictationPreferences.self, from: Data(contentsOf: url))
            var repairs: [String] = []
            if !["zh", "auto"].contains(loaded.recognitionLanguage) { loaded.recognitionLanguage = "zh"; repairs.append("识别语言") }
            let migrateHistoryPolicy = loaded.historyRetentionDays != -1
            loaded.historyRetentionDays = -1
            loaded.vocabulary = Self.normalizedVocabulary(loaded.vocabulary)
            // A transport-invalid saved dictionary is still user data. Keep
            // every term visible for repair instead of silently clearing it.
            let vocabularyIssue = Self.validateVocabulary(loaded.vocabulary, corrections: loaded.correctionHints)
            if Self.validateShortcut(keyCode: loaded.shortcutKeyCode, modifiers: loaded.shortcutModifiers, display: loaded.shortcutDisplay, mode: loaded.shortcutMode) != nil {
                let defaults = DictationPreferences()
                loaded.shortcutMode = defaults.shortcutMode
                loaded.shortcutKeyCode = defaults.shortcutKeyCode
                loaded.shortcutModifiers = defaults.shortcutModifiers
                loaded.shortcutDisplay = defaults.shortcutDisplay
                repairs.append("快捷键")
            }
            preferences = loaded
            var issues: [String] = []
            if !repairs.isEmpty { issues.append("部分设置无效，已使用安全默认值，原文件未改动：" + repairs.joined(separator: "、")) }
            if let vocabularyIssue { issues.append("已保留全部词条，修正后可继续使用词典：" + vocabularyIssue) }
            if !issues.isEmpty { preferencesError = issues.joined(separator: "\n") }
            else if migrateHistoryPolicy { savePreferences() }
        } catch {
            preferencesError = "设置文件无法读取，暂用默认设置；当前录音与结果仍可使用。"
        }
    }

    private func loadHistory() {
        guard let directory else { return }
        let primary = directory.appendingPathComponent("history.json")
        let backup = directory.appendingPathComponent("history.backup.json")
        let primaryExists = files.fileExists(atPath: primary.path)
        let backupExists = files.fileExists(atPath: backup.path)
        guard primaryExists || backupExists else { return }
        let primaryData = try? Data(contentsOf: primary)
        let backupData = try? Data(contentsOf: backup)
        let mainEntries = primaryData.flatMap { try? JSONDecoder().decode([DictationEntry].self, from: $0) }
        let backupEntries = backupData.flatMap { try? JSONDecoder().decode([DictationEntry].self, from: $0) }
        if let mainEntries {
            entries = mainEntries
            sortHistory()
            // Repair a missing/stale mirror from the authoritative main file.
            // No history is replayed into the independent daily statistics.
            if primaryData != backupData {
                hasUnsavedHistory = true
                _ = persistHistory()
            }
        } else if let backupEntries {
            entries = backupEntries
            sortHistory()
            hasUnsavedHistory = true
            let restored = persistHistory()
            historyRecoveryPending = !restored
            historyRecoveryMessage = restored
                ? (primaryExists ? "历史主文件异常，已从完整备份恢复；损坏原件已单独保留。" : "历史主文件缺失，已从完整备份恢复。")
                : "历史主文件异常，当前展示来自备份；修复尚未写入，请勿直接结束进程。"
        } else {
            // Without a readable complete copy, an empty in-memory list is not
            // proof that the user's history is empty. Keep both originals intact.
            historyWriteBlocked = true
            hasUnsavedHistory = true
            historyError = "历史主文件与备份均无法读取，原文件已保留；新增结果暂存内存，尚不能安全退出。"
        }
    }

    private func loadUsage() {
        guard let url = directory?.appendingPathComponent("usage.json"), files.fileExists(atPath: url.path) else { return }
        do {
            let loaded = try JSONDecoder().decode(DictationUsage.self, from: Data(contentsOf: url))
            guard loaded.isValid else { throw CocoaError(.coderReadCorrupt) }
            usage = loaded
        } catch {
            usageWriteBlocked = true
            usageError = "统计文件无法读取，原文件已保留；新增统计暂存内存。清空统计后可恢复保存。"
        }
    }

    private func saveUsage() {
        guard !memoryOnly, !usageWriteBlocked else { return }
        do {
            try write(usage, named: "usage.json")
            usageError = nil
        } catch {
            usageError = "统计未能保存，当前累计仅在本次运行中生效。"
        }
    }

    private func savePreferences() {
        guard !memoryOnly else { return }
        do {
            try write(preferences, named: "preferences.json")
            preferencesError = nil
        } catch {
            preferencesError = "设置未能保存，当前修改仅在本次运行中生效。"
        }
    }

    /// Call before quitting/updating even when the last add succeeded. This
    /// refreshes both complete copies and reports any newly unavailable storage.
    @discardableResult
    func flushHistory() -> Bool {
        hasUnsavedHistory = true
        if historyWriteBlocked { recoverRepairedHistory() }
        let saved = persistHistory()
        changed()
        return saved
    }

    private func recoverRepairedHistory() {
        guard let directory else { return }
        // When both copies were unreadable at launch, ordinary writes stayed
        // blocked. A restored valid copy can now be merged with newly dictated
        // in-memory records; retry must not require discarding those records.
        for name in ["history.json", "history.backup.json"] {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  let restored = try? JSONDecoder().decode([DictationEntry].self, from: data) else { continue }
            let pendingIDs = Set(entries.map(\.id))
            entries.append(contentsOf: restored.filter { !pendingIDs.contains($0.id) })
            sortHistory()
            historyWriteBlocked = false
            historyRecoveryPending = true
            historyRecoveryMessage = "已读入修复后的历史副本，并合并本次尚未保存的口述。"
            return
        }
    }

    private func persistHistory() -> Bool {
        guard !memoryOnly else {
            hasUnsavedHistory = false
            historyClearRequested = false
            return true
        }
        guard !historyWriteBlocked else { return false }
        do {
            if !historyClearRequested {
                try preserveDamagedHistory(named: "history.json")
                try preserveDamagedHistory(named: "history.backup.json")
            }
            // A crash between the two renames leaves a complete new primary
            // and the previous complete mirror. At rest both include the newest
            // record. A failed mirror update remains pending and blocks quit.
            try write(entries, named: "history.json")
            try write(entries, named: "history.backup.json")
            if historyClearRequested { try removePreservedHistory() }
            historyClearRequested = false
            hasUnsavedHistory = false
            historyError = nil
            if historyRecoveryPending {
                historyRecoveryMessage = "恢复的历史与本次口述已完整保存到主文件和备份。"
                historyRecoveryPending = false
            }
            return true
        } catch {
            hasUnsavedHistory = true
            historyError = historyClearRequested
                ? "历史尚未完全清除，磁盘文件或隔离副本仍需处理；请检查权限后重试。"
                : "历史尚未完整保存到主文件和备份；当前结果仍在内存，请勿直接结束进程，可修复存储后重试保存。"
            return false
        }
    }

    private func preserveDamagedHistory(named name: String) throws {
        guard let url = directory?.appendingPathComponent(name), files.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        if (try? JSONDecoder().decode([DictationEntry].self, from: data)) != nil { return }
        // Memoize only successfully preserved bytes. A failed later rename can
        // be retried without creating duplicate quarantine copies every time.
        if preservedHistoryBytes[name] == data { return }
        let stem = String(name.dropLast(5))
        try writeData(data, named: "\(stem).damaged-\(UUID().uuidString).json")
        preservedHistoryBytes[name] = data
    }

    private func removePreservedHistory() throws {
        guard let directory, files.fileExists(atPath: directory.path) else { return }
        // Explicit clear owns only the history recovery copies. Preferences,
        // vocabulary, usage totals, and unrelated files remain untouched.
        for url in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let name = url.lastPathComponent
            let prefix = ["history.damaged-", "history.backup.damaged-"].first { name.hasPrefix($0) }
            if let prefix, name.hasSuffix(".json"),
               UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(5))) != nil,
               try files.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular {
                try files.removeItem(at: url)
            }
        }
        preservedHistoryBytes.removeAll()
        historyRecoveryMessage = nil
        historyRecoveryPending = false
    }

    private func write<T: Encodable>(_ value: T, named name: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        try writeData(data, named: name)
    }

    private func writeData(_ data: Data, named name: String) throws {
        guard let directory else { throw CocoaError(.fileNoSuchFile) }
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let destination = directory.appendingPathComponent(name)
        let temporary = directory.appendingPathComponent(".\(name).\(UUID().uuidString).tmp")
        guard files.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? files.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        // Rename within the same private directory atomically replaces the old
        // complete JSON. No reader can observe an incomplete preferences/history.
        guard Darwin.rename(temporary.path, destination.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func refreshError() {
        let messages = [validationError, preferencesError, historyError, usageError].compactMap { $0 }
        storageError = messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    private func changed() {
        refreshError()
        onChange?()
    }
}
