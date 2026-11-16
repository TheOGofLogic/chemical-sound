import AVFAudio
import Foundation

/// Serial, lock-synchronized lossless Float32 WAV writer preventing tap buffer race conditions.
public final class RecordingController: @unchecked Sendable {
    private let lock = NSLock()
    private var recordingFile: AVAudioFile?
    private var monoTargetFormat: AVAudioFormat?
    private var capturedFrames: AVAudioFramePosition = 0
    private var writeFailure: Error?

    public init() {}

    public func prepare(destinationURL: URL, sampleRateHz: Double) throws {
        lock.lock()
        defer { lock.unlock() }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRateHz,
            channels: 1,
            interleaved: false
        ) else {
            throw AcquisitionFailure.audioEngineFailure("Unable to construct 48 kHz Float32 mono format.")
        }

        let wavSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRateHz,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        do {
            self.recordingFile = try AVAudioFile(
                forWriting: destinationURL,
                settings: wavSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            self.monoTargetFormat = format
            self.capturedFrames = 0
            self.writeFailure = nil
        } catch {
            throw AcquisitionFailure.fileWriteFailure("Cannot open WAV for writing: \(error)")
        }
    }

    /// Called synchronously on the AVAudioNode tap queue; writes channel 0 into a copied mono buffer.
    public func appendTapBuffer(_ incomingBuffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }

        guard writeFailure == nil,
              let file = recordingFile,
              let monoFormat = monoTargetFormat,
              incomingBuffer.frameLength > 0,
              let srcChannel0 = incomingBuffer.floatChannelData?[0] else {
            return
        }

        guard let copyBuffer = AVAudioPCMBuffer(
            pcmFormat: monoFormat,
            frameCapacity: incomingBuffer.frameLength
        ), let dstChannel0 = copyBuffer.floatChannelData?[0] else {
            writeFailure = AcquisitionFailure.fileWriteFailure("Failed allocating mono PCM copy buffer.")
            return
        }

        copyBuffer.frameLength = incomingBuffer.frameLength
        dstChannel0.update(from: srcChannel0, count: Int(incomingBuffer.frameLength))

        do {
            try file.write(from: copyBuffer)
            capturedFrames += AVAudioFramePosition(copyBuffer.frameLength)
        } catch {
            writeFailure = error
        }
    }

    public func finishAndClose() throws -> AVAudioFramePosition {
        lock.lock()
        defer { lock.unlock() }

        recordingFile = nil
        let total = capturedFrames
        if let err = writeFailure {
            writeFailure = nil
            throw AcquisitionFailure.fileWriteFailure("Audio tap write error: \(err)")
        }
        return total
    }

    public func currentCapturedFrames() -> AVAudioFramePosition {
        lock.lock()
        defer { lock.unlock() }
        return capturedFrames
    }
}
