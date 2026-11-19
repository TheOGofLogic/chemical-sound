import Foundation

/// Primary consumer navigation tabs (`Scan | History | Learn | More`).
public enum ConsumerTab: String, CaseIterable, Hashable, Sendable {
    case scan
    case history
    case learn
    case more
}

/// Consumer Scan tab flow (`HOME -> AIM -> SCAN -> RESULT -> LISTEN`).
public enum ScanFlowStep: Equatable, Sendable {
    case home
    case aim
    case scanning
    case result(ConsumerScanItem)
}

/// Five-state scientific outcome mapped cleanly for consumer & geometry-controlled blind-test display.
public enum ConsumerMatchStatus: String, Codable, Equatable, Sendable {
    case referenceMatch = "REFERENCE_MATCH"
    case unmatchedSignature = "NO_VALIDATED_MATCH"
    case emptyContainer = "EMPTY_CONTAINER"
    case nonLiquidMaterial = "NON_LIQUID_SURFACE"
    case unclearScan = "INVALID_MEASUREMENT"
}

/// Authoritative Phase R2-B (`LA-R2-SPEC-001` Sec. 3.1.4) airborne `MODE_A` physical screening states.
/// `MODE_A` is strictly restricted to verifiable acoustic-structural screening, bubble-scatter detection,
/// and calibrated container baseline shifts (`Delta X_empty`, `Delta X_water`) — never uncalibrated molecular or viscosity claims.
public enum ModeAScreeningState: String, Codable, CaseIterable, Equatable, Sendable {
    case emptyContainer = "EMPTY_CONTAINER"
    case liquidLoaded = "LIQUID_LOADED"
    case bubbleScatterDetected = "BUBBLE_SCATTER_DETECTED"
    case nonstandardSurfaceResponse = "NONSTANDARD_SURFACE_RESPONSE"
    case calibratedClassCandidate = "CALIBRATED_CLASS_CANDIDATE"
    case noValidatedMatch = "NO_VALIDATED_MATCH"
    case rejectedSignalQuality = "REJECTED_SIGNAL_QUALITY"
    case rejectedBaselineMismatch = "REJECTED_BASELINE_MISMATCH"
}

/// Phase R2-B 4-mode multi-parameter acoustic vector (`F = [f_1..f_4]`, `Q = [Q_1..Q_4]`, `alpha = [alpha_1..alpha_4]`)
/// with explicit missing-mode validity masks (`validityMask[i] == 0` -> `frequenciesWithNaN[i].isNaN == true`).
/// Zero-padding, synthetic frequency injection, and band-centroid substitution are strictly prohibited.
public struct ModalVector4: Codable, Equatable, Sendable {
    public let frequenciesHz: [Double?]
    public let validityMask: [Int]
    public let qualityFactorsQ: [Double?]
    public let qValidityMask: [Int]
    public let decayAlphaPerSec: [Double?]
    public let decayDBPerSec: [Double?]
    public let decayRSquared: [Double?]
    public let decayValidityMask: [Int]
    public let spectralAttenuationSlopeDBPerKHz: Double?
    public let bubbleScatter55to85DB: Double?
    public let latePreRollNoiseDBFS: Double

    /// Returns the 4-element modal frequency vector `[f_1..f_4]` with `Double.nan` wherever `validityMask[i] == 0`.
    public var frequenciesWithNaN: [Double] {
        (0..<4).map { idx in
            guard idx < validityMask.count, validityMask[idx] == 1,
                  idx < frequenciesHz.count, let f = frequenciesHz[idx], f.isFinite else {
                return Double.nan
            }
            return f
        }
    }

    public init(
        frequenciesHz: [Double?],
        validityMask: [Int],
        qualityFactorsQ: [Double?],
        qValidityMask: [Int],
        decayAlphaPerSec: [Double?],
        decayDBPerSec: [Double?],
        decayRSquared: [Double?],
        decayValidityMask: [Int],
        spectralAttenuationSlopeDBPerKHz: Double? = nil,
        bubbleScatter55to85DB: Double? = nil,
        latePreRollNoiseDBFS: Double = -82.0
    ) {
        self.frequenciesHz = Self.pad4(frequenciesHz)
        self.validityMask = Self.padMask4(validityMask, values: frequenciesHz)
        self.qualityFactorsQ = Self.pad4(qualityFactorsQ)
        self.qValidityMask = Self.padMask4(qValidityMask, values: qualityFactorsQ)
        self.decayAlphaPerSec = Self.pad4(decayAlphaPerSec)
        self.decayDBPerSec = Self.pad4(decayDBPerSec)
        self.decayRSquared = Self.pad4(decayRSquared)
        self.decayValidityMask = Self.padMask4(decayValidityMask, values: decayAlphaPerSec)
        self.spectralAttenuationSlopeDBPerKHz = spectralAttenuationSlopeDBPerKHz
        self.bubbleScatter55to85DB = bubbleScatter55to85DB
        self.latePreRollNoiseDBFS = latePreRollNoiseDBFS
    }

    public static let emptyMasked = ModalVector4(
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
        latePreRollNoiseDBFS: -120.0
    )

    private static func pad4(_ arr: [Double?]) -> [Double?] {
        var out: [Double?] = Array(arr.prefix(4)).map { val in
            guard let v = val, v.isFinite else { return nil }
            return v
        }
        while out.count < 4 { out.append(nil) }
        return out
    }

    private static func padMask4(_ mask: [Int], values: [Double?]) -> [Int] {
        let paddedVals = pad4(values)
        return (0..<4).map { idx in
            let flag = idx < mask.count ? mask[idx] : 0
            return (flag == 1 && paddedVals[idx] != nil) ? 1 : 0
        }
    }
}

/// Differential baseline normalization vector (`Delta X_empty` or `Delta X_water`) computed strictly on mutually valid slots.
public struct DifferentialBaselineVector: Codable, Equatable, Sendable {
    public let referenceTargetID: String
    public let compatible: Bool
    public let rejectionCode: String?
    public let relativeFrequencyShifts: [Double?]
    public let shiftMask: [Int]
    public let deltaDecayAlphaPerSec: [Double?]
    public let deltaQualityFactorQ: [Double?]
    public let deltaAttenuationSlopeDBPerKHz: Double?
    public let deltaBubbleScatter55to85DB: Double?

    public init(
        referenceTargetID: String,
        compatible: Bool,
        rejectionCode: String? = nil,
        relativeFrequencyShifts: [Double?] = [nil, nil, nil, nil],
        shiftMask: [Int] = [0, 0, 0, 0],
        deltaDecayAlphaPerSec: [Double?] = [nil, nil, nil, nil],
        deltaQualityFactorQ: [Double?] = [nil, nil, nil, nil],
        deltaAttenuationSlopeDBPerKHz: Double? = nil,
        deltaBubbleScatter55to85DB: Double? = nil
    ) {
        self.referenceTargetID = referenceTargetID
        self.compatible = compatible
        self.rejectionCode = rejectionCode
        self.relativeFrequencyShifts = relativeFrequencyShifts
        self.shiftMask = shiftMask
        self.deltaDecayAlphaPerSec = deltaDecayAlphaPerSec
        self.deltaQualityFactorQ = deltaQualityFactorQ
        self.deltaAttenuationSlopeDBPerKHz = deltaAttenuationSlopeDBPerKHz
        self.deltaBubbleScatter55to85DB = deltaBubbleScatter55to85DB
    }

    public static func compute(
        sample: ModalVector4,
        sampleGeometry: String?,
        reference: ModalVector4,
        referenceTargetID: String,
        referenceGeometry: String?
    ) -> DifferentialBaselineVector {
        if let sg = sampleGeometry, let rg = referenceGeometry, !sg.isEmpty, !rg.isEmpty, sg != rg {
            return DifferentialBaselineVector(
                referenceTargetID: referenceTargetID,
                compatible: false,
                rejectionCode: "REJECTED_BASELINE_MISMATCH_GEOMETRY"
            )
        }

        var relF: [Double?] = [nil, nil, nil, nil]
        var fMask: [Int] = [0, 0, 0, 0]
        var dAlpha: [Double?] = [nil, nil, nil, nil]
        var dQ: [Double?] = [nil, nil, nil, nil]

        // Associate each valid sample slot to the nearest valid reference slot within +-250 Hz (or 12% shift)
        var usedRefSlots = Set<Int>()
        for i in 0..<4 {
            guard sample.validityMask[i] == 1, let fs = sample.frequenciesHz[i], fs > 0 else { continue }
            var bestRefIdx: Int?
            var bestDist = Double.infinity
            for j in 0..<4 where !usedRefSlots.contains(j) {
                guard reference.validityMask[j] == 1, let fr = reference.frequenciesHz[j], fr > 0 else { continue }
                let dist = abs(fs - fr)
                let maxAllowed = max(250.0, 0.14 * fr)
                if dist <= maxAllowed && dist < bestDist {
                    bestDist = dist
                    bestRefIdx = j
                }
            }
            if let rIdx = bestRefIdx, let fr = reference.frequenciesHz[rIdx], fr > 0 {
                usedRefSlots.insert(rIdx)
                relF[i] = (fs - fr) / fr
                fMask[i] = 1
                if sample.decayValidityMask[i] == 1, reference.decayValidityMask[rIdx] == 1,
                   let asmp = sample.decayAlphaPerSec[i], let aref = reference.decayAlphaPerSec[rIdx] {
                    dAlpha[i] = asmp - aref
                }
                if sample.qValidityMask[i] == 1, reference.qValidityMask[rIdx] == 1,
                   let qsmp = sample.qualityFactorsQ[i], let qref = reference.qualityFactorsQ[rIdx] {
                    dQ[i] = qsmp - qref
                }
            }
        }

        let dSlope: Double? = {
            guard let s = sample.spectralAttenuationSlopeDBPerKHz,
                  let r = reference.spectralAttenuationSlopeDBPerKHz else { return nil }
            return s - r
        }()
        let dScatter: Double? = {
            guard let s = sample.bubbleScatter55to85DB,
                  let r = reference.bubbleScatter55to85DB else { return nil }
            return s - r
        }()

        return DifferentialBaselineVector(
            referenceTargetID: referenceTargetID,
            compatible: true,
            rejectionCode: nil,
            relativeFrequencyShifts: relF,
            shiftMask: fMask,
            deltaDecayAlphaPerSec: dAlpha,
            deltaQualityFactorQ: dQ,
            deltaAttenuationSlopeDBPerKHz: dSlope,
            deltaBubbleScatter55to85DB: dScatter
        )
    }
}

/// Geometry condition tag preventing substantially different camera/container distances from being pooled
/// into the same Repeatability Gate R1 summary statistics.
public enum GeometryTestCondition: String, Codable, CaseIterable, Equatable, Sendable {
    case stationary15InBaseline = "STATIONARY_15IN_BASELINE"
    case closeRangeSub8In = "CLOSE_RANGE_SUB_8IN"
    case handheldGeneral = "HANDHELD_GENERAL"

    public var displayLabel: String {
        switch self {
        case .stationary15InBaseline:
            return "15-in Stationary Baseline"
        case .closeRangeSub8In:
            return "Close-Range (<8 in)"
        case .handheldGeneral:
            return "Standard Handheld"
        }
    }
}

/// Post-acquisition audit label for controlled R1 series (strictly firewalled from classifier input).
public enum ControlSeriesTag: String, Codable, CaseIterable, Equatable, Sendable {
    case unlabeledBlind = "UNLABELED_BLIND"
    case emptyContainer = "CONTROL_A_EMPTY_CONTAINER"
    case water = "CONTROL_B_WATER"
    case saltWater = "CONTROL_C_SALT_WATER"
    case hydrogenPeroxide = "CONTROL_D_HYDROGEN_PEROXIDE"
    case vinegar = "CONTROL_E_VINEGAR"
    case cookingOil = "CONTROL_F_COOKING_OIL"
    case solidNonLiquid = "CONTROL_G_SOLID_NON_LIQUID"

    public var displayLabel: String {
        switch self {
        case .unlabeledBlind:
            return "Blind / Unlabeled"
        case .emptyContainer:
            return "A. Empty Container"
        case .water:
            return "B. Water"
        case .saltWater:
            return "C. Salt-Water Standard"
        case .hydrogenPeroxide:
            return "D. Hydrogen Peroxide"
        case .vinegar:
            return "E. Vinegar"
        case .cookingOil:
            return "F. Cooking / Veg Oil"
        case .solidNonLiquid:
            return "G. Solid / Non-Liquid"
        }
    }
}

/// Raw distance score against a single frozen reference profile for Repeatability Gate R1 auditing.
public struct CandidateScoreEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: String { profileID }
    public let profileID: String
    public let displayName: String
    public let distance: Double

    public init(profileID: String, displayName: String, distance: Double) {
        self.profileID = profileID
        self.displayName = displayName
        self.distance = distance
    }
}

/// Extracted multi-dimensional acoustic scattering & optical refraction features from a 48 kHz ESS scan.
public struct ExtractedConsumerFeatures: Codable, Equatable, Sendable {
    public let activeSNRDB: Double
    public let activeRMSDBFS: Double
    public let peakDBFS: Double
    public let clippedSamples: Int
    public let dominantPeakHz: Double
    public let primaryPeakAmplitudeDB: Double
    public let secondaryPeaksHz: [Double]
    public let secondaryPeakAmplitudesDB: [Double]
    public let spectralCentroidHz: Double
    public let midToHighBandDB: Double
    public let decaySlopeDBPerSec: Double
    public let highFreqBubbleScatterDB: Double
    public let spectralFlatness: Double
    public let peakProminenceDB: Double
    public let cavityMultipathDB: Double
    public let subBandShapeDB: [Double]
    public let echoReturnDB: Double
    public let echoRMSDBFS: Double
    public let tailSNRDB: Double
    public let alignmentOffsetSamples: Int
    public let echoArrivalDelayMs: Double
    public let intraScanPersistenceRatio: Double
    public let featureVectorChecksum: String
    public let opticalCenterBrightness: Double
    public let opticalInteriorContrast: Double
    public let opticalRimContrast: Double
    public let opticsLocked: Bool
    public let latePreRollNoiseDBFS: Double
    public let preRollExcessHFDB: Double
    public let modalVector: ModalVector4?

    public init(
        activeSNRDB: Double,
        activeRMSDBFS: Double = -24.0,
        peakDBFS: Double,
        clippedSamples: Int,
        dominantPeakHz: Double,
        primaryPeakAmplitudeDB: Double = -24.0,
        secondaryPeaksHz: [Double] = [],
        secondaryPeakAmplitudesDB: [Double] = [],
        spectralCentroidHz: Double,
        midToHighBandDB: Double,
        decaySlopeDBPerSec: Double,
        highFreqBubbleScatterDB: Double = -8.5,
        spectralFlatness: Double = 0.25,
        peakProminenceDB: Double = 12.0,
        cavityMultipathDB: Double = -3.0,
        subBandShapeDB: [Double] = [0, 0, 0, 0, 0, 0],
        echoReturnDB: Double = -14.0,
        echoRMSDBFS: Double = -52.0,
        tailSNRDB: Double = 12.0,
        alignmentOffsetSamples: Int = 0,
        echoArrivalDelayMs: Double = 2.2,
        intraScanPersistenceRatio: Double = 0.85,
        featureVectorChecksum: String = "00000000",
        opticalCenterBrightness: Double = 0.50,
        opticalInteriorContrast: Double = 0.02,
        opticalRimContrast: Double = 0.04,
        opticsLocked: Bool = false,
        latePreRollNoiseDBFS: Double = -82.0,
        preRollExcessHFDB: Double = 0.0,
        modalVector: ModalVector4? = nil
    ) {
        self.activeSNRDB = activeSNRDB
        self.activeRMSDBFS = activeRMSDBFS
        self.peakDBFS = peakDBFS
        self.clippedSamples = clippedSamples
        self.dominantPeakHz = dominantPeakHz
        self.primaryPeakAmplitudeDB = primaryPeakAmplitudeDB
        self.secondaryPeaksHz = secondaryPeaksHz
        self.secondaryPeakAmplitudesDB = secondaryPeakAmplitudesDB
        self.spectralCentroidHz = spectralCentroidHz
        self.midToHighBandDB = midToHighBandDB
        self.decaySlopeDBPerSec = decaySlopeDBPerSec
        self.highFreqBubbleScatterDB = highFreqBubbleScatterDB
        self.spectralFlatness = spectralFlatness
        self.peakProminenceDB = peakProminenceDB
        self.cavityMultipathDB = cavityMultipathDB
        self.subBandShapeDB = subBandShapeDB
        self.echoReturnDB = echoReturnDB
        self.echoRMSDBFS = echoRMSDBFS
        self.tailSNRDB = tailSNRDB
        self.alignmentOffsetSamples = alignmentOffsetSamples
        self.echoArrivalDelayMs = echoArrivalDelayMs
        self.intraScanPersistenceRatio = intraScanPersistenceRatio
        self.featureVectorChecksum = featureVectorChecksum
        self.opticalCenterBrightness = opticalCenterBrightness
        self.opticalInteriorContrast = opticalInteriorContrast
        self.opticalRimContrast = opticalRimContrast
        self.opticsLocked = opticsLocked
        self.latePreRollNoiseDBFS = latePreRollNoiseDBFS
        self.preRollExcessHFDB = preRollExcessHFDB
        self.modalVector = modalVector
    }

    private enum CodingKeys: String, CodingKey {
        case activeSNRDB
        case activeRMSDBFS
        case peakDBFS
        case clippedSamples
        case dominantPeakHz
        case primaryPeakAmplitudeDB
        case secondaryPeaksHz
        case secondaryPeakAmplitudesDB
        case spectralCentroidHz
        case midToHighBandDB
        case decaySlopeDBPerSec
        case highFreqBubbleScatterDB
        case spectralFlatness
        case peakProminenceDB
        case cavityMultipathDB
        case subBandShapeDB
        case echoReturnDB
        case echoRMSDBFS
        case tailSNRDB
        case alignmentOffsetSamples
        case echoArrivalDelayMs
        case intraScanPersistenceRatio
        case featureVectorChecksum
        case opticalCenterBrightness
        case opticalInteriorContrast
        case opticalRimContrast
        case opticsLocked
        case latePreRollNoiseDBFS
        case preRollExcessHFDB
        case modalVector
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.activeSNRDB = try c.decode(Double.self, forKey: .activeSNRDB)
        let actRMS = try c.decodeIfPresent(Double.self, forKey: .activeRMSDBFS) ?? -24.0
        self.activeRMSDBFS = actRMS
        self.peakDBFS = try c.decode(Double.self, forKey: .peakDBFS)
        self.clippedSamples = try c.decode(Int.self, forKey: .clippedSamples)
        self.dominantPeakHz = try c.decode(Double.self, forKey: .dominantPeakHz)
        self.primaryPeakAmplitudeDB = try c.decodeIfPresent(Double.self, forKey: .primaryPeakAmplitudeDB) ?? actRMS
        let secHz = try c.decodeIfPresent([Double].self, forKey: .secondaryPeaksHz) ?? []
        self.secondaryPeaksHz = secHz
        self.secondaryPeakAmplitudesDB = try c.decodeIfPresent([Double].self, forKey: .secondaryPeakAmplitudesDB) ?? []
        self.spectralCentroidHz = try c.decode(Double.self, forKey: .spectralCentroidHz)
        self.midToHighBandDB = try c.decode(Double.self, forKey: .midToHighBandDB)
        self.decaySlopeDBPerSec = try c.decode(Double.self, forKey: .decaySlopeDBPerSec)
        self.highFreqBubbleScatterDB = try c.decodeIfPresent(Double.self, forKey: .highFreqBubbleScatterDB) ?? -8.5
        self.spectralFlatness = try c.decodeIfPresent(Double.self, forKey: .spectralFlatness) ?? 0.25
        self.peakProminenceDB = try c.decodeIfPresent(Double.self, forKey: .peakProminenceDB) ?? 12.0
        self.cavityMultipathDB = try c.decodeIfPresent(Double.self, forKey: .cavityMultipathDB) ?? -3.0
        self.subBandShapeDB = try c.decodeIfPresent([Double].self, forKey: .subBandShapeDB) ?? [0, 0, 0, 0, 0, 0]
        let echoRel = try c.decodeIfPresent(Double.self, forKey: .echoReturnDB) ?? -14.0
        self.echoReturnDB = echoRel
        self.echoRMSDBFS = try c.decodeIfPresent(Double.self, forKey: .echoRMSDBFS) ?? (actRMS + echoRel)
        self.tailSNRDB = try c.decodeIfPresent(Double.self, forKey: .tailSNRDB) ?? 12.0
        self.alignmentOffsetSamples = try c.decodeIfPresent(Int.self, forKey: .alignmentOffsetSamples) ?? 0
        self.echoArrivalDelayMs = try c.decodeIfPresent(Double.self, forKey: .echoArrivalDelayMs) ?? 2.2
        self.intraScanPersistenceRatio = try c.decodeIfPresent(Double.self, forKey: .intraScanPersistenceRatio) ?? 0.85
        self.featureVectorChecksum = try c.decodeIfPresent(String.self, forKey: .featureVectorChecksum) ?? "00000000"
        self.opticalCenterBrightness = try c.decodeIfPresent(Double.self, forKey: .opticalCenterBrightness) ?? 0.50
        self.opticalInteriorContrast = try c.decodeIfPresent(Double.self, forKey: .opticalInteriorContrast) ?? 0.02
        self.opticalRimContrast = try c.decodeIfPresent(Double.self, forKey: .opticalRimContrast) ?? 0.04
        self.opticsLocked = try c.decodeIfPresent(Bool.self, forKey: .opticsLocked) ?? false
        self.latePreRollNoiseDBFS = try c.decodeIfPresent(Double.self, forKey: .latePreRollNoiseDBFS) ?? -82.0
        self.preRollExcessHFDB = try c.decodeIfPresent(Double.self, forKey: .preRollExcessHFDB) ?? 0.0
        self.modalVector = try c.decodeIfPresent(ModalVector4.self, forKey: .modalVector)
    }
}

/// Empirical known-standard prototype saved on-device for calibrated indirect acoustic/optical inference.
public struct CalibratedAcousticPrototype: Codable, Equatable, Identifiable, Sendable {
    public static let solidSurfaceTargetID = "SOLID_SURFACE"
    public static let emptyContainerTargetID = "EMPTY_CONTAINER"

    public let id: UUID
    public let createdAt: Date
    public let targetID: String
    public let features: ExtractedConsumerFeatures

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        targetID: String,
        features: ExtractedConsumerFeatures
    ) {
        self.id = id
        self.createdAt = createdAt
        self.targetID = targetID
        self.features = features
    }
}

/// Thread-safe persistent store for user-calibrated known liquid & solid-surface acoustic standards.
public final class CalibratedPrototypeStore: @unchecked Sendable {
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
                .appendingPathComponent("calibrated_prototypes.json")
        }
    }

    public func loadAll() -> [CalibratedAcousticPrototype] {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([CalibratedAcousticPrototype].self, from: data)) ?? []
    }

    public func append(_ prototype: CalibratedAcousticPrototype) {
        var current = loadAll()
        current.insert(prototype, at: 0)
        if current.count > 120 {
            current = Array(current.prefix(120))
        }
        saveAll(current)
    }

    public func clearAll() {
        saveAll([])
    }

    public func saveAll(_ items: [CalibratedAcousticPrototype]) {
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

/// Constituent item displayed in the separated Composition panel.
/// Never claims unvalidated purity percentages during experimental operation.
public struct ReferenceConstituent: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(symbol)-\(name)" }
    public let symbol: String
    public let name: String
    public let roleDescription: String

    public init(symbol: String, name: String, roleDescription: String) {
        self.symbol = symbol
        self.name = name
        self.roleDescription = roleDescription
    }
}

/// Musical pitch & harmonic mapping specification for a reference profile.
public struct ChemicalTuneProfile: Codable, Equatable, Sendable {
    public let formulaDisplay: String
    public let subtitle: String
    public let mappingSummary: String
    public let baseFrequenciesHz: [Double]
    public let shimmerMultiplier: Double
    public let warmthDecayPerSec: Double

    public init(
        formulaDisplay: String,
        subtitle: String = "Chemical Tune",
        mappingSummary: String,
        baseFrequenciesHz: [Double],
        shimmerMultiplier: Double = 1.0,
        warmthDecayPerSec: Double = 1.6
    ) {
        self.formulaDisplay = formulaDisplay
        self.subtitle = subtitle
        self.mappingSummary = mappingSummary
        self.baseFrequenciesHz = baseFrequenciesHz
        self.shimmerMultiplier = shimmerMultiplier
        self.warmthDecayPerSec = warmthDecayPerSec
    }
}

/// Experimental reference profile in the on-device reference library.
public struct ReferenceLiquidProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let formulaDisplay: String
    public let categorySummary: String
    public let constituents: [ReferenceConstituent]
    public let expectedCentroidHz: Double
    public let expectedPeakHz: Double
    public let expectedMidToHighDB: Double
    public let expectedDecayDBPerSec: Double
    public let expectedHighScatterDB: Double
    public let tuneProfile: ChemicalTuneProfile

    public init(
        id: String,
        displayName: String,
        formulaDisplay: String,
        categorySummary: String,
        constituents: [ReferenceConstituent],
        expectedCentroidHz: Double,
        expectedPeakHz: Double,
        expectedMidToHighDB: Double,
        expectedDecayDBPerSec: Double,
        expectedHighScatterDB: Double = -8.0,
        tuneProfile: ChemicalTuneProfile
    ) {
        self.id = id
        self.displayName = displayName
        self.formulaDisplay = formulaDisplay
        self.categorySummary = categorySummary
        self.constituents = constituents
        self.expectedCentroidHz = expectedCentroidHz
        self.expectedPeakHz = expectedPeakHz
        self.expectedMidToHighDB = expectedMidToHighDB
        self.expectedDecayDBPerSec = expectedDecayDBPerSec
        self.expectedHighScatterDB = expectedHighScatterDB
        self.tuneProfile = tuneProfile
    }

    public static let provisionalLibrary: [ReferenceLiquidProfile] = [
        ReferenceLiquidProfile(
            id: "H2O_DIST",
            displayName: "Water",
            formulaDisplay: "H₂O",
            categorySummary: "Aqueous Reference Profile",
            constituents: [
                ReferenceConstituent(
                    symbol: "H₂O",
                    name: "Water",
                    roleDescription: "Primary aqueous reference constituent"
                )
            ],
            expectedCentroidHz: 2_560.0,
            expectedPeakHz: 2_220.0,
            expectedMidToHighDB: 3.8,
            expectedDecayDBPerSec: 76.0,
            expectedHighScatterDB: -8.8,
            tuneProfile: ChemicalTuneProfile(
                formulaDisplay: "H₂O",
                mappingSummary: "Mapped musical representation of hydrogen-oxygen reference intervals and measured resonance.",
                baseFrequenciesHz: [392.00, 493.88, 587.33, 783.99, 880.00], // G4, B4, D5, G5, A5
                shimmerMultiplier: 1.06,
                warmthDecayPerSec: 1.45
            )
        ),
        ReferenceLiquidProfile(
            id: "NACL_AQ",
            displayName: "Salt / Saline Water",
            formulaDisplay: "H₂O + NaCl",
            categorySummary: "Aqueous Electrolyte Reference",
            constituents: [
                ReferenceConstituent(
                    symbol: "H₂O",
                    name: "Water",
                    roleDescription: "Aqueous solvent reference"
                ),
                ReferenceConstituent(
                    symbol: "NaCl",
                    name: "Sodium Chloride",
                    roleDescription: "Dissolved salt / electrolyte constituent"
                )
            ],
            expectedCentroidHz: 3_320.0,
            expectedPeakHz: 2_780.0,
            expectedMidToHighDB: 1.8,
            expectedDecayDBPerSec: 64.0,
            expectedHighScatterDB: -9.5,
            tuneProfile: ChemicalTuneProfile(
                formulaDisplay: "H₂O + NaCl",
                mappingSummary: "Mapped musical representation combining water harmonics with bright high-Q ionic fifth and ninth intervals.",
                baseFrequenciesHz: [392.00, 587.33, 659.25, 739.99, 987.77], // G4, D5, E5, F#5, B5
                shimmerMultiplier: 1.24,
                warmthDecayPerSec: 1.55
            )
        ),
        ReferenceLiquidProfile(
            id: "H2O2_AQ",
            displayName: "Hydrogen Peroxide Solution",
            formulaDisplay: "H₂O + H₂O₂",
            categorySummary: "Dilute Peroxide / Micro-Bubble Aqueous Reference",
            constituents: [
                ReferenceConstituent(
                    symbol: "H₂O",
                    name: "Water",
                    roleDescription: "Primary aqueous stabilizer phase"
                ),
                ReferenceConstituent(
                    symbol: "H₂O₂",
                    name: "Hydrogen Peroxide",
                    roleDescription: "Reactive oxygen & micro-bubble constituent"
                )
            ],
            expectedCentroidHz: 3_760.0,
            expectedPeakHz: 2_480.0,
            expectedMidToHighDB: 1.2,
            expectedDecayDBPerSec: 78.0,
            expectedHighScatterDB: -2.8,
            tuneProfile: ChemicalTuneProfile(
                formulaDisplay: "H₂O + H₂O₂",
                mappingSummary: "Mapped musical representation pairing aqueous fundamentals with sparkling high-register oxygen-bond overtones.",
                baseFrequenciesHz: [329.63, 493.88, 659.25, 830.61, 987.77], // E4, B4, E5, G#5, B5
                shimmerMultiplier: 1.30,
                warmthDecayPerSec: 1.68
            )
        ),
        ReferenceLiquidProfile(
            id: "VIN_WHITE",
            displayName: "Vinegar",
            formulaDisplay: "H₂O + CH₃COOH",
            categorySummary: "Dilute Organic Acid Reference",
            constituents: [
                ReferenceConstituent(
                    symbol: "H₂O",
                    name: "Water",
                    roleDescription: "Primary aqueous base"
                ),
                ReferenceConstituent(
                    symbol: "CH₃COOH",
                    name: "Acetic Acid",
                    roleDescription: "Dilute organic acid constituent"
                )
            ],
            expectedCentroidHz: 2_880.0,
            expectedPeakHz: 2_520.0,
            expectedMidToHighDB: 2.1,
            expectedDecayDBPerSec: 92.0,
            expectedHighScatterDB: -6.2,
            tuneProfile: ChemicalTuneProfile(
                formulaDisplay: "H₂O + CH₃COOH",
                mappingSummary: "Mapped musical representation blending carbon-oxygen intervals with crisp upper harmonics.",
                baseFrequenciesHz: [293.66, 440.00, 554.37, 659.25, 880.00], // D4, A4, C#5, E5, A5
                shimmerMultiplier: 1.15,
                warmthDecayPerSec: 1.70
            )
        ),
        ReferenceLiquidProfile(
            id: "SUC_AQ",
            displayName: "Sweetened Beverage",
            formulaDisplay: "H₂O + C₁₂H₂₂O₁₁",
            categorySummary: "Aqueous Carbohydrate Reference",
            constituents: [
                ReferenceConstituent(
                    symbol: "H₂O",
                    name: "Water",
                    roleDescription: "Aqueous solvent reference"
                ),
                ReferenceConstituent(
                    symbol: "C₁₂H₂₂O₁₁",
                    name: "Dissolved Sugars",
                    roleDescription: "Carbohydrate solute reference constituent"
                )
            ],
            expectedCentroidHz: 2_020.0,
            expectedPeakHz: 1_740.0,
            expectedMidToHighDB: 6.6,
            expectedDecayDBPerSec: 116.0,
            expectedHighScatterDB: -10.5,
            tuneProfile: ChemicalTuneProfile(
                formulaDisplay: "H₂O + C₁₂H₂₂O₁₁",
                mappingSummary: "Mapped musical representation pairing carbon bass intervals with warm damped water harmonics.",
                baseFrequenciesHz: [261.63, 392.00, 493.88, 587.33, 659.25], // C4, G4, B4, D5, E5
                shimmerMultiplier: 0.90,
                warmthDecayPerSec: 1.95
            )
        ),
        ReferenceLiquidProfile(
            id: "MILK_DAIRY",
            displayName: "Milk",
            formulaDisplay: "H₂O + Lactose · Lipids",
            categorySummary: "Aqueous Colloidal Emulsion Reference",
            constituents: [
                ReferenceConstituent(
                    symbol: "H₂O",
                    name: "Water",
                    roleDescription: "Primary aqueous phase"
                ),
                ReferenceConstituent(
                    symbol: "C₁₂H₂₂O₁₁",
                    name: "Lactose & Milk Solids",
                    roleDescription: "Dissolved carbohydrate & protein phase"
                ),
                ReferenceConstituent(
                    symbol: "Lipids",
                    name: "Emulsified Milk Fat",
                    roleDescription: "Dispersed colloidal lipid droplets"
                )
            ],
            expectedCentroidHz: 2_240.0,
            expectedPeakHz: 1_940.0,
            expectedMidToHighDB: 4.9,
            expectedDecayDBPerSec: 112.0,
            expectedHighScatterDB: -9.8,
            tuneProfile: ChemicalTuneProfile(
                formulaDisplay: "H₂O + Lactose",
                mappingSummary: "Mapped musical representation using soft, warm F-major ninth intervals reflecting colloidal damping.",
                baseFrequenciesHz: [349.23, 440.00, 523.25, 659.25, 783.99], // F4, A4, C5, E5, G5
                shimmerMultiplier: 0.86,
                warmthDecayPerSec: 2.05
            )
        ),
        ReferenceLiquidProfile(
            id: "COFFEE_DARK",
            displayName: "Coffee / Dark Beverage",
            formulaDisplay: "H₂O + C₈H₁₀N₄O₂",
            categorySummary: "Brewed Aqueous Solute Reference",
            constituents: [
                ReferenceConstituent(
                    symbol: "H₂O",
                    name: "Water",
                    roleDescription: "Primary brewed solvent"
                ),
                ReferenceConstituent(
                    symbol: "C₈H₁₀N₄O₂",
                    name: "Caffeine & Roasted Solutes",
                    roleDescription: "Dissolved aromatic & alkaloid compounds"
                )
            ],
            expectedCentroidHz: 2_680.0,
            expectedPeakHz: 2_340.0,
            expectedMidToHighDB: 3.0,
            expectedDecayDBPerSec: 90.0,
            expectedHighScatterDB: -7.2,
            tuneProfile: ChemicalTuneProfile(
                formulaDisplay: "H₂O + C₈H₁₀N₄O₂",
                mappingSummary: "Mapped musical representation blending resonant E-minor ninth harmonics with warm mid-band overtones.",
                baseFrequenciesHz: [329.63, 392.00, 493.88, 587.33, 739.99], // E4, G4, B4, D5, F#5
                shimmerMultiplier: 0.98,
                warmthDecayPerSec: 1.75
            )
        ),
        ReferenceLiquidProfile(
            id: "CITRUS_JUICE",
            displayName: "Citrus / Fruit Juice",
            formulaDisplay: "H₂O + C₆H₈O₇ · Sugars",
            categorySummary: "Organic Acid & Sugar Beverage Reference",
            constituents: [
                ReferenceConstituent(
                    symbol: "H₂O",
                    name: "Water",
                    roleDescription: "Primary juice base"
                ),
                ReferenceConstituent(
                    symbol: "C₆H₈O₇",
                    name: "Citric & Organic Acids",
                    roleDescription: "Fruit acid reference constituent"
                ),
                ReferenceConstituent(
                    symbol: "C₆H₁₂O₆",
                    name: "Natural Sugars",
                    roleDescription: "Dissolved carbohydrate constituent"
                )
            ],
            expectedCentroidHz: 2_400.0,
            expectedPeakHz: 2_060.0,
            expectedMidToHighDB: 4.2,
            expectedDecayDBPerSec: 102.0,
            expectedHighScatterDB: -8.8,
            tuneProfile: ChemicalTuneProfile(
                formulaDisplay: "H₂O + C₆H₈O₇",
                mappingSummary: "Mapped musical representation featuring bright C-Lydian intervals for fruit acids and warm harmonic sustain.",
                baseFrequenciesHz: [261.63, 329.63, 392.00, 493.88, 739.99], // C4, E4, G4, B4, F#5
                shimmerMultiplier: 1.12,
                warmthDecayPerSec: 1.80
            )
        ),
        ReferenceLiquidProfile(
            id: "AQUA_SURFACTANT",
            displayName: "Packaged Aqueous Solution",
            formulaDisplay: "H₂O + Dissolved Solutes",
            categorySummary: "Formulated Household / Bottled Solution",
            constituents: [
                ReferenceConstituent(
                    symbol: "H₂O",
                    name: "Water",
                    roleDescription: "Primary liquid carrier"
                ),
                ReferenceConstituent(
                    symbol: "Solutes",
                    name: "Formulated Active & Ionic Agents",
                    roleDescription: "Packaged household, personal-care, or flavored solute class"
                )
            ],
            expectedCentroidHz: 2_820.0,
            expectedPeakHz: 2_440.0,
            expectedMidToHighDB: 2.2,
            expectedDecayDBPerSec: 98.0,
            expectedHighScatterDB: -6.5,
            tuneProfile: ChemicalTuneProfile(
                formulaDisplay: "H₂O + Solutes",
                mappingSummary: "Mapped musical representation pairing shimmering A-major add9 intervals with clean container resonance.",
                baseFrequenciesHz: [440.00, 554.37, 659.25, 880.00, 987.77], // A4, C#5, E5, A5, B5
                shimmerMultiplier: 1.18,
                warmthDecayPerSec: 1.72
            )
        ),
        ReferenceLiquidProfile(
            id: "ISOPROPYL_ALC",
            displayName: "Rubbing Alcohol Solution",
            formulaDisplay: "H₂O + C₃H₈O",
            categorySummary: "Volatile Alcohol-Water Reference",
            constituents: [
                ReferenceConstituent(
                    symbol: "C₃H₈O",
                    name: "Isopropyl / Ethyl Alcohol",
                    roleDescription: "Volatile alcohol reference constituent"
                ),
                ReferenceConstituent(
                    symbol: "H₂O",
                    name: "Water",
                    roleDescription: "Aqueous cosolvent"
                )
            ],
            expectedCentroidHz: 3_520.0,
            expectedPeakHz: 3_180.0,
            expectedMidToHighDB: -0.8,
            expectedDecayDBPerSec: 80.0,
            expectedHighScatterDB: -5.4,
            tuneProfile: ChemicalTuneProfile(
                formulaDisplay: "H₂O + C₃H₈O",
                mappingSummary: "Mapped musical representation using crisp high-register B-minor pentatonic harmonics.",
                baseFrequenciesHz: [493.88, 587.33, 659.25, 739.99, 987.77], // B4, D5, E5, F#5, B5
                shimmerMultiplier: 1.26,
                warmthDecayPerSec: 1.50
            )
        ),
        ReferenceLiquidProfile(
            id: "OIL_VEG",
            displayName: "Cooking / Vegetable Oil",
            formulaDisplay: "Triglyceride",
            categorySummary: "Lipid Reference Profile (Optical / Calibrated Shift Only — No Airborne Viscosity Claim)",
            constituents: [
                ReferenceConstituent(
                    symbol: "C · H · O",
                    name: "Plant Triglycerides",
                    roleDescription: "Lipid reference class (airborne MODE_A makes no uncalibrated viscosity claim)"
                )
            ],
            expectedCentroidHz: 1_860.0,
            expectedPeakHz: 1_560.0,
            expectedMidToHighDB: 6.8,
            expectedDecayDBPerSec: 128.0,
            expectedHighScatterDB: -11.2,
            tuneProfile: ChemicalTuneProfile(
                formulaDisplay: "C · H · O",
                mappingSummary: "Mapped musical representation featuring low-register carbon-chain intervals.",
                baseFrequenciesHz: [196.00, 293.66, 392.00, 440.00, 587.33], // G3, D4, G4, A4, D5
                shimmerMultiplier: 0.72,
                warmthDecayPerSec: 2.35
            )
        )
    ]
}

/// Persisted consumer-friendly scan item used by Result, Chemical Tune, Calibration, and History.
public struct ConsumerScanItem: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let scannedAt: Date
    public let scanSequenceNumber: Int?
    public let batchRunID: String?
    public let batchScanIndex: Int?
    public let batchTotalCount: Int?
    public let geometryCondition: String?
    public let controlSeriesTag: String?
    public let aeAfWbLockState: String?
    public let targetLockState: String?
    public let targetLockScore: Double?
    public let gateDecision: String?
    public let rejectionReason: String?
    public let status: ConsumerMatchStatus
    public let title: String
    public let formulaDisplay: String
    public let statusBadgeText: String
    public let confidencePercent: Int?
    public let scientificNote: String
    public let constituents: [ReferenceConstituent]
    public let tuneProfile: ChemicalTuneProfile
    public let measuredPeakHz: Double
    public let measuredCentroidHz: Double
    public let measuredDecayDBPerSec: Double
    public let measuredFeatures: ExtractedConsumerFeatures?
    public let topCandidateName: String?
    public let topCandidateDistance: Double?
    public let runnerUpTitle: String?
    public let runnerUpSimilarityPercent: Int?
    public let secondCandidateDistance: Double?
    public let winningMargin: Double?
    public let allCandidateDistances: [CandidateScoreEntry]?
    public let thumbnailJPEGData: Data?
    public let isConditioningCycle: Bool
    public let conditioningTag: String?
    public let modeAScreeningState: ModeAScreeningState?
    public let deltaEmptyBaseline: DifferentialBaselineVector?
    public let deltaWaterBaseline: DifferentialBaselineVector?

    public init(
        id: UUID = UUID(),
        scannedAt: Date = Date(),
        scanSequenceNumber: Int? = nil,
        batchRunID: String? = nil,
        batchScanIndex: Int? = nil,
        batchTotalCount: Int? = nil,
        geometryCondition: String? = nil,
        controlSeriesTag: String? = nil,
        aeAfWbLockState: String? = nil,
        targetLockState: String? = nil,
        targetLockScore: Double? = nil,
        gateDecision: String? = nil,
        rejectionReason: String? = nil,
        status: ConsumerMatchStatus,
        title: String,
        formulaDisplay: String,
        statusBadgeText: String,
        confidencePercent: Int?,
        scientificNote: String,
        constituents: [ReferenceConstituent],
        tuneProfile: ChemicalTuneProfile,
        measuredPeakHz: Double,
        measuredCentroidHz: Double,
        measuredDecayDBPerSec: Double,
        measuredFeatures: ExtractedConsumerFeatures? = nil,
        topCandidateName: String? = nil,
        topCandidateDistance: Double? = nil,
        runnerUpTitle: String? = nil,
        runnerUpSimilarityPercent: Int? = nil,
        secondCandidateDistance: Double? = nil,
        winningMargin: Double? = nil,
        allCandidateDistances: [CandidateScoreEntry]? = nil,
        thumbnailJPEGData: Data? = nil,
        isConditioningCycle: Bool? = nil,
        conditioningTag: String? = nil,
        modeAScreeningState: ModeAScreeningState? = nil,
        deltaEmptyBaseline: DifferentialBaselineVector? = nil,
        deltaWaterBaseline: DifferentialBaselineVector? = nil
    ) {
        self.id = id
        self.scannedAt = scannedAt
        self.scanSequenceNumber = scanSequenceNumber
        self.batchRunID = batchRunID
        self.batchScanIndex = batchScanIndex
        self.batchTotalCount = batchTotalCount
        self.geometryCondition = geometryCondition
        self.controlSeriesTag = controlSeriesTag
        self.aeAfWbLockState = aeAfWbLockState
        self.targetLockState = targetLockState
        self.targetLockScore = targetLockScore
        self.gateDecision = gateDecision
        self.rejectionReason = rejectionReason
        self.status = status
        self.title = title
        self.formulaDisplay = formulaDisplay
        self.statusBadgeText = statusBadgeText
        self.confidencePercent = confidencePercent
        self.scientificNote = scientificNote
        self.constituents = constituents
        self.tuneProfile = tuneProfile
        self.measuredPeakHz = measuredPeakHz
        self.measuredCentroidHz = measuredCentroidHz
        self.measuredDecayDBPerSec = measuredDecayDBPerSec
        self.measuredFeatures = measuredFeatures
        self.topCandidateName = topCandidateName
        self.topCandidateDistance = topCandidateDistance
        self.runnerUpTitle = runnerUpTitle
        self.runnerUpSimilarityPercent = runnerUpSimilarityPercent
        self.secondCandidateDistance = secondCandidateDistance
        self.winningMargin = winningMargin
        self.allCandidateDistances = allCandidateDistances
        self.thumbnailJPEGData = thumbnailJPEGData
        let autoCond = WarmBatchAudioEngine.isConditioningSweep(
            batchIndex: batchScanIndex ?? 0,
            batchTotalCount: batchTotalCount ?? 1
        )
        let resolvedCond = isConditioningCycle ?? autoCond
        self.isConditioningCycle = resolvedCond
        self.conditioningTag = conditioningTag ?? (resolvedCond ? "ACQ_WARMUP_PURGE_K2" : nil)
        self.modeAScreeningState = modeAScreeningState
        self.deltaEmptyBaseline = deltaEmptyBaseline
        self.deltaWaterBaseline = deltaWaterBaseline
    }

    private enum CodingKeys: String, CodingKey {
        case id, scannedAt, scanSequenceNumber, batchRunID, batchScanIndex, batchTotalCount
        case geometryCondition, controlSeriesTag, aeAfWbLockState, targetLockState, targetLockScore
        case gateDecision, rejectionReason, status, title, formulaDisplay, statusBadgeText
        case confidencePercent, scientificNote, constituents, tuneProfile
        case measuredPeakHz, measuredCentroidHz, measuredDecayDBPerSec, measuredFeatures
        case topCandidateName, topCandidateDistance, runnerUpTitle, runnerUpSimilarityPercent
        case secondCandidateDistance, winningMargin, allCandidateDistances, thumbnailJPEGData
        case isConditioningCycle, conditioningTag, modeAScreeningState
        case deltaEmptyBaseline, deltaWaterBaseline
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.scannedAt = try c.decode(Date.self, forKey: .scannedAt)
        self.scanSequenceNumber = try c.decodeIfPresent(Int.self, forKey: .scanSequenceNumber)
        self.batchRunID = try c.decodeIfPresent(String.self, forKey: .batchRunID)
        let bIdx = try c.decodeIfPresent(Int.self, forKey: .batchScanIndex)
        let bTot = try c.decodeIfPresent(Int.self, forKey: .batchTotalCount)
        self.batchScanIndex = bIdx
        self.batchTotalCount = bTot
        self.geometryCondition = try c.decodeIfPresent(String.self, forKey: .geometryCondition)
        self.controlSeriesTag = try c.decodeIfPresent(String.self, forKey: .controlSeriesTag)
        self.aeAfWbLockState = try c.decodeIfPresent(String.self, forKey: .aeAfWbLockState)
        self.targetLockState = try c.decodeIfPresent(String.self, forKey: .targetLockState)
        self.targetLockScore = try c.decodeIfPresent(Double.self, forKey: .targetLockScore)
        self.gateDecision = try c.decodeIfPresent(String.self, forKey: .gateDecision)
        self.rejectionReason = try c.decodeIfPresent(String.self, forKey: .rejectionReason)
        self.status = try c.decode(ConsumerMatchStatus.self, forKey: .status)
        self.title = try c.decode(String.self, forKey: .title)
        self.formulaDisplay = try c.decode(String.self, forKey: .formulaDisplay)
        self.statusBadgeText = try c.decode(String.self, forKey: .statusBadgeText)
        self.confidencePercent = try c.decodeIfPresent(Int.self, forKey: .confidencePercent)
        self.scientificNote = try c.decode(String.self, forKey: .scientificNote)
        self.constituents = try c.decode([ReferenceConstituent].self, forKey: .constituents)
        self.tuneProfile = try c.decode(ChemicalTuneProfile.self, forKey: .tuneProfile)
        self.measuredPeakHz = try c.decode(Double.self, forKey: .measuredPeakHz)
        self.measuredCentroidHz = try c.decode(Double.self, forKey: .measuredCentroidHz)
        self.measuredDecayDBPerSec = try c.decode(Double.self, forKey: .measuredDecayDBPerSec)
        self.measuredFeatures = try c.decodeIfPresent(ExtractedConsumerFeatures.self, forKey: .measuredFeatures)
        self.topCandidateName = try c.decodeIfPresent(String.self, forKey: .topCandidateName)
        self.topCandidateDistance = try c.decodeIfPresent(Double.self, forKey: .topCandidateDistance)
        self.runnerUpTitle = try c.decodeIfPresent(String.self, forKey: .runnerUpTitle)
        self.runnerUpSimilarityPercent = try c.decodeIfPresent(Int.self, forKey: .runnerUpSimilarityPercent)
        self.secondCandidateDistance = try c.decodeIfPresent(Double.self, forKey: .secondCandidateDistance)
        self.winningMargin = try c.decodeIfPresent(Double.self, forKey: .winningMargin)
        self.allCandidateDistances = try c.decodeIfPresent([CandidateScoreEntry].self, forKey: .allCandidateDistances)
        self.thumbnailJPEGData = try c.decodeIfPresent(Data.self, forKey: .thumbnailJPEGData)
        let decodedCond = try c.decodeIfPresent(Bool.self, forKey: .isConditioningCycle)
            ?? WarmBatchAudioEngine.isConditioningSweep(batchIndex: bIdx ?? 0, batchTotalCount: bTot ?? 1)
        self.isConditioningCycle = decodedCond
        self.conditioningTag = try c.decodeIfPresent(String.self, forKey: .conditioningTag)
            ?? (decodedCond ? "ACQ_WARMUP_PURGE_K2" : nil)
        self.modeAScreeningState = try c.decodeIfPresent(ModeAScreeningState.self, forKey: .modeAScreeningState)
        self.deltaEmptyBaseline = try c.decodeIfPresent(DifferentialBaselineVector.self, forKey: .deltaEmptyBaseline)
        self.deltaWaterBaseline = try c.decodeIfPresent(DifferentialBaselineVector.self, forKey: .deltaWaterBaseline)
    }
}

// MARK: - R1 (20x) Multi-Scan Spectral Peak-Stability Analyzer (Modal Integrity Only — Never Chemical Identity)

/// Five-category modal classification for recurring candidate bands & noisy acquisitions across an N-scan series.
public enum SpectralPeakBandCategory: String, Codable, Equatable, Sendable {
    case persistentPeak = "PERSISTENT_PEAK"
    case intermittentPeak = "INTERMITTENT_PEAK"
    case likelyHarmonicOrSubharmonic = "LIKELY_HARMONIC_OR_SUBHARMONIC"
    case isolatedTransientPeak = "ISOLATED_TRANSIENT_PEAK"
}

public struct TrackedSpectralBand: Codable, Equatable, Identifiable, Sendable {
    public var id: String { String(format: "%.1f_%@", centerMeanHz, category.rawValue) }
    public let centerMeanHz: Double
    public let centerSDHz: Double
    public let minHz: Double
    public let maxHz: Double
    public let cvPercent: Double
    public let presenceCount: Int
    public let validScanCount: Int
    public let primaryWinCount: Int
    public let meanAmplitudeDB: Double
    public let category: SpectralPeakBandCategory
    public let harmonicRelationNote: String?

    public var persistenceFraction: Double {
        guard validScanCount > 0 else { return 0.0 }
        return Double(presenceCount) / Double(validScanCount)
    }

    public init(
        centerMeanHz: Double,
        centerSDHz: Double,
        minHz: Double,
        maxHz: Double,
        cvPercent: Double,
        presenceCount: Int,
        validScanCount: Int,
        primaryWinCount: Int,
        meanAmplitudeDB: Double,
        category: SpectralPeakBandCategory,
        harmonicRelationNote: String? = nil
    ) {
        self.centerMeanHz = centerMeanHz
        self.centerSDHz = centerSDHz
        self.minHz = minHz
        self.maxHz = maxHz
        self.cvPercent = cvPercent
        self.presenceCount = presenceCount
        self.validScanCount = validScanCount
        self.primaryWinCount = primaryWinCount
        self.meanAmplitudeDB = meanAmplitudeDB
        self.category = category
        self.harmonicRelationNote = harmonicRelationNote
    }
}

public struct NoisyAcquisitionEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(scanSequenceNumber ?? 0)_\(batchScanIndex ?? 0)" }
    public let scanSequenceNumber: Int?
    public let batchScanIndex: Int?
    public let measuredPeakHz: Double
    public let activeSNRDB: Double
    public let tailSNRDB: Double
    public let reason: String

    public init(
        scanSequenceNumber: Int?,
        batchScanIndex: Int?,
        measuredPeakHz: Double,
        activeSNRDB: Double,
        tailSNRDB: Double,
        reason: String
    ) {
        self.scanSequenceNumber = scanSequenceNumber
        self.batchScanIndex = batchScanIndex
        self.measuredPeakHz = measuredPeakHz
        self.activeSNRDB = activeSNRDB
        self.tailSNRDB = tailSNRDB
        self.reason = reason
    }
}

public struct RepeatabilityPeakStabilityReport: Codable, Equatable, Sendable {
    public let totalAcquisitions: Int
    public let validQualityAcquisitions: Int
    public let primaryPeakMeanHz: Double
    public let primaryPeakSDHz: Double
    public let primaryPeakCVPercent: Double
    public let primaryPeakMinHz: Double
    public let primaryPeakMaxHz: Double
    public let persistentBands: [TrackedSpectralBand]
    public let intermittentBands: [TrackedSpectralBand]
    public let harmonicOrSubharmonicBands: [TrackedSpectralBand]
    public let isolatedTransientBands: [TrackedSpectralBand]
    public let lowConfidenceNoisyScans: [NoisyAcquisitionEntry]
    public let stabilityDisposition: String

    public init(
        totalAcquisitions: Int,
        validQualityAcquisitions: Int,
        primaryPeakMeanHz: Double,
        primaryPeakSDHz: Double,
        primaryPeakCVPercent: Double,
        primaryPeakMinHz: Double,
        primaryPeakMaxHz: Double,
        persistentBands: [TrackedSpectralBand],
        intermittentBands: [TrackedSpectralBand],
        harmonicOrSubharmonicBands: [TrackedSpectralBand],
        isolatedTransientBands: [TrackedSpectralBand],
        lowConfidenceNoisyScans: [NoisyAcquisitionEntry],
        stabilityDisposition: String
    ) {
        self.totalAcquisitions = totalAcquisitions
        self.validQualityAcquisitions = validQualityAcquisitions
        self.primaryPeakMeanHz = primaryPeakMeanHz
        self.primaryPeakSDHz = primaryPeakSDHz
        self.primaryPeakCVPercent = primaryPeakCVPercent
        self.primaryPeakMinHz = primaryPeakMinHz
        self.primaryPeakMaxHz = primaryPeakMaxHz
        self.persistentBands = persistentBands
        self.intermittentBands = intermittentBands
        self.harmonicOrSubharmonicBands = harmonicOrSubharmonicBands
        self.isolatedTransientBands = isolatedTransientBands
        self.lowConfidenceNoisyScans = lowConfidenceNoisyScans
        self.stabilityDisposition = stabilityDisposition
    }
}

public enum RepeatabilityPeakStabilityAnalyzer {
    private struct PeakObservation {
        let scanIdx: Int
        let freqHz: Double
        let ampDB: Double
        let isPrimary: Bool
    }

    private struct MutableCluster {
        var observations: [PeakObservation]
        var meanHz: Double {
            guard !observations.isEmpty else { return 0.0 }
            return observations.reduce(0.0) { $0 + $1.freqHz } / Double(observations.count)
        }
    }

    /// Evaluates spectral peak persistence across a fixed-geometry scan series without assigning chemical identity.
    public static func analyze(items: [ConsumerScanItem]) -> RepeatabilityPeakStabilityReport {
        var noisyEntries: [NoisyAcquisitionEntry] = []
        var validItems: [(idx: Int, item: ConsumerScanItem)] = []

        for (offset, item) in items.enumerated() {
            let feat = item.measuredFeatures
            let actSNR = feat?.activeSNRDB ?? 0.0
            let tailSNR = feat?.tailSNRDB ?? 12.0
            let clipped = feat?.clippedSamples ?? 0

            if item.status == .unclearScan || clipped > 8 || (feat != nil && actSNR < 1.8) || (feat != nil && tailSNR < 2.2) {
                let reason = item.rejectionReason ?? (
                    clipped > 8 ? "CLIPPING (\(clipped) samples)" :
                    actSNR < 1.8 ? String(format: "LOW_ACTIVE_SNR (%.1f dB)", actSNR) :
                    tailSNR < 2.2 ? String(format: "LOW_TAIL_SNR (%.1f dB)", tailSNR) :
                    "INVALID_MEASUREMENT"
                )
                noisyEntries.append(
                    NoisyAcquisitionEntry(
                        scanSequenceNumber: item.scanSequenceNumber,
                        batchScanIndex: item.batchScanIndex ?? (offset + 1),
                        measuredPeakHz: item.measuredPeakHz,
                        activeSNRDB: actSNR,
                        tailSNRDB: tailSNR,
                        reason: reason
                    )
                )
            } else if item.status != .nonLiquidMaterial {
                validItems.append((offset, item))
            }
        }

        let validCount = validItems.count
        let primaryPeaks = validItems.map { $0.item.measuredPeakHz }
        let (pkMean, pkSD, pkMin, pkMax) = Self.basicStats(primaryPeaks)
        let pkCV = pkMean > 1e-6 ? (100.0 * pkSD / pkMean) : 0.0

        // Gather primary + secondary candidate peaks per valid scan
        var allObs: [PeakObservation] = []
        for (scanKey, item) in validItems {
            let f = item.measuredFeatures
            let pAmp = f?.primaryPeakAmplitudeDB ?? f?.activeRMSDBFS ?? -30.0
            allObs.append(PeakObservation(scanIdx: scanKey, freqHz: item.measuredPeakHz, ampDB: pAmp, isPrimary: true))

            if let secHz = f?.secondaryPeaksHz {
                let secAmps = f?.secondaryPeakAmplitudesDB ?? []
                for (k, hz) in secHz.enumerated() where hz > 100.0 {
                    let sAmp = k < secAmps.count ? secAmps[k] : (pAmp - 4.0)
                    allObs.append(PeakObservation(scanIdx: scanKey, freqHz: hz, ampDB: sAmp, isPrimary: false))
                }
            }
        }

        // Greedy agglomerative clustering into recurring frequency bands (tolerance max(75 Hz, 4.0% of center))
        let sortedObs = allObs.sorted { $0.freqHz < $1.freqHz }
        var clusters: [MutableCluster] = []
        for obs in sortedObs {
            var bestIdx: Int?
            var bestDist = Double.infinity
            for (cIdx, cluster) in clusters.enumerated() {
                // Only one peak per scan can belong to a given modal band
                if cluster.observations.contains(where: { $0.scanIdx == obs.scanIdx }) { continue }
                let center = cluster.meanHz
                let tol = max(75.0, 0.040 * center)
                let dist = abs(obs.freqHz - center)
                if dist <= tol && dist < bestDist {
                    bestDist = dist
                    bestIdx = cIdx
                }
            }
            if let idx = bestIdx {
                clusters[idx].observations.append(obs)
            } else {
                clusters.append(MutableCluster(observations: [obs]))
            }
        }

        // Identify persistent core bands first (>= 60% presence & CV <= 4.5%) to check harmonic/subharmonic ratios
        struct RawBandStats {
            let meanHz: Double
            let sdHz: Double
            let minHz: Double
            let maxHz: Double
            let cvPct: Double
            let presence: Int
            let primaryWins: Int
            let meanAmpDB: Double
            let fraction: Double
        }

        let rawBands: [RawBandStats] = clusters.map { c in
            let freqs = c.observations.map(\.freqHz)
            let (m, sd, mn, mx) = Self.basicStats(freqs)
            let cv = m > 1e-6 ? (100.0 * sd / m) : 0.0
            let pres = Set(c.observations.map(\.scanIdx)).count
            let wins = c.observations.filter(\.isPrimary).count
            let meanAmp = c.observations.reduce(0.0) { $0 + $1.ampDB } / Double(max(1, c.observations.count))
            let frac = validCount > 0 ? Double(pres) / Double(validCount) : 0.0
            return RawBandStats(
                meanHz: m, sdHz: sd, minHz: mn, maxHz: mx, cvPct: cv,
                presence: pres, primaryWins: wins, meanAmpDB: meanAmp, fraction: frac
            )
        }.sorted {
            if $0.presence != $1.presence { return $0.presence > $1.presence }
            return $0.meanAmpDB > $1.meanAmpDB
        }

        let persistentAnchors = rawBands.filter { $0.fraction >= 0.60 && $0.cvPct <= 4.5 }

        var persistentOut: [TrackedSpectralBand] = []
        var intermittentOut: [TrackedSpectralBand] = []
        var harmonicOut: [TrackedSpectralBand] = []
        var transientOut: [TrackedSpectralBand] = []

        for band in rawBands {
            var harmonicNote: String?
            for anchor in persistentAnchors where abs(anchor.meanHz - band.meanHz) > 120.0 {
                // Only classify the weaker or secondary-winning mode as harmonic/subharmonic of the dominant persistent mode
                let anchorDominates = (anchor.primaryWins > band.primaryWins) ||
                    (anchor.primaryWins == band.primaryWins && anchor.meanAmpDB >= band.meanAmpDB)
                guard anchorDominates else { continue }

                let ratio = band.meanHz / max(1.0, anchor.meanHz)
                for mult in [2, 3, 4] {
                    if abs(ratio - Double(mult)) <= (0.042 * Double(mult)) {
                        harmonicNote = String(format: "%dx harmonic of %.0f Hz (ratio %.2f)", mult, anchor.meanHz, ratio)
                        break
                    }
                }
                if harmonicNote == nil {
                    for div in [2, 3] {
                        let target = 1.0 / Double(div)
                        if abs(ratio - target) <= (0.042 * target) {
                            harmonicNote = String(format: "1/%d subharmonic of %.0f Hz (ratio %.2f)", div, anchor.meanHz, ratio)
                            break
                        }
                    }
                }
                if harmonicNote != nil { break }
            }

            let isIsolated = (validCount >= 5) ? (band.presence <= 1 || band.fraction < 0.15) : (band.presence == 1 && validCount >= 3)
            let category: SpectralPeakBandCategory
            if harmonicNote != nil && !(band.primaryWins > validCount / 2 && band.fraction >= 0.75) {
                category = .likelyHarmonicOrSubharmonic
            } else if band.fraction >= 0.60 && band.cvPct <= 4.5 {
                category = .persistentPeak
            } else if isIsolated {
                category = .isolatedTransientPeak
            } else {
                category = .intermittentPeak
            }

            let tracked = TrackedSpectralBand(
                centerMeanHz: band.meanHz,
                centerSDHz: band.sdHz,
                minHz: band.minHz,
                maxHz: band.maxHz,
                cvPercent: band.cvPct,
                presenceCount: band.presence,
                validScanCount: validCount,
                primaryWinCount: band.primaryWins,
                meanAmplitudeDB: band.meanAmpDB,
                category: category,
                harmonicRelationNote: harmonicNote
            )

            switch category {
            case .persistentPeak:
                persistentOut.append(tracked)
            case .intermittentPeak:
                intermittentOut.append(tracked)
            case .likelyHarmonicOrSubharmonic:
                harmonicOut.append(tracked)
            case .isolatedTransientPeak:
                transientOut.append(tracked)
            }
        }

        let disposition: String
        if validCount < 2 {
            disposition = "INSUFFICIENT_VALID_ACQUISITIONS"
        } else if !persistentOut.isEmpty && pkCV <= 3.5 {
            disposition = "REPEATABLE_PERSISTENT_MODE"
        } else if persistentOut.count >= 1 && pkCV > 8.0 {
            disposition = "COMPETING_PEAK_REGIMES"
        } else {
            disposition = "UNSTABLE_SPECTRAL_SCATTER"
        }

        return RepeatabilityPeakStabilityReport(
            totalAcquisitions: items.count,
            validQualityAcquisitions: validCount,
            primaryPeakMeanHz: pkMean,
            primaryPeakSDHz: pkSD,
            primaryPeakCVPercent: pkCV,
            primaryPeakMinHz: pkMin,
            primaryPeakMaxHz: pkMax,
            persistentBands: persistentOut,
            intermittentBands: intermittentOut,
            harmonicOrSubharmonicBands: harmonicOut,
            isolatedTransientBands: transientOut,
            lowConfidenceNoisyScans: noisyEntries,
            stabilityDisposition: disposition
        )
    }

    private static func basicStats(_ values: [Double]) -> (mean: Double, sd: Double, min: Double, max: Double) {
        guard !values.isEmpty else { return (0, 0, 0, 0) }
        let n = Double(values.count)
        let mean = values.reduce(0.0, +) / n
        let variance = values.count > 1
            ? values.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / (n - 1.0)
            : 0.0
        return (mean, sqrt(max(0.0, variance)), values.min() ?? mean, values.max() ?? mean)
    }
}

/// Phase R2-B (`LA-R2-A-SANDBOX-REPORT-001`) continuity-preserving 4-mode vector tracker across multi-sweep bursts.
/// Purges `K_cond = 2` conditioning sweeps on calibration bursts, associates modal peaks via Hungarian minimum-cost
/// bipartite matching, and emits `mask_i = 0` (`frequenciesWithNaN[i] == .nan`) for any absent mode without zero-padding.
public enum BatchModalVectorTracker {
    public struct SweepModeObservation: Sendable, Equatable {
        public let freqHz: Double
        public let ampDB: Double
        public let qFactor: Double?
        public let alphaPerSec: Double?
        public let alphaDBPerSec: Double?
        public let alphaRSquared: Double?

        public init(
            freqHz: Double,
            ampDB: Double,
            qFactor: Double? = nil,
            alphaPerSec: Double? = nil,
            alphaDBPerSec: Double? = nil,
            alphaRSquared: Double? = nil
        ) {
            self.freqHz = freqHz
            self.ampDB = ampDB
            self.qFactor = qFactor
            self.alphaPerSec = alphaPerSec
            self.alphaDBPerSec = alphaDBPerSec
            self.alphaRSquared = alphaRSquared
        }
    }

    private struct ActiveTrack {
        let trackID: Int
        let birthSweep: Int
        let fInit: Double
        var lastSweep: Int
        var fHat: Double
        var vHat: Double
        var ampHat: Double
        var qHat: Double?
        var alphaHat: Double?
        var observations: [SweepModeObservation]
    }

    public static func aggregateSteadyStateModalVector(
        items: [ConsumerScanItem],
        purgeConditioningK2: Bool = true,
        persistenceFraction: Double = 0.65
    ) -> ModalVector4 {
        let ordered = items.sorted { ($0.batchScanIndex ?? 0) < ($1.batchScanIndex ?? 0) }
        let eligible = ordered.filter { item in
            guard item.status != .unclearScan && item.status != .nonLiquidMaterial else { return false }
            if purgeConditioningK2 && item.isConditioningCycle { return false }
            return true
        }
        guard !eligible.isEmpty else { return .emptyMasked }

        var sweepList: [(sweepIdx: Int, modes: [SweepModeObservation])] = []
        var slopes: [Double] = []
        var scatters: [Double] = []
        var latePreRolls: [Double] = []

        for (offset, item) in eligible.enumerated() {
            let sIdx = item.batchScanIndex ?? (offset + 1)
            guard let feat = item.measuredFeatures else { continue }
            latePreRolls.append(feat.latePreRollNoiseDBFS)
            if let mv = feat.modalVector {
                if let s = mv.spectralAttenuationSlopeDBPerKHz, s.isFinite { slopes.append(s) }
                if let sc = mv.bubbleScatter55to85DB, sc.isFinite { scatters.append(sc) }
                var cands: [SweepModeObservation] = []
                for k in 0..<4 where mv.validityMask[k] == 1 {
                    if let f = mv.frequenciesHz[k], f.isFinite {
                        let amp = k == 0
                            ? feat.primaryPeakAmplitudeDB
                            : (k - 1 < feat.secondaryPeakAmplitudesDB.count ? feat.secondaryPeakAmplitudesDB[k - 1] : feat.primaryPeakAmplitudeDB - 3.0)
                        cands.append(
                            SweepModeObservation(
                                freqHz: f,
                                ampDB: amp,
                                qFactor: mv.qValidityMask[k] == 1 ? mv.qualityFactorsQ[k] : nil,
                                alphaPerSec: mv.decayValidityMask[k] == 1 ? mv.decayAlphaPerSec[k] : nil,
                                alphaDBPerSec: mv.decayValidityMask[k] == 1 ? mv.decayDBPerSec[k] : nil,
                                alphaRSquared: mv.decayValidityMask[k] == 1 ? mv.decayRSquared[k] : nil
                            )
                        )
                    }
                }
                sweepList.append((sIdx, cands))
            } else {
                var cands = [SweepModeObservation(freqHz: item.measuredPeakHz, ampDB: feat.primaryPeakAmplitudeDB)]
                for (k, sf) in feat.secondaryPeaksHz.enumerated() where sf > 0 {
                    let sa = k < feat.secondaryPeakAmplitudesDB.count ? feat.secondaryPeakAmplitudesDB[k] : (feat.primaryPeakAmplitudeDB - 3.0)
                    cands.append(SweepModeObservation(freqHz: sf, ampDB: sa))
                }
                sweepList.append((sIdx, cands))
            }
        }

        return trackSweeps(
            sweeps: sweepList,
            persistenceFraction: persistenceFraction,
            medianSlope: median(slopes),
            medianScatter: median(scatters),
            medianLatePreRoll: median(latePreRolls) ?? -82.0
        )
    }

    public static func trackSweeps(
        sweeps: [(sweepIdx: Int, modes: [SweepModeObservation])],
        persistenceFraction: Double = 0.65,
        enableDriftVelocity: Bool = false,
        medianSlope: Double? = nil,
        medianScatter: Double? = nil,
        medianLatePreRoll: Double = -82.0
    ) -> ModalVector4 {
        guard !sweeps.isEmpty else { return .emptyMasked }
        var tracks: [ActiveTrack] = []
        var nextID = 1
        let unmatchedCost = 9.0

        for (sweepIdx, cands) in sweeps {
            if tracks.isEmpty {
                for c in cands.sorted(by: { $0.freqHz < $1.freqHz }) {
                    tracks.append(
                        ActiveTrack(
                            trackID: nextID,
                            birthSweep: sweepIdx,
                            fInit: c.freqHz,
                            lastSweep: sweepIdx,
                            fHat: c.freqHz,
                            vHat: 0.0,
                            ampHat: c.ampDB,
                            qHat: c.qFactor,
                            alphaHat: c.alphaPerSec,
                            observations: [c]
                        )
                    )
                    nextID += 1
                }
                continue
            }

            let nT = tracks.count
            let nC = cands.count
            var costMat = Array(repeating: Array(repeating: unmatchedCost, count: nC + nT), count: nT)

            for i in 0..<nT {
                let tr = tracks[i]
                let dt = Double(max(1, sweepIdx - tr.lastSweep))
                let fPred = tr.fHat + (enableDriftVelocity ? tr.vHat * dt : 0.0)
                let effSigmaF = 45.0 * sqrt(dt)
                let maxDisp = max(150.0 * sqrt(dt), 0.045 * tr.fHat)

                for j in 0..<nC {
                    let c = cands[j]
                    let df = abs(c.freqHz - fPred)
                    if df > maxDisp {
                        costMat[i][j] = 1e5
                        continue
                    }
                    var cost = (df / effSigmaF) * (df / effSigmaF)
                    let dAmp = (c.ampDB - tr.ampHat) / 6.0
                    cost += 0.35 * dAmp * dAmp
                    if let qc = c.qFactor, let qt = tr.qHat, qc > 0, qt > 0 {
                        let lq = log(qc / qt)
                        cost += 0.80 * lq * lq
                    }
                    if let ac = c.alphaPerSec, let at = tr.alphaHat, ac > 0, at > 0 {
                        let la = log(ac / at)
                        cost += 0.80 * la * la
                    }
                    costMat[i][j] = cost
                }
                costMat[i][nC + i] = unmatchedCost
            }

            let assignment = solveHungarian(costMatrix: costMat)
            var matchedCand = Set<Int>()
            for i in 0..<nT {
                let col = assignment[i]
                if col >= 0 && col < nC && costMat[i][col] < unmatchedCost {
                    matchedCand.insert(col)
                    let c = cands[col]
                    let dt = Double(max(1, sweepIdx - tracks[i].lastSweep))
                    let fPred = tracks[i].fHat + (enableDriftVelocity ? tracks[i].vHat * dt : 0.0)
                    let res = c.freqHz - fPred
                    if enableDriftVelocity {
                        if tracks[i].observations.count == 1 {
                            tracks[i].vHat = (c.freqHz - tracks[i].fHat) / dt
                            tracks[i].fHat = c.freqHz
                        } else {
                            tracks[i].fHat = fPred + 0.70 * res
                            tracks[i].vHat += 0.35 * (res / dt)
                        }
                    } else {
                        tracks[i].fHat = 0.35 * tracks[i].fHat + 0.65 * c.freqHz
                    }
                    tracks[i].ampHat = 0.5 * tracks[i].ampHat + 0.5 * c.ampDB
                    if let qc = c.qFactor { tracks[i].qHat = tracks[i].qHat.map { 0.5 * $0 + 0.5 * qc } ?? qc }
                    if let ac = c.alphaPerSec { tracks[i].alphaHat = tracks[i].alphaHat.map { 0.5 * $0 + 0.5 * ac } ?? ac }
                    tracks[i].lastSweep = sweepIdx
                    tracks[i].observations.append(c)
                }
            }

            for j in 0..<nC where !matchedCand.contains(j) {
                let c = cands[j]
                tracks.append(
                    ActiveTrack(
                        trackID: nextID,
                        birthSweep: sweepIdx,
                        fInit: c.freqHz,
                        lastSweep: sweepIdx,
                        fHat: c.freqHz,
                        vHat: 0.0,
                        ampHat: c.ampDB,
                        qHat: c.qFactor,
                        alphaHat: c.alphaPerSec,
                        observations: [c]
                    )
                )
                nextID += 1
            }
        }

        let minCount = max(1, Int(ceil(persistenceFraction * Double(sweeps.count))))
        let qualified = tracks.filter { $0.observations.count >= minCount }
        let topStrength = qualified.sorted {
            (median($0.observations.map(\.ampDB)) ?? -120.0) > (median($1.observations.map(\.ampDB)) ?? -120.0)
        }
        let selected = Array(topStrength.prefix(4)).sorted {
            if $0.birthSweep != $1.birthSweep { return $0.birthSweep < $1.birthSweep }
            return $0.fInit < $1.fInit
        }

        var fOut: [Double?] = [nil, nil, nil, nil]
        var fMask: [Int] = [0, 0, 0, 0]
        var qOut: [Double?] = [nil, nil, nil, nil]
        var qMask: [Int] = [0, 0, 0, 0]
        var aOut: [Double?] = [nil, nil, nil, nil]
        var aDBOut: [Double?] = [nil, nil, nil, nil]
        var aR2Out: [Double?] = [nil, nil, nil, nil]
        var aMask: [Int] = [0, 0, 0, 0]

        for (slot, tr) in selected.enumerated() where slot < 4 {
            if let fm = median(tr.observations.map(\.freqHz)) {
                fOut[slot] = fm
                fMask[slot] = 1
            }
            let qs = tr.observations.compactMap(\.qFactor).filter(\.isFinite)
            if let qm = median(qs) {
                qOut[slot] = qm
                qMask[slot] = 1
            }
            let alphas = tr.observations.compactMap(\.alphaPerSec).filter(\.isFinite)
            if let am = median(alphas) {
                aOut[slot] = am
                aDBOut[slot] = (20.0 / log(10.0)) * am
                aR2Out[slot] = median(tr.observations.compactMap(\.alphaRSquared).filter(\.isFinite))
                aMask[slot] = 1
            }
        }

        return ModalVector4(
            frequenciesHz: fOut,
            validityMask: fMask,
            qualityFactorsQ: qOut,
            qValidityMask: qMask,
            decayAlphaPerSec: aOut,
            decayDBPerSec: aDBOut,
            decayRSquared: aR2Out,
            decayValidityMask: aMask,
            spectralAttenuationSlopeDBPerKHz: medianSlope,
            bubbleScatter55to85DB: medianScatter,
            latePreRollNoiseDBFS: medianLatePreRoll
        )
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let mid = s.count / 2
        return (s.count % 2 != 0) ? s[mid] : 0.5 * (s[mid - 1] + s[mid])
    }

    private static func solveHungarian(costMatrix: [[Double]]) -> [Int] {
        let nRows = costMatrix.count
        guard nRows > 0 else { return [] }
        let nCols = costMatrix[0].count
        let n = max(nRows, nCols)
        let padCost = 1e6
        var a = Array(repeating: Array(repeating: 0.0, count: n + 1), count: n + 1)
        for i in 1...n {
            for j in 1...n {
                a[i][j] = (i <= nRows && j <= nCols) ? costMatrix[i - 1][j - 1] : padCost
            }
        }
        var u = Array(repeating: 0.0, count: n + 1)
        var v = Array(repeating: 0.0, count: n + 1)
        var p = Array(repeating: 0, count: n + 1)
        var way = Array(repeating: 0, count: n + 1)

        for i in 1...n {
            p[0] = i
            var j0 = 0
            var minv = Array(repeating: Double.infinity, count: n + 1)
            var used = Array(repeating: false, count: n + 1)
            repeat {
                used[j0] = true
                let i0 = p[j0]
                var delta = Double.infinity
                var j1 = 0
                for j in 1...n where !used[j] {
                    let cur = a[i0][j] - u[i0] - v[j]
                    if cur < minv[j] {
                        minv[j] = cur
                        way[j] = j0
                    }
                    if minv[j] < delta {
                        delta = minv[j]
                        j1 = j
                    }
                }
                for j in 0...n {
                    if used[j] {
                        u[p[j]] += delta
                        v[j] -= delta
                    } else {
                        minv[j] -= delta
                    }
                }
                j0 = j1
            } while p[j0] != 0

            repeat {
                let j1 = way[j0]
                p[j0] = p[j1]
                j0 = j1
            } while j0 != 0
        }

        var rowToCol = Array(repeating: -1, count: nRows)
        for j in 1...nCols where p[j] >= 1 && p[j] <= nRows {
            rowToCol[p[j] - 1] = j - 1
        }
        return rowToCol
    }
}
