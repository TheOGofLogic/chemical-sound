import AVFAudio
import Foundation

public struct ImmediateAudioMetrics: Sendable, Equatable {
    public let sampleRateHz: Double
    public let channelCount: Int
    public let totalFrames: Int
    public let hasNonFiniteValues: Bool
    public let clippedSampleCount: Int
    public let peakDBFS: Double
    public let preRollRMSDBFS: Double
    public let activeRMSDBFS: Double
}

public struct ImmediateAudioAnalyzer: Sendable {
    public init() {}

    public func analyze(
        recordingURL: URL,
        preRollFrames: Int,
        activeFrames: Int,
        clippingCeilingDBFS: Double
    ) throws -> ImmediateAudioMetrics {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: recordingURL)
        } catch {
            throw AcquisitionFailure.fileWriteFailure("Cannot read recorded WAV: \(error)")
        }

        let format = file.processingFormat
        let totalFrames = Int(file.length)
        guard totalFrames > 0,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(totalFrames)
              ) else {
            throw AcquisitionFailure.fileWriteFailure("Empty or unreadable PCM recording.")
        }

        do {
            try file.read(into: buffer)
        } catch {
            throw AcquisitionFailure.fileWriteFailure("Failed reading PCM frames: \(error)")
        }

        guard let chan0 = buffer.floatChannelData?[0] else {
            throw AcquisitionFailure.fileWriteFailure("Missing Float32 channel data.")
        }

        let n = Int(buffer.frameLength)
        let clipThreshold = pow(10.0, clippingCeilingDBFS / 20.0)
        var hasNonFinite = false
        var clippedCount = 0
        var peakLinear = 0.0

        for i in 0..<n {
            let v = Double(chan0[i])
            if !v.isFinite {
                hasNonFinite = true
                continue
            }
            let a = abs(v)
            if a > peakLinear { peakLinear = a }
            if a >= clipThreshold { clippedCount += 1 }
        }

        let preEnd = max(1, min(n, preRollFrames))
        let preRMS = Self.dcRemovedRMS(pointer: chan0, start: 0, end: preEnd)

        let actStart = min(n, preRollFrames)
        let actEnd = min(n, preRollFrames + max(1, activeFrames))
        let actRMS = actEnd > actStart
            ? Self.dcRemovedRMS(pointer: chan0, start: actStart, end: actEnd)
            : 0.0

        return ImmediateAudioMetrics(
            sampleRateHz: format.sampleRate,
            channelCount: Int(format.channelCount),
            totalFrames: n,
            hasNonFiniteValues: hasNonFinite,
            clippedSampleCount: clippedCount,
            peakDBFS: Self.linearToDBFS(peakLinear),
            preRollRMSDBFS: Self.linearToDBFS(preRMS),
            activeRMSDBFS: Self.linearToDBFS(actRMS)
        )
    }

    public static func linearToDBFS(_ value: Double, floorDB: Double = -120.0) -> Double {
        guard value > 0.0 else { return floorDB }
        return max(floorDB, 20.0 * log10(value))
    }

    private static func dcRemovedRMS(
        pointer: UnsafeMutablePointer<Float>,
        start: Int,
        end: Int
    ) -> Double {
        let count = end - start
        guard count > 0 else { return 0.0 }
        var sum = 0.0
        for i in start..<end {
            let v = Double(pointer[i])
            if v.isFinite { sum += v }
        }
        let mean = sum / Double(count)
        var sqSum = 0.0
        for i in start..<end {
            let v = Double(pointer[i])
            if v.isFinite {
                let d = v - mean
                sqSum += d * d
            }
        }
        return sqrt(sqSum / Double(count))
    }
}
