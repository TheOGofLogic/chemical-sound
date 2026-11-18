import AVFAudio
import Combine
import Foundation

/// Synthesizes a musical audio representation ("Chemical Tune") from a defined constituent-to-pitch
/// mapping modulated by the scan's measured acoustic resonance characteristics.
public struct ChemicalTuneSynthesizer: Sendable {
    public let sampleRateHz: Double
    public let durationSeconds: Double

    public init(sampleRateHz: Double = 48_000.0, durationSeconds: Double = 6.0) {
        self.sampleRateHz = sampleRateHz
        self.durationSeconds = durationSeconds
    }

    public func synthesizeSamples(for item: ConsumerScanItem) -> [Float] {
        let totalFrames = max(1, Int(round(sampleRateHz * durationSeconds)))
        var buffer = [Double](repeating: 0.0, count: totalFrames)

        let freqs = item.tuneProfile.baseFrequenciesHz.isEmpty
            ? [392.00, 493.88, 587.33, 783.99]
            : item.tuneProfile.baseFrequenciesHz

        let shimmer = max(0.65, min(1.40, item.tuneProfile.shimmerMultiplier))
        let decayRate = max(1.0, min(3.0, item.tuneProfile.warmthDecayPerSec))
        let resonanceDetune = ((item.measuredPeakHz.truncatingRemainder(dividingBy: 500.0)) - 250.0) * 0.00004

        // 1. Warm sustained harmonic chord bed
        for (voiceIdx, baseFreq) in freqs.prefix(4).enumerated() {
            let f = baseFreq * (1.0 + resonanceDetune * Double(voiceIdx))
            let amp = 0.11 / Double(1 + voiceIdx / 2)
            for n in 0..<totalFrames {
                let t = Double(n) / sampleRateHz
                let slowLFO = 0.85 + 0.15 * sin(2.0 * Double.pi * (0.35 + 0.08 * Double(voiceIdx)) * t)
                let fundamental = sin(2.0 * Double.pi * f * t)
                let secondHarm = 0.25 * shimmer * sin(2.0 * Double.pi * (2.0 * f) * t)
                buffer[n] += amp * slowLFO * (fundamental + secondHarm)
            }
        }

        // 2. Crystalline arpeggiated signature motif (8 gentle bell notes across the 6 s phrase)
        let noteCount = 8
        let stepSpacing = (durationSeconds - 0.8) / Double(noteCount)
        for step in 0..<noteCount {
            let fNote = freqs[step % freqs.count] * (step >= freqs.count ? 1.0 : 1.0)
            let noteStartSec = 0.18 + Double(step) * stepSpacing
            let startFrame = max(0, Int(round(noteStartSec * sampleRateHz)))
            let noteLenFrames = min(totalFrames - startFrame, Int(round(1.65 * sampleRateHz)))
            guard noteLenFrames > 64 else { continue }

            let attackFrames = max(32, Int(round(0.018 * sampleRateHz)))
            for k in 0..<noteLenFrames {
                let dt = Double(k) / sampleRateHz
                let attackEnv = k < attackFrames
                    ? 0.5 * (1.0 - cos(Double.pi * Double(k) / Double(attackFrames)))
                    : 1.0
                let decayEnv = exp(-decayRate * dt)
                let releaseTail = k > (noteLenFrames - 960)
                    ? Double(noteLenFrames - k) / 960.0
                    : 1.0
                let env = attackEnv * decayEnv * max(0.0, releaseTail)

                let s1 = sin(2.0 * Double.pi * fNote * dt)
                let s2 = 0.32 * shimmer * sin(2.0 * Double.pi * (2.0 * fNote) * dt)
                let s3 = 0.10 * shimmer * sin(2.0 * Double.pi * (3.0 * fNote) * dt)
                buffer[startFrame + k] += 0.22 * env * (s1 + s2 + s3)
            }
        }

        // 3. Smooth global fade-in (40 ms) & fade-out (280 ms) + -3 dBFS peak normalization
        let fadeIn = min(totalFrames / 4, Int(round(0.040 * sampleRateHz)))
        let fadeOut = min(totalFrames / 3, Int(round(0.280 * sampleRateHz)))
        for i in 0..<fadeIn {
            let w = 0.5 * (1.0 - cos(Double.pi * Double(i) / Double(max(1, fadeIn))))
            buffer[i] *= w
        }
        for i in 0..<fadeOut {
            let w = 0.5 * (1.0 - cos(Double.pi * Double(i) / Double(max(1, fadeOut))))
            buffer[totalFrames - 1 - i] *= w
        }

        var peak = 1e-9
        for v in buffer where abs(v) > peak { peak = abs(v) }
        let targetPeak = pow(10.0, -3.0 / 20.0) // ~0.7079 (-3 dBFS)
        let gain = targetPeak / peak

        return buffer.map { Float($0 * gain) }
    }

    public func writeTemporaryWAV(for item: ConsumerScanItem) throws -> URL {
        let samples = synthesizeSamples(for: item)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiquidAnalyzer_Tune_\(item.id.uuidString).wav")

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRateHz,
            channels: 1,
            interleaved: false
        ),
        let pcmBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw AcquisitionFailure.fileWriteFailure("Unable to allocate Chemical Tune audio buffer.")
        }

        pcmBuffer.frameLength = AVAudioFrameCount(samples.count)
        if let channelPtr = pcmBuffer.floatChannelData?[0] {
            for i in 0..<samples.count {
                channelPtr[i] = samples[i]
            }
        }

        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: pcmBuffer)
        return url
    }
}

/// Playback controller driving the Chemical Tune screen's Play / Pause & scrubber UI.
@MainActor
public final class ChemicalTunePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published public private(set) var isPlaying: Bool = false
    @Published public var progress: Double = 0.0
    @Published public private(set) var durationSeconds: Double = 6.0

    private let synthesizer = ChemicalTuneSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    private var preparedItemID: UUID?
    private var preparedURL: URL?
    private var timer: Timer?

    public override init() {
        super.init()
    }

    public func prepareIfNeeded(for item: ConsumerScanItem) {
        guard preparedItemID != item.id else { return }
        stop()
        do {
            let wavURL = try synthesizer.writeTemporaryWAV(for: item)
            preparedURL = wavURL
            preparedItemID = item.id
            let player = try AVAudioPlayer(contentsOf: wavURL)
            player.delegate = self
            player.prepareToPlay()
            audioPlayer = player
            durationSeconds = max(0.5, player.duration)
            progress = 0.0
        } catch {
            audioPlayer = nil
        }
    }

    public func togglePlayPause(for item: ConsumerScanItem) {
        prepareIfNeeded(for: item)
        guard let player = audioPlayer else { return }

        if player.isPlaying {
            player.pause()
            isPlaying = false
            stopTimer()
        } else {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default, options: [])
            try? session.setActive(true)
            #endif

            if player.currentTime >= player.duration - 0.05 {
                player.currentTime = 0.0
                progress = 0.0
            }
            player.play()
            isPlaying = true
            startTimer()
        }
    }

    public func seek(to normalizedProgress: Double, for item: ConsumerScanItem) {
        prepareIfNeeded(for: item)
        let clamped = max(0.0, min(1.0, normalizedProgress))
        progress = clamped
        if let player = audioPlayer {
            player.currentTime = clamped * player.duration
        }
    }

    public func stop() {
        stopTimer()
        audioPlayer?.stop()
        isPlaying = false
        progress = 0.0
    }

    nonisolated public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.stopTimer()
            self.isPlaying = false
            self.progress = 1.0
        }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let player = self.audioPlayer, player.duration > 0 else { return }
                if player.isPlaying {
                    self.progress = max(0.0, min(1.0, player.currentTime / player.duration))
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
