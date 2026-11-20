import AVFAudio
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

    func testRepeatabilityGateR1HoldsBackAmbiguousMatchesAndLogsCompleteRawTelemetry() throws {
        // Multi-mode container echo (1.62 kHz + 5.6 kHz + 7.8 kHz) whose distance (~1.2) sits in the weak/ambiguous zone
        let ambiguousSamples = Self.makeMultiBandEcho(
            f1: 1_620.0,
            a2: 0.90,
            f2: 5_600.0,
            a3: 0.35,
            f3: 7_800.0,
            decay: 7.0
        )
        let cupJPEG = try Self.makeSyntheticReticleJPEG(
            outerRGB: (215, 215, 215),
            rimRGB: (80, 84, 90),
            innerRGB: (190, 194, 198)
        )

        let classifier = OnDeviceAcousticClassifier()
        let r1 = classifier.classifySamples(
            samples: ambiguousSamples,
            inverseFilter: nil,
            scanSequenceNumber: 7,
            thumbnailJPEGData: cupJPEG
        )
        let r2 = classifier.classifySamples(
            samples: ambiguousSamples,
            inverseFilter: nil,
            scanSequenceNumber: 8,
            thumbnailJPEGData: cupJPEG
        )

        // Stringent Ambiguity Gate R1 must hold back weak/close matches as Unmatched rather than guessing random chemicals
        XCTAssertEqual(r1.status, .unmatchedSignature)
        XCTAssertEqual(r1.title, "Unmatched Liquid")
        XCTAssertEqual(r1.scanSequenceNumber, 7)

        // All raw Repeatability Gate R1 telemetry must be populated and repeatable
        XCTAssertEqual(r1.measuredPeakHz, 1_620.0, accuracy: 18.0)
        XCTAssertEqual(r1.measuredFeatures?.featureVectorChecksum, r2.measuredFeatures?.featureVectorChecksum)
        XCTAssertFalse(r1.measuredFeatures?.secondaryPeaksHz.isEmpty ?? true)
        XCTAssertNotNil(r1.topCandidateName)
        XCTAssertNotNil(r1.topCandidateDistance)
        XCTAssertNotNil(r1.runnerUpTitle)
        XCTAssertNotNil(r1.secondCandidateDistance)
        XCTAssertNotNil(r1.winningMargin)
        XCTAssertEqual(r1.allCandidateDistances?.count, ReferenceLiquidProfile.provisionalLibrary.count)
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

    func testDeconvolved20xRepeatabilityUnder15InchWeakEchoAndTimingJitter() throws {
        let (ess, inv) = try Self.loadBundledESSAndInverse()
        let classifier = OnDeviceAcousticClassifier()
        let cupJPEG = try Self.makeSyntheticReticleJPEG(
            outerRGB: (215, 215, 215),
            rimRGB: (80, 84, 90),
            innerRGB: (190, 194, 198)
        )

        var prngState: UInt64 = 0x9E37_79B9_7F4A_7C15
        var batchItems: [ConsumerScanItem] = []

        for idx in 1...20 {
            let jitter = Int(Self.nextGaussian(&prngState) * 1_100.0) // +/- ~23 ms timing jitter
            let rec = Self.makeDeconvolvedChannelRecording(
                ess: ess,
                distanceInches: 15.0,
                modes: [(2_315.0, 0.00035, 0.0032), (4_660.0, 0.00024, 0.0024), (6_684.0, 0.00021, 0.0020)],
                noiseRMS: 0.0024,
                onsetJitterSamples: jitter,
                injectStartupTransient: true,
                prng: &prngState
            )
            let item = classifier.classifySamples(
                samples: rec,
                inverseFilter: inv,
                sampleRateHz: 48_000.0,
                preRollFrames: 7_200,
                activeFrames: 9_600,
                scanSequenceNumber: idx,
                batchRunID: "R1_20X_TEST",
                batchScanIndex: idx,
                batchTotalCount: 20,
                geometryCondition: GeometryTestCondition.stationary15InBaseline.rawValue,
                controlSeriesTag: ControlSeriesTag.unlabeledBlind.rawValue,
                aeAfWbLockState: "LOCKED",
                targetLockState: "R1_STATIONARY_LOCKED",
                targetLockScore: 1.0,
                thumbnailJPEGData: cupJPEG,
                opticsLocked: true
            )
            batchItems.append(item)
        }

        XCTAssertEqual(batchItems.count, 20)
        for item in batchItems {
            XCTAssertNotEqual(item.status, .unclearScan)
            // Every single scan in the 20x series must stay in the ~2315 Hz fundamental without jumping to 4.66 or 6.68 kHz
            XCTAssertEqual(item.measuredPeakHz, 2_315.0, accuracy: 25.0)
            XCTAssertNotNil(item.measuredFeatures?.primaryPeakAmplitudeDB)
            XCTAssertNotNil(item.gateDecision)
        }

        let report = RepeatabilityPeakStabilityAnalyzer.analyze(items: batchItems)
        XCTAssertEqual(report.validQualityAcquisitions, 20)
        XCTAssertEqual(report.stabilityDisposition, "REPEATABLE_PERSISTENT_MODE")
        XCTAssertLessThan(report.primaryPeakSDHz, 12.0)
        XCTAssertFalse(report.persistentBands.isEmpty)
        XCTAssertFalse(report.harmonicOrSubharmonicBands.isEmpty)
    }

    func testDeconvolvedPipelineHasZeroHardcodedLowFrequencyBiasWhenTrueModeIsHighFrequency() throws {
        let (ess, inv) = try Self.loadBundledESSAndInverse()
        let classifier = OnDeviceAcousticClassifier()
        let cupJPEG = try Self.makeSyntheticReticleJPEG(
            outerRGB: (215, 215, 215),
            rimRGB: (80, 84, 90),
            innerRGB: (190, 194, 198)
        )

        var prngState: UInt64 = 0xA5A5_5A5A_1234_5678
        for idx in 1...5 {
            let rec = Self.makeDeconvolvedChannelRecording(
                ess: ess,
                distanceInches: 15.0,
                modes: [(6_150.0, 0.00048, 0.0030)],
                noiseRMS: 0.0018,
                onsetJitterSamples: 350,
                injectStartupTransient: false,
                prng: &prngState
            )
            let item = classifier.classifySamples(
                samples: rec,
                inverseFilter: inv,
                scanSequenceNumber: idx,
                thumbnailJPEGData: cupJPEG
            )
            // True 6.15 kHz mode is preserved faithfully AND held back by Ambiguity Gate R1 as Unmatched Liquid
            XCTAssertEqual(item.measuredPeakHz, 6_150.0, accuracy: 30.0)
            XCTAssertEqual(item.status, .unmatchedSignature)
            XCTAssertEqual(item.title, "Unmatched Liquid")
            XCTAssertNotNil(item.rejectionReason)
        }
    }

    func testNoisyBuriedEchoIsFlaggedUnclearAndRetainedInPeakStabilityReport() throws {
        let (ess, inv) = try Self.loadBundledESSAndInverse()
        let classifier = OnDeviceAcousticClassifier()
        let cupJPEG = try Self.makeSyntheticReticleJPEG(
            outerRGB: (215, 215, 215),
            rimRGB: (80, 84, 90),
            innerRGB: (190, 194, 198)
        )

        var prngState: UInt64 = 0xDEAD_BEEF_CAFE_BABE
        let buriedRec = Self.makeDeconvolvedChannelRecording(
            ess: ess,
            distanceInches: 15.0,
            modes: [], // Zero container reflection -> tail SNR ~ 0 dB
            noiseRMS: 0.0065,
            onsetJitterSamples: 0,
            injectStartupTransient: false,
            prng: &prngState
        )
        let noisyItem = classifier.classifySamples(
            samples: buriedRec,
            inverseFilter: inv,
            scanSequenceNumber: 99,
            thumbnailJPEGData: cupJPEG
        )

        XCTAssertEqual(noisyItem.status, .unclearScan)
        XCTAssertEqual(noisyItem.gateDecision, "REJECTED_SIGNAL_QUALITY")
        XCTAssertNotNil(noisyItem.rejectionReason)
        XCTAssertNotNil(noisyItem.measuredFeatures)

        let report = RepeatabilityPeakStabilityAnalyzer.analyze(items: [noisyItem])
        XCTAssertEqual(report.totalAcquisitions, 1)
        XCTAssertEqual(report.validQualityAcquisitions, 0)
        XCTAssertEqual(report.lowConfidenceNoisyScans.count, 1)
    }

    func testCapturedSampleStoreFIFOSegmentsAndLosslessWAVArchival() throws {
        let store = CapturedSampleStore()
        store.reset()
        store.append([0.1, 0.2, 0.3]) // pre-segment warm idle samples

        try store.openSegment()
        XCTAssertThrowsError(try store.openSegment())
        store.append([0.25, -0.5, 0.75, -0.25])
        let seg1 = try store.closeSegment()
        XCTAssertEqual(seg1, [0.25, -0.5, 0.75, -0.25])
        XCTAssertThrowsError(try store.closeSegment())

        store.append([0.0, 0.0]) // inter-sweep quiet gap
        try store.openSegment()
        store.append([0.5, -0.5])
        let seg2 = try store.closeSegment()
        XCTAssertEqual(seg2, [0.5, -0.5])
        XCTAssertEqual(store.count(), 11)

        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WarmStore_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wavURL) }
        try WarmBatchAudioEngine.writeLosslessMonoWAV(samples: seg1, sampleRateHz: 48_000.0, to: wavURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: wavURL.path))
    }

    func testSpeakerPortHelmholtzBleedAt3820HzDoesNotSwitch15InchPrimaryPeak() throws {
        let (ess, inv) = try Self.loadBundledESSAndInverse()
        let classifier = OnDeviceAcousticClassifier()
        let cupJPEG = try Self.makeSyntheticReticleJPEG(
            outerRGB: (215, 215, 215),
            rimRGB: (80, 84, 90),
            innerRGB: (190, 194, 198)
        )

        var prngState: UInt64 = 0x1357_9BDF_2468_ACE0
        for idx in 1...12 {
            let rec = Self.makeDeconvolvedChannelRecording(
                ess: ess,
                distanceInches: 15.0,
                modes: [(2_460.0, 0.00042, 0.0034)],
                noiseRMS: 0.0028,
                onsetJitterSamples: (idx - 6) * 140,
                injectStartupTransient: true,
                injectSpeakerPortBleed3820Hz: true,
                prng: &prngState
            )
            let item = classifier.classifySamples(
                samples: rec,
                inverseFilter: inv,
                scanSequenceNumber: idx,
                thumbnailJPEGData: cupJPEG
            )
            XCTAssertNotEqual(item.status, .unclearScan)
            // Must reject the 3820 Hz internal speaker-port/case Helmholtz ring-down and stay locked on 2460 Hz
            XCTAssertEqual(item.measuredPeakHz, 2_460.0, accuracy: 28.0)
        }
    }

    @MainActor
    func testUnlockedR1CSVExportWritesToDocumentsAndMatchesText() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LA_CSV_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let histStore = ConsumerHistoryStore(fileURL: tempDir.appendingPathComponent("history.json"))
        let protoStore = CalibratedPrototypeStore(fileURL: tempDir.appendingPathComponent("protos.json"))
        let prof = ReferenceLiquidProfile.provisionalLibrary[0]
        let sampleItem = ConsumerScanItem(
            scanSequenceNumber: 1,
            batchRunID: "R1_20X_20261118_160000",
            batchScanIndex: 1,
            batchTotalCount: 20,
            geometryCondition: GeometryTestCondition.stationary15InBaseline.rawValue,
            controlSeriesTag: ControlSeriesTag.water.rawValue,
            aeAfWbLockState: "LOCKED",
            targetLockState: "R1_STATIONARY_LOCKED",
            targetLockScore: 1.0,
            gateDecision: "HELD_AMBIGUITY_GATE",
            rejectionReason: "AMBIGUITY_MARGIN(m=0.07<0.11)",
            status: .unmatchedSignature,
            title: "Unmatched Liquid",
            formulaDisplay: "Acoustic Profile",
            statusBadgeText: "Ambiguity Gate R1 • No Forced Match",
            confidencePercent: nil,
            scientificNote: "Held back.",
            constituents: [],
            tuneProfile: prof.tuneProfile,
            measuredPeakHz: 2_314.5,
            measuredCentroidHz: 3_390.2,
            measuredDecayDBPerSec: 84.0
        )
        histStore.saveAll([sampleItem])

        let logger = AuditLogger(logFileURL: tempDir.appendingPathComponent("audit.jsonl"))
        let machine = AcquisitionStateMachine(auditLogger: logger)
        let acq = AcquisitionCoordinator(stateMachine: machine, auditLogger: logger)
        let coord = ConsumerScanCoordinator(
            researchCoordinator: acq,
            historyStore: histStore,
            prototypeStore: protoStore
        )

        let sanitized = ConsumerScanCoordinator.sanitizedCSVFilename(suffix: "BATCH_R1_20X_20261118 (15-in)")
        XCTAssertEqual(sanitized, "LiquidAnalyzer_R1_BATCH_R1_20X_20261118_15-in.csv")

        let csvText = coord.exportRepeatabilityCSVText(items: [sampleItem])
        XCTAssertTrue(csvText.contains("scan_num,batch_run_id,batch_index"))
        XCTAssertTrue(csvText.contains("STATIONARY_15IN_BASELINE"))
        XCTAssertTrue(csvText.contains("2314.50"))

        let exportedURL = try XCTUnwrap(
            coord.exportRepeatabilityCSVURL(items: [sampleItem], filenameSuffix: "BATCH_R1_20X_TEST")
        )
        defer { try? FileManager.default.removeItem(at: exportedURL) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportedURL.path))
        XCTAssertTrue(exportedURL.path.contains("R1_Exports"))
        let diskText = try String(contentsOf: exportedURL, encoding: .utf8)
        XCTAssertEqual(diskText, csvText)

        let copiedRows = coord.copyRepeatabilityCSVToClipboard(items: [sampleItem])
        XCTAssertEqual(copiedRows, 1)
    }

    func testR2B_WarmBatchAudioEngineEnforcesKCond2And900msInterSweepSettleAndLatePreRollRouting() {
        XCTAssertEqual(WarmBatchAudioEngine.calibrationConditioningPurgeCount, 2)
        XCTAssertEqual(WarmBatchAudioEngine.minimumInterSweepSettleMs, 900)
        XCTAssertEqual(WarmBatchAudioEngine.resolvedInterSweepSettleMs(requestedMs: 650), 900)
        XCTAssertEqual(WarmBatchAudioEngine.resolvedInterSweepSettleMs(requestedMs: 1_100), 1_100)

        // K_cond = 2 marks Sweeps 1 and 2 as conditioning purge on 20x calibration bursts, leaving single scans unpurged
        XCTAssertFalse(WarmBatchAudioEngine.isConditioningSweep(batchIndex: 1, batchTotalCount: 1))
        XCTAssertTrue(WarmBatchAudioEngine.isConditioningSweep(batchIndex: 1, batchTotalCount: 20))
        XCTAssertTrue(WarmBatchAudioEngine.isConditioningSweep(batchIndex: 2, batchTotalCount: 20))
        XCTAssertFalse(WarmBatchAudioEngine.isConditioningSweep(batchIndex: 3, batchTotalCount: 20))

        // Simulate Sweep 2 with heavy early pre-roll ring-down bleed in [0..3,000] and clean silence in late pre-roll
        var buffer = [Float](repeating: 0.0002, count: 28_800)
        for i in 0..<3_000 {
            buffer[i] = 0.08 * Float(sin(Double(i) * 0.35))
        }
        let lateSlice = WarmBatchAudioEngine.extractLatePreRollSilenceSlice(
            from: buffer,
            nominalPreRollFrames: 9_600,
            alignedExcitationStart: 14_000,
            sampleRateHz: 48_000.0
        )
        XCTAssertGreaterThan(lateSlice.count, 3_000)
        let maxLateAbs = lateSlice.map { abs($0) }.max() ?? 1.0
        XCTAssertLessThan(maxLateAbs, 0.001) // Completely excludes the 0.08 early bleed!
    }

    func testR2B_SchroederEDCUnclampedDecayEliminates145CeilingAnd4ModeMaskEmitsNaNForMissingModes() throws {
        let (ess, inv) = try Self.loadBundledESSAndInverse()
        let classifier = OnDeviceAcousticClassifier()
        var prng: UInt64 = 0x5232_4230_0001_ABCD

        // Synthesize a 2-mode deconvolved container echo (2,200 Hz + 3,600 Hz) with rapid physical decay (tau = 2.8 ms -> alpha ~ 357 s^-1 ~ 3,100 dB/s)
        let rec = Self.makeDeconvolvedChannelRecording(
            ess: ess,
            distanceInches: 15.0,
            modes: [(2_200.0, 0.00055, 0.0028), (3_600.0, 0.00048, 0.0028)],
            noiseRMS: 0.0012,
            onsetJitterSamples: 0,
            injectStartupTransient: false,
            prng: &prng
        )
        let feat = classifier.extractFeatures(
            samples: rec,
            inverseFilter: inv,
            sampleRateHz: 48_000.0,
            preRollFrames: 7_200,
            activeFrames: 9_600
        )

        // 1. Hardcoded 145.0 dB/s clamp is gone: Schroeder EDC recovers rapid decay >> 145.0 dB/s
        XCTAssertGreaterThan(feat.decaySlopeDBPerSec, 200.0)
        XCTAssertGreaterThan(abs(feat.decaySlopeDBPerSec - 145.0), 0.5)

        // 2. 4-Mode Vector recovers the 2 physical modes and sets mask = 0, f = NaN on absent slots 3 & 4 (no zero-padding!)
        let mv = try XCTUnwrap(feat.modalVector)
        XCTAssertEqual(mv.validityMask[0], 1)
        XCTAssertEqual(mv.validityMask[1], 1)
        XCTAssertEqual(mv.validityMask[2], 0)
        XCTAssertEqual(mv.validityMask[3], 0)
        let nanVec = mv.frequenciesWithNaN
        XCTAssertEqual(nanVec[0], 2_200.0, accuracy: 30.0)
        XCTAssertEqual(nanVec[1], 3_600.0, accuracy: 30.0)
        XCTAssertTrue(nanVec[2].isNaN)
        XCTAssertTrue(nanVec[3].isNaN)
    }

    func testR2B_BubbleScatterScreeningAndDifferentialBaselineShiftsWorkWithoutCookingOilViscosityClaims() throws {
        // Verify zero ungrounded airborne viscosity claims remain on Cooking / Vegetable Oil profile
        let oilProfile = try XCTUnwrap(ReferenceLiquidProfile.provisionalLibrary.first { $0.id == "OIL_VEG" })
        XCTAssertFalse(oilProfile.categorySummary.localizedCaseInsensitiveContains("viscous"))
        XCTAssertFalse(oilProfile.tuneProfile.mappingSummary.localizedCaseInsensitiveContains("damped"))

        // Verify DifferentialBaselineVector computes exact relative frequency shifts on valid slots & rejects geometry mismatch
        let emptyMV = ModalVector4(
            frequenciesHz: [2_250.0, 4_280.0, nil, nil],
            validityMask: [1, 1, 0, 0],
            qualityFactorsQ: [23.0, 37.0, nil, nil],
            qValidityMask: [1, 1, 0, 0],
            decayAlphaPerSec: [85.0, 101.0, nil, nil],
            decayDBPerSec: [738.0, 877.0, nil, nil],
            decayRSquared: [0.82, 0.79, nil, nil],
            decayValidityMask: [1, 1, 0, 0],
            spectralAttenuationSlopeDBPerKHz: -1.33,
            bubbleScatter55to85DB: -5.52
        )
        let loadedMV = ModalVector4(
            frequenciesHz: [2_160.0, 4_194.4, nil, nil], // -4.0% and -2.0% mass-loading shifts
            validityMask: [1, 1, 0, 0],
            qualityFactorsQ: [21.0, 26.0, nil, nil],
            qValidityMask: [1, 1, 0, 0],
            decayAlphaPerSec: [93.0, 60.0, nil, nil],
            decayDBPerSec: [808.0, 521.0, nil, nil],
            decayRSquared: [0.86, 0.78, nil, nil],
            decayValidityMask: [1, 1, 0, 0],
            spectralAttenuationSlopeDBPerKHz: -0.05,
            bubbleScatter55to85DB: -7.90
        )

        let shiftOK = DifferentialBaselineVector.compute(
            sample: loadedMV,
            sampleGeometry: GeometryTestCondition.stationary15InBaseline.rawValue,
            reference: emptyMV,
            referenceTargetID: CalibratedAcousticPrototype.emptyContainerTargetID,
            referenceGeometry: GeometryTestCondition.stationary15InBaseline.rawValue
        )
        XCTAssertTrue(shiftOK.compatible)
        XCTAssertEqual(shiftOK.shiftMask, [1, 1, 0, 0])
        XCTAssertEqual(shiftOK.relativeFrequencyShifts[0] ?? 0.0, -0.04, accuracy: 1e-5)
        XCTAssertEqual(shiftOK.relativeFrequencyShifts[1] ?? 0.0, -0.02, accuracy: 1e-5)
        XCTAssertNil(shiftOK.relativeFrequencyShifts[2])

        let shiftMismatch = DifferentialBaselineVector.compute(
            sample: loadedMV,
            sampleGeometry: GeometryTestCondition.closeRangeSub8In.rawValue,
            reference: emptyMV,
            referenceTargetID: CalibratedAcousticPrototype.emptyContainerTargetID,
            referenceGeometry: GeometryTestCondition.stationary15InBaseline.rawValue
        )
        XCTAssertFalse(shiftMismatch.compatible)
        XCTAssertEqual(shiftMismatch.rejectionCode, "REJECTED_BASELINE_MISMATCH_GEOMETRY")
    }

    func testR2C_BatchSteadyStateBaselinePurgesKCond2AndReconcilesDifferentialShifts() throws {
        let geom = GeometryTestCondition.stationary15InBaseline.rawValue
        let tune = ChemicalTuneProfile(
            formulaDisplay: "Mode A",
            mappingSummary: "Test",
            baseFrequenciesHz: [261.63, 329.63, 392.0]
        )

        // Build 20x Empty Glass cohort where Sweeps 1..2 have transient outliers (1440 Hz) and Sweeps 3..20 are steady (2130 Hz)
        var emptyBatch: [ConsumerScanItem] = []
        for idx in 1...20 {
            let isCond = idx <= 2
            let f1 = isCond ? 1_440.0 : 2_130.0
            let mv = ModalVector4(
                frequenciesHz: [f1, 2_516.0, 2_846.0, 3_310.0],
                validityMask: [1, 1, 1, 1],
                qualityFactorsQ: [12.0, 13.0, 10.3, 30.0],
                qValidityMask: [1, 1, 1, 1],
                decayAlphaPerSec: [75.5, 90.7, 49.0, 56.1],
                decayDBPerSec: [655.0, 788.0, 425.0, 487.0],
                decayRSquared: [0.88, 0.85, 0.90, 0.86],
                decayValidityMask: [1, 1, 1, 1],
                spectralAttenuationSlopeDBPerKHz: 1.94,
                bubbleScatter55to85DB: -9.8
            )
            let feat = ExtractedConsumerFeatures(
                activeSNRDB: 32.0,
                peakDBFS: -26.1,
                clippedSamples: 0,
                dominantPeakHz: isCond ? 1_440.0 : 2_529.0,
                spectralCentroidHz: 3_775.0,
                midToHighBandDB: 3.1,
                decaySlopeDBPerSec: isCond ? 8_500.0 : 797.0,
                highFreqBubbleScatterDB: -9.8,
                subBandShapeDB: [0.4, 6.8, 2.1, 0.2, -3.9, -5.6],
                echoReturnDB: -36.7,
                tailSNRDB: 17.2,
                preRollExcessHFDB: -4.5,
                modalVector: mv
            )
            emptyBatch.append(
                ConsumerScanItem(
                    scanSequenceNumber: idx,
                    batchRunID: "R1_20X_EMPTY",
                    batchScanIndex: idx,
                    batchTotalCount: 20,
                    geometryCondition: geom,
                    status: .unmatchedSignature,
                    title: "Unmatched Liquid",
                    formulaDisplay: "NO_VALIDATED_MATCH",
                    statusBadgeText: "Ambiguity Gate R2",
                    confidencePercent: nil,
                    scientificNote: "Uncalibrated",
                    constituents: [],
                    tuneProfile: tune,
                    measuredPeakHz: feat.dominantPeakHz,
                    measuredCentroidHz: feat.spectralCentroidHz,
                    measuredDecayDBPerSec: feat.decaySlopeDBPerSec,
                    measuredFeatures: feat,
                    isConditioningCycle: isCond
                )
            )
        }

        let aggEmpty = try XCTUnwrap(
            BatchSteadyStateFeatureAggregator.aggregate(
                items: emptyBatch,
                targetID: CalibratedAcousticPrototype.emptyContainerTargetID
            )
        )
        XCTAssertEqual(aggEmpty.steadyStateSweepCount, 18) // Strictly purged K_cond = 2 sweeps!
        XCTAssertEqual(aggEmpty.features.dominantPeakHz, 2_529.0, accuracy: 0.1)
        XCTAssertEqual(aggEmpty.features.modalVector?.frequenciesHz[0] ?? 0.0, 2_130.0, accuracy: 0.1)

        let emptyProto = CalibratedAcousticPrototype(
            targetID: CalibratedAcousticPrototype.emptyContainerTargetID,
            features: aggEmpty.features,
            geometryCondition: geom,
            sourceBatchRunID: aggEmpty.batchRunID,
            steadyStateSweepCount: aggEmpty.steadyStateSweepCount
        )

        // Now evaluate an uncalibrated Vinegar/loaded scan ([1724.4, 2155.1, 2494.9, 2892.3] Hz -> ~-19%..-12% shift vs Empty)
        let loadedMV = ModalVector4(
            frequenciesHz: [1_724.4, 2_155.1, 2_494.9, 2_892.3],
            validityMask: [1, 1, 1, 1],
            qualityFactorsQ: [13.9, 14.8, 22.4, 10.0],
            qValidityMask: [1, 1, 1, 1],
            decayAlphaPerSec: [84.8, 105.3, 33.6, 46.8],
            decayDBPerSec: [736.0, 914.0, 292.0, 406.0],
            decayRSquared: [0.84, 0.89, 0.91, 0.87],
            decayValidityMask: [1, 1, 1, 1],
            spectralAttenuationSlopeDBPerKHz: 1.34,
            bubbleScatter55to85DB: -10.2
        )
        let loadedFeat = ExtractedConsumerFeatures(
            activeSNRDB: 33.3,
            peakDBFS: -24.8,
            clippedSamples: 0,
            dominantPeakHz: 2_182.0,
            spectralCentroidHz: 3_383.0,
            midToHighBandDB: 4.5,
            decaySlopeDBPerSec: 910.0,
            highFreqBubbleScatterDB: -10.2,
            subBandShapeDB: [4.6, 4.4, 5.8, -1.6, -5.8, -7.4],
            echoReturnDB: -34.8,
            tailSNRDB: 20.1,
            preRollExcessHFDB: -6.5,
            modalVector: loadedMV
        )
        let uncalibratedItem = ConsumerScanItem(
            scanSequenceNumber: 215,
            batchRunID: "R1_20X_LOADED",
            batchScanIndex: 4,
            batchTotalCount: 20,
            geometryCondition: geom,
            status: .unmatchedSignature,
            title: "Unmatched Liquid",
            formulaDisplay: "NO_VALIDATED_MATCH",
            statusBadgeText: "Ambiguity Gate R2",
            confidencePercent: nil,
            scientificNote: "Uncalibrated",
            constituents: [],
            tuneProfile: tune,
            measuredPeakHz: loadedFeat.dominantPeakHz,
            measuredCentroidHz: loadedFeat.spectralCentroidHz,
            measuredDecayDBPerSec: loadedFeat.decaySlopeDBPerSec,
            measuredFeatures: loadedFeat,
            isConditioningCycle: false
        )

        let classifier = OnDeviceAcousticClassifier()
        let reconciled = classifier.reevaluateExistingItem(uncalibratedItem, calibratedPrototypes: [emptyProto])
        XCTAssertEqual(reconciled.modeAScreeningState, .liquidLoaded)
        XCTAssertEqual(reconciled.title, "Liquid Loaded (Unmatched Class)")
        let de = try XCTUnwrap(reconciled.deltaEmptyBaseline)
        XCTAssertTrue(de.compatible)
        XCTAssertEqual(de.shiftMask, [1, 1, 1, 1])
        XCTAssertEqual(de.relativeFrequencyShifts[0] ?? 0.0, (1_724.4 - 2_130.0) / 2_130.0, accuracy: 1e-4)
    }

    func testR2C_DifferentialBubbleScatterRequiresDeltaSHFAndActivePreRollFizz() {
        let geom = GeometryTestCondition.stationary15InBaseline.rawValue
        let emptyProto = CalibratedAcousticPrototype(
            targetID: CalibratedAcousticPrototype.emptyContainerTargetID,
            features: ExtractedConsumerFeatures(
                activeSNRDB: 32.0, peakDBFS: -26.0, clippedSamples: 0,
                dominantPeakHz: 2_529.0, spectralCentroidHz: 3_775.0,
                midToHighBandDB: 3.0, decaySlopeDBPerSec: 797.0,
                highFreqBubbleScatterDB: -7.5, preRollExcessHFDB: -4.5
            ),
            geometryCondition: geom
        )
        let waterProto = CalibratedAcousticPrototype(
            targetID: CalibratedAcousticPrototype.waterReferenceTargetID,
            features: ExtractedConsumerFeatures(
                activeSNRDB: 33.0, peakDBFS: -25.0, clippedSamples: 0,
                dominantPeakHz: 2_182.0, spectralCentroidHz: 3_383.0,
                midToHighBandDB: 4.5, decaySlopeDBPerSec: 910.0,
                highFreqBubbleScatterDB: -6.8, preRollExcessHFDB: -6.2
            ),
            geometryCondition: geom
        )
        let baselines = [emptyProto, waterProto]

        // 1. Dry empty glass with elevated -4.56 dB ratio but quiet room pre-roll (-4.5 dB <= 0) -> FALSE
        let dryEmptyWeakEcho = ExtractedConsumerFeatures(
            activeSNRDB: 31.0, peakDBFS: -26.2, clippedSamples: 0,
            dominantPeakHz: 2_527.0, spectralCentroidHz: 3_780.0,
            midToHighBandDB: 2.8, decaySlopeDBPerSec: 800.0,
            highFreqBubbleScatterDB: -4.56, preRollExcessHFDB: -4.5
        )
        XCTAssertFalse(OnDeviceAcousticClassifier.detectMicroBubbleScatter(features: dryEmptyWeakEcho))
        XCTAssertFalse(
            OnDeviceAcousticClassifier.detectMicroBubbleScatter(
                features: dryEmptyWeakEcho,
                geometryCondition: geom,
                prototypes: baselines
            )
        )

        // 2. Fizzing pre-roll (+2.2 dB > 0) but Delta S_HF = -5.0 - (-6.8) = +1.8 dB < +2.5 dB -> FALSE
        let belowDeltaGate = ExtractedConsumerFeatures(
            activeSNRDB: 34.0, peakDBFS: -25.0, clippedSamples: 0,
            dominantPeakHz: 2_480.0, spectralCentroidHz: 3_820.0,
            midToHighBandDB: 1.4, decaySlopeDBPerSec: 640.0,
            highFreqBubbleScatterDB: -5.0, preRollExcessHFDB: 2.2
        )
        XCTAssertEqual(
            OnDeviceAcousticClassifier.computeDifferentialBubbleScatterDB(
                features: belowDeltaGate,
                geometryCondition: geom,
                prototypes: baselines
            ) ?? 0.0,
            1.8,
            accuracy: 1e-6
        )
        XCTAssertFalse(
            OnDeviceAcousticClassifier.detectMicroBubbleScatter(
                features: belowDeltaGate,
                geometryCondition: geom,
                prototypes: baselines
            )
        )

        // 3. Active effervescence: preRollExcessHFDB = +3.1 dB > 0 AND Delta S_HF = -3.4 - (-6.8) = +3.4 dB >= +2.5 dB -> TRUE
        let activeFizz = ExtractedConsumerFeatures(
            activeSNRDB: 35.0, peakDBFS: -24.5, clippedSamples: 0,
            dominantPeakHz: 2_480.0, spectralCentroidHz: 3_880.0,
            midToHighBandDB: 1.1, decaySlopeDBPerSec: 620.0,
            highFreqBubbleScatterDB: -3.4, preRollExcessHFDB: 3.1
        )
        XCTAssertTrue(
            OnDeviceAcousticClassifier.detectMicroBubbleScatter(
                features: activeFizz,
                geometryCondition: geom,
                prototypes: baselines
            )
        )
    }

    func testR2C_LogRatioDecayNormalizationPreventsDiagnosticDistanceExplosion() {
        let classifier = OnDeviceAcousticClassifier()
        // High-rate Schroeder EDC decay (2,955 dB/s from live Build 13 iPhone Duo scan)
        let highRateScan = ExtractedConsumerFeatures(
            activeSNRDB: 35.5,
            peakDBFS: -23.1,
            clippedSamples: 0,
            dominantPeakHz: 3_497.0,
            spectralCentroidHz: 3_703.0,
            midToHighBandDB: 2.1,
            decaySlopeDBPerSec: 2_955.0,
            highFreqBubbleScatterDB: -9.5
        )
        let scored = classifier.computeFrozenCandidateDistances(
            profiles: ReferenceLiquidProfile.provisionalLibrary,
            features: highRateScan
        )
        let bestDist = scored.first?.distance ?? 999.0
        // Under Build 13 linear /38 scaling, bestDist exploded to ~28.1; log-ratio keeps diagnostic distances bounded < 3.6
        XCTAssertLessThan(bestDist, 3.6)
    }

    @MainActor
    func testR2C_CameraTargetingServicePurgesStaleThumbnailOnStopAndStart() {
        let cam = CameraTargetingService()
        #if !os(iOS)
        let fakeOilJPEG = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02])
        cam.injectSimulatedLiveFrameForTesting(thumbnail: fakeOilJPEG)
        XCTAssertTrue(cam.isCameraLive)
        XCTAssertEqual(cam.latestTargetingThumbnail(), fakeOilJPEG)
        #endif

        // Stopping camera after Run 5 must immediately clear isCameraLive and purge cached JPEG frames
        cam.stopCamera()
        XCTAssertFalse(cam.isCameraLive)
        XCTAssertNil(cam.latestTargetingThumbnail())
        XCTAssertNil(cam.latestSceneContextJPEG())

        // Starting camera with graceDelaySeconds: 0.0 must also ensure no stale frame is present prior to fresh capture
        cam.startCamera(graceDelaySeconds: 0.0)
        XCTAssertNil(cam.latestTargetingThumbnail())
    }

    // MARK: - v0.5.0 Multi-Modal Sensor Fusion & Guided 3-Step Cup Comparator Tests

    func testV050_Scan63CookingOilWithEmptyBaselineResolvesFusedOilAndHonorsPureAcousticModeAOverride() throws {
        let geom = GeometryTestCondition.stationary15InBaseline.rawValue
        let goldenOilJPEG = try Self.makeSyntheticReticleJPEG(
            outerRGB: (216, 216, 216),
            rimRGB: (82, 82, 82),
            innerRGB: (232, 192, 32)
        )

        // Exact Build 14 iPhone Duo Empty Glass baseline (`R1_20X_20261119_151200`: [2836.4, 3418.6, 3637.6, 4314.4] Hz)
        let emptyMV = ModalVector4(
            frequenciesHz: [2_836.4, 3_418.6, 3_637.6, 4_314.4],
            validityMask: [1, 1, 1, 1],
            qualityFactorsQ: [18.0, 22.0, 25.0, 31.0],
            qValidityMask: [1, 1, 1, 1],
            decayAlphaPerSec: [82.0, 96.0, 74.0, 68.0],
            decayDBPerSec: [712.0, 834.0, 643.0, 591.0],
            decayRSquared: [0.89, 0.87, 0.90, 0.86],
            decayValidityMask: [1, 1, 1, 1],
            spectralAttenuationSlopeDBPerKHz: -1.10,
            bubbleScatter55to85DB: -9.41
        )
        let emptyProto = CalibratedAcousticPrototype(
            targetID: CalibratedAcousticPrototype.emptyContainerTargetID,
            features: ExtractedConsumerFeatures(
                activeSNRDB: 33.0, peakDBFS: -25.0, clippedSamples: 0,
                dominantPeakHz: 2_836.4, spectralCentroidHz: 3_610.0,
                midToHighBandDB: 2.8, decaySlopeDBPerSec: 712.0,
                highFreqBubbleScatterDB: -9.41, preRollExcessHFDB: -5.2,
                modalVector: emptyMV
            ),
            geometryCondition: geom
        )

        // Exact Scan 63 Cooking Oil modes ([2073.5, 3071.9, 4165.7, 4324.3] Hz -> max |Delta f/f| = 26.89%)
        let oilMV = ModalVector4(
            frequenciesHz: [2_073.5, 3_071.9, 4_165.7, 4_324.3],
            validityMask: [1, 1, 1, 1],
            qualityFactorsQ: [14.2, 16.5, 19.0, 24.0],
            qValidityMask: [1, 1, 1, 1],
            decayAlphaPerSec: [79.0, 64.0, 58.0, 72.0],
            decayDBPerSec: [686.0, 556.0, 504.0, 625.0],
            decayRSquared: [0.86, 0.88, 0.84, 0.89],
            decayValidityMask: [1, 1, 1, 1],
            spectralAttenuationSlopeDBPerKHz: -0.56,
            bubbleScatter55to85DB: -10.61
        )
        let oilFeat = ExtractedConsumerFeatures(
            activeSNRDB: 34.2, peakDBFS: -24.1, clippedSamples: 0,
            dominantPeakHz: 2_073.5, spectralCentroidHz: 3_210.0,
            midToHighBandDB: 4.1, decaySlopeDBPerSec: 610.0,
            highFreqBubbleScatterDB: -10.61, preRollExcessHFDB: -6.0,
            modalVector: oilMV
        )
        let scan63Held = ConsumerScanItem(
            scanSequenceNumber: 63,
            geometryCondition: geom,
            status: .unmatchedSignature,
            title: "Liquid Loaded (Unmatched Class)",
            formulaDisplay: "LIQUID_LOADED",
            statusBadgeText: "MODE_A Screening • Liquid Loaded",
            confidencePercent: nil,
            scientificNote: "Held",
            constituents: [],
            tuneProfile: ReferenceLiquidProfile.provisionalLibrary[0].tuneProfile,
            measuredPeakHz: 2_073.5,
            measuredCentroidHz: 3_210.0,
            measuredDecayDBPerSec: 610.0,
            measuredFeatures: oilFeat,
            thumbnailJPEGData: goldenOilJPEG
        )

        let classifier = OnDeviceAcousticClassifier()
        // 1. Default v0.5.0 Multi-Modal Fusion resolves Cooking / Vegetable Oil with dual-channel attribution
        let fused = classifier.reevaluateExistingItem(scan63Held, calibratedPrototypes: [emptyProto])
        XCTAssertEqual(fused.status, .referenceMatch)
        XCTAssertEqual(fused.title, "Cooking / Vegetable Oil")
        XCTAssertEqual(fused.formulaDisplay, "Triglyceride")
        XCTAssertNotNil(fused.fusionAttribution)
        XCTAssertTrue(fused.fusionAttribution?.acousticEvidenceSummary.contains("26.90%") == true || fused.fusionAttribution?.acousticEvidenceSummary.contains("26.89%") == true)

        // 2. Pure-Acoustic MODE_A override preserves frozen Build 14 screening holdback verbatim
        let pureModeA = classifier.reevaluateExistingItem(
            scan63Held,
            calibratedPrototypes: [emptyProto],
            inferenceModeOverride: .pureAcousticModeA
        )
        XCTAssertEqual(pureModeA.status, .unmatchedSignature)
        XCTAssertEqual(pureModeA.title, "Liquid Loaded (Unmatched Class)")
        XCTAssertNil(pureModeA.fusionAttribution)
    }

    func testV050_MilkRedWineCitrusJuiceAndColaVsCoffeeDisambiguateCleanly() throws {
        let (ess, inv) = try Self.loadBundledESSAndInverse()
        let classifier = OnDeviceAcousticClassifier()
        var prng: UInt64 = 0x1234_5678_9ABC_DEF0
        let cavityRec = Self.makeDeconvolvedChannelRecording(
            ess: ess,
            distanceInches: 14.0,
            modes: [(2_240.0, 0.00042, 0.0034), (3_680.0, 0.00028, 0.0026)],
            noiseRMS: 0.0014,
            onsetJitterSamples: 0,
            injectStartupTransient: false,
            prng: &prng
        )

        // 1. Milk: High-albedo opaque white colloidal emulsion
        let milkJPEG = try Self.makeSyntheticReticleJPEG(
            outerRGB: (214, 214, 214),
            rimRGB: (106, 110, 118),
            innerRGB: (244, 244, 242)
        )
        let milkRes = classifier.classifySamples(samples: cavityRec, inverseFilter: inv, thumbnailJPEGData: milkJPEG)
        XCTAssertEqual(milkRes.status, .referenceMatch)
        XCTAssertEqual(milkRes.title, "Milk")

        // 2. Red Wine: Dark absorptive core with ruby/burgundy meniscus halo
        let wineJPEG = try Self.makeSyntheticHaloReticleJPEG(
            outerRGB: (216, 216, 216),
            rimRGB: (188, 190, 194),
            haloRGB: (168, 22, 52),
            innerRGB: (38, 10, 18)
        )
        let wineRes = classifier.classifySamples(samples: cavityRec, inverseFilter: inv, thumbnailJPEGData: wineJPEG)
        XCTAssertEqual(wineRes.status, .referenceMatch)
        XCTAssertEqual(wineRes.title, "Red Wine")

        // 3. Citrus / Fruit Juice: Chromatic orange pool
        let juiceJPEG = try Self.makeSyntheticReticleJPEG(
            outerRGB: (216, 216, 216),
            rimRGB: (176, 180, 184),
            innerRGB: (242, 136, 22)
        )
        let juiceRes = classifier.classifySamples(samples: cavityRec, inverseFilter: inv, thumbnailJPEGData: juiceJPEG)
        XCTAssertEqual(juiceRes.status, .referenceMatch)
        XCTAssertEqual(juiceRes.title, "Citrus / Fruit Juice")

        // 4. Black Coffee vs. Carbonated Cola on identical dark caramel frame split by acoustic BUBBLE_SCATTER_DETECTED
        let darkCaramelJPEG = try Self.makeSyntheticHaloReticleJPEG(
            outerRGB: (216, 216, 216),
            rimRGB: (188, 190, 194),
            haloRGB: (126, 78, 36),
            innerRGB: (34, 24, 18)
        )
        let coffeeRes = classifier.classifySamples(samples: cavityRec, inverseFilter: inv, thumbnailJPEGData: darkCaramelJPEG)
        XCTAssertEqual(coffeeRes.status, .referenceMatch)
        XCTAssertEqual(coffeeRes.title, "Coffee / Dark Beverage")

        let colaFizzFeat = ExtractedConsumerFeatures(
            activeSNRDB: 34.0, peakDBFS: -24.0, clippedSamples: 0,
            dominantPeakHz: 2_260.0, spectralCentroidHz: 3_420.0,
            midToHighBandDB: 1.5, decaySlopeDBPerSec: 690.0,
            highFreqBubbleScatterDB: -2.1, preRollExcessHFDB: 3.4,
            modalVector: ModalVector4(
                frequenciesHz: [2_260.0, 3_680.0, nil, nil],
                validityMask: [1, 1, 0, 0],
                qualityFactorsQ: [15.0, 20.0, nil, nil],
                qValidityMask: [1, 1, 0, 0],
                decayAlphaPerSec: [80.0, 92.0, nil, nil],
                decayDBPerSec: [695.0, 799.0, nil, nil],
                decayRSquared: [0.85, 0.82, nil, nil],
                decayValidityMask: [1, 1, 0, 0]
            )
        )
        let heldDarkItem = ConsumerScanItem(
            status: .unmatchedSignature,
            title: "Unmatched Liquid",
            formulaDisplay: "NO_VALIDATED_MATCH",
            statusBadgeText: "Held",
            confidencePercent: nil,
            scientificNote: "Held",
            constituents: [],
            tuneProfile: ReferenceLiquidProfile.provisionalLibrary[0].tuneProfile,
            measuredPeakHz: 2_260.0,
            measuredCentroidHz: 3_420.0,
            measuredDecayDBPerSec: 690.0,
            measuredFeatures: colaFizzFeat,
            thumbnailJPEGData: darkCaramelJPEG
        )
        let colaRes = classifier.reevaluateExistingItem(heldDarkItem, calibratedPrototypes: [])
        XCTAssertEqual(colaRes.status, .referenceMatch)
        XCTAssertEqual(colaRes.title, "Cola / Carbonated Soda")
    }

    func testV050_CarbonatedSeltzerVsUncalibratedClearWaterGuidance() throws {
        let geom = GeometryTestCondition.stationary15InBaseline.rawValue
        let clearCupJPEG = try Self.makeSyntheticReticleJPEG(
            outerRGB: (215, 215, 215),
            rimRGB: (84, 88, 94),
            innerRGB: (192, 195, 198)
        )
        let emptyMV = ModalVector4(
            frequenciesHz: [2_836.4, 3_418.6, 3_637.6, 4_314.4],
            validityMask: [1, 1, 1, 1],
            qualityFactorsQ: [18.0, 22.0, 25.0, 31.0],
            qValidityMask: [1, 1, 1, 1],
            decayAlphaPerSec: [82.0, 96.0, 74.0, 68.0],
            decayDBPerSec: [712.0, 834.0, 643.0, 591.0],
            decayRSquared: [0.89, 0.87, 0.90, 0.86],
            decayValidityMask: [1, 1, 1, 1]
        )
        let emptyProto = CalibratedAcousticPrototype(
            targetID: CalibratedAcousticPrototype.emptyContainerTargetID,
            features: ExtractedConsumerFeatures(
                activeSNRDB: 33.0, peakDBFS: -25.0, clippedSamples: 0,
                dominantPeakHz: 2_836.4, spectralCentroidHz: 3_610.0,
                midToHighBandDB: 2.8, decaySlopeDBPerSec: 712.0,
                highFreqBubbleScatterDB: -9.41, preRollExcessHFDB: -5.2,
                modalVector: emptyMV
            ),
            geometryCondition: geom
        )

        let loadedMV = ModalVector4(
            frequenciesHz: [2_380.0, 3_120.0, 3_590.0, 4_290.0],
            validityMask: [1, 1, 1, 1],
            qualityFactorsQ: [14.0, 19.0, 22.0, 27.0],
            qValidityMask: [1, 1, 1, 1],
            decayAlphaPerSec: [95.0, 110.0, 88.0, 76.0],
            decayDBPerSec: [825.0, 955.0, 764.0, 660.0],
            decayRSquared: [0.86, 0.84, 0.88, 0.85],
            decayValidityMask: [1, 1, 1, 1]
        )

        // 1. Effervescent sparkling water (Delta S_HF = -5.8 - (-9.41) = +3.61 dB >= +2.5 dB AND preRollExcessHFDB = +2.9 > 0)
        let seltzerFeat = ExtractedConsumerFeatures(
            activeSNRDB: 34.5, peakDBFS: -24.2, clippedSamples: 0,
            dominantPeakHz: 2_380.0, spectralCentroidHz: 3_640.0,
            midToHighBandDB: 1.4, decaySlopeDBPerSec: 825.0,
            highFreqBubbleScatterDB: -5.80, preRollExcessHFDB: 2.9,
            modalVector: loadedMV
        )
        let classifier = OnDeviceAcousticClassifier()
        let baseItem = ConsumerScanItem(
            geometryCondition: geom,
            status: .unmatchedSignature,
            title: "Unmatched",
            formulaDisplay: "HELD",
            statusBadgeText: "Held",
            confidencePercent: nil,
            scientificNote: "Held",
            constituents: [],
            tuneProfile: ReferenceLiquidProfile.provisionalLibrary[0].tuneProfile,
            measuredPeakHz: 2_380.0,
            measuredCentroidHz: 3_640.0,
            measuredDecayDBPerSec: 825.0,
            measuredFeatures: seltzerFeat,
            thumbnailJPEGData: clearCupJPEG
        )
        let seltzerRes = classifier.reevaluateExistingItem(baseItem, calibratedPrototypes: [emptyProto])
        XCTAssertEqual(seltzerRes.status, .referenceMatch)
        XCTAssertEqual(seltzerRes.title, "Carbonated Seltzer")
        XCTAssertEqual(seltzerRes.formulaDisplay, "H₂O + CO₂(aq)")

        // 2. Still clear liquid without WATER_REFERENCE holds solute sub-claim and recommends Guided 3-Step Cup Comparator
        let stillClearFeat = ExtractedConsumerFeatures(
            activeSNRDB: 34.5, peakDBFS: -24.2, clippedSamples: 0,
            dominantPeakHz: 2_380.0, spectralCentroidHz: 3_380.0,
            midToHighBandDB: 4.2, decaySlopeDBPerSec: 825.0,
            highFreqBubbleScatterDB: -10.1, preRollExcessHFDB: -5.8,
            modalVector: loadedMV
        )
        let stillItem = ConsumerScanItem(
            geometryCondition: geom,
            status: .unmatchedSignature,
            title: "Unmatched",
            formulaDisplay: "HELD",
            statusBadgeText: "Held",
            confidencePercent: nil,
            scientificNote: "Held",
            constituents: [],
            tuneProfile: ReferenceLiquidProfile.provisionalLibrary[0].tuneProfile,
            measuredPeakHz: 2_380.0,
            measuredCentroidHz: 3_380.0,
            measuredDecayDBPerSec: 825.0,
            measuredFeatures: stillClearFeat,
            thumbnailJPEGData: clearCupJPEG
        )
        let stillRes = classifier.reevaluateExistingItem(stillItem, calibratedPrototypes: [emptyProto])
        XCTAssertEqual(stillRes.status, .unmatchedSignature)
        XCTAssertEqual(stillRes.fusionAttribution?.recommendsGuidedComparator, true)
    }

    func testV050_Guided3StepCupComparatorSeparatesWaterVinegarAndSaline() throws {
        let geom = GeometryTestCondition.stationary15InBaseline.rawValue
        let steepMeniscusJPEG = try Self.makeSyntheticSideMeniscusJPEG(capillaryRisePx: 7.0)
        let flatMeniscusJPEG = try Self.makeSyntheticSideMeniscusJPEG(capillaryRisePx: 0.0)

        // Verify VisionFeatureExtractor meniscus contact-angle geometry directly
        let extractor = VisionFeatureExtractor()
        let waterVis = extractor.extract(jpegData: steepMeniscusJPEG)
        let vinegarVis = extractor.extract(jpegData: flatMeniscusJPEG)
        XCTAssertGreaterThanOrEqual(waterVis.meniscusEdgeStrength, 0.028)
        XCTAssertLessThan(waterVis.meniscusContactAngleDegrees, 34.0)
        XCTAssertGreaterThan(vinegarVis.meniscusContactAngleDegrees, 40.0)
        XCTAssertNotNil(waterVis.estimatedFillFraction)

        // Step 1: Empty Cup ([2836.4, 3418.6, 3637.6, 4314.4] Hz)
        let emptyMV = ModalVector4(
            frequenciesHz: [2_836.4, 3_418.6, 3_637.6, 4_314.4],
            validityMask: [1, 1, 1, 1],
            qualityFactorsQ: [18.0, 22.0, 25.0, 31.0],
            qValidityMask: [1, 1, 1, 1],
            decayAlphaPerSec: [82.0, 96.0, 74.0, 68.0],
            decayDBPerSec: [712.0, 834.0, 643.0, 591.0],
            decayRSquared: [0.89, 0.87, 0.90, 0.86],
            decayValidityMask: [1, 1, 1, 1]
        )
        // Step 2: Water Blank ([1811.0, 3117.4, 3608.3, 4329.3] Hz)
        let waterMV = ModalVector4(
            frequenciesHz: [1_811.0, 3_117.4, 3_608.3, 4_329.3],
            validityMask: [1, 1, 1, 1],
            qualityFactorsQ: [14.0, 18.0, 23.0, 26.0],
            qValidityMask: [1, 1, 1, 1],
            decayAlphaPerSec: [85.0, 104.0, 90.0, 62.0],
            decayDBPerSec: [738.0, 903.0, 782.0, 538.0],
            decayRSquared: [0.86, 0.88, 0.90, 0.85],
            decayValidityMask: [1, 1, 1, 1]
        )
        let comparatorBaselines = [
            CalibratedAcousticPrototype(
                targetID: CalibratedAcousticPrototype.emptyContainerTargetID,
                features: ExtractedConsumerFeatures(
                    activeSNRDB: 33.0, peakDBFS: -25.0, clippedSamples: 0,
                    dominantPeakHz: 2_836.4, spectralCentroidHz: 3_610.0,
                    midToHighBandDB: 2.8, decaySlopeDBPerSec: 712.0,
                    highFreqBubbleScatterDB: -9.4, preRollExcessHFDB: -5.2,
                    modalVector: emptyMV
                ),
                geometryCondition: geom
            ),
            CalibratedAcousticPrototype(
                targetID: CalibratedAcousticPrototype.waterReferenceTargetID,
                features: ExtractedConsumerFeatures(
                    activeSNRDB: 34.0, peakDBFS: -24.5, clippedSamples: 0,
                    dominantPeakHz: 1_811.0, spectralCentroidHz: 3_380.0,
                    midToHighBandDB: 4.5, decaySlopeDBPerSec: 780.0,
                    highFreqBubbleScatterDB: -10.1, preRollExcessHFDB: -6.0,
                    modalVector: waterMV
                ),
                geometryCondition: geom
            )
        ]

        func evaluateClearSample(freqs: [Double], jpeg: Data) -> ConsumerScanItem {
            let mv = ModalVector4(
                frequenciesHz: freqs.map { Optional($0) },
                validityMask: [1, 1, 1, 1],
                qualityFactorsQ: [14.0, 18.0, 22.0, 26.0],
                qValidityMask: [1, 1, 1, 1],
                decayAlphaPerSec: [84.0, 98.0, 86.0, 64.0],
                decayDBPerSec: [729.0, 851.0, 747.0, 556.0],
                decayRSquared: [0.86, 0.87, 0.89, 0.85],
                decayValidityMask: [1, 1, 1, 1]
            )
            let feat = ExtractedConsumerFeatures(
                activeSNRDB: 34.0, peakDBFS: -24.4, clippedSamples: 0,
                dominantPeakHz: freqs[0], spectralCentroidHz: 3_350.0,
                midToHighBandDB: 4.2, decaySlopeDBPerSec: 760.0,
                highFreqBubbleScatterDB: -9.8, preRollExcessHFDB: -5.5,
                modalVector: mv
            )
            let item = ConsumerScanItem(
                geometryCondition: geom,
                status: .unmatchedSignature,
                title: "Unmatched",
                formulaDisplay: "HELD",
                statusBadgeText: "Held",
                confidencePercent: nil,
                scientificNote: "Held",
                constituents: [],
                tuneProfile: ReferenceLiquidProfile.provisionalLibrary[0].tuneProfile,
                measuredPeakHz: freqs[0],
                measuredCentroidHz: 3_350.0,
                measuredDecayDBPerSec: 760.0,
                measuredFeatures: feat,
                thumbnailJPEGData: jpeg
            )
            return OnDeviceAcousticClassifier().reevaluateExistingItem(item, calibratedPrototypes: comparatorBaselines)
        }

        // Step 3A: Pure Water re-pour (~0.2% deviation from Water Blank, steep capillary rise) -> Water
        let waterMatch = evaluateClearSample(freqs: [1_814.0, 3_112.0, 3_613.0, 4_324.0], jpeg: steepMeniscusJPEG)
        XCTAssertEqual(waterMatch.status, .referenceMatch)
        XCTAssertEqual(waterMatch.title, "Water")

        // Step 3B: Vinegar / Acetic Acid (~ -2.3% modal shift vs. Water Blank + flatter meniscus) -> Vinegar
        let vinegarMatch = evaluateClearSample(freqs: [1_764.0, 3_048.0, 3_525.0, 4_232.0], jpeg: flatMeniscusJPEG)
        XCTAssertEqual(vinegarMatch.status, .referenceMatch)
        XCTAssertEqual(vinegarMatch.title, "Vinegar")
        XCTAssertEqual(vinegarMatch.formulaDisplay, "H₂O + CH₃COOH")

        // Step 3C: Salt / Saline Water (~ +2.4% ionic velocity/density shift vs. Water Blank + steep meniscus) -> Salt / Saline Water
        let salineMatch = evaluateClearSample(freqs: [1_862.0, 3_196.0, 3_691.0, 4_422.0], jpeg: steepMeniscusJPEG)
        XCTAssertEqual(salineMatch.status, .referenceMatch)
        XCTAssertEqual(salineMatch.title, "Salt / Saline Water")
        XCTAssertEqual(salineMatch.formulaDisplay, "H₂O + NaCl")
    }

    func testV050_Flat2DSpoofAcousticsBlocksGoldenOilFalseClaim() throws {
        // Synthetic broadband flat-spectrum noise lacking any 3D container cavity resonance
        var flatNoise = [Float](repeating: 0.0, count: 24_000)
        var prng: UInt64 = 0xCAFE_BABE_1357_2468
        for i in 0..<24_000 {
            let amp = (i < 7_200) ? 0.0003 : 0.06
            flatNoise[i] = Float(amp * Self.nextGaussian(&prng))
        }
        let goldenOilJPEG = try Self.makeSyntheticReticleJPEG(
            outerRGB: (216, 216, 216),
            rimRGB: (82, 82, 82),
            innerRGB: (232, 192, 32)
        )
        let res = OnDeviceAcousticClassifier().classifySamples(
            samples: flatNoise,
            inverseFilter: nil,
            thumbnailJPEGData: goldenOilJPEG
        )
        // Must NOT classify flat broadband noise + golden picture as Cooking / Vegetable Oil
        XCTAssertNotEqual(res.title, "Cooking / Vegetable Oil")
    }

    // MARK: - Helpers

    private static func loadBundledESSAndInverse() throws -> (ess: [Float], inv: [Float]) {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let assetsDir = repoRoot.appendingPathComponent("Assets", isDirectory: true)
        let essFile = try AVAudioFile(forReading: assetsDir.appendingPathComponent("SIG_ESS_v1.wav"))
        let invFile = try AVAudioFile(forReading: assetsDir.appendingPathComponent("SIG_ESS_v1_inverse.wav"))

        func readFloats(_ f: AVAudioFile) throws -> [Float] {
            let n = AVAudioFrameCount(f.length)
            let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: n)!
            try f.read(into: buf)
            let ptr = buf.floatChannelData![0]
            return Array(UnsafeBufferPointer(start: ptr, count: Int(buf.frameLength)))
        }
        return (try readFloats(essFile), try readFloats(invFile))
    }

    private static func nextGaussian(_ state: inout UInt64) -> Double {
        func nextUnit(_ s: inout UInt64) -> Double {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Double((s >> 11) | 1) / Double(1 << 53)
        }
        let u1 = max(1e-9, nextUnit(&state))
        let u2 = nextUnit(&state)
        return sqrt(-2.0 * log(u1)) * cos(2.0 * Double.pi * u2)
    }

    private static func makeDeconvolvedChannelRecording(
        ess: [Float],
        distanceInches: Double,
        modes: [(freqHz: Double, amp: Double, tauSec: Double)],
        noiseRMS: Double,
        onsetJitterSamples: Int,
        injectStartupTransient: Bool,
        injectSpeakerPortBleed3820Hz: Bool = false,
        prng: inout UInt64
    ) -> [Float] {
        let sr = 48_000.0
        var h = [Double](repeating: 0.0, count: 1_024)
        h[4] = 0.105
        h[5] = -0.042
        if injectSpeakerPortBleed3820Hz {
            for k in 1..<180 {
                let dt = Double(k) / sr
                h[4 + k] += 0.025 * exp(-dt / 0.00115) * sin(2.0 * Double.pi * 3_820.0 * dt)
            }
        }
        let tof = Int(round((2.0 * (distanceInches * 0.0254) / 343.0) * sr)) + 4
        for k in 0..<420 where (tof + k) < h.count {
            let dt = Double(k) / sr
            var v = 0.0
            for m in modes {
                v += m.amp * exp(-dt / m.tauSec) * sin(2.0 * Double.pi * m.freqHz * dt)
            }
            h[tof + k] += v
        }

        // Direct time-domain convolution with short 512-tap channel h
        let convLen = ess.count + 512
        var clean = [Double](repeating: 0.0, count: convLen)
        for i in 0..<ess.count {
            let x = Double(ess[i])
            for k in 0..<min(512, h.count) where h[k] != 0.0 {
                clean[i + k] += x * h[k]
            }
        }

        let totalLen = 26_000
        var rec = [Float](repeating: 0.0, count: totalLen)
        if injectStartupTransient {
            for i in 0..<600 {
                let pop = 0.014 * exp(-Double(i) / 120.0) * sin(2.0 * Double.pi * 6_800.0 * Double(i) / sr)
                rec[i] += Float(pop)
            }
        }
        let startIdx = max(2_000, 7_200 + onsetJitterSamples)
        for i in 0..<clean.count where (startIdx + i) < totalLen {
            rec[startIdx + i] += Float(clean[i])
        }
        for i in 0..<totalLen {
            rec[i] += Float(noiseRMS * nextGaussian(&prng))
        }
        return rec
    }

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

    private static func makeSyntheticHaloReticleJPEG(
        outerRGB: (UInt8, UInt8, UInt8),
        rimRGB: (UInt8, UInt8, UInt8),
        haloRGB: (UInt8, UInt8, UInt8),
        innerRGB: (UInt8, UInt8, UInt8)
    ) throws -> Data {
        let size = 128
        var rgba = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let dx = (Double(x) - 63.5) / 64.0
                let dy = (Double(y) - 63.5) / 64.0
                let r = sqrt(dx * dx + dy * dy)
                let c: (UInt8, UInt8, UInt8)
                if r <= 0.24 {
                    c = innerRGB
                } else if r <= 0.36 {
                    c = haloRGB
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

    private static func makeSyntheticSideMeniscusJPEG(capillaryRisePx: Double) throws -> Data {
        let size = 128
        var rgba = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let dx = (Double(x) - 63.5) / 64.0
                let dy = (Double(y) - 63.5) / 64.0
                let r = sqrt(dx * dx + dy * dy)
                let c: (UInt8, UInt8, UInt8)
                if r > 0.58 {
                    c = (216, 216, 216)
                } else if r >= 0.40 {
                    c = (88, 92, 98)
                } else {
                    let normWallX = min(1.2, abs(Double(x) - 63.5) / 22.0)
                    let meniscusY = 64.0 - capillaryRisePx * (normWallX * normWallX)
                    if Double(y) < meniscusY {
                        c = (212, 214, 218)
                    } else {
                        c = (160, 164, 170)
                    }
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
