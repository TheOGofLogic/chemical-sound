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
    public let secondaryPeaksHz: [Double]
    public let spectralCentroidHz: Double
    public let midToHighBandDB: Double
    public let decaySlopeDBPerSec: Double
    public let highFreqBubbleScatterDB: Double
    public let spectralFlatness: Double
    public let peakProminenceDB: Double
    public let cavityMultipathDB: Double
    public let subBandShapeDB: [Double]
    public let echoReturnDB: Double
    public let featureVectorChecksum: String
    public let opticalCenterBrightness: Double
    public let opticalInteriorContrast: Double
    public let opticalRimContrast: Double
    public let opticsLocked: Bool

    public init(
        activeSNRDB: Double,
        activeRMSDBFS: Double = -24.0,
        peakDBFS: Double,
        clippedSamples: Int,
        dominantPeakHz: Double,
        secondaryPeaksHz: [Double] = [],
        spectralCentroidHz: Double,
        midToHighBandDB: Double,
        decaySlopeDBPerSec: Double,
        highFreqBubbleScatterDB: Double = -8.5,
        spectralFlatness: Double = 0.25,
        peakProminenceDB: Double = 12.0,
        cavityMultipathDB: Double = -3.0,
        subBandShapeDB: [Double] = [0, 0, 0, 0, 0, 0],
        echoReturnDB: Double = -14.0,
        featureVectorChecksum: String = "00000000",
        opticalCenterBrightness: Double = 0.50,
        opticalInteriorContrast: Double = 0.02,
        opticalRimContrast: Double = 0.04,
        opticsLocked: Bool = false
    ) {
        self.activeSNRDB = activeSNRDB
        self.activeRMSDBFS = activeRMSDBFS
        self.peakDBFS = peakDBFS
        self.clippedSamples = clippedSamples
        self.dominantPeakHz = dominantPeakHz
        self.secondaryPeaksHz = secondaryPeaksHz
        self.spectralCentroidHz = spectralCentroidHz
        self.midToHighBandDB = midToHighBandDB
        self.decaySlopeDBPerSec = decaySlopeDBPerSec
        self.highFreqBubbleScatterDB = highFreqBubbleScatterDB
        self.spectralFlatness = spectralFlatness
        self.peakProminenceDB = peakProminenceDB
        self.cavityMultipathDB = cavityMultipathDB
        self.subBandShapeDB = subBandShapeDB
        self.echoReturnDB = echoReturnDB
        self.featureVectorChecksum = featureVectorChecksum
        self.opticalCenterBrightness = opticalCenterBrightness
        self.opticalInteriorContrast = opticalInteriorContrast
        self.opticalRimContrast = opticalRimContrast
        self.opticsLocked = opticsLocked
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
            categorySummary: "Viscous Lipid Reference",
            constituents: [
                ReferenceConstituent(
                    symbol: "C · H · O",
                    name: "Plant Triglycerides",
                    roleDescription: "Viscous lipid reference class"
                )
            ],
            expectedCentroidHz: 1_860.0,
            expectedPeakHz: 1_560.0,
            expectedMidToHighDB: 6.8,
            expectedDecayDBPerSec: 128.0,
            expectedHighScatterDB: -11.2,
            tuneProfile: ChemicalTuneProfile(
                formulaDisplay: "C · H · O",
                mappingSummary: "Mapped musical representation featuring warm, rapidly damped low-register carbon-chain harmonics.",
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

    public init(
        id: UUID = UUID(),
        scannedAt: Date = Date(),
        scanSequenceNumber: Int? = nil,
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
        thumbnailJPEGData: Data? = nil
    ) {
        self.id = id
        self.scannedAt = scannedAt
        self.scanSequenceNumber = scanSequenceNumber
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
    }
}
