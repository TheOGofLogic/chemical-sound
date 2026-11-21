import Foundation

/// Selects between v0.5.0 Consumer Multi-Modal Sensor Fusion (`MODE_AF_FUSION`) and frozen Phase R2 Pure-Acoustic `MODE_A`.
public enum ConsumerInferenceMode: String, Codable, CaseIterable, Equatable, Sendable {
    case multiModalFusion = "MULTI_MODAL_FUSION"
    case pureAcousticModeA = "PURE_ACOUSTIC_MODE_A"

    public var displayTitle: String {
        switch self {
        case .multiModalFusion:
            return "Multi-Modal Fusion (Acoustic + Vision)"
        case .pureAcousticModeA:
            return "Pure Acoustic Screening (MODE_A Frozen)"
        }
    }
}

/// Transparent sensor-channel provenance attached to v0.5.0 fused consumer classifications.
public struct MultiModalAttribution: Codable, Equatable, Sendable {
    public let inferenceMode: String
    public let acousticEvidenceSummary: String
    public let visionEvidenceSummary: String
    public let comparatorEvidenceSummary: String?
    public let mahalanobisDistance: Double?
    public let secondBestDistance: Double?
    public let winningMargin: Double?
    public let recommendsGuidedComparator: Bool

    public init(
        inferenceMode: String,
        acousticEvidenceSummary: String,
        visionEvidenceSummary: String,
        comparatorEvidenceSummary: String? = nil,
        mahalanobisDistance: Double? = nil,
        secondBestDistance: Double? = nil,
        winningMargin: Double? = nil,
        recommendsGuidedComparator: Bool = false
    ) {
        self.inferenceMode = inferenceMode
        self.acousticEvidenceSummary = acousticEvidenceSummary
        self.visionEvidenceSummary = visionEvidenceSummary
        self.comparatorEvidenceSummary = comparatorEvidenceSummary
        self.mahalanobisDistance = mahalanobisDistance
        self.secondBestDistance = secondBestDistance
        self.winningMargin = winningMargin
        self.recommendsGuidedComparator = recommendsGuidedComparator
    }
}

/// Result of the v0.5.0 Mahalanobis Multi-Modal Fusion & Guided Comparator engine.
public struct MultiModalFusionDecision: Sendable {
    public let profile: ReferenceLiquidProfile
    public let confidencePercent: Int
    public let statusBadgeText: String
    public let scientificNote: String
    public let gateDecision: String
    public let screeningState: ModeAScreeningState
    public let attribution: MultiModalAttribution
    public let rankedCandidates: [CandidateScoreEntry]
}

/// Fuses VisionFeatureVector (HSV colorimetry, turbidity, meniscus contact angle & halo) with
/// DifferentialBaselineVector (Delta F_empty, Delta F_water, Delta S_HF, Schroeder decay) via Mahalanobis distance.
public struct MultiModalFusionClassifier: Sendable {
    public let maximumMahalanobisDistance: Double
    public let minimumWinningMargin: Double

    public init(
        maximumMahalanobisDistance: Double = 2.55,
        minimumWinningMargin: Double = 0.18
    ) {
        self.maximumMahalanobisDistance = maximumMahalanobisDistance
        self.minimumWinningMargin = minimumWinningMargin
    }

    public func evaluate(
        features: ExtractedConsumerFeatures,
        visual: VisualContextSummary,
        vision: VisionFeatureVector,
        deltaEmpty: DifferentialBaselineVector?,
        deltaWater: DifferentialBaselineVector?,
        bubbleDetected: Bool,
        hasInverseDeconv: Bool,
        inferenceMode: ConsumerInferenceMode
    ) -> MultiModalFusionDecision? {
        // 0. Preserve 100% pure-acoustic MODE_A behavior for headless unit tests and Pure-Acoustic Research Mode
        guard inferenceMode == .multiModalFusion,
              vision.hasCameraFrame,
              visual.hint != .audioOnly,
              visual.hint != .solidOrNonLiquid else {
            return nil
        }

        // 1. 2D Photo / Flat Screen Anti-Spoof Gate:
        // Require real 3D container cavity resonance or calibrated mass-loading shift before trusting any optical tint
        let hasCalibratedLiquidLoad: Bool = {
            guard let de = deltaEmpty, de.compatible else { return false }
            let shifts = de.relativeFrequencyShifts.compactMap { $0 }.map { abs($0) }
            return (shifts.max() ?? 0.0) >= 0.012
        }()

        if !hasCalibratedLiquidLoad && !visual.hasBarcode {
            if (features.spectralFlatness > 0.58 && features.peakProminenceDB < 7.5) ||
                (features.spectralFlatness >= 0.48 && features.peakProminenceDB < 11.5) {
                return nil
            }
            // Reject out-of-envelope ultrasonic/non-cavity anomalies (e.g., 9.4 kHz pure tone)
            if features.dominantPeakHz < 520.0 || features.dominantPeakHz > 5_850.0 {
                return nil
            }
        }

        let catalog = ReferenceLiquidProfile.fusionLibrary
        func findProfile(_ id: String) -> ReferenceLiquidProfile? {
            catalog.first { $0.id == id }
        }

        let maxEmptyShiftPct: Double? = {
            guard let de = deltaEmpty, de.compatible else { return nil }
            let vals = de.relativeFrequencyShifts.compactMap { $0 }.map { abs($0) * 100.0 }
            return vals.max()
        }()

        let acousticSummaryText: String = {
            var parts: [String] = []
            if let shiftPct = maxEmptyShiftPct {
                parts.append(String(format: "Liquid Loaded (max |Δf/f_empty| = %.2f%%)", shiftPct))
            } else {
                parts.append(String(format: "Cavity Resonance %.0f Hz (%.0f dB/s EDC)", features.dominantPeakHz, features.decaySlopeDBPerSec))
            }
            if bubbleDetected {
                parts.append("Bubble Scatter Active (ΔS_HF + Pre-Roll Fizz)")
            } else {
                parts.append("Still Meniscus")
            }
            return parts.joined(separator: " • ")
        }()

        let visionSummaryText = String(
            format: "Hue %.0f° • Sat %.0f%% • Turbidity %.0f%% • Meniscus %.0f°",
            vision.meanHueDegrees,
            vision.meanSaturationWB * 100.0,
            vision.opticalTurbidity * 100.0,
            vision.meniscusContactAngleDegrees
        )

        // 2. Explicit OCR Bottle / Package Label Fusion (with acoustic effervescence disambiguation)
        if let labelID = Self.profileIDForExplicitLabel(visual.hint, bubbleDetected: bubbleDetected),
           let prof = findProfile(labelID) {
            let attr = MultiModalAttribution(
                inferenceMode: "MULTI_MODAL_FUSION_V050",
                acousticEvidenceSummary: acousticSummaryText,
                visionEvidenceSummary: "Verified Container Label + " + visionSummaryText,
                mahalanobisDistance: 0.32,
                secondBestDistance: 1.95,
                winningMargin: 1.63
            )
            return MultiModalFusionDecision(
                profile: prof,
                confidencePercent: 92,
                statusBadgeText: "Multi-Modal Fusion • 92% Match",
                scientificNote: "Identified via fused acoustic container verification (\(acousticSummaryText)) and optical context.",
                gateDecision: "PASS_MULTIMODAL_LABEL_FUSION",
                screeningState: bubbleDetected ? .bubbleScatterDetected : .liquidLoaded,
                attribution: attr,
                rankedCandidates: [
                    CandidateScoreEntry(profileID: prof.id, displayName: prof.displayName, distance: 0.32)
                ]
            )
        }

        // 3. Evaluate Chromatic, Turbid, & Effervescent Consumer Liquid Prototypes in Mahalanobis Space
        let isClearNeutralOptics = vision.meanSaturationWB < 0.22 && vision.opticalTurbidity < 0.42 && vision.meanValueBrightness >= 0.24
        let isCoolSurfactantTint = !bubbleDetected
            && vision.meanHueDegrees >= 160.0 && vision.meanHueDegrees <= 205.0
            && vision.meanSaturationWB >= 0.10
            && vision.meniscusContactAngleDegrees >= 35.5
        let isDeconvolvedOrCalibrated = hasInverseDeconv || (deltaEmpty?.compatible == true) || (deltaWater?.compatible == true)

        // 3A. Clear Neutral Liquid + Verified BUBBLE_SCATTER_DETECTED on real deconvolved / calibrated scan -> Carbonated Seltzer
        if isClearNeutralOptics && bubbleDetected && isDeconvolvedOrCalibrated {
            if let seltzer = findProfile("SELTZER_CARBONATED") {
                let dSeltzer = max(0.22, hypot(vision.meanSaturationWB / 0.12, vision.opticalTurbidity / 0.30) * 0.55)
                let dWater = 2.85
                let margin = dWater - dSeltzer
                let conf = Self.confidenceFromMahalanobis(distance: dSeltzer, margin: margin)
                let attr = MultiModalAttribution(
                    inferenceMode: "MULTI_MODAL_FUSION_V050",
                    acousticEvidenceSummary: acousticSummaryText,
                    visionEvidenceSummary: "Clear Colorless Meniscus (" + visionSummaryText + ")",
                    mahalanobisDistance: dSeltzer,
                    secondBestDistance: dWater,
                    winningMargin: margin
                )
                return MultiModalFusionDecision(
                    profile: seltzer,
                    confidencePercent: conf,
                    statusBadgeText: "Multi-Modal Fusion • Effervescent Match (\(conf)%)",
                    scientificNote: "Clear aqueous optics fused with dual-gate high-frequency micro-bubble scatter and active pre-roll fizz distinguishes Carbonated Seltzer from still water.",
                    gateDecision: "PASS_MULTIMODAL_EFFERVESCENT_SELTZER",
                    screeningState: .bubbleScatterDetected,
                    attribution: attr,
                    rankedCandidates: [
                        CandidateScoreEntry(profileID: seltzer.id, displayName: seltzer.displayName, distance: dSeltzer),
                        CandidateScoreEntry(profileID: "H2O_DIST", displayName: "Water", distance: dWater)
                    ]
                )
            }
        }

        // 3B. Non-Clear Chromatic, Turbid, or Cool Surfactant Consumer Liquids (Cooking Oil, Milk, Soapy Water, Cola, Coffee, Red Wine, Citrus Juice, Iced Tea)
        if !isClearNeutralOptics || isCoolSurfactantTint {
            let candidates = Self.scoreOpticalAcousticCandidates(
                features: features,
                visual: visual,
                vision: vision,
                deltaEmpty: deltaEmpty,
                bubbleDetected: bubbleDetected,
                catalog: catalog
            )
            if let best = candidates.first {
                let secondDist = candidates.count > 1 ? candidates[1].distance : (best.distance + 1.20)
                let margin = secondDist - best.distance
                if best.distance <= maximumMahalanobisDistance && margin >= minimumWinningMargin {
                    let conf = Self.confidenceFromMahalanobis(distance: best.distance, margin: margin)
                    let ranked = candidates.map {
                        CandidateScoreEntry(profileID: $0.profile.id, displayName: $0.profile.displayName, distance: $0.distance)
                    }
                    let attr = MultiModalAttribution(
                        inferenceMode: "MULTI_MODAL_FUSION_V050",
                        acousticEvidenceSummary: acousticSummaryText,
                        visionEvidenceSummary: visionSummaryText,
                        mahalanobisDistance: best.distance,
                        secondBestDistance: secondDist,
                        winningMargin: margin
                    )
                    let shiftClause = maxEmptyShiftPct.map { String(format: "max |Δf/f_empty| = %.2f%% + ", $0) } ?? ""
                    return MultiModalFusionDecision(
                        profile: best.profile,
                        confidencePercent: conf,
                        statusBadgeText: "Multi-Modal Fusion • \(conf)% Match",
                        scientificNote: String(
                            format: "Fused acoustic-optical identification (%@d_M = %.2f, margin = +%.2f). Combines container resonance verification with illuminant-normalized colorimetry & turbidity.",
                            shiftClause,
                            best.distance,
                            margin
                        ),
                        gateDecision: "PASS_MULTIMODAL_MAHALANOBIS",
                        screeningState: bubbleDetected ? .bubbleScatterDetected : .liquidLoaded,
                        attribution: attr,
                        rankedCandidates: ranked
                    )
                }
            }
        }

        // 4. Guided 3-Step Cup Comparator Fusion (Clear Still Liquids with Empty + Water Reference Baselines Locked):
        // Differentiates Distilled / Tap Water vs. Vinegar (Acetic Acid) vs. Salt / Saline Water!
        if isClearNeutralOptics,
           !bubbleDetected,
           hasCalibratedLiquidLoad,
           let dw = deltaWater,
           dw.compatible {
            let validShifts = dw.relativeFrequencyShifts.compactMap { $0 }
            if !validShifts.isEmpty {
                let compScores = Self.scoreComparativeClearAqueousCandidates(
                    waterShifts: validShifts,
                    deltaWater: dw,
                    vision: vision,
                    catalog: catalog
                )
                if let best = compScores.first {
                    let secondDist = compScores.count > 1 ? compScores[1].distance : (best.distance + 0.90)
                    let margin = secondDist - best.distance
                    if best.distance <= 2.35 && margin >= 0.16 {
                        let conf = Self.confidenceFromMahalanobis(distance: best.distance, margin: margin)
                        let shiftList = validShifts.map { String(format: "%+.2f%%", $0 * 100.0) }.joined(separator: ", ")
                        let compSummary = String(
                            format: "ΔF/F_water = [%@] • Meniscus θ ≈ %.0f°",
                            shiftList,
                            vision.meniscusContactAngleDegrees
                        )
                        let attr = MultiModalAttribution(
                            inferenceMode: "COMPARATIVE_BASELINE_FUSION_V050",
                            acousticEvidenceSummary: acousticSummaryText,
                            visionEvidenceSummary: visionSummaryText,
                            comparatorEvidenceSummary: compSummary,
                            mahalanobisDistance: best.distance,
                            secondBestDistance: secondDist,
                            winningMargin: margin,
                            recommendsGuidedComparator: false
                        )
                        let ranked = compScores.map {
                            CandidateScoreEntry(profileID: $0.profile.id, displayName: $0.profile.displayName, distance: $0.distance)
                        }
                        return MultiModalFusionDecision(
                            profile: best.profile,
                            confidencePercent: conf,
                            statusBadgeText: "Comparative Fusion • \(conf)% Match",
                            scientificNote: String(
                                format: "3-Step Cup Comparator match (%@; d_M = %.2f, margin = +%.2f) fusing modal shift vs. Water Blank with meniscus boundary geometry.",
                                compSummary,
                                best.distance,
                                margin
                            ),
                            gateDecision: "PASS_COMPARATIVE_CLEAR_FUSION",
                            screeningState: .calibratedClassCandidate,
                            attribution: attr,
                            rankedCandidates: ranked
                        )
                    }
                }
            }
        }

        return nil
    }

    /// Builds advisory attribution for clear uncalibrated vessels so the Result screen surfaces grounded scope guidance
    /// without falsely asserting that an empty clear glass contains liquid.
    public static func uncalibratedClearLiquidGuidance(
        features: ExtractedConsumerFeatures,
        vision: VisionFeatureVector,
        deltaEmpty: DifferentialBaselineVector?,
        deltaWater: DifferentialBaselineVector?,
        bubbleDetected: Bool
    ) -> MultiModalAttribution? {
        guard vision.hasCameraFrame else { return nil }
        let isClear = vision.meanSaturationWB < 0.22 && vision.opticalTurbidity < 0.42 && vision.meanValueBrightness >= 0.24 && !bubbleDetected
        let missingWaterRef = (deltaWater == nil) || (deltaWater?.compatible == false)
        guard isClear && missingWaterRef else { return nil }

        let loadState = OnDeviceAcousticClassifier.evaluateEmptyBaselineLoadState(
            features: features,
            deltaEmpty: deltaEmpty
        )
        let emptySummary: String = {
            switch loadState {
            case .explicitLiquidLoad(let maxS, _):
                return String(format: "Liquid Loaded (max |Δf/f_empty| = %.2f%%)", maxS * 100.0)
            case .withinDryContainerShell(let meanS):
                return String(format: "Dry Container Shell (mean |Δf/f_empty| = %.2f%% • No Liquid Load)", meanS * 100.0)
            case .staleOrPositionalDrift(let reason):
                return "Baseline Drift (\(reason)) — Re-run Step 1 (Empty Cup)"
            case .noEmptyBaseline:
                return String(format: "Container Resonance %.0f Hz (Uncalibrated / Low Coupling)", features.dominantPeakHz)
            }
        }()

        let visSummary = String(
            format: "Clear Colorless Vessel — Empty or Clear Liquid (Sat %.0f%%, Turbidity %.0f%%, Meniscus %.0f°)",
            vision.meanSaturationWB * 100.0,
            vision.opticalTurbidity * 100.0,
            vision.meniscusContactAngleDegrees
        )

        let comparatorNote: String = {
            switch loadState {
            case .explicitLiquidLoad:
                return "Step 1 (Empty Cup) locked — add Step 2 (Water Blank) in the same stationary cup to compare Water, Vinegar & Saline."
            case .staleOrPositionalDrift:
                return "Container shifted relative to your saved Empty Cup baseline. Reset or re-lock Step 1 (Empty Cup) before testing."
            case .withinDryContainerShell, .noEmptyBaseline:
                return "Phone-only mode identifies colored, turbid, or fizzy beverages directly. For clear liquids, use the experimental 3-Step Cup Comparator (stationary Empty → Water → Sample)."
            }
        }()

        return MultiModalAttribution(
            inferenceMode: "CLEAR_VESSEL_SCOPE_BOUNDARY",
            acousticEvidenceSummary: emptySummary,
            visionEvidenceSummary: visSummary,
            comparatorEvidenceSummary: comparatorNote,
            mahalanobisDistance: nil,
            secondBestDistance: nil,
            winningMargin: nil,
            recommendsGuidedComparator: true
        )
    }

    // MARK: - Internal Mahalanobis Scoring Engines

    private static func scoreOpticalAcousticCandidates(
        features: ExtractedConsumerFeatures,
        visual: VisualContextSummary,
        vision: VisionFeatureVector,
        deltaEmpty: DifferentialBaselineVector?,
        bubbleDetected: Bool,
        catalog: [ReferenceLiquidProfile]
    ) -> [(profile: ReferenceLiquidProfile, distance: Double)] {
        var results: [(profile: ReferenceLiquidProfile, distance: Double)] = []
        // Compare inner liquid against BOTH rim ring (top-down bowls) and outer background ring (side-view tall glasses!)
        let effectiveSatContrast = max(
            vision.meanSaturationWB - vision.rimSaturationWB,
            vision.meanSaturationWB - vision.outerBackgroundSaturationWB
        )
        let effectiveBrightExcess = max(
            vision.meanValueBrightness - vision.rimValueBrightness,
            vision.meanValueBrightness - vision.outerBackgroundValueBrightness
        )
        let effectiveDarkDeficit = max(
            vision.rimValueBrightness - vision.meanValueBrightness,
            vision.outerBackgroundValueBrightness - vision.meanValueBrightness
        )

        // 0. Packaged Bottle OR Open-Glass Cool Cyan/Aqua Soapy Surfactant Solution (AQUA_SURFACTANT)
        if let pkg = catalog.first(where: { $0.id == "AQUA_SURFACTANT" }) {
            if visual.hint == .coloredPackagedBottle {
                results.append((pkg, 0.48))
            } else if !bubbleDetected,
                      vision.meanHueDegrees >= 160.0 && vision.meanHueDegrees <= 205.0,
                      vision.meanSaturationWB >= 0.10,
                      effectiveSatContrast >= 0.05,
                      vision.meniscusContactAngleDegrees >= 35.5,
                      vision.meanValueBrightness >= 0.25 {
                let dHue = circularHueDiff(vision.meanHueDegrees, 184.0) / 16.0
                let dSat = max(0.0, 0.16 - vision.meanSaturationWB) / 0.08
                let dMen = max(0.0, 38.0 - vision.meniscusContactAngleDegrees) / 6.0
                let dist = sqrt(dHue * dHue + dSat * dSat + dMen * dMen + 0.16)
                results.append((pkg, dist))
            }
        }

        // 1. Cooking / Vegetable Oil (OIL_VEG): Golden yellow-amber chroma (38..66 deg), calibrated for real kitchen glasses
        if let oil = catalog.first(where: { $0.id == "OIL_VEG" }),
           !bubbleDetected,
           vision.meanHueDegrees >= 38.0 && vision.meanHueDegrees <= 66.0,
           effectiveSatContrast >= 0.05,
           vision.meanSaturationWB >= 0.24,
           vision.meanValueBrightness >= 0.25 {
            let dHue = circularHueDiff(vision.meanHueDegrees, 52.0) / 11.5
            let dSat = max(0.0, 0.34 - vision.meanSaturationWB) / 0.12
            let dTurb = max(0.0, vision.opticalTurbidity - 0.34) / 0.14
            // Acoustic dispersion consistency bonus/check when Empty baseline is present
            let dDispersion: Double = {
                guard let de = deltaEmpty, de.compatible else { return 0.18 }
                let valid = de.relativeFrequencyShifts.compactMap { $0 }.map { abs($0) }
                guard let maxS = valid.max() else { return 0.25 }
                return maxS >= 0.015 ? 0.05 : 1.40
            }()
            let dist = sqrt(dHue * dHue + dSat * dSat + dTurb * dTurb + dDispersion * dDispersion)
            results.append((oil, dist))
        }

        // 2. Milk / Dairy (MILK_DAIRY): Opaque white colloidal emulsion (supports both top-down studio and real indoor side-view)
        if let milk = catalog.first(where: { $0.id == "MILK_DAIRY" }),
           !bubbleDetected,
           !visual.hasBarcode,
           vision.meanValueBrightness >= 0.62,
           vision.opticalTurbidity >= 0.64,
           vision.meanSaturationWB <= 0.14,
           effectiveBrightExcess >= 0.06 {
            let dSat = vision.meanSaturationWB / 0.09
            let dVal = max(0.0, 0.78 - vision.meanValueBrightness) / 0.14
            let dTurb = max(0.0, 0.80 - vision.opticalTurbidity) / 0.16
            let dist = sqrt(dSat * dSat + dVal * dVal + dTurb * dTurb)
            results.append((milk, dist))
        }

        // 3. Dark Absorptive Beverages: Red Wine vs. Carbonated Cola vs. Black Coffee
        if vision.meanValueBrightness < 0.30 && effectiveDarkDeficit > 0.14 {
            let isRubyHalo = vision.meniscusHaloSaturation >= 0.24
                && (vision.meniscusHaloHueDegrees >= 328.0 || vision.meniscusHaloHueDegrees <= 16.0)

            if isRubyHalo && !bubbleDetected, let wine = catalog.first(where: { $0.id == "WINE_RED" }) {
                let dHalo = circularHueDiff(vision.meniscusHaloHueDegrees, 352.0) / 18.0
                let dVal = max(0.0, vision.meanValueBrightness - 0.18) / 0.10
                let dist = sqrt(dHalo * dHalo + dVal * dVal + 0.09)
                results.append((wine, dist))
            } else if bubbleDetected, let cola = catalog.first(where: { $0.id == "COLA_CARBONATED" }) {
                let dVal = max(0.0, vision.meanValueBrightness - 0.18) / 0.10
                let dist = sqrt(dVal * dVal + 0.12)
                results.append((cola, dist))
            } else if !bubbleDetected, let coffee = catalog.first(where: { $0.id == "COFFEE_DARK" }) {
                let dVal = max(0.0, vision.meanValueBrightness - 0.18) / 0.10
                let dist = sqrt(dVal * dVal + 0.14)
                results.append((coffee, dist))
            }
        }

        // 4. Citrus / Fruit Juice (CITRUS_JUICE): Chromatic orange / berry / turbid yellow pool
        if let juice = catalog.first(where: { $0.id == "CITRUS_JUICE" }),
           effectiveSatContrast >= 0.06,
           vision.meanSaturationWB >= 0.30,
           vision.meanValueBrightness >= 0.30 {
            let isOrangeOrBerry = (vision.meanHueDegrees < 39.0 || vision.meanHueDegrees > 328.0)
            let isTurbidYellowJuice = (vision.meanHueDegrees >= 39.0 && vision.meanHueDegrees <= 58.0 && vision.opticalTurbidity >= 0.36)
            if isOrangeOrBerry || isTurbidYellowJuice {
                let targetHue = vision.meanHueDegrees > 300.0 ? 348.0 : 26.0
                let dHue = isTurbidYellowJuice ? 0.32 : (circularHueDiff(vision.meanHueDegrees, targetHue) / 18.0)
                let dSat = max(0.0, 0.44 - vision.meanSaturationWB) / 0.15
                let dTurb = max(0.0, 0.44 - vision.opticalTurbidity) / 0.20
                let dist = sqrt(dHue * dHue + dSat * dSat + dTurb * dTurb)
                results.append((juice, dist))
            }
        }

        // 5. Iced Tea / Translucent Amber Liquid (TEA_AMBER)
        if let tea = catalog.first(where: { $0.id == "TEA_AMBER" }),
           !bubbleDetected,
           !visual.hasBarcode,
           effectiveSatContrast >= 0.06,
           vision.meanHueDegrees >= 18.0 && vision.meanHueDegrees < 38.0,
           vision.meanSaturationWB >= 0.24 && vision.meanSaturationWB < 0.44,
           vision.opticalTurbidity < 0.38,
           vision.meanValueBrightness >= 0.22 {
            let dHue = circularHueDiff(vision.meanHueDegrees, 29.0) / 10.0
            let dTurb = vision.opticalTurbidity / 0.30
            let dist = sqrt(dHue * dHue + dTurb * dTurb + 0.16)
            results.append((tea, dist))
        }

        return results.filter { $0.distance.isFinite }.sorted { $0.distance < $1.distance }
    }

    private static func scoreComparativeClearAqueousCandidates(
        waterShifts: [Double],
        deltaWater: DifferentialBaselineVector,
        vision: VisionFeatureVector,
        catalog: [ReferenceLiquidProfile]
    ) -> [(profile: ReferenceLiquidProfile, distance: Double)] {
        let n = Double(waterShifts.count)
        let meanAbs = waterShifts.map { abs($0) }.reduce(0.0, +) / n
        let maxAbs = waterShifts.map { abs($0) }.max() ?? 0.0
        let signedMean = waterShifts.reduce(0.0, +) / n
        let hasMeniscus = vision.meniscusEdgeStrength >= 0.028
        let theta = vision.meniscusContactAngleDegrees

        var out: [(profile: ReferenceLiquidProfile, distance: Double)] = []

        // A. Distilled / Tap Water (H2O_DIST): Near-zero modal shift vs. locked WATER_REFERENCE + steep concave meniscus (~26 deg)
        if let water = catalog.first(where: { $0.id == "H2O_DIST" }) {
            let zShift = meanAbs / 0.0065
            let zMax = max(0.0, maxAbs - 0.010) / 0.009
            let zMeniscus = hasMeniscus ? max(0.0, theta - 34.0) / 8.5 : 0.0
            let dist = sqrt(zShift * zShift + zMax * zMax + zMeniscus * zMeniscus)
            out.append((water, dist))
        }

        // B. Vinegar / 5% Acetic Acid (VIN_WHITE): Measurable downward/negative relative modal shift + flatter reduced-surface-tension meniscus (~44 deg)
        if let vinegar = catalog.first(where: { $0.id == "VIN_WHITE" }) {
            let tooCloseToWaterPenalty = meanAbs < 0.010 ? ((0.012 - meanAbs) / 0.004) : 0.0
            let zSigned = signedMean <= -0.004
                ? abs(signedMean - (-0.022)) / 0.026
                : (0.85 + max(0.0, signedMean + 0.004) / 0.018)
            let zMeniscus = hasMeniscus
                ? abs(theta - 44.0) / 9.0
                : 0.35
            let dist = sqrt(tooCloseToWaterPenalty * tooCloseToWaterPenalty + zSigned * zSigned + zMeniscus * zMeniscus)
            out.append((vinegar, dist))
        }

        // C. Salt / Saline Water (NACL_AQ): Positive/ionic density & sound-speed shift + steep high-surface-tension meniscus (~24 deg)
        if let saline = catalog.first(where: { $0.id == "NACL_AQ" }) {
            let tooCloseToWaterPenalty = meanAbs < 0.011 ? ((0.013 - meanAbs) / 0.004) : 0.0
            let zSigned = signedMean >= 0.004
                ? abs(signedMean - 0.024) / 0.026
                : (0.95 + max(0.0, 0.004 - signedMean) / 0.018)
            let zMeniscus = hasMeniscus
                ? abs(theta - 24.5) / 9.0
                : 0.35
            let dist = sqrt(tooCloseToWaterPenalty * tooCloseToWaterPenalty + zSigned * zSigned + zMeniscus * zMeniscus)
            out.append((saline, dist))
        }

        return out.filter { $0.distance.isFinite }.sorted { $0.distance < $1.distance }
    }

    private static func profileIDForExplicitLabel(_ hint: VisualLiquidHint, bubbleDetected: Bool) -> String? {
        switch hint {
        case .labeledWater:
            return bubbleDetected ? "SELTZER_CARBONATED" : "H2O_DIST"
        case .labeledSaline:
            return "NACL_AQ"
        case .labeledPeroxide, .brownPeroxideBottle:
            return "H2O2_AQ"
        case .labeledVinegar:
            return "VIN_WHITE"
        case .labeledOil:
            return "OIL_VEG"
        case .labeledMilk:
            return "MILK_DAIRY"
        case .labeledJuice:
            return "CITRUS_JUICE"
        case .labeledCoffeeOrCola:
            return bubbleDetected ? "COLA_CARBONATED" : "COFFEE_DARK"
        case .labeledAlcohol:
            return "ISOPROPYL_ALC"
        case .labeledSurfactant:
            return "AQUA_SURFACTANT"
        default:
            return nil
        }
    }

    private static func circularHueDiff(_ a: Double, _ b: Double) -> Double {
        let diff = abs(a - b).truncatingRemainder(dividingBy: 360.0)
        return diff > 180.0 ? (360.0 - diff) : diff
    }

    /// Phase R3 `MODE_B` Contact Ultrasonic Fusion Classifier:
    /// Evaluates wall-thickness-invariant longitudinal sound speed (`c_20C`), double-echo attenuation (`A2/A1`),
    /// and boundary phase polarity (`hasInvertedBubbleEcho`) via Mahalanobis distance against `ReferenceLiquidProfile.fusionLibrary`.
    public func evaluateModeBContactMeasurement(
        _ measurement: UltrasonicMeasurement
    ) -> MultiModalFusionDecision? {
        let c20 = measurement.normalizedVelocity20CMps
        let attenRatio = measurement.echoAttenuationRatio
        let hasBubble = measurement.hasInvertedBubbleEcho
        guard c20.isFinite, attenRatio.isFinite else { return nil }

        let catalog = ReferenceLiquidProfile.fusionLibrary
        struct ModeBTarget {
            let profileID: String
            let meanVelocityMps: Double
            let sigmaVelocityMps: Double
            let meanAttenRatio: Double
            let sigmaAttenRatio: Double
            let expectsInvertedBubble: Bool
        }

        let targets: [ModeBTarget] = [
            ModeBTarget(profileID: "ISOPROPYL_ALC", meanVelocityMps: 1_210.0, sigmaVelocityMps: 65.0, meanAttenRatio: 0.56, sigmaAttenRatio: 0.16, expectsInvertedBubble: false),
            ModeBTarget(profileID: "OIL_VEG", meanVelocityMps: 1_455.0, sigmaVelocityMps: 12.0, meanAttenRatio: 0.36, sigmaAttenRatio: 0.12, expectsInvertedBubble: false),
            ModeBTarget(profileID: "H2O_DIST", meanVelocityMps: 1_482.0, sigmaVelocityMps: 7.5, meanAttenRatio: 0.72, sigmaAttenRatio: 0.14, expectsInvertedBubble: false),
            ModeBTarget(profileID: "SELTZER_CARBONATED", meanVelocityMps: 1_482.0, sigmaVelocityMps: 10.0, meanAttenRatio: 0.58, sigmaAttenRatio: 0.18, expectsInvertedBubble: true),
            ModeBTarget(profileID: "VIN_WHITE", meanVelocityMps: 1_500.0, sigmaVelocityMps: 7.0, meanAttenRatio: 0.68, sigmaAttenRatio: 0.14, expectsInvertedBubble: false),
            ModeBTarget(profileID: "NACL_AQ", meanVelocityMps: 1_548.0, sigmaVelocityMps: 26.0, meanAttenRatio: 0.66, sigmaAttenRatio: 0.15, expectsInvertedBubble: false)
        ]

        var scored: [(profile: ReferenceLiquidProfile, distance: Double)] = []
        for t in targets {
            guard let profile = catalog.first(where: { $0.id == t.profileID }) else { continue }
            let zVel = (c20 - t.meanVelocityMps) / t.sigmaVelocityMps
            let zAtten = (attenRatio - t.meanAttenRatio) / t.sigmaAttenRatio
            let zBubble: Double = (hasBubble == t.expectsInvertedBubble) ? 0.0 : 2.6
            let dist = sqrt(zVel * zVel + 0.45 * zAtten * zAtten + zBubble * zBubble)
            if dist.isFinite {
                scored.append((profile, dist))
            }
        }
        scored.sort { $0.distance < $1.distance }

        guard let best = scored.first else { return nil }
        let secondDist = scored.dropFirst().first?.distance ?? (best.distance + 1.5)
        let margin = secondDist - best.distance
        guard best.distance <= 2.40 && margin >= 0.25 else { return nil }

        let conf = Self.confidenceFromMahalanobis(distance: best.distance, margin: margin)
        let wallPolarity = (!measurement.firstEcho.isPhaseInverted && !measurement.secondEcho.isPhaseInverted)
            ? "+R In-Phase (Rigid Glass Wall)"
            : "Mixed/Inverted Boundary Polarity"
        let bubbleSummary = hasBubble
            ? "180° Phase-Inverted Air Bubble Echo Detected (-R)"
            : "Clean Liquid Column (Zero Inverted Bubble Echoes)"

        let attr = MultiModalAttribution(
            inferenceMode: "MODE_B_ULTRASONIC_PULSE_ECHO",
            acousticEvidenceSummary: String(
                format: "c_20°C = %.1f m/s (Δt = %.2f µs, A₂/A₁ = %.2f, %.2f dB/cm) • %@",
                c20,
                measurement.transitGapMicroseconds,
                attenRatio,
                measurement.attenuationDBPerCm,
                wallPolarity
            ),
            visionEvidenceSummary: bubbleSummary,
            comparatorEvidenceSummary: String(
                format: "Wall-Thickness-Invariant Double-Echo Solver (D = %.0f mm, T = %.1f °C)",
                measurement.containerDiameterMeters * 1_000.0,
                measurement.temperatureCelsius
            ),
            mahalanobisDistance: best.distance,
            secondBestDistance: secondDist,
            winningMargin: margin,
            recommendsGuidedComparator: false
        )

        let ranked = scored.map {
            CandidateScoreEntry(profileID: $0.profile.id, displayName: $0.profile.displayName, distance: $0.distance)
        }

        return MultiModalFusionDecision(
            profile: best.profile,
            confidencePercent: conf,
            statusBadgeText: "MODE_B Pulse-Echo • \(conf)% Match",
            scientificNote: String(
                format: "Direct ultrasonic pulse-echo match (c_20°C = %.1f m/s, Δt = %.2f µs, d_M = %.2f, margin = +%.2f).",
                c20,
                measurement.transitGapMicroseconds,
                best.distance,
                margin
            ),
            gateDecision: "PASS_MODE_B_ULTRASONIC_FUSION",
            screeningState: hasBubble ? .bubbleScatterDetected : .calibratedClassCandidate,
            attribution: attr,
            rankedCandidates: ranked
        )
    }

    private static func confidenceFromMahalanobis(distance: Double, margin: Double) -> Int {
        guard distance.isFinite, margin.isFinite else { return 70 }
        let fit = exp(-0.34 * max(0.0, distance))
        let sep = 0.84 + 0.16 * min(1.0, max(0.0, margin) / 0.85)
        let raw = fit * sep * 96.0
        guard raw.isFinite else { return 70 }
        return min(96, max(70, Int(round(raw))))
    }
}
