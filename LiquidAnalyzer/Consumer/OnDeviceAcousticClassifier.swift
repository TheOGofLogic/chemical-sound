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
    private let visualAnalyzer = VisualLiquidContextAnalyzer()

    public init(
        referenceLibrary: [ReferenceLiquidProfile] = ReferenceLiquidProfile.provisionalLibrary,
        distanceThreshold: Double = 0.75,
        minimumWinningMargin: Double = 0.11,
        minimumSNRDB: Double = 1.8
    ) {
        self.referenceLibrary = referenceLibrary
        self.distanceThreshold = distanceThreshold
        self.minimumWinningMargin = minimumWinningMargin
        self.minimumSNRDB = minimumSNRDB
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
        calibratedPrototypes: [CalibratedAcousticPrototype] = []
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
            calibratedPrototypes: calibratedPrototypes
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
        calibratedPrototypes: [CalibratedAcousticPrototype] = []
    ) -> ConsumerScanItem {
        let visual = visualAnalyzer.analyze(jpegData: thumbnailJPEGData, sceneContextJPEGData: sceneContextJPEGData)
        let features = extractFeatures(
            samples: samples,
            inverseFilter: inverseFilter,
            sampleRateHz: sampleRateHz,
            preRollFrames: preRollFrames,
            activeFrames: activeFrames,
            clippingCeilingDBFS: clippingCeilingDBFS,
            visual: visual,
            opticsLocked: opticsLocked
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
                thumbnailJPEGData: thumbnailJPEGData
            )
        }

        // 3. Calibrated Indirect Inference (when explicit empirical standards have been saved on-device)
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
               thumbnailJPEGData: thumbnailJPEGData
           ) {
            return calibratedResult
        }

        // 4. Layer 2 Acoustic Specular Flat-Surface Guard
        if visual.hint != .audioOnly &&
            !visual.hasBarcode &&
            visual.vesselConfidence < 0.16 &&
            features.spectralFlatness > 0.58 &&
            features.peakProminenceDB < 7.5 {
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
                thumbnailJPEGData: thumbnailJPEGData
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
            thumbnailJPEGData: thumbnailJPEGData
        )
    }

    private func computeFrozenCandidateDistances(
        profiles: [ReferenceLiquidProfile],
        features: ExtractedConsumerFeatures
    ) -> [(profile: ReferenceLiquidProfile, distance: Double)] {
        profiles.map { prof in
            let dPeak = (features.dominantPeakHz - prof.expectedPeakHz) / 580.0
            let dCent = (features.spectralCentroidHz - prof.expectedCentroidHz) / 650.0
            let dBand = (features.midToHighBandDB - prof.expectedMidToHighDB) / 3.8
            let dDecay = (features.decaySlopeDBPerSec - prof.expectedDecayDBPerSec) / 38.0
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
        let dDecay = (a.decaySlopeDBPerSec - b.decaySlopeDBPerSec) / 30.0
        let dScatter = (a.highFreqBubbleScatterDB - b.highFreqBubbleScatterDB) / 3.4
        let dCavity = (a.cavityMultipathDB - b.cavityMultipathDB) / 3.4
        let dEcho = (a.echoReturnDB - b.echoReturnDB) / 4.5

        let macroSq = 0.24 * dPeak * dPeak +
            0.22 * dCent * dCent +
            0.14 * dDecay * dDecay +
            0.16 * dScatter * dScatter +
            0.12 * dCavity * dCavity +
            0.12 * dEcho * dEcho

        let acousticSq = 0.55 * subBandSq + 0.45 * macroSq
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
            opticsLocked: items.allSatisfy(\.opticsLocked)
        )
    }

    private func displayTitleForTarget(_ targetID: String) -> String {
        if targetID == CalibratedAcousticPrototype.emptyContainerTargetID {
            return "Empty Container"
        }
        if targetID == CalibratedAcousticPrototype.solidSurfaceTargetID {
            return "Solid / Non-Liquid Material"
        }
        return referenceLibrary.first(where: { $0.id == targetID })?.displayName ?? targetID
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
        thumbnailJPEGData: Data?
    ) -> ConsumerScanItem? {
        var grouped: [String: [ExtractedConsumerFeatures]] = [:]
        for proto in prototypes {
            grouped[proto.targetID, default: []].append(proto.features)
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
                thumbnailJPEGData: thumbnailJPEGData
            )
        }

        guard let matchedProfile = referenceLibrary.first(where: { $0.id == bestTarget.targetID }) else {
            return nil
        }

        let note: String
        if matchedProfile.id == "NACL_AQ" {
            note = "Salt signature detected under the calibrated acquisition setup (d = \(String(format: "%.2f", bestTarget.distance)), margin = +\(String(format: "%.2f", margin)))."
        } else if matchedProfile.id == "H2O_DIST" {
            note = "Matches plain water blank under the calibrated setup—no reliable solute shift detected at this sensitivity."
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
            thumbnailJPEGData: thumbnailJPEGData
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
        opticsLocked: Bool = false
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
                opticsLocked: opticsLocked
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

        if let inv = inverseFilter, !inv.isEmpty, samples.count > max(512, inv.count / 2) {
            // 1. Convolve full recording with matched ESS inverse filter for exact sample-accurate sync!
            let fullDouble = samples.map { $0.isFinite ? Double($0) : 0.0 }
            let invDouble = inv.map { $0.isFinite ? Double($0) : 0.0 }
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

            // 2. Recompute pre-roll & active sweep RMS on exact sample-aligned sweep bounds
            let alignedActStart = max(0, min(samples.count - 1, peakIdx - (inv.count - 1)))
            let alignedActEnd = min(samples.count, alignedActStart + max(1, activeFrames))
            alignmentOffsetSamples = alignedActStart - preRollFrames

            // Skip initial 25 ms hardware ADC startup transient and leave 5 ms guard before sweep onset
            let settleSkip = min(alignedActStart, Int(0.025 * sampleRateHz))
            let guardSamples = Int(0.005 * sampleRateHz)
            let alignedPreEnd = max(0, alignedActStart - guardSamples)
            let alignedPreStart = (alignedPreEnd - settleSkip >= 256) ? settleSkip : 0

            if alignedPreEnd > alignedPreStart + 64 {
                preRMS = Self.segmentRMS(samples, start: alignedPreStart, end: alignedPreEnd)
                preEnd = alignedPreEnd
            }
            if alignedActEnd > alignedActStart + 256 {
                actRMS = Self.segmentRMS(samples, start: alignedActStart, end: alignedActEnd)
                actStart = alignedActStart
                actEnd = alignedActEnd
            }
            preDB = ImmediateAudioAnalyzer.linearToDBFS(preRMS)
            actDB = ImmediateAudioAnalyzer.linearToDBFS(actRMS)
            snrDB = max(0.0, actDB - preDB)

            // 3. Causal container reflection gate [t0 + 1.25 ms .. t0 + 15.0 ms]
            // Captures close-up & 15-in (2.22 ms) arrival at unity weight while cutting >2.5 m room walls
            let dirStart = max(0, peakIdx - Int(0.0004 * sampleRateHz))
            let dirEnd = min(ir.count, peakIdx + Int(0.0011 * sampleRateHz))
            let tailStart = min(ir.count, peakIdx + Int(0.00125 * sampleRateHz))
            let tailEnd = min(ir.count, peakIdx + Int(0.0150 * sampleRateHz))

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

            // 4. Empirical deconvolved noise spectrum from quiet post-tail region [t0 + 42 ms .. t0 + 68 ms]
            // Removes Farina ESS inverse-filter +3 dB/octave high-frequency noise tilt without frequency bias!
            let floorStart = min(ir.count, peakIdx + Int(0.0420 * sampleRateHz))
            let floorEnd = min(ir.count, peakIdx + Int(0.0680 * sampleRateHz))
            var noisePowerSpec = [Double](repeating: 0.0, count: nFFT / 2)
            if floorEnd - floorStart >= 256 {
                let floorSlice = Array(ir[floorStart..<floorEnd])
                let fLen = min(floorSlice.count, nFFT)
                let floorSum = floorSlice[0..<fLen].reduce(0.0) { $0 + $1 * $1 }
                noiseFloorPowerPerSample = floorSum / Double(fLen)

                var nr = [Double](repeating: 0.0, count: nFFT)
                var ni = [Double](repeating: 0.0, count: nFFT)
                var wNormNoise = 0.0
                for i in 0..<fLen {
                    let w = 0.5 * (1.0 - cos(2.0 * Double.pi * Double(i) / Double(max(1, fLen - 1))))
                    nr[i] = floorSlice[i] * w
                    wNormNoise += w * w
                }
                Self.fftRadix2(real: &nr, imag: &ni, inverse: false)
                var rawNP = [Double](repeating: 0.0, count: nFFT / 2)
                let invWNorm = 1.0 / max(1e-9, wNormNoise)
                for b in 0..<(nFFT / 2) {
                    rawNP[b] = (nr[b] * nr[b] + ni[b] * ni[b]) * invWNorm
                }
                for b in 1..<(nFFT / 2 - 1) {
                    var s = 0.0
                    var c = 0.0
                    let kLo = max(1, b - 6)
                    let kHi = min(nFFT / 2 - 1, b + 6)
                    for k in kLo...kHi {
                        s += rawNP[k]
                        c += 1.0
                    }
                    noisePowerSpec[b] = c > 0 ? (s / c) : rawNP[b]
                }
            }

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
            let leadIn = min(Int(0.00045 * sampleRateHz), max(1, copyCount / 6))
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
                    let cFull = max(unitFull * 0.04, unitFull - 1.45 * nf) * windowPowerScale
                    let cEarly = max(unitEarly * 0.04, unitEarly - 1.45 * nf) * windowPowerScale
                    let cSust = max(unitSust * 0.04, unitSust - 1.45 * nf) * windowPowerScale
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

            // Scale settled pre-roll excess micro-bubble fizz into the deconvolved ir gain domain
            if alignedPreEnd > alignedPreStart + 512 {
                let settledPre = Array(samples[alignedPreStart..<alignedPreEnd]).map { $0.isFinite ? Double($0) : 0.0 }
                let preHF = Self.bandPower(slice: settledPre, sampleRateHz: sampleRateHz, lowHz: 5_200.0, highHz: 11_800.0)
                let preMid = Self.bandPower(slice: settledPre, sampleRateHz: sampleRateHz, lowHz: 1_500.0, highHz: 4_200.0)
                let excessFizz = max(0.0, preHF - 0.85 * preMid)
                let deconvGainRatio = netEchoMean / max(actRMS * actRMS, 1e-12)
                scaledPreFizzScatterTerm = 6.0 * excessFizz * Double(nFFT) * deconvGainRatio * windowPowerScale
            }
        } else {
            // Direct active-window analysis path (headless unit tests & non-deconvolved fallback)
            analysisSignal = Array(samples[actStart..<max(actStart + 1, actEnd)]).map { $0.isFinite ? Double($0) : 0.0 }
            let preFizzHighPower = Self.bandPower(
                slice: Array(samples[0..<preEnd]).map { $0.isFinite ? Double($0) : 0.0 },
                sampleRateHz: sampleRateHz,
                lowHz: 5_200.0,
                highHz: 11_800.0
            )
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

        let half = analysisSignal.count / 2
        let decayDBPerSec: Double
        if half >= 64 {
            let rawEarly = analysisSignal[0..<half].reduce(1e-15) { $0 + $1 * $1 } / Double(half)
            let rawLate = analysisSignal[half..<analysisSignal.count].reduce(1e-15) { $0 + $1 * $1 } / Double(analysisSignal.count - half)
            let earlyE = max(1e-14, rawEarly - 0.85 * noiseFloorPowerPerSample)
            let lateE = max(1e-14, rawLate - 0.85 * noiseFloorPowerPerSample)
            let dropDB = min(7.2, max(1.0, 10.0 * log10(earlyE / max(lateE, earlyE * 0.16))))
            let dtSec = max(0.045, Double(half) / sampleRateHz)
            decayDBPerSec = min(145.0, max(50.0, dropDB / dtSec))
        } else {
            decayDBPerSec = 80.0
        }

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
            opticsLocked: opticsLocked
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
        thumbnailJPEGData: Data?
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
            thumbnailJPEGData: thumbnailJPEGData
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
        thumbnailJPEGData: Data?
    ) -> ConsumerScanItem {
        let margin = (topEntry != nil && secondEntry != nil) ? (secondEntry!.distance - topEntry!.distance) : nil
        let gateSummary: String
        if let top = topEntry, let m = margin {
            gateSummary = "Ambiguity Gate R1 held back forced classification (top raw candidate \(top.displayName) d=\(String(format: "%.2f", top.distance)), margin=+\(String(format: "%.2f", m))). Expand 'Repeatability Gate R1 Telemetry' below to inspect all raw measurements."
        } else {
            gateSummary = "Measured acoustic echo without forcing an unverified chemical match. Expand 'Repeatability Gate R1 Telemetry' below for full raw measurements."
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
            gateDecision: gateDecision,
            rejectionReason: rejectionReason,
            status: .unmatchedSignature,
            title: "Unmatched Liquid",
            formulaDisplay: "Acoustic Profile",
            statusBadgeText: "Ambiguity Gate R1 • No Forced Match",
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
            thumbnailJPEGData: thumbnailJPEGData
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
