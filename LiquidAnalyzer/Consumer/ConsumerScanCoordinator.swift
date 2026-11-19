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
    @Published public var autoScanWhenSteady: Bool = false {
        didSet {
            cameraService.isAutoScanEnabled = autoScanWhenSteady
        }
    }
    @Published public var hapticsEnabled: Bool = true
    @Published public var selectedGeometryCondition: GeometryTestCondition = .stationary15InBaseline
    @Published public var selectedControlSeriesTag: ControlSeriesTag = .unlabeledBlind
    @Published public var isResearchConsolePresented: Bool = false

    public private(set) var isConfiguringSession: Bool = false
    public let cameraService: CameraTargetingService
    public let tunePlayer: ChemicalTunePlayer
    public let warmAudioEngine = WarmBatchAudioEngine()

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
        resolvedCam.isAutoScanEnabled = false
        self.cameraService = resolvedCam
        self.tunePlayer = tunePlayer ?? ChemicalTunePlayer()
        self.classifier = classifier
        let resolvedStore = historyStore ?? ConsumerHistoryStore()
        self.historyStore = resolvedStore
        let loadedHistory = resolvedStore.loadAll()
        self.history = loadedHistory
        self.consumerScanCounter = max(loadedHistory.compactMap(\.scanSequenceNumber).max() ?? 0, loadedHistory.count)
        let resolvedProtoStore = prototypeStore ?? CalibratedPrototypeStore()
        self.prototypeStore = resolvedProtoStore
        self.calibratedPrototypes = resolvedProtoStore.loadAll()

        resolvedCam.onAutoTargetLocked = { [weak self] in
            guard let self, self.autoScanWhenSteady, case .aim = self.flowStep else { return }
            self.triggerLightHaptic()
            self.beginScan(isAutoTriggered: true)
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

    public func beginScan(isAutoTriggered: Bool = false) {
        guard activeScanTask == nil else { return }
        tunePlayer.stop()
        consumerAlertMessage = nil
        triggerLightHaptic()

        // Grab latest silent preview thumbnail + full wide-angle scene frame + camera lock state BEFORE stopping AIM
        let thumbnailData = cameraService.latestTargetingThumbnail()
        let sceneContextData = cameraService.latestSceneContextJPEG()
        let lockSnapshot = cameraService.captureLockSnapshot(isAutoTriggered: isAutoTriggered, isControlledBatch: false)
        let geometryTag = selectedGeometryCondition.rawValue
        let controlTag = selectedControlSeriesTag.rawValue
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
                lockSnapshot: lockSnapshot,
                geometryCondition: geometryTag,
                controlSeriesTag: controlTag,
                batchTotalCount: 1
            )
            self.activeScanTask = nil
        }
    }

    /// Runs a hands-free N-scan untouched Repeatability Gate R1 sequence (default 20 scans)
    /// locking AE/AF/WB on the reference frame, keeping a single warm measurement-mode `AVAudioEngine`,
    /// and preserving every individual acquisition (including quality-gate rejections) without silent drops.
    public func startRepeatabilityGateR1Batch(count: Int = 20) {
        guard activeScanTask == nil else { return }
        tunePlayer.stop()
        consumerAlertMessage = nil
        triggerLightHaptic()

        let targetN = max(2, min(30, count))
        let geometryTag = selectedGeometryCondition.rawValue
        let controlTag = selectedControlSeriesTag.rawValue

        scanProgress = 0.04
        scanningStatusTitle = "Repeatability Gate R1 (1 / \(targetN))"
        scanningStatusSubtitle = "Locking optics • Keep phone & target untouched"
        flowStep = .scanning

        activeScanTask = Task { [weak self] in
            guard let self else { return }
            if !self.cameraService.isCameraLive {
                self.cameraService.startCamera(graceDelaySeconds: 10.0)
                try? await self.researchCoordinator.timing.sleepMilliseconds(800)
            }
            _ = await self.cameraService.lockOpticsForControlledBatchIfLive()
            let thumbnailData = self.cameraService.latestTargetingThumbnail()
            let sceneContextData = self.cameraService.latestSceneContextJPEG()
            let lockSnapshot = self.cameraService.captureLockSnapshot(isAutoTriggered: false, isControlledBatch: true)
            self.cameraService.stopCamera()

            await self.runAutomatedConsumerScan(
                thumbnailData: thumbnailData,
                sceneContextData: sceneContextData,
                lockSnapshot: lockSnapshot,
                geometryCondition: geometryTag,
                controlSeriesTag: controlTag,
                batchTotalCount: targetN
            )
            self.activeScanTask = nil
        }
    }

    public func cancelActiveScan() {
        guard !isConfiguringSession else { return }
        activeScanTask?.cancel()
        activeScanTask = nil
        warmAudioEngine.stopWarmBatchEngine()
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

    /// Generates the complete UTF-8 Repeatability Gate R1 CSV string for a cohort or full history.
    public func exportRepeatabilityCSVText(items subset: [ConsumerScanItem]? = nil) -> String {
        let source = subset ?? history
        guard !source.isEmpty else { return "" }
        let ordered = Array(source.reversed())
        var lines: [String] = [
            "scan_num,batch_run_id,batch_index,batch_total,timestamp_iso,geometry_condition,control_series_tag,ae_af_wb_lock_state,target_lock_state,target_lock_score,final_status,gate_decision,rejection_reason,final_classification,primary_peak_hz,primary_peak_db,secondary_peaks_hz,secondary_peaks_db,intra_scan_persistence,container_centroid_hz,active_rms_dbfs,peak_dbfs,snr_db,echo_rms_dbfs,echo_return_db,tail_snr_db,alignment_offset_samples,echo_arrival_delay_ms,hf_scatter_db,decay_db_per_s,cavity_multipath_db,feature_checksum,subband_db_vector,top_candidate,top_dist,second_candidate,second_dist,winning_margin,all_candidate_scores,is_conditioning_cycle,mode_a_screening,modal_f1_f4_hz,modal_mask_1_4,modal_q1_q4,modal_edc_alpha1_4_per_s,modal_s_att_db_per_khz,late_preroll_dbfs"
        ]
        let isoFmt = ISO8601DateFormatter()
        for (idx, item) in ordered.enumerated() {
            let seq = item.scanSequenceNumber ?? (idx + 1)
            let iso = isoFmt.string(from: item.scannedAt)
            let f = item.measuredFeatures
            let mv = f?.modalVector
            let secPeaks = f?.secondaryPeaksHz.map { String(format: "%.1f", $0) }.joined(separator: ";") ?? ""
            let secAmps = f?.secondaryPeakAmplitudesDB.map { String(format: "%.2f", $0) }.joined(separator: ";") ?? ""
            let subBands = f?.subBandShapeDB.map { String(format: "%+.2f", $0) }.joined(separator: ";") ?? ""
            let allScores = item.allCandidateDistances?.map { "\($0.profileID):\(String(format: "%.3f", $0.distance))" }.joined(separator: ";") ?? ""
            let modalFreqs = mv?.frequenciesHz.map { $0.map { String(format: "%.2f", $0) } ?? "NaN" }.joined(separator: ";") ?? ""
            let modalMask = mv?.validityMask.map { "\($0)" }.joined(separator: ";") ?? ""
            let modalQs = mv?.qualityFactorsQ.map { $0.map { String(format: "%.2f", $0) } ?? "NaN" }.joined(separator: ";") ?? ""
            let modalAlphas = mv?.decayAlphaPerSec.map { $0.map { String(format: "%.2f", $0) } ?? "NaN" }.joined(separator: ";") ?? ""
            let sAttStr = mv?.spectralAttenuationSlopeDBPerKHz.map { String(format: "%.3f", $0) } ?? ""
            let latePreStr = f.map { String(format: "%.2f", $0.latePreRollNoiseDBFS) } ?? ""
            let row = [
                "\(seq)",
                Self.csvEscape(item.batchRunID ?? ""),
                item.batchScanIndex.map { "\($0)" } ?? "1",
                item.batchTotalCount.map { "\($0)" } ?? "1",
                iso,
                Self.csvEscape(item.geometryCondition ?? GeometryTestCondition.handheldGeneral.rawValue),
                Self.csvEscape(item.controlSeriesTag ?? ControlSeriesTag.unlabeledBlind.rawValue),
                Self.csvEscape(item.aeAfWbLockState ?? ""),
                Self.csvEscape(item.targetLockState ?? ""),
                item.targetLockScore.map { String(format: "%.2f", $0) } ?? "",
                item.status.rawValue,
                Self.csvEscape(item.gateDecision ?? ""),
                Self.csvEscape(item.rejectionReason ?? ""),
                Self.csvEscape(item.title),
                String(format: "%.2f", item.measuredPeakHz),
                String(format: "%.2f", f?.primaryPeakAmplitudeDB ?? 0.0),
                Self.csvEscape(secPeaks),
                Self.csvEscape(secAmps),
                String(format: "%.3f", f?.intraScanPersistenceRatio ?? 0.0),
                String(format: "%.2f", item.measuredCentroidHz),
                String(format: "%.2f", f?.activeRMSDBFS ?? 0.0),
                String(format: "%.2f", f?.peakDBFS ?? 0.0),
                String(format: "%.2f", f?.activeSNRDB ?? 0.0),
                String(format: "%.2f", f?.echoRMSDBFS ?? 0.0),
                String(format: "%.2f", f?.echoReturnDB ?? 0.0),
                String(format: "%.2f", f?.tailSNRDB ?? 0.0),
                "\(f?.alignmentOffsetSamples ?? 0)",
                String(format: "%.2f", f?.echoArrivalDelayMs ?? 0.0),
                String(format: "%.2f", f?.highFreqBubbleScatterDB ?? 0.0),
                String(format: "%.2f", item.measuredDecayDBPerSec),
                String(format: "%.2f", f?.cavityMultipathDB ?? 0.0),
                f?.featureVectorChecksum ?? "",
                Self.csvEscape(subBands),
                Self.csvEscape(item.topCandidateName ?? ""),
                item.topCandidateDistance.map { String(format: "%.4f", $0) } ?? "",
                Self.csvEscape(item.runnerUpTitle ?? ""),
                item.secondCandidateDistance.map { String(format: "%.4f", $0) } ?? "",
                item.winningMargin.map { String(format: "%.4f", $0) } ?? "",
                Self.csvEscape(allScores),
                item.isConditioningCycle ? "true" : "false",
                Self.csvEscape(item.modeAScreeningState?.rawValue ?? ""),
                Self.csvEscape(modalFreqs),
                Self.csvEscape(modalMask),
                Self.csvEscape(modalQs),
                Self.csvEscape(modalAlphas),
                sAttStr,
                latePreStr
            ].joined(separator: ",")
            lines.append(row)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func sanitizedCSVFilename(suffix: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let cleaned = suffix.unicodeScalars
            .map { allowed.contains($0) ? Character($0) : Character("_") }
        var compact = String(cleaned)
        while compact.contains("__") {
            compact = compact.replacingOccurrences(of: "__", with: "_")
        }
        compact = compact.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let trimmed = compact.isEmpty ? "cohort" : String(compact.prefix(48))
        return "LiquidAnalyzer_R1_\(trimmed).csv"
    }

    /// Writes unlocked Repeatability Gate R1 CSV into `Documents/R1_Exports/` (`NSFileProtectionNone`),
    /// making it immediately accessible without file-protection locks in Files (`On My Device -> Liquid Analyzer -> R1_Exports`) and Share Sheet.
    @discardableResult
    public func exportRepeatabilityCSVURL(items subset: [ConsumerScanItem]? = nil, filenameSuffix: String = "all") -> URL? {
        let csvContent = exportRepeatabilityCSVText(items: subset)
        guard !csvContent.isEmpty, let utf8Data = csvContent.data(using: .utf8) else { return nil }

        let fm = FileManager.default
        let baseDocs = fm.urls(for: .documentDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        let exportDir = baseDocs.appendingPathComponent("R1_Exports", isDirectory: true)
        #if os(iOS)
        try? fm.createDirectory(
            at: exportDir,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.none]
        )
        try? fm.setAttributes([.protectionKey: FileProtectionType.none], ofItemAtPath: exportDir.path)
        #else
        try? fm.createDirectory(at: exportDir, withIntermediateDirectories: true)
        #endif

        let outURL = exportDir.appendingPathComponent(Self.sanitizedCSVFilename(suffix: filenameSuffix))
        do {
            #if os(iOS)
            try utf8Data.write(to: outURL, options: [.atomic, .noFileProtection])
            try? fm.setAttributes([.protectionKey: FileProtectionType.none], ofItemAtPath: outURL.path)
            #else
            try utf8Data.write(to: outURL, options: .atomic)
            #endif
            var rv = URLResourceValues()
            rv.isExcludedFromBackup = false
            var mutableURL = outURL
            try? mutableURL.setResourceValues(rv)
            return outURL
        } catch {
            let fallbackURL = fm.temporaryDirectory.appendingPathComponent(Self.sanitizedCSVFilename(suffix: filenameSuffix))
            try? utf8Data.write(to: fallbackURL, options: .atomic)
            return fallbackURL
        }
    }

    /// Copies the complete UTF-8 R1 CSV text directly to the system clipboard and returns the number of scan rows copied.
    @discardableResult
    public func copyRepeatabilityCSVToClipboard(items subset: [ConsumerScanItem]? = nil) -> Int {
        let source = subset ?? history
        let csvText = exportRepeatabilityCSVText(items: source)
        guard !csvText.isEmpty else { return 0 }
        #if os(iOS)
        UIPasteboard.general.string = csvText
        triggerLightHaptic()
        #endif
        return source.count
    }

    /// Presents a native UIKit `UIActivityViewController` properly anchored for both iPhone and iPad compatibility windows.
    public func presentNativeCSVShareSheet(items subset: [ConsumerScanItem]? = nil, filenameSuffix: String = "cohort") {
        guard let fileURL = exportRepeatabilityCSVURL(items: subset, filenameSuffix: filenameSuffix) else {
            consumerAlertMessage = "No scans available to export yet."
            return
        }
        #if os(iOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let activeScene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        guard let keyWindow = activeScene?.windows.first(where: \.isKeyWindow) ?? activeScene?.windows.first,
              var topVC = keyWindow.rootViewController else {
            consumerAlertMessage = "CSV saved unlocked to Files -> On My Device -> Liquid Analyzer -> R1_Exports/\(fileURL.lastPathComponent)."
            return
        }
        while let presented = topVC.presentedViewController {
            topVC = presented
        }
        let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = topVC.view
            popover.sourceRect = CGRect(
                x: topVC.view.bounds.midX,
                y: topVC.view.bounds.midY,
                width: 1,
                height: 1
            )
            popover.permittedArrowDirections = []
        }
        topVC.present(activityVC, animated: true)
        #endif
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
                scanSequenceNumber: item.scanSequenceNumber,
                batchRunID: item.batchRunID,
                batchScanIndex: item.batchScanIndex,
                batchTotalCount: item.batchTotalCount,
                geometryCondition: item.geometryCondition,
                controlSeriesTag: item.controlSeriesTag,
                aeAfWbLockState: item.aeAfWbLockState,
                targetLockState: item.targetLockState,
                targetLockScore: item.targetLockScore,
                gateDecision: "CALIBRATED_EMPTY_CONTAINER",
                rejectionReason: nil,
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
            if history.count > 500 { history = Array(history.prefix(500)) }
            historyStore.saveAll(history)
        } else if targetID == CalibratedAcousticPrototype.solidSurfaceTargetID {
            updatedItem = ConsumerScanItem(
                id: item.id,
                scannedAt: item.scannedAt,
                scanSequenceNumber: item.scanSequenceNumber,
                batchRunID: item.batchRunID,
                batchScanIndex: item.batchScanIndex,
                batchTotalCount: item.batchTotalCount,
                geometryCondition: item.geometryCondition,
                controlSeriesTag: item.controlSeriesTag,
                aeAfWbLockState: item.aeAfWbLockState,
                targetLockState: item.targetLockState,
                targetLockScore: item.targetLockScore,
                gateDecision: "CALIBRATED_SOLID_SURFACE",
                rejectionReason: nil,
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
                scanSequenceNumber: item.scanSequenceNumber,
                batchRunID: item.batchRunID,
                batchScanIndex: item.batchScanIndex,
                batchTotalCount: item.batchTotalCount,
                geometryCondition: item.geometryCondition,
                controlSeriesTag: item.controlSeriesTag,
                aeAfWbLockState: item.aeAfWbLockState,
                targetLockState: item.targetLockState,
                targetLockScore: item.targetLockScore,
                gateDecision: "CALIBRATED_KNOWN_STANDARD",
                rejectionReason: nil,
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
            if history.count > 500 { history = Array(history.prefix(500)) }
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
        lockSnapshot: CameraLockSnapshot,
        geometryCondition: String,
        controlSeriesTag: String,
        batchTotalCount: Int
    ) async {
        let protocolConfig = researchCoordinator.protocolConfiguration
        let waveformRepo = researchCoordinator.waveformRepository
        let timing = researchCoordinator.timing
        let store = researchCoordinator.store
        let targetCount = max(1, batchTotalCount)

        let slugFmt = DateFormatter()
        slugFmt.locale = Locale(identifier: "en_US_POSIX")
        slugFmt.dateFormat = "yyyyMMdd_HHmmss"
        let slug = slugFmt.string(from: Date())
        let batchRunID = targetCount > 1 ? "R1_\(targetCount)X_\(slug)" : "SINGLE_\(slug)"

        do {
            try await store.verifySufficientStorage()
            try waveformRepo.verifyAllAssets()
            if Task.isCancelled { return }
            scanProgress = targetCount > 1 ? 0.06 : 0.22

            let assetMeta = try waveformRepo.assetMetadata(assetID: "SIG_ESS_v1")
            let excitationURL = try waveformRepo.assetURL(assetID: "SIG_ESS_v1")
            let inverseURL = try? waveformRepo.assetURL(assetID: "SIG_ESS_v1_inverse")
            let initialWaveform = try waveformRepo.audioFile(assetID: "SIG_ESS_v1")

            warmAudioEngine.stopWarmBatchEngine()
            isConfiguringSession = true
            let routeSnapshot: WarmBatchAudioEngine.RouteSnapshot
            do {
                routeSnapshot = try await warmAudioEngine.startWarmBatchEngine(
                    waveformFormat: initialWaveform.processingFormat
                )
                isConfiguringSession = false
            } catch WarmAudioEngineError.mutedOutputVolume {
                isConfiguringSession = false
                warmAudioEngine.stopWarmBatchEngine()
                flowStep = .aim
                scanProgress = 0.0
                consumerAlertMessage = "Your device volume is muted. Please press Volume Up slightly so Liquid Analyzer can play its acoustic test sound."
                return
            } catch {
                isConfiguringSession = false
                throw error
            }

            let actualRate = routeSnapshot.sampleRate > 0 ? routeSnapshot.sampleRate : 48_000.0
            let preRollMs = max(180, protocolConfig.preRollMs)
            let postRollMs = max(180, protocolConfig.postRollMs)
            var lastResultItem: ConsumerScanItem?

            for batchIdx in 1...targetCount {
                if Task.isCancelled {
                    warmAudioEngine.stopWarmBatchEngine()
                    return
                }
                let isCondSweep = WarmBatchAudioEngine.isConditioningSweep(batchIndex: batchIdx, batchTotalCount: targetCount)
                if targetCount > 1 {
                    let phaseLabel = isCondSweep ? "Conditioning Purge K2" : "Steady-State"
                    scanningStatusTitle = "Repeatability Gate R2 (\(batchIdx) / \(targetCount) • \(phaseLabel))"
                    scanningStatusSubtitle = "Keep device & target untouched (\(geometryCondition == GeometryTestCondition.stationary15InBaseline.rawValue ? "15-in Baseline" : "Fixed Geometry"))"
                    scanProgress = Double(batchIdx - 1) / Double(targetCount)
                }

                if batchIdx == 1 {
                    let remainingCooldownMs = timing.remainingCooldownMilliseconds
                    if remainingCooldownMs > 0 {
                        try await timing.sleepMilliseconds(min(remainingCooldownMs, 2_050))
                    }
                } else {
                    // Phase R2-B mandatory >= 900 ms inter-sweep acoustic ring-down dissipation gap on warm engine
                    try await warmAudioEngine.awaitInterSweepSettle(
                        requestedMs: WarmBatchAudioEngine.minimumInterSweepSettleMs
                    )
                }

                if Task.isCancelled {
                    warmAudioEngine.stopWarmBatchEngine()
                    return
                }
                if targetCount == 1 { scanProgress = 0.38 }

                consumerScanCounter += 1
                let currentSeq = consumerScanCounter
                let sessionID = "CONSUMER_SESS"
                let sampleID = String(format: "SCAN_%04d", currentSeq)
                let tempURL = try await store.temporaryRecordingURL(
                    sessionID: sessionID,
                    sampleID: sampleID,
                    repetition: batchIdx
                )

                // Verify audio route & mic data source remain strictly unchanged before opening RAM segment
                try warmAudioEngine.validateRouteUnchanged()
                try warmAudioEngine.openSweepRecording()

                try await timing.sleepMilliseconds(preRollMs)
                if Task.isCancelled {
                    warmAudioEngine.stopWarmBatchEngine()
                    return
                }
                if targetCount == 1 { scanProgress = 0.56 }

                let playTimes = try await warmAudioEngine.playSweep(fileURL: excitationURL)
                if targetCount == 1 { scanProgress = 0.78 }

                try await timing.sleepMilliseconds(postRollMs)
                let preRollFrames = Int(round(Double(preRollMs) * actualRate / 1_000.0))
                let activeFrames = Int(round(Double(assetMeta.durationMs) * actualRate / 1_000.0))
                let captureSegment = try warmAudioEngine.closeSweepRecordingSegment(
                    nominalPreRollFrames: preRollFrames,
                    sampleRateHz: actualRate
                )
                let capturedSamples = captureSegment.fullSamples
                timing.recordExcitationCompleted(atUptime: playTimes.endUptimeSeconds)

                // Archive lossless Float32 WAV to disk outside the real-time capture window
                try WarmBatchAudioEngine.writeLosslessMonoWAV(
                    samples: capturedSamples,
                    sampleRateHz: actualRate,
                    to: tempURL
                )

                let committed = try await store.commitRecordingFile(
                    temporaryURL: tempURL,
                    sessionID: sessionID,
                    sampleID: sampleID,
                    repetition: batchIdx
                )
                if Task.isCancelled {
                    warmAudioEngine.stopWarmBatchEngine()
                    return
                }
                if targetCount == 1 { scanProgress = 0.92 }

                let resultItem = try classifier.analyzeAndClassify(
                    recordingURL: committed.finalURL,
                    inverseFilterURL: (abs(actualRate - 48_000.0) < 100.0) ? inverseURL : nil,
                    preRollFrames: preRollFrames,
                    activeFrames: activeFrames,
                    clippingCeilingDBFS: protocolConfig.clippingCeilingDBFS,
                    scanSequenceNumber: currentSeq,
                    batchRunID: batchRunID,
                    batchScanIndex: batchIdx,
                    batchTotalCount: targetCount,
                    geometryCondition: geometryCondition,
                    controlSeriesTag: controlSeriesTag,
                    aeAfWbLockState: lockSnapshot.aeAfWbLockState,
                    targetLockState: lockSnapshot.targetLockState,
                    targetLockScore: lockSnapshot.targetLockScore,
                    thumbnailJPEGData: thumbnailData,
                    sceneContextJPEGData: sceneContextData,
                    opticsLocked: lockSnapshot.opticsLocked,
                    calibratedPrototypes: calibratedPrototypes,
                    latePreRollSilence: captureSegment.latePreRollSilenceSamples
                )

                // Preserve EVERY scan (including rejected quality & non-liquid controls) — never silently drop!
                history.insert(resultItem, at: 0)
                if history.count > 500 {
                    history = Array(history.prefix(500))
                }
                historyStore.saveAll(history)
                lastResultItem = resultItem
                scanProgress = Double(batchIdx) / Double(targetCount)
            }

            warmAudioEngine.stopWarmBatchEngine()
            // Auto-save unlocked CSV copies into Documents/R1_Exports/ so they are always available in the Files app
            _ = exportRepeatabilityCSVURL(items: nil, filenameSuffix: "latest_all")
            if targetCount > 1 {
                let batchMembers = history.filter { $0.batchRunID == batchRunID }
                _ = exportRepeatabilityCSVURL(items: batchMembers, filenameSuffix: batchRunID)
            }
            try? await timing.sleepMilliseconds(120)
            if Task.isCancelled { return }
            scanProgress = 1.0

            if targetCount > 1 {
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
            warmAudioEngine.stopWarmBatchEngine()
            await researchCoordinator.audioEngine.abortImmediately()
            if Task.isCancelled { return }
            scanProgress = 0.0
            flowStep = .aim
            consumerAlertMessage = friendlyConsumerMessage(for: error)
        }
    }

    private func friendlyConsumerMessage(for error: Error) -> String {
        if let warmErr = error as? WarmAudioEngineError {
            return warmErr.localizedDescription
        }
        guard let failure = error as? AcquisitionFailure else {
            return "Unable to complete the scan right now. Please hold your device steady in a quiet spot and try again."
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
