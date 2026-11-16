import AVFAudio
import Foundation

public struct PlaybackTimestamps: Sendable, Equatable {
    public let startUptimeSeconds: Double
    public let endUptimeSeconds: Double
}

public final class PlaybackController: @unchecked Sendable {
    public let playerNode = AVAudioPlayerNode()

    public init() {}

    public func playAndAwaitCompletion(waveform: AVAudioFile) async -> PlaybackTimestamps {
        let startUptime = ProcessInfo.processInfo.systemUptime
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            playerNode.scheduleFile(
                waveform,
                at: nil,
                completionCallbackType: .dataPlayedBack
            ) { _ in
                continuation.resume()
            }
            playerNode.play()
        }
        let endUptime = ProcessInfo.processInfo.systemUptime
        return PlaybackTimestamps(
            startUptimeSeconds: startUptime,
            endUptimeSeconds: endUptime
        )
    }

    public func stop() {
        playerNode.stop()
    }
}
