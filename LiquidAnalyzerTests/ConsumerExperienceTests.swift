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
        prng: inout UInt64
    ) -> [Float] {
        let sr = 48_000.0
        var h = [Double](repeating: 0.0, count: 1_024)
        h[4] = 0.105
        h[5] = -0.042
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
