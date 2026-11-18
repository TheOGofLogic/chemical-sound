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
