import AVFAudio
import Foundation

public actor AudioAcquisitionEngine {
    private var engine: AVAudioEngine?
    private var playback: PlaybackController?
    private let recorder = RecordingController()
    private var tapInstalled = false

    public init() {}

    @discardableResult
    public func prepare(
        waveform: AVAudioFile,
        destinationURL: URL,
        expectedSampleRateHz: Double,
        enforceExactSampleRate: Bool = true
    ) throws -> Double {
        abortImmediately()

        let newEngine = AVAudioEngine()
        let newPlayback = PlaybackController()
        newEngine.attach(newPlayback.playerNode)

        let input = newEngine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let actualRate = inputFormat.sampleRate > 0 ? inputFormat.sampleRate : expectedSampleRateHz

        if enforceExactSampleRate {
            guard abs(actualRate - expectedSampleRateHz) < 0.5 else {
                throw AcquisitionFailure.sampleRateMismatch(
                    expected: expectedSampleRateHz,
                    actual: actualRate
                )
            }
        }

        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw AcquisitionFailure.audioEngineFailure(
                "Microphone hardware format not ready (\(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) ch)."
            )
        }

        newEngine.connect(
            newPlayback.playerNode,
            to: newEngine.mainMixerNode,
            format: waveform.processingFormat
        )
        newEngine.connect(
            newEngine.mainMixerNode,
            to: newEngine.outputNode,
            format: nil
        )

        try recorder.prepare(
            destinationURL: destinationURL,
            sampleRateHz: actualRate
        )

        let recorderRef = recorder
        input.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: nil
        ) { buffer, _ in
            recorderRef.appendTapBuffer(buffer)
        }
        tapInstalled = true
        newEngine.prepare()

        self.engine = newEngine
        self.playback = newPlayback
        return actualRate
    }

    /// Starts a single continuous measurement `AVAudioEngine` for a multi-scan R1 batch so CoreAudio
    /// never re-triggers ADC startup pops or route renegotiation between repeated sweeps.
    @discardableResult
    public func startWarmBatchEngine(
        waveform: AVAudioFile,
        expectedSampleRateHz: Double
    ) throws -> Double {
        abortImmediately()

        let newEngine = AVAudioEngine()
        let newPlayback = PlaybackController()
        newEngine.attach(newPlayback.playerNode)

        let input = newEngine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let actualRate = inputFormat.sampleRate > 0 ? inputFormat.sampleRate : expectedSampleRateHz

        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw AcquisitionFailure.audioEngineFailure(
                "Microphone hardware format not ready (\(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) ch)."
            )
        }

        newEngine.connect(
            newPlayback.playerNode,
            to: newEngine.mainMixerNode,
            format: waveform.processingFormat
        )
        newEngine.connect(
            newEngine.mainMixerNode,
            to: newEngine.outputNode,
            format: nil
        )

        let recorderRef = recorder
        input.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: nil
        ) { buffer, _ in
            recorderRef.appendTapBuffer(buffer)
        }
        tapInstalled = true
        newEngine.prepare()

        do {
            try newEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            throw AcquisitionFailure.audioEngineFailure("AVAudioEngine failed to start warm batch: \(error)")
        }

        self.engine = newEngine
        self.playback = newPlayback
        return actualRate
    }

    /// Opens a lossless Float32 WAV capture window on the already-running warm `AVAudioEngine`.
    public func openSweepRecording(destinationURL: URL, sampleRateHz: Double) throws {
        guard engine != nil else {
            throw AcquisitionFailure.audioEngineFailure("Warm AVAudioEngine is not running.")
        }
        try recorder.prepare(destinationURL: destinationURL, sampleRateHz: sampleRateHz)
    }

    /// Flushes and closes the current sweep WAV without stopping the warm `AVAudioEngine`.
    @discardableResult
    public func closeSweepRecording() throws -> AVAudioFramePosition {
        playback?.stop()
        return try recorder.finishAndClose()
    }

    public func start() throws {
        guard let engine else {
            throw AcquisitionFailure.audioEngineFailure("AVAudioEngine was not prepared before start().")
        }
        do {
            try engine.start()
        } catch {
            throw AcquisitionFailure.audioEngineFailure("AVAudioEngine failed to start: \(error)")
        }
    }

    public func playExcitation(waveform: AVAudioFile) async -> PlaybackTimestamps {
        guard let playback else {
            let now = ProcessInfo.processInfo.systemUptime
            return PlaybackTimestamps(startUptimeSeconds: now, endUptimeSeconds: now)
        }
        return await playback.playAndAwaitCompletion(waveform: waveform)
    }

    @discardableResult
    public func stopAndFinalizeRecording() throws -> AVAudioFramePosition {
        playback?.stop()
        if tapInstalled, let engine {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine?.stop()
        engine = nil
        playback = nil
        return try recorder.finishAndClose()
    }

    public func abortImmediately() {
        playback?.stop()
        if tapInstalled, let engine {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine?.stop()
        engine = nil
        playback = nil
        _ = try? recorder.finishAndClose()
    }

    public func capturedFrameCount() -> AVAudioFramePosition {
        recorder.currentCapturedFrames()
    }
}
