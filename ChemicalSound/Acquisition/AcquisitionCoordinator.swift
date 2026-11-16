import AVFAudio
import Combine
import Foundation

@MainActor
public final class AcquisitionCoordinator: ObservableObject {
    public let stateMachine: AcquisitionStateMachine
    public let timing: TimingController
    public let repetitions: RepetitionManager
    public let calibration: CalibrationManager

    public let audioSession: AudioSessionController
    public let audioEngine: AudioAcquisitionEngine
    public let waveformRepository: WaveformRepository
    public let qualityControl: QualityControlEngine
    public let store: AcquisitionStore
    public let auditLogger: AuditLogger
    public let exportManager: ExportManager
    public let protocolConfiguration: ResearchProtocol

    private let routeValidator = AudioRouteValidator()
    private let isoFormatter = ISO8601DateFormatter()

    @Published public private(set) var latestRuntimeProfile: AudioRuntimeProfile?
    @Published public private(set) var sessionRecords: [AcquisitionRecord] = []
    @Published public private(set) var lastExportedBundleURL: URL?

    public init(
        stateMachine: AcquisitionStateMachine,
        timing: TimingController = TimingController(),
        repetitions: RepetitionManager = RepetitionManager(),
        calibration: CalibrationManager = CalibrationManager(),
        audioSession: AudioSessionController = AudioSessionController(),
        audioEngine: AudioAcquisitionEngine = AudioAcquisitionEngine(),
        waveformRepository: WaveformRepository = WaveformRepository(),
        qualityControl: QualityControlEngine = QualityControlEngine(),
        store: AcquisitionStore = AcquisitionStore(),
        auditLogger: AuditLogger,
        exportManager: ExportManager = ExportManager(),
        protocolConfiguration: ResearchProtocol = .phase1v12
    ) {
        self.stateMachine = stateMachine
        self.timing = timing
        self.repetitions = repetitions
        self.calibration = calibration
        self.audioSession = audioSession
        self.audioEngine = audioEngine
        self.waveformRepository = waveformRepository
        self.qualityControl = qualityControl
        self.store = store
        self.auditLogger = auditLogger
        self.exportManager = exportManager
        self.protocolConfiguration = protocolConfiguration
    }

    public func configure(sessionID: String = "SESS_01") async {
        do {
            try stateMachine.handle(.configureRequested)
            try await store.verifySufficientStorage()
            _ = try await store.recoverInterruptedTemporaryFiles(sessionID: sessionID)
            try waveformRepository.verifyAllAssets()

            let profile = try await audioSession.configure(protocol: protocolConfiguration)
            latestRuntimeProfile = profile
            try stateMachine.handle(.configurationSucceeded)
        } catch {
            let failure = mapFailure(error)
            try? stateMachine.handle(.configurationFailed(failure))
        }
    }

    public func refreshRuntimeProfile() async {
        latestRuntimeProfile = await audioSession.currentRuntimeProfile(protocol: protocolConfiguration)
    }

    public func runCalibrationStep(
        _ step: CalibrationStepKind,
        studyID: String,
        sessionID: String,
        operatorID: String,
        roomIdentifier: String,
        fixtureVersion: String
    ) async {
        do {
            if stateMachine.state != .readyForCalibration && stateMachine.state != .calibrationFailed {
                try stateMachine.handle(.resetCalibrationRequested)
            }
            try stateMachine.handle(.calibrationRequested)

            let signal: ExcitationSignalChoice = (step == .silenceControl) ? .silence : .ess
            let calMeta = SampleMetadata(
                studyID: studyID,
                sessionID: sessionID,
                operatorID: operatorID,
                roomIdentifier: roomIdentifier,
                scanStage: .blank,
                excitationSignal: signal,
                sampleID: step.rawValue,
                formulationID: (step == .distilledWaterStart || step == .periodicWaterCheck || step == .distilledWaterEnd) ? "H2O_DIST" : nil,
                preparationBatchID: "CAL_BATCH",
                fixtureVersion: fixtureVersion,
                calibrationID: calibration.activeCalibrationID
            )

            let rec = try await executeSingleCapture(
                metadata: calMeta,
                repetitionNumber: 1
            )
            sessionRecords = await store.records(forSession: sessionID)

            guard rec.qualityStatus == "PROVISIONALLY_ACCEPTED" else {
                throw AcquisitionFailure.integrityFailure(
                    "Calibration step \(step.rawValue) rejected: \(rec.qualityFlags.joined(separator: ", "))"
                )
            }

            let driftOK = calibration.recordAcceptedStep(
                step,
                preRollRMSDBFS: rec.preRollRMSDBFS ?? -80.0,
                peakDBFS: rec.peakDBFS ?? -20.0
            )
            try await store.updateSessionValidity(
                sessionID: sessionID,
                sessionValidityState: calibration.sessionValidityState
            )
            sessionRecords = await store.records(forSession: sessionID)

            guard driftOK else {
                throw AcquisitionFailure.calibrationDrift("End-of-session water calibration drift exceeded limit.")
            }

            try stateMachine.handle(.calibrationSucceeded)
        } catch {
            await audioEngine.abortImmediately()
            try? stateMachine.handle(.calibrationFailed(mapFailure(error)))
        }
    }

    public func acknowledgeCalibration() throws {
        guard calibration.hasPassedInitialCalibration else {
            throw AcquisitionFailure.calibrationUnavailable
        }
        try stateMachine.handle(.calibrationAcknowledged)
    }

    public func acceptSampleAndRunSettling(
        metadata: SampleMetadata,
        overrideSettleSeconds: Int? = nil
    ) async throws -> SampleMetadata {
        var updatedMetadata = metadata
        guard calibration.hasPassedInitialCalibration else {
            throw AcquisitionFailure.calibrationUnavailable
        }
        let missing = updatedMetadata.missingRequiredFields()
        guard missing.isEmpty else {
            throw AcquisitionFailure.metadataIncomplete(missing)
        }

        repetitions.resetForNewSample()
        try stateMachine.handle(.sampleMetadataAccepted)
        try stateMachine.handle(.settlingStarted)

        let targetSec = overrideSettleSeconds ?? (updatedMetadata.isLiquidSample ? protocolConfiguration.settleDurationSeconds : 0)
        let actualElapsed = try await timing.runSettleCountdown(seconds: targetSec)
        if updatedMetadata.sampleRestDurationSec == nil {
            updatedMetadata.sampleRestDurationSec = max(Double(targetSec), actualElapsed)
        }
        try stateMachine.handle(.settlingCompleted)
        return updatedMetadata
    }

    public func acquireRepetition(metadata: SampleMetadata) async {
        let repNum = repetitions.nextAttemptNumber()
        let prevEndUptime = timing.lastExcitationEndUptime

        // 1. Arming verification (recoverable without fatalError if volume/route/cooldown off)
        let preProfile: AudioRuntimeProfile
        do {
            let missing = metadata.missingRequiredFields()
            guard missing.isEmpty else {
                throw AcquisitionFailure.metadataIncomplete(missing)
            }
            try timing.verifyCooldownSatisfied(cooldownMs: protocolConfiguration.cooldownMs)
            preProfile = try await verifyArmingConditions(
                isSilenceControl: metadata.excitationSignal == .silence
            )
            latestRuntimeProfile = preProfile
            try stateMachine.handle(.armSucceeded)
        } catch {
            try? stateMachine.handle(.armFailed(mapFailure(error)))
            return
        }

        // 2. Active pre-roll -> playback -> post-roll -> cooldown -> immediate QC -> persist
        do {
            try stateMachine.handle(.preRollStarted)

            let tempURL = try await store.temporaryRecordingURL(
                sessionID: metadata.sessionID,
                sampleID: metadata.sampleID,
                repetition: repNum
            )

            let assetID = metadata.excitationSignal.rawValue
            let assetMeta = try waveformRepository.assetMetadata(assetID: assetID)
            let waveformFile = try waveformRepository.audioFile(assetID: assetID)

            try await audioEngine.prepare(
                waveform: waveformFile,
                destinationURL: tempURL,
                expectedSampleRateHz: protocolConfiguration.requestedSampleRateHz
            )
            try await audioEngine.start()

            try await timing.sleepMilliseconds(protocolConfiguration.preRollMs)
            try stateMachine.handle(.excitationStarted)

            let playTimes = await audioEngine.playExcitation(waveform: waveformFile)
            try stateMachine.handle(.excitationCompleted)

            try await timing.sleepMilliseconds(protocolConfiguration.postRollMs)
            _ = try await audioEngine.stopAndFinalizeRecording()

            let postProfile = await audioSession.currentRuntimeProfile(protocol: protocolConfiguration)
            latestRuntimeProfile = postProfile

            let committed = try await store.commitRecordingFile(
                temporaryURL: tempURL,
                sessionID: metadata.sessionID,
                sampleID: metadata.sampleID,
                repetition: repNum
            )

            try stateMachine.handle(.postRollCompleted)

            try await timing.runCooldown(
                fromExcitationEndUptime: playTimes.endUptimeSeconds,
                cooldownMs: protocolConfiguration.cooldownMs
            )
            try stateMachine.handle(.cooldownCompleted)

            let qcResult = try qualityControl.evaluate(
                recordingURL: committed.finalURL,
                metadata: metadata,
                preProfile: preProfile,
                postProfile: postProfile,
                activeExcitationDurationMs: assetMeta.durationMs,
                protocolConfiguration: protocolConfiguration,
                silenceBaselineRMSDBFS: calibration.silenceBaselineRMSDBFS,
                previousExcitationEndUptime: prevEndUptime,
                currentExcitationStartUptime: playTimes.startUptimeSeconds
            )

            let record = buildAcquisitionRecord(
                metadata: metadata,
                repetitionNumber: repNum,
                preProfile: preProfile,
                postProfile: postProfile,
                assetMeta: assetMeta,
                playTimes: playTimes,
                committedFile: (committed.filename, committed.sha256),
                qcResult: qcResult
            )

            try await store.appendScanRecord(record, sessionID: metadata.sessionID)
            repetitions.recordOutcome(record)
            sessionRecords = await store.records(forSession: metadata.sessionID)

            if qcResult.flags.isEmpty {
                try stateMachine.handle(.qualityControlPassed)
                if repetitions.hasReachedTarget(protocolConfiguration.requiredAcceptedRepetitions) {
                    try stateMachine.handle(.requiredRepetitionsCompleted)
                }
            } else {
                try stateMachine.handle(.qualityControlFailed(qcResult.flags))
            }
        } catch {
            await audioEngine.abortImmediately()
            if stateMachine.state != .interrupted {
                try? stateMachine.handle(.fatal(mapFailure(error)))
            }
        }
    }

    public func requestNextRepetition() throws {
        try stateMachine.handle(.nextRepetitionRequested)
    }

    public func prepareForAnotherSample() throws {
        repetitions.resetForNewSample()
        try stateMachine.handle(.resetSampleRequested)
    }

    public func exportSession(studyID: String, sessionID: String) async {
        do {
            try stateMachine.handle(.saveRequested)
            let sessionDir = try await store.sessionDirectory(sessionID: sessionID)
            let records = await store.records(forSession: sessionID)
            let exportsRoot = store.rootDirectoryURL.appendingPathComponent("Exports", isDirectory: true)
            try FileManager.default.createDirectory(at: exportsRoot, withIntermediateDirectories: true)

            let bundleURL = try exportManager.exportSessionBundle(
                studyID: studyID,
                sessionID: sessionID,
                sessionValidityState: calibration.sessionValidityState,
                protocolConfiguration: protocolConfiguration,
                baselineProfile: latestRuntimeProfile,
                sessionDirectoryURL: sessionDir,
                auditLogURL: auditLogger.logFileURL,
                waveformRepository: waveformRepository,
                records: records,
                exportRootURL: exportsRoot
            )
            lastExportedBundleURL = bundleURL
            try stateMachine.handle(.saveSucceeded)
        } catch {
            try? stateMachine.handle(.saveFailed(mapFailure(error)))
        }
    }

    public func handleRouteChange() {
        guard stateMachine.state.isActivelyAcquiring else { return }
        Task { await audioEngine.abortImmediately() }
        try? stateMachine.handle(.routeChanged)
    }

    public func handleAudioInterruption() {
        guard stateMachine.state.isActivelyAcquiring else { return }
        Task { await audioEngine.abortImmediately() }
        try? stateMachine.handle(.audioInterrupted)
    }

    public func handleAppBackgrounded() {
        guard stateMachine.state.isActivelyAcquiring else { return }
        Task { await audioEngine.abortImmediately() }
        try? stateMachine.handle(.appBackgrounded)
    }

    public func recoverFromInterruption(sessionID: String) async {
        do {
            try stateMachine.handle(.recoverRequested)
            let profile = try await audioSession.configure(protocol: protocolConfiguration)
            latestRuntimeProfile = profile
            try stateMachine.handle(.recoverySucceeded)
        } catch {
            try? stateMachine.handle(.recoveryFailed(mapFailure(error)))
        }
    }

    // MARK: - Helpers

    private func executeSingleCapture(
        metadata: SampleMetadata,
        repetitionNumber: Int
    ) async throws -> AcquisitionRecord {
        let prevEnd = timing.lastExcitationEndUptime
        try timing.verifyCooldownSatisfied(cooldownMs: protocolConfiguration.cooldownMs)
        let preProfile = try await verifyArmingConditions(
            isSilenceControl: metadata.excitationSignal == .silence
        )

        let tempURL = try await store.temporaryRecordingURL(
            sessionID: metadata.sessionID,
            sampleID: metadata.sampleID,
            repetition: repetitionNumber
        )
        let assetID = metadata.excitationSignal.rawValue
        let assetMeta = try waveformRepository.assetMetadata(assetID: assetID)
        let waveformFile = try waveformRepository.audioFile(assetID: assetID)

        try await audioEngine.prepare(
            waveform: waveformFile,
            destinationURL: tempURL,
            expectedSampleRateHz: protocolConfiguration.requestedSampleRateHz
        )
        try await audioEngine.start()
        try await timing.sleepMilliseconds(protocolConfiguration.preRollMs)
        let playTimes = await audioEngine.playExcitation(waveform: waveformFile)
        try await timing.sleepMilliseconds(protocolConfiguration.postRollMs)
        _ = try await audioEngine.stopAndFinalizeRecording()

        let postProfile = await audioSession.currentRuntimeProfile(protocol: protocolConfiguration)
        let committed = try await store.commitRecordingFile(
            temporaryURL: tempURL,
            sessionID: metadata.sessionID,
            sampleID: metadata.sampleID,
            repetition: repetitionNumber
        )
        try await timing.runCooldown(
            fromExcitationEndUptime: playTimes.endUptimeSeconds,
            cooldownMs: protocolConfiguration.cooldownMs
        )

        let qcResult = try qualityControl.evaluate(
            recordingURL: committed.finalURL,
            metadata: metadata,
            preProfile: preProfile,
            postProfile: postProfile,
            activeExcitationDurationMs: assetMeta.durationMs,
            protocolConfiguration: protocolConfiguration,
            silenceBaselineRMSDBFS: calibration.silenceBaselineRMSDBFS,
            previousExcitationEndUptime: prevEnd,
            currentExcitationStartUptime: playTimes.startUptimeSeconds
        )

        let record = buildAcquisitionRecord(
            metadata: metadata,
            repetitionNumber: repetitionNumber,
            preProfile: preProfile,
            postProfile: postProfile,
            assetMeta: assetMeta,
            playTimes: playTimes,
            committedFile: (committed.filename, committed.sha256),
            qcResult: qcResult
        )
        try await store.appendScanRecord(record, sessionID: metadata.sessionID)
        return record
    }

    private func verifyArmingConditions(isSilenceControl: Bool) async throws -> AudioRuntimeProfile {
        let profile = await audioSession.currentRuntimeProfile(protocol: protocolConfiguration)
        try routeValidator.validateConfiguration(
            profile: profile,
            protocolConfiguration: protocolConfiguration
        )
        if !isSilenceControl {
            try routeValidator.validateOutputVolume(
                actualVolume: profile.outputVolume,
                protocolConfiguration: protocolConfiguration
            )
        }
        return profile
    }

    private func buildAcquisitionRecord(
        metadata: SampleMetadata,
        repetitionNumber: Int,
        preProfile: AudioRuntimeProfile,
        postProfile: AudioRuntimeProfile,
        assetMeta: WaveformAsset,
        playTimes: PlaybackTimestamps,
        committedFile: (filename: String, sha256: String),
        qcResult: QualityEvaluationResult
    ) -> AcquisitionRecord {
        let finalValidity: String
        if qcResult.qualityStatus == "PROVISIONALLY_ACCEPTED" {
            finalValidity = (calibration.sessionValidityState == "SESSION_VALID")
                ? "FINAL_ACCEPTED"
                : "PROVISIONALLY_ACCEPTED"
        } else {
            finalValidity = "INVALID_MEASUREMENT"
        }

        return AcquisitionRecord(
            datasetVersion: protocolConfiguration.datasetVersion,
            protocolVersion: protocolConfiguration.specVersion,
            waveformVersion: protocolConfiguration.waveformVersion,
            hardwareDomain: protocolConfiguration.hardwareDomain,
            studyID: metadata.studyID,
            sessionID: metadata.sessionID,
            operatorID: metadata.operatorID,
            scanStage: metadata.scanStage.rawValue,
            sampleID: metadata.sampleID,
            blindCode: metadata.blindCode,
            isBlindedRun: metadata.isBlindedRun,
            liquidClass: metadata.liquidClass,
            formulationID: metadata.formulationID,
            preparationBatchID: metadata.preparationBatchID,
            concentrationValue: metadata.concentrationValue,
            concentrationUnit: metadata.concentrationUnit,
            preparationMethod: metadata.preparationMethod,
            preparationTimestamp: metadata.preparationTimestampISO,
            fillTimestamp: metadata.fillTimestampISO,
            scanTimestamp: isoFormatter.string(from: Date()),
            containerType: metadata.containerType,
            containerProductNumber: metadata.containerProductNumber,
            containerLot: metadata.containerLot,
            containerID: metadata.containerID,
            isHeldOutContainer: metadata.isHeldOutContainer,
            capClosureState: metadata.capClosureState,
            bubbleFoamFlag: metadata.bubbleFoamFlag,
            positionConfirmed: metadata.positionConfirmed,
            nominalVolumeML: metadata.nominalVolumeML,
            measuredMassG: metadata.measuredMassG,
            fillHeightMM: metadata.fillHeightMM,
            headspaceHeightMM: metadata.headspaceHeightMM,
            sampleTemperatureC: metadata.sampleTemperatureC,
            tempMeasurementMethod: metadata.tempMeasurementMethod,
            tempMeasurementTiming: metadata.tempMeasurementTiming,
            ambientTemperatureC: metadata.ambientTemperatureC,
            ambientHumidityPct: metadata.ambientHumidityPct,
            sampleRestDurationSec: metadata.sampleRestDurationSec,
            roomIdentifier: metadata.roomIdentifier,
            fixtureVersion: metadata.fixtureVersion,
            fixtureMode: metadata.fixtureMode,
            couplingForceSetting: metadata.couplingForceSetting,
            expectedCouplingForceSetting: metadata.expectedCouplingForceSetting,
            addedDeadweightG: metadata.addedDeadweightG,
            deadweightAttachmentLocation: metadata.deadweightAttachmentLocation,
            deadweightMethod: metadata.deadweightMethod,
            iphoneModel: postProfile.commercialModelName,
            hardwareModelIdentifier: postProfile.hardwareModelIdentifier,
            iosVersion: postProfile.iosVersion,
            appVersion: postProfile.appVersion,
            deviceCode: postProfile.deviceCode,
            caseStatus: postProfile.caseStatus,
            batteryLevel: postProfile.batteryLevel,
            chargingState: postProfile.chargingState,
            thermalState: postProfile.thermalState,
            deviceOrientation: postProfile.deviceOrientation,
            requestedAudioMode: "measurement",
            verifiedAudioMode: postProfile.actualMode.lowercased().contains("measurement") ? "measurement" : postProfile.actualMode,
            requestedSampleRateHz: Int(protocolConfiguration.requestedSampleRateHz),
            verifiedSampleRateHz: Int(round(postProfile.actualSampleRate)),
            selectedInputPort: preProfile.inputPortNames.first,
            verifiedInputPort: postProfile.inputPortNames.first,
            selectedMicDatasource: preProfile.requestedInputDataSource,
            verifiedMicDatasource: postProfile.selectedInputDataSource,
            selectedPolarPattern: preProfile.requestedPolarPattern,
            verifiedPolarPattern: postProfile.selectedPolarPattern,
            verifiedOutputPort: postProfile.outputPortNames.first,
            inputChannelCount: postProfile.inputChannelCount,
            outputChannelCount: postProfile.outputChannelCount,
            reportedSpeakerChannelMapping: postProfile.reportedSpeakerChannelMapping,
            targetHardwareVolume: protocolConfiguration.targetOutputVolume,
            preScanHardwareVolume: preProfile.outputVolume,
            postScanHardwareVolume: postProfile.outputVolume,
            softwareWaveformAmplitudeDBFS: protocolConfiguration.softwareAmplitudeDBFS,
            inputLatencySec: postProfile.inputLatencySeconds,
            outputLatencySec: postProfile.outputLatencySeconds,
            ioBufferDurationSec: postProfile.ioBufferDurationSeconds,
            routeProfileVerified: !qcResult.flags.contains(.audioRouteInvalid),
            excitationSignalID: assetMeta.assetID,
            excitationWavSHA256: assetMeta.sha256,
            recordingFormat: "WAV_IEEE_FLOAT32",
            repetitionNumber: repetitionNumber,
            excitationStartHostTimeS: playTimes.startUptimeSeconds,
            excitationEndHostTimeS: playTimes.endUptimeSeconds,
            cooldownSec: Double(protocolConfiguration.cooldownMs) / 1_000.0,
            peakDBFS: qcResult.peakDBFS,
            preRollRMSDBFS: qcResult.preRollRMSDBFS,
            qualityStatus: qcResult.qualityStatus,
            sessionValidityState: calibration.sessionValidityState,
            finalScanValidity: finalValidity,
            qualityFlags: qcResult.flags.map(\.rawValue),
            rawAudioFilename: committedFile.filename,
            rawAudioSHA256: committedFile.sha256,
            featureRecordID: nil,
            calibrationID: metadata.calibrationID ?? calibration.activeCalibrationID,
            operatorNotes: metadata.operatorNotes
        )
    }

    private func mapFailure(_ error: Error) -> AcquisitionFailure {
        if let failure = error as? AcquisitionFailure {
            return failure
        }
        return .integrityFailure(String(describing: error))
    }
}
