import AVFAudio
import Foundation

/// Layer 2 on-device acoustic feature analyzer and 4-state experimental/calibrated matcher
/// (`REFERENCE_MATCH`, `NO_VALIDATED_MATCH`, `NON_LIQUID_SURFACE`, `INVALID_MEASUREMENT`).
/// Implements radar-style indirect acoustic inference:
/// Transmitted ESS -> Target Interaction -> Returned Echo -> 11D Scattering Signature -> Calibrated / Reference Match.
public struct OnDeviceAcousticClassifier: Sendable {
    public let referenceLibrary: [ReferenceLiquidProfile]
    public let distanceThreshold: Double
    public let minimumSNRDB: Double
    private let visualAnalyzer = VisualLiquidContextAnalyzer()

    public init(
        referenceLibrary: [ReferenceLiquidProfile] = ReferenceLiquidProfile.provisionalLibrary,
        distanceThreshold: Double = 2.35,
        minimumSNRDB: Double = 1.8
    ) {
        self.referenceLibrary = referenceLibrary
        self.distanceThreshold = distanceThreshold
        self.minimumSNRDB = minimumSNRDB
    }

    public func analyzeAndClassify(
        recordingURL: URL,
        inverseFilterURL: URL?,
        preRollFrames: Int = 7_200,
        activeFrames: Int = 9_600,
        clippingCeilingDBFS: Double = -0.5,
        thumbnailJPEGData: Data? = nil,
        sceneContextJPEGData: Data? = nil,
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
            thumbnailJPEGData: thumbnailJPEGData,
            sceneContextJPEGData: sceneContextJPEGData,
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
        thumbnailJPEGData: Data? = nil,
        sceneContextJPEGData: Data? = nil,
        calibratedPrototypes: [CalibratedAcousticPrototype] = []
    ) -> ConsumerScanItem {
        let features = extractFeatures(
            samples: samples,
            inverseFilter: inverseFilter,
            sampleRateHz: sampleRateHz,
            preRollFrames: preRollFrames,
            activeFrames: activeFrames,
            clippingCeilingDBFS: clippingCeilingDBFS
        )

        // 1. Visual Positive-Container Gate — Rejects Walls, Furniture, Floors, & Non-Liquid Objects Immediately
        let visual = visualAnalyzer.analyze(jpegData: thumbnailJPEGData, sceneContextJPEGData: sceneContextJPEGData)
        if visual.hint == .solidOrNonLiquid {
            return buildSolidNonLiquidItem(features: features, thumbnailJPEGData: thumbnailJPEGData)
        }

        // 2. Audio Signal Quality Verification (`INVALID_MEASUREMENT`)
        if samples.count < (preRollFrames + activeFrames / 2) ||
            features.clippedSamples > 8 ||
            features.activeSNRDB < minimumSNRDB {
            let reasonNote: String
            if features.clippedSamples > 8 {
                reasonNote = "The sound reflection was too loud or clipped. Lower your volume slightly and try again."
            } else {
                reasonNote = "Ambient noise was too close to the acoustic test wave. Move to a quieter spot, hold steady near the container, and scan again."
            }
            return ConsumerScanItem(
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
                thumbnailJPEGData: thumbnailJPEGData
            )
        }

        // 3. Calibrated Indirect Acoustic Inference (Empirical Known-Standard Prototypes — Container-Agnostic!)
        if !calibratedPrototypes.isEmpty,
           let calibratedResult = matchCalibratedPrototypes(
               features: features,
               prototypes: calibratedPrototypes,
               thumbnailJPEGData: thumbnailJPEGData
           ) {
            return calibratedResult
        }

        // 4. Layer 2 Acoustic Specular Flat-Surface Guard (catches flat wall reflections lacking cavity resonance)
        if visual.hint != .audioOnly &&
            !visual.hasBarcode &&
            visual.vesselConfidence < 0.16 &&
            features.spectralFlatness > 0.56 &&
            features.peakProminenceDB < 7.8 {
            return buildSolidNonLiquidItem(features: features, thumbnailJPEGData: thumbnailJPEGData)
        }

        // 5. Fair 5-Feature Reference Acoustic Comparison (zero default H₂O bias, zero Sweetened-Beverage sink)
        let candidateSpec = resolveEligibleCandidates(for: visual.hint, features: features)
        let scored: [(profile: ReferenceLiquidProfile, distance: Double)] = candidateSpec.profiles.map { prof in
            let dPeak = (features.dominantPeakHz - prof.expectedPeakHz) / 580.0
            let dCent = (features.spectralCentroidHz - prof.expectedCentroidHz) / 650.0
            let dBand = (features.midToHighBandDB - prof.expectedMidToHighDB) / 3.8
            let dDecay = (features.decaySlopeDBPerSec - prof.expectedDecayDBPerSec) / 38.0
            let dScatter = (features.highFreqBubbleScatterDB - prof.expectedHighScatterDB) / 4.5
            let rawDist = sqrt(
                0.30 * dPeak * dPeak +
                0.25 * dCent * dCent +
                0.18 * dBand * dBand +
                0.14 * dDecay * dDecay +
                0.13 * dScatter * dScatter
            )
            let weight = candidateSpec.priorMultipliers[prof.id] ?? 1.0
            return (prof, rawDist * weight)
        }.sorted { $0.distance < $1.distance }

        guard let best = scored.first else {
            return buildUnmatchedItem(features: features, thumbnailJPEGData: thumbnailJPEGData)
        }

        let secondDistance = scored.count > 1 ? scored[1].distance : (best.distance + 0.65)
        let margin = secondDistance - best.distance
        let isExplicitLabelOrOptics = (scored.count <= 2 && visual.hint != .audioOnly && visual.hint != .openVesselAqueousOrGeneral)
        let effectiveThreshold = isExplicitLabelOrOptics ? max(distanceThreshold, 3.10) : distanceThreshold

        // 6. Open-Set Unknown Rejection (`NO_VALIDATED_MATCH`) — never falls back to H₂O when unrecognized!
        if best.distance > effectiveThreshold || (!isExplicitLabelOrOptics && margin < 0.025) {
            return buildUnmatchedItem(features: features, thumbnailJPEGData: thumbnailJPEGData)
        }

        // 7. Experimental Reference Match (`REFERENCE_MATCH`) — bounded experimental confidence (never 99.9%)
        let rawSimilarity = exp(-0.36 * best.distance) * (0.83 + 0.17 * min(1.0, margin / 0.38))
        let snrFactor = min(1.0, max(0.80, features.activeSNRDB / 22.0))
        let boundedConfidence = min(92, max(62, Int(round(rawSimilarity * snrFactor * 93.0))))

        return ConsumerScanItem(
            status: .referenceMatch,
            title: best.profile.displayName,
            formulaDisplay: best.profile.formulaDisplay,
            statusBadgeText: "Experimental Reference Match • \(boundedConfidence)% Similarity",
            confidencePercent: boundedConfidence,
            scientificNote: "Estimated from acoustic echo scattering and container resonance against the \(best.profile.displayName.lowercased()) reference profile. Experimental research result—not a laboratory chemical or safety test.",
            constituents: best.profile.constituents,
            tuneProfile: best.profile.tuneProfile,
            measuredPeakHz: features.dominantPeakHz,
            measuredCentroidHz: features.spectralCentroidHz,
            measuredDecayDBPerSec: features.decaySlopeDBPerSec,
            measuredFeatures: features,
            thumbnailJPEGData: thumbnailJPEGData
        )
    }

    // MARK: - Radar-Style 11D Calibrated Indirect Inference

    public static func calibratedScatteringDistance(
        _ a: ExtractedConsumerFeatures,
        _ b: ExtractedConsumerFeatures
    ) -> Double {
        var subBandSq = 0.0
        let count = min(a.subBandShapeDB.count, b.subBandShapeDB.count)
        if count > 0 {
            for k in 0..<count {
                let diff = (a.subBandShapeDB[k] - b.subBandShapeDB[k]) / 3.0
                subBandSq += diff * diff
            }
            subBandSq /= Double(count)
        }

        let dPeak = (a.dominantPeakHz - b.dominantPeakHz) / 480.0
        let dCent = (a.spectralCentroidHz - b.spectralCentroidHz) / 520.0
        let dDecay = (a.decaySlopeDBPerSec - b.decaySlopeDBPerSec) / 32.0
        let dScatter = (a.highFreqBubbleScatterDB - b.highFreqBubbleScatterDB) / 3.6
        let dCavity = (a.cavityMultipathDB - b.cavityMultipathDB) / 3.5

        let macroSq = 0.28 * dPeak * dPeak +
            0.24 * dCent * dCent +
            0.16 * dDecay * dDecay +
            0.18 * dScatter * dScatter +
            0.14 * dCavity * dCavity

        return sqrt(0.55 * subBandSq + 0.45 * macroSq)
    }

    private func matchCalibratedPrototypes(
        features: ExtractedConsumerFeatures,
        prototypes: [CalibratedAcousticPrototype],
        thumbnailJPEGData: Data?
    ) -> ConsumerScanItem? {
        // Compute best (minimum) distance per distinct targetID so multi-shot calibration averages cleanly
        var bestByTarget: [String: Double] = [:]
        for proto in prototypes {
            let d = Self.calibratedScatteringDistance(features, proto.features)
            if let existing = bestByTarget[proto.targetID] {
                if d < existing { bestByTarget[proto.targetID] = d }
            } else {
                bestByTarget[proto.targetID] = d
            }
        }

        let sortedTargets = bestByTarget.sorted { $0.value < $1.value }
        guard let bestTarget = sortedTargets.first, bestTarget.value <= 1.55 else {
            return nil
        }

        if bestTarget.key == CalibratedAcousticPrototype.solidSurfaceTargetID {
            return buildSolidNonLiquidItem(features: features, thumbnailJPEGData: thumbnailJPEGData)
        }

        guard let matchedProfile = referenceLibrary.first(where: { $0.id == bestTarget.key }) else {
            return nil
        }

        let secondDist = sortedTargets.count > 1 ? sortedTargets[1].value : (bestTarget.value + 0.60)
        let margin = secondDist - bestTarget.value
        guard margin >= 0.02 || sortedTargets.count == 1 else {
            return nil
        }

        let rawSim = exp(-0.42 * bestTarget.value) * (0.86 + 0.14 * min(1.0, margin / 0.35))
        let confidence = min(96, max(68, Int(round(rawSim * 96.0))))

        return ConsumerScanItem(
            status: .referenceMatch,
            title: matchedProfile.displayName,
            formulaDisplay: matchedProfile.formulaDisplay,
            statusBadgeText: "Calibrated Acoustic Match • \(confidence)% Similarity",
            confidencePercent: confidence,
            scientificNote: "Inferred from your on-device calibrated acoustic scattering standard for \(matchedProfile.displayName.lowercased()) (6-band echo profile + resonance decay). Experimental indirect acoustic measurement.",
            constituents: matchedProfile.constituents,
            tuneProfile: matchedProfile.tuneProfile,
            measuredPeakHz: features.dominantPeakHz,
            measuredCentroidHz: features.spectralCentroidHz,
            measuredDecayDBPerSec: features.decaySlopeDBPerSec,
            measuredFeatures: features,
            thumbnailJPEGData: thumbnailJPEGData
        )
    }

    private func resolveEligibleCandidates(
        for hint: VisualLiquidHint,
        features: ExtractedConsumerFeatures
    ) -> (profiles: [ReferenceLiquidProfile], priorMultipliers: [String: Double]) {
        let allowedIDs: Set<String>
        let priors: [String: Double] = [:]

        switch hint {
        case .audioOnly, .openVesselAqueousOrGeneral:
            var excluded: Set<String> = ["OIL_VEG", "AQUA_SURFACTANT", "ISOPROPYL_ALC"]
            if !(features.decaySlopeDBPerSec >= 98.0 && features.dominantPeakHz < 1_920.0) {
                excluded.insert("SUC_AQ")
            }
            if features.dominantPeakHz < 1_650.0 && features.midToHighBandDB > 6.2 && features.decaySlopeDBPerSec >= 112.0 {
                excluded.remove("OIL_VEG")
            }
            let openPool = referenceLibrary.filter { !excluded.contains($0.id) }
            return (openPool.isEmpty ? referenceLibrary : openPool, [:])

        case .solidOrNonLiquid:
            return ([], [:])

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
        if matched.isEmpty {
            let fallback = referenceLibrary.filter { $0.id != "OIL_VEG" && $0.id != "SUC_AQ" }
            return (fallback.isEmpty ? referenceLibrary : fallback, priors)
        }
        return (matched, priors)
    }

    public func extractFeatures(
        samples: [Float],
        inverseFilter: [Float]?,
        sampleRateHz: Double = 48_000.0,
        preRollFrames: Int = 7_200,
        activeFrames: Int = 9_600,
        clippingCeilingDBFS: Double = -0.5
    ) -> ExtractedConsumerFeatures {
        guard !samples.isEmpty else {
            return ExtractedConsumerFeatures(
                activeSNRDB: 0.0,
                peakDBFS: -120.0,
                clippedSamples: 0,
                dominantPeakHz: 2_220.0,
                spectralCentroidHz: 2_560.0,
                midToHighBandDB: 3.8,
                decaySlopeDBPerSec: 76.0,
                highFreqBubbleScatterDB: -8.5,
                spectralFlatness: 0.65,
                peakProminenceDB: 3.0,
                cavityMultipathDB: -6.0,
                subBandShapeDB: [0, 0, 0, 0, 0, 0]
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

        let preEnd = max(1, min(samples.count, preRollFrames))
        let actStart = min(samples.count, preRollFrames)
        let actEnd = min(samples.count, preRollFrames + max(1, activeFrames))

        let preRMS = Self.segmentRMS(samples, start: 0, end: preEnd)
        let actRMS = actEnd > actStart ? Self.segmentRMS(samples, start: actStart, end: actEnd) : 0.0
        let preDB = ImmediateAudioAnalyzer.linearToDBFS(preRMS)
        let actDB = ImmediateAudioAnalyzer.linearToDBFS(actRMS)
        let snrDB = max(0.0, actDB - preDB)

        let preFizzHighPower = Self.bandPower(
            slice: Array(samples[0..<preEnd]).map { $0.isFinite ? Double($0) : 0.0 },
            sampleRateHz: sampleRateHz,
            lowHz: 5_200.0,
            highHz: 11_800.0
        )

        let analysisSignal: [Double]
        let applyHardwareSpeakerTrim: Bool
        var noiseFloorPowerPerSample = 0.0

        if let inv = inverseFilter, !inv.isEmpty, samples.count > actStart + 512 {
            applyHardwareSpeakerTrim = true
            let responseSlice = Array(samples[actStart..<samples.count]).map { $0.isFinite ? Double($0) : 0.0 }
            let invDouble = inv.map { $0.isFinite ? Double($0) : 0.0 }
            let ir = Self.fastLinearConvolve(responseSlice, invDouble)

            var peakIdx = 0
            var maxAbs = 0.0
            for (idx, val) in ir.enumerated() {
                let a = abs(val)
                if a > maxAbs {
                    maxAbs = a
                    peakIdx = idx
                }
            }

            let tailStart = min(ir.count, peakIdx + Int(0.0020 * sampleRateHz))
            let tailEnd = min(ir.count, peakIdx + Int(0.0280 * sampleRateHz))

            let floorStart = min(ir.count, peakIdx + Int(0.0480 * sampleRateHz))
            let floorEnd = min(ir.count, peakIdx + Int(0.0680 * sampleRateHz))
            if floorEnd - floorStart >= 128 {
                let floorSum = ir[floorStart..<floorEnd].reduce(0.0) { $0 + $1 * $1 }
                noiseFloorPowerPerSample = floorSum / Double(floorEnd - floorStart)
            }

            if tailEnd - tailStart >= 256 {
                analysisSignal = Array(ir[tailStart..<tailEnd])
            } else {
                analysisSignal = Array(samples[actStart..<actEnd]).map { $0.isFinite ? Double($0) : 0.0 }
            }
        } else {
            applyHardwareSpeakerTrim = false
            analysisSignal = Array(samples[actStart..<max(actStart + 1, actEnd)]).map { $0.isFinite ? Double($0) : 0.0 }
        }

        // Compute multipath cavity-to-specular ratio (2.5..22 ms cavity ring-down vs 0..2.5 ms initial front)
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

        // Compute Hann-windowed spectrum over 1,200 Hz - 11,800 Hz + 6 scattering sub-bands
        let nFFT = 4_096
        var real = [Double](repeating: 0.0, count: nFFT)
        var imag = [Double](repeating: 0.0, count: nFFT)
        let copyCount = min(analysisSignal.count, nFFT)
        if copyCount > 1 {
            for i in 0..<copyCount {
                let w = 0.5 * (1.0 - cos(2.0 * Double.pi * Double(i) / Double(copyCount - 1)))
                real[i] = analysisSignal[i] * w
            }
        }
        Self.fftRadix2(real: &real, imag: &imag, inverse: false)

        let binHz = sampleRateHz / Double(nFFT)
        let minBin = max(1, Int(ceil(1_200.0 / binHz)))
        let maxPassBin = min(nFFT / 2 - 1, Int(floor(9_600.0 / binHz)))
        let maxScatterBin = min(nFFT / 2 - 1, Int(floor(11_800.0 / binHz)))

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
        var dominantFreq = 2_220.0
        var midBandPower = 1e-15
        var highBandPower = 1e-15
        var coreRefPower = 1e-15
        var upperScatterPower = 1e-15
        var logPowerSum = 0.0
        var flatnessBinCount = 0

        if maxScatterBin > minBin {
            for b in minBin...maxScatterBin {
                let rawP = real[b] * real[b] + imag[b] * imag[b]
                let f = Double(b) * binHz

                let speakerWeight: Double
                if applyHardwareSpeakerTrim {
                    let normAbove = max(0.0, (f - 3_200.0) / 3_800.0)
                    speakerWeight = 1.0 / (1.0 + 0.28 * pow(normAbove, 1.3))
                } else {
                    speakerWeight = 1.0
                }
                let p = rawP * speakerWeight

                for (k, edge) in subBandEdges.enumerated() where f >= edge.0 && f < edge.1 {
                    subBandSum[k] += p
                    subBandCnt[k] += 1.0
                }

                if b <= maxPassBin {
                    weightedFreqSum += f * p
                    powerSum += p
                    if p > maxBinPower {
                        maxBinPower = p
                        dominantFreq = f
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

        let rawBandDB: [Double] = (0..<6).map { k in
            let meanP = subBandCnt[k] > 0 ? (subBandSum[k] / subBandCnt[k]) : 1e-15
            return 10.0 * log10(max(meanP, 1e-18))
        }
        let avgBandDB = rawBandDB.reduce(0.0, +) / 6.0
        let subBandShapeDB = rawBandDB.map { min(18.0, max(-18.0, $0 - avgBandDB)) }

        let centroidHz = weightedFreqSum / powerSum
        let midToHighDB = min(14.0, max(-14.0, 10.0 * log10(midBandPower / highBandPower)))

        let combinedScatter = upperScatterPower + 6.0 * preFizzHighPower * Double(nFFT)
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

        return ExtractedConsumerFeatures(
            activeSNRDB: snrDB,
            peakDBFS: ImmediateAudioAnalyzer.linearToDBFS(peakLin),
            clippedSamples: clipped,
            dominantPeakHz: dominantFreq,
            spectralCentroidHz: centroidHz,
            midToHighBandDB: midToHighDB,
            decaySlopeDBPerSec: decayDBPerSec,
            highFreqBubbleScatterDB: highFreqBubbleScatterDB,
            spectralFlatness: spectralFlatness,
            peakProminenceDB: peakProminenceDB,
            cavityMultipathDB: cavityMultipathDB,
            subBandShapeDB: subBandShapeDB
        )
    }

    private func buildSolidNonLiquidItem(
        features: ExtractedConsumerFeatures,
        thumbnailJPEGData: Data?
    ) -> ConsumerScanItem {
        ConsumerScanItem(
            status: .nonLiquidMaterial,
            title: "Solid / Non-Liquid Material",
            formulaDisplay: "No Liquid Container Detected",
            statusBadgeText: "Solid Surface • Aim at a Liquid",
            confidencePercent: nil,
            scientificNote: "Visual framing and flat acoustic reflection indicate a solid surface or non-liquid object (such as a wall, table, or floor) rather than liquid in a container. Point at a glass, cup, mug, bowl, or bottle holding liquid and scan again.",
            constituents: [],
            tuneProfile: Self.buildAcousticSignatureTune(features: features, formula: "Surface Echo"),
            measuredPeakHz: features.dominantPeakHz,
            measuredCentroidHz: features.spectralCentroidHz,
            measuredDecayDBPerSec: features.decaySlopeDBPerSec,
            measuredFeatures: features,
            thumbnailJPEGData: thumbnailJPEGData
        )
    }

    private func buildUnmatchedItem(
        features: ExtractedConsumerFeatures,
        thumbnailJPEGData: Data?
    ) -> ConsumerScanItem {
        ConsumerScanItem(
            status: .unmatchedSignature,
            title: "Unmatched Liquid",
            formulaDisplay: "Acoustic Profile",
            statusBadgeText: "Experimental • Outside Current Reference Library",
            confidencePercent: nil,
            scientificNote: "A container reflection was captured, but its acoustic signature did not closely match a calibrated reference liquid—Liquid Analyzer does not guess H₂O when uncertain. Tap 'Calibrate Known Standard' below to teach this signature, or play its mapped acoustic tune.",
            constituents: [
                ReferenceConstituent(
                    symbol: "≈ \(Int(round(features.dominantPeakHz))) Hz",
                    name: "Measured Resonance Peak",
                    roleDescription: "Unclassified liquid signature (no reference claim)"
                )
            ],
            tuneProfile: Self.buildAcousticSignatureTune(features: features, formula: "Acoustic Signature"),
            measuredPeakHz: features.dominantPeakHz,
            measuredCentroidHz: features.spectralCentroidHz,
            measuredDecayDBPerSec: features.decaySlopeDBPerSec,
            measuredFeatures: features,
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
            mappingSummary: "Mapped musical representation derived directly from the liquid's measured acoustic resonance frequencies.",
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
