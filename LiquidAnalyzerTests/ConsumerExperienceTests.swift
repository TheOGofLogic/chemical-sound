import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LiquidAnalyzer

final class ConsumerExperienceTests: XCTestCase {
    func testConsumerPrimaryNavigationContainsOnlyFourSimpleTabs() {
        XCTAssertEqual(ConsumerTab.allCases, [.scan, .history, .learn, .more])
    }

    func testCleanWaterResonanceProducesExperimentalReferenceMatchWithoutFakePurity() {
        let samples = Self.makeWaterResonanceSamples()
        let classifier = OnDeviceAcousticClassifier()
        let result = classifier.classifySamples(
            samples: samples,
            inverseFilter: nil,
            sampleRateHz: 48_000.0,
            preRollFrames: 7_200,
            activeFrames: 9_600
        )

        XCTAssertEqual(result.status, .referenceMatch)
        XCTAssertEqual(result.title, "Water")
        XCTAssertEqual(result.formulaDisplay, "H₂O")
        XCTAssertFalse(result.statusBadgeText.contains("99.9%"))
        XCTAssertTrue(result.statusBadgeText.localizedCaseInsensitiveContains("Experimental"))
        XCTAssertEqual(result.constituents.first?.symbol, "H₂O")
        XCTAssertEqual(result.constituents.first?.name, "Water")
        XCTAssertNotEqual(result.constituents.first?.symbol, "C · H · O")
    }

    func testWallAndSolidSurfaceReturnNonLiquidMaterialNeverDefaultToH2O() throws {
        let samples = Self.makeWaterResonanceSamples()
        let classifier = OnDeviceAcousticClassifier()

        // 1. Painted warm-beige indoor wall with straight phone shadow (exactly like aiming at a wall)
        let wallWithShadowJPEG = try Self.makePlanarWallShadowJPEG(
            wallRGB: (214, 206, 192),
            shadowRGB: (154, 148, 138)
        )
        let wallResult = classifier.classifySamples(
            samples: samples,
            inverseFilter: nil,
            thumbnailJPEGData: wallWithShadowJPEG
        )
        XCTAssertEqual(wallResult.status, .nonLiquidMaterial)
        XCTAssertEqual(wallResult.title, "Solid / Non-Liquid Material")
        XCTAssertNotEqual(wallResult.formulaDisplay, "H₂O")
        XCTAssertTrue(wallResult.constituents.isEmpty)

        // 2. Covered / dark lens also returns Solid / Non-Liquid Material instead of H₂O
        let darkJPEG = try Self.makeSyntheticReticleJPEG(
            outerRGB: (8, 8, 8),
            rimRGB: (8, 8, 8),
            innerRGB: (8, 8, 8)
        )
        let darkResult = classifier.classifySamples(
            samples: samples,
            inverseFilter: nil,
            thumbnailJPEGData: darkJPEG
        )
        XCTAssertEqual(darkResult.status, .nonLiquidMaterial)
        XCTAssertEqual(darkResult.title, "Solid / Non-Liquid Material")
    }

    func testOpaqueColoredMugHoldingWaterOrSaltWaterWorksWithoutSweetenedBeverageBias() throws {
        let classifier = OnDeviceAcousticClassifier()

        // Opaque blue ceramic mug (vivid blue rim) holding clear neutral liquid in center
        let blueMugJPEG = try Self.makeSyntheticReticleJPEG(
            outerRGB: (210, 210, 210),
            rimRGB: (26, 92, 196),
            innerRGB: (186, 190, 194)
        )

        // A) Water inside opaque blue mug -> Water (H₂O), NEVER "Sweetened Beverage"
        let waterInMug = classifier.classifySamples(
            samples: Self.makeWaterResonanceSamples(),
            inverseFilter: nil,
            thumbnailJPEGData: blueMugJPEG
        )
        XCTAssertEqual(waterInMug.status, .referenceMatch)
        XCTAssertEqual(waterInMug.title, "Water")
        XCTAssertEqual(waterInMug.formulaDisplay, "H₂O")
        XCTAssertNotEqual(waterInMug.title, "Sweetened Beverage")

        // B) Salt water inside opaque blue mug -> Salt / Saline Water (H₂O + NaCl)
        let saltWaterSamples = Self.makeSaltWaterResonanceSamples()
        let saltInMug = classifier.classifySamples(
            samples: saltWaterSamples,
            inverseFilter: nil,
            thumbnailJPEGData: blueMugJPEG
        )
        XCTAssertEqual(saltInMug.status, .referenceMatch)
        XCTAssertEqual(saltInMug.title, "Salt / Saline Water")
        XCTAssertEqual(saltInMug.formulaDisplay, "H₂O + NaCl")
    }

    func testHydrogenPeroxideInBowlIdentifiesPeroxideFromHighFrequencyMicroBubbleScatter() throws {
        let classifier = OnDeviceAcousticClassifier()

        // Open ceramic bowl holding clear Hydrogen Peroxide solution
        let bowlJPEG = try Self.makeSyntheticReticleJPEG(
            outerRGB: (218, 214, 206),
            rimRGB: (92, 96, 102),
            innerRGB: (196, 198, 200)
        )
        let peroxideSamples = Self.makeHydrogenPeroxideResonanceSamples()
        let result = classifier.classifySamples(
            samples: peroxideSamples,
            inverseFilter: nil,
            thumbnailJPEGData: bowlJPEG
        )

        XCTAssertEqual(result.status, .referenceMatch)
        XCTAssertEqual(result.title, "Hydrogen Peroxide Solution")
        XCTAssertEqual(result.formulaDisplay, "H₂O + H₂O₂")
        XCTAssertTrue(result.constituents.contains(where: { $0.symbol == "H₂O₂" }))
    }

    func testCalibratedIndirectAcousticInferenceDiscriminatesBlindScansInIdenticalOpaqueBowl() throws {
        let classifier = OnDeviceAcousticClassifier()

        // Identical opaque grey ceramic bowl image used across ALL calibration & blind test scans!
        let identicalOpaqueBowlJPEG = try Self.makeSyntheticReticleJPEG(
            outerRGB: (205, 205, 205),
            rimRGB: (70, 72, 76),
            innerRGB: (182, 184, 186)
        )

        // Subtle container-specific acoustic echoes (all near 1.95 - 2.35 kHz, differing in 6-band scattering shape)
        let calWater = Self.makeMultiBandEcho(f1: 1_960, a2: 0.35, f2: 3_300, a3: 0.10, f3: 6_400, decay: 5.0)
        let calSalt = Self.makeMultiBandEcho(f1: 2_120, a2: 0.92, f2: 3_650, a3: 0.14, f3: 6_500, decay: 4.1)
        let calPeroxide = Self.makeMultiBandEcho(f1: 2_010, a2: 0.42, f2: 3_450, a3: 0.78, f3: 7_200, decay: 6.4)

        let prototypes = [
            CalibratedAcousticPrototype(targetID: "H2O_DIST", features: classifier.extractFeatures(samples: calWater, inverseFilter: nil)),
            CalibratedAcousticPrototype(targetID: "NACL_AQ", features: classifier.extractFeatures(samples: calSalt, inverseFilter: nil)),
            CalibratedAcousticPrototype(targetID: "H2O2_AQ", features: classifier.extractFeatures(samples: calPeroxide, inverseFilter: nil))
        ]

        // Blind test with perturbed/unseen measurements in the exact same opaque bowl
        let blindSalt = Self.makeMultiBandEcho(f1: 2_145, a2: 0.88, f2: 3_690, a3: 0.15, f3: 6_550, decay: 4.3)
        let saltResult = classifier.classifySamples(
            samples: blindSalt,
            inverseFilter: nil,
            thumbnailJPEGData: identicalOpaqueBowlJPEG,
            calibratedPrototypes: prototypes
        )
        XCTAssertEqual(saltResult.status, .referenceMatch)
        XCTAssertEqual(saltResult.title, "Salt / Saline Water")
        XCTAssertTrue(saltResult.statusBadgeText.contains("Calibrated Acoustic Match"))

        let blindPeroxide = Self.makeMultiBandEcho(f1: 2_030, a2: 0.40, f2: 3_490, a3: 0.74, f3: 7_150, decay: 6.2)
        let peroxideResult = classifier.classifySamples(
            samples: blindPeroxide,
            inverseFilter: nil,
            thumbnailJPEGData: identicalOpaqueBowlJPEG,
            calibratedPrototypes: prototypes
        )
        XCTAssertEqual(peroxideResult.status, .referenceMatch)
        XCTAssertEqual(peroxideResult.title, "Hydrogen Peroxide Solution")
        XCTAssertEqual(peroxideResult.formulaDisplay, "H₂O + H₂O₂")
    }

    func testLowFrequencyRoomRumbleNeverForcesEverythingToVegetableOilCHO() {
        let sr = 48_000.0
        let preFrames = 7_200
        let totalFrames = 24_000
        var samples = [Float](repeating: 0.0, count: totalFrames)

        // Heavy 560 Hz room rumble + normal 2.25 kHz aqueous container reflection
        for i in 0..<totalFrames {
            let t = Double(i) / sr
            if i < preFrames {
                samples[i] = Float(0.0004 * sin(2.0 * Double.pi * 180.0 * t))
            } else {
                let dt = Double(i - preFrames) / sr
                let env = exp(-4.8 * dt)
                let rumble = 0.35 * sin(2.0 * Double.pi * 560.0 * dt)
                let waterMode = 0.16 * env * (sin(2.0 * Double.pi * 2_250.0 * dt) + 0.42 * sin(2.0 * Double.pi * 4_300.0 * dt))
                samples[i] = Float(rumble + waterMode)
            }
        }

        let classifier = OnDeviceAcousticClassifier()
        let result = classifier.classifySamples(samples: samples, inverseFilter: nil)
        XCTAssertEqual(result.status, .referenceMatch)
        XCTAssertEqual(result.title, "Water")
        XCTAssertEqual(result.formulaDisplay, "H₂O")
        XCTAssertFalse(result.constituents.contains(where: { $0.symbol.contains("C · H · O") }))
    }

    func testGoldenOilAndPackagedBottleOpticsClassifyCleanly() throws {
        let samples = Self.makeWaterResonanceSamples()
        let classifier = OnDeviceAcousticClassifier()

        // 1. Full-body vivid blue packaged bottle -> Packaged Aqueous Solution
        let blueBottleJPEG = try Self.makeSyntheticReticleJPEG(
            outerRGB: (212, 212, 212),
            rimRGB: (20, 120, 220),
            innerRGB: (24, 128, 226)
        )
        let packagedResult = classifier.classifySamples(samples: samples, inverseFilter: nil, thumbnailJPEGData: blueBottleJPEG)
        XCTAssertEqual(packagedResult.status, .referenceMatch)
        XCTAssertEqual(packagedResult.title, "Packaged Aqueous Solution")

        // 2. High-chroma golden oil inside neutral rim -> Cooking / Vegetable Oil (Triglyceride)
        let goldenOilJPEG = try Self.makeSyntheticReticleJPEG(
            outerRGB: (216, 216, 216),
            rimRGB: (82, 82, 82),
            innerRGB: (232, 192, 32)
        )
        let oilResult = classifier.classifySamples(samples: samples, inverseFilter: nil, thumbnailJPEGData: goldenOilJPEG)
        XCTAssertEqual(oilResult.status, .referenceMatch)
        XCTAssertEqual(oilResult.title, "Cooking / Vegetable Oil")
        XCTAssertEqual(oilResult.formulaDisplay, "Triglyceride")
    }

    func testClippedOrNoisyScanReturnsFriendlyConsumerUnclearScan() {
        var clipped = [Float](repeating: 0.0, count: 24_000)
        for i in 7_200..<7_250 {
            clipped[i] = 0.99
        }

        let classifier = OnDeviceAcousticClassifier()
        let result = classifier.classifySamples(samples: clipped, inverseFilter: nil)
        XCTAssertEqual(result.status, .unclearScan)
        XCTAssertEqual(result.title, "Scan Unclear")
        XCTAssertFalse(result.scientificNote.contains("SIG_ESS"))
        XCTAssertFalse(result.scientificNote.contains("AVAudioSession"))
    }

    func testOutOfEnvelopeResonanceReturnsUnmatchedSignatureNeverDefaultsToH2O() throws {
        let sr = 48_000.0
        var samples = [Float](repeating: 0.0002, count: 24_000)
        for i in 7_200..<20_000 {
            let dt = Double(i - 7_200) / sr
            samples[i] = Float(0.16 * sin(2.0 * Double.pi * 9_400.0 * dt))
        }

        let cupJPEG = try Self.makeSyntheticReticleJPEG(
            outerRGB: (215, 215, 215),
            rimRGB: (80, 84, 90),
            innerRGB: (190, 194, 198)
        )

        let classifier = OnDeviceAcousticClassifier()
        let result = classifier.classifySamples(samples: samples, inverseFilter: nil, thumbnailJPEGData: cupJPEG)
        XCTAssertEqual(result.status, .unmatchedSignature)
        XCTAssertEqual(result.title, "Unmatched Liquid")
        XCTAssertNotEqual(result.formulaDisplay, "H₂O")
        XCTAssertFalse(result.tuneProfile.baseFrequenciesHz.isEmpty)
    }

    func testChemicalTuneSynthesizerGeneratesCleanBounded48kHzWAV() throws {
        let waterProfile = ReferenceLiquidProfile.provisionalLibrary[0]
        let item = ConsumerScanItem(
            status: .referenceMatch,
            title: waterProfile.displayName,
            formulaDisplay: waterProfile.formulaDisplay,
            statusBadgeText: "Experimental Reference Match • 85% Similarity",
            confidencePercent: 85,
            scientificNote: "Experimental research estimate.",
            constituents: waterProfile.constituents,
            tuneProfile: waterProfile.tuneProfile,
            measuredPeakHz: 2_220.0,
            measuredCentroidHz: 2_560.0,
            measuredDecayDBPerSec: 76.0
        )

        let synth = ChemicalTuneSynthesizer(sampleRateHz: 48_000.0, durationSeconds: 2.0)
        let samples = synth.synthesizeSamples(for: item)
        XCTAssertEqual(samples.count, 96_000)
        XCTAssertTrue(samples.allSatisfy(\.isFinite))

        let peak = samples.map { abs($0) }.max() ?? 0.0
        XCTAssertGreaterThan(peak, 0.50)
        XCTAssertLessThanOrEqual(peak, 0.75) // Bounded cleanly near -3 dBFS
        XCTAssertEqual(samples.first ?? 1.0, 0.0, accuracy: 1e-4) // Zero-click fade-in start

        let wavURL = try synth.writeTemporaryWAV(for: item)
        defer { try? FileManager.default.removeItem(at: wavURL) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: wavURL.path))
    }

    func testConsumerHistoryStorePersistsAndReloadsItems() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LA_Hist_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = ConsumerHistoryStore(fileURL: tempDir.appendingPathComponent("history.json"))
        let prof = ReferenceLiquidProfile.provisionalLibrary[0]
        let item = ConsumerScanItem(
            status: .referenceMatch,
            title: prof.displayName,
            formulaDisplay: prof.formulaDisplay,
            statusBadgeText: "Experimental Reference Match • 84% Similarity",
            confidencePercent: 84,
            scientificNote: "Experimental reference match.",
            constituents: prof.constituents,
            tuneProfile: prof.tuneProfile,
            measuredPeakHz: 2_220.0,
            measuredCentroidHz: 2_560.0,
            measuredDecayDBPerSec: 76.0
        )

        store.saveAll([item])
        let loaded = store.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.title, "Water")
        XCTAssertEqual(loaded.first?.formulaDisplay, "H₂O")
    }

    // MARK: - Helpers

    private static func makeWaterResonanceSamples() -> [Float] {
        let sr = 48_000.0
        let preFrames = 7_200
        let totalFrames = 24_000
        var samples = [Float](repeating: 0.0, count: totalFrames)
        for i in 0..<totalFrames {
            let t = Double(i) / sr
            if i < preFrames {
                samples[i] = Float(0.00035 * sin(2.0 * Double.pi * 240.0 * t))
            } else {
                let dt = Double(i - preFrames) / sr
                let env = exp(-4.2 * dt)
                let primary = sin(2.0 * Double.pi * 2_150.0 * dt)
                let upper = 0.45 * sin(2.0 * Double.pi * 4_200.0 * dt)
                samples[i] = Float(0.18 * env * (primary + upper))
            }
        }
        return samples
    }

    private static func makeSaltWaterResonanceSamples() -> [Float] {
        let sr = 48_000.0
        let preFrames = 7_200
        let totalFrames = 24_000
        var samples = [Float](repeating: 0.0, count: totalFrames)
        for i in 0..<totalFrames {
            let t = Double(i) / sr
            if i < preFrames {
                samples[i] = Float(0.00035 * sin(2.0 * Double.pi * 220.0 * t))
            } else {
                let dt = Double(i - preFrames) / sr
                let env = exp(-3.5 * dt)
                let primary = sin(2.0 * Double.pi * 2_820.0 * dt)
                let upper = 0.78 * sin(2.0 * Double.pi * 4_550.0 * dt)
                samples[i] = Float(0.17 * env * (primary + upper))
            }
        }
        return samples
    }

    private static func makeHydrogenPeroxideResonanceSamples() -> [Float] {
        let sr = 48_000.0
        let preFrames = 7_200
        let totalFrames = 24_000
        var samples = [Float](repeating: 0.0, count: totalFrames)
        for i in 0..<totalFrames {
            let t = Double(i) / sr
            if i < preFrames {
                // Subtle high-frequency micro-bubble fizz during pre-roll (~ -60 dBFS at 7.6 kHz)
                samples[i] = Float(0.0009 * sin(2.0 * Double.pi * 7_600.0 * t))
            } else {
                let dt = Double(i - preFrames) / sr
                let env = exp(-9.5 * dt)
                let primary = sin(2.0 * Double.pi * 2_480.0 * dt)
                let midUpper = 0.60 * sin(2.0 * Double.pi * 4_050.0 * dt)
                let bubbleScatter = 0.62 * sin(2.0 * Double.pi * 7_400.0 * dt)
                samples[i] = Float(0.18 * env * (primary + midUpper + bubbleScatter))
            }
        }
        return samples
    }

    private static func makeMultiBandEcho(
        f1: Double,
        a2: Double,
        f2: Double,
        a3: Double,
        f3: Double,
        decay: Double
    ) -> [Float] {
        let sr = 48_000.0
        let preFrames = 7_200
        let totalFrames = 24_000
        var samples = [Float](repeating: 0.0, count: totalFrames)
        for i in 0..<totalFrames {
            let t = Double(i) / sr
            if i < preFrames {
                samples[i] = Float(0.0003 * sin(2.0 * Double.pi * 210.0 * t))
            } else {
                let dt = Double(i - preFrames) / sr
                let env = exp(-decay * dt)
                let s = sin(2.0 * Double.pi * f1 * dt)
                    + a2 * sin(2.0 * Double.pi * f2 * dt)
                    + a3 * sin(2.0 * Double.pi * f3 * dt)
                samples[i] = Float(0.16 * env * s)
            }
        }
        return samples
    }

    private static func makePlanarWallShadowJPEG(
        wallRGB: (UInt8, UInt8, UInt8),
        shadowRGB: (UInt8, UInt8, UInt8)
    ) throws -> Data {
        let size = 96
        var rgba = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let inPhoneShadow = (y >= 54 && x >= 34)
                let c = inPhoneShadow ? shadowRGB : wallRGB
                let idx = (y * size + x) * 4
                rgba[idx] = c.0
                rgba[idx + 1] = c.1
                rgba[idx + 2] = c.2
                rgba[idx + 3] = 255
            }
        }
        return try encodeRGBA(rgba, size: size)
    }

    private static func makeSyntheticReticleJPEG(
        outerRGB: (UInt8, UInt8, UInt8),
        rimRGB: (UInt8, UInt8, UInt8),
        innerRGB: (UInt8, UInt8, UInt8)
    ) throws -> Data {
        let size = 96
        var rgba = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let dx = (Double(x) - 47.5) / 48.0
                let dy = (Double(y) - 47.5) / 48.0
                let r = sqrt(dx * dx + dy * dy)
                let c: (UInt8, UInt8, UInt8)
                if r <= 0.34 {
                    c = innerRGB
                } else if r <= 0.58 {
                    c = rimRGB
                } else {
                    c = outerRGB
                }
                let idx = (y * size + x) * 4
                rgba[idx] = c.0
                rgba[idx + 1] = c.1
                rgba[idx + 2] = c.2
                rgba[idx + 3] = 255
            }
        }
        return try encodeRGBA(rgba, size: size)
    }

    private static func encodeRGBA(_ rgba: [UInt8], size: Int) throws -> Data {
        var mutableRGBA = rgba
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &mutableRGBA,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImg = ctx.makeImage() else {
            throw NSError(domain: "ConsumerExperienceTests", code: 1)
        }

        let mutableData = CFDataCreateMutable(nil, 0)!
        guard let dest = CGImageDestinationCreateWithData(
            mutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "ConsumerExperienceTests", code: 2)
        }
        CGImageDestinationAddImage(dest, cgImg, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "ConsumerExperienceTests", code: 3)
        }
        return mutableData as Data
    }
}
