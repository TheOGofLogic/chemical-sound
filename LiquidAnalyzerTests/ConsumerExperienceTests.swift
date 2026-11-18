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

    func testLowFrequencyRoomRumbleNeverForcesEverythingToVegetableOilCHO() {
        let sr = 48_000.0
        let preFrames = 7_200
        let totalFrames = 24_000
        var samples = [Float](repeating: 0.0, count: totalFrames)

        // Heavy 550 Hz room rumble + normal 2.25 kHz aqueous container reflection
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

    func testMultimodalVisualAndAcousticClassifierDistinguishesWaterBottleOilAndBlankSurface() throws {
        let samples = Self.makeWaterResonanceSamples()
        let classifier = OnDeviceAcousticClassifier()

        // 1. Covered / blank non-liquid frame -> friendly "No Liquid Detected"
        let blankJPEG = try Self.makeSyntheticReticleJPEG(
            outerRGB: (8, 8, 8),
            rimRGB: (8, 8, 8),
            innerRGB: (8, 8, 8)
        )
        let blankResult = classifier.classifySamples(samples: samples, inverseFilter: nil, thumbnailJPEGData: blankJPEG)
        XCTAssertEqual(blankResult.status, .unclearScan)
        XCTAssertEqual(blankResult.title, "No Liquid Detected")

        // 2. Clear water inside cup/bowl (even with slight warm indoor tint) -> Water (H₂O)
        let waterJPEG = try Self.makeSyntheticReticleJPEG(
            outerRGB: (220, 212, 198),
            rimRGB: (75, 78, 84),
            innerRGB: (192, 186, 174)
        )
        let waterResult = classifier.classifySamples(samples: samples, inverseFilter: nil, thumbnailJPEGData: waterJPEG)
        XCTAssertEqual(waterResult.status, .referenceMatch)
        XCTAssertEqual(waterResult.title, "Water")
        XCTAssertEqual(waterResult.formulaDisplay, "H₂O")

        // 3. Blue packaged bottle -> Packaged Aqueous Solution
        let blueBottleJPEG = try Self.makeSyntheticReticleJPEG(
            outerRGB: (212, 212, 212),
            rimRGB: (28, 125, 210),
            innerRGB: (32, 136, 218)
        )
        let packagedResult = classifier.classifySamples(samples: samples, inverseFilter: nil, thumbnailJPEGData: blueBottleJPEG)
        XCTAssertEqual(packagedResult.status, .referenceMatch)
        XCTAssertEqual(packagedResult.title, "Packaged Aqueous Solution")

        // 4. Genuine high-chroma golden oil inside neutral rim -> Cooking / Vegetable Oil (Triglyceride)
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

    func testOutOfEnvelopeResonanceReturnsUnmatchedSignatureWithPlayableTune() {
        let sr = 48_000.0
        var samples = [Float](repeating: 0.0002, count: 24_000)
        for i in 7_200..<20_000 {
            let dt = Double(i - 7_200) / sr
            samples[i] = Float(0.16 * sin(2.0 * Double.pi * 9_400.0 * dt))
        }

        let classifier = OnDeviceAcousticClassifier()
        let result = classifier.classifySamples(samples: samples, inverseFilter: nil)
        XCTAssertEqual(result.status, .unmatchedSignature)
        XCTAssertEqual(result.title, "Unmatched Liquid")
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
            measuredPeakHz: 2_180.0,
            measuredCentroidHz: 2_520.0,
            measuredDecayDBPerSec: 74.0
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
            measuredPeakHz: 2_180.0,
            measuredCentroidHz: 2_520.0,
            measuredDecayDBPerSec: 74.0
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
                if r <= 0.40 {
                    c = innerRGB
                } else if r <= 0.54 {
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

        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &rgba,
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
