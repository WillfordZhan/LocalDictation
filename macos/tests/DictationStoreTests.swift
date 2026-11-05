import Foundation

@main
enum StoreChecks {
    static let files = FileManager.default

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "StoreChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    @discardableResult
    static func add(_ store: DictationStore, _ text: String = "请不要删除 12 条记录。") -> DictationEntry {
        store.add(rawText: "嗯，" + text, text: text, asrSeconds: 0.2, cleanupSeconds: 0.1,
                  totalSeconds: 0.3, audioSeconds: 2, cleanupApplied: true, warning: nil)
    }

    static func seed(_ directory: URL, preferences: DictationPreferences, entries: [DictationEntry]) throws {
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(preferences).write(to: directory.appendingPathComponent("preferences.json"))
        try JSONEncoder().encode(entries).write(to: directory.appendingPathComponent("history.json"))
    }

    static func entry(ageDays: Int, text: String) -> DictationEntry {
        DictationEntry(id: UUID(), createdAt: Date().addingTimeInterval(-Double(ageDays) * 86400),
                       rawText: text, text: text, asrSeconds: 0.2, cleanupSeconds: 0.1,
                       totalSeconds: 0.3, audioSeconds: nil, cleanupApplied: true, warning: nil)
    }

    static func usageChecks(_ root: URL) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
        }
        func sample(_ day: Date, text: String = "你好，AB 12", audio: Double? = 2,
                    processing: Double = 0.3) -> DictationEntry {
            DictationEntry(id: UUID(), createdAt: day, rawText: "嗯，重复重复" + text,
                           text: text, asrSeconds: 0.2, cleanupSeconds: 0.1,
                           totalSeconds: processing, audioSeconds: audio,
                           cleanupApplied: true, warning: nil)
        }
        try require(DictationUsage.characterCount(in: "你 好，Codex 12!\n e\u{301} 🗣️") == 11,
                    "output character count must exclude whitespace/punctuation and count composed characters once")
        var usage = DictationUsage()
        let empty = usage.summary(now: date(2026, 3, 9), calendar: calendar)
        try require(empty.startedAt == nil && empty.characterCount == 0 && empty.dictationCount == 0 &&
                    empty.audioSeconds == 0 && empty.charactersPerMinute == nil && empty.estimatedSavedSeconds == 0 &&
                    empty.activeDays == 0 && empty.currentStreak == 0 && empty.longestStreak == 0,
                    "empty usage must not invent activity or a start date")
        usage.record(sample(date(2026, 3, 6), text: "  ，。!?\n"), calendar: calendar)
        try require(usage.days.isEmpty && usage.startedAt == nil, "punctuation-only result counted as dictation")
        for day in 6...8 { usage.record(sample(date(2026, 3, day)), calendar: calendar) }
        let summary = usage.summary(now: date(2026, 3, 9), calendar: calendar)
        try require(summary.characterCount == 18 && summary.dictationCount == 3 && summary.audioSeconds == 6,
                    "usage counted raw fillers or lost successful results")
        try require(abs((summary.charactersPerMinute ?? -1) - 180) < 0.001 &&
                    abs((summary.estimatedSavedSeconds ?? -1) - 11.1) < 0.001,
                    "speed or 60-char/min estimate did not include recording and processing time")
        try require(summary.activeDays == 3 && summary.currentStreak == 3 && summary.longestStreak == 3,
                    "yesterday-ending streak across spring DST lost a calendar day")
        try require(usage.summary(now: date(2026, 3, 10), calendar: calendar).currentStreak == 0,
                    "streak should end after a fully inactive day")
        usage.record(sample(date(2026, 3, 9)), calendar: calendar)
        try require(usage.summary(now: date(2026, 3, 9), calendar: calendar).currentStreak == 4,
                    "today's activity did not extend streak")
        usage.record(sample(date(2026, 2, 28)), calendar: calendar)
        usage.record(sample(date(2026, 3, 1)), calendar: calendar)
        try require(usage.summary(now: date(2026, 3, 9), calendar: calendar).longestStreak == 4,
                    "gaps incorrectly joined separate activity runs")
        try require(usage.startedAt == date(2026, 2, 28), "first observed activity date not preserved")
        let fixedKeys = Set(usage.days.keys)
        var tokyo = Calendar(identifier: .gregorian); tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        _ = usage.summary(now: date(2026, 3, 9), calendar: tokyo)
        try require(Set(usage.days.keys) == fixedKeys, "timezone change rebucketed recorded civil dates")

        var fall = DictationUsage()
        for stamp in [date(2026, 10, 31), date(2026, 11, 1), date(2026, 11, 2)] {
            fall.record(sample(stamp), calendar: calendar)
        }
        try require(fall.summary(now: date(2026, 11, 2), calendar: calendar).currentStreak == 3,
                    "fall DST repeated hour changed calendar streak")
        var year = DictationUsage()
        year.record(sample(date(2026, 12, 31)), calendar: calendar)
        year.record(sample(date(2027, 1, 1)), calendar: calendar)
        try require(year.summary(now: date(2027, 1, 1), calendar: calendar).currentStreak == 2,
                    "year boundary broke consecutive days")

        for audio in [nil, 0, -1, Double.nan, Double.infinity] as [Double?] {
            var incomplete = DictationUsage()
            incomplete.record(sample(date(2026, 3, 8)), calendar: calendar)
            incomplete.record(sample(date(2026, 3, 9), audio: audio), calendar: calendar)
            let result = incomplete.summary(now: date(2026, 3, 9), calendar: calendar)
            try require(result.characterCount == 12 && result.dictationCount == 2 && result.audioSeconds == nil &&
                        result.charactersPerMinute == nil && result.estimatedSavedSeconds == nil && incomplete.isValid,
                        "unknown duration fabricated complete time, speed or savings")
        }
        var expensive = DictationUsage()
        expensive.record(sample(date(2026, 3, 9), audio: 30, processing: 10), calendar: calendar)
        try require(expensive.summary().estimatedSavedSeconds == 0, "negative estimated savings must clamp to zero")
        var unknownProcessing = DictationUsage()
        unknownProcessing.record(sample(date(2026, 3, 9), processing: .nan), calendar: calendar)
        let unknownResult = unknownProcessing.summary()
        try require(unknownResult.audioSeconds == 2 && unknownResult.charactersPerMinute == 180 &&
                    unknownResult.estimatedSavedSeconds == nil && unknownProcessing.isValid,
                    "unknown processing duration should only suppress the savings estimate")

        let directory = root.appendingPathComponent("usage-persistence")
        let store = DictationStore(directory: directory)
        let usageURL = directory.appendingPathComponent("usage.json")
        let historyURL = directory.appendingPathComponent("history.json")
        store.add(rawText: "这是不应落盘的口述正文", text: "你好，AB 12", asrSeconds: 0.2, cleanupSeconds: 0.1,
                  totalSeconds: 0.3, audioSeconds: 2, cleanupApplied: true, warning: nil,
                  createdAt: date(2026, 3, 8))
        let persisted = try Data(contentsOf: usageURL)
        let storedText = String(decoding: persisted, as: UTF8.self)
        try require(!storedText.contains("口述正文") && !storedText.contains("你好") && !storedText.contains("rawText") &&
                    !storedText.contains("cleanupApplied") && files.fileExists(atPath: historyURL.path),
                    "aggregate file leaked transcript data or permanent history was not saved")
        let mode = try files.attributesOfItem(atPath: usageURL.path)[.posixPermissions] as? NSNumber
        try require(mode?.intValue == 0o600, "daily aggregates are not private")
        let restarted = DictationStore(directory: directory)
        try require(restarted.entries.count == 1 && restarted.usageSummary().characterCount == 6 &&
                    restarted.usageSummary().dictationCount == 1, "restart lost or replayed usage")
        restarted.updatePreferences { $0.historyRetentionDays = 7 }
        let next = add(restarted)
        let beforeDeletion = restarted.usageSummary().characterCount
        restarted.delete(id: next.id)
        restarted.removeAll()
        restarted.updatePreferences { $0.historyRetentionDays = 0 }
        try require(restarted.usageSummary().characterCount == beforeDeletion &&
                    DictationStore(directory: directory).usageSummary().characterCount == beforeDeletion,
                    "history deletion or retention changed independent usage")
        let keep = add(restarted, "保留历史正文")
        restarted.clearUsage()
        try require(restarted.usageSummary().characterCount == 0 && restarted.usage.startedAt == nil &&
                    restarted.entries.contains(where: { $0.id == keep.id }) && !files.fileExists(atPath: usageURL.path),
                    "clear usage changed history or left old aggregate data")
        try require(DictationStore(directory: directory).usage.days.isEmpty, "cleared usage returned after restart")
        add(restarted)
        try require(DictationStore(directory: directory).usageSummary().dictationCount == 1,
                    "usage did not resume from zero after clear")

        let noBackfill = root.appendingPathComponent("usage-no-backfill")
        var preferences = DictationPreferences(); preferences.historyRetentionDays = 7
        try seed(noBackfill, preferences: preferences, entries: [entry(ageDays: 0, text: "旧历史不是完整累计")])
        let priorHistory = DictationStore(directory: noBackfill)
        try require(priorHistory.entries.count == 1 && priorHistory.usage.days.isEmpty &&
                    !files.fileExists(atPath: noBackfill.appendingPathComponent("usage.json").path),
                    "loading old bounded history fabricated usage totals")
        add(priorHistory)
        try require(DictationStore(directory: noBackfill).usageSummary().dictationCount == 1,
                    "restart backfilled or doubled already counted history")

        let damagedDirectory = root.appendingPathComponent("usage-damaged")
        try files.createDirectory(at: damagedDirectory, withIntermediateDirectories: true)
        let damagedURL = damagedDirectory.appendingPathComponent("usage.json")
        let badData = Data("{broken-statistics".utf8)
        try badData.write(to: damagedURL)
        let damaged = DictationStore(directory: damagedDirectory)
        add(damaged)
        damaged.removeAll()
        damaged.updatePreferences { $0.cleanupEnabled = false }
        let preserved = try Data(contentsOf: damagedURL)
        try require(preserved == badData && damaged.storageError != nil && damaged.usageSummary().dictationCount == 1,
                    "normal operations overwrote damaged aggregates or lost in-memory usage")
        damaged.clearUsage()
        try require(damaged.storageError == nil && !files.fileExists(atPath: damagedURL.path),
                    "explicit aggregate clear failed to recover corrupt file")
        add(damaged)
        try require(DictationStore(directory: damagedDirectory).usageSummary().dictationCount == 1,
                    "aggregate persistence did not recover after explicit clear")
        for modification in ["invalid-date", "negative-count", "unknown-version", "missing-start", "overflow"] {
            var value = DictationUsage()
            value.record(sample(date(2026, 3, 9)), calendar: calendar)
            let key = "2026-03-09"
            switch modification {
            case "invalid-date": value.days["2026-02-30"] = value.days.removeValue(forKey: key)
            case "negative-count": value.days[key]!.dictationCount = -1
            case "unknown-version": value.version = 2
            case "missing-start": value.startedAt = nil
            default:
                value.days[key]!.characterCount = Int.max
                value.days["2026-03-10"] = DictationUsageDay(characterCount: 1, dictationCount: 1)
            }
            let bytes = try JSONEncoder().encode(value)
            try bytes.write(to: damagedURL)
            let invalid = DictationStore(directory: damagedDirectory)
            add(invalid)
            let after = try Data(contentsOf: damagedURL)
            try require(invalid.storageError != nil && after == bytes,
                        "invalid aggregate schema/value overwritten: \(modification)")
        }

        var saturated = DictationUsage()
        saturated.record(sample(date(2026, 3, 9)), calendar: calendar)
        saturated.days["2026-03-09"]!.characterCount = Int.max
        let saturatedBytes = try JSONEncoder().encode(saturated)
        try saturatedBytes.write(to: damagedURL)
        let saturatedStore = DictationStore(directory: damagedDirectory)
        let priorHistoryCount = saturatedStore.entries.count
        add(saturatedStore)
        let afterSaturation = try Data(contentsOf: damagedURL)
        try require(saturatedStore.storageError != nil && saturatedStore.entries.count == priorHistoryCount + 1 &&
                    afterSaturation == saturatedBytes, "saturated aggregate counter crashed or replaced the ledger")

        let memory = DictationStore(directory: damagedDirectory, memoryOnly: true)
        let beforeMemory = try Data(contentsOf: damagedURL)
        try require(memory.usage.days.isEmpty && memory.storageError == nil, "preview loaded aggregate data")
        add(memory)
        try require(memory.usageSummary().dictationCount == 1, "preview did not calculate sample statistics")
        memory.clearUsage()
        let afterMemory = try Data(contentsOf: damagedURL)
        try require(beforeMemory == afterMemory && memory.usage.days.isEmpty, "preview wrote or removed usage file")
    }

    static func permanentHistoryChecks(_ root: URL) throws {
        func read(_ directory: URL, _ name: String = "history.json") throws -> [DictationEntry] {
            try JSONDecoder().decode([DictationEntry].self, from: Data(contentsOf: directory.appendingPathComponent(name)))
        }
        func mirrored(_ directory: URL, count: Int) throws {
            let primary = try Data(contentsOf: directory.appendingPathComponent("history.json"))
            let backup = try Data(contentsOf: directory.appendingPathComponent("history.backup.json"))
            try require(primary == backup, "main history and complete mirror differ after successful save")
            let entries = try JSONDecoder().decode([DictationEntry].self, from: primary)
            try require(entries.count == count, "complete history copy has the wrong entry count")
        }
        func quarantines(_ directory: URL) throws -> [URL] {
            try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter {
                $0.lastPathComponent.hasPrefix("history") && $0.lastPathComponent.contains(".damaged-")
            }
        }

        for legacyDays in [0, 7, 30] {
            let directory = root.appendingPathComponent("permanent-legacy-\(legacyDays)")
            var preferences = DictationPreferences()
            preferences.historyRetentionDays = legacyDays
            preferences.cleanupEnabled = false; preferences.vocabulary = ["保留词典"]
            let old = entry(ageDays: 1500, text: "四年前的完整正文")
            try seed(directory, preferences: preferences, entries: [old])
            let store = DictationStore(directory: directory)
            try require(store.preferences.historyRetentionDays == -1 && !store.preferences.cleanupEnabled &&
                        store.preferences.vocabulary == ["保留词典"] && store.entries.map(\.id) == [old.id],
                        "legacy retention migration deleted old data or unrelated settings")
            let saved = try JSONDecoder().decode(DictationPreferences.self,
                from: Data(contentsOf: directory.appendingPathComponent("preferences.json")))
            try require(saved.historyRetentionDays == -1 && !store.hasUnsavedHistory,
                        "permanent policy or initial mirror was not persisted")
            try mirrored(directory, count: 1)
        }

        let largeDirectory = root.appendingPathComponent("unbounded-history")
        let original = (0..<240).map { entry(ageDays: $0 + 31, text: "永久记录 \($0)") }
        try seed(largeDirectory, preferences: DictationPreferences(), entries: original)
        let large = DictationStore(directory: largeDirectory)
        try require(large.entries.count == 240, "loading permanently retained history trimmed by age/count")
        let latest = add(large, "新增后仍保留全部旧记录")
        try require(large.entries.count == 241 && large.entries.first?.id == latest.id && !large.hasUnsavedHistory,
                    "adding a result trimmed permanent history or left an unreported pending write")
        try require(large.flushHistory(), "explicit permanent-history flush failed")
        let restarted = DictationStore(directory: largeDirectory)
        try require(Set(restarted.entries.map(\.id)) == Set(original.map(\.id) + [latest.id]),
                    "restart lost permanent history identifiers")
        try mirrored(largeDirectory, count: 241)
        try require(large.storageDirectory == largeDirectory && DictationStore(memoryOnly: true).storageDirectory == nil,
                    "storage location is not isolated or preview exposes a production path")

        let recoveryDirectory = root.appendingPathComponent("history-recovery")
        let originalStore = DictationStore(directory: recoveryDirectory)
        let first = add(originalStore, "第一条完整记录"), second = add(originalStore, "第二条完整记录")
        let primary = recoveryDirectory.appendingPathComponent("history.json")
        let backup = recoveryDirectory.appendingPathComponent("history.backup.json")
        let latestIDs = Set([first.id, second.id])
        try mirrored(recoveryDirectory, count: 2)
        let backupMode = try files.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber
        try require(backupMode?.intValue == 0o600, "history mirror lacks private permissions")
        let badPrimary = Data("{primary-truncated".utf8)
        try badPrimary.write(to: primary)
        let recovered = DictationStore(directory: recoveryDirectory)
        try require(Set(recovered.entries.map(\.id)) == latestIDs && !recovered.hasUnsavedHistory &&
                    recovered.historyRecoveryMessage != nil, "valid backup did not recover all latest entries")
        try mirrored(recoveryDirectory, count: 2)
        let firstQuarantines = try quarantines(recoveryDirectory)
        let primaryPreserved = firstQuarantines.contains { (try? Data(contentsOf: $0)) == badPrimary }
        try require(primaryPreserved, "automatic recovery overwrote damaged primary bytes")

        let badBackup = Data("{backup-truncated".utf8)
        try badBackup.write(to: backup)
        let repairedMirror = DictationStore(directory: recoveryDirectory)
        try require(Set(repairedMirror.entries.map(\.id)) == latestIDs && !repairedMirror.hasUnsavedHistory,
                    "valid main file was lost while repairing a damaged backup")
        try mirrored(recoveryDirectory, count: 2)
        let allQuarantines = try quarantines(recoveryDirectory)
        try require(allQuarantines.contains { (try? Data(contentsOf: $0)) == badBackup },
                    "damaged mirror bytes were not preserved")
        try files.removeItem(at: primary)
        let recoveredMissing = DictationStore(directory: recoveryDirectory)
        try require(Set(recoveredMissing.entries.map(\.id)) == latestIDs && !recoveredMissing.hasUnsavedHistory,
                    "missing primary was not recreated from its complete mirror")
        try mirrored(recoveryDirectory, count: 2)
        recoveredMissing.delete(id: first.id)
        try mirrored(recoveryDirectory, count: 1)
        try badPrimary.write(to: primary)
        let noResurrection = DictationStore(directory: recoveryDirectory)
        try require(noResurrection.entries.map(\.id) == [second.id], "backup resurrected an explicitly deleted entry")

        let blockedDirectory = root.appendingPathComponent("history-both-damaged")
        try files.createDirectory(at: blockedDirectory, withIntermediateDirectories: true)
        let blockedMain = blockedDirectory.appendingPathComponent("history.json")
        let blockedBackup = blockedDirectory.appendingPathComponent("history.backup.json")
        try badPrimary.write(to: blockedMain); try badBackup.write(to: blockedBackup)
        let blocked = DictationStore(directory: blockedDirectory)
        let pending = add(blocked, "尚未保存但必须保留的新记录")
        try require(blocked.hasUnsavedHistory && !blocked.flushHistory() && blocked.entries.map(\.id) == [pending.id],
                    "unrecoverable history did not retain pending result or block unsafe flush")
        let retainedMain = try Data(contentsOf: blockedMain), retainedBackup = try Data(contentsOf: blockedBackup)
        try require(retainedMain == badPrimary && retainedBackup == badBackup,
                    "unrecoverable originals were overwritten by an incomplete memory list")
        // A user-restored valid copy can be merged without quitting and losing
        // the pending record. The retry is also the app's quit/update guard.
        try JSONEncoder().encode([first, second]).write(to: blockedBackup)
        try require(blocked.flushHistory() && !blocked.hasUnsavedHistory &&
                    Set(blocked.entries.map(\.id)) == Set([first.id, second.id, pending.id]),
                    "retry after restoring backup discarded the pending result")
        try mirrored(blockedDirectory, count: 3)

        let delayedRecoveryDirectory = root.appendingPathComponent("history-delayed-recovery")
        try files.createDirectory(at: delayedRecoveryDirectory, withIntermediateDirectories: true)
        let obstructedMain = delayedRecoveryDirectory.appendingPathComponent("history.json")
        try files.createDirectory(at: obstructedMain, withIntermediateDirectories: true)
        try JSONEncoder().encode([first]).write(to: delayedRecoveryDirectory.appendingPathComponent("history.backup.json"))
        let delayedRecovery = DictationStore(directory: delayedRecoveryDirectory)
        try require(delayedRecovery.hasUnsavedHistory && delayedRecovery.historyRecoveryMessage?.contains("尚未") == true,
                    "failed recovery write did not remain visibly pending")
        try files.moveItem(at: obstructedMain, to: root.appendingPathComponent("preserved-obstructed-history-directory"))
        try require(delayedRecovery.flushHistory() && !delayedRecovery.hasUnsavedHistory &&
                    delayedRecovery.historyRecoveryMessage?.contains("完整保存") == true,
                    "successful recovery retry retained a stale pending warning")
        try mirrored(delayedRecoveryDirectory, count: 1)

        let writeFailure = root.appendingPathComponent("history-unavailable")
        let sentinel = Data("unrelated sentinel".utf8)
        try sentinel.write(to: writeFailure)
        let unavailable = DictationStore(directory: writeFailure)
        let pendingOne = add(unavailable, "写失败保留一"), pendingTwo = add(unavailable, "写失败保留二")
        try require(unavailable.hasUnsavedHistory && !unavailable.flushHistory() && unavailable.entries.count == 2,
                    "write failure was reported as durable or lost pending records")
        let unchanged = try Data(contentsOf: writeFailure)
        try require(unchanged == sentinel, "history write damaged an unrelated existing file")
        try files.moveItem(at: writeFailure, to: root.appendingPathComponent("history-unavailable-sentinel"))
        try files.createDirectory(at: writeFailure, withIntermediateDirectories: true)
        try require(unavailable.flushHistory() && !unavailable.hasUnsavedHistory,
                    "pending writes did not recover after storage became available")
        try require(Set(DictationStore(directory: writeFailure).entries.map(\.id)) == Set([pendingOne.id, pendingTwo.id]),
                    "recovered write did not persist all pending entries across restart")
        try mirrored(writeFailure, count: 2)

        let mirrorFailureDirectory = root.appendingPathComponent("history-mirror-unavailable")
        let mirrorFailure = DictationStore(directory: mirrorFailureDirectory)
        _ = add(mirrorFailure, "已有完整记录")
        let mirrorPath = mirrorFailureDirectory.appendingPathComponent("history.backup.json")
        try files.removeItem(at: mirrorPath)
        try files.createDirectory(at: mirrorPath, withIntermediateDirectories: true)
        let mirroredPending = add(mirrorFailure, "备份不可写时等待保存")
        try require(mirrorFailure.hasUnsavedHistory && !mirrorFailure.flushHistory() &&
                    mirrorFailure.entries.contains(where: { $0.id == mirroredPending.id }),
                    "mirror failure did not block unsafe completion")
        try files.removeItem(at: mirrorPath)
        try require(mirrorFailure.flushHistory() && !mirrorFailure.hasUnsavedHistory,
                    "mirror repair did not complete the pending save")
        try mirrored(mirrorFailureDirectory, count: 2)
        try files.removeItem(at: mirrorPath)
        try files.createDirectory(at: mirrorPath, withIntermediateDirectories: true)
        mirrorFailure.removeAll()
        try require(mirrorFailure.hasUnsavedHistory && !mirrorFailure.flushHistory() && mirrorFailure.storageError != nil,
                    "partial clear incorrectly reported that both copies were cleared")
        try files.removeItem(at: mirrorPath)
        try require(mirrorFailure.flushHistory() && !mirrorFailure.hasUnsavedHistory,
                    "clear did not resume after mirror destination was repaired")
        try mirrored(mirrorFailureDirectory, count: 0)

        let preferenceFailureDirectory = root.appendingPathComponent("history-bad-preferences")
        try files.createDirectory(at: preferenceFailureDirectory, withIntermediateDirectories: true)
        let badPreferences = Data("{unreadable-preferences".utf8)
        let preferencesPath = preferenceFailureDirectory.appendingPathComponent("preferences.json")
        try badPreferences.write(to: preferencesPath)
        let independentHistory = DictationStore(directory: preferenceFailureDirectory)
        add(independentHistory, "设置损坏不能阻止历史保存")
        try require(independentHistory.preferences.historyRetentionDays == -1 &&
                    independentHistory.flushHistory() && !independentHistory.hasUnsavedHistory,
                    "unrelated preference error disabled permanent history")
        let stillBadPreferences = try Data(contentsOf: preferencesPath)
        try require(stillBadPreferences == badPreferences, "history persistence overwrote unreadable settings")
        try mirrored(preferenceFailureDirectory, count: 1)

        let unknown = recoveryDirectory.appendingPathComponent("history.damaged-manual.json")
        try sentinel.write(to: unknown)
        let independentBackup = recoveryDirectory.appendingPathComponent("upgrade-safety-backup", isDirectory: true)
        try files.createDirectory(at: independentBackup, withIntermediateDirectories: true)
        try sentinel.write(to: independentBackup.appendingPathComponent("history.json"))
        let unknownDirectory = recoveryDirectory.appendingPathComponent("history.damaged-\(UUID().uuidString).json", isDirectory: true)
        try files.createDirectory(at: unknownDirectory, withIntermediateDirectories: true)
        try sentinel.write(to: unknownDirectory.appendingPathComponent("unrelated"))
        let usageBeforeClear = try Data(contentsOf: recoveryDirectory.appendingPathComponent("usage.json"))
        noResurrection.removeAll()
        try require(!noResurrection.hasUnsavedHistory && noResurrection.entries.isEmpty,
                    "explicit clear did not finish safely")
        try mirrored(recoveryDirectory, count: 0)
        let remainingQuarantines = try quarantines(recoveryDirectory)
        // All entries come from this exact directory. macOS may enumerate the
        // canonical /private/var spelling while temporary URLs use /var.
        try require(Set(remainingQuarantines.map(\.lastPathComponent)) == Set([unknown, unknownDirectory].map(\.lastPathComponent)), "explicit clear retained owned quarantines or removed unknown history-like files")
        let unknownAfter = try Data(contentsOf: unknown)
        let independentAfter = try Data(contentsOf: independentBackup.appendingPathComponent("history.json"))
        let usageAfterClear = try Data(contentsOf: recoveryDirectory.appendingPathComponent("usage.json"))
        try require(unknownAfter == sentinel && independentAfter == sentinel && usageAfterClear == usageBeforeClear,
                    "history clear touched upgrade backup, unknown files, or usage aggregates")
        let cleared = DictationStore(directory: recoveryDirectory)
        try require(cleared.entries.isEmpty && !cleared.hasUnsavedHistory, "cleared history reappeared from a backup")
    }

    static func expandedVocabularyChecks(_ root: URL) throws {
        let directory = root.appendingPathComponent("expanded-vocabulary")
        let store = DictationStore(directory: directory)
        for count in [65, 1000] {
            let terms = (0..<count).map { "term-\($0)" }
            store.updatePreferences { $0.vocabulary = terms }
            try require(store.preferences.vocabulary == terms && store.storageError == nil,
                        "valid dictionary over 64 terms was rejected or truncated")
            try require(DictationStore(directory: directory).preferences.vocabulary == terms,
                        "large dictionary was cleared or truncated on restart")
        }
        let longTotal = (0..<100).map { String(repeating: "x", count: 60) + "\($0)" }
        try require(DictationStore.validateVocabulary(longTotal) == nil,
                    "obsolete 2048-character total limit still applies")
        let unicode = (0..<1000).map { "术语\($0)😀" }
        try require(DictationStore.validateVocabulary(unicode) == nil, "Unicode dictionary within transport budget rejected")
        store.updatePreferences { $0.vocabulary = unicode }
        try require(DictationStore(directory: directory).preferences.vocabulary == unicode,
                    "large Unicode dictionary did not survive restart exactly")

        var boundary: [String] = []
        var next = [String]()
        for index in 0..<1000 {
            next = boundary + [String(repeating: "界", count: 60) + "\(index)"]
            let bytes = try DictationStore.encodeRequestOptions(cleanup: false, language: "auto", vocabulary: next)
                .base64EncodedData().count
            if bytes > DictationStore.maxOptionsHeaderBytes { break }
            boundary = next
        }
        let atBoundary = try DictationStore.encodeRequestOptions(cleanup: false, language: "auto", vocabulary: boundary)
            .base64EncodedData().count
        try require(atBoundary > DictationStore.maxOptionsHeaderBytes - 300 &&
                    DictationStore.validateVocabulary(boundary) == nil &&
                    DictationStore.validateVocabulary(next)?.contains("40 KiB") == true,
                    "dictionary capacity must use encoded bytes, including multibyte Unicode")
        for cleanup in [true, false] {
            for language in ["zh", "auto"] {
                let data = try DictationStore.encodeRequestOptions(cleanup: cleanup, language: language, vocabulary: boundary)
                let options = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                try require(options.count == 3 && options["cleanup"] as? Bool == cleanup &&
                            options["language"] as? String == language && options["vocabulary"] as? [String] == boundary,
                            "transport helper changed the request contract or terms")
                try require(data.base64EncodedData().count <= atBoundary,
                            "dictionary validation did not reserve the longest setting encoding")
            }
        }

        let before = store.preferences.vocabulary
        store.updatePreferences { $0.vocabulary = next }
        try require(store.preferences.vocabulary == before && store.storageError?.contains("40 KiB") == true,
                    "oversized transport must reject the whole edit without dropping terms")
        let settingsURL = directory.appendingPathComponent("preferences.json")
        for invalid in [next + ["extra-repair-a", "extra-repair-b"], [String(repeating: "😀", count: 65)]] {
            var preferences = DictationPreferences()
            preferences.cleanupEnabled = false
            preferences.vocabulary = invalid
            let original = try JSONEncoder().encode(preferences)
            try original.write(to: settingsURL)
            let restored = DictationStore(directory: directory)
            try require(restored.preferences.vocabulary == invalid && !restored.preferences.cleanupEnabled &&
                        restored.storageError?.contains("已保留全部词条") == true,
                        "invalid stored vocabulary must remain visible for repair")
            let afterLoad = try Data(contentsOf: settingsURL)
            try require(afterLoad == original, "loading invalid vocabulary changed the source file")
            restored.updatePreferences { $0.autoInsertEnabled = false }
            let afterUnrelatedEdit = try Data(contentsOf: settingsURL)
            try require(afterUnrelatedEdit == original, "unrelated edit discarded an invalid saved dictionary")
            if invalid.count > 1 {
                let reduced = Array(invalid.dropLast())
                try require(DictationStore.validateVocabulary(reduced) != nil, "repair fixture no longer exceeds transport capacity")
                restored.updatePreferences { $0.vocabulary.removeLast() }
                try require(restored.preferences.vocabulary == reduced && restored.storageError?.contains("40 KiB") == true &&
                            DictationStore(directory: directory).preferences.vocabulary == reduced,
                            "oversized saved dictionary could not be repaired by partial deletion")
            }
            restored.updatePreferences { $0.vocabulary = ["修正后的词条"] }
            try require(restored.storageError == nil && DictationStore(directory: directory).preferences.vocabulary == ["修正后的词条"],
                        "repaired dictionary did not clear the warning or persist")
        }
    }

    static func main() {
        do { try run() }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }

    static func run() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("dictation-store-checks-" + UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }

        let localDirectory = root.appendingPathComponent("local")
        let local = DictationStore(directory: localDirectory)
        let first = add(local)
        try require(local.entries.count == 1 && local.preferences.historyRetentionDays == -1, "default permanent history")
        try require(files.fileExists(atPath: localDirectory.appendingPathComponent("history.json").path) &&
                    files.fileExists(atPath: localDirectory.appendingPathComponent("usage.json").path),
                    "default add should save both permanent history and independent aggregates")

        local.updatePreferences { $0.vocabulary = ["  Whisper  ", "Whisper", "", "Qwen"] }
        try require(local.preferences.vocabulary == ["Whisper", "Qwen"], "trim/deduplicate")
        try require(DictationStore.validateVocabulary([String(repeating: "e\u{301}", count: 33)]) != nil, "length must count Unicode scalars")
        try expandedVocabularyChecks(root)
        local.updatePreferences { $0.historyRetentionDays = 7 }
        let historyURL = localDirectory.appendingPathComponent("history.json")
        let reloaded = DictationStore(directory: localDirectory)
        try require(reloaded.entries.map(\.id) == [first.id], "default history did not survive restart")
        let directoryMode = try files.attributesOfItem(atPath: localDirectory.path)[.posixPermissions] as? NSNumber
        let historyMode = try files.attributesOfItem(atPath: historyURL.path)[.posixPermissions] as? NSNumber
        let preferencesMode = try files.attributesOfItem(atPath: localDirectory.appendingPathComponent("preferences.json").path)[.posixPermissions] as? NSNumber
        try require(directoryMode?.intValue == 0o700 && historyMode?.intValue == 0o600 && preferencesMode?.intValue == 0o600, "private permissions")
        reloaded.delete(id: first.id)
        try require(DictationStore(directory: localDirectory).entries.isEmpty, "delete did not persist")
        add(reloaded, "临时保留")
        reloaded.updatePreferences { $0.historyRetentionDays = 0 }
        try require(files.fileExists(atPath: historyURL.path) && reloaded.entries.count == 1 && DictationStore(directory: localDirectory).entries.count == 1 && reloaded.preferences.historyRetentionDays == -1, "legacy opt-out must not disable permanent history or delete existing records")

        let legacyDirectory = root.appendingPathComponent("legacy")
        try files.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        try Data("{\"cleanupEnabled\":false}".utf8).write(to: legacyDirectory.appendingPathComponent("preferences.json"))
        let legacy = DictationStore(directory: legacyDirectory)
        try require(!legacy.preferences.cleanupEnabled && legacy.preferences.autoInsertEnabled && legacy.preferences.recognitionLanguage == "zh" && legacy.preferences.historyRetentionDays == -1, "older settings lost existing values")
        try require(legacy.preferences.shortcutMode == "fn" && legacy.preferences.shortcutKeyCode == 63 && legacy.preferences.shortcutModifiers == 0 && legacy.preferences.shortcutDisplay == "Fn", "older settings did not get Fn default")

        let shortcutDirectory = root.appendingPathComponent("shortcut")
        let shortcut = DictationStore(directory: shortcutDirectory)
        shortcut.updatePreferences {
            $0.shortcutMode = "combination"
            $0.shortcutKeyCode = 122 // F1
            $0.shortcutModifiers = 4096 | 512
            $0.shortcutDisplay = "⌃⇧F1"
            $0.cleanupEnabled = false
            $0.vocabulary = ["Whisper", "工作流"]
        }
        let customShortcut = DictationStore(directory: shortcutDirectory)
        try require(customShortcut.preferences.shortcutMode == "combination" && customShortcut.preferences.shortcutKeyCode == 122 && customShortcut.preferences.shortcutModifiers == 4608 && customShortcut.preferences.shortcutDisplay == "⌃⇧F1", "custom shortcut did not round-trip")
        let shortcutURL = shortcutDirectory.appendingPathComponent("preferences.json")
        let customBytes = try Data(contentsOf: shortcutURL)
        let invalidShortcuts: [(UInt32, UInt32, String)] = [
            (128, 256, "⌘?"), (53, 256, "⌘Esc"), (54, 256, "⌘"), (57, 256, "⌘CapsLock"),
            (63, 256, "⌘Fn"), (49, 0, "Space"), (49, 512, "⇧Space"),
            (49, 6400 | 1024, "unsupported"), (49, 6400, "  \n"),
            (49, 6400, String(repeating: "e\u{301}", count: 33))
        ]
        for (keyCode, modifiers, display) in invalidShortcuts {
            try require(DictationStore.validateShortcut(keyCode: keyCode, modifiers: modifiers, display: display) != nil, "invalid shortcut accepted")
            shortcut.updatePreferences {
                $0.shortcutKeyCode = keyCode; $0.shortcutModifiers = modifiers; $0.shortcutDisplay = display
                $0.cleanupEnabled = true
            }
            try require(shortcut.preferences.shortcutKeyCode == 122 && shortcut.preferences.shortcutModifiers == 4608 && !shortcut.preferences.cleanupEnabled && shortcut.storageError != nil, "invalid shortcut partially changed preferences")
            let afterInvalid = try Data(contentsOf: shortcutURL)
            try require(afterInvalid == customBytes, "invalid shortcut replaced saved settings")
        }
        try require(DictationStore.validateShortcut(keyCode: 49, modifiers: 256, display: "⌘Space") == nil, "space shortcut rejected")
        try require(DictationStore.validateShortcut(keyCode: 0, modifiers: 2048, display: "任意非空显示") == nil, "valid key or display rejected")
        try require(DictationStore.validateShortcut(keyCode: 63, modifiers: 0, display: "Fn", mode: "fn") == nil, "Fn default rejected")
        try require(DictationStore.validateShortcut(keyCode: 63, modifiers: 0, display: "Fn", mode: "combination") != nil, "Fn accepted as combination")
        for (key, modifiers, display, mode) in [(UInt32(49), UInt32(0), "Fn", "fn"), (63, 256, "Fn", "fn"), (63, 0, "fn", "fn"), (63, 0, "Fn", "unknown")] {
            shortcut.updatePreferences {
                $0.shortcutMode = mode; $0.shortcutKeyCode = key; $0.shortcutModifiers = modifiers; $0.shortcutDisplay = display
            }
            try require(shortcut.preferences.shortcutMode == "combination" && shortcut.preferences.shortcutKeyCode == 122 && shortcut.storageError != nil, "invalid mode or Fn tuple changed preferences")
            let afterInvalid = try Data(contentsOf: shortcutURL)
            try require(afterInvalid == customBytes, "invalid Fn tuple replaced saved settings")
        }
        shortcut.updatePreferences { $0.shortcutMode = "fn"; $0.shortcutKeyCode = 63; $0.shortcutModifiers = 0; $0.shortcutDisplay = "Fn" }
        let fnReloaded = DictationStore(directory: shortcutDirectory)
        try require(fnReloaded.preferences.shortcutMode == "fn" && fnReloaded.preferences.shortcutKeyCode == 63 && fnReloaded.preferences.shortcutModifiers == 0 && fnReloaded.preferences.shortcutDisplay == "Fn", "Fn did not round-trip")
        let legacyCombination: [String: Any] = ["cleanupEnabled": false, "shortcutKeyCode": 122, "shortcutModifiers": 4608, "shortcutDisplay": "⌃⇧F1"]
        try JSONSerialization.data(withJSONObject: legacyCombination).write(to: shortcutURL)
        let migrated = DictationStore(directory: shortcutDirectory)
        try require(migrated.preferences.shortcutMode == "combination" && migrated.preferences.shortcutKeyCode == 122 && migrated.preferences.shortcutModifiers == 4608 && migrated.preferences.shortcutDisplay == "⌃⇧F1" && !migrated.preferences.cleanupEnabled, "legacy custom shortcut not preserved")
        // Both semantic violations and malformed JSON field types repair only
        // the shortcut, leaving the user's independent settings intact.
        for invalidKey: Any in [53, -1, "not-a-key"] {
            let stored: [String: Any] = ["cleanupEnabled": false, "recognitionLanguage": "auto",
                "vocabulary": ["Whisper", "工作流"], "shortcutKeyCode": invalidKey,
                "shortcutModifiers": 4608, "shortcutDisplay": "⌃⇧F1"]
            let bytes = try JSONSerialization.data(withJSONObject: stored, options: [.sortedKeys])
            try bytes.write(to: shortcutURL)
            let repaired = DictationStore(directory: shortcutDirectory)
            try require(repaired.preferences.shortcutMode == "fn" && repaired.preferences.shortcutKeyCode == 63 && repaired.preferences.shortcutModifiers == 0 && repaired.preferences.shortcutDisplay == "Fn", "invalid stored shortcut not repaired to Fn as a whole")
            try require(!repaired.preferences.cleanupEnabled && repaired.preferences.recognitionLanguage == "auto" && repaired.preferences.vocabulary == ["Whisper", "工作流"], "shortcut repair discarded unrelated preferences")
            let unchanged = try Data(contentsOf: shortcutURL)
            try require(unchanged == bytes, "loading repaired shortcut unexpectedly rewrote disk")
        }

        let expiryDirectory = root.appendingPathComponent("expiry")
        var sevenDays = DictationPreferences()
        sevenDays.historyRetentionDays = 7
        let recent = entry(ageDays: 0, text: "recent"), old = entry(ageDays: 8, text: "expired")
        try seed(expiryDirectory, preferences: sevenDays, entries: [old, recent])
        let expiry = DictationStore(directory: expiryDirectory)
        try require(expiry.entries.map(\.id) == [recent.id, old.id], "legacy 7-day policy deleted older entries")
        let diskEntries = try JSONDecoder().decode([DictationEntry].self, from: Data(contentsOf: expiryDirectory.appendingPathComponent("history.json")))
        try require(diskEntries.map(\.id) == [recent.id, old.id], "permanent history lost older disk entries")
        var thirtyDays = sevenDays
        thirtyDays.historyRetentionDays = 30
        let oldest = entry(ageDays: 731, text: "two years old")
        try seed(expiryDirectory, preferences: thirtyDays, entries: [old, recent, oldest])
        try require(DictationStore(directory: expiryDirectory).entries.map(\.id) == [recent.id, old.id, oldest.id], "legacy 30-day policy deleted permanent history")

        let damagedDirectory = root.appendingPathComponent("damaged")
        try seed(damagedDirectory, preferences: sevenDays, entries: [])
        let damagedURL = damagedDirectory.appendingPathComponent("history.json")
        let damagedBytes = Data("{not-valid-json".utf8)
        try damagedBytes.write(to: damagedURL)
        let damaged = DictationStore(directory: damagedDirectory)
        try require(damaged.storageError != nil && damaged.entries.isEmpty, "damaged history must expose error")
        let pending = add(damaged)
        damaged.delete(id: pending.id)
        damaged.updatePreferences { $0.historyRetentionDays = 30 }
        let retainedBadBytes = try Data(contentsOf: damagedURL)
        try require(retainedBadBytes == damagedBytes, "damaged history was overwritten")
        damaged.removeAll()
        try require(files.fileExists(atPath: damagedURL.path) && damaged.storageError == nil && !damaged.hasUnsavedHistory && DictationStore(directory: damagedDirectory).entries.isEmpty, "clear must reset both copies and unblock damaged history")
        add(damaged)
        try require(DictationStore(directory: damagedDirectory).entries.count == 1, "persistence did not resume after explicit clear")

        let orphanDirectory = root.appendingPathComponent("orphan")
        try files.createDirectory(at: orphanDirectory, withIntermediateDirectories: true)
        let orphanURL = orphanDirectory.appendingPathComponent("history.json")
        try damagedBytes.write(to: orphanURL)
        let orphan = DictationStore(directory: orphanDirectory)
        add(orphan)
        orphan.updatePreferences { $0.historyRetentionDays = 7 }
        let orphanBytes = try Data(contentsOf: orphanURL)
        try require(orphanBytes == damagedBytes && orphan.storageError != nil, "legacy preference change overwrote unreadable history")

        let memoryOnly = DictationStore(directory: damagedDirectory, memoryOnly: true)
        try require(memoryOnly.entries.isEmpty && memoryOnly.preferences.historyRetentionDays == -1, "memory-only read persisted state")
        let savedHistory = try Data(contentsOf: damagedURL)
        let savedSettings = try Data(contentsOf: damagedDirectory.appendingPathComponent("preferences.json"))
        memoryOnly.updatePreferences { $0.historyRetentionDays = 30; $0.cleanupEnabled = false }
        for number in 0..<201 { add(memoryOnly, "\(number)") }
        try require(memoryOnly.entries.count == 201 && memoryOnly.entries.first?.text == "200", "permanent history must retain more than 200 entries")
        try require(memoryOnly.usageSummary().dictationCount == 201,
                    "history growth changed independent aggregate usage")
        memoryOnly.removeAll()
        try require(memoryOnly.usageSummary().dictationCount == 201, "clearing history also cleared usage")
        let unchangedHistory = try Data(contentsOf: damagedURL)
        let unchangedSettings = try Data(contentsOf: damagedDirectory.appendingPathComponent("preferences.json"))
        try require(unchangedHistory == savedHistory && unchangedSettings == savedSettings, "memory-only wrote disk")

        let unavailableDirectory = root.appendingPathComponent("not-a-directory")
        try Data("sentinel".utf8).write(to: unavailableDirectory)
        let unavailable = DictationStore(directory: unavailableDirectory)
        unavailable.updatePreferences { $0.historyRetentionDays = 7; $0.cleanupEnabled = false }
        add(unavailable)
        try require(unavailable.storageError != nil && unavailable.entries.count == 1 && !unavailable.preferences.cleanupEnabled, "write failure must retain current memory")
        let sentinel = try Data(contentsOf: unavailableDirectory)
        try require(sentinel == Data("sentinel".utf8), "write failure changed existing unrelated bytes")
        try usageChecks(root)
        try permanentHistoryChecks(root)
        print("PASS: shortcut defaults/validation/persistence/isolated repair; permanent history and legacy policy migration; vocabulary limits; no age/count trimming; explicit delete/clear; corrupt-file preservation; private permissions; older settings; preview IO isolation; write failure memory retention; independent daily aggregates; counts/rates/estimated savings; unknown timing; DST/year-boundary streaks; restart without aggregate backfill; aggregate clear/corruption recovery; mirrored history recovery and safe flush.")
    }
}
