import Combine
import Foundation

/// Persists consumer scan items locally on disk for the History tab.
public final class ConsumerHistoryStore: @unchecked Sendable {
    public let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.fileURL = docs
                .appendingPathComponent("LiquidAnalyzerSessions", isDirectory: true)
                .appendingPathComponent("consumer_history.json")
        }
    }

    public func loadAll() -> [ConsumerScanItem] {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ConsumerScanItem].self, from: data)) ?? []
    }

    public func saveAll(_ items: [ConsumerScanItem]) {
        lock.lock()
        defer { lock.unlock() }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(items) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

/// Orchestrates the consumer AIM -> SCAN -> RESULT -> LISTEN experience on top of the Layer 2 Research Engine.
/// All calibration/route/waveform/QC steps happen automatically in the background without exposing lab jargon.
@MainActor
public final class ConsumerScanCoordinator: ObservableObject {
    @Published public var selectedTab: ConsumerTab = .scan
    @Published public var flowStep: ScanFlowStep = .aim
    @Published public private(set) var scanProgress: Double = 0.0
    @Published public var consumerAlertMessage: String?
    @Published public private(set) var history: [ConsumerScanItem] = []
    @Published public var autoPlayTunePreview: Bool = false
    @Published public var hapticsEnabled: Bool = true
    @Published public var isResearchConsolePresented: Bool = false

    public let cameraService: CameraTargetingService
    public let tunePlayer: ChemicalTunePlayer

    // Underlying Layer 2 Research Engine services
    private let researchCoordinator: AcquisitionCoordinator
    private let classifier: OnDeviceAcousticClassifier
    private let historyStore: ConsumerHistoryStore
    private let routeValidator = AudioRouteValidator()
    private var activeScanTask: Task<Void, Never>?
    private var consumerScanCounter: Int = 0

    public init(
        researchCoordinator: AcquisitionCoordinator,
        cameraService: CameraTargetingService? = nil,
        tunePlayer: ChemicalTunePlayer? = nil,
        classifier: OnDeviceAcousticClassifier = OnDeviceAcousticClassifier(),
        historyStore: ConsumerHistoryStore? = nil
    ) {
        self.researchCoordinator = researchCoordinator
        self.cameraService = cameraService ?? CameraTargetingService()
        self.tunePlayer = tunePlayer ?? ChemicalTunePlayer()
        self.classifier = classifier
        let resolvedStore = historyStore ?? ConsumerHistoryStore()
        self.historyStore = resolvedStore
        self.history = resolvedStore.loadAll()
    }

    public func beginScan() {
        guard activeScanTask == nil else { return }
        tunePlayer.stop()
        consumerAlertMessage = nil
        scanProgress = 0.06
        flowStep = .scanning

        activeScanTask = Task { [weak self] in
            guard let self else { return }
            await self.runAutomatedConsumerScan()
            self.activeScanTask = nil
        }
    }

    public func cancelActiveScan() {
        activeScanTask?.cancel()
        activeScanTask = nil
        Task {
            await researchCoordinator.audioEngine.abortImmediately()
        }
        scanProgress = 0.0
        flowStep = .aim
    }

    public func resetToAim() {
        tunePlayer.stop()
        consumerAlertMessage = nil
        scanProgress = 0.0
        flowStep = .aim
    }

    public func openHistoryItem(_ item: ConsumerScanItem) {
        tunePlayer.stop()
        selectedTab = .scan
        flowStep = .result(item)
    }

    public func clearHistory() {
        history = []
        historyStore.saveAll([])
    }

    // MARK: - Automated Layer 2 Research Sequence

    private func runAutomatedConsumerScan() async {
        // 1. Capture visual context thumbnail from camera if available (targeting context only)
        let thumbnailData = await cameraService.captureTargetingThumbnail()
        if Task.isCancelled { return }
        scanProgress = 0.16

        let protocolConfig = researchCoordinator.protocolConfiguration
        let waveformRepo = researchCoordinator.waveformRepository
        let audioSession = researchCoordinator.audioSession
        let audioEngine = researchCoordinator.audioEngine
        let timing = researchCoordinator.timing
        let store = researchCoordinator.store

        do {
            // 2. Verify storage & SHA-256 waveform integrity silently
            try await store.verifySufficientStorage()
            try waveformRepo.verifyAllAssets()
            if Task.isCancelled { return }
            scanProgress = 0.28

            // 3. Configure native iPhone built-in speaker & microphone measurement session
            let preProfile = try await audioSession.configure(protocol: protocolConfig)
            try routeValidator.validateConfiguration(
                profile: preProfile,
                protocolConfiguration: protocolConfig
            )

            // Friendly check if phone hardware volume is muted
            if preProfile.outputVolume < 0.08 {
                flowStep = .aim
                scanProgress = 0.0
                consumerAlertMessage = "Please turn up your iPhone volume slightly so Liquid Analyzer can play its acoustic test sound."
                return
            }

            // 4. Honor thermal/acoustic inter-scan cooldown automatically if user rescans immediately
            let remainingCooldownMs = timing.remainingCooldownMilliseconds
            if remainingCooldownMs > 0 {
                try await timing.sleepMilliseconds(remainingCooldownMs)
            }
            if Task.isCancelled { return }
            scanProgress = 0.42

            // 5. Emit calibrated ESS sweep (`SIG_ESS_v1`) and record 48 kHz Float32 response
            consumerScanCounter += 1
            let sessionID = "CONSUMER_SESS"
            let sampleID = String(format: "SCAN_%04d", consumerScanCounter + history.count)
            let tempURL = try await store.temporaryRecordingURL(
                sessionID: sessionID,
                sampleID: sampleID,
                repetition: 1
            )

            let assetMeta = try waveformRepo.assetMetadata(assetID: "SIG_ESS_v1")
            let waveformFile = try waveformRepo.audioFile(assetID: "SIG_ESS_v1")
            let inverseURL = try? waveformRepo.assetURL(assetID: "SIG_ESS_v1_inverse")

            try await audioEngine.prepare(
                waveform: waveformFile,
                destinationURL: tempURL,
                expectedSampleRateHz: protocolConfig.requestedSampleRateHz
            )
            try await audioEngine.start()

            try await timing.sleepMilliseconds(protocolConfig.preRollMs)
            if Task.isCancelled {
                await audioEngine.abortImmediately()
                return
            }
            scanProgress = 0.58

            let playTimes = await audioEngine.playExcitation(waveform: waveformFile)
            scanProgress = 0.76

            try await timing.sleepMilliseconds(protocolConfig.postRollMs)
            _ = try await audioEngine.stopAndFinalizeRecording()

            // Record excitation timestamp so back-to-back scans respect the 2.0 s hardware cooldown
            Task {
                try? await timing.runCooldown(
                    fromExcitationEndUptime: playTimes.endUptimeSeconds,
                    cooldownMs: protocolConfig.cooldownMs
                )
            }

            let committed = try await store.commitRecordingFile(
                temporaryURL: tempURL,
                sessionID: sessionID,
                sampleID: sampleID,
                repetition: 1
            )
            if Task.isCancelled { return }
            scanProgress = 0.90

            // 6. Deconvolve, verify signal quality, and run experimental reference classification
            let preRollFrames = Int(round(Double(protocolConfig.preRollMs) * protocolConfig.requestedSampleRateHz / 1_000.0))
            let activeFrames = assetMeta.numFrames ?? Int(round(Double(assetMeta.durationMs) * protocolConfig.requestedSampleRateHz / 1_000.0))

            let resultItem = try classifier.analyzeAndClassify(
                recordingURL: committed.finalURL,
                inverseFilterURL: inverseURL,
                preRollFrames: preRollFrames,
                activeFrames: activeFrames,
                clippingCeilingDBFS: protocolConfig.clippingCeilingDBFS,
                thumbnailJPEGData: thumbnailData
            )

            try? await timing.sleepMilliseconds(180)
            if Task.isCancelled { return }
            scanProgress = 1.0

            // Save valid or unmatched scans to consumer history
            if resultItem.status != .unclearScan {
                history.insert(resultItem, at: 0)
                if history.count > 50 {
                    history = Array(history.prefix(50))
                }
                historyStore.saveAll(history)
            }

            flowStep = .result(resultItem)
        } catch {
            await audioEngine.abortImmediately()
            if Task.isCancelled { return }
            scanProgress = 0.0
            flowStep = .aim
            consumerAlertMessage = friendlyConsumerMessage(for: error)
        }
    }

    private func friendlyConsumerMessage(for error: Error) -> String {
        guard let failure = error as? AcquisitionFailure else {
            return "Unable to complete the acoustic scan right now. Please hold your iPhone steady in a quiet area and try again."
        }
        switch failure {
        case .microphonePermissionDenied:
            return "Microphone access is turned off. Please enable Microphone access for Liquid Analyzer in Settings so it can hear acoustic reflections."
        case .externalAudioRoute, .unsupportedAudioRoute:
            return "Headphones or a Bluetooth speaker are connected. Please disconnect external audio so Liquid Analyzer can use your iPhone's built-in speaker and microphone."
        case .insufficientStorage:
            return "Your iPhone is low on storage space. Please free a small amount of space and try scanning again."
        default:
            return "Unable to capture a clean acoustic signal right now. Please disconnect any external audio accessories, check your volume, and try again."
        }
    }
}
