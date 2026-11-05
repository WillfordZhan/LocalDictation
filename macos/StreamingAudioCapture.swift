import AVFoundation
import Foundation

struct StreamingAudioMeterSnapshot {
    let elapsedSeconds: Double
    let averageDecibels: Double
    let peakDecibels: Double
    static let silence = StreamingAudioMeterSnapshot(elapsedSeconds: 0, averageDecibels: -160, peakDecibels: -160)
}

enum StreamingAudioError: LocalizedError {
    case invalidState, cancelled, invalidFormat, formatChanged, conversion(String), inputBacklog
    var errorDescription: String? {
        switch self {
        case .invalidState: return "录音状态已变化。"
        case .cancelled: return "本次口述已取消。"
        case .invalidFormat: return "麦克风没有提供有效音频格式。"
        case .formatChanged: return "录音设备或采样格式已变化，请重新录音。"
        case .conversion(let detail): return "无法处理麦克风音频：" + detail
        case .inputBacklog: return "音频处理未能及时跟上录音，本次口述已停止。"
        }
    }
}

/// Runs only on the capture worker. The same converter and WAV writer are used
/// by microphone capture and synthetic-PCM checks, including end-of-stream drain.
final class StreamingPCMEncoder {
    static let sampleRate = 16_000
    static let maximumSamples: Int64 = 300 * 16_000
    let url: URL
    private var file: FileHandle?
    private var sourceFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private(set) var totalSamples: Int64 = 0
    private(set) var meter = StreamingAudioMeterSnapshot.silence
    private var pending = Data()
    private var convertedPending = Data()
    private var inputFrames: Int64 = 0
    private var expectedSamples: Int64 = 0
    private var deliveredSamples: Int64 = 0
    private var finished = false
    var onPCM: ((Data, Int64) -> Void)?

    init(url: URL) throws {
        self.url = url
        guard FileManager.default.createFile(atPath: url.path, contents: Self.header(samples: 0), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        file = try FileHandle(forWritingTo: url)
        try file?.seekToEnd()
    }

    func append(_ input: AVAudioPCMBuffer) throws {
        guard !finished else { throw StreamingAudioError.invalidState }
        guard input.format.sampleRate > 0, input.format.channelCount > 0 else { throw StreamingAudioError.invalidFormat }
        guard input.frameLength > 0 else { return }
        if let sourceFormat {
            guard sourceFormat == input.format else { throw StreamingAudioError.formatChanged }
        } else {
            sourceFormat = input.format
            guard let made = AVAudioConverter(from: input.format, to: outputFormat) else { throw StreamingAudioError.invalidFormat }
            // No artificial leading padding: a new dictation owns a fresh converter.
            made.primeMethod = .none
            converter = made
        }
        inputFrames += Int64(input.frameLength)
        expectedSamples = min(Self.maximumSamples, Int64(floor(Double(inputFrames) * 16_000 / input.format.sampleRate)))
        var supplied = false
        try convert { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
    }

    private func convert(_ input: @escaping AVAudioConverterInputBlock) throws {
        guard let converter else { return }
        for _ in 0..<1024 {
            let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096)!
            var error: NSError?
            let status = converter.convert(to: output, error: &error, withInputFrom: input)
            if let error { throw StreamingAudioError.conversion(error.localizedDescription) }
            if output.frameLength > 0 { try consume(output) }
            switch status {
            case .inputRanDry, .endOfStream: return
            case .error: throw StreamingAudioError.conversion("采样转换失败。")
            case .haveData: continue
            @unknown default: throw StreamingAudioError.conversion("未知采样转换状态。")
            }
        }
        throw StreamingAudioError.conversion("采样转换没有结束。")
    }

    private func consume(_ output: AVAudioPCMBuffer) throws {
        guard totalSamples < Self.maximumSamples, let samples = output.int16ChannelData?[0] else { return }
        convertedPending.append(Data(bytes: samples, count: Int(output.frameLength) * MemoryLayout<Int16>.size))
        // CoreAudio may emit a fractional-frame lead or resampler tail padding.
        // Hold any lead for the next input, then discard only padding beyond the
        // exact source duration at EOF. Never drop a real sample between blocks.
        let count = min(Int64(convertedPending.count / 2), expectedSamples - totalSamples)
        guard count > 0 else { return }
        let data = Data(convertedPending.prefix(Int(count) * 2))
        convertedPending.removeFirst(Int(count) * 2)
        try file?.write(contentsOf: data)
        pending.append(data)
        totalSamples += count
        var squares = 0.0, peak = 0.0
        data.withUnsafeBytes { bytes in
            for index in 0..<Int(count) {
                let sample = bytes.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)
                let amplitude = abs(Double(sample)) / 32768.0
                squares += amplitude * amplitude; peak = max(peak, amplitude)
            }
        }
        func decibels(_ level: Double) -> Double { level > 0 ? max(-160, 20 * log10(level)) : -160 }
        meter = StreamingAudioMeterSnapshot(elapsedSeconds: Double(totalSamples) / 16_000,
            averageDecibels: decibels(sqrt(squares / Double(count))), peakDecibels: decibels(peak))
        // Half-second transport blocks keep the real-time audio callback separate
        // from network scheduling. Meter snapshots still update for each PCM buffer.
        while pending.count >= 16_000 {
            let block = Data(pending.prefix(16_000)); pending.removeFirst(16_000)
            onPCM?(block, deliveredSamples); deliveredSamples += 8_000
        }
    }

    @discardableResult func finish() throws -> Int64 {
        if finished { return totalSamples }
        try convert { _, status in status.pointee = .endOfStream; return nil }
        if !pending.isEmpty {
            onPCM?(pending, deliveredSamples); deliveredSamples += Int64(pending.count / 2); pending.removeAll()
        }
        try file?.seek(toOffset: 0)
        try file?.write(contentsOf: Self.header(samples: totalSamples))
        try file?.synchronize()
        try file?.close(); file = nil; finished = true; convertedPending.removeAll()
        return totalSamples
    }

    func cancel() {
        finished = true; pending.removeAll(); convertedPending.removeAll(); try? file?.close(); file = nil
        try? FileManager.default.removeItem(at: url)
    }

    deinit { try? file?.close() }

    private static func header(samples: Int64) -> Data {
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func number<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        let bytes = UInt32(samples * 2)
        text("RIFF"); number(UInt32(36) + bytes); text("WAVEfmt "); number(UInt32(16))
        number(UInt16(1)); number(UInt16(1)); number(UInt32(sampleRate)); number(UInt32(sampleRate * 2))
        number(UInt16(2)); number(UInt16(16)); text("data"); number(bytes)
        return data
    }
}

/// Main-thread control, serial PCM conversion/file IO, and thread-safe metering.
/// No HTTP or model work runs on the audio tap. The complete temporary WAV stays
/// available after stop; its owner removes it after successful delivery/fallback.
final class StreamingAudioCapture {
    let url: URL
    var onPCM: ((Data, Int64) -> Void)?
    var onFailure: ((String) -> Void)?
    private enum State { case idle, recording, stopping, stopped, failed, cancelled }
    private var state: State = .idle
    private let engine = AVAudioEngine()
    private let worker = DispatchQueue(label: "local-dictation.streaming-pcm", qos: .userInitiated)
    private let lock = NSLock()
    private var receiving = false
    private var pendingInputFrames: Int64 = 0
    private var snapshot = StreamingAudioMeterSnapshot.silence
    private var encoder: StreamingPCMEncoder?
    private var configurationObserver: NSObjectProtocol?
    private var tapInstalled = false
    private var stopCallbacks: [(Result<Int64, Error>) -> Void] = []
    private var stopResult: Result<Int64, Error>?

    init(url: URL) { self.url = url }

    var meterSnapshot: StreamingAudioMeterSnapshot {
        lock.lock(); defer { lock.unlock() }; return snapshot
    }

    func start() throws {
        precondition(Thread.isMainThread)
        guard state == .idle else { throw StreamingAudioError.invalidState }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw StreamingAudioError.invalidFormat }
        try prepareEncoder()
        input.installTap(onBus: 0, bufferSize: 256, format: format) { [weak self] buffer, _ in self?.accept(buffer) }
        tapInstalled = true
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self, self.state == .recording else { return }
            self.fail(StreamingAudioError.formatChanged)
        }
        do { engine.prepare(); try engine.start() }
        catch {
            closeInput(); state = .failed
            worker.sync { encoder?.cancel(); encoder = nil }
            throw error
        }
    }

    private func prepareEncoder() throws {
        try worker.sync {
            let encoder = try StreamingPCMEncoder(url: url)
            encoder.onPCM = { [weak self] data, offset in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.state == .recording || self.state == .stopping else { return }
                    self.onPCM?(data, offset)
                }
            }
            self.encoder = encoder
        }
        state = .recording
        lock.lock(); receiving = true; lock.unlock()
    }

    #if STREAMING_AUDIO_TESTS
    // Isolate hardware ownership only. Tests exercise the same buffer copy,
    // worker, converter, callbacks and drain/cancel paths as microphone capture.
    func startSyntheticInput() throws {
        precondition(Thread.isMainThread)
        guard state == .idle else { throw StreamingAudioError.invalidState }
        try prepareEncoder()
    }
    func appendSyntheticInput(_ buffer: AVAudioPCMBuffer) { accept(buffer) }
    #endif

    private func accept(_ input: AVAudioPCMBuffer) {
        lock.lock()
        guard receiving else { lock.unlock(); return }
        let frames = Int64(input.frameLength)
        guard frames > 0 else { lock.unlock(); return }
        guard pendingInputFrames + frames <= Int64(input.format.sampleRate * 4),
              let copy = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: input.frameLength) else {
            receiving = false; lock.unlock()
            DispatchQueue.main.async { [weak self] in self?.fail(StreamingAudioError.inputBacklog) }
            return
        }
        copy.frameLength = input.frameLength
        let source = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<source.count {
            guard let from = source[index].mData, let to = destination[index].mData else {
                receiving = false; lock.unlock()
                DispatchQueue.main.async { [weak self] in self?.fail(StreamingAudioError.invalidFormat) }
                return
            }
            memcpy(to, from, Int(source[index].mDataByteSize))
        }
        pendingInputFrames += frames
        // Enqueue under the same lock as closeInput. This establishes a precise
        // boundary: stop drains every accepted buffer before flushing the tail.
        worker.async { [weak self] in
            guard let self else { return }
            do {
                try self.encoder?.append(copy)
                self.lock.lock()
                self.pendingInputFrames -= frames
                if let encoder = self.encoder { self.snapshot = encoder.meter }
                self.lock.unlock()
            } catch {
                self.lock.lock(); self.pendingInputFrames -= frames; self.receiving = false; self.lock.unlock()
                DispatchQueue.main.async { [weak self] in self?.fail(error) }
            }
        }
        lock.unlock()
    }

    func stop(completion: @escaping (Result<Int64, Error>) -> Void) {
        precondition(Thread.isMainThread)
        if let stopResult { completion(stopResult); return }
        guard state == .recording || state == .stopping else { completion(.failure(StreamingAudioError.invalidState)); return }
        stopCallbacks.append(completion)
        guard state != .stopping else { return }
        state = .stopping; closeInput()
        worker.async { [self] in
            let result = Result { try self.encoder?.finish() ?? 0 }
            self.lock.lock()
            if let encoder = self.encoder { self.snapshot = encoder.meter }
            self.lock.unlock()
            DispatchQueue.main.async { [self] in
                guard self.state == .stopping else { return }
                self.state = .stopped; self.stopResult = result
                let callbacks = self.stopCallbacks; self.stopCallbacks.removeAll()
                callbacks.forEach { $0(result) }
            }
        }
    }

    func cancel() {
        precondition(Thread.isMainThread)
        guard state != .cancelled else { return }
        state = .cancelled; closeInput()
        worker.async { [self] in encoder?.cancel(); encoder = nil }
        let result: Result<Int64, Error> = .failure(StreamingAudioError.cancelled)
        stopResult = result
        let callbacks = stopCallbacks; stopCallbacks.removeAll(); callbacks.forEach { $0(result) }
    }

    private func fail(_ error: Error) {
        guard state == .recording || state == .stopping else { return }
        state = .failed; closeInput()
        worker.async { [self] in _ = try? encoder?.finish() }
        let result: Result<Int64, Error> = .failure(error)
        stopResult = result
        let callbacks = stopCallbacks; stopCallbacks.removeAll(); callbacks.forEach { $0(result) }
        onFailure?(error.localizedDescription)
    }

    private func closeInput() {
        lock.lock(); receiving = false; lock.unlock()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        engine.stop()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver); self.configurationObserver = nil }
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        engine.stop()
    }
}
