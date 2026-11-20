import AVFAudio
import CryptoKit
import Foundation

/// Layer 2 on-device acoustic feature analyzer and Repeatability Gate R1 instrument engine.
/// Freezes reference profile centroids, enforces a stringent ambiguity gate (`distance <= 0.90` AND `margin >= 0.11`)
/// to prevent forced chemical guessing, and records complete raw resonance & candidate-score telemetry on every scan.
public struct OnDeviceAcousticClassifier: Sendable {
    public let referenceLibrary: [ReferenceLiquidProfile]
    public let distanceThreshold: Double
    public let minimumWinningMargin: Double
    public let minimumSNRDB: Double
    public let inferenceMode: ConsumerInferenceMode
    private let visualAnalyzer = VisualLiquidContextAnalyzer()
    private let visionExtractor = VisionFeatureExtractor()
    private let fusionClassifier = MultiModalFusionClassifier()

    public init(
        referenceLibrary: [ReferenceLiquidProfile] = ReferenceLiquidProfile.provisionalLibrary,
        distanceThreshold: Double = 0.75,
        minimumWinningMargin: Double = 0.11,
        minimumSNRDB: Double = 1.8,
        inferenceMode: ConsumerInferenceMode = .multiModalFusion
    ) {
        self.referenceLibrary = referenceLibrary
        self.distanceThreshold = distanceThreshold
        self.minimumWinningMargin = minimumWinningMargin
        self.minimumSNRDB = minimumSNRDB
        self.inferenceMode = inferenceMode
    }

    public func analyzeAndClassify(
        recordingURL: URL,
        inverseFilterURL: URL?,
        preRollFrames: Int = 7_200,
        activeFrames: Int = 9_600,
        clippingCeilingDBFS: Double = -0.5,
        scanSequenceNumber: Int? = nil,
        batchRunID: String? = nil,
        batchScanIndex: Int? = nil,
        batchTotalCount: Int? = nil,
        geometryCondition: String? = nil,
        controlSeriesTag: String? = nil,
        aeAfWbLockState: String? = nil,
        targetLockState: String? = nil,
        targetLockScore: Double? = nil,
        thumbnailJPEGData: Data? = nil,
        sceneContextJPEGData: Data? = nil,
        opticsLocked: Bool = false,
        calibratedPrototypes: [CalibratedAcousticPrototype] = [],
        latePreRollSilence: [Float]? = nil,
        inferenceModeOverride: ConsumerInferenceMode? = nil
    ) throws -> ConsumerScanItem {
        let (samples, actualSR) = try Self.readMonoFloatSamplesAndRate(from: recordingURL)
        let inverse = inverseFilterURL.flatMap { try? Self.readMonoFloatSamplesAndRate(from: $0).samples }
        return classifySamples(
            samples: samples,
            inverseFilter: inverse,
            sampleRateHz: actualSR,
            preRollFrames: preRollFrames,
            activeFrames: activeFrames,
            clippingCeilingDBFS: clippingCeilingDBFS,
            scanSequenceNumber: scanSequenceNumber,
            batchRunID: batchRunID,
            batchScanIndex: batchScanIndex,
            batchTotalCount: batchTotalCount,
            geometryCondition: geometryCondition,
            controlSeriesTag: controlSeriesTag,
            aeAfWbLockState: aeAfWbLockState,
            targetLockState: targetLockState,
            targetLockScore: targetLockScore,
            thumbnailJPEGData: thumbnailJPEGData,
            sceneContextJPEGData: sceneContextJPEGData,
            opticsLocked: opticsLocked,
            calibratedPrototypes: calibratedPrototypes,
            latePreRollSilence: latePreRollSilence,
            inferenceModeOverride: inferenceModeOverride
        )
    }

    public func classifySamples(
        samples: [Float],
        inverseFilter: [Float]?,
        sampleRateHz: Double = 48_000.0,
        preRollFrames: Int = 7_200,
        activeFrames: Int = 9_600,
        clippingCeilingDBFS: Double = -0.5,
        scanSequenceNumber: Int? = nil,
        batchRunID: String? = nil,
        batchScanIndex: Int? = nil,
        batchTotalCount: Int? = nil,
        geometryCondition: String? = nil,
        controlSeriesTag: String? = nil,
        aeAfWbLockState: String? = nil,
        targetLockState: String? = nil,
        targetLockScore: Double? = nil,
        thumbnailJPEGData: Data? = nil,
        sceneContextJPEGData: Data? = nil,
        opticsLocked: Bool = false,
        calibratedPrototypes: [CalibratedAcousticPrototype] = [],
        latePreRollSilence: [Float]? = nil,
        inferenceModeOverride: ConsumerInferenceMode? = nil
    ) -> ConsumerScanItem {
        let activeMode = inferenceModeOverride ?? inferenceMode
        let visual = visualAnalyzer.analyze(jpegData: thumbnailJPEGData, sceneContextJPEGData: sceneContextJPEGData)
        let vision = visionExtractor.extract(jpegData: thumbnailJPEGData, sceneContextJPEGData: sceneContextJPEGData)
        let features = extractFeatures(
            samples: samples,
            inverseFilter: inverseFilter,
            sampleRateHz: sampleRateHz,
            preRollFrames: preRollFrames,
            activeFrames: activeFrames,
            clippingCeilingDBFS: clippingCeilingDBFS,
            visual: visual,
            vision: vision,
            opticsLocked: opticsLocked,
            latePreRollSilence: latePreRollSilence
        )
        let (deltaEmpty, deltaWater) = Self.computeBaselineShifts(
            features: features,
            geometryCondition: geometryCondition,
            prototypes: calibratedPrototypes
        )
        let baselineMismatch = (deltaEmpty?.compatible == false) || (deltaWater?.compatible == false)
        let bubbleDetected = Self.detectMicroBubbleScatter(
            features: features,
            geometryCondition: geometryCondition,
            prototypes: calibratedPrototypes
        )
        let resolvedOpticsState = aeAfWbLockState ?? (
            visual.hint == .audioOnly ? "HEADLESS" : (opticsLocked ? "LOCKED" : "UNLOCKED_CONTINUOUS")
        )
        let resolvedTargetState = targetLockState ?? (
            visual.hint == .audioOnly ? "HEADLESS" : "CAPTURED"
        )

        // Compute raw frozen reference scores across ALL profiles first so Gate R1 always logs them
        let fullLibraryScores = computeFrozenCandidateDistances(
            profiles: referenceLibrary,
            features: features
        )
        let allEntries = fullLibraryScores.map {
            CandidateScoreEntry(profileID: $0.profile.id, displayName: $0.profile.displayName, distance: $0.distance)
        }

        // 1. Visual Positive-Container Gate — Rejects Walls, Furniture, Floors, & Non-Liquid Objects
        if visual.hint == .solidOrNonLiquid {
            return buildSolidNonLiquidItem(
                features: features,
                scanSequenceNumber: scanSequenceNumber,
                batchRunID: batchRunID,
                batchScanIndex: batchScanIndex,
                batchTotalCount: batchTotalCount,
                geometryCondition: geometryCondition,
                controlSeriesTag: controlSeriesTag,
                aeAfWbLockState: resolvedOpticsState,
                targetLockState: resolvedTargetState,
                targetLockScore: targetLockScore,
                gateDecision: "REJECTED_NON_LIQUID_OPTICS",
                rejectionReason: String(
                    format: "NON_LIQUID_SURFACE: vesselConf=%.2f, solidConf=%.2f",
                    visual.vesselConfidence,
                    visual.solidSurfaceConfidence
                ),
                allEntries: allEntries,
                thumbnailJPEGData: thumbnailJPEGData
            )
        }

        // 2. Independent Audio Signal Quality Verification (`INVALID_MEASUREMENT` — never deletes raw telemetry)
        let hasInverseDeconv = (inverseFilter != nil && !(inverseFilter?.isEmpty ?? true))
        let insufficientFrames = samples.count < (preRollFrames + activeFrames / 2)
        let hasClipping = features.clippedSamples > 8
        let hasLowActiveSNR = features.activeSNRDB < minimumSNRDB
        let hasLowTailSNR = hasInverseDeconv && features.tailSNRDB < 2.2

        if insufficientFrames || hasClipping || hasLowActiveSNR || hasLowTailSNR {
            let reasonNote: String
            let machineReason: String
            if insufficientFrames {
                reasonNote = "The audio capture ended early before completing the test sweep. Hold steady in a quiet spot and try again."
                machineReason = "INSUFFICIENT_CAPTURE_FRAMES: \(samples.count) frames"
            } else if hasClipping {
                reasonNote = "The sound reflection was too loud or clipped. Lower your volume slightly and try again."
                machineReason = String(
                    format: "ADC_CLIPPING: %d samples >= %.1f dBFS",
                    features.clippedSamples,
                    clippingCeilingDBFS
                )
            } else if hasLowActiveSNR {
                reasonNote = "Ambient noise was too close to the acoustic test wave. Move to a quieter spot, hold steady near the container, and scan again."
                machineReason = String(
                    format: "LOW_ACTIVE_SNR: %.2f dB < %.2f dB",
                    features.activeSNRDB,
                    minimumSNRDB
                )
            } else {
                reasonNote = "Container echo did not rise clearly above ambient background noise. Move closer to the container in a quiet room and scan again."
                machineReason = String(
                    format: "LOW_DECONVOLVED_TAIL_SNR: %.2f dB < 2.20 dB (echo buried in noise floor)",
                    features.tailSNRDB
                )
            }
            return ConsumerScanItem(
                scanSequenceNumber: scanSequenceNumber,
                batchRunID: batchRunID,
                batchScanIndex: batchScanIndex,
                batchTotalCount: batchTotalCount,
                geometryCondition: geometryCondition,
                controlSeriesTag: controlSeriesTag,
                aeAfWbLockState: resolvedOpticsState,
                targetLockState: resolvedTargetState,
                targetLockScore: targetLockScore,
                gateDecision: "REJECTED_SIGNAL_QUALITY",
                rejectionReason: machineReason,
                status: .unclearScan,
                title: "Scan Unclear",
                formulaDisplay: "Signal Check",
                statusBadgeText: "Rescan Needed",
                confidencePercent: nil,
                scientificNote: reasonNote,
                constituents: [],
                tuneProfile: Self.buildAcousticSignatureTune(features: features, formula: "Signal Echo"),
                measuredPeakHz: features.dominantPeakHz,
                measuredCentroidHz: features.spectralCentroidHz,
                measuredDecayDBPerSec: features.decaySlopeDBPerSec,
                measuredFeatures: features,
                topCandidateName: allEntries.first?.displayName,
                topCandidateDistance: allEntries.first?.distance,
                runnerUpTitle: allEntries.dropFirst().first?.displayName,
                secondCandidateDistance: allEntries.dropFirst().first?.distance,
                winningMargin: (allEntries.count > 1) ? (allEntries[1].distance - allEntries[0].distance) : nil,
                allCandidateDistances: allEntries,
                thumbnailJPEGData: thumbnailJPEGData,
                modeAScreeningState: .rejectedSignalQuality,
                deltaEmptyBaseline: deltaEmpty,
                deltaWaterBaseline: deltaWater
            )
        }

        if baselineMismatch {
            let mismatchCode = deltaEmpty?.rejectionCode ?? deltaWater?.rejectionCode ?? "REJECTED_BASELINE_MISMATCH"
            return buildUnmatchedItem(
                features: features,
                scanSequenceNumber: scanSequenceNumber,
                batchRunID: batchRunID,
                batchScanIndex: batchScanIndex,
                batchTotalCount: batchTotalCount,
                geometryCondition: geometryCondition,
                controlSeriesTag: controlSeriesTag,
                aeAfWbLockState: resolvedOpticsState,
                targetLockState: resolvedTargetState,
                targetLockScore: targetLockScore,
                gateDecision: "REJECTED_BASELINE_MISMATCH",
                rejectionReason: mismatchCode,
                topEntry: allEntries.first,
                secondEntry: allEntries.dropFirst().first,
                allEntries: allEntries,
                thumbnailJPEGData: thumbnailJPEGData,
                modeAScreeningState: .rejectedBaselineMismatch,
                deltaEmptyBaseline: deltaEmpty,
                deltaWaterBaseline: deltaWater
            )
        }

        // 3. Calibrated Indirect Inference & Differential Baseline Normalization (`Delta X_empty` / `Delta X_water`)
        if !calibratedPrototypes.isEmpty,
           let calibratedResult = matchCalibratedPrototypes(
               features: features,
               scanSequenceNumber: scanSequenceNumber,
               batchRunID: batchRunID,
               batchScanIndex: batchScanIndex,
               batchTotalCount: batchTotalCount,
               geometryCondition: geometryCondition,
               controlSeriesTag: controlSeriesTag,
               aeAfWbLockState: resolvedOpticsState,
               targetLockState: resolvedTargetState,
               targetLockScore: targetLockScore,
               hasOptics: visual.hint != .audioOnly,
               prototypes: calibratedPrototypes,
               allFrozenEntries: allEntries,
               thumbnailJPEGData: thumbnailJPEGData,
               deltaEmpty: deltaEmpty,
               deltaWater: deltaWater,
               bubbleDetected: bubbleDetected,
               vision: vision,
               inferenceMode: activeMode
           ) {
            return calibratedResult
        }

        // 3B. v0.5.0 Multi-Modal Sensor Fusion (VisionFeatureVector + DifferentialBaselineVector Mahalanobis Engine)
        if let fused = fusionClassifier.evaluate(
            features: features,
            visual: visual,
            vision: vision,
            deltaEmpty: deltaEmpty,
            deltaWater: deltaWater,
            bubbleDetected: bubbleDetected,
            hasInverseDeconv: hasInverseDeconv,
            inferenceMode: activeMode
        ) {
            let runnerUp = fused.rankedCandidates.dropFirst().first
            return ConsumerScanItem(
                scanSequenceNumber: scanSequenceNumber,
                batchRunID: batchRunID,
                batchScanIndex: batchScanIndex,
                batchTotalCount: batchTotalCount,
                geometryCondition: geometryCondition,
                controlSeriesTag: controlSeriesTag,
                aeAfWbLockState: resolvedOpticsState,
                targetLockState: resolvedTargetState,
                targetLockScore: targetLockScore,
                gateDecision: fused.gateDecision,
                rejectionReason: nil,
                status: .referenceMatch,
                title: fused.profile.displayName,
                formulaDisplay: fused.profile.formulaDisplay,
                statusBadgeText: fused.statusBadgeText,
                confidencePercent: fused.confidencePercent,
                scientificNote: fused.scientificNote,
                constituents: fused.profile.constituents,
                tuneProfile: fused.profile.tuneProfile,
                measuredPeakHz: features.dominantPeakHz,
                measuredCentroidHz: features.spectralCentroidHz,
                measuredDecayDBPerSec: features.decaySlopeDBPerSec,
                measuredFeatures: features,
                topCandidateName: fused.profile.displayName,
                topCandidateDistance: fused.attribution.mahalanobisDistance,
                runnerUpTitle: runnerUp?.displayName,
                secondCandidateDistance: runnerUp?.distance,
                winningMargin: fused.attribution.winningMargin,
                allCandidateDistances: fused.rankedCandidates.isEmpty ? allEntries : fused.rankedCandidates,
                thumbnailJPEGData: thumbnailJPEGData,
                modeAScreeningState: fused.screeningState,
                deltaEmptyBaseline: deltaEmpty,
                deltaWaterBaseline: deltaWater,
                fusionAttribution: fused.attribution
            )
        }

        let clearGuidance = (activeMode == .multiModalFusion)
            ? MultiModalFusionClassifier.uncalibratedClearLiquidGuidance(
                features: features,
                vision: vision,
                deltaEmpty: deltaEmpty,
                deltaWater: deltaWater,
                bubbleDetected: bubbleDetected
            )
            : nil

        // If an EMPTY_CONTAINER baseline is calibrated under matching geometry and shows a clear liquid mass-loading shift
        // (`|Delta f_i| >= 1.2%`) without matching a specific calibrated class standard, report `LIQUID_LOADED` screening
        if let de = deltaEmpty, de.compatible {
            let validShifts = de.relativeFrequencyShifts.compactMap { $0 }.map { abs($0) }
            if let maxShift = validShifts.max(), maxShift >= 0.012 {
                let resolvedScreening: ModeAScreeningState = bubbleDetected ? .bubbleScatterDetected : .liquidLoaded
                let badge = bubbleDetected
                    ? "MODE_A Screening • Bubble Scatter Detected"
                    : "MODE_A Screening • Liquid Loaded"
                let titleText = bubbleDetected ? "Bubble-Active Liquid" : "Liquid Loaded (Unmatched Class)"
                let noteText = String(
                    format: "Calibrated container shift detected (max |Δf/f| = %.2f%% vs. Empty Container%@). No uncalibrated molecular or viscosity claim is asserted.",
                    maxShift * 100.0,
                    bubbleDetected ? "; micro-bubble high-frequency scatter detected" : ""
                )
                return ConsumerScanItem(
                    scanSequenceNumber: scanSequenceNumber,
                    batchRunID: batchRunID,
                    batchScanIndex: batchScanIndex,
                    batchTotalCount: batchTotalCount,
                    geometryCondition: geometryCondition,
                    controlSeriesTag: controlSeriesTag,
                    aeAfWbLockState: resolvedOpticsState,
                    targetLockState: resolvedTargetState,
                    targetLockScore: targetLockScore,
                    gateDecision: resolvedScreening.rawValue,
                    rejectionReason: "UNCALIBRATED_CLASS_HELD",
                    status: .unmatchedSignature,
                    title: titleText,
                    formulaDisplay: resolvedScreening.rawValue,
                    statusBadgeText: badge,
                    confidencePercent: nil,
                    scientificNote: noteText,
                    constituents: [],
                    tuneProfile: Self.buildAcousticSignatureTune(features: features, formula: "Liquid Loaded"),
                    measuredPeakHz: features.dominantPeakHz,
                    measuredCentroidHz: features.spectralCentroidHz,
                    measuredDecayDBPerSec: features.decaySlopeDBPerSec,
                    measuredFeatures: features,
                    topCandidateName: allEntries.first?.displayName,
                    topCandidateDistance: allEntries.first?.distance,
                    runnerUpTitle: allEntries.dropFirst().first?.displayName,
                    secondCandidateDistance: allEntries.dropFirst().first?.distance,
                    winningMargin: (allEntries.count > 1) ? (allEntries[1].distance - allEntries[0].distance) : nil,
                    allCandidateDistances: allEntries,
                    thumbnailJPEGData: thumbnailJPEGData,
                    modeAScreeningState: resolvedScreening,
                    deltaEmptyBaseline: deltaEmpty,
                    deltaWaterBaseline: deltaWater,
                    fusionAttribution: clearGuidance
                )
            }
        }

        // 4. Layer 2 Acoustic Specular Flat-Surface / 2D Spoof Guard
        let isFlatNonCavitySpectrum = (visual.vesselConfidence < 0.16 && features.spectralFlatness > 0.58 && features.peakProminenceDB < 7.5)
            || (deltaEmpty == nil && features.spectralFlatness >= 0.48 && features.peakProminenceDB < 11.5)
        if visual.hint != .audioOnly &&
            !visual.hasBarcode &&
            isFlatNonCavitySpectrum {
            return buildSolidNonLiquidItem(
                features: features,
                scanSequenceNumber: scanSequenceNumber,
                batchRunID: batchRunID,
                batchScanIndex: batchScanIndex,
                batchTotalCount: batchTotalCount,
                geometryCondition: geometryCondition,
                controlSeriesTag: controlSeriesTag,
                aeAfWbLockState: resolvedOpticsState,
                targetLockState: resolvedTargetState,
                targetLockScore: targetLockScore,
                gateDecision: "REJECTED_NON_LIQUID_ACOUSTIC_FLATNESS",
                rejectionReason: String(
                    format: "FLAT_SPECULAR_REFLECTION: flatness=%.2f, prominence=%.1f dB",
                    features.spectralFlatness,
                    features.peakProminenceDB
                ),
                allEntries: allEntries,
                thumbnailJPEGData: thumbnailJPEGData
            )
        }

        // 5. Frozen Reference Evaluation + Stringent Ambiguity Gate (Repeatability Gate R1 — FROZEN)
        let eligibleProfiles = resolveEligibleCandidates(for: visual.hint, features: features)
        let scored = computeFrozenCandidateDistances(profiles: eligibleProfiles, features: features)
        let scoredEntries = scored.map {
            CandidateScoreEntry(profileID: $0.profile.id, displayName: $0.profile.displayName, distance: $0.distance)
        }

        guard let best = scored.first else {
            return buildUnmatchedItem(
                features: features,
                scanSequenceNumber: scanSequenceNumber,
                batchRunID: batchRunID,
                batchScanIndex: batchScanIndex,
                batchTotalCount: batchTotalCount,
                geometryCondition: geometryCondition,
                controlSeriesTag: controlSeriesTag,
                aeAfWbLockState: resolvedOpticsState,
                targetLockState: resolvedTargetState,
                targetLockScore: targetLockScore,
                gateDecision: "HELD_NO_ELIGIBLE_PROFILE",
                rejectionReason: "NO_ELIGIBLE_CANDIDATE",
                topEntry: allEntries.first,
                secondEntry: allEntries.dropFirst().first,
                allEntries: allEntries,
                thumbnailJPEGData: thumbnailJPEGData
            )
        }

        let secondEntry: CandidateScoreEntry? = scoredEntries.count > 1
            ? scoredEntries[1]
            : allEntries.first(where: { $0.profileID != best.profile.id })
        let secondDistance = secondEntry?.distance ?? (best.distance + 0.60)
        let margin = secondDistance - best.distance

        let isExplicitLabelOrOptics = (scored.count == 1 && visual.hint != .audioOnly && visual.hint != .openVesselAqueousOrGeneral)

        // Phase R2-B (`LA-R2-SPEC-001` Sec. 3.1.4): On real deconvolved airborne MODE_A scans without an explicit optical label
        // or calibrated container standard, never assert uncalibrated chemical or viscosity identity!
        // Only physical `BUBBLE_SCATTER_DETECTED` or `NO_VALIDATED_MATCH` (`Unmatched Liquid`) may be emitted.
        if hasInverseDeconv && !isExplicitLabelOrOptics {
            let screenState: ModeAScreeningState = bubbleDetected ? .bubbleScatterDetected : .noValidatedMatch
            let gateCode = bubbleDetected ? "MODE_A_BUBBLE_SCATTER_DETECTED" : "HELD_MODE_A_UNCALIBRATED_SCREENING"
            let holdReason = bubbleDetected
                ? "BUBBLE_SCATTER_DETECTED: physical micro-bubble/effervescence scatter observed (non-specific without reference calibration)"
                : "MODE_A_SCREENING_BOUNDARY: uncalibrated airborne reflection requires container baseline (Delta X_empty / Delta X_water)"
            return buildUnmatchedItem(
                features: features,
                scanSequenceNumber: scanSequenceNumber,
                batchRunID: batchRunID,
                batchScanIndex: batchScanIndex,
                batchTotalCount: batchTotalCount,
                geometryCondition: geometryCondition,
                controlSeriesTag: controlSeriesTag,
                aeAfWbLockState: resolvedOpticsState,
                targetLockState: resolvedTargetState,
                targetLockScore: targetLockScore,
                gateDecision: gateCode,
                rejectionReason: holdReason,
                topEntry: CandidateScoreEntry(profileID: best.profile.id, displayName: best.profile.displayName, distance: best.distance),
                secondEntry: secondEntry,
                allEntries: allEntries,
                thumbnailJPEGData: thumbnailJPEGData,
                modeAScreeningState: screenState,
                deltaEmptyBaseline: deltaEmpty,
                deltaWaterBaseline: deltaWater,
                fusionAttribution: clearGuidance
            )
        }

        let effectiveThreshold = isExplicitLabelOrOptics ? 3.10 : distanceThreshold

        // STRINGENT AMBIGUITY GATE: Weak match OR close first/second candidates -> UNMATCHED (never force a chemical!)
        let failsDistance = best.distance > effectiveThreshold
        let failsMargin = !isExplicitLabelOrOptics && margin < minimumWinningMargin
        if failsDistance || failsMargin {
            let holdDecision: String
            let holdReason: String
            if failsDistance && failsMargin {
                holdDecision = "HELD_AMBIGUITY_DISTANCE_AND_MARGIN"
                holdReason = String(
                    format: "AMBIGUITY_DISTANCE_AND_MARGIN: d=%.3f > %.2f AND margin=+%.3f < %.2f",
                    best.distance,
                    effectiveThreshold,
                    margin,
                    minimumWinningMargin
                )
            } else if failsDistance {
                holdDecision = "HELD_AMBIGUITY_DISTANCE"
                holdReason = String(
                    format: "AMBIGUITY_DISTANCE: d=%.3f > %.2f",
                    best.distance,
                    effectiveThreshold
                )
            } else {
                holdDecision = "HELD_AMBIGUITY_MARGIN"
                holdReason = String(
                    format: "AMBIGUITY_MARGIN: margin=+%.3f < %.2f",
                    margin,
                    minimumWinningMargin
                )
            }
            return buildUnmatchedItem(
                features: features,
                scanSequenceNumber: scanSequenceNumber,
                batchRunID: batchRunID,
                batchScanIndex: batchScanIndex,
                batchTotalCount: batchTotalCount,
                geometryCondition: geometryCondition,
                controlSeriesTag: controlSeriesTag,
                aeAfWbLockState: resolvedOpticsState,
                targetLockState: resolvedTargetState,
                targetLockScore: targetLockScore,
                gateDecision: holdDecision,
                rejectionReason: holdReason,
                topEntry: CandidateScoreEntry(profileID: best.profile.id, displayName: best.profile.displayName, distance: best.distance),
                secondEntry: secondEntry,
                allEntries: allEntries,
                thumbnailJPEGData: thumbnailJPEGData,
                modeAScreeningState: bubbleDetected ? .bubbleScatterDetected : .noValidatedMatch,
                deltaEmptyBaseline: deltaEmpty,
                deltaWaterBaseline: deltaWater
            )
        }

        let rawSimilarity = exp(-0.38 * best.distance) * (0.84 + 0.16 * min(1.0, margin / 0.35))
        let snrFactor = min(1.0, max(0.82, features.activeSNRDB / 22.0))
        let boundedConfidence = min(93, max(70, Int(round(rawSimilarity * snrFactor * 94.0))))
        let runnerUpSim = secondEntry.map { min(89, max(35, Int(round(exp(-0.38 * $0.distance) * 92.0)))) }

        return ConsumerScanItem(
            scanSequenceNumber: scanSequenceNumber,
            batchRunID: batchRunID,
            batchScanIndex: batchScanIndex,
            batchTotalCount: batchTotalCount,
            geometryCondition: geometryCondition,
            controlSeriesTag: controlSeriesTag,
            aeAfWbLockState: resolvedOpticsState,
            targetLockState: resolvedTargetState,
            targetLockScore: targetLockScore,
            gateDecision: "PASS_REFERENCE_MATCH",
            rejectionReason: nil,
            status: .referenceMatch,
            title: best.profile.displayName,
            formulaDisplay: best.profile.formulaDisplay,
            statusBadgeText: "Experimental Reference Match • \(boundedConfidence)% Similarity",
            confidencePercent: boundedConfidence,
            scientificNote: "Passed stringent separation gate (d = \(String(format: "%.2f", best.distance)), margin = +\(String(format: "%.2f", margin))) against frozen \(best.profile.displayName.lowercased()) profile.",
            constituents: best.profile.constituents,
            tuneProfile: best.profile.tuneProfile,
            measuredPeakHz: features.dominantPeakHz,
            measuredCentroidHz: features.spectralCentroidHz,
            measuredDecayDBPerSec: features.decaySlopeDBPerSec,
            measuredFeatures: features,
            topCandidateName: best.profile.displayName,
            topCandidateDistance: best.distance,
            runnerUpTitle: secondEntry?.displayName,
            runnerUpSimilarityPercent: runnerUpSim,
            secondCandidateDistance: secondEntry?.distance,
            winningMargin: margin,
            allCandidateDistances: allEntries,
            thumbnailJPEGData: thumbnailJPEGData,
            modeAScreeningState: bubbleDetected ? .bubbleScatterDetected : .calibratedClassCandidate,
            deltaEmptyBaseline: deltaEmpty,
            deltaWaterBaseline: deltaWater
        )
    }

    public func computeFrozenCandidateDistances(
        profiles: [ReferenceLiquidProfile],
        features: ExtractedConsumerFeatures
    ) -> [(profile: ReferenceLiquidProfile, distance: Double)] {
        profiles.map { prof in
            let dPeak = (features.dominantPeakHz - prof.expectedPeakHz) / 580.0
            let dCent = (features.spectralCentroidHz - prof.expectedCentroidHz) / 650.0
            let dBand = (features.midToHighBandDB - prof.expectedMidToHighDB) / 3.8
            // Phase R2-C (`LA-R2-C-PLAN-001` Sec. 2.3): Log-ratio decay normalization prevents diagnostic distances
            // from ballooning (d = 6.9..118.1) against unclamped Schroeder EDC decay rates while preserving R1 margins
            let dDecay = abs(log(max(1.0, features.decaySlopeDBPerSec) / max(1.0, prof.expectedDecayDBPerSec))) / 0.42
            let dScatter = (features.highFreqBubbleScatterDB - prof.expectedHighScatterDB) / 3.2
            let rawDist = sqrt(
                0.26 * dPeak * dPeak +
                0.22 * dCent * dCent +
                0.16 * dBand * dBand +
                0.14 * dDecay * dDecay +
                0.22 * dScatter * dScatter
            )
            return (prof, rawDist)
        }.sorted { $0.distance < $1.distance }
    }

    // MARK: - Centroid-Averaged Calibrated Indirect Inference

    public static func calibratedScatteringDistance(
        _ a: ExtractedConsumerFeatures,
        _ b: ExtractedConsumerFeatures,
        includeOptics: Bool = false
    ) -> Double {
        var subBandSq = 0.0
        let count = min(a.subBandShapeDB.count, b.subBandShapeDB.count)
        if count > 0 {
            for k in 0..<count {
                let diff = (a.subBandShapeDB[k] - b.subBandShapeDB[k]) / 2.8
                subBandSq += diff * diff
            }
            subBandSq /= Double(count)
        }

        let dPeak = (a.dominantPeakHz - b.dominantPeakHz) / 460.0
        let dCent = (a.spectralCentroidHz - b.spectralCentroidHz) / 500.0
        // Scale unclamped Schroeder EDC decay logarithmically so high-rate decays (e.g., 500..6000 dB/s) compare proportionally
        let dDecay = log(max(20.0, a.decaySlopeDBPerSec) / max(20.0, b.decaySlopeDBPerSec)) / 0.42
        let dScatter = (a.highFreqBubbleScatterDB - b.highFreqBubbleScatterDB) / 3.4
        let dCavity = (a.cavityMultipathDB - b.cavityMultipathDB) / 3.4
        let dEcho = (a.echoReturnDB - b.echoReturnDB) / 4.5

        let macroSq = 0.24 * dPeak * dPeak +
            0.22 * dCent * dCent +
            0.14 * dDecay * dDecay +
            0.16 * dScatter * dScatter +
            0.12 * dCavity * dCavity +
            0.12 * dEcho * dEcho

        let baseAcousticSq = 0.55 * subBandSq + 0.45 * macroSq
        let modalSq: Double? = {
            guard let mvA = a.modalVector, let mvB = b.modalVector else { return nil }
            var shifts: [Double] = []
            var usedB = Set<Int>()
            for i in 0..<4 where mvA.validityMask[i] == 1 {
                guard let fs = mvA.frequenciesHz[i], fs > 0 else { continue }
                var bestJ: Int?
                var bestAbs = Double.infinity
                for j in 0..<4 where !usedB.contains(j) && mvB.validityMask[j] == 1 {
                    guard let fr = mvB.frequenciesHz[j], fr > 0 else { continue }
                    let d = abs(fs - fr)
                    if d <= max(450.0, 0.28 * fr) && d < bestAbs {
                        bestAbs = d
                        bestJ = j
                    }
                }
                if let rIdx = bestJ, let fr = mvB.frequenciesHz[rIdx], fr > 0 {
                    usedB.insert(rIdx)
                    shifts.append(abs((fs - fr) / fr))
                } else {
                    shifts.append(0.12)
                }
            }
            guard !shifts.isEmpty else { return nil }
            let meanShift = shifts.reduce(0.0, +) / Double(shifts.count)
            return pow(meanShift / 0.032, 2.0)
        }()
        let acousticSq = modalSq.map { 0.50 * baseAcousticSq + 0.50 * $0 } ?? baseAcousticSq
        guard includeOptics else {
            return sqrt(acousticSq)
        }

        let dBright = (a.opticalCenterBrightness - b.opticalCenterBrightness) / 0.14
        let dIntCon = (a.opticalInteriorContrast - b.opticalInteriorContrast) / 0.035
        let dRimCon = (a.opticalRimContrast - b.opticalRimContrast) / 0.035
        let opticalSq = 0.35 * dBright * dBright + 0.40 * dIntCon * dIntCon + 0.25 * dRimCon * dRimCon

        let optWeight = (a.opticsLocked && b.opticsLocked) ? 0.30 : 0.16
        return sqrt((1.0 - optWeight) * acousticSq + optWeight * opticalSq)
    }

    private static func averagePrototypeCentroid(_ items: [ExtractedConsumerFeatures]) -> ExtractedConsumerFeatures {
        guard let first = items.first, items.count > 1 else {
            return items.first ?? ExtractedConsumerFeatures(
                activeSNRDB: 20, peakDBFS: -12, clippedSamples: 0,
                dominantPeakHz: 2220, spectralCentroidHz: 2560,
                midToHighBandDB: 3.8, decaySlopeDBPerSec: 76
            )
        }
        let n = Double(items.count)
        let bandLen = first.subBandShapeDB.count
        var avgBands = [Double](repeating: 0.0, count: bandLen)
        for item in items where item.subBandShapeDB.count == bandLen {
            for k in 0..<bandLen { avgBands[k] += item.subBandShapeDB[k] / n }
        }
        return ExtractedConsumerFeatures(
            activeSNRDB: items.reduce(0.0) { $0 + $1.activeSNRDB } / n,
            activeRMSDBFS: items.reduce(0.0) { $0 + $1.activeRMSDBFS } / n,
            peakDBFS: items.reduce(0.0) { $0 + $1.peakDBFS } / n,
            clippedSamples: 0,
            dominantPeakHz: items.reduce(0.0) { $0 + $1.dominantPeakHz } / n,
            primaryPeakAmplitudeDB: items.reduce(0.0) { $0 + $1.primaryPeakAmplitudeDB } / n,
            secondaryPeaksHz: first.secondaryPeaksHz,
            secondaryPeakAmplitudesDB: first.secondaryPeakAmplitudesDB,
            spectralCentroidHz: items.reduce(0.0) { $0 + $1.spectralCentroidHz } / n,
            midToHighBandDB: items.reduce(0.0) { $0 + $1.midToHighBandDB } / n,
            decaySlopeDBPerSec: items.reduce(0.0) { $0 + $1.decaySlopeDBPerSec } / n,
            highFreqBubbleScatterDB: items.reduce(0.0) { $0 + $1.highFreqBubbleScatterDB } / n,
            spectralFlatness: items.reduce(0.0) { $0 + $1.spectralFlatness } / n,
            peakProminenceDB: items.reduce(0.0) { $0 + $1.peakProminenceDB } / n,
            cavityMultipathDB: items.reduce(0.0) { $0 + $1.cavityMultipathDB } / n,
            subBandShapeDB: avgBands,
            echoReturnDB: items.reduce(0.0) { $0 + $1.echoReturnDB } / n,
            echoRMSDBFS: items.reduce(0.0) { $0 + $1.echoRMSDBFS } / n,
            tailSNRDB: items.reduce(0.0) { $0 + $1.tailSNRDB } / n,
            alignmentOffsetSamples: 0,
            echoArrivalDelayMs: items.reduce(0.0) { $0 + $1.echoArrivalDelayMs } / n,
            intraScanPersistenceRatio: items.reduce(0.0) { $0 + $1.intraScanPersistenceRatio } / n,
            featureVectorChecksum: first.featureVectorChecksum,
            opticalCenterBrightness: items.reduce(0.0) { $0 + $1.opticalCenterBrightness } / n,
            opticalInteriorContrast: items.reduce(0.0) { $0 + $1.opticalInteriorContrast } / n,
            opticalRimContrast: items.reduce(0.0) { $0 + $1.opticalRimContrast } / n,
            opticsLocked: items.allSatisfy(\.opticsLocked),
            latePreRollNoiseDBFS: items.reduce(0.0) { $0 + $1.latePreRollNoiseDBFS } / n,
            preRollExcessHFDB: items.reduce(0.0) { $0 + $1.preRollExcessHFDB } / n,
            modalVector: first.modalVector
        )
    }

    private func displayTitleForTarget(_ targetID: String) -> String {
        if targetID == CalibratedAcousticPrototype.emptyContainerTargetID {
            return "Empty Container"
        }
        if targetID == CalibratedAcousticPrototype.solidSurfaceTargetID {
            return "Solid / Non-Liquid Material"
        }
        return ReferenceLiquidProfile.fusionLibrary.first(where: { $0.id == targetID })?.displayName ?? targetID
    }

    /// Re-evaluates an existing persisted `ConsumerScanItem` against newly saved `CalibratedAcousticPrototype`s
    /// without altering immutable raw measured features, timestamps, thumbnails, or sequence identifiers.
    public func reevaluateExistingItem(
        _ item: ConsumerScanItem,
        calibratedPrototypes: [CalibratedAcousticPrototype],
        inferenceModeOverride: ConsumerInferenceMode? = nil
    ) -> ConsumerScanItem {
        guard var features = item.measuredFeatures, item.status != .unclearScan else {
            return item
        }
        let activeMode = inferenceModeOverride ?? inferenceMode
        let visual = visualAnalyzer.analyze(jpegData: item.thumbnailJPEGData)
        let vision = features.visionFeatures ?? visionExtractor.extract(jpegData: item.thumbnailJPEGData)
        if features.visionFeatures == nil && vision.hasCameraFrame {
            features = ExtractedConsumerFeatures(
                activeSNRDB: features.activeSNRDB,
                activeRMSDBFS: features.activeRMSDBFS,
                peakDBFS: features.peakDBFS,
                clippedSamples: features.clippedSamples,
                dominantPeakHz: features.dominantPeakHz,
                primaryPeakAmplitudeDB: features.primaryPeakAmplitudeDB,
                secondaryPeaksHz: features.secondaryPeaksHz,
                secondaryPeakAmplitudesDB: features.secondaryPeakAmplitudesDB,
                spectralCentroidHz: features.spectralCentroidHz,
                midToHighBandDB: features.midToHighBandDB,
                decaySlopeDBPerSec: features.decaySlopeDBPerSec,
                highFreqBubbleScatterDB: features.highFreqBubbleScatterDB,
                spectralFlatness: features.spectralFlatness,
                peakProminenceDB: features.peakProminenceDB,
                cavityMultipathDB: features.cavityMultipathDB,
                subBandShapeDB: features.subBandShapeDB,
                echoReturnDB: features.echoReturnDB,
                echoRMSDBFS: features.echoRMSDBFS,
                tailSNRDB: features.tailSNRDB,
                alignmentOffsetSamples: features.alignmentOffsetSamples,
                echoArrivalDelayMs: features.echoArrivalDelayMs,
                intraScanPersistenceRatio: features.intraScanPersistenceRatio,
                featureVectorChecksum: features.featureVectorChecksum,
                opticalCenterBrightness: features.opticalCenterBrightness,
                opticalInteriorContrast: features.opticalInteriorContrast,
                opticalRimContrast: features.opticalRimContrast,
                opticsLocked: features.opticsLocked,
                latePreRollNoiseDBFS: features.latePreRollNoiseDBFS,
                preRollExcessHFDB: features.preRollExcessHFDB,
                modalVector: features.modalVector,
                visionFeatures: vision
            )
        }
        let (deltaEmpty, deltaWater) = Self.computeBaselineShifts(
            features: features,
            geometryCondition: item.geometryCondition,
            prototypes: calibratedPrototypes
        )
        let bubbleDetected = Self.detectMicroBubbleScatter(
            features: features,
            geometryCondition: item.geometryCondition,
            prototypes: calibratedPrototypes
        )
        let fullLibraryScores = computeFrozenCandidateDistances(
            profiles: referenceLibrary,
            features: features
        )
        let allEntries = fullLibraryScores.map {
            CandidateScoreEntry(profileID: $0.profile.id, displayName: $0.profile.displayName, distance: $0.distance)
        }

        if (deltaEmpty?.compatible == false) || (deltaWater?.compatible == false) {
            let mismatchCode = deltaEmpty?.rejectionCode ?? deltaWater?.rejectionCode ?? "REJECTED_BASELINE_MISMATCH"
            return ConsumerScanItem(
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
                gateDecision: "REJECTED_BASELINE_MISMATCH",
                rejectionReason: mismatchCode,
                status: .unmatchedSignature,
                title: "Unmatched Liquid",
                formulaDisplay: "Baseline Mismatch",
                statusBadgeText: "MODE_A Screening • Baseline Mismatch",
                confidencePercent: nil,
                scientificNote: "Container geometry does not match the saved calibration baseline (\(mismatchCode)).",
                constituents: [],
                tuneProfile: item.tuneProfile,
                measuredPeakHz: item.measuredPeakHz,
                measuredCentroidHz: item.measuredCentroidHz,
                measuredDecayDBPerSec: item.measuredDecayDBPerSec,
                measuredFeatures: features,
                topCandidateName: allEntries.first?.displayName,
                topCandidateDistance: allEntries.first?.distance,
                runnerUpTitle: allEntries.dropFirst().first?.displayName,
                secondCandidateDistance: allEntries.dropFirst().first?.distance,
                winningMargin: (allEntries.count > 1) ? (allEntries[1].distance - allEntries[0].distance) : nil,
                allCandidateDistances: allEntries,
                thumbnailJPEGData: item.thumbnailJPEGData,
                isConditioningCycle: item.isConditioningCycle,
                conditioningTag: item.conditioningTag,
                modeAScreeningState: .rejectedBaselineMismatch,
                deltaEmptyBaseline: deltaEmpty,
                deltaWaterBaseline: deltaWater
            )
        }

        if let calibratedResult = matchCalibratedPrototypes(
            features: features,
            scanSequenceNumber: item.scanSequenceNumber,
            batchRunID: item.batchRunID,
            batchScanIndex: item.batchScanIndex,
            batchTotalCount: item.batchTotalCount,
            geometryCondition: item.geometryCondition,
            controlSeriesTag: item.controlSeriesTag,
            aeAfWbLockState: item.aeAfWbLockState,
            targetLockState: item.targetLockState,
            targetLockScore: item.targetLockScore,
            hasOptics: item.thumbnailJPEGData != nil,
            prototypes: calibratedPrototypes,
            allFrozenEntries: allEntries,
            thumbnailJPEGData: item.thumbnailJPEGData,
            deltaEmpty: deltaEmpty,
            deltaWater: deltaWater,
            bubbleDetected: bubbleDetected,
            vision: vision,
            inferenceMode: activeMode
        ) {
            return ConsumerScanItem(
                id: item.id,
                scannedAt: item.scannedAt,
                scanSequenceNumber: calibratedResult.scanSequenceNumber,
                batchRunID: calibratedResult.batchRunID,
                batchScanIndex: calibratedResult.batchScanIndex,
                batchTotalCount: calibratedResult.batchTotalCount,
                geometryCondition: calibratedResult.geometryCondition,
                controlSeriesTag: calibratedResult.controlSeriesTag,
                aeAfWbLockState: calibratedResult.aeAfWbLockState,
                targetLockState: calibratedResult.targetLockState,
                targetLockScore: calibratedResult.targetLockScore,
                gateDecision: calibratedResult.gateDecision,
                rejectionReason: calibratedResult.rejectionReason,
                status: calibratedResult.status,
                title: calibratedResult.title,
                formulaDisplay: calibratedResult.formulaDisplay,
                statusBadgeText: calibratedResult.statusBadgeText,
                confidencePercent: calibratedResult.confidencePercent,
                scientificNote: calibratedResult.scientificNote,
                constituents: calibratedResult.constituents,
                tuneProfile: calibratedResult.tuneProfile,
                measuredPeakHz: calibratedResult.measuredPeakHz,
                measuredCentroidHz: calibratedResult.measuredCentroidHz,
                measuredDecayDBPerSec: calibratedResult.measuredDecayDBPerSec,
                measuredFeatures: features,
                topCandidateName: calibratedResult.topCandidateName,
                topCandidateDistance: calibratedResult.topCandidateDistance,
                runnerUpTitle: calibratedResult.runnerUpTitle,
                runnerUpSimilarityPercent: calibratedResult.runnerUpSimilarityPercent,
                secondCandidateDistance: calibratedResult.secondCandidateDistance,
                winningMargin: calibratedResult.winningMargin,
                allCandidateDistances: calibratedResult.allCandidateDistances,
                thumbnailJPEGData: item.thumbnailJPEGData,
                isConditioningCycle: item.isConditioningCycle,
                conditioningTag: item.conditioningTag,
                modeAScreeningState: calibratedResult.modeAScreeningState,
                deltaEmptyBaseline: deltaEmpty,
                deltaWaterBaseline: deltaWater,
                fusionAttribution: calibratedResult.fusionAttribution
            )
        }

        if let fused = fusionClassifier.evaluate(
            features: features,
            visual: visual,
            vision: vision,
            deltaEmpty: deltaEmpty,
            deltaWater: deltaWater,
            bubbleDetected: bubbleDetected,
            hasInverseDeconv: features.modalVector != nil,
            inferenceMode: activeMode
        ) {
            let runnerUp = fused.rankedCandidates.dropFirst().first
            return ConsumerScanItem(
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
                gateDecision: fused.gateDecision,
                rejectionReason: nil,
                status: .referenceMatch,
                title: fused.profile.displayName,
                formulaDisplay: fused.profile.formulaDisplay,
                statusBadgeText: fused.statusBadgeText,
                confidencePercent: fused.confidencePercent,
                scientificNote: fused.scientificNote,
                constituents: fused.profile.constituents,
                tuneProfile: fused.profile.tuneProfile,
                measuredPeakHz: item.measuredPeakHz,
                measuredCentroidHz: item.measuredCentroidHz,
                measuredDecayDBPerSec: item.measuredDecayDBPerSec,
                measuredFeatures: features,
                topCandidateName: fused.profile.displayName,
                topCandidateDistance: fused.attribution.mahalanobisDistance,
                runnerUpTitle: runnerUp?.displayName,
                secondCandidateDistance: runnerUp?.distance,
                winningMargin: fused.attribution.winningMargin,
                allCandidateDistances: fused.rankedCandidates.isEmpty ? allEntries : fused.rankedCandidates,
                thumbnailJPEGData: item.thumbnailJPEGData,
                isConditioningCycle: item.isConditioningCycle,
                conditioningTag: item.conditioningTag,
                modeAScreeningState: fused.screeningState,
                deltaEmptyBaseline: deltaEmpty,
                deltaWaterBaseline: deltaWater,
                fusionAttribution: fused.attribution
            )
        }

        let clearGuidance = (activeMode == .multiModalFusion)
            ? MultiModalFusionClassifier.uncalibratedClearLiquidGuidance(
                features: features,
                vision: vision,
                deltaEmpty: deltaEmpty,
                deltaWater: deltaWater,
                bubbleDetected: bubbleDetected
            )
            : nil

        if let de = deltaEmpty, de.compatible {
            let validShifts = de.relativeFrequencyShifts.compactMap { $0 }.map { abs($0) }
            if let maxShift = validShifts.max(), maxShift >= 0.012 {
                let resolvedScreening: ModeAScreeningState = bubbleDetected ? .bubbleScatterDetected : .liquidLoaded
                let badge = bubbleDetected
                    ? "MODE_A Screening • Bubble Scatter Detected"
                    : "MODE_A Screening • Liquid Loaded"
                let titleText = bubbleDetected ? "Bubble-Active Liquid" : "Liquid Loaded (Unmatched Class)"
                let waterShiftNote: String = {
                    guard let dw = deltaWater, dw.compatible else { return "" }
                    let ws = dw.relativeFrequencyShifts.compactMap { $0 }.map { String(format: "%+.1f%%", $0 * 100.0) }
                    return ws.isEmpty ? "" : "; Δf/f_water = [\(ws.joined(separator: ", "))]"
                }()
                let noteText = String(
                    format: "Calibrated container shift detected (max |Δf/f_empty| = %.2f%%%@%@). No uncalibrated molecular or viscosity claim is asserted.",
                    maxShift * 100.0,
                    waterShiftNote,
                    bubbleDetected ? "; micro-bubble scatter detected" : ""
                )
                return ConsumerScanItem(
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
                    gateDecision: resolvedScreening.rawValue,
                    rejectionReason: "UNCALIBRATED_CLASS_HELD",
                    status: .unmatchedSignature,
                    title: titleText,
                    formulaDisplay: resolvedScreening.rawValue,
                    statusBadgeText: badge,
                    confidencePercent: nil,
                    scientificNote: noteText,
                    constituents: [],
                    tuneProfile: item.tuneProfile,
                    measuredPeakHz: item.measuredPeakHz,
                    measuredCentroidHz: item.measuredCentroidHz,
                    measuredDecayDBPerSec: item.measuredDecayDBPerSec,
                    measuredFeatures: features,
                    topCandidateName: allEntries.first?.displayName,
                    topCandidateDistance: allEntries.first?.distance,
                    runnerUpTitle: allEntries.dropFirst().first?.displayName,
                    secondCandidateDistance: allEntries.dropFirst().first?.distance,
                    winningMargin: (allEntries.count > 1) ? (allEntries[1].distance - allEntries[0].distance) : nil,
                    allCandidateDistances: allEntries,
                    thumbnailJPEGData: item.thumbnailJPEGData,
                    isConditioningCycle: item.isConditioningCycle,
                    conditioningTag: item.conditioningTag,
                    modeAScreeningState: resolvedScreening,
                    deltaEmptyBaseline: deltaEmpty,
                    deltaWaterBaseline: deltaWater,
                    fusionAttribution: clearGuidance
                )
            }
        }

        let screenState: ModeAScreeningState = bubbleDetected ? .bubbleScatterDetected : .noValidatedMatch
        return ConsumerScanItem(
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
            gateDecision: bubbleDetected ? "MODE_A_BUBBLE_SCATTER_DETECTED" : "HELD_MODE_A_UNCALIBRATED_SCREENING",
            rejectionReason: bubbleDetected
                ? "BUBBLE_SCATTER_DETECTED: physical micro-bubble/effervescence scatter observed"
                : "MODE_A_SCREENING_BOUNDARY: uncalibrated airborne reflection requires container baseline (Delta X_empty / Delta X_water)",
            status: .unmatchedSignature,
            title: "Unmatched Liquid",
            formulaDisplay: screenState.rawValue,
            statusBadgeText: bubbleDetected ? "MODE_A Screening • Bubble Scatter Detected" : "Ambiguity Gate R2 • No Forced Match",
            confidencePercent: nil,
            scientificNote: item.scientificNote,
            constituents: [],
            tuneProfile: item.tuneProfile,
            measuredPeakHz: item.measuredPeakHz,
            measuredCentroidHz: item.measuredCentroidHz,
            measuredDecayDBPerSec: item.measuredDecayDBPerSec,
            measuredFeatures: features,
            topCandidateName: allEntries.first?.displayName,
            topCandidateDistance: allEntries.first?.distance,
            runnerUpTitle: allEntries.dropFirst().first?.displayName,
            secondCandidateDistance: allEntries.dropFirst().first?.distance,
            winningMargin: (allEntries.count > 1) ? (allEntries[1].distance - allEntries[0].distance) : nil,
            allCandidateDistances: allEntries,
            thumbnailJPEGData: item.thumbnailJPEGData,
            isConditioningCycle: item.isConditioningCycle,
            conditioningTag: item.conditioningTag,
            modeAScreeningState: screenState,
            deltaEmptyBaseline: deltaEmpty,
            deltaWaterBaseline: deltaWater,
            fusionAttribution: clearGuidance
        )
    }

    private func matchCalibratedPrototypes(
        features: ExtractedConsumerFeatures,
        scanSequenceNumber: Int?,
        batchRunID: String?,
        batchScanIndex: Int?,
        batchTotalCount: Int?,
        geometryCondition: String?,
        controlSeriesTag: String?,
        aeAfWbLockState: String?,
        targetLockState: String?,
        targetLockScore: Double?,
        hasOptics: Bool,
        prototypes: [CalibratedAcousticPrototype],
        allFrozenEntries: [CandidateScoreEntry],
        thumbnailJPEGData: Data?,
        deltaEmpty: DifferentialBaselineVector? = nil,
        deltaWater: DifferentialBaselineVector? = nil,
        bubbleDetected: Bool = false,
        vision: VisionFeatureVector = .audioOnlyEmpty,
        inferenceMode: ConsumerInferenceMode = .multiModalFusion
    ) -> ConsumerScanItem? {
        var grouped: [String: [ExtractedConsumerFeatures]] = [:]
        for proto in prototypes {
            if let sg = geometryCondition, let pg = proto.geometryCondition, !sg.isEmpty, !pg.isEmpty, sg != pg {
                continue
            }
            grouped[proto.targetID, default: []].append(proto.features)
        }

        let hasExplicitNonWaterLiquidStandard = grouped.keys.contains { key in
            key != CalibratedAcousticPrototype.emptyContainerTargetID &&
                key != CalibratedAcousticPrototype.waterReferenceTargetID &&
                key != CalibratedAcousticPrototype.solidSurfaceTargetID
        }

        let scoredTargets: [(targetID: String, distance: Double)] = grouped.map { targetID, feats in
            let centroid = Self.averagePrototypeCentroid(feats)
            let dCentroid = Self.calibratedScatteringDistance(features, centroid, includeOptics: hasOptics)
            let dNearest = feats.map { Self.calibratedScatteringDistance(features, $0, includeOptics: hasOptics) }.min() ?? dCentroid
            return (targetID, 0.70 * dCentroid + 0.30 * dNearest)
        }.sorted { $0.distance < $1.distance }

        guard let bestTarget = scoredTargets.first, bestTarget.distance <= 1.25 else {
            return nil
        }

        let runnerUpEntry = scoredTargets.count > 1 ? scoredTargets[1] : nil
        let secondDist = runnerUpEntry?.distance ?? (bestTarget.distance + 0.55)
        let margin = secondDist - bestTarget.distance
        guard margin >= 0.08 || scoredTargets.count == 1 else {
            return nil
        }

        let topName = displayTitleForTarget(bestTarget.targetID)
        let runnerUpName = runnerUpEntry.map { displayTitleForTarget($0.targetID) }
        let runnerUpSim = runnerUpEntry.map { entry in
            min(94, max(35, Int(round(exp(-0.42 * entry.distance) * 94.0))))
        }
        let calEntries = scoredTargets.map {
            CandidateScoreEntry(profileID: $0.targetID, displayName: displayTitleForTarget($0.targetID), distance: $0.distance)
        }

        let rawSim = exp(-0.42 * bestTarget.distance) * (0.85 + 0.15 * min(1.0, margin / 0.35))
        let confidence = min(96, max(68, Int(round(rawSim * 96.0))))

        if bestTarget.targetID == CalibratedAcousticPrototype.solidSurfaceTargetID {
            return buildSolidNonLiquidItem(
                features: features,
                scanSequenceNumber: scanSequenceNumber,
                batchRunID: batchRunID,
                batchScanIndex: batchScanIndex,
                batchTotalCount: batchTotalCount,
                geometryCondition: geometryCondition,
                controlSeriesTag: controlSeriesTag,
                aeAfWbLockState: aeAfWbLockState,
                targetLockState: targetLockState,
                targetLockScore: targetLockScore,
                gateDecision: "REJECTED_CALIBRATED_SOLID_SURFACE",
                rejectionReason: String(format: "CALIBRATED_SOLID_MATCH: d=%.3f", bestTarget.distance),
                allEntries: calEntries,
                thumbnailJPEGData: thumbnailJPEGData
            )
        }

        if bestTarget.targetID == CalibratedAcousticPrototype.emptyContainerTargetID {
            // Never classify a container as Empty if its 4-mode vector exhibits a >= 2.2% mean mass-loading shift
            if let de = deltaEmpty, de.compatible {
                let validShifts = de.relativeFrequencyShifts.compactMap { $0 }.map { abs($0) }
                if !validShifts.isEmpty {
                    let meanShift = validShifts.reduce(0.0, +) / Double(validShifts.count)
                    if meanShift >= 0.022 || (validShifts.max() ?? 0.0) >= 0.080 {
                        return nil
                    }
                }
            }
            return ConsumerScanItem(
                scanSequenceNumber: scanSequenceNumber,
                batchRunID: batchRunID,
                batchScanIndex: batchScanIndex,
                batchTotalCount: batchTotalCount,
                geometryCondition: geometryCondition,
                controlSeriesTag: controlSeriesTag,
                aeAfWbLockState: aeAfWbLockState,
                targetLockState: targetLockState,
                targetLockScore: targetLockScore,
                gateDecision: "CALIBRATED_EMPTY_CONTAINER",
                rejectionReason: nil,
                status: .emptyContainer,
                title: "Empty Container",
                formulaDisplay: "No Liquid Fill Detected",
                statusBadgeText: "Calibrated Empty Glass • \(confidence)% Similarity",
                confidencePercent: confidence,
                scientificNote: "Matches calibrated empty-container control (d = \(String(format: "%.2f", bestTarget.distance)), margin = +\(String(format: "%.2f", margin))).",
                constituents: [],
                tuneProfile: Self.buildAcousticSignatureTune(features: features, formula: "Container Shell"),
                measuredPeakHz: features.dominantPeakHz,
                measuredCentroidHz: features.spectralCentroidHz,
                measuredDecayDBPerSec: features.decaySlopeDBPerSec,
                measuredFeatures: features,
                topCandidateName: topName,
                topCandidateDistance: bestTarget.distance,
                runnerUpTitle: runnerUpName,
                runnerUpSimilarityPercent: runnerUpSim,
                secondCandidateDistance: runnerUpEntry?.distance,
                winningMargin: margin,
                allCandidateDistances: calEntries,
                thumbnailJPEGData: thumbnailJPEGData,
                modeAScreeningState: .emptyContainer,
                deltaEmptyBaseline: deltaEmpty,
                deltaWaterBaseline: deltaWater
            )
        }

        guard let matchedProfile = ReferenceLiquidProfile.fusionLibrary.first(where: { $0.id == bestTarget.targetID }) else {
            return nil
        }

        // In v0.5.0 Multi-Modal & Comparator mode, when H2O_DIST was saved as the Water Reference Baseline
        // (without explicit multi-liquid blind standards), defer to MultiModalFusionClassifier if the sample is
        // effervescent, optically chromatic/turbid (Oil/Milk/Wine/Juice), or exhibits a >1.1% modal shift / vinegar meniscus!
        if matchedProfile.id == CalibratedAcousticPrototype.waterReferenceTargetID && !hasExplicitNonWaterLiquidStandard {
            if bubbleDetected { return nil }
            if vision.hasCameraFrame && (vision.meanSaturationWB >= 0.22 || vision.opticalTurbidity >= 0.42) {
                return nil
            }
            if inferenceMode == .multiModalFusion, let dw = deltaWater, dw.compatible {
                let shifts = dw.relativeFrequencyShifts.compactMap { $0 }.map { abs($0) }
                if !shifts.isEmpty {
                    let meanAbs = shifts.reduce(0.0, +) / Double(shifts.count)
                    let maxAbs = shifts.max() ?? 0.0
                    if meanAbs > 0.011 || maxAbs > 0.018 {
                        return nil
                    }
                    if vision.hasCameraFrame && vision.meniscusEdgeStrength >= 0.028 && vision.meniscusContactAngleDegrees >= 39.0 {
                        return nil
                    }
                }
            }
        }

        let note: String
        if matchedProfile.id == "NACL_AQ" {
            note = "Salt signature detected under the calibrated acquisition setup (d = \(String(format: "%.2f", bestTarget.distance)), margin = +\(String(format: "%.2f", margin)))."
        } else if matchedProfile.id == "H2O_DIST" {
            note = "Matches plain water blank under the calibrated setup—no reliable solute shift detected at this sensitivity."
        } else if matchedProfile.id == "OIL_VEG" {
            note = "Calibrated container-shift match to Cooking / Vegetable Oil standard (screening candidate; no airborne bulk-viscosity claim)."
        } else {
            note = "\(matchedProfile.displayName) signature detected under the calibrated acquisition setup."
        }

        return ConsumerScanItem(
            scanSequenceNumber: scanSequenceNumber,
            batchRunID: batchRunID,
            batchScanIndex: batchScanIndex,
            batchTotalCount: batchTotalCount,
            geometryCondition: geometryCondition,
            controlSeriesTag: controlSeriesTag,
            aeAfWbLockState: aeAfWbLockState,
            targetLockState: targetLockState,
            targetLockScore: targetLockScore,
            gateDecision: "PASS_CALIBRATED_MATCH",
            rejectionReason: nil,
            status: .referenceMatch,
            title: matchedProfile.displayName,
            formulaDisplay: matchedProfile.formulaDisplay,
            statusBadgeText: "Calibrated Acoustic Match • \(confidence)% Similarity",
            confidencePercent: confidence,
            scientificNote: note,
            constituents: matchedProfile.constituents,
            tuneProfile: matchedProfile.tuneProfile,
            measuredPeakHz: features.dominantPeakHz,
            measuredCentroidHz: features.spectralCentroidHz,
            measuredDecayDBPerSec: features.decaySlopeDBPerSec,
            measuredFeatures: features,
            topCandidateName: topName,
            topCandidateDistance: bestTarget.distance,
            runnerUpTitle: runnerUpName,
            runnerUpSimilarityPercent: runnerUpSim,
            secondCandidateDistance: runnerUpEntry?.distance,
            winningMargin: margin,
            allCandidateDistances: calEntries.isEmpty ? allFrozenEntries : calEntries,
            thumbnailJPEGData: thumbnailJPEGData,
            modeAScreeningState: bubbleDetected ? .bubbleScatterDetected : .calibratedClassCandidate,
            deltaEmptyBaseline: deltaEmpty,
            deltaWaterBaseline: deltaWater
        )
    }

    private func resolveEligibleCandidates(
        for hint: VisualLiquidHint,
        features: ExtractedConsumerFeatures
    ) -> [ReferenceLiquidProfile] {
        let allowedIDs: Set<String>
        switch hint {
        case .audioOnly, .openVesselAqueousOrGeneral:
            var excluded: Set<String> = ["OIL_VEG", "AQUA_SURFACTANT", "ISOPROPYL_ALC"]
            if !(features.decaySlopeDBPerSec >= 98.0 && features.dominantPeakHz < 1_920.0) {
                excluded.insert("SUC_AQ")
            }
            let openPool = referenceLibrary.filter { !excluded.contains($0.id) }
            return openPool.isEmpty ? referenceLibrary : openPool

        case .solidOrNonLiquid:
            return []
        case .labeledWater:
            allowedIDs = ["H2O_DIST"]
        case .labeledSaline:
            allowedIDs = ["NACL_AQ"]
        case .labeledPeroxide, .brownPeroxideBottle:
            allowedIDs = ["H2O2_AQ"]
        case .labeledVinegar:
            allowedIDs = ["VIN_WHITE"]
        case .labeledOil, .goldenOil:
            allowedIDs = ["OIL_VEG"]
        case .labeledMilk, .milkOpaqueWhite:
            allowedIDs = ["MILK_DAIRY"]
        case .labeledJuice, .citrusOrAmberJuice:
            allowedIDs = ["CITRUS_JUICE"]
        case .labeledCoffeeOrCola, .darkBeverage:
            allowedIDs = ["COFFEE_DARK"]
        case .labeledAlcohol:
            allowedIDs = ["ISOPROPYL_ALC"]
        case .labeledSurfactant, .coloredPackagedBottle:
            allowedIDs = ["AQUA_SURFACTANT"]
        }
        let matched = referenceLibrary.filter { allowedIDs.contains($0.id) }
        return matched.isEmpty ? referenceLibrary : matched
    }

    // MARK: - Raw Physical Feature Extraction (Repeatability Gate R1)

    public func extractFeatures(
        samples: [Float],
        inverseFilter: [Float]?,
        sampleRateHz: Double = 48_000.0,
        preRollFrames: Int = 7_200,
        activeFrames: Int = 9_600,
        clippingCeilingDBFS: Double = -0.5,
        visual: VisualContextSummary = .audioOnlyDefault,
        vision: VisionFeatureVector = .audioOnlyEmpty,
        opticsLocked: Bool = false,
        latePreRollSilence: [Float]? = nil
    ) -> ExtractedConsumerFeatures {
        guard !samples.isEmpty else {
            return ExtractedConsumerFeatures(
                activeSNRDB: 0.0,
                activeRMSDBFS: -120.0,
                peakDBFS: -120.0,
                clippedSamples: 0,
                dominantPeakHz: 2_220.0,
                primaryPeakAmplitudeDB: -120.0,
                secondaryPeaksHz: [],
                secondaryPeakAmplitudesDB: [],
                spectralCentroidHz: 2_560.0,
                midToHighBandDB: 3.8,
                decaySlopeDBPerSec: 76.0,
                highFreqBubbleScatterDB: -8.8,
                spectralFlatness: 0.65,
                peakProminenceDB: 3.0,
                cavityMultipathDB: -6.0,
                subBandShapeDB: [0, 0, 0, 0, 0, 0],
                echoReturnDB: -18.0,
                echoRMSDBFS: -120.0,
                tailSNRDB: 0.0,
                alignmentOffsetSamples: 0,
                echoArrivalDelayMs: 0.0,
                intraScanPersistenceRatio: 0.0,
                featureVectorChecksum: "00000000",
                opticalCenterBrightness: visual.innerBrightness,
                opticalInteriorContrast: visual.innerSpatialContrast,
                opticalRimContrast: visual.rimContrast,
                opticsLocked: opticsLocked,
                latePreRollNoiseDBFS: -120.0,
                preRollExcessHFDB: 0.0,
                modalVector: .emptyMasked
            )
        }

        let clipLin = pow(10.0, clippingCeilingDBFS / 20.0)
        var peakLin = 0.0
        var clipped = 0
        for s in samples where s.isFinite {
            let a = abs(Double(s))
            if a > peakLin { peakLin = a }
            if a >= clipLin { clipped += 1 }
        }

        var preEnd = max(1, min(samples.count, preRollFrames))
        var actStart = min(samples.count, preRollFrames)
        var actEnd = min(samples.count, preRollFrames + max(1, activeFrames))

        var preRMS = Self.segmentRMS(samples, start: 0, end: preEnd)
        var actRMS = actEnd > actStart ? Self.segmentRMS(samples, start: actStart, end: actEnd) : 0.0
        var preDB = ImmediateAudioAnalyzer.linearToDBFS(preRMS)
        var actDB = ImmediateAudioAnalyzer.linearToDBFS(actRMS)
        var snrDB = max(0.0, actDB - preDB)

        let nFFT = 4_096
        let binHz = sampleRateHz / Double(nFFT)
        let minBin = max(2, Int(ceil(1_200.0 / binHz)))
        let maxPassBin = min(nFFT / 2 - 3, Int(floor(9_600.0 / binHz)))
        let maxScatterBin = min(nFFT / 2 - 2, Int(floor(11_800.0 / binHz)))

        var analysisSignal: [Double] = []
        var weightedPower = [Double](repeating: 0.0, count: nFFT / 2)
        var peakRankPower = [Double](repeating: 0.0, count: nFFT / 2)
        var windowPowerScale = 1.0
        var windowCoherentAmpSum = 1.0
        var noiseFloorPowerPerSample = 0.0
        var echoReturnDB = -14.0
        var tailSNRDB = max(0.0, snrDB - 6.0)
        var alignmentOffsetSamples = 0
        var echoArrivalDelayMs = 2.2
        var persistenceByBin = [Double](repeating: 1.0, count: nFFT / 2)
        var scaledPreFizzScatterTerm = 0.0
        var latePreRollSliceDouble: [Double] = []
        var invEnergyGain = 1.0
        var preRollExcessHFDB = 0.0
        let isDeconvolvedPath = (inverseFilter != nil && !(inverseFilter?.isEmpty ?? true) && samples.count > max(512, (inverseFilter?.count ?? 0) / 2))

        if let inv = inverseFilter, isDeconvolvedPath {
            // 1. Convolve full recording with matched ESS inverse filter for exact sample-accurate sync!
            let fullDouble = samples.map { $0.isFinite ? Double($0) : 0.0 }
            let invDouble = inv.map { $0.isFinite ? Double($0) : 0.0 }
            invEnergyGain = max(1e-12, invDouble.reduce(0.0) { $0 + $1 * $1 })
            let ir = Self.fastLinearConvolve(fullDouble, invDouble)

            let expectedPeak = preRollFrames + inv.count - 1
            let searchLo = max(0, inv.count - 1 - Int(0.050 * sampleRateHz))
            let searchHi = min(ir.count, expectedPeak + Int(0.180 * sampleRateHz))
            var peakIdx = min(max(0, expectedPeak), max(0, ir.count - 1))
            var maxAbs = 0.0
            if searchHi > searchLo {
                for idx in searchLo..<searchHi {
                    let a = abs(ir[idx])
                    if a > maxAbs {
                        maxAbs = a
                        peakIdx = idx
                    }
                }
            } else {
                for (idx, val) in ir.enumerated() {
                    let a = abs(val)
                    if a > maxAbs {
                        maxAbs = a
                        peakIdx = idx
                    }
                }
            }

            // 2. Recompute pre-roll & active sweep RMS using the clean LATE pre-roll silence window
            // (eliminating both Sweep-1-to-Sweep-2 early pre-roll bleed and post-tail late-echo contamination)
            let alignedActStart = max(0, min(samples.count - 1, peakIdx - (inv.count - 1)))
            let alignedActEnd = min(samples.count, alignedActStart + max(1, activeFrames))
            alignmentOffsetSamples = alignedActStart - preRollFrames

            let lateBounds = WarmBatchAudioEngine.extractLatePreRollSilenceBounds(
                totalSamples: samples.count,
                nominalPreRollFrames: preRollFrames,
                alignedExcitationStart: alignedActStart,
                sampleRateHz: sampleRateHz
            )
            let alignedPreStart = lateBounds.lowerBound
            let alignedPreEnd = lateBounds.upperBound

            if let explicitLate = latePreRollSilence, explicitLate.count >= 256 {
                latePreRollSliceDouble = explicitLate.map { $0.isFinite ? Double($0) : 0.0 }
                let meanVal = latePreRollSliceDouble.reduce(0.0, +) / Double(latePreRollSliceDouble.count)
                let varVal = latePreRollSliceDouble.reduce(0.0) { $0 + ($1 - meanVal) * ($1 - meanVal) } / Double(latePreRollSliceDouble.count)
                preRMS = sqrt(max(0.0, varVal))
            } else if alignedPreEnd > alignedPreStart + 64 {
                preRMS = Self.segmentRMS(samples, start: alignedPreStart, end: alignedPreEnd)
                preEnd = alignedPreEnd
                latePreRollSliceDouble = Array(samples[alignedPreStart..<alignedPreEnd]).map { $0.isFinite ? Double($0) : 0.0 }
            } else {
                latePreRollSliceDouble = Array(samples[0..<preEnd]).map { $0.isFinite ? Double($0) : 0.0 }
            }

            if alignedActEnd > alignedActStart + 256 {
                actRMS = Self.segmentRMS(samples, start: alignedActStart, end: alignedActEnd)
                actStart = alignedActStart
                actEnd = alignedActEnd
            }
            preDB = ImmediateAudioAnalyzer.linearToDBFS(preRMS)
            actDB = ImmediateAudioAnalyzer.linearToDBFS(actRMS)
            snrDB = max(0.0, actDB - preDB)

            // 3. Causal container reflection gate [t0 + 2.15 ms .. t0 + 15.5 ms]
            let dirStart = max(0, peakIdx - Int(0.0004 * sampleRateHz))
            let dirEnd = min(ir.count, peakIdx + Int(0.0011 * sampleRateHz))
            let tailStart = min(ir.count, peakIdx + Int(0.00215 * sampleRateHz))
            let tailEnd = min(ir.count, peakIdx + Int(0.0155 * sampleRateHz))

            // Measure physical echo arrival delay after direct path t0
            let arrivalLo = min(ir.count, peakIdx + Int(0.00065 * sampleRateHz))
            let arrivalHi = min(ir.count, peakIdx + Int(0.0120 * sampleRateHz))
            if arrivalHi > arrivalLo {
                var maxEnv = 0.0
                var bestOff = arrivalLo
                for k in arrivalLo..<arrivalHi {
                    let a = abs(ir[k])
                    if a > maxEnv {
                        maxEnv = a
                        bestOff = k
                    }
                }
                echoArrivalDelayMs = max(0.5, Double(bestOff - peakIdx) * 1_000.0 / sampleRateHz)
            }

            var dirMean = 1e-15
            var echoMean = 1e-15
            if dirEnd > dirStart {
                dirMean = ir[dirStart..<dirEnd].reduce(1e-15) { $0 + $1 * $1 } / Double(dirEnd - dirStart)
            }
            if tailEnd > tailStart {
                echoMean = ir[tailStart..<tailEnd].reduce(1e-15) { $0 + $1 * $1 } / Double(tailEnd - tailStart)
            }

            // 4. Phase R2-B Relocated Deconvolved Noise Spectrum from Late Pre-Roll Silence Buffer!
            // Uses exact LTI Parseval transfer `N_deconv(b) = P_latePreRoll(b) * |G_inv(b)|^2` so late-tail
            // container echoes (42..68 ms) and Farina harmonic pre-impulses never contaminate baseline noise.
            noiseFloorPowerPerSample = max(1e-24, preRMS * preRMS * invEnergyGain)
            let noisePowerSpec = Self.computeDeconvolvedPreRollNoiseSpectrum(
                latePreRollSlice: latePreRollSliceDouble,
                invDouble: invDouble,
                nFFT: nFFT
            )

            let rawTailSNR = 10.0 * log10(max(echoMean, 1e-18) / max(noiseFloorPowerPerSample, 1e-18))
            tailSNRDB = max(-10.0, min(60.0, rawTailSNR))
            let netEchoMean = max(echoMean * 0.15, echoMean - 0.85 * noiseFloorPowerPerSample)
            echoReturnDB = min(0.0, max(-42.0, 10.0 * log10(netEchoMean / max(dirMean, 1e-15))))

            if tailEnd - tailStart >= 192 {
                analysisSignal = Array(ir[tailStart..<tailEnd])
            } else {
                analysisSignal = Array(samples[actStart..<max(actStart + 1, actEnd)]).map { $0.isFinite ? Double($0) : 0.0 }
            }

            // 5. Asymmetric Tukey-tapered gate + overlapping sustain sub-window for intra-scan modal persistence
            let copyCount = min(analysisSignal.count, nFFT)
            var real1 = [Double](repeating: 0.0, count: nFFT)
            var imag1 = [Double](repeating: 0.0, count: nFFT)
            let leadIn = min(Int(0.00065 * sampleRateHz), max(1, copyCount / 5))
            let flatEnd = min(copyCount, Int(0.00725 * sampleRateHz))
            var wNorm1 = 0.0
            var wSum1 = 0.0
            if copyCount > 1 {
                for i in 0..<copyCount {
                    let w: Double
                    if i < leadIn {
                        w = 0.5 * (1.0 - cos(Double.pi * Double(i) / Double(max(1, leadIn))))
                    } else if i > flatEnd {
                        let rem = max(1, copyCount - 1 - flatEnd)
                        w = 0.5 * (1.0 + cos(Double.pi * Double(i - flatEnd) / Double(rem)))
                    } else {
                        w = 1.0
                    }
                    real1[i] = analysisSignal[i] * w
                    wNorm1 += w * w
                    wSum1 += w
                }
            }
            Self.fftRadix2(real: &real1, imag: &imag1, inverse: false)
            windowPowerScale = max(1.0, wNorm1)
            windowCoherentAmpSum = max(1.0, wSum1)

            // Sub-window Early [0..56%] & Sub-window Sustain [20..82%] (Welch 3-gate modal persistence)
            let earlyLen = max(8, min(copyCount, Int(0.56 * Double(copyCount))))
            var realEarly = [Double](repeating: 0.0, count: nFFT)
            var imagEarly = [Double](repeating: 0.0, count: nFFT)
            var wNormEarly = 0.0
            if copyCount >= 16 {
                for idx in 0..<earlyLen {
                    let w = 0.5 * (1.0 - cos(2.0 * Double.pi * Double(idx) / Double(max(1, earlyLen - 1))))
                    realEarly[idx] = analysisSignal[idx] * w
                    wNormEarly += w * w
                }
                Self.fftRadix2(real: &realEarly, imag: &imagEarly, inverse: false)
            }

            let subOffset = min(max(0, copyCount - 32), Int(0.20 * Double(copyCount)))
            let subLen = max(8, min(copyCount - subOffset, Int(0.62 * Double(copyCount))))
            var real2 = [Double](repeating: 0.0, count: nFFT)
            var imag2 = [Double](repeating: 0.0, count: nFFT)
            var wNorm2 = 0.0
            if subLen > 8 && (subOffset + subLen) <= copyCount {
                for idx in 0..<subLen {
                    let w = 0.5 * (1.0 - cos(2.0 * Double.pi * Double(idx) / Double(max(1, subLen - 1))))
                    real2[idx] = analysisSignal[subOffset + idx] * w
                    wNorm2 += w * w
                }
                Self.fftRadix2(real: &real2, imag: &imag2, inverse: false)
            }

            var cleanP1 = [Double](repeating: 0.0, count: nFFT / 2)
            var cleanP2 = [Double](repeating: 0.0, count: nFFT / 2)
            var persistRaw = [Double](repeating: 0.85, count: nFFT / 2)
            let bLo = max(1, minBin - 1)
            let bHi = min(nFFT / 2 - 1, maxScatterBin + 1)
            if bHi >= bLo {
                for b in bLo...bHi {
                    let unitFull = (real1[b] * real1[b] + imag1[b] * imag1[b]) / max(1e-9, wNorm1)
                    let unitEarly = wNormEarly > 1e-6
                        ? (realEarly[b] * realEarly[b] + imagEarly[b] * imagEarly[b]) / wNormEarly
                        : unitFull
                    let unitSust = wNorm2 > 1e-6
                        ? (real2[b] * real2[b] + imag2[b] * imag2[b]) / wNorm2
                        : unitFull
                    let nf = noisePowerSpec[b]
                    // Phase R2-C (`LA-R2-C-PLAN-001` Sec. 2.2): Strip the 4% residual floor from the [5.2-11.8 kHz]
                    // high-frequency scatter window so weak-echo runs on dry glass do not integrate noise bins as scatter
                    let binFreqHz = Double(b) * binHz
                    let residualFloorFrac = (binFreqHz >= 5_200.0) ? 0.0 : 0.04
                    let cFull = max(unitFull * residualFloorFrac, unitFull - 1.45 * nf) * windowPowerScale
                    let cEarly = max(unitEarly * residualFloorFrac, unitEarly - 1.45 * nf) * windowPowerScale
                    let cSust = max(unitSust * residualFloorFrac, unitSust - 1.45 * nf) * windowPowerScale
                    cleanP1[b] = cFull
                    cleanP2[b] = pow(max(0.0, cFull * cEarly * cSust), 1.0 / 3.0)
                    let hi = max(cEarly, cSust)
                    persistRaw[b] = hi > 1e-18 ? min(1.0, min(cEarly, cSust) / hi) : 0.5
                }
            }

            if maxScatterBin > minBin {
                for b in minBin...maxScatterBin {
                    let smooth1 = 0.25 * cleanP1[b - 1] + 0.50 * cleanP1[b] + 0.25 * cleanP1[b + 1]
                    let smooth2 = 0.25 * cleanP2[b - 1] + 0.50 * cleanP2[b] + 0.25 * cleanP2[b + 1]
                    let f = Double(b) * binHz
                    let normAbove = max(0.0, (f - 3_200.0) / 3_800.0)
                    let speakerWeight = 1.0 / (1.0 + 0.28 * pow(normAbove, 1.3))
                    weightedPower[b] = smooth1 * speakerWeight
                    peakRankPower[b] = smooth2 * speakerWeight
                    persistenceByBin[b] = persistRaw[b]
                }
            }

            // Scale settled LATE pre-roll excess micro-bubble fizz into the deconvolved ir gain domain
            if latePreRollSliceDouble.count >= 512 {
                let preHF = Self.bandPower(slice: latePreRollSliceDouble, sampleRateHz: sampleRateHz, lowHz: 5_200.0, highHz: 11_800.0)
                let preMid = Self.bandPower(slice: latePreRollSliceDouble, sampleRateHz: sampleRateHz, lowHz: 1_500.0, highHz: 4_200.0)
                if preMid > 1e-24 && preHF > 1e-24 {
                    preRollExcessHFDB = 10.0 * log10(preHF / (0.85 * preMid))
                }
                let excessFizz = max(0.0, preHF - 0.85 * preMid)
                let deconvGainRatio = netEchoMean / max(actRMS * actRMS, 1e-12)
                scaledPreFizzScatterTerm = 6.0 * excessFizz * Double(nFFT) * deconvGainRatio * windowPowerScale
            }
        } else {
            // Direct active-window analysis path (headless unit tests & non-deconvolved fallback)
            analysisSignal = Array(samples[actStart..<max(actStart + 1, actEnd)]).map { $0.isFinite ? Double($0) : 0.0 }
            let lateBounds = WarmBatchAudioEngine.extractLatePreRollSilenceBounds(
                totalSamples: samples.count,
                nominalPreRollFrames: preEnd,
                alignedExcitationStart: preEnd,
                sampleRateHz: sampleRateHz
            )
            latePreRollSliceDouble = (!lateBounds.isEmpty && lateBounds.upperBound <= samples.count)
                ? Array(samples[lateBounds]).map { $0.isFinite ? Double($0) : 0.0 }
                : Array(samples[0..<preEnd]).map { $0.isFinite ? Double($0) : 0.0 }
            let preFizzHighPower = Self.bandPower(
                slice: latePreRollSliceDouble,
                sampleRateHz: sampleRateHz,
                lowHz: 5_200.0,
                highHz: 11_800.0
            )
            let preFizzMidPower = Self.bandPower(
                slice: latePreRollSliceDouble,
                sampleRateHz: sampleRateHz,
                lowHz: 1_500.0,
                highHz: 4_200.0
            )
            if preFizzHighPower > 1e-24 {
                preRollExcessHFDB = 10.0 * log10(preFizzHighPower / max(1e-20, 0.85 * preFizzMidPower))
            }
            scaledPreFizzScatterTerm = 6.0 * preFizzHighPower * Double(nFFT)

            var real = [Double](repeating: 0.0, count: nFFT)
            var imag = [Double](repeating: 0.0, count: nFFT)
            let copyCount = min(analysisSignal.count, nFFT)
            var wNorm = 0.0
            var wSum = 0.0
            if copyCount > 1 {
                for i in 0..<copyCount {
                    let w = 0.5 * (1.0 - cos(2.0 * Double.pi * Double(i) / Double(copyCount - 1)))
                    real[i] = analysisSignal[i] * w
                    wNorm += w * w
                    wSum += w
                }
            }
            Self.fftRadix2(real: &real, imag: &imag, inverse: false)
            windowPowerScale = max(1.0, wNorm)
            windowCoherentAmpSum = max(1.0, wSum)

            if maxScatterBin > minBin {
                for b in minBin...maxScatterBin {
                    let rawP = real[b] * real[b] + imag[b] * imag[b]
                    weightedPower[b] = rawP
                    peakRankPower[b] = rawP
                }
            }
        }

        let specCount = max(1, min(analysisSignal.count / 4, Int(0.0025 * sampleRateHz)))
        let cavityEnd = min(analysisSignal.count, Int(0.0220 * sampleRateHz))
        let cavityMultipathDB: Double
        if cavityEnd > specCount + 32 {
            let specMean = analysisSignal[0..<specCount].reduce(1e-15) { $0 + $1 * $1 } / Double(specCount)
            let cavMean = analysisSignal[specCount..<cavityEnd].reduce(1e-15) { $0 + $1 * $1 } / Double(cavityEnd - specCount)
            cavityMultipathDB = min(10.0, max(-18.0, 10.0 * log10(cavMean / max(specMean, 1e-15))))
        } else {
            cavityMultipathDB = -3.0
        }

        // Local spectral candidate peaks ranked by persistent modal power (parabolic bin interpolation)
        var localPeaks: [(bin: Int, freqHz: Double, rankScore: Double, power: Double)] = []
        if maxPassBin > minBin + 1 {
            for b in (minBin + 1)..<maxPassBin {
                let p0 = peakRankPower[b]
                let pLeft = peakRankPower[b - 1]
                let pRight = peakRankPower[b + 1]
                if p0 >= pLeft && p0 > pRight && p0 > 1e-16 {
                    let denom = pLeft - 2.0 * p0 + pRight
                    let delta = abs(denom) > 1e-18 ? max(-0.5, min(0.5, 0.5 * (pLeft - pRight) / denom)) : 0.0
                    let interpHz = (Double(b) + delta) * binHz
                    localPeaks.append((b, interpHz, p0, weightedPower[b]))
                }
            }
        }
        localPeaks.sort { $0.rankScore > $1.rankScore }

        var distinctPeaks: [(bin: Int, freqHz: Double, ampDB: Double)] = []
        let ampNorm = max(1e-6, pow(0.5 * windowCoherentAmpSum, 2.0))
        for pk in localPeaks {
            if distinctPeaks.allSatisfy({ abs($0.freqHz - pk.freqHz) >= 180.0 }) {
                let db = 10.0 * log10(max(pk.power / ampNorm, 1e-18))
                distinctPeaks.append((pk.bin, pk.freqHz, db))
                if distinctPeaks.count >= 4 { break }
            }
        }

        let subBandEdges: [(Double, Double)] = [
            (1_250.0, 1_900.0),
            (1_900.0, 2_800.0),
            (2_800.0, 4_100.0),
            (4_100.0, 5_900.0),
            (5_900.0, 8_400.0),
            (8_400.0, 11_600.0)
        ]
        var subBandSum = [Double](repeating: 1e-15, count: 6)
        var subBandCnt = [Double](repeating: 0.0, count: 6)

        var weightedFreqSum = 0.0
        var powerSum = 1e-15
        var maxBinPower = 1e-15
        var fallbackPeakHz = 2_220.0
        var fallbackBin = minBin
        var midBandPower = 1e-15
        var highBandPower = 1e-15
        var coreRefPower = 1e-15
        var upperScatterPower = 1e-15
        var logPowerSum = 0.0
        var flatnessBinCount = 0

        if maxScatterBin > minBin {
            for b in minBin...maxScatterBin {
                let p = weightedPower[b]
                let f = Double(b) * binHz

                for (k, edge) in subBandEdges.enumerated() where f >= edge.0 && f < edge.1 {
                    subBandSum[k] += p
                    subBandCnt[k] += 1.0
                }

                if b <= maxPassBin {
                    weightedFreqSum += f * p
                    powerSum += p
                    if p > maxBinPower {
                        maxBinPower = p
                        fallbackPeakHz = f
                        fallbackBin = b
                    }
                    if f >= 1_200.0 && f < 3_200.0 {
                        midBandPower += p
                    } else if f >= 3_200.0 && f <= 9_600.0 {
                        highBandPower += p
                    }
                    if f <= 8_500.0 {
                        logPowerSum += log(max(p, 1e-18))
                        flatnessBinCount += 1
                    }
                }

                if f >= 1_500.0 && f < 4_200.0 {
                    coreRefPower += p
                } else if f >= 5_200.0 && f <= 11_800.0 {
                    upperScatterPower += p
                }
            }
        }

        let primaryPeakHz = distinctPeaks.first?.freqHz ?? fallbackPeakHz
        let primaryPeakBin = distinctPeaks.first?.bin ?? fallbackBin
        let primaryPeakAmpDB = distinctPeaks.first?.ampDB ?? (10.0 * log10(max(maxBinPower / ampNorm, 1e-18)))
        let secondaryPeaksHz = distinctPeaks.dropFirst().map(\.freqHz)
        let secondaryPeakAmpsDB = distinctPeaks.dropFirst().map(\.ampDB)
        let primaryPersistence = (primaryPeakBin >= 0 && primaryPeakBin < persistenceByBin.count)
            ? persistenceByBin[primaryPeakBin]
            : 0.85
        let echoRMSDBFS = max(-120.0, actDB + echoReturnDB)

        let rawBandDB: [Double] = (0..<6).map { k in
            let meanP = subBandCnt[k] > 0 ? (subBandSum[k] / subBandCnt[k]) : 1e-15
            return 10.0 * log10(max(meanP, 1e-18))
        }
        let avgBandDB = rawBandDB.reduce(0.0, +) / 6.0
        let subBandShapeDB = rawBandDB.map { min(18.0, max(-18.0, $0 - avgBandDB)) }

        let centroidHz = weightedFreqSum / powerSum
        let midToHighDB = min(14.0, max(-14.0, 10.0 * log10(midBandPower / highBandPower)))

        let combinedScatter = upperScatterPower + scaledPreFizzScatterTerm
        let highFreqBubbleScatterDB = min(4.0, max(-12.0, 10.0 * log10(combinedScatter / coreRefPower)))

        let meanBinPower = flatnessBinCount > 0 ? (powerSum / Double(flatnessBinCount)) : 1e-15
        let geoMeanPower = flatnessBinCount > 0 ? exp(logPowerSum / Double(flatnessBinCount)) : 1e-15
        let spectralFlatness = min(1.0, max(0.0, geoMeanPower / max(meanBinPower, 1e-18)))
        let peakProminenceDB = max(0.0, 10.0 * log10(maxBinPower / max(meanBinPower, 1e-18)))

        // Phase R2-B: Remove hardcoded 145.0 dB/s clamp ceiling and compute Chu-compensated Narrowband Schroeder EDC
        // together with the 4-Mode Vector (`ModalVector4`, `mask_i = 0, f_i = NaN` when absent).
        let modalVector = Self.extractModalVector4(
            analysisSignal: analysisSignal,
            latePreRollSlice: latePreRollSliceDouble,
            inverseFilter: inverseFilter,
            invEnergyGain: invEnergyGain,
            sampleRateHz: sampleRateHz,
            latePreRollDBFS: preDB,
            isDeconvolvedTail: isDeconvolvedPath
        )

        let primaryEdc = Self.estimateSchroederEDCDecay(
            signal: analysisSignal,
            modeFreqHz: primaryPeakHz,
            latePreRollSlice: latePreRollSliceDouble,
            invEnergyGain: isDeconvolvedPath ? invEnergyGain : 1.0,
            sampleRateHz: sampleRateHz,
            isDeconvolvedTail: isDeconvolvedPath
        )
        let decayDBPerSec = primaryEdc.decayDBPerSec
            ?? modalVector.decayDBPerSec.compactMap({ $0 }).first
            ?? 80.0

        let canonicalVector = String(
            format: "%.1f|%.1f|%.2f|%.1f|%.2f|%.2f|%@",
            primaryPeakHz,
            centroidHz,
            midToHighDB,
            decayDBPerSec,
            highFreqBubbleScatterDB,
            echoReturnDB,
            subBandShapeDB.map { String(format: "%.2f", $0) }.joined(separator: ",")
        )
        let digest = SHA256.hash(data: Data(canonicalVector.utf8))
        let checksumHex = digest.prefix(4).map { String(format: "%02x", $0) }.joined()

        return ExtractedConsumerFeatures(
            activeSNRDB: snrDB,
            activeRMSDBFS: actDB,
            peakDBFS: ImmediateAudioAnalyzer.linearToDBFS(peakLin),
            clippedSamples: clipped,
            dominantPeakHz: primaryPeakHz,
            primaryPeakAmplitudeDB: primaryPeakAmpDB,
            secondaryPeaksHz: secondaryPeaksHz,
            secondaryPeakAmplitudesDB: secondaryPeakAmpsDB,
            spectralCentroidHz: centroidHz,
            midToHighBandDB: midToHighDB,
            decaySlopeDBPerSec: decayDBPerSec,
            highFreqBubbleScatterDB: highFreqBubbleScatterDB,
            spectralFlatness: spectralFlatness,
            peakProminenceDB: peakProminenceDB,
            cavityMultipathDB: cavityMultipathDB,
            subBandShapeDB: subBandShapeDB,
            echoReturnDB: echoReturnDB,
            echoRMSDBFS: echoRMSDBFS,
            tailSNRDB: tailSNRDB,
            alignmentOffsetSamples: alignmentOffsetSamples,
            echoArrivalDelayMs: echoArrivalDelayMs,
            intraScanPersistenceRatio: primaryPersistence,
            featureVectorChecksum: checksumHex,
            opticalCenterBrightness: visual.innerBrightness,
            opticalInteriorContrast: visual.innerSpatialContrast,
            opticalRimContrast: visual.rimContrast,
            opticsLocked: opticsLocked,
            latePreRollNoiseDBFS: preDB,
            preRollExcessHFDB: preRollExcessHFDB,
            modalVector: modalVector,
            visionFeatures: vision.hasCameraFrame ? vision : nil
        )
    }

    private func buildSolidNonLiquidItem(
        features: ExtractedConsumerFeatures,
        scanSequenceNumber: Int?,
        batchRunID: String? = nil,
        batchScanIndex: Int? = nil,
        batchTotalCount: Int? = nil,
        geometryCondition: String? = nil,
        controlSeriesTag: String? = nil,
        aeAfWbLockState: String? = nil,
        targetLockState: String? = nil,
        targetLockScore: Double? = nil,
        gateDecision: String = "REJECTED_NON_LIQUID_SURFACE",
        rejectionReason: String = "NON_LIQUID_SURFACE",
        allEntries: [CandidateScoreEntry],
        thumbnailJPEGData: Data?,
        modeAScreeningState: ModeAScreeningState = .nonstandardSurfaceResponse,
        deltaEmptyBaseline: DifferentialBaselineVector? = nil,
        deltaWaterBaseline: DifferentialBaselineVector? = nil
    ) -> ConsumerScanItem {
        let top = allEntries.first
        let second = allEntries.dropFirst().first
        return ConsumerScanItem(
            scanSequenceNumber: scanSequenceNumber,
            batchRunID: batchRunID,
            batchScanIndex: batchScanIndex,
            batchTotalCount: batchTotalCount,
            geometryCondition: geometryCondition,
            controlSeriesTag: controlSeriesTag,
            aeAfWbLockState: aeAfWbLockState,
            targetLockState: targetLockState,
            targetLockScore: targetLockScore,
            gateDecision: gateDecision,
            rejectionReason: rejectionReason,
            status: .nonLiquidMaterial,
            title: "Solid / Non-Liquid Material",
            formulaDisplay: "No Liquid Container Detected",
            statusBadgeText: "Solid Surface • Aim at a Liquid",
            confidencePercent: nil,
            scientificNote: "Visual framing and flat acoustic reflection indicate a solid surface or non-liquid object rather than liquid in a container.",
            constituents: [],
            tuneProfile: Self.buildAcousticSignatureTune(features: features, formula: "Surface Echo"),
            measuredPeakHz: features.dominantPeakHz,
            measuredCentroidHz: features.spectralCentroidHz,
            measuredDecayDBPerSec: features.decaySlopeDBPerSec,
            measuredFeatures: features,
            topCandidateName: top?.displayName,
            topCandidateDistance: top?.distance,
            runnerUpTitle: second?.displayName,
            secondCandidateDistance: second?.distance,
            winningMargin: (top != nil && second != nil) ? (second!.distance - top!.distance) : nil,
            allCandidateDistances: allEntries,
            thumbnailJPEGData: thumbnailJPEGData,
            modeAScreeningState: modeAScreeningState,
            deltaEmptyBaseline: deltaEmptyBaseline,
            deltaWaterBaseline: deltaWaterBaseline
        )
    }

    private func buildUnmatchedItem(
        features: ExtractedConsumerFeatures,
        scanSequenceNumber: Int?,
        batchRunID: String? = nil,
        batchScanIndex: Int? = nil,
        batchTotalCount: Int? = nil,
        geometryCondition: String? = nil,
        controlSeriesTag: String? = nil,
        aeAfWbLockState: String? = nil,
        targetLockState: String? = nil,
        targetLockScore: Double? = nil,
        gateDecision: String = "HELD_AMBIGUITY_GATE",
        rejectionReason: String? = nil,
        topEntry: CandidateScoreEntry?,
        secondEntry: CandidateScoreEntry?,
        allEntries: [CandidateScoreEntry],
        thumbnailJPEGData: Data?,
        modeAScreeningState: ModeAScreeningState = .noValidatedMatch,
        deltaEmptyBaseline: DifferentialBaselineVector? = nil,
        deltaWaterBaseline: DifferentialBaselineVector? = nil,
        fusionAttribution: MultiModalAttribution? = nil
    ) -> ConsumerScanItem {
        let margin = (topEntry != nil && secondEntry != nil) ? (secondEntry!.distance - topEntry!.distance) : nil
        let gateSummary: String
        if modeAScreeningState == .bubbleScatterDetected {
            gateSummary = "MODE_A Screening detected elevated high-frequency micro-bubble / effervescence scatter. Held as Unmatched Liquid because uncalibrated airborne scatter is non-specific without a container baseline."
        } else if let top = topEntry, let m = margin {
            gateSummary = "MODE_A Ambiguity Gate held back forced classification (top raw candidate \(top.displayName) d=\(String(format: "%.2f", top.distance)), margin=+\(String(format: "%.2f", m))). Calibrate Empty & Water container baselines for differential shift screening."
        } else {
            gateSummary = "Measured acoustic echo without forcing an unverified chemical match."
        }

        let badge = (modeAScreeningState == .bubbleScatterDetected)
            ? "MODE_A Screening • Bubble Scatter Detected"
            : "Ambiguity Gate R2 • No Forced Match"

        return ConsumerScanItem(
            scanSequenceNumber: scanSequenceNumber,
            batchRunID: batchRunID,
            batchScanIndex: batchScanIndex,
            batchTotalCount: batchTotalCount,
            geometryCondition: geometryCondition,
            controlSeriesTag: controlSeriesTag,
            aeAfWbLockState: aeAfWbLockState,
            targetLockState: targetLockState,
            targetLockScore: targetLockScore,
            gateDecision: gateDecision,
            rejectionReason: rejectionReason,
            status: .unmatchedSignature,
            title: "Unmatched Liquid",
            formulaDisplay: "Acoustic Profile",
            statusBadgeText: badge,
            confidencePercent: nil,
            scientificNote: gateSummary,
            constituents: [
                ReferenceConstituent(
                    symbol: String(format: "%.1f Hz", features.dominantPeakHz),
                    name: "Primary Resonance Peak",
                    roleDescription: "Raw measured resonance (unclassified)"
                )
            ],
            tuneProfile: Self.buildAcousticSignatureTune(features: features, formula: "Acoustic Signature"),
            measuredPeakHz: features.dominantPeakHz,
            measuredCentroidHz: features.spectralCentroidHz,
            measuredDecayDBPerSec: features.decaySlopeDBPerSec,
            measuredFeatures: features,
            topCandidateName: topEntry?.displayName,
            topCandidateDistance: topEntry?.distance,
            runnerUpTitle: secondEntry?.displayName,
            secondCandidateDistance: secondEntry?.distance,
            winningMargin: margin,
            allCandidateDistances: allEntries,
            thumbnailJPEGData: thumbnailJPEGData,
            modeAScreeningState: modeAScreeningState,
            deltaEmptyBaseline: deltaEmptyBaseline,
            deltaWaterBaseline: deltaWaterBaseline,
            fusionAttribution: fusionAttribution
        )
    }

    public static func buildAcousticSignatureTune(
        features: ExtractedConsumerFeatures,
        formula: String
    ) -> ChemicalTuneProfile {
        let pentatonicBase: [Double] = [293.66, 329.63, 369.99, 440.00, 493.88, 587.33, 659.25, 739.99, 880.00]
        let normalizedIdx = max(0, min(pentatonicBase.count - 4, Int((features.dominantPeakHz - 1_200.0) / 550.0)))
        let chord = [
            pentatonicBase[normalizedIdx],
            pentatonicBase[min(pentatonicBase.count - 1, normalizedIdx + 1)],
            pentatonicBase[min(pentatonicBase.count - 1, normalizedIdx + 2)],
            pentatonicBase[min(pentatonicBase.count - 1, normalizedIdx + 3)]
        ]
        return ChemicalTuneProfile(
            formulaDisplay: formula,
            mappingSummary: "Mapped musical representation derived directly from the measured acoustic resonance frequencies.",
            baseFrequenciesHz: chord,
            shimmerMultiplier: max(0.75, min(1.30, features.spectralCentroidHz / 2_600.0)),
            warmthDecayPerSec: max(1.3, min(2.4, features.decaySlopeDBPerSec / 65.0))
        )
    }

    // MARK: - Phase R2-B (`LA-R2-A-SANDBOX-REPORT-001`) Mathematical Estimators & MODE_A Screening

    /// Evaluates physical micro-bubble / effervescence backscatter (`BUBBLE_SCATTER_DETECTED`) using both
    /// reflected `[5.5-8.5] / [2.0-4.5] kHz` energy and active late-pre-roll high-frequency fizz excess,
    /// preventing bare empty plastic cups (quiet pre-roll) from false-triggering bubble detection.
    /// Computes `Delta S_HF = S_HF_sample - max(S_HF_empty, S_HF_water)` against geometry-compatible calibrated baselines.
    public static func computeDifferentialBubbleScatterDB(
        features: ExtractedConsumerFeatures,
        geometryCondition: String? = nil,
        prototypes: [CalibratedAcousticPrototype] = []
    ) -> Double? {
        let compatible = prototypes.filter { proto in
            guard proto.targetID == CalibratedAcousticPrototype.emptyContainerTargetID ||
                    proto.targetID == CalibratedAcousticPrototype.waterReferenceTargetID else {
                return false
            }
            if let sg = geometryCondition, let pg = proto.geometryCondition, !sg.isEmpty, !pg.isEmpty, sg != pg {
                return false
            }
            return true
        }
        guard !compatible.isEmpty else { return nil }

        func medianValue(_ arr: [Double]) -> Double? {
            let finite = arr.filter(\.isFinite).sorted()
            guard !finite.isEmpty else { return nil }
            let m = finite.count / 2
            return (finite.count % 2 != 0) ? finite[m] : 0.5 * (finite[m - 1] + finite[m])
        }

        let emptyMed = medianValue(
            compatible
                .filter { $0.targetID == CalibratedAcousticPrototype.emptyContainerTargetID }
                .map(\.features.highFreqBubbleScatterDB)
        )
        let waterMed = medianValue(
            compatible
                .filter { $0.targetID == CalibratedAcousticPrototype.waterReferenceTargetID }
                .map(\.features.highFreqBubbleScatterDB)
        )
        let refs = [emptyMed, waterMed].compactMap { $0 }
        guard let maxRefSHF = refs.max() else { return nil }
        return features.highFreqBubbleScatterDB - maxRefSHF
    }

    /// Phase R2-C (`LA-R2-C-PLAN-001` Sec. 2.2): Requires genuine positive pre-roll acoustic fizz (`preRollExcessHFDB > 0.0`)
    /// AND differential scatter excess `Delta S_HF >= +2.5 dB` above `max(S_HF_empty, S_HF_water)` when calibrated
    /// (or `highFreqBubbleScatterDB >= -3.0` when uncalibrated), eliminating false bubble triggers on dry containers.
    public static func detectMicroBubbleScatter(
        features: ExtractedConsumerFeatures,
        geometryCondition: String? = nil,
        prototypes: [CalibratedAcousticPrototype] = []
    ) -> Bool {
        guard features.preRollExcessHFDB > 0.0 else { return false }
        if let deltaSHF = computeDifferentialBubbleScatterDB(
            features: features,
            geometryCondition: geometryCondition,
            prototypes: prototypes
        ) {
            return deltaSHF >= 2.5
        }
        return features.highFreqBubbleScatterDB >= -3.0
    }

    /// Computes differential shift vectors (`Delta X_empty`, `Delta X_water`) against saved baseline prototypes.
    public static func computeBaselineShifts(
        features: ExtractedConsumerFeatures,
        geometryCondition: String?,
        prototypes: [CalibratedAcousticPrototype]
    ) -> (deltaEmpty: DifferentialBaselineVector?, deltaWater: DifferentialBaselineVector?) {
        guard let sampleMV = features.modalVector else { return (nil, nil) }

        let emptyAll = prototypes.filter { $0.targetID == CalibratedAcousticPrototype.emptyContainerTargetID }
        let waterAll = prototypes.filter { $0.targetID == CalibratedAcousticPrototype.waterReferenceTargetID }

        func pickGeometryMatched(_ all: [CalibratedAcousticPrototype]) -> (protos: [CalibratedAcousticPrototype], refGeom: String?) {
            guard !all.isEmpty else { return ([], nil) }
            if let sg = geometryCondition, !sg.isEmpty {
                let exact = all.filter { ($0.geometryCondition ?? sg) == sg }
                if !exact.isEmpty {
                    return (exact, exact.first?.geometryCondition ?? sg)
                }
            }
            return (all, all.first?.geometryCondition)
        }

        let dEmpty: DifferentialBaselineVector? = {
            let picked = pickGeometryMatched(emptyAll)
            guard !picked.protos.isEmpty else { return nil }
            let refMV = aggregatePrototypeModalVector(picked.protos)
            return DifferentialBaselineVector.compute(
                sample: sampleMV,
                sampleGeometry: geometryCondition,
                reference: refMV,
                referenceTargetID: CalibratedAcousticPrototype.emptyContainerTargetID,
                referenceGeometry: picked.refGeom
            )
        }()

        let dWater: DifferentialBaselineVector? = {
            let picked = pickGeometryMatched(waterAll)
            guard !picked.protos.isEmpty else { return nil }
            let refMV = aggregatePrototypeModalVector(picked.protos)
            return DifferentialBaselineVector.compute(
                sample: sampleMV,
                sampleGeometry: geometryCondition,
                reference: refMV,
                referenceTargetID: CalibratedAcousticPrototype.waterReferenceTargetID,
                referenceGeometry: picked.refGeom
            )
        }()

        return (dEmpty, dWater)
    }

    private static func aggregatePrototypeModalVector(_ protos: [CalibratedAcousticPrototype]) -> ModalVector4 {
        if protos.count == 1, let mv = protos[0].features.modalVector {
            return mv
        }
        var sweeps: [(sweepIdx: Int, modes: [BatchModalVectorTracker.SweepModeObservation])] = []
        var slopes: [Double] = []
        var scatters: [Double] = []
        var preRolls: [Double] = []
        for (idx, p) in protos.enumerated() {
            preRolls.append(p.features.latePreRollNoiseDBFS)
            if let mv = p.features.modalVector {
                if let s = mv.spectralAttenuationSlopeDBPerKHz, s.isFinite { slopes.append(s) }
                if let sc = mv.bubbleScatter55to85DB, sc.isFinite { scatters.append(sc) }
                var obs: [BatchModalVectorTracker.SweepModeObservation] = []
                for k in 0..<4 where mv.validityMask[k] == 1 {
                    if let f = mv.frequenciesHz[k], f.isFinite {
                        obs.append(
                            BatchModalVectorTracker.SweepModeObservation(
                                freqHz: f,
                                ampDB: p.features.primaryPeakAmplitudeDB,
                                qFactor: mv.qValidityMask[k] == 1 ? mv.qualityFactorsQ[k] : nil,
                                alphaPerSec: mv.decayValidityMask[k] == 1 ? mv.decayAlphaPerSec[k] : nil,
                                alphaDBPerSec: mv.decayValidityMask[k] == 1 ? mv.decayDBPerSec[k] : nil,
                                alphaRSquared: mv.decayValidityMask[k] == 1 ? mv.decayRSquared[k] : nil
                            )
                        )
                    }
                }
                sweeps.append((idx + 1, obs))
            } else {
                var obs = [BatchModalVectorTracker.SweepModeObservation(freqHz: p.features.dominantPeakHz, ampDB: p.features.primaryPeakAmplitudeDB)]
                for sf in p.features.secondaryPeaksHz where sf > 0 {
                    obs.append(BatchModalVectorTracker.SweepModeObservation(freqHz: sf, ampDB: p.features.primaryPeakAmplitudeDB - 3.0))
                }
                sweeps.append((idx + 1, obs))
            }
        }
        let medSlope = slopes.isEmpty ? nil : slopes.sorted()[slopes.count / 2]
        let medScat = scatters.isEmpty ? nil : scatters.sorted()[scatters.count / 2]
        let medPre = preRolls.isEmpty ? -82.0 : preRolls.sorted()[preRolls.count / 2]
        return BatchModalVectorTracker.trackSweeps(
            sweeps: sweeps,
            persistenceFraction: 0.50,
            medianSlope: medSlope,
            medianScatter: medScat,
            medianLatePreRoll: medPre
        )
    }

    /// Computes deconvolved noise power per bin strictly from the late pre-roll silence buffer:
    /// `N_deconv(b) = P_latePreRoll(b) * |G_inv(b)|^2`, avoiding both early Sweep-1 bleed and post-tail echoes.
    public static func computeDeconvolvedPreRollNoiseSpectrum(
        latePreRollSlice: [Double],
        invDouble: [Double],
        nFFT: Int
    ) -> [Double] {
        let halfBins = nFFT / 2
        guard latePreRollSlice.count >= 128, !invDouble.isEmpty else {
            return [Double](repeating: 0.0, count: halfBins)
        }
        let fLen = min(latePreRollSlice.count, nFFT)
        var nr = [Double](repeating: 0.0, count: nFFT)
        var ni = [Double](repeating: 0.0, count: nFFT)
        var wNormNoise = 0.0
        for i in 0..<fLen {
            let w = 0.5 * (1.0 - cos(2.0 * Double.pi * Double(i) / Double(max(1, fLen - 1))))
            nr[i] = latePreRollSlice[i] * w
            wNormNoise += w * w
        }
        fftRadix2(real: &nr, imag: &ni, inverse: false)

        // Evaluate inverse-filter transfer power |G_inv|^2 on a power-of-2 grid >= max(nFFT, invDouble.count)
        var invFftLen = max(nFFT, 1)
        while invFftLen < invDouble.count { invFftLen <<= 1 }
        var gr = [Double](repeating: 0.0, count: invFftLen)
        var gi = [Double](repeating: 0.0, count: invFftLen)
        for i in 0..<invDouble.count { gr[i] = invDouble[i] }
        fftRadix2(real: &gr, imag: &gi, inverse: false)
        let ratio = invFftLen / nFFT

        var rawNP = [Double](repeating: 0.0, count: halfBins)
        let invWNorm = 1.0 / max(1e-9, wNormNoise)
        for b in 0..<halfBins {
            let pPre = (nr[b] * nr[b] + ni[b] * ni[b]) * invWNorm
            let gIdx = min(invFftLen / 2, b * ratio)
            let gMag2 = gr[gIdx] * gr[gIdx] + gi[gIdx] * gi[gIdx]
            rawNP[b] = pPre * gMag2
        }

        var smoothed = [Double](repeating: 0.0, count: halfBins)
        for b in 1..<(halfBins - 1) {
            var s = 0.0
            var c = 0.0
            let kLo = max(1, b - 6)
            let kHi = min(halfBins - 1, b + 6)
            for k in kLo...kHi {
                s += rawNP[k]
                c += 1.0
            }
            smoothed[b] = c > 0 ? (s / c) : rawNP[b]
        }
        return smoothed
    }

    /// Chu-compensated Narrowband Schroeder Energy Decay Curve (EDC) estimator (`LA-R2-A-SANDBOX-REPORT-001` Sec. 5.1).
    /// Removes the legacy 145.0 dB/s ceiling and integrates narrowband energy backwards to average out cavity multipath beats.
    public static func estimateSchroederEDCDecay(
        signal: [Double],
        modeFreqHz: Double,
        latePreRollSlice: [Double],
        invEnergyGain: Double,
        sampleRateHz: Double,
        isDeconvolvedTail: Bool
    ) -> (alphaPerSec: Double?, decayDBPerSec: Double?, rSquared: Double?) {
        let len = signal.count
        let firLen = isDeconvolvedTail ? 193 : 257
        guard len >= max(160, firLen), modeFreqHz > 200.0 else {
            return (nil, nil, nil)
        }
        let halfFir = (firLen - 1) / 2
        var hBp = [Double](repeating: 0.0, count: firLen)
        var norm = 0.0
        for k in 0..<firLen {
            let w = 0.5 * (1.0 - cos(2.0 * Double.pi * Double(k) / Double(firLen - 1)))
            let v = w * cos(2.0 * Double.pi * modeFreqHz * Double(k - halfFir) / sampleRateHz)
            hBp[k] = v
            norm += v * v
        }
        let invNorm = 1.0 / sqrt(max(1e-30, norm))
        for k in 0..<firLen { hBp[k] *= invNorm }

        // Chu (1978) narrowband baseline noise variance from late pre-roll silence slice
        var noiseSqSum = 0.0
        var noiseCnt = 0
        if latePreRollSlice.count > firLen {
            var idx = halfFir
            while idx + halfFir < latePreRollSlice.count {
                var acc = 0.0
                for k in 0..<firLen {
                    acc += latePreRollSlice[idx - halfFir + k] * hBp[k]
                }
                noiseSqSum += acc * acc
                noiseCnt += 1
                idx += 12
            }
        }
        let meanNoiseSq = (noiseCnt > 0 ? (noiseSqSum / Double(noiseCnt)) : 0.0) * max(1.0, invEnergyGain)

        var bpSq = [Double](repeating: 0.0, count: len)
        for n in 0..<len {
            var acc = 0.0
            for k in 0..<firLen {
                let sIdx = n - halfFir + k
                if sIdx >= 0 && sIdx < len {
                    acc += signal[sIdx] * hBp[k]
                }
            }
            bpSq[n] = max(0.0, acc * acc - meanNoiseSq)
        }

        var edc = [Double](repeating: 0.0, count: len)
        edc[len - 1] = bpSq[len - 1]
        if len >= 2 {
            for n in stride(from: len - 2, through: 0, by: -1) {
                edc[n] = edc[n + 1] + bpSq[n]
            }
        }
        guard edc[0] > 1e-30 else { return (nil, nil, nil) }

        let fitStart = isDeconvolvedTail ? Int(0.0005 * sampleRateHz) : Int(0.005 * sampleRateHz)
        let fitEnd = isDeconvolvedTail
            ? min(len - 8, Int(0.0095 * sampleRateHz))
            : min(len - 32, Int(0.080 * sampleRateHz))
        let step = isDeconvolvedTail ? 16 : 48
        guard fitEnd > fitStart + step * 4 else { return (nil, nil, nil) }

        var ts: [Double] = []
        var ys: [Double] = []
        var n = fitStart
        while n < fitEnd {
            if edc[n] <= 0.01 * edc[0] { break }
            ts.append(Double(n) / sampleRateHz)
            ys.append(0.5 * log(edc[n] / edc[0]))
            n += step
        }
        guard ts.count >= 5 else { return (nil, nil, nil) }

        let countD = Double(ts.count)
        let mt = ts.reduce(0.0, +) / countD
        let my = ys.reduce(0.0, +) / countD
        var sxx = 0.0
        var sxy = 0.0
        for i in 0..<ts.count {
            let dt = ts[i] - mt
            sxx += dt * dt
            sxy += dt * (ys[i] - my)
        }
        guard sxx > 1e-24 else { return (nil, nil, nil) }
        let slope = sxy / sxx
        let b0 = my - slope * mt
        var ssr = 0.0
        var sst = 0.0
        for i in 0..<ts.count {
            let pred = b0 + slope * ts[i]
            let r = ys[i] - pred
            let d = ys[i] - my
            ssr += r * r
            sst += d * d
        }
        let alpha = -slope
        guard alpha.isFinite && alpha > 0.0 else { return (nil, nil, nil) }
        let r2 = sst > 1e-18 ? max(0.0, 1.0 - ssr / sst) : 0.0
        let dbPerSec = (20.0 / log(10.0)) * alpha
        return (alpha, dbPerSec, r2)
    }

    /// Extracts the Phase R2-B 4-Mode Vector (`ModalVector4`) with 3-point log-magnitude parabolic `E1` interpolation,
    /// monotonic `-3 dB` spectral `Q_i` (rejecting mode overlaps without clamping), Chu-compensated Schroeder EDC `alpha_i`,
    /// ESS-normalized modal-excluded `S_att`, `[5.5-8.5]/[2.0-4.5] kHz` bubble scatter, and `mask_i = 0, f_i = NaN` for absent modes.
    public static func extractModalVector4(
        analysisSignal: [Double],
        latePreRollSlice: [Double],
        inverseFilter: [Float]?,
        invEnergyGain: Double,
        sampleRateHz: Double,
        latePreRollDBFS: Double,
        isDeconvolvedTail: Bool
    ) -> ModalVector4 {
        let nFFT = 8_192
        let halfBins = nFFT / 2
        let copyLen = min(analysisSignal.count, nFFT)
        guard copyLen >= 128 else {
            return ModalVector4(
                frequenciesHz: [nil, nil, nil, nil],
                validityMask: [0, 0, 0, 0],
                qualityFactorsQ: [nil, nil, nil, nil],
                qValidityMask: [0, 0, 0, 0],
                decayAlphaPerSec: [nil, nil, nil, nil],
                decayDBPerSec: [nil, nil, nil, nil],
                decayRSquared: [nil, nil, nil, nil],
                decayValidityMask: [0, 0, 0, 0],
                spectralAttenuationSlopeDBPerKHz: nil,
                bubbleScatter55to85DB: nil,
                latePreRollNoiseDBFS: latePreRollDBFS
            )
        }

        var re = [Double](repeating: 0.0, count: nFFT)
        var im = [Double](repeating: 0.0, count: nFFT)
        var wNorm = 0.0
        for i in 0..<copyLen {
            let w = 0.5 * (1.0 - cos(2.0 * Double.pi * Double(i) / Double(max(1, copyLen - 1))))
            re[i] = analysisSignal[i] * w
            wNorm += w * w
        }
        fftRadix2(real: &re, imag: &im, inverse: false)
        let invWNorm = 1.0 / max(1e-9, wNorm)
        var power = [Double](repeating: 0.0, count: halfBins)
        for b in 0..<halfBins {
            power[b] = (re[b] * re[b] + im[b] * im[b]) * invWNorm
        }

        let invDouble = inverseFilter?.map { $0.isFinite ? Double($0) : 0.0 } ?? []
        let noiseSpec: [Double]
        if isDeconvolvedTail && !invDouble.isEmpty {
            noiseSpec = computeDeconvolvedPreRollNoiseSpectrum(
                latePreRollSlice: latePreRollSlice,
                invDouble: invDouble,
                nFFT: nFFT
            )
        } else {
            var np = [Double](repeating: 0.0, count: halfBins)
            if latePreRollSlice.count >= 128 {
                let fLen = min(latePreRollSlice.count, nFFT)
                var nr = [Double](repeating: 0.0, count: nFFT)
                var ni = [Double](repeating: 0.0, count: nFFT)
                var wn = 0.0
                for i in 0..<fLen {
                    let w = 0.5 * (1.0 - cos(2.0 * Double.pi * Double(i) / Double(max(1, fLen - 1))))
                    nr[i] = latePreRollSlice[i] * w
                    wn += w * w
                }
                fftRadix2(real: &nr, imag: &ni, inverse: false)
                for b in 0..<halfBins {
                    np[b] = (nr[b] * nr[b] + ni[b] * ni[b]) / max(1e-9, wn)
                }
            }
            noiseSpec = np
        }

        let df = sampleRateHz / Double(nFFT)
        let mainlobeWidthHz = 1.44 * (sampleRateHz / Double(copyLen)) // Hann -3 dB mainlobe width
        let kMin = max(2, Int(ceil(1_100.0 / df)))
        let kMax = min(halfBins - 3, Int(floor(5_500.0 / df)))
        let flankBins = max(3, Int(round(250.0 / df)))
        let minSepBins = max(2, Int(round(150.0 / df)))

        struct RawModeCand {
            let bin: Int
            let fE1Hz: Double
            let peakPower: Double
            let prominenceDB: Double
            let localSnrDB: Double
        }

        var rawPeaks: [RawModeCand] = []
        if kMax > kMin {
            for k in kMin...kMax {
                if power[k] > power[k - 1] && power[k] >= power[k + 1] && power[k] > 1e-24 {
                    var minL = power[k]
                    var minR = power[k]
                    for j in max(1, k - flankBins)..<k { if power[j] < minL { minL = power[j] } }
                    for j in (k + 1)...min(halfBins - 2, k + flankBins) { if power[j] < minR { minR = power[j] } }
                    let refTrough = max(minL, minR, 1e-30)
                    let promDB = 10.0 * log10(power[k] / refTrough)
                    if promDB < 3.0 { continue }

                    let lnL = 0.5 * log(max(power[k - 1], 1e-36))
                    let ln0 = 0.5 * log(max(power[k], 1e-36))
                    let lnR = 0.5 * log(max(power[k + 1], 1e-36))
                    let denom = lnL - 2.0 * ln0 + lnR
                    if !denom.isFinite || abs(denom) <= 1e-9 { continue }
                    let delta = max(-0.5, min(0.5, 0.5 * (lnL - lnR) / denom))
                    let lnPeak = ln0 - 0.25 * (lnL - lnR) * delta
                    let pkPow = exp(2.0 * lnPeak)
                    let locNoise = max(noiseSpec[k], 1e-30)
                    let locSnrDB = 10.0 * log10(max(1e-6, pkPow / locNoise))
                    if locSnrDB < 6.0 { continue }

                    rawPeaks.append(
                        RawModeCand(
                            bin: k,
                            fE1Hz: (Double(k) + delta) * df,
                            peakPower: pkPow,
                            prominenceDB: promDB,
                            localSnrDB: locSnrDB
                        )
                    )
                }
            }
        }

        rawPeaks.sort { $0.peakPower > $1.peakPower }
        let maxPeakPow = rawPeaks.first?.peakPower ?? 0.0
        // Reject finite-window truncation sinc sidelobes (<= -19 dB) while preserving real multi-mode resonances
        let sidelobeFloorPower = maxPeakPow * pow(10.0, -14.0 / 10.0)
        var selected: [RawModeCand] = []
        for p in rawPeaks where p.peakPower >= sidelobeFloorPower {
            if selected.contains(where: { abs($0.bin - p.bin) < minSepBins }) { continue }
            selected.append(p)
            if selected.count >= 4 { break }
        }
        // Order physical modes by ascending frequency within the sweep; if < 4 modes exist, remaining slots stay nil/NaN
        selected.sort { $0.fE1Hz < $1.fE1Hz }

        var fOut: [Double?] = [nil, nil, nil, nil]
        var fMask: [Int] = [0, 0, 0, 0]
        var qOut: [Double?] = [nil, nil, nil, nil]
        var qMask: [Int] = [0, 0, 0, 0]
        var aOut: [Double?] = [nil, nil, nil, nil]
        var aDBOut: [Double?] = [nil, nil, nil, nil]
        var aR2Out: [Double?] = [nil, nil, nil, nil]
        var aMask: [Int] = [0, 0, 0, 0]
        var detectedExclusions: [(centerHz: Double, halfWidthHz: Double)] = []

        for (slot, cand) in selected.enumerated() where slot < 4 {
            fOut[slot] = cand.fE1Hz
            fMask[slot] = 1

            // Monotonic -3 dB spectral Q_i (never clamped; rejects intervening saddle overlap as nil)
            let k0 = cand.bin
            let cleanPeak = max(0.0, cand.peakPower - noiseSpec[k0])
            let halfTarget = 0.5 * cleanPeak
            var bwHz: Double?
            if cleanPeak > 0 && cand.localSnrDB >= 10.0 {
                let qMinBin = max(1, Int(floor(600.0 / df)))
                let qMaxBin = min(halfBins - 2, Int(ceil(12_000.0 / df)))
                var kLStar: Double?
                var prevL = max(cleanPeak, max(0.0, power[k0] - noiseSpec[k0]))
                var overlapL = false
                if k0 - 1 >= qMinBin {
                    for k in stride(from: k0 - 1, through: qMinBin, by: -1) {
                        let c = max(0.0, power[k] - noiseSpec[k])
                        if c <= halfTarget {
                            let cHi = (k == k0 - 1) ? cleanPeak : max(0.0, power[k + 1] - noiseSpec[k + 1])
                            let frac = (halfTarget - c) / max(1e-30, cHi - c)
                            kLStar = Double(k) + frac
                            break
                        }
                        if c > prevL * 1.08 {
                            overlapL = true
                            break
                        }
                        prevL = min(prevL, c)
                    }
                }
                var kRStar: Double?
                var prevR = max(cleanPeak, max(0.0, power[k0] - noiseSpec[k0]))
                var overlapR = false
                if k0 + 1 <= qMaxBin {
                    for k in (k0 + 1)...qMaxBin {
                        let c = max(0.0, power[k] - noiseSpec[k])
                        if c <= halfTarget {
                            let cHi = (k == k0 + 1) ? cleanPeak : max(0.0, power[k - 1] - noiseSpec[k - 1])
                            let frac = (cHi - halfTarget) / max(1e-30, cHi - c)
                            kRStar = Double(k - 1) + frac
                            break
                        }
                        if c > prevR * 1.08 {
                            overlapR = true
                            break
                        }
                        prevR = min(prevR, c)
                    }
                }
                if !overlapL, !overlapR, let kl = kLStar, let kr = kRStar, kr > kl {
                    let candidateBW = (kr - kl) * df
                    if candidateBW >= 0.80 * mainlobeWidthHz {
                        bwHz = candidateBW
                        qOut[slot] = cand.fE1Hz / candidateBW
                        qMask[slot] = 1
                    }
                }
            }
            detectedExclusions.append((cand.fE1Hz, max(120.0, 1.5 * (bwHz ?? 80.0))))

            let edc = estimateSchroederEDCDecay(
                signal: analysisSignal,
                modeFreqHz: cand.fE1Hz,
                latePreRollSlice: latePreRollSlice,
                invEnergyGain: isDeconvolvedTail ? invEnergyGain : 1.0,
                sampleRateHz: sampleRateHz,
                isDeconvolvedTail: isDeconvolvedTail
            )
            if let alpha = edc.alphaPerSec, let dbS = edc.decayDBPerSec {
                aOut[slot] = alpha
                aDBOut[slot] = dbS
                aR2Out[slot] = edc.rSquared
                aMask[slot] = 1
            }
        }

        // Modal-neighborhood-excluded spectral attenuation slope S_att (dB/kHz) over [1.2 .. 6.0 kHz]
        var xs: [Double] = []
        var ys: [Double] = []
        var ws: [Double] = []
        for k in 1..<halfBins {
            let fHz = Double(k) * df
            let fKhz = fHz / 1_000.0
            if fKhz < 1.2 || fKhz > 6.0 { continue }
            if detectedExclusions.contains(where: { abs(fHz - $0.centerHz) <= $0.halfWidthHz }) { continue }
            let cleanP = power[k] - noiseSpec[k]
            let snrLin = cleanP / max(noiseSpec[k], 1e-30)
            if cleanP <= 1e-30 || snrLin < 2.0 { continue }
            xs.append(fKhz)
            ys.append(10.0 * log10(cleanP))
            ws.append(min(20.0, sqrt(snrLin)))
        }

        var sAtt: Double?
        if xs.count >= 20, let firstX = xs.first, let lastX = xs.last, (lastX - firstX) >= 1.5 {
            var sw = 0.0, swx = 0.0, swy = 0.0, swxx = 0.0, swxy = 0.0
            for i in 0..<xs.count {
                let w = ws[i]
                sw += w
                swx += w * xs[i]
                swy += w * ys[i]
                swxx += w * xs[i] * xs[i]
                swxy += w * xs[i] * ys[i]
            }
            let denom = sw * swxx - swx * swx
            if denom > 1e-12 {
                // Compensate for intrinsic -2.05 dB/kHz ESS inverse-filter deconvolution roll-off established in PC-04
                let rawSlope = (sw * swxy - swx * swy) / denom
                sAtt = isDeconvolvedTail ? (rawSlope + 2.05) : rawSlope
            }
        }

        // Bubble-Sensitive High-Frequency Scatter [5.5-8.5 kHz] vs [2.0-4.5 kHz]
        var sumHF = 0.0
        var sumLF = 0.0
        for k in 1..<halfBins {
            let fKhz = (Double(k) * df) / 1_000.0
            let cleanP = max(0.0, power[k] - noiseSpec[k])
            if fKhz >= 5.5 && fKhz <= 8.5 { sumHF += cleanP }
            if fKhz >= 2.0 && fKhz <= 4.5 { sumLF += cleanP }
        }
        let sHF55to85: Double? = (sumLF > 1e-30 && sumHF > 1e-30) ? (10.0 * log10(sumHF / sumLF)) : nil

        return ModalVector4(
            frequenciesHz: fOut,
            validityMask: fMask,
            qualityFactorsQ: qOut,
            qValidityMask: qMask,
            decayAlphaPerSec: aOut,
            decayDBPerSec: aDBOut,
            decayRSquared: aR2Out,
            decayValidityMask: aMask,
            spectralAttenuationSlopeDBPerKHz: sAtt,
            bubbleScatter55to85DB: sHF55to85,
            latePreRollNoiseDBFS: latePreRollDBFS
        )
    }

    // MARK: - Pure Swift Audio & FFT Utilities

    private static func bandPower(
        slice: [Double],
        sampleRateHz: Double,
        lowHz: Double,
        highHz: Double
    ) -> Double {
        guard slice.count >= 256 else { return 0.0 }
        let nFFT = 2_048
        var real = [Double](repeating: 0.0, count: nFFT)
        var imag = [Double](repeating: 0.0, count: nFFT)
        let count = min(slice.count, nFFT)
        for i in 0..<count {
            let w = 0.5 * (1.0 - cos(2.0 * Double.pi * Double(i) / Double(max(1, count - 1))))
            real[i] = slice[i] * w
        }
        fftRadix2(real: &real, imag: &imag, inverse: false)
        let binHz = sampleRateHz / Double(nFFT)
        let b0 = max(1, Int(ceil(lowHz / binHz)))
        let b1 = min(nFFT / 2 - 1, Int(floor(highHz / binHz)))
        guard b1 >= b0 else { return 0.0 }
        var sum = 0.0
        for b in b0...b1 {
            sum += real[b] * real[b] + imag[b] * imag[b]
        }
        return sum / Double(nFFT * nFFT)
    }

    private static func readMonoFloatSamplesAndRate(from url: URL) throws -> (samples: [Float], sampleRateHz: Double) {
        let file = try AVAudioFile(forReading: url)
        let sr = file.processingFormat.sampleRate > 0 ? file.processingFormat.sampleRate : 48_000.0
        let count = Int(file.length)
        guard count > 0,
              let buf = AVAudioPCMBuffer(
                  pcmFormat: file.processingFormat,
                  frameCapacity: AVAudioFrameCount(count)
              ) else {
            return ([], sr)
        }
        try file.read(into: buf)
        guard let ptr = buf.floatChannelData?[0] else { return ([], sr) }
        let n = Int(buf.frameLength)
        return (Array(UnsafeBufferPointer(start: ptr, count: n)), sr)
    }

    private static func segmentRMS(_ samples: [Float], start: Int, end: Int) -> Double {
        let n = end - start
        guard n > 0 else { return 0.0 }
        var sum = 0.0
        for i in start..<end {
            let v = Double(samples[i])
            if v.isFinite { sum += v }
        }
        let mean = sum / Double(n)
        var sq = 0.0
        for i in start..<end {
            let v = Double(samples[i])
            if v.isFinite {
                let d = v - mean
                sq += d * d
            }
        }
        return sqrt(sq / Double(n))
    }

    private static func fastLinearConvolve(_ a: [Double], _ b: [Double]) -> [Double] {
        let total = a.count + b.count - 1
        var nFFT = 1
        while nFFT < total { nFFT <<= 1 }

        var ar = [Double](repeating: 0.0, count: nFFT)
        var ai = [Double](repeating: 0.0, count: nFFT)
        var br = [Double](repeating: 0.0, count: nFFT)
        var bi = [Double](repeating: 0.0, count: nFFT)

        for i in 0..<a.count { ar[i] = a[i] }
        for i in 0..<b.count { br[i] = b[i] }

        fftRadix2(real: &ar, imag: &ai, inverse: false)
        fftRadix2(real: &br, imag: &bi, inverse: false)

        for i in 0..<nFFT {
            let rr = ar[i] * br[i] - ai[i] * bi[i]
            let ii = ar[i] * bi[i] + ai[i] * br[i]
            ar[i] = rr
            ai[i] = ii
        }

        fftRadix2(real: &ar, imag: &ai, inverse: true)
        return Array(ar.prefix(total))
    }

    public static func fftRadix2(real: inout [Double], imag: inout [Double], inverse: Bool) {
        let n = real.count
        guard n > 1 && (n & (n - 1)) == 0 else { return }

        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while (j & bit) != 0 {
                j ^= bit
                bit >>= 1
            }
            j ^= bit
            if i < j {
                real.swapAt(i, j)
                imag.swapAt(i, j)
            }
        }

        var len = 2
        let sign = inverse ? 1.0 : -1.0
        while len <= n {
            let ang = sign * 2.0 * Double.pi / Double(len)
            let wlenR = cos(ang)
            let wlenI = sin(ang)
            let half = len >> 1
            var i = 0
            while i < n {
                var wR = 1.0
                var wI = 0.0
                for k in 0..<half {
                    let uR = real[i + k]
                    let uI = imag[i + k]
                    let vR = real[i + k + half] * wR - imag[i + k + half] * wI
                    let vI = real[i + k + half] * wI + imag[i + k + half] * wR
                    real[i + k] = uR + vR
                    imag[i + k] = uI + vI
                    real[i + k + half] = uR - vR
                    imag[i + k + half] = uI - vI
                    let nextWR = wR * wlenR - wI * wlenI
                    wI = wR * wlenI + wI * wlenR
                    wR = nextWR
                }
                i += len
            }
            len <<= 1
        }

        if inverse {
            let scale = 1.0 / Double(n)
            for i in 0..<n {
                real[i] *= scale
                imag[i] *= scale
            }
        }
    }
}
