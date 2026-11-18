import Combine
import Foundation
#if os(iOS)
import UIKit
#endif

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

/// Orchestrates the consumer HOME -> AIM -> SCAN -> RESULT -> LISTEN experience on top of the Layer 2 Research Engine.
@MainActor
public final class ConsumerScanCoordinator: ObservableObject {
    @Published public var selectedTab: ConsumerTab = .scan
    @Published public var flowStep: ScanFlowStep = .home
    @Published public private(set) var scanProgress: Double = 0.0
    @Published public private(set) var scanningStatusTitle: String = "Analyzing Liquid..."
    @Published public private(set) var scanningStatusSubtitle: String = "Listening to sound-wave reflections"
    @Published public var consumerAlertMessage: String?
    @Published public private(set) var history: [ConsumerScanItem] = []
    @Published public private(set) var calibratedPrototypes: [CalibratedAcousticPrototype] = []
    @Published public var autoPlayTunePreview: Bool = true
    @Published public var autoScanWhenSteady: Bool = true
    @Published public var hapticsEnabled: Bool = true
    @Published public var isResearchConsolePresented: Bool = false

    public private(set) var isConfiguringSession: Bool = false
    public let cameraService: CameraTargetingService
    public let tunePlayer: ChemicalTunePlayer

    private let researchCoordinator: AcquisitionCoordinator
    private let classifier: OnDeviceAcousticClassifier
    private let historyStore: ConsumerHistoryStore
    private let prototypeStore: CalibratedPrototypeStore
    private var activeScanTask: Task<Void, Never>?
    private var consumerScanCounter: Int = 0

    public init(
        researchCoordinator: AcquisitionCoordinator,
        cameraService: CameraTargetingService? = nil,
        tunePlayer: ChemicalTunePlayer? = nil,
        classifier: OnDeviceAcousticClassifier = OnDeviceAcousticClassifier(),
        historyStore: ConsumerHistoryStore? = nil,
        prototypeStore: CalibratedPrototypeStore? = nil
    ) {
        self.researchCoordinator = researchCoordinator
        let resolvedCam = cameraService ?? CameraTargetingService()
        self.cameraService = resolvedCam
        self.tunePlayer = tunePlayer ?? ChemicalTunePlayer()
        self.classifier = classifier
        let resolvedStore = historyStore ?? ConsumerHistoryStore()
        self.historyStore = resolvedStore
        self.history = resolvedStore.loadAll()
        let resolvedProtoStore = prototypeStore ?? CalibratedPrototypeStore()
        self.prototypeStore = resolvedProtoStore
        self.calibratedPrototypes = resolvedProtoStore.loadAll()

        resolvedCam.onAutoTargetLocked = { [weak self] in
            guard let self, self.autoScanWhenSteady, case .aim = self.flowStep else { return }
            self.triggerLightHaptic()
            self.beginScan()
        }
    }

    public func openCameraAiming(graceDelaySeconds: Double = 0.9) {
        tunePlayer.stop()
        consumerAlertMessage = nil
        scanProgress = 0.0
        flowStep = .aim
        cameraService.startCamera(graceDelaySeconds: graceDelaySeconds)
    }

    public func returnToHome() {
        activeScanTask?.cancel()
        activeScanTask = nil
        cameraService.stopCamera()
        tunePlayer.stop()
        scanProgress = 0.0
        flowStep = .home
    }

    public func beginScan() {
        guard activeScanTask == nil else { return }
        tunePlayer.stop()
        consumerAlertMessage = nil
        triggerLightHaptic()

        // Grab latest silent preview thumbnail + full wide-angle scene frame + camera lock state BEFORE stopping AIM
        let thumbnailData = cameraService.latestTargetingThumbnail()
        let sceneContextData = cameraService.latestSceneContextJPEG()
        let opticsLocked = cameraService.isOpticsLocked
        cameraService.stopCamera()

        scanProgress = 0.08
        scanningStatusTitle = "Analyzing Liquid..."
        scanningStatusSubtitle = "Listening to sound-wave reflections"
        flowStep = .scanning

        activeScanTask = Task { [weak self] in
            guard let self else { return }
            await self.runAutomatedConsumerScan(
                thumbnailData: thumbnailData,
                sceneContextData: sceneContextData,
                opticsLocked: opticsLocked,
                batchTotalCount: 1
            )
            self.activeScanTask = nil
        }
    }

    /// Runs a hands-free N-scan untouched Repeatability Gate R1 sequence (default 20 scans)
    /// using the locked camera frame and `.measurement` mode bottom microphone.
    public func startRepeatabilityGateR1Batch(count: Int = 20) {
        guard activeScanTask == nil else { return }
        tunePlayer.stop()
        consumerAlertMessage = nil
        triggerLightHaptic()

        let thumbnailData = cameraService.latestTargetingThumbnail()
        let sceneContextData = cameraService.latestSceneContextJPEG()
        let opticsLocked = cameraService.isOpticsLocked
        cameraService.stopCamera()

        let targetN = max(2, min(30, count))
        scanProgress = 0.04
        scanningStatusTitle = "Repeatability Gate R1 (1 / \(targetN))"
        scanningStatusSubtitle = "Keep phone & glass completely untouched"
        flowStep = .scanning

        activeScanTask = Task { [weak self] in
            guard let self else { return }
            await self.runAutomatedConsumerScan(
                thumbnailData: thumbnailData,
                sceneContextData: sceneContextData,
                opticsLocked: opticsLocked,
                batchTotalCount: targetN
            )
            self.activeScanTask = nil
        }
    }

    public func cancelActiveScan() {
        guard !isConfiguringSession else { return }
        activeScanTask?.cancel()
        activeScanTask = nil
        Task {
            await researchCoordinator.audioEngine.abortImmediately()
        }
        scanProgress = 0.0
        openCameraAiming(graceDelaySeconds: 2.0)
    }

    public func resetToAim() {
        openCameraAiming(graceDelaySeconds: 1.8)
    }

    private func triggerLightHaptic() {
        #if os(iOS)
        guard hapticsEnabled else { return }
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        #endif
    }

    public func openHistoryItem(_ item: ConsumerScanItem) {
        tunePlayer.stop()
        selectedTab = .scan
        flowStep = .result(item)
    }

    public func clearHistory() {
        history = []
        consumerScanCounter = 0
        historyStore.saveAll([])
    }

    /// Exports all recorded history items with full Repeatability Gate R1 telemetry to a shareable CSV file.
    public func exportRepeatabilityCSVURL() -> URL? {
        guard !history.isEmpty else { return nil }
        let ordered = Array(history.reversed())
        var lines: [String] = [
            "scan_num,timestamp_iso,final_status,final_classification,primary_peak_hz,secondary_peaks_hz,active_rms_dbfs,peak_dbfs,snr_db,echo_return_db,hf_scatter_db,container_centroid_hz,decay_db_per_s,cavity_multipath_db,feature_checksum,subband_db_vector,top_candidate,top_dist,second_candidate,second_dist,winning_margin,all_candidate_scores"
        ]
        let isoFmt = ISO8601DateFormatter()
        for (idx, item) in ordered.enumerated() {
            let seq = item.scanSequenceNumber ?? (idx + 1)
            let iso = isoFmt.string(from: item.scannedAt)
            let f = item.measuredFeatures
            let secPeaks = f?.secondaryPeaksHz.map { String(format: "%.1f", $0) }.joined(separator: ";") ?? ""
            let subBands = f?.subBandShapeDB.map { String(format: "%+.2f", $0) }.joined(separator: ";") ?? ""
            let allScores = item.allCandidateDistances?.map { "\($0.profileID):\(String(format: "%.3f", $0.distance))" }.joined(separator: ";") ?? ""
            let row = [
                "\(seq)",
                iso,
                item.status.rawValue,
                Self.csvEscape(item.title),
                String(format: "%.2f", item.measuredPeakHz),
                Self.csvEscape(secPeaks),
                String(format: "%.2f", f?.activeRMSDBFS ?? 0.0),
                String(format: "%.2f", f?.peakDBFS ?? 0.0),
                String(format: "%.2f", f?.activeSNRDB ?? 0.0),
                String(format: "%.2f", f?.echoReturnDB ?? 0.0),
                String(format: "%.2f", f?.highFreqBubbleScatterDB ?? 0.0),
                String(format: "%.2f", item.measuredCentroidHz),
                String(format: "%.2f", item.measuredDecayDBPerSec),
                String(format: "%.2f", f?.cavityMultipathDB ?? 0.0),
                f?.featureVectorChecksum ?? "",
                Self.csvEscape(subBands),
                Self.csvEscape(item.topCandidateName ?? ""),
                item.topCandidateDistance.map { String(format: "%.4f", $0) } ?? "",
                Self.csvEscape(item.runnerUpTitle ?? ""),
                item.secondCandidateDistance.map { String(format: "%.4f", $0) } ?? "",
                item.winningMargin.map { String(format: "%.4f", $0) } ?? "",
                Self.csvEscape(allScores)
            ].joined(separator: ",")
            lines.append(row)
        }
        let csvContent = lines.joined(separator: "\n") + "\n"
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("repeatability_gate_r1.csv")
        try? csvContent.data(using: .utf8)?.write(to: outURL, options: .atomic)
        return outURL
    }

    private static func csvEscape(_ raw: String) -> String {
        if raw.contains(",") || raw.contains("\"") || raw.contains("\n") {
            return "\"" + raw.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return raw
    }

    public func clearCalibratedStandards() {
        calibratedPrototypes = []
        prototypeStore.clearAll()
    }

    /// Saves the measured 11D acoustic scattering vector from a scan as a known empirical standard
    /// (enabling calibrated indirect acoustic inference for blind testing in clear or opaque containers).
    public func teachCalibratedStandard(from item: ConsumerScanItem, targetID: String) {
        guard let features = item.measuredFeatures else { return }
        let proto = CalibratedAcousticPrototype(targetID: targetID, features: features)
        prototypeStore.append(proto)
        calibratedPrototypes = prototypeStore.loadAll()
        triggerLightHaptic()

        let updatedItem: ConsumerScanItem
        if targetID == CalibratedAcousticPrototype.emptyContainerTargetID {
            updatedItem = ConsumerScanItem(
                id: item.id,
                scannedAt: item.scannedAt,
                status: .emptyContainer,
                title: "Empty Container",
                formulaDisplay: "Calibrated Empty Glass Control",
                statusBadgeText: "Calibrated Empty Glass Saved",
                confidencePercent: 95,
                scientificNote: "Saved as your calibrated empty-container standard for this setup so dry glass resonance is separated from liquid fills.",
                constituents: [],
                tuneProfile: item.tuneProfile,
                measuredPeakHz: item.measuredPeakHz,
                measuredCentroidHz: item.measuredCentroidHz,
                measuredDecayDBPerSec: item.measuredDecayDBPerSec,
                measuredFeatures: features,
                thumbnailJPEGData: item.thumbnailJPEGData
            )
            history.removeAll { $0.id == item.id }
            history.insert(updatedItem, at: 0)
            if history.count > 50 { history = Array(history.prefix(50)) }
            historyStore.saveAll(history)
        } else if targetID == CalibratedAcousticPrototype.solidSurfaceTargetID {
            updatedItem = ConsumerScanItem(
                id: item.id,
                scannedAt: item.scannedAt,
                status: .nonLiquidMaterial,
                title: "Solid / Non-Liquid Material",
                formulaDisplay: "Calibrated Surface Standard",
                statusBadgeText: "Calibrated Solid Echo Saved",
                confidencePercent: nil,
                scientificNote: "Saved as a known solid-surface reflection standard on this iPhone so similar non-liquid echoes are rejected.",
                constituents: [],
                tuneProfile: item.tuneProfile,
                measuredPeakHz: item.measuredPeakHz,
                measuredCentroidHz: item.measuredCentroidHz,
                measuredDecayDBPerSec: item.measuredDecayDBPerSec,
                measuredFeatures: features,
                thumbnailJPEGData: item.thumbnailJPEGData
            )
        } else if let profile = ReferenceLiquidProfile.provisionalLibrary.first(where: { $0.id == targetID }) {
            updatedItem = ConsumerScanItem(
                id: item.id,
                scannedAt: item.scannedAt,
                status: .referenceMatch,
                title: profile.displayName,
                formulaDisplay: profile.formulaDisplay,
                statusBadgeText: "Calibrated Standard Saved • 95% Similarity",
                confidencePercent: 95,
                scientificNote: "Saved to your iPhone's calibrated acoustic library for \(profile.displayName.lowercased()). Future blind scans in this container will match against this empirical acoustic echo signature.",
                constituents: profile.constituents,
                tuneProfile: profile.tuneProfile,
                measuredPeakHz: item.measuredPeakHz,
                measuredCentroidHz: item.measuredCentroidHz,
                measuredDecayDBPerSec: item.measuredDecayDBPerSec,
                measuredFeatures: features,
                thumbnailJPEGData: item.thumbnailJPEGData
            )
            history.removeAll { $0.id == item.id }
            history.insert(updatedItem, at: 0)
            if history.count > 50 { history = Array(history.prefix(50)) }
            historyStore.saveAll(history)
        } else {
            return
        }

        flowStep = .result(updatedItem)
    }

    // MARK: - Automated Layer 2 Research Sequence

    private func runAutomatedConsumerScan(
        thumbnailData: Data?,
        sceneContextData: Data?,
        opticsLocked: Bool,
        batchTotalCount: Int
    ) async {
        let protocolConfig = researchCoordinator.protocolConfiguration
        let waveformRepo = researchCoordinator.waveformRepository
        let audioSession = researchCoordinator.audioSession
        let audioEngine = researchCoordinator.audioEngine
        let timing = researchCoordinator.timing
        let store = researchCoordinator.store

        do {
            try await store.verifySufficientStorage()
            try waveformRepo.verifyAllAssets()
            if Task.isCancelled { return }
            scanProgress = batchTotalCount > 1 ? 0.06 : 0.22

            isConfiguringSession = true
            let sessionInfo: (sampleRateHz: Double, outputVolume: Float)
            do {
                sessionInfo = try await audioSession.configureForConsumerScan()
                isConfiguringSession = false
            } catch {
                isConfiguringSession = false
                throw error
            }

            if sessionInfo.outputVolume < 0.03 {
                flowStep = .aim
                scanProgress = 0.0
                consumerAlertMessage = "Your iPhone volume is muted. Please press the Volume Up button slightly so Liquid Analyzer can play its acoustic test sound."
                return
            }

            let assetMeta = try waveformRepo.assetMetadata(assetID: "SIG_ESS_v1")
            let inverseURL = try? waveformRepo.assetURL(assetID: "SIG_ESS_v1_inverse")
            var lastResultItem: ConsumerScanItem?

            for batchIdx in 1...max(1, batchTotalCount) {
                if Task.isCancelled { return }
                if batchTotalCount > 1 {
                    scanningStatusTitle = "Repeatability Gate R1 (\(batchIdx) / \(batchTotalCount))"
                    scanningStatusSubtitle = "Do not move phone or glass between sweeps"
                    scanProgress = Double(batchIdx - 1) / Double(batchTotalCount)
                }

                let remainingCooldownMs = timing.remainingCooldownMilliseconds
                if remainingCooldownMs > 0 {
                    try await timing.sleepMilliseconds(min(remainingCooldownMs, 2_050))
                }
                if Task.isCancelled { return }
                if batchTotalCount == 1 { scanProgress = 0.38 }

                consumerScanCounter += 1
                let currentSeq = consumerScanCounter
                let sessionID = "CONSUMER_SESS"
                let sampleID = String(format: "SCAN_%04d", currentSeq + history.count)
                let tempURL = try await store.temporaryRecordingURL(
                    sessionID: sessionID,
                    sampleID: sampleID,
                    repetition: 1
                )

                let waveformFile = try waveformRepo.audioFile(assetID: "SIG_ESS_v1")
                let actualRate = try await audioEngine.prepare(
                    waveform: waveformFile,
                    destinationURL: tempURL,
                    expectedSampleRateHz: sessionInfo.sampleRateHz,
                    enforceExactSampleRate: false
                )
                try await audioEngine.start()

                try await timing.sleepMilliseconds(protocolConfig.preRollMs)
                if Task.isCancelled {
                    await audioEngine.abortImmediately()
                    return
                }
                if batchTotalCount == 1 { scanProgress = 0.56 }

                let playTimes = await audioEngine.playExcitation(waveform: waveformFile)
                if batchTotalCount == 1 { scanProgress = 0.78 }

                try await timing.sleepMilliseconds(protocolConfig.postRollMs)
                _ = try await audioEngine.stopAndFinalizeRecording()

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
                if batchTotalCount == 1 { scanProgress = 0.92 }

                let preRollFrames = Int(round(Double(protocolConfig.preRollMs) * actualRate / 1_000.0))
                let activeFrames = Int(round(Double(assetMeta.durationMs) * actualRate / 1_000.0))

                let resultItem = try classifier.analyzeAndClassify(
                    recordingURL: committed.finalURL,
                    inverseFilterURL: (abs(actualRate - 48_000.0) < 100.0) ? inverseURL : nil,
                    preRollFrames: preRollFrames,
                    activeFrames: activeFrames,
                    clippingCeilingDBFS: protocolConfig.clippingCeilingDBFS,
                    scanSequenceNumber: currentSeq,
                    thumbnailJPEGData: thumbnailData,
                    sceneContextJPEGData: sceneContextData,
                    opticsLocked: opticsLocked,
                    calibratedPrototypes: calibratedPrototypes
                )

                // Record every scan in R1 batch (or any valid single scan) into History for full R1 variance audit
                if batchTotalCount > 1 || (resultItem.status != .unclearScan && resultItem.status != .nonLiquidMaterial) {
                    history.insert(resultItem, at: 0)
                    if history.count > 60 {
                        history = Array(history.prefix(60))
                    }
                    historyStore.saveAll(history)
                }
                lastResultItem = resultItem
                scanProgress = Double(batchIdx) / Double(max(1, batchTotalCount))
            }

            try? await timing.sleepMilliseconds(140)
            if Task.isCancelled { return }
            scanProgress = 1.0

            if batchTotalCount > 1 {
                selectedTab = .history
                if let lastResultItem {
                    flowStep = .result(lastResultItem)
                } else {
                    flowStep = .aim
                }
            } else if let lastResultItem {
                flowStep = .result(lastResultItem)
            }
        } catch {
            isConfiguringSession = false
            await audioEngine.abortImmediately()
            if Task.isCancelled { return }
            scanProgress = 0.0
            flowStep = .aim
            consumerAlertMessage = friendlyConsumerMessage(for: error)
        }
    }

    private func friendlyConsumerMessage(for error: Error) -> String {
        guard let failure = error as? AcquisitionFailure else {
            return "Unable to complete the scan right now. Please hold your iPhone steady in a quiet spot and try again."
        }
        switch failure {
        case .microphonePermissionDenied:
            return "Microphone access is turned off. Please enable Microphone access for Liquid Analyzer in Settings so it can hear sound-wave reflections."
        case .externalAudioRoute, .unsupportedAudioRoute:
            return "Headphones or Bluetooth audio are connected. Please disconnect external audio so Liquid Analyzer can use your iPhone's built-in speaker and microphone."
        case .insufficientStorage:
            return "Your iPhone is low on storage space. Please free a small amount of space and try again."
        default:
            return "Could not capture a clean sound reflection (\(failure.localizedDescription)). Please unplug any audio accessories, turn up media volume, and try again."
        }
    }
}
