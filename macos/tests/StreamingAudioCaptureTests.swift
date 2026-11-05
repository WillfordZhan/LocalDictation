import AVFoundation
import Foundation

@main enum StreamingAudioCaptureChecks {
    static var checks = 0
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw NSError(domain: "StreamingAudioCaptureChecks", code: checks, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func main() {
        do { try run(); print("PASS: \(checks) streaming PCM checks (synthetic buffers; no microphone)") }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func pcm(rate: Double, channels: AVAudioChannelCount, start: Int, count: Int, amplitude: Float = 0.5) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        for channel in 0..<Int(channels) {
            for frame in 0..<count {
                buffer.floatChannelData![channel][frame] = amplitude * sin(Float(Double(start + frame) * 2 * .pi * 440 / rate))
            }
        }
        return buffer
    }
    static func run() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("streaming-pcm-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (rate, channels) in [(48_000.0, AVAudioChannelCount(2)), (44_100.0, 1), (16_000.0, 1)] {
            let url = directory.appendingPathComponent("\(Int(rate)).wav")
            let encoder = try StreamingPCMEncoder(url: url)
            var transmitted = Data(), expectedOffset: Int64 = 0
            encoder.onPCM = { data, offset in
                precondition(offset == expectedOffset, "Skipped/repeated PCM offset")
                transmitted.append(data); expectedOffset += Int64(data.count / 2)
            }
            let frames = Int(rate * 2.317)
            var start = 0
            while start < frames {
                let count = min(257, frames - start)
                try encoder.append(pcm(rate: rate, channels: channels, start: start, count: count))
                start += count
            }
            let total = try encoder.finish()
            let expected = Double(frames) * 16_000 / rate
            print("rate=\(rate) output=\(total) expected=\(expected)")
            try require(abs(Double(total) - expected) <= 1, "Resampling lost or invented audio duration")
            try require(expectedOffset == total, "Tail was not delivered")
            try require(transmitted.count == Int(total) * 2, "Incorrect PCM byte count")
            let unsplit = try StreamingPCMEncoder(url: directory.appendingPathComponent("whole-\(Int(rate)).wav"))
            var unsplitData = Data()
            unsplit.onPCM = { data, _ in unsplitData.append(data) }
            try unsplit.append(pcm(rate: rate, channels: channels, start: 0, count: frames))
            _ = try unsplit.finish()
            try require(unsplitData == transmitted, "Changing input buffer boundaries altered PCM or repeated samples")
            let wav = try Data(contentsOf: url)
            try require(Data(wav.dropFirst(44)) == transmitted, "Stream differs from complete WAV")
            let file = try AVAudioFile(forReading: url)
            try require(file.length == total && file.fileFormat.sampleRate == 16_000 && file.fileFormat.channelCount == 1, "Invalid complete WAV")
            let firstFinish = transmitted.count
            let finishedAgain = try encoder.finish()
            try require(finishedAgain == total, "Finish is not idempotent")
            try require(transmitted.count == firstFinish, "Duplicate finish redelivered tail")
            try require(encoder.meter.averageDecibels > -20 && encoder.meter.peakDecibels > -12, "Voiced meter did not respond")
        }
        let meter = try StreamingPCMEncoder(url: directory.appendingPathComponent("meter.wav"))
        try meter.append(pcm(rate: 16_000, channels: 1, start: 0, count: 512, amplitude: 0.75))
        try require(meter.meter.peakDecibels > -4, "Loud sample did not respond")
        try meter.append(pcm(rate: 16_000, channels: 1, start: 512, count: 512, amplitude: 0))
        try require(meter.meter.averageDecibels == -160 && meter.meter.peakDecibels == -160, "Silence meter has an artificial decay")
        let cancelledURL = meter.url
        meter.cancel()
        try require(!FileManager.default.fileExists(atPath: cancelledURL.path), "Cancel retained audio")
        let empty = try StreamingPCMEncoder(url: directory.appendingPathComponent("empty.wav"))
        let emptyTotal = try empty.finish()
        let emptyData = try Data(contentsOf: empty.url)
        try require(emptyTotal == 0 && emptyData.count == 44, "Empty capture failed")
        let changed = try StreamingPCMEncoder(url: directory.appendingPathComponent("changed.wav"))
        try changed.append(pcm(rate: 48_000, channels: 2, start: 0, count: 512))
        do {
            try changed.append(pcm(rate: 44_100, channels: 1, start: 0, count: 512))
            throw NSError(domain: "Expected format failure", code: 1)
        } catch StreamingAudioError.formatChanged { try require(true, "Format change rejected") }
        changed.cancel()
        #if STREAMING_AUDIO_TESTS
        var capture: StreamingAudioCapture? = StreamingAudioCapture(url: directory.appendingPathComponent("released-stop.wav"))
        let stoppedURL = capture!.url
        var stopped: Result<Int64, Error>?, delivered = Data(), offset: Int64 = 0
        capture?.onPCM = { data, position in
            precondition(Thread.isMainThread && position == offset)
            delivered.append(data); offset += Int64(data.count / 2)
        }
        try capture?.startSyntheticInput()
        let emptyTick = pcm(rate: 48_000, channels: 2, start: 0, count: 1)
        emptyTick.frameLength = 0
        capture?.appendSyntheticInput(emptyTick)
        capture?.appendSyntheticInput(pcm(rate: 48_000, channels: 2, start: 0, count: 24_321))
        capture?.stop { result in precondition(Thread.isMainThread); stopped = result }
        capture = nil
        let deadline = Date().addingTimeInterval(4)
        while stopped == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        try require(stopped != nil, "Releasing capture dropped stop completion")
        let total = try stopped!.get()
        let stoppedData = try Data(contentsOf: stoppedURL)
        try require(total == 8107 && delivered.count == 16214, "Released capture omitted queued input/tail")
        try require(Data(stoppedData.dropFirst(44)) == delivered, "Stop completed before WAV drain")
        var cancelledCapture: StreamingAudioCapture? = StreamingAudioCapture(url: directory.appendingPathComponent("released-cancel.wav"))
        let cancelledPath = cancelledCapture!.url.path
        try cancelledCapture?.startSyntheticInput()
        cancelledCapture?.appendSyntheticInput(pcm(rate: 48_000, channels: 2, start: 0, count: 48_000))
        cancelledCapture?.cancel(); cancelledCapture = nil
        let cancelDeadline = Date().addingTimeInterval(4)
        while FileManager.default.fileExists(atPath: cancelledPath) && Date() < cancelDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        try require(!FileManager.default.fileExists(atPath: cancelledPath), "Releasing capture dropped cancellation cleanup")
        var interrupted: StreamingAudioCapture? = StreamingAudioCapture(url: directory.appendingPathComponent("interrupted-stop.wav"))
        let interruptedPath = interrupted!.url.path
        var interruptionResults = 0, interruptionSuccess = false, latePCM = false
        var cancelledAlready = false
        interrupted?.onPCM = { _, _ in if cancelledAlready { latePCM = true } }
        try interrupted?.startSyntheticInput()
        interrupted?.appendSyntheticInput(pcm(rate: 48_000, channels: 2, start: 0, count: 96_000))
        interrupted?.stop { result in
            interruptionResults += 1
            if case .success = result { interruptionSuccess = true }
        }
        interrupted?.cancel(); cancelledAlready = true; interrupted = nil
        let interruptedDeadline = Date().addingTimeInterval(4)
        while FileManager.default.fileExists(atPath: interruptedPath) && Date() < interruptedDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        try require(interruptionResults == 1 && !interruptionSuccess, "Cancel during drain delivered success or duplicate completion")
        try require(!latePCM && !FileManager.default.fileExists(atPath: interruptedPath), "Cancel during drain retained audio or delivered late PCM")
        #endif
    }
}
