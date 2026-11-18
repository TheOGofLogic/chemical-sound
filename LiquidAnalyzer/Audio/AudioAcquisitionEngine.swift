import AVFAudio
import Foundation

public actor AudioAcquisitionEngine {
    private let engine = AVAudioEngine()
    private let playback = PlaybackController()
    private let recorder = RecordingController()
    private var tapInstalled = false

    public init() {
        engine.attach(playback.playerNode)
    }

    public func prepare(
        waveform: AVAudioFile,
        destinationURL: URL,
        expectedSampleRateHz: Double
    ) throws {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let outputFormat = engine.outputNode.inputFormat(forBus: 0)

        guard abs(inputFormat.sampleRate - expectedSampleRateHz) < 0.5 else {
            throw AcquisitionFailure.sampleRateMismatch(
                expected: expectedSampleRateHz,
                actual: inputFormat.sampleRate
            )
        }

        engine.connect(
            playback.playerNode,
            to: engine.mainMixerNode,
            format: waveform.processingFormat
        )
        engine.connect(
            engine.mainMixerNode,
            to: engine.outputNode,
            format: nil
        )

        try recorder.prepare(
            destinationURL: destinationURL,
            sampleRateHz: expectedSampleRateHz
        )

        let recorderRef = recorder
        input.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: inputFormat
        ) { buffer, _ in
            recorderRef.appendTapBuffer(buffer)
        }
        tapInstalled = true
        engine.prepare()
    }

    public func start() throws {
        do {
            try engine.start()
        } catch {
            throw AcquisitionFailure.audioEngineFailure("AVAudioEngine failed to start: \(error)")
        }
    }

    public func playExcitation(waveform: AVAudioFile) async -> PlaybackTimestamps {
        await playback.playAndAwaitCompletion(waveform: waveform)
    }

    @discardableResult
    public func stopAndFinalizeRecording() throws -> AVAudioFramePosition {
        playback.stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        return try recorder.finishAndClose()
    }

    public func abortImmediately() {
        playback.stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        _ = try? recorder.finishAndClose()
    }

    public func capturedFrameCount() -> AVAudioFramePosition {
        recorder.currentCapturedFrames()
    }
}
