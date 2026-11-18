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
            expectedCentroidHz: 2_520.0,
            expectedPeakHz: 2_180.0,
            expectedMidToHighDB: 4.2,
            expectedDecayDBPerSec: 74.0,
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
            displayName: "Saline / Electrolyte Water",
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
                    roleDescription: "Dissolved electrolyte reference constituent"
                )
            ],
            expectedCentroidHz: 3_180.0,
            expectedPeakHz: 2_820.0,
            expectedMidToHighDB: 1.2,
            expectedDecayDBPerSec: 88.0,
            tuneProfile: ChemicalTuneProfile(
                formulaDisplay: "H₂O + NaCl",
                mappingSummary: "Mapped musical representation combining water harmonics with bright ionic fifth and ninth intervals.",
                baseFrequenciesHz: [392.00, 587.33, 659.25, 739.99, 987.77], // G4, D5, E5, F#5, B5
                shimmerMultiplier: 1.22,
                warmthDecayPerSec: 1.65
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
            expectedCentroidHz: 2_920.0,
            expectedPeakHz: 2_580.0,
            expectedMidToHighDB: 2.4,
            expectedDecayDBPerSec: 96.0,
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
            expectedCentroidHz: 2_140.0,
            expectedPeakHz: 1_840.0,
            expectedMidToHighDB: 5.4,
            expectedDecayDBPerSec: 108.0,
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
            expectedCentroidHz: 2_260.0,
            expectedPeakHz: 1_960.0,
            expectedMidToHighDB: 4.8,
            expectedDecayDBPerSec: 112.0,
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
            expectedPeakHz: 2_320.0,
            expectedMidToHighDB: 3.1,
            expectedDecayDBPerSec: 94.0,
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
            expectedCentroidHz: 2_420.0,
            expectedPeakHz: 2_080.0,
            expectedMidToHighDB: 3.9,
            expectedDecayDBPerSec: 102.0,
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
            expectedCentroidHz: 2_840.0,
            expectedPeakHz: 2_460.0,
            expectedMidToHighDB: 2.2,
            expectedDecayDBPerSec: 98.0,
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
            expectedCentroidHz: 3_480.0,
            expectedPeakHz: 3_150.0,
            expectedMidToHighDB: -0.6,
            expectedDecayDBPerSec: 80.0,
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
            expectedCentroidHz: 1_880.0,
            expectedPeakHz: 1_580.0,
            expectedMidToHighDB: 6.4,
            expectedDecayDBPerSec: 128.0,
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
