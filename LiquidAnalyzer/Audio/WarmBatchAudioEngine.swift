import AVFAudio
import Foundation

public enum WarmAudioEngineError: LocalizedError, Equatable, Sendable {
    case alreadyRunning
    case notRunning
    case segmentAlreadyOpen
    case noOpenSegment
    case unsupportedInputFormat
    case audioRouteChanged(String)
    case interrupted(String)
    case mediaServicesReset
    case mutedOutputVolume

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "Warm batch audio engine is already running."
        case .notRunning:
            return "Warm batch audio engine is not running."
        case .segmentAlreadyOpen:
            return "Sweep recording segment is already open."
        case .noOpenSegment:
            return "No active sweep recording segment is open."
        case .unsupportedInputFormat:
            return "Microphone input format is unavailable or has zero channels."
        case .audioRouteChanged(let detail):
            return "Audio route changed during controlled acquisition (\(detail))."
        case .interrupted(let detail):
            return "Audio session was interrupted during acquisition (\(detail))."
        case .mediaServicesReset:
            return "iOS media services were reset during acquisition."
        case .mutedOutputVolume:
            return "Output volume is muted."
        }
    }
}

/// Lock-synchronized FIFO in-memory sample store used by the real-time CoreAudio input tap.
/// Avoids spawning unstructured `Task` blocks on the real-time render thread so consecutive
/// 1,024-sample buffers are guaranteed to remain in exact hardware sample order.
public final class CapturedSampleStore: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var segmentStart: Int?

    public init() {}

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        samples.removeAll(keepingCapacity: true)
        samples.reserveCapacity(48_000 * 16)
        segmentStart = nil
    }

    public func appendBuffer(_ ptr: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        samples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: count))
    }

    public func append(_ newSamples: [Float]) {
        guard !newSamples.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        samples.append(contentsOf: newSamples)
    }

    public func openSegment() throws {
        lock.lock()
        defer { lock.unlock() }
        guard segmentStart == nil else {
            throw WarmAudioEngineError.segmentAlreadyOpen
        }
        segmentStart = samples.count
    }

    public func closeSegment() throws -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        guard let start = segmentStart else {
            throw WarmAudioEngineError.noOpenSegment
        }
        segmentStart = nil
        let clampedStart = min(start, samples.count)
        return Array(samples[clampedStart..<samples.count])
    }

    public func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return samples.count
    }
}

private final class OneShotSweepContinuation: @unchecked Sendable {
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

private final class NotificationObserverBag: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [NSObjectProtocol] = []

    func append(_ token: NSObjectProtocol) {
        lock.lock()
        tokens.append(token)
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        let copy = tokens
        tokens.removeAll()
        lock.unlock()
        for t in copy {
            NotificationCenter.default.removeObserver(t)
        }
    }

    deinit {
        removeAll()
    }
}

/// Persistent warm `.measurement`-mode `AVAudioEngine` for single scans and 20x R1 batches.
/// Eliminates per-sweep engine restart transients, captures exact FIFO Float32 samples in RAM,
/// logs CoreAudio route/interruption events, and enforces `validateRouteUnchanged()` across sweeps.
@MainActor
public final class WarmBatchAudioEngine {
    public struct RouteSnapshot: Sendable, Equatable {
        public let sampleRate: Double
        public let inputLatency: TimeInterval
        public let outputLatency: TimeInterval
        public let ioBufferDuration: TimeInterval
        public let inputPorts: [String]
        public let outputPorts: [String]
        public let selectedMicDataSource: String?
        public let outputVolume: Float

        public init(
            sampleRate: Double,
            inputLatency: TimeInterval,
            outputLatency: TimeInterval,
            ioBufferDuration: TimeInterval,
            inputPorts: [String],
            outputPorts: [String],
            selectedMicDataSource: String?,
            outputVolume: Float
        ) {
            self.sampleRate = sampleRate
            self.inputLatency = inputLatency
            self.outputLatency = outputLatency
            self.ioBufferDuration = ioBufferDuration
            self.inputPorts = inputPorts
            self.outputPorts = outputPorts
            self.selectedMicDataSource = selectedMicDataSource
            self.outputVolume = outputVolume
        }
    }

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private let sampleStore = CapturedSampleStore()

    public private(set) var isRunning = false
    public private(set) var routeSnapshot: RouteSnapshot?
    private let observerBag = NotificationObserverBag()
    private var observedInterruptionReason: String?
    private var observedMediaReset = false

    public init() {}

    public func startWarmBatchEngine(waveformFormat: AVAudioFormat? = nil) async throws -> RouteSnapshot {
        guard !isRunning else {
            throw WarmAudioEngineError.alreadyRunning
        }

        observedInterruptionReason = nil
        observedMediaReset = false
        clearObservers()

        #if os(iOS)
        let granted: Bool
        if #available(iOS 17.0, *) {
            granted = await AVAudioApplication.requestRecordPermission()
        } else {
            granted = await withCheckedContinuation { cont in
                AVAudioSession.sharedInstance().requestRecordPermission { ok in
                    cont.resume(returning: ok)
                }
            }
        }
        guard granted else {
            throw AcquisitionFailure.microphonePermissionDenied
        }

        let session = AVAudioSession.sharedInstance()

        if session.category != .playAndRecord || session.mode != .measurement {
            try? session.overrideOutputAudioPort(.none)
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        }

        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [])
            try? session.setPreferredSampleRate(48_000)
            try? session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true)
        } catch {
            throw AcquisitionFailure.audioEngineFailure("Unable to activate measurement audio session: \(error)")
        }

        // Reject external Bluetooth or wired headphones so speaker-to-mic sweep uses built-in transducers
        let initialRoute = session.currentRoute
        let portDescriptions = initialRoute.outputs.map { $0.portType.rawValue + " " + $0.portName }
            + initialRoute.inputs.map { $0.portType.rawValue + " " + $0.portName }
        for desc in portDescriptions {
            let lower = desc.lowercased()
            if AudioRouteValidator.prohibitedPortSubstrings.contains(where: { lower.contains($0) }) {
                throw AcquisitionFailure.externalAudioRoute(desc)
            }
        }

        try? session.overrideOutputAudioPort(.speaker)
        try await Task.sleep(for: .milliseconds(60))

        if let builtInMic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(builtInMic)
            if let dataSources = builtInMic.dataSources {
                let bottomOmni = dataSources.first {
                    $0.dataSourceName.localizedCaseInsensitiveContains("bottom") &&
                    ($0.supportedPolarPatterns?.contains(.omnidirectional) ?? true)
                } ?? dataSources.first {
                    $0.supportedPolarPatterns?.contains(.omnidirectional) == true
                } ?? dataSources.first

                if let bottomOmni {
                    if bottomOmni.supportedPolarPatterns?.contains(.omnidirectional) == true {
                        try? bottomOmni.setPreferredPolarPattern(.omnidirectional)
                    }
                    try? builtInMic.setPreferredDataSource(bottomOmni)
                }
            }
        }
        if session.maximumInputNumberOfChannels >= 1 {
            try? session.setPreferredInputNumberOfChannels(1)
        }

        try await Task.sleep(for: .milliseconds(120))

        if session.outputVolume < 0.03 {
            throw WarmAudioEngineError.mutedOutputVolume
        }
        #endif

        let newEngine = AVAudioEngine()
        let newPlayer = AVAudioPlayerNode()
        newEngine.attach(newPlayer)

        let inputNode = newEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw WarmAudioEngineError.unsupportedInputFormat
        }

        newEngine.connect(
            newPlayer,
            to: newEngine.mainMixerNode,
            format: waveformFormat
        )
        newEngine.connect(
            newEngine.mainMixerNode,
            to: newEngine.outputNode,
            format: nil
        )

        let storeRef = sampleStore
        storeRef.reset()

        inputNode.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: inputFormat
        ) { buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let frameCount = Int(buffer.frameLength)
            storeRef.appendBuffer(channel, count: frameCount)
        }

        newEngine.prepare()
        do {
            try newEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw AcquisitionFailure.audioEngineFailure("Warm AVAudioEngine failed to start: \(error)")
        }

        // Allow hardware ADC startup DC/pop transient to settle completely before resetting store & arming route guards
        try await Task.sleep(for: .milliseconds(120))
        storeRef.reset()

        registerNotifications()

        let snapshot = currentRouteSnapshot(fallbackRate: inputFormat.sampleRate)
        self.engine = newEngine
        self.player = newPlayer
        self.routeSnapshot = snapshot
        self.isRunning = true

        return snapshot
    }

    public func openSweepRecording() throws {
        guard isRunning else {
            throw WarmAudioEngineError.notRunning
        }
        try validateRouteUnchanged()
        try sampleStore.openSegment()
    }

    @discardableResult
    public func playSweep(fileURL: URL) async throws -> PlaybackTimestamps {
        guard isRunning, let player else {
            throw WarmAudioEngineError.notRunning
        }
        try validateRouteUnchanged()

        let file = try AVAudioFile(forReading: fileURL)
        let sr = max(8_000.0, file.processingFormat.sampleRate)
        let durationSec = Double(file.length) / sr
        let timeoutMs = max(400, Int((durationSec + 1.2) * 1_000.0))

        let startUptime = ProcessInfo.processInfo.systemUptime
        let gate = OneShotSweepContinuation()
        let watchdog = Task {
            try? await Task.sleep(for: .milliseconds(timeoutMs))
            gate.fire()
        }

        // Schedule excitation file ONCE and await hardware playback completion
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            gate.install(continuation)
            player.scheduleFile(
                file,
                at: nil,
                completionCallbackType: .dataPlayedBack
            ) { _ in
                gate.fire()
            }
            player.volume = 1.0
            player.play()
        }

        watchdog.cancel()
        let endUptime = ProcessInfo.processInfo.systemUptime
        try validateRouteUnchanged()
        return PlaybackTimestamps(startUptimeSeconds: startUptime, endUptimeSeconds: endUptime)
    }

    public func closeSweepRecording() throws -> [Float] {
        guard isRunning else {
            throw WarmAudioEngineError.notRunning
        }
        player?.stop()
        let captured = try sampleStore.closeSegment()
        try validateRouteUnchanged()
        return captured
    }

    public func stopWarmBatchEngine() {
        clearObservers()
        if let player {
            player.stop()
        }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        player = nil
        sampleStore.reset()

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
        #endif

        isRunning = false
        routeSnapshot = nil
    }

    public func validateRouteUnchanged() throws {
        guard let original = routeSnapshot, isRunning else {
            throw WarmAudioEngineError.notRunning
        }
        if observedMediaReset {
            throw WarmAudioEngineError.mediaServicesReset
        }
        if let interruption = observedInterruptionReason {
            throw WarmAudioEngineError.interrupted(interruption)
        }

        let current = currentRouteSnapshot(fallbackRate: original.sampleRate)
        let rateChanged = abs(current.sampleRate - original.sampleRate) > 1.0
        let portsChanged = (current.inputPorts != original.inputPorts)
            || (current.outputPorts != original.outputPorts)
            || (current.selectedMicDataSource != original.selectedMicDataSource)

        if rateChanged || portsChanged {
            let detail = "in=\(current.inputPorts.joined(separator: "+"))/\(current.selectedMicDataSource ?? "default"), out=\(current.outputPorts.joined(separator: "+")), sr=\(Int(current.sampleRate))"
            throw WarmAudioEngineError.audioRouteChanged(detail)
        }
    }

    nonisolated public static func writeLosslessMonoWAV(
        samples: [Float],
        sampleRateHz: Double,
        to destinationURL: URL
    ) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRateHz,
            channels: 1,
            interleaved: false
        ) else {
            throw AcquisitionFailure.audioEngineFailure("Unable to construct mono Float32 WAV format.")
        }
        let frameCap = AVAudioFrameCount(max(1, samples.count))
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCap),
              let dst = pcmBuffer.floatChannelData?[0] else {
            throw AcquisitionFailure.fileWriteFailure("Unable to allocate PCM buffer for WAV archival.")
        }
        if samples.isEmpty {
            pcmBuffer.frameLength = 1
            dst[0] = 0.0
        } else {
            pcmBuffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { src in
                if let base = src.baseAddress {
                    dst.update(from: base, count: samples.count)
                }
            }
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
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try? FileManager.default.removeItem(at: destinationURL)
        }
        let outFile = try AVAudioFile(
            forWriting: destinationURL,
            settings: wavSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try outFile.write(from: pcmBuffer)
    }

    private func currentRouteSnapshot(fallbackRate: Double) -> RouteSnapshot {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        return RouteSnapshot(
            sampleRate: session.sampleRate > 0 ? session.sampleRate : fallbackRate,
            inputLatency: session.inputLatency,
            outputLatency: session.outputLatency,
            ioBufferDuration: session.ioBufferDuration,
            inputPorts: session.currentRoute.inputs.map { "\($0.portType.rawValue):\($0.portName)" },
            outputPorts: session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" },
            selectedMicDataSource: session.inputDataSource?.dataSourceName,
            outputVolume: session.outputVolume
        )
        #else
        return RouteSnapshot(
            sampleRate: fallbackRate > 0 ? fallbackRate : 48_000.0,
            inputLatency: 0.005,
            outputLatency: 0.005,
            ioBufferDuration: 0.005,
            inputPorts: ["MicrophoneBuiltIn:Built-In Microphone"],
            outputPorts: ["Speaker:Built-In Speaker"],
            selectedMicDataSource: "Bottom",
            outputVolume: 0.65
        )
        #endif
    }

    private func clearObservers() {
        observerBag.removeAll()
    }

    private func registerNotifications() {
        #if os(iOS)
        let center = NotificationCenter.default

        observerBag.append(
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: .main
            ) { notification in
                print("AUDIT AUDIO_ROUTE_CHANGED:", notification.userInfo ?? [:])
            }
        )

        observerBag.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                print("AUDIT AUDIO_SESSION_INTERRUPTION:", notification.userInfo ?? [:])
                Task { @MainActor [weak self] in
                    self?.observedInterruptionReason = "AVAudioSession interruption"
                }
            }
        )

        observerBag.append(
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                print("AUDIT MEDIA_SERVICES_WERE_RESET")
                Task { @MainActor [weak self] in
                    self?.observedMediaReset = true
                }
            }
        )
        #endif
    }
}
