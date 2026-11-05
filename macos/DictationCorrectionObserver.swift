import AppKit
import ApplicationServices
import NaturalLanguage

struct DictationCorrectionCandidate: Equatable {
    let entryID: UUID
    let original: String
    let corrected: String
    let bundleID: String?
    let observedAt: Date
    var requiresConfirmation = false
}

enum DictationCorrectionAvailability: Equatable {
    case idle, confirming, observing, learned, awaitingConfirmation, unsupported, unconfirmed
}

struct DictationCorrectionSnapshot {
    let text: String
    let selection: CFRange
}

enum DictationCorrectionReadResult {
    case snapshot(DictationCorrectionSnapshot)
    case unavailable
    case focusChanged
}

/// Automatic learning requires a spelling/casing signal. Short lower-case
/// phrases remain ambiguous and can only become an explicit confirmation.
/// In either path, replaying the same replacement must explain the entire edit.
enum DictationCorrectionDetector {
    static func candidate(in original: String, edited: String) -> (original: String, corrected: String, requiresConfirmation: Bool)? {
        if let correction = correction(in: original, edited: edited) {
            return (correction.original, correction.corrected, false)
        }
        let before = Array(original), after = Array(edited)
        guard let start = firstChange(before, after),
              let oldRange = phraseRange(in: before, at: start),
              let newRange = phraseRange(in: after, at: start) else { return nil }
        let source = String(before[oldRange]), destination = String(after[newRange])
        let oldWords = source.split(separator: " ", omittingEmptySubsequences: false)
        let newWords = destination.split(separator: " ", omittingEmptySubsequences: false)
        // Keep the confirmation about a short term, not a rewritten English
        // sentence. A neighbouring unchanged word supplies the phrase scope.
        guard (2...3).contains(oldWords.count), oldWords.count == newWords.count,
              source.count <= 64, destination.count <= 64,
              oldWords.allSatisfy({ !$0.isEmpty && $0.allSatisfy(isLowercaseLetter) }),
              newWords.allSatisfy({ !$0.isEmpty && $0.allSatisfy(isLowercaseLetter) }) else { return nil }
        let changed = oldWords.indices.filter { oldWords[$0] != newWords[$0] }
        guard changed.count == 1 else { return nil }
        let a = Array(oldWords[changed[0]]), b = Array(newWords[changed[0]])
        guard min(a.count, b.count) >= 3, abs(a.count - b.count) <= 1,
              editDistance(a, b) <= 2, hasTermShape(destination),
              replacementExplainsEdit(original, edited: edited, source: source, destination: destination) else { return nil }
        return (source, destination, true)
    }

    static func correction(in original: String, edited: String) -> (original: String, corrected: String)? {
        if let result = singleCorrection(in: original, edited: edited) { return result }
        let before = Array(original), after = Array(edited)
        guard let start = firstChange(before, after),
              let oldRange = tokenRange(in: original, characters: before, start: start, end: start + 1),
              let newRange = tokenRange(in: edited, characters: after, start: start, end: start + 1) else { return nil }
        let source = String(before[oldRange]), destination = String(after[newRange])
        guard isHighConfidence(source: source, destination: destination),
              replacementExplainsEdit(original, edited: edited, source: source, destination: destination) else { return nil }
        return (source, destination)
    }

    private static func singleCorrection(in original: String, edited: String) -> (original: String, corrected: String)? {
        let before = Array(original), after = Array(edited)
        guard before != after, !before.isEmpty, !after.isEmpty else { return nil }
        // Appending a message or deleting its tail is not an explicit correction.
        guard !edited.hasPrefix(original), !original.hasPrefix(edited) else { return nil }
        var start = 0
        while start < min(before.count, after.count), before[start] == after[start] { start += 1 }
        var oldEnd = before.count, newEnd = after.count
        while oldEnd > start, newEnd > start, before[oldEnd - 1] == after[newEnd - 1] {
            oldEnd -= 1; newEnd -= 1
        }
        guard let token = tokenRange(in: edited, characters: after, start: start, end: newEnd) else { return nil }
        let oldTokenEnd = token.upperBound + before.count - after.count
        guard token.lowerBound < oldTokenEnd, oldTokenEnd <= before.count,
              before[..<token.lowerBound].elementsEqual(after[..<token.lowerBound]),
              before[oldTokenEnd...].elementsEqual(after[token.upperBound...]) else { return nil }
        let source = String(before[token.lowerBound..<oldTokenEnd])
        let destination = String(after[token])
        guard isHighConfidence(source: source, destination: destination) else { return nil }
        return (source, destination)
    }

    private static func firstChange(_ before: [Character], _ after: [Character]) -> Int? {
        var index = 0
        while index < min(before.count, after.count), before[index] == after[index] { index += 1 }
        // A pure append/delete is not a correction, even if the result looks
        // like a known technical identifier.
        return index < min(before.count, after.count) ? index : nil
    }

    private static func isLowercaseLetter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { (97...122).contains($0.value) }
    }

    private static func phraseRange(in characters: [Character], at index: Int) -> Range<Int>? {
        func isPhraseCharacter(_ value: Character) -> Bool { isLowercaseLetter(value) || value == " " }
        guard characters.indices.contains(index), isPhraseCharacter(characters[index]) else { return nil }
        var lower = index, upper = index + 1
        while lower > 0, isPhraseCharacter(characters[lower - 1]) { lower -= 1 }
        while upper < characters.count, isPhraseCharacter(characters[upper]) { upper += 1 }
        while lower < upper, characters[lower] == " " { lower += 1 }
        while upper > lower, characters[upper - 1] == " " { upper -= 1 }
        return lower..<upper
    }

    private static func hasTermShape(_ phrase: String) -> Bool {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = phrase; tagger.setLanguage(.english, range: phrase.startIndex..<phrase.endIndex)
        var tags: [NLTag] = []
        tagger.enumerateTags(in: phrase.startIndex..<phrase.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, _ in
            tags.append(tag ?? .otherWord); return true
        }
        // A noun phrase may contain an ambiguous internal word ("cache hit
        // rate"). Verb-led commands and pronoun-led sentences are not terms.
        // This is only a conservative presentation filter, never proof that a
        // lower-case replacement is semantically equivalent or safe to learn.
        return (tags.first == .noun || tags.first == .adjective) && tags.last == .noun
    }

    private static func replacementExplainsEdit(_ original: String, edited: String,
                                                source: String, destination: String) -> Bool {
        let before = Array(original), after = Array(edited), source = Array(source), destination = Array(destination)
        guard !source.isEmpty, !destination.isEmpty, source != destination else { return false }
        func matches(_ term: [Character], in text: [Character], at index: Int) -> Bool {
            guard index + term.count <= text.count,
                  text[index..<index + term.count].elementsEqual(term) else { return false }
            return (index == 0 || !isIdentifier(text[index - 1]))
                && (index + term.count == text.count || !isIdentifier(text[index + term.count]))
        }
        var oldIndex = 0, newIndex = 0, replacements = 0
        while oldIndex < before.count {
            if matches(source, in: before, at: oldIndex) {
                if matches(destination, in: after, at: newIndex) {
                    oldIndex += source.count; newIndex += destination.count; replacements += 1
                } else if matches(source, in: after, at: newIndex) {
                    oldIndex += source.count; newIndex += source.count
                } else { return false }
            } else {
                guard newIndex < after.count, before[oldIndex] == after[newIndex] else { return false }
                oldIndex += 1; newIndex += 1
            }
        }
        return newIndex == after.count && replacements > 0
    }

    private static func tokenRange(in text: String, characters: [Character], start: Int, end: Int) -> Range<Int>? {
        // An insertion at a word boundary must not borrow a neighbouring word.
        let probe = min(start, characters.count - 1)
        if isIdentifier(characters[probe]) || (probe > 0 && end == start && isIdentifier(characters[probe - 1])) {
            var lower = probe, upper = max(end, probe)
            while lower > 0 && isIdentifier(characters[lower - 1]) { lower -= 1 }
            while upper < characters.count && isIdentifier(characters[upper]) { upper += 1 }
            while upper > lower && characters[upper - 1] == "." { upper -= 1 }
            guard lower < upper, start >= lower, end <= upper else { return nil }
            return lower..<upper
        }
        guard isHan(characters[probe]) else { return nil }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text; tokenizer.setLanguage(.simplifiedChinese)
        let index = text.index(text.startIndex, offsetBy: probe)
        let range = tokenizer.tokenRange(at: index)
        let lower = text.distance(from: text.startIndex, to: range.lowerBound)
        let upper = text.distance(from: text.startIndex, to: range.upperBound)
        guard lower <= start, upper >= end, lower < upper else { return nil }
        return lower..<upper
    }

    private static func isHighConfidence(source: String, destination: String) -> Bool {
        guard source != destination, (2...64).contains(source.count), (2...64).contains(destination.count),
              source == source.trimmingCharacters(in: .whitespacesAndNewlines),
              destination == destination.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        if source.allSatisfy(isHan), destination.allSatisfy(isHan) {
            guard source.count <= 12, destination.count <= 12 else { return false }
            func pronunciation(_ value: String) -> String {
                (value.applyingTransform(.toLatin, reverse: false)?
                    .applyingTransform(.stripDiacritics, reverse: false) ?? "")
                    .lowercased().filter(\.isLetter)
            }
            let spoken = pronunciation(source)
            return !spoken.isEmpty && spoken == pronunciation(destination)
        }
        guard source.allSatisfy({ isIdentifier($0) || $0 == " " }), destination.allSatisfy(isIdentifier),
              source.contains(where: \.isLetter), destination.contains(where: \.isLetter),
              source.filter(\.isNumber) == destination.filter(\.isNumber) else { return false }
        let a = source.lowercased().replacingOccurrences(of: " ", with: "")
        let b = destination.lowercased()
        let letters = destination.filter(\.isLetter)
        let acronym = (2...12).contains(letters.count) && letters == letters.uppercased()
        let camelCase = destination.dropFirst().contains(where: \.isUppercase)
        let explicitCode = destination.contains { $0.isNumber || "_+#./-".contains($0) }
        if a == b { return acronym || camelCase || explicitCode }
        let transposition = isAdjacentTransposition(Array(a), Array(b))
        // Ordinary lower-case word substitutions can be a change of meaning.
        guard acronym || camelCase || explicitCode || (destination.first?.isUppercase == true && transposition) else { return false }
        return transposition || editDistance(Array(a), Array(b)) <= (max(a.count, b.count) >= 8 ? 2 : 1)
    }

    private static func isIdentifier(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_+#./-".unicodeScalars.contains($0)) }
    }
    private static func isHan(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { (0x3400...0x9fff).contains($0.value) || (0x20000...0x3134f).contains($0.value) }
    }
    private static func isAdjacentTransposition(_ a: [Character], _ b: [Character]) -> Bool {
        guard a.count == b.count else { return false }
        let changed = a.indices.filter { a[$0] != b[$0] }
        return changed.count == 2 && changed[1] == changed[0] + 1 && a[changed[0]] == b[changed[1]] && a[changed[1]] == b[changed[0]]
    }
    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        var previous = Array(0...b.count)
        for (i, character) in a.enumerated() {
            var current = [i + 1]
            for (j, other) in b.enumerated() {
                current.append(min(current[j] + 1, previous[j + 1] + 1, previous[j] + (character == other ? 0 : 1)))
            }
            previous = current
        }
        return previous[b.count]
    }
}

/// Watches only one verified insertion into one focused AX element. No keyboard
/// monitor is installed and no field text leaves this short-lived memory state.
final class DictationCorrectionObserver {
    typealias Reader = (pid_t, AXUIElement) -> DictationCorrectionReadResult
    static let maximumFieldLength = 16_384
    static let maximumObservation: TimeInterval = 120
    var onCorrection: ((DictationCorrectionCandidate) -> Void)?
    var onAvailability: ((DictationCorrectionAvailability) -> Void)?
    private(set) var availability: DictationCorrectionAvailability = .idle

    private struct Observation {
        let pid: pid_t
        let element: AXUIElement
        let range: NSRange
        let original: String
        let entryID: UUID
        let bundleID: String?
        let started: TimeInterval
        var prefix: String?
        var suffix: String?
        var pending: String?
        var pendingSince: TimeInterval = 0
    }
    private let reader: Reader
    private let clock: () -> TimeInterval
    private let pollsAutomatically: Bool
    private let readQueue: DispatchQueue
    private var observation: Observation?
    private var generation = UUID()
    private var inFlight = false
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?

    init(reader: @escaping Reader = DictationCorrectionObserver.readField,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         pollsAutomatically: Bool = true,
         readQueue: DispatchQueue = DispatchQueue(label: "local-dictation.correction-observer", qos: .utility)) {
        self.reader = reader; self.clock = clock; self.pollsAutomatically = pollsAutomatically; self.readQueue = readQueue
    }

    deinit {
        timer?.invalidate()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }

    func observeInsertion(pid: pid_t, element: AXUIElement, range: CFRange, text: String,
                          entryID: UUID, bundleID: String?) {
        precondition(Thread.isMainThread)
        stop()
        let length = text.utf16.count
        guard range.location >= 0, range.length >= 0, length > 0,
              length <= Self.maximumFieldLength, range.location <= Self.maximumFieldLength - length else {
            setAvailability(.unsupported); return
        }
        observation = Observation(pid: pid, element: element, range: NSRange(location: range.location, length: length),
            original: text, entryID: entryID, bundleID: bundleID, started: clock())
        setAvailability(.confirming)
        if pollsAutomatically {
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let self, let application = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      application.processIdentifier != self.observation?.pid else { return }
                self.stop()
            }
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.sampleNow() }
            self.timer = timer; RunLoop.main.add(timer, forMode: .common)
            sampleNow()
        }
    }

    func stop() {
        precondition(Thread.isMainThread)
        generation = UUID(); observation = nil
        timer?.invalidate(); timer = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        setAvailability(.idle)
    }

    /// A bounded AX read runs off the main thread; late results from an older
    /// insertion cannot adopt the identity or contents of a newer insertion.
    func sampleNow() {
        precondition(Thread.isMainThread)
        guard let observation else { return }
        guard clock() - observation.started < Self.maximumObservation else { stop(); return }
        guard observation.prefix != nil || clock() - observation.started < 2 else {
            stop(); setAvailability(.unconfirmed); return
        }
        guard !inFlight else { return }
        inFlight = true
        let generation = self.generation, reader = self.reader
        readQueue.async { [weak self] in
            let result = reader(observation.pid, observation.element)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.inFlight = false
                guard self.generation == generation else { return }
                self.consume(result)
            }
        }
    }

    private func consume(_ result: DictationCorrectionReadResult) {
        guard var item = observation else { return }
        guard clock() - item.started < Self.maximumObservation else { stop(); return }
        switch result {
        case .focusChanged: stop()
        case .unavailable: stop(); setAvailability(.unsupported)
        case .snapshot(let snapshot):
            let text = snapshot.text as NSString
            let selection = snapshot.selection
            guard text.length <= Self.maximumFieldLength, selection.location >= 0, selection.length >= 0,
                  selection.location <= text.length, selection.length <= text.length - selection.location else {
                stop(); setAvailability(.unsupported); return
            }
            if item.prefix == nil {
                guard clock() - item.started < 2 else { stop(); setAvailability(.unconfirmed); return }
                guard NSMaxRange(item.range) <= text.length,
                      text.substring(with: item.range) == item.original,
                      selection.location == NSMaxRange(item.range), selection.length == 0 else { return }
                item.prefix = text.substring(to: item.range.location)
                item.suffix = text.substring(from: NSMaxRange(item.range))
                observation = item; setAvailability(.observing); return
            }
            let prefix = item.prefix!, suffix = item.suffix!
            let prefixLength = prefix.utf16.count, suffixLength = suffix.utf16.count
            // Submission/clear, editing outside our span, or moving to another
            // part of the field ends observation rather than widening its scope.
            guard snapshot.text.hasPrefix(prefix), snapshot.text.hasSuffix(suffix),
                  text.length > prefixLength + suffixLength else { stop(); return }
            let range = NSRange(location: prefixLength, length: text.length - prefixLength - suffixLength)
            guard selection.location >= range.location, selection.location + selection.length <= NSMaxRange(range) else { stop(); return }
            let edited = text.substring(with: range)
            if edited == item.original { item.pending = nil; observation = item; return }
            if edited != item.pending {
                item.pending = edited; item.pendingSince = clock(); observation = item; return
            }
            guard clock() - item.pendingSince >= 1.5, selection.length == 0 else { return }
            guard let correction = DictationCorrectionDetector.candidate(in: item.original, edited: edited) else { stop(); return }
            let candidate = DictationCorrectionCandidate(entryID: item.entryID, original: correction.original,
                corrected: correction.corrected, bundleID: item.bundleID, observedAt: Date(),
                requiresConfirmation: correction.requiresConfirmation)
            stop(); setAvailability(correction.requiresConfirmation ? .awaitingConfirmation : .learned); onCorrection?(candidate)
        }
    }

    private func setAvailability(_ value: DictationCorrectionAvailability) {
        guard availability != value else { return }
        availability = value; onAvailability?(value)
    }

    static func readField(pid: pid_t, element: AXUIElement) -> DictationCorrectionReadResult {
        guard AXIsProcessTrusted() else { return .unavailable }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.08)
        AXUIElementSetMessagingTimeout(element, 0.08)
        func isSameFocus() -> Bool {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
            var focused: CFTypeRef?
            return AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused) == .success
                && focused.map { CFEqual($0, element) } == true
        }
        guard isSameFocus() else { return .focusChanged }
        var subrole: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        guard subrole as? String != "AXSecureTextField" else { return .unavailable }
        // Require a bounded character count before reading any field content.
        var countValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &countValue) == .success,
              let count = (countValue as? NSNumber)?.intValue, count >= 0, count <= maximumFieldLength else { return .unavailable }
        var selectionValue: CFTypeRef?, selection = CFRange(location: 0, length: 0)
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selectionValue) == .success,
              let selectionValue, CFGetTypeID(selectionValue) == AXValueGetTypeID(),
              AXValueGetValue(selectionValue as! AXValue, .cfRange, &selection) else { return .unavailable }
        var requestedRange = CFRange(location: 0, length: count)
        guard let parameter = AXValueCreate(.cfRange, &requestedRange) else { return .unavailable }
        var textValue: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                       parameter, &textValue) != .success {
            guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &textValue) == .success else { return .unavailable }
        }
        guard let text = textValue as? String, text.utf16.count == count else { return .unavailable }
        guard isSameFocus() else { return .focusChanged }
        return .snapshot(DictationCorrectionSnapshot(text: text, selection: selection))
    }
}
