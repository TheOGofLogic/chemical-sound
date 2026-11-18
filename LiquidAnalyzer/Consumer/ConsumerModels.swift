import Foundation

/// Primary consumer navigation tabs (`Scan | History | Learn | More`).
public enum ConsumerTab: String, CaseIterable, Hashable, Sendable {
    case scan
    case history
    case learn
    case more
}

/// Four-step consumer flow (`AIM -> SCAN -> RESULT -> LISTEN`).
public enum ScanFlowStep: Equatable, Sendable {
    case aim
    case scanning
    case result(ConsumerScanItem)
}

/// Three-state scientific outcome mapped cleanly for consumer display.
public enum ConsumerMatchStatus: String, Codable, Equatable, Sendable {
    case referenceMatch = "REFERENCE_MATCH"
    case unmatchedSignature = "NO_VALIDATED_MATCH"
    case unclearScan = "INVALID_MEASUREMENT"
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
    public let tuneProfile: ChemicalTuneProfile

    public static let provisionalLibrary: [ReferenceLiquidProfile] = [
        ReferenceLiquidProfile(
            id: "H2O_DIST",
            displayName: "Distilled Water",
            formulaDisplay: "H₂O",
            categorySummary: "Aqueous Reference Profile",
            constituents: [
                ReferenceConstituent(
                    symbol: "H₂O",
                    name: "Water",
                    roleDescription: "Primary reference constituent"
                )
            ],
            expectedCentroidHz: 2_350.0,
            expectedPeakHz: 2_150.0,
            expectedMidToHighDB: 4.5,
            expectedDecayDBPerSec: 88.0,
            tuneProfile: ChemicalTuneProfile(
                formulaDisplay: "H₂O",
                mappingSummary: "Mapped musical representation of hydrogen-oxygen reference intervals and measured resonance.",
                baseFrequenciesHz: [392.00, 493.88, 587.33, 783.99, 880.00], // G4, B4, D5, G5, A5
                shimmerMultiplier: 1.05,
                warmthDecayPerSec: 1.45
            )
        ),
        ReferenceLiquidProfile(
            id: "NACL_AQ",
            displayName: "Saline Water",
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
                    roleDescription: "Dissolved salt reference constituent"
                )
            ],
            expectedCentroidHz: 2_720.0,
            expectedPeakHz: 2_520.0,
            expectedMidToHighDB: 3.1,
            expectedDecayDBPerSec: 96.0,
            tuneProfile: ChemicalTuneProfile(
                formulaDisplay: "H₂O + NaCl",
                mappingSummary: "Mapped musical representation combining water harmonics with bright ionic fifth/ninth intervals.",
                baseFrequenciesHz: [392.00, 587.33, 659.25, 739.99, 987.77], // G4, D5, E5, F#5, B5
                shimmerMultiplier: 1.22,
                warmthDecayPerSec: 1.65
            )
        ),
        ReferenceLiquidProfile(
            id: "SUC_AQ",
            displayName: "Sweetened Water",
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
                    name: "Sucrose",
                    roleDescription: "Dissolved sugar reference constituent"
                )
            ],
            expectedCentroidHz: 2_050.0,
            expectedPeakHz: 1_880.0,
            expectedMidToHighDB: 6.4,
            expectedDecayDBPerSec: 118.0,
            tuneProfile: ChemicalTuneProfile(
                formulaDisplay: "H₂O + C₁₂H₂₂O₁₁",
                mappingSummary: "Mapped musical representation pairing carbon bass intervals with warm damped water harmonics.",
                baseFrequenciesHz: [261.63, 392.00, 493.88, 587.33, 659.25], // C4, G4, B4, D5, E5
                shimmerMultiplier: 0.90,
                warmthDecayPerSec: 1.95
            )
        ),
        ReferenceLiquidProfile(
            id: "VIN_WHITE",
            displayName: "White Vinegar",
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
            expectedCentroidHz: 2_540.0,
            expectedPeakHz: 2_310.0,
            expectedMidToHighDB: 3.8,
            expectedDecayDBPerSec: 104.0,
            tuneProfile: ChemicalTuneProfile(
                formulaDisplay: "H₂O + CH₃COOH",
                mappingSummary: "Mapped musical representation blending carbon-oxygen intervals with crisp upper harmonics.",
                baseFrequenciesHz: [293.66, 440.00, 554.37, 659.25, 880.00], // D4, A4, C#5, E5, A5
                shimmerMultiplier: 1.15,
                warmthDecayPerSec: 1.70
            )
        ),
        ReferenceLiquidProfile(
            id: "OIL_VEG",
            displayName: "Vegetable Oil",
            formulaDisplay: "Triglyceride",
            categorySummary: "Viscous Lipid Reference",
            constituents: [
                ReferenceConstituent(
                    symbol: "C · H · O",
                    name: "Plant Triglycerides",
                    roleDescription: "Viscous lipid reference class"
                )
            ],
            expectedCentroidHz: 1_580.0,
            expectedPeakHz: 1_420.0,
            expectedMidToHighDB: 9.2,
            expectedDecayDBPerSec: 155.0,
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

/// Persisted consumer-friendly scan item used by Result, Chemical Tune, and History.
public struct ConsumerScanItem: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let scannedAt: Date
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
    public let thumbnailJPEGData: Data?

    public init(
        id: UUID = UUID(),
        scannedAt: Date = Date(),
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
        thumbnailJPEGData: Data? = nil
    ) {
        self.id = id
        self.scannedAt = scannedAt
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
        self.thumbnailJPEGData = thumbnailJPEGData
    }
}
