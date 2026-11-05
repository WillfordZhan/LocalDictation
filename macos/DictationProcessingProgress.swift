import Foundation

/// A visual estimate, not token-level model telemetry. Each utterance owns its
/// clock so queued work cannot consume another utterance's progress budget.
struct DictationProcessingProgress {
    struct Sample {
        let characterCount: Int
        let cleanupSeconds: Double
    }

    private let secondsPerCharacter: Double
    private let cleanupEnabled: Bool
    private var backendState = "queued"
    private var characterCount = 0
    private var audioSeconds = 0.0
    private var recognizedSeconds = 0.0
    private var lastTick: TimeInterval?
    private var recognitionElapsed = 0.0
    private var cleanupElapsed = 0.0
    private(set) var value = 0.0

    init(samples: [Sample] = [], cleanupEnabled: Bool = true) {
        self.cleanupEnabled = cleanupEnabled
        // Ignore failed/invalid measurements; warm-up and occasional stalls
        // should not dictate all future animations. No transcript is retained.
        let rates = samples.filter { $0.characterCount > 0 && $0.cleanupSeconds.isFinite && $0.cleanupSeconds > 0 }
            .prefix(16).map { max(0.003, ($0.cleanupSeconds - 1.5) / Double($0.characterCount)) }.sorted()
        secondsPerCharacter = rates.isEmpty ? 1.0 / 50.0 : min(0.25, rates[rates.count / 2])
    }

    var estimatedCleanupSeconds: Double {
        let count = characterCount > 0 ? Double(characterCount) : audioSeconds * 3
        return max(2, 1.5 + count * secondsPerCharacter)
    }

    mutating func observe(state: String, characters: Int, audioSeconds: Double,
                          recognizedSeconds: Double, now: TimeInterval) {
        _ = advance(now: now)
        backendState = state
        characterCount = max(0, characters)
        self.audioSeconds = audioSeconds.isFinite ? max(0, audioSeconds) : 0
        self.recognizedSeconds = recognizedSeconds.isFinite ? max(0, recognizedSeconds) : 0
    }

    mutating func advance(now: TimeInterval) -> Double {
        guard now.isFinite else { return value }
        let elapsed = max(0, now - (lastTick ?? now)); lastTick = now
        if backendState == "transcribing" { recognitionElapsed += elapsed }
        if backendState == "editing" { cleanupElapsed += elapsed }
        let fraction = audioSeconds > 0 ? min(1, recognizedSeconds / audioSeconds) : 0
        let tailEstimate = max(1, (audioSeconds - recognizedSeconds) * 0.10)
        let tail = backendState == "transcribing" ? curve(recognitionElapsed / tailEstimate) : 0
        var candidate = 0.04 + 0.24 * max(fraction, tail)
        if backendState == "editing" {
            candidate = 0.28 + 0.71 * curve(cleanupElapsed / estimatedCleanupSeconds)
        } else if !cleanupEnabled {
            candidate = 0.04 + 0.93 * max(fraction, tail)
        }
        // A longer late ASR snapshot may revise the estimate. Never move the
        // fill backwards, and never announce completion before a valid result.
        value = max(value, min(0.99, candidate))
        return value
    }

    private func curve(_ time: Double) -> Double { min(1, 1 - exp(-2.12 * max(0, time))) }
}
