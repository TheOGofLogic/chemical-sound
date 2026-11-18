import AVFAudio
import Foundation

public struct PlaybackTimestamps: Sendable, Equatable {
    public let startUptimeSeconds: Double
    public let endUptimeSeconds: Double
}

private final class OneShotGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private var continuation: CheckedContinuation<Void, Never>?

    func install(_ cont: CheckedContinuation<Void, Never>) {
        lock.lock()
        if resumed {
            lock.unlock()
            cont.resume()
        } else {
            continuation = cont
            lock.unlock()
        }
    }

    func fire() {
        lock.lock()
        guard !resumed else {
            lock.unlock()
            return
        }
        resumed = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume()
    }
}

public final class PlaybackController: @unchecked Sendable {
    public let playerNode = AVAudioPlayerNode()

    public init() {}

    public func playAndAwaitCompletion(waveform: AVAudioFile) async -> PlaybackTimestamps {
        let startUptime = ProcessInfo.processInfo.systemUptime
        let sr = max(8_000.0, waveform.processingFormat.sampleRate)
        let durationSec = Double(waveform.length) / sr
        let timeoutMs = Int((durationSec + 1.2) * 1_000.0)

        let gate = OneShotGate()
        let watchdog = Task {
            try? await Task.sleep(for: .milliseconds(max(400, timeoutMs)))
            gate.fire()
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            gate.install(continuation)
            playerNode.scheduleFile(
                waveform,
                at: nil,
                completionCallbackType: .dataPlayedBack
            ) { _ in
                gate.fire()
            }
            playerNode.volume = 1.0
            playerNode.play()
        }

        watchdog.cancel()
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
