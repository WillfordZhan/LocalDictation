import Foundation

@main
struct DictationProcessingProgressTests {
    static func main() {
        let samples = [DictationProcessingProgress.Sample(characterCount: 100, cleanupSeconds: 3.5)]
        var short = DictationProcessingProgress(samples: samples)
        var long = DictationProcessingProgress(samples: samples)
        short.observe(state: "editing", characters: 100, audioSeconds: 30, recognizedSeconds: 30, now: 0)
        long.observe(state: "editing", characters: 1000, audioSeconds: 300, recognizedSeconds: 300, now: 0)
        precondition(short.estimatedCleanupSeconds < long.estimatedCleanupSeconds)
        precondition(short.advance(now: 2) > long.advance(now: 2), "Longer text must have a longer progress budget")
        var previous = long.value
        for index in 3...1000 {
            let value = long.advance(now: Double(index))
            precondition(value >= previous && value < 1)
            previous = value
        }
        var queued = DictationProcessingProgress()
        queued.observe(state: "queued", characters: 50, audioSeconds: 30, recognizedSeconds: 10, now: 0)
        let initial = queued.advance(now: 0)
        precondition(queued.advance(now: 500) == initial, "Queued time cannot consume processing progress")
        queued.observe(state: "transcribing", characters: 50, audioSeconds: 30, recognizedSeconds: 10, now: 500)
        precondition(queued.advance(now: 500.2) < 0.3, "Queue wait leaked into active clock")
        queued.observe(state: "editing", characters: 80, audioSeconds: 30, recognizedSeconds: 30, now: 501)
        let partial = queued.advance(now: 502)
        queued.observe(state: "editing", characters: 2000, audioSeconds: 30, recognizedSeconds: 30, now: 502)
        precondition(queued.advance(now: 502.1) >= partial, "A revised ETA cannot reverse the fill")
        var paused = queued
        paused.observe(state: "queued", characters: 2000, audioSeconds: 30, recognizedSeconds: 30, now: 503)
        let pausedValue = paused.value
        precondition(paused.advance(now: 900) == pausedValue)
        let invalid = DictationProcessingProgress(samples: [.init(characterCount: 0, cleanupSeconds: 4),
            .init(characterCount: 100, cleanupSeconds: .nan), .init(characterCount: 100, cleanupSeconds: -1)])
        precondition(invalid.estimatedCleanupSeconds.isFinite)
        var withoutCleanup = DictationProcessingProgress(cleanupEnabled: false)
        withoutCleanup.observe(state: "transcribing", characters: 20, audioSeconds: 10, recognizedSeconds: 10, now: 0)
        precondition(withoutCleanup.advance(now: 100) < 1)
        precondition(withoutCleanup.advance(now: .nan).isFinite)
        print("PASS processing progress: per-job clocks, text-length estimate, history calibration, monotonic fill, queue pause, no premature completion")
    }
}
